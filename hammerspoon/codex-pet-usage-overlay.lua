local M = {}

local moduleRegistryKey = "__codexPetUsageOverlayModule"
local canvasRegistryKey = "__codexPetUsageOverlayCanvases"
local previousModule = rawget(_G, moduleRegistryKey)
if type(previousModule) == "table" and type(previousModule.stop) == "function" then
  pcall(previousModule.stop)
end
local previousCanvases = rawget(_G, canvasRegistryKey)
if type(previousCanvases) == "table" then
  for _, canvas in pairs(previousCanvases) do
    pcall(function() canvas:delete() end)
  end
end
rawset(_G, moduleRegistryKey, M)

-- Load the two interaction-critical extensions during config startup. Loading
-- hs.canvas lazily on the first hover can otherwise delay the first ring.
local canvasModule = hs.canvas
local mouseModule = hs.mouse

local home = os.getenv("HOME") or "/Users/bzj"
local statePath = home .. "/.codex/.codex-global-state.json"
local logPaths = {
  home .. "/.codex/logs_2.sqlite",
  home .. "/.codex/logs_1.sqlite",
}

local canvases = {}
local canvasStates = {}
local timer = nil
local screenWatcher = nil
local stateWatcher = nil
local mouseWatcher = nil
local wakeTimer = nil
local wakeUpdate = nil
local currentUsage = { available = false, source = "none", observedAt = os.time() }
local lastUsageRead = 0
local usageRequestInFlight = false
local cachedState = nil
local codexRunning = false
local lastCodexCheckAt = 0

local idlePollSeconds = 0.1
local usageRefreshSeconds = 15

rawset(_G, canvasRegistryKey, canvases)

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function fileExists(path)
  local f = io.open(path, "r")
  if not f then return false end
  f:close()
  return true
end

local function readState()
  local body = readFile(statePath)
  if not body then return nil end
  local ok, decoded = pcall(hs.json.decode, body)
  if ok then return decoded end
  return nil
end

local function refreshCachedState()
  cachedState = readState()
  return cachedState
end

local function isCodexRunning()
  local now = hs.timer.secondsSinceEpoch()
  if now - lastCodexCheckAt < 1 then return codexRunning end
  lastCodexCheckAt = now
  codexRunning = false
  for _, bundleId in ipairs({ "com.openai.codex", "com.openai.chat" }) do
    if #(hs.application.applicationsForBundleID(bundleId) or {}) > 0 then
      codexRunning = true
      break
    end
  end
  return codexRunning
end

local function jsonObjectAt(text, startIndex)
  local depth = 0
  local inString = false
  local escaped = false

  for i = startIndex, #text do
    local ch = text:sub(i, i)
    if inString then
      if escaped then
        escaped = false
      elseif ch == "\\" then
        escaped = true
      elseif ch == '"' then
        inString = false
      end
    else
      if ch == '"' then
        inString = true
      elseif ch == "{" then
        depth = depth + 1
      elseif ch == "}" then
        depth = depth - 1
        if depth == 0 then
          return text:sub(startIndex, i)
        end
      end
    end
  end

  return nil
end

local function payloadFromLogBody(body)
  if type(body) ~= "string" or body == "" then return nil end

  local searchFrom = 1
  while true do
    local startIndex = body:find('{%s*"type"%s*:%s*"codex%.rate_limits"', searchFrom)
    if not startIndex then return nil end

    local json = jsonObjectAt(body, startIndex)
    if json then
      local ok, payload = pcall(hs.json.decode, json)
      if ok and type(payload) == "table" and payload.type == "codex.rate_limits" then
        return payload
      end
    end

    searchFrom = startIndex + 1
  end
end

local function clampPercent(value)
  local n = tonumber(value)
  if not n then return nil end
  if n < 0 then return 0 end
  if n > 100 then return 100 end
  return n
end

local function bucketRemaining(bucket)
  if type(bucket) ~= "table" then return nil end
  if bucket.remaining_percent ~= nil then
    return clampPercent(bucket.remaining_percent)
  end
  if bucket.used_percent ~= nil then
    return clampPercent(100 - tonumber(bucket.used_percent))
  end
  return nil
end

local function bucketResetAt(bucket)
  if type(bucket) ~= "table" then return nil end

  local after = tonumber(bucket.reset_after_seconds or bucket.seconds_until_reset)
  if after then return os.time() + after end

  for _, key in ipairs({ "reset_at", "resets_at", "reset_time", "expires_at", "window_reset_at" }) do
    local value = tonumber(bucket[key])
    if value then
      if value > 100000000000 then value = value / 1000 end
      return value
    end
  end

  return nil
end

local function bucketWindowSeconds(bucket)
  return type(bucket) == "table" and tonumber(bucket.limit_window_seconds or bucket.window_seconds) or nil
end

local function convertUsage(payload)
  local rate = payload and (payload.rate_limits or payload.rate_limit)
  if type(rate) ~= "table" then return nil end

  local primary = rate.primary_window or rate.primary
  local secondary = rate.secondary_window or rate.secondary
  local primaryRemaining = bucketRemaining(primary)
  local secondaryRemaining = bucketRemaining(secondary)

  if primaryRemaining == nil and secondaryRemaining == nil then return nil end

  return {
    available = true,
    source = "本地日志",
    observedAt = os.time(),
    primaryRemaining = primaryRemaining,
    secondaryRemaining = secondaryRemaining,
    primaryResetAt = bucketResetAt(primary),
    secondaryResetAt = bucketResetAt(secondary),
    primaryWindowSeconds = bucketWindowSeconds(primary),
    secondaryWindowSeconds = bucketWindowSeconds(secondary),
  }
end

local function readLiveUsage(callback)
  local authBody = readFile(home .. "/.codex/auth.json")
  if not authBody then callback(nil); return end

  local authOk, auth = pcall(hs.json.decode, authBody)
  local token = authOk and type(auth) == "table" and type(auth.tokens) == "table" and auth.tokens.access_token
  if type(token) ~= "string" or token == "" then callback(nil); return end

  hs.http.asyncGet("https://chatgpt.com/backend-api/wham/usage", {
    ["Authorization"] = "Bearer " .. token,
    ["Accept"] = "application/json",
  }, function(status, body)
    if status < 200 or status >= 300 or type(body) ~= "string" or body == "" then
      callback(nil)
      return
    end
    local decodedOk, payload = pcall(hs.json.decode, body)
    if not decodedOk or type(payload) ~= "table" then callback(nil); return end
    local usage = convertUsage(payload)
    if usage then usage.source = "实时" end
    callback(usage)
  end)
end

local function readLocalUsage(callback, index)
  local query = "SELECT feedback_log_body FROM logs WHERE feedback_log_body LIKE '%codex.rate_limits%' ORDER BY ts DESC, ts_nanos DESC, id DESC LIMIT 25;"
  local pathIndex = index or 1
  local path = logPaths[pathIndex]
  if not path then callback(nil); return end
  if not fileExists(path) then
    readLocalUsage(callback, pathIndex + 1)
    return
  end

  hs.task.new("/usr/bin/sqlite3", function(exitCode, output)
    if exitCode == 0 and output and output ~= "" then
      local decodedOk, rows = pcall(hs.json.decode, output)
      if decodedOk and type(rows) == "table" then
        for _, row in ipairs(rows) do
          local payload = payloadFromLogBody(row.feedback_log_body)
          local usage = convertUsage(payload)
          if usage then callback(usage); return end
        end
      end
    end
    readLocalUsage(callback, pathIndex + 1)
  end, { "-json", path, query }):start()
end

local function readUsage(force)
  local now = os.time()
  if usageRequestInFlight or (not force and now - lastUsageRead < usageRefreshSeconds) then
    return currentUsage
  end

  lastUsageRead = now
  usageRequestInFlight = true
  readLiveUsage(function(live)
    local function finish(usage)
      usageRequestInFlight = false
      if usage then
        currentUsage = usage
      elseif not currentUsage.available then
        currentUsage = { available = false, source = "none", observedAt = os.time() }
      end
      if wakeUpdate then wakeUpdate() end
    end

    if live then
      finish(live)
    else
      readLocalUsage(finish)
    end
  end)

  return currentUsage
end

local function refreshUsageLater()
  readUsage(false)
end

local function formatDuration(timestamp)
  if not timestamp then return "--" end
  local seconds = math.max(0, math.ceil(timestamp - os.time()))

  if seconds >= 86400 then
    return string.format("%d天 %d小时", math.floor(seconds / 86400), math.floor((seconds % 86400) / 3600))
  end
  if seconds >= 3600 then
    return string.format("%d小时 %d分钟", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
  end
  if seconds >= 60 then
    return string.format("%d分钟", math.floor(seconds / 60))
  end
  return string.format("%d秒", seconds)
end

local function matchingScreenFrame(display, displayId)
  if not display then return nil end
  local numericDisplayId = tonumber(displayId)
  if numericDisplayId then
    for _, s in ipairs(hs.screen.allScreens()) do
      if tonumber(s:id()) == numericDisplayId then return s:fullFrame() end
    end
  end
  for _, s in ipairs(hs.screen.allScreens()) do
    local f = s:fullFrame()
    if math.abs(f.x - (display.x or 0)) < 8
      and math.abs(f.w - (display.width or 0)) < 8
      and math.abs(f.h - (display.height or 0)) < 8 then
      return f
    end
  end
  for _, s in ipairs(hs.screen.allScreens()) do
    local f = s:fullFrame()
    if math.abs(f.w - (display.width or 0)) < 8
      and math.abs(f.h - (display.height or 0)) < 8 then
      return f
    end
  end
  return hs.screen.mainScreen() and hs.screen.mainScreen():fullFrame() or { x = 0, y = 0, w = 1280, h = 720 }
end

local function clamp(v, lo, hi)
  if hi < lo then return lo end
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function activeBoundsRecord(bounds)
  local displayId = bounds.displayId
  local byDisplay = type(bounds.byDisplayId) == "table" and bounds.byDisplayId
  local stored = byDisplay and (byDisplay[displayId] or byDisplay[tostring(displayId)])
  if type(stored) ~= "table" then return bounds end

  -- Codex keeps historical records for every display. Only enrich the active
  -- record when it describes the same pet position as the top-level record.
  if tonumber(bounds.x) and tonumber(bounds.y) and tonumber(stored.x) and tonumber(stored.y)
    and math.abs(bounds.x - stored.x) <= 1 and math.abs(bounds.y - stored.y) <= 1 then
    local merged = {}
    for key, value in pairs(stored) do merged[key] = value end
    for key, value in pairs(bounds) do
      if key ~= "byDisplayId" and key ~= "byResolution" then merged[key] = value end
    end
    return merged
  end
  return bounds
end

local function petGeometryForBounds(bounds)
  if type(bounds.anchor) == "table" then
    local anchor = bounds.anchor
    if tonumber(anchor.x) and tonumber(anchor.y) then
      return { x = anchor.x, y = anchor.y, w = anchor.width or 108, h = anchor.height or 117 }
    end
  end

  if type(bounds.mascot) == "table" and tonumber(bounds.x) and tonumber(bounds.y) then
    local mascot = bounds.mascot
    return {
      x = bounds.x + (mascot.left or 0),
      y = bounds.y + (mascot.top or 0),
      w = mascot.width or 108,
      h = mascot.height or 117,
    }
  end

  -- ChatGPT/Codex 26.x publishes the pet's top-left point directly.
  if tonumber(bounds.x) and tonumber(bounds.y) then
    return { x = bounds.x, y = bounds.y, w = 108, h = 117 }
  end
  return nil
end

local function targetFromBounds(bounds)
  if type(bounds) ~= "table" then return nil end
  local activeBounds = activeBoundsRecord(bounds)
  local display = activeBounds.displayBounds or bounds.displayBounds
  if type(display) ~= "table" or not tonumber(display.width) or not tonumber(display.height) then return nil end
  local geometry = petGeometryForBounds(activeBounds)
  if not geometry then return nil end
  local localX = geometry.x - (display.x or 0)
  local localY = geometry.y - (display.y or 0)
  if localX + geometry.w < -16 or localY + geometry.h < -16
    or localX > display.width + 16 or localY > display.height + 16 then
    return nil
  end

  local screen = matchingScreenFrame(display, activeBounds.displayId or bounds.displayId)
  if not screen then return nil end
  local scaleX = screen.w / display.width
  local scaleY = screen.h / display.height

  return {
    screen = screen,
    pet = {
      x = screen.x + localX * scaleX,
      y = screen.y + localY * scaleY,
      w = geometry.w * scaleX,
      h = geometry.h * scaleY,
    },
  }
end

local hoverStartedAt = nil
local visibleCardFrame = nil
local hoverCardDelaySeconds = 3
local startupHideUntil = 0

local function ringFrameForPet(target)
  local pet = target.pet
  local diameter = math.max(pet.w, pet.h) + 28
  return {
    x = pet.x + pet.w / 2 - diameter / 2,
    y = pet.y + pet.h / 2 - diameter / 2,
    w = diameter,
    h = diameter,
  }
end

local function cardFrameForPet(target)
  local panelW, panelH, gap = 332, 122, 12
  local screen = target.screen
  local pet = target.pet
  local x = pet.x + pet.w / 2 - panelW / 2
  local y = pet.y - panelH - gap
  if y < screen.y + 8 then y = pet.y + pet.h + gap end

  return {
    x = clamp(x, screen.x + 8, screen.x + screen.w - panelW - 8),
    y = clamp(y, screen.y + 8, screen.y + screen.h - panelH - 8),
    w = panelW,
    h = panelH,
  }
end

local function mouseIsOverPet(target)
  local cursor = mouseModule.absolutePosition()
  local pet = target.pet
  local padding = 8
  if cursor.x >= pet.x - padding and cursor.x <= pet.x + pet.w + padding
    and cursor.y >= pet.y - padding and cursor.y <= pet.y + pet.h + padding then
    return pet
  end
  return nil
end

local function mouseIsInInteractionRegion(target)
  -- The card is an informational tooltip, not a separate hover target.
  -- Restricting this to the pet avoids a stale card being held open by the
  -- large rectangle between the pet and card after Codex restores its state.
  local pet = mouseIsOverPet(target)
  return pet ~= nil, pet
end

local function makeRingElements(usage, diameter)
  local center = { x = diameter / 2, y = diameter / 2 }
  local elements = {}
  local remainderColor = { red = 0.22, green = 0.27, blue = 0.31, alpha = 0.62 }

  local function segment(radius, startAngle, endAngle, color)
    return {
      type = "arc", action = "stroke", center = center, radius = radius,
      startAngle = startAngle, endAngle = endAngle,
      arcRadii = false, arcClockwise = true, strokeWidth = 7,
      strokeCapStyle = "butt", strokeColor = color,
    }
  end

  local function addRing(radius, percent, color)
    local value = clamp(percent or 0, 0, 100)
    local progressEnd = -90 + 360 * value / 100
    if value > 0 then
      table.insert(elements, segment(radius, -90, progressEnd, color))
    end
    if value < 100 then
      table.insert(elements, segment(radius, progressEnd, 270, remainderColor))
    end
  end

  addRing(diameter / 2 - 10, usage.primaryRemaining, { red = 0.28, green = 1, blue = 0.72, alpha = 0.98 })
  if usage.secondaryRemaining ~= nil then
    addRing(diameter / 2 - 21, usage.secondaryRemaining, { red = 0.22, green = 0.58, blue = 1, alpha = 0.98 })
  end
  return elements
end

local function windowLabel(seconds, fallback)
  local value = tonumber(seconds)
  if not value or value <= 0 then return fallback end
  if value >= 6 * 86400 then return "7天" end
  if value >= 86400 then return string.format("%d天", math.floor(value / 86400 + 0.5)) end
  if value >= 3600 then return string.format("%d小时", math.floor(value / 3600 + 0.5)) end
  return string.format("%d分钟", math.max(1, math.floor(value / 60 + 0.5)))
end

local function addUsageBar(elements, label, percent, resetAt, y, color)
  local p = percent or 0
  local text = percent and string.format("%s 剩余 %.0f%% · %s后刷新", label, p, formatDuration(resetAt)) or (label .. " 用量暂不可用")
  table.insert(elements, { type = "text", text = text, textSize = 13, textColor = { red = 0.93, green = 0.97, blue = 0.98, alpha = 1 }, frame = { x = 18, y = y, w = 296, h = 20 } })
  table.insert(elements, { type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 4, yRadius = 4 }, fillColor = { red = 1, green = 1, blue = 1, alpha = 0.13 }, frame = { x = 18, y = y + 23, w = 296, h = 7 } })
  table.insert(elements, { type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 4, yRadius = 4 }, fillColor = color, frame = { x = 18, y = y + 23, w = math.max(4, 296 * p / 100), h = 7 } })
end

local function makeCardElements(usage)
  local source = usage.available and (usage.source .. " · " .. os.date("%H:%M", usage.observedAt)) or "等待用量数据"
  local elements = {
    { type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 14, yRadius = 14 }, fillColor = { red = 0.02, green = 0.03, blue = 0.04, alpha = 0.95 } },
    { type = "rectangle", action = "stroke", roundedRectRadii = { xRadius = 14, yRadius = 14 }, strokeWidth = 1.5, strokeColor = { red = 0.35, green = 1, blue = 0.76, alpha = 0.72 } },
    { type = "text", text = "Codex /pet 用量", textSize = 17, textColor = { red = 1, green = 1, blue = 1, alpha = 1 }, frame = { x = 18, y = 10, w = 190, h = 24 } },
    { type = "text", text = source, textSize = 11, textAlignment = "right", textColor = { red = 0.72, green = 0.82, blue = 0.86, alpha = 0.95 }, frame = { x = 160, y = 13, w = 154, h = 18 } },
  }
  addUsageBar(elements, windowLabel(usage.primaryWindowSeconds, "5小时"), usage.primaryRemaining, usage.primaryResetAt, 38, { red = 0.28, green = 1, blue = 0.72, alpha = 0.95 })
  if usage.secondaryRemaining ~= nil then
    addUsageBar(elements, windowLabel(usage.secondaryWindowSeconds, "7天"), usage.secondaryRemaining, usage.secondaryResetAt, 76, { red = 0.22, green = 0.58, blue = 1, alpha = 0.95 })
  else
    table.insert(elements, { type = "text", text = "当前账户仅返回一个用量窗口", textSize = 11, textColor = { red = 0.72, green = 0.82, blue = 0.86, alpha = 0.9 }, frame = { x = 18, y = 80, w = 296, h = 18 } })
  end
  return elements
end

local function frameSignature(frame)
  return string.format("%.0f,%.0f,%.0f,%.0f", frame.x, frame.y, frame.w, frame.h)
end

local function usageSignature(usage)
  return table.concat({
    tostring(usage.available),
    tostring(usage.source),
    tostring(usage.observedAt),
    tostring(usage.primaryRemaining),
    tostring(usage.secondaryRemaining),
    tostring(usage.primaryResetAt),
    tostring(usage.secondaryResetAt),
    tostring(usage.primaryWindowSeconds),
    tostring(usage.secondaryWindowSeconds),
  }, ":")
end

local function setCanvas(index, frame, elements, signature)
  local state = canvasStates[index]
  if state and state.visible and state.signature == signature then return end

  canvases[index] = canvases[index] or canvasModule.new(frame)
  canvases[index]:frame(frame)
  canvases[index]:replaceElements(elements)
  canvases[index]:level(hs.canvas.windowLevels.screenSaver or hs.canvas.windowLevels.overlay)
  canvases[index]:behavior({ "canJoinAllSpaces", "stationary" })
  canvases[index]:show()
  canvasStates[index] = { visible = true, signature = signature }
end

local function hideCanvas(index)
  local state = canvasStates[index]
  if canvases[index] and state and state.visible then canvases[index]:hide() end
  if state then state.visible = false end
end

local function hideAll()
  for index in pairs(canvases) do hideCanvas(index) end
end

local function discardCanvases()
  for _, canvas in pairs(canvases) do
    pcall(function() canvas:delete() end)
  end
  canvases = {}
  canvasStates = {}
  rawset(_G, canvasRegistryKey, canvases)
end

local function terminateLegacyOverlays()
  for _, bundleId in ipairs({
    "dev.jimmyasksai.codex-pet-usage-overlay",
    "dev.jimmyasksai.CodexPetUsageOverlay2",
  }) do
    for _, app in ipairs(hs.application.applicationsForBundleID(bundleId) or {}) do
      pcall(function() app:terminate() end)
    end
  end
  hs.execute("/usr/bin/pkill -x codex-pet-usage-overlay-mac >/dev/null 2>&1 || true", true)
  hs.execute("/usr/bin/pkill -x CodexPetUsageOverlay >/dev/null 2>&1 || true", true)
end

local function update()
  if hs.timer.secondsSinceEpoch() < startupHideUntil then
    hideAll()
    return
  end

  local state = cachedState
  if not isCodexRunning() or not state or not state["electron-avatar-overlay-open"] then
    hoverStartedAt = nil
    visibleCardFrame = nil
    hideAll()
    return
  end

  local target = targetFromBounds(state["electron-avatar-overlay-bounds"])
  if not target then
    hoverStartedAt = nil
    visibleCardFrame = nil
    hideAll()
    return
  end

  local interacting, hoveredPet = mouseIsInInteractionRegion(target)
  if not interacting then
    hoverStartedAt = nil
    visibleCardFrame = nil
    hideAll()
    return
  end

  target.pet = hoveredPet
  local now = hs.timer.secondsSinceEpoch()
  if hoveredPet and not hoverStartedAt then hoverStartedAt = now end
  local usage = currentUsage
  refreshUsageLater()

  if hoverStartedAt and now - hoverStartedAt >= hoverCardDelaySeconds then
    local cardFrame = cardFrameForPet(target)
    visibleCardFrame = cardFrame
    hideCanvas(1)
    setCanvas(2, cardFrame, makeCardElements(usage), "card:" .. frameSignature(cardFrame) .. ":" .. usageSignature(usage))
  else
    visibleCardFrame = nil
    local ringFrame = ringFrameForPet(target)
    setCanvas(1, ringFrame, makeRingElements(usage, ringFrame.w), "ring:" .. frameSignature(ringFrame) .. ":" .. usageSignature(usage))
    hideCanvas(2)
  end
end

wakeUpdate = function()
  if wakeTimer then return end
  wakeTimer = hs.timer.doAfter(0.01, function()
    wakeTimer = nil
    update()
  end)
end

function M.start()
  if timer then timer:stop() end
  if screenWatcher then screenWatcher:stop() end
  if stateWatcher then stateWatcher:stop() end
  if mouseWatcher then mouseWatcher:stop() end
  if wakeTimer then wakeTimer:stop(); wakeTimer = nil end
  terminateLegacyOverlays()
  hideAll()
  hoverStartedAt = nil
  visibleCardFrame = nil
  startupHideUntil = hs.timer.secondsSinceEpoch() + 0.2
  refreshCachedState()
  screenWatcher = hs.screen.watcher.new(function()
    -- Canvas windows can become orphaned when macOS rearranges displays.
    -- Recreate them lazily against the new screen geometry on the next tick.
    hoverStartedAt = nil
    visibleCardFrame = nil
    discardCanvases()
  end)
  screenWatcher:start()
  stateWatcher = hs.pathwatcher.new(statePath, function()
    refreshCachedState()
    wakeUpdate()
  end)
  stateWatcher:start()
  mouseWatcher = hs.eventtap.new({ hs.eventtap.event.types.mouseMoved }, function()
    wakeUpdate()
    return false
  end)
  mouseWatcher:start()
  readUsage(true)
  timer = hs.timer.doEvery(idlePollSeconds, update)
  update()
  hs.alert.show("Codex /pet 悬停圆环已启动", 2)
end

function M.stop()
  if timer then timer:stop(); timer = nil end
  if screenWatcher then screenWatcher:stop(); screenWatcher = nil end
  if stateWatcher then stateWatcher:stop(); stateWatcher = nil end
  if mouseWatcher then mouseWatcher:stop(); mouseWatcher = nil end
  if wakeTimer then wakeTimer:stop(); wakeTimer = nil end
  cachedState = nil
  codexRunning = false
  lastCodexCheckAt = 0
  hoverStartedAt = nil
  visibleCardFrame = nil
  startupHideUntil = 0
  hideAll()
  discardCanvases()
  if rawget(_G, moduleRegistryKey) == M then rawset(_G, moduleRegistryKey, nil) end
end

M.start()

return M
