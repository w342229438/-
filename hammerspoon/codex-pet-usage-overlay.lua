local M = {}

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
local currentUsage = { available = false, source = "none", observedAt = os.time() }
local lastUsageRead = 0
local usageRefreshTimer = nil
local cachedState = nil
local hasCachedState = false
local lastStateReadAt = 0

local idlePollSeconds = 0.25
local activePollSeconds = 0.1
local idleStateReadSeconds = 0.5
local activeStateReadSeconds = 0.25

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

local function readCachedState(active)
  local now = hs.timer.secondsSinceEpoch()
  local interval = active and activeStateReadSeconds or idleStateReadSeconds
  if hasCachedState and now - lastStateReadAt < interval then
    return cachedState
  end

  cachedState = readState()
  hasCachedState = true
  lastStateReadAt = now
  return cachedState
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
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
  }
end

local function readLiveUsage()
  local authBody = readFile(home .. "/.codex/auth.json")
  if not authBody then return nil end

  local authOk, auth = pcall(hs.json.decode, authBody)
  local token = authOk and type(auth) == "table" and type(auth.tokens) == "table" and auth.tokens.access_token
  if type(token) ~= "string" or token == "" then return nil end

  local cmd = "/usr/bin/curl --silent --show-error --fail --max-time 15 -H "
    .. shellQuote("Authorization: Bearer " .. token)
    .. " -H " .. shellQuote("Accept: application/json")
    .. " " .. shellQuote("https://chatgpt.com/backend-api/wham/usage")
  local output, ok = hs.execute(cmd, true)
  if not ok or not output or output == "" then return nil end

  local decodedOk, payload = pcall(hs.json.decode, output)
  if not decodedOk or type(payload) ~= "table" then return nil end

  local usage = convertUsage(payload)
  if usage then usage.source = "实时" end
  return usage
end

local function readUsage(force)
  local now = os.time()
  if not force and now - lastUsageRead < 30 then
    return currentUsage
  end

  lastUsageRead = now
  local live = readLiveUsage()
  if live then
    currentUsage = live
    return currentUsage
  end

  local query = "SELECT feedback_log_body FROM logs WHERE feedback_log_body LIKE '%codex.rate_limits%' ORDER BY ts DESC, ts_nanos DESC, id DESC LIMIT 25;"

  for _, path in ipairs(logPaths) do
    if fileExists(path) then
      local cmd = "/usr/bin/sqlite3 -json " .. shellQuote(path) .. " " .. shellQuote(query)
      local output, ok = hs.execute(cmd, true)
      if ok and output and output ~= "" then
        local decodedOk, rows = pcall(hs.json.decode, output)
        if decodedOk and type(rows) == "table" then
          for _, row in ipairs(rows) do
            local payload = payloadFromLogBody(row.feedback_log_body)
            local usage = convertUsage(payload)
            if usage then
              currentUsage = usage
              return currentUsage
            end
          end
        end
      end
    end
  end

  if not currentUsage.available then
    currentUsage = { available = false, source = "none", observedAt = now }
  end
  return currentUsage
end

local function refreshUsageLater()
  if usageRefreshTimer or os.time() - lastUsageRead < 30 then return end

  usageRefreshTimer = hs.timer.doAfter(0.25, function()
    usageRefreshTimer = nil
    readUsage(false)
  end)
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

local function matchingScreenFrame(display)
  if not display then return nil end
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

local function makeRingElements(usage, diameter)
  local center = { x = diameter / 2, y = diameter / 2 }
  local primary = usage.primaryRemaining or 0
  local secondary = usage.secondaryRemaining or 0

  local function arc(radius, percent, color)
    return {
      type = "arc",
      action = "stroke",
      center = center,
      radius = radius,
      startAngle = -90,
      endAngle = -90 + 360 * percent / 100,
      arcRadii = false,
      arcClockwise = true,
      strokeWidth = 7,
      strokeCapStyle = "round",
      strokeColor = color,
    }
  end

  return {
    {
      type = "circle",
      action = "stroke",
      center = center,
      radius = diameter / 2 - 5,
      strokeWidth = 2,
      strokeColor = { red = 0.12, green = 0.16, blue = 0.20, alpha = 0.58 },
    },
    {
      type = "circle",
      action = "stroke",
      center = center,
      radius = diameter / 2 - 10,
      strokeWidth = 7,
      strokeColor = { red = 0.22, green = 0.27, blue = 0.31, alpha = 0.62 },
    },
    arc(diameter / 2 - 10, primary, { red = 0.28, green = 1, blue = 0.72, alpha = 0.98 }),
    {
      type = "circle",
      action = "stroke",
      center = center,
      radius = diameter / 2 - 21,
      strokeWidth = 7,
      strokeColor = { red = 0.22, green = 0.27, blue = 0.31, alpha = 0.62 },
    },
    arc(diameter / 2 - 21, secondary, { red = 0.22, green = 0.58, blue = 1, alpha = 0.98 }),
  }
end

local function targetFromBounds(bounds)
  if type(bounds) ~= "table" or type(bounds.mascot) ~= "table" then return nil end

  local mascot = bounds.mascot
  local display = bounds.displayBounds or { x = 0, y = 0, width = 1280, height = 720 }
  local screen = matchingScreenFrame(display)
  local petX = (bounds.x or 0) + (mascot.left or 0)
  local petY = (bounds.y or 0) + (mascot.top or 0)
  local localX = petX - (display.x or 0)
  local localY = petY - (display.y or 0)

  return {
    screen = screen,
    pet = {
      x = screen.x + localX,
      y = screen.y + localY,
      w = mascot.width or 108,
      h = mascot.height or 117,
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
  local cursor = hs.mouse.absolutePosition()
  local pet = target.pet
  local padding = 4
  return cursor.x >= pet.x - padding and cursor.x <= pet.x + pet.w + padding
    and cursor.y >= pet.y - padding and cursor.y <= pet.y + pet.h + padding
end

local function mouseIsInInteractionRegion(target)
  -- The card is an informational tooltip, not a separate hover target.
  -- Restricting this to the pet avoids a stale card being held open by the
  -- large rectangle between the pet and card after Codex restores its state.
  local overPet = mouseIsOverPet(target)
  return overPet, overPet
end

local function makeRingElements(usage, diameter)
  local center = { x = diameter / 2, y = diameter / 2 }
  local primary = usage.primaryRemaining or 0
  local secondary = usage.secondaryRemaining or 0

  local function arc(radius, percent, color)
    return {
      type = "arc", action = "stroke", center = center, radius = radius,
      startAngle = -90, endAngle = -90 + 360 * percent / 100,
      arcRadii = false, arcClockwise = true, strokeWidth = 7,
      strokeCapStyle = "round", strokeColor = color,
    }
  end

  return {
    { type = "circle", action = "stroke", center = center, radius = diameter / 2 - 5, strokeWidth = 2, strokeColor = { red = 0.12, green = 0.16, blue = 0.20, alpha = 0.58 } },
    { type = "circle", action = "stroke", center = center, radius = diameter / 2 - 10, strokeWidth = 7, strokeColor = { red = 0.22, green = 0.27, blue = 0.31, alpha = 0.62 } },
    arc(diameter / 2 - 10, primary, { red = 0.28, green = 1, blue = 0.72, alpha = 0.98 }),
    { type = "circle", action = "stroke", center = center, radius = diameter / 2 - 21, strokeWidth = 7, strokeColor = { red = 0.22, green = 0.27, blue = 0.31, alpha = 0.62 } },
    arc(diameter / 2 - 21, secondary, { red = 0.22, green = 0.58, blue = 1, alpha = 0.98 }),
  }
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
  addUsageBar(elements, "5小时", usage.primaryRemaining, usage.primaryResetAt, 38, { red = 0.28, green = 1, blue = 0.72, alpha = 0.95 })
  addUsageBar(elements, "7天", usage.secondaryRemaining, usage.secondaryResetAt, 76, { red = 0.22, green = 0.58, blue = 1, alpha = 0.95 })
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
  }, ":")
end

local function setCanvas(index, frame, elements, signature)
  local state = canvasStates[index]
  if state and state.visible and state.signature == signature then return end

  canvases[index] = canvases[index] or hs.canvas.new(frame)
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
end

local function update()
  if hs.timer.secondsSinceEpoch() < startupHideUntil then
    hideAll()
    return idlePollSeconds
  end

  local active = hoverStartedAt ~= nil or visibleCardFrame ~= nil
  local state = readCachedState(active)
  if not state or not state["electron-avatar-overlay-open"] then
    hoverStartedAt = nil
    visibleCardFrame = nil
    hideAll()
    return idlePollSeconds
  end

  local target = targetFromBounds(state["electron-avatar-overlay-bounds"])
  if not target then
    hoverStartedAt = nil
    visibleCardFrame = nil
    hideAll()
    return idlePollSeconds
  end

  local interacting, overPet = mouseIsInInteractionRegion(target)
  if not interacting then
    hoverStartedAt = nil
    visibleCardFrame = nil
    hideAll()
    return idlePollSeconds
  end

  if overPet and not hoverStartedAt then hoverStartedAt = os.time() end
  local usage = currentUsage
  refreshUsageLater()

  if hoverStartedAt and os.time() - hoverStartedAt >= hoverCardDelaySeconds then
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

  return activePollSeconds
end

local function scheduleUpdate(delay)
  if timer then timer:stop() end
  timer = hs.timer.doAfter(delay, function()
    timer = nil
    scheduleUpdate(update())
  end)
end

function M.start()
  if timer then timer:stop() end
  if screenWatcher then screenWatcher:stop() end
  hideAll()
  hoverStartedAt = nil
  visibleCardFrame = nil
  startupHideUntil = hs.timer.secondsSinceEpoch() + 0.5
  screenWatcher = hs.screen.watcher.new(function()
    -- Canvas windows can become orphaned when macOS rearranges displays.
    -- Recreate them lazily against the new screen geometry on the next tick.
    hoverStartedAt = nil
    visibleCardFrame = nil
    discardCanvases()
  end)
  screenWatcher:start()
  readUsage(true)
  scheduleUpdate(update())
  hs.alert.show("Codex /pet 悬停圆环已启动", 2)
end

function M.stop()
  if timer then timer:stop(); timer = nil end
  if usageRefreshTimer then usageRefreshTimer:stop(); usageRefreshTimer = nil end
  if screenWatcher then screenWatcher:stop(); screenWatcher = nil end
  cachedState = nil
  hasCachedState = false
  lastStateReadAt = 0
  hoverStartedAt = nil
  visibleCardFrame = nil
  startupHideUntil = 0
  hideAll()
  discardCanvases()
end

M.start()

return M
