param(
  [ValidateSet("Start", "Stop", "Status", "SelfTest", "InstallStartup", "UninstallStartup", "Run")]
  [string]$Command = "Start",
  [int]$UsagePollSeconds = 30,
  [int]$PetPollMs = 100,
  [int]$HoverPaddingPx = 24,
  [string]$CodexHome = "$env:USERPROFILE\.codex"
)

$ErrorActionPreference = "Stop"
$UsagePollSeconds = [Math]::Max(10, $UsagePollSeconds)
$PetPollMs = [Math]::Max(50, $PetPollMs)
$HoverPaddingPx = [Math]::Max(0, [Math]::Min(200, $HoverPaddingPx))
$AppName = "CodexPetUsageOverlay"
$AppDir = Join-Path $env:LOCALAPPDATA $AppName
$PidPath = Join-Path $AppDir "overlay.pid"
$LogPath = Join-Path $AppDir "overlay.log"
$HoverShowSeconds = 10
$StartupShortcutName = "Codex pet usage overlay.lnk"

function U {
  param([string]$Text)
  return [regex]::Replace($Text, "\\u([0-9a-fA-F]{4})", {
    param($Match)
    return [string][char]([Convert]::ToInt32($Match.Groups[1].Value, 16))
  })
}

function Ensure-AppDir {
  New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
}

function Write-AppLog {
  param([string]$Message)
  try {
    Ensure-AppDir
    $line = "{0:s} {1}" -f (Get-Date), $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
  } catch {
  }
}

function Get-OverlayProcessFromPid {
  param([int]$ProcessId)
  if ($ProcessId -le 0) { return $null }
  try {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId"
    if ($null -eq $process) { return $null }
    $scriptPath = [System.IO.Path]::GetFullPath($PSCommandPath)
    $commandLine = [string]$process.CommandLine
    if (
      $commandLine.IndexOf($scriptPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
      $commandLine.IndexOf("-File", [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
      $commandLine.IndexOf("-Command Run", [StringComparison]::OrdinalIgnoreCase) -ge 0
    ) {
      return $process
    }
  } catch {
  }
  return $null
}

function Get-AllOverlayProcesses {
  try {
    $scriptPath = [System.IO.Path]::GetFullPath($PSCommandPath)
    return @(Get-CimInstance Win32_Process | Where-Object {
      $commandLine = [string]$_.CommandLine
      $commandLine.IndexOf($scriptPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
      $commandLine.IndexOf("-File", [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
      $commandLine.IndexOf("-Command Run", [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
  } catch {
    return @()
  }
}

function Get-RunningOverlayProcess {
  if (-not (Test-Path -LiteralPath $PidPath)) {
    return @(Get-AllOverlayProcesses | Select-Object -First 1)[0]
  }
  try {
    $pidText = (Get-Content -LiteralPath $PidPath -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($pidText)) { return $null }
    $process = Get-OverlayProcessFromPid -ProcessId ([int]$pidText)
    if ($null -ne $process) { return $process }
  } catch {
  }
  return @(Get-AllOverlayProcesses | Select-Object -First 1)[0]
}

function Get-StartupShortcutPath {
  $startupDir = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
  return Join-Path $startupDir $StartupShortcutName
}

function Install-StartupShortcut {
  # ponytail: per-user Startup shortcut is enough; use Task Scheduler only if delayed/elevated startup is needed.
  $scriptPath = [System.IO.Path]::GetFullPath($PSCommandPath)
  $scriptDir = Split-Path -Parent $scriptPath
  $powerShellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
  $shortcutPath = Get-StartupShortcutPath
  $quotedScript = '"' + ($scriptPath -replace '"', '\"') + '"'
  $quotedCodexHome = '"' + ([System.IO.Path]::GetFullPath($CodexHome) -replace '"', '\"') + '"'

  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($shortcutPath)
  $shortcut.TargetPath = $powerShellPath
  $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $quotedScript -Command Start -UsagePollSeconds $UsagePollSeconds -PetPollMs $PetPollMs -HoverPaddingPx $HoverPaddingPx -CodexHome $quotedCodexHome"
  $shortcut.WorkingDirectory = $scriptDir
  $shortcut.WindowStyle = 7
  $shortcut.Description = "Start Codex pet usage overlay"
  $shortcut.Save()

  Write-Output ("Installed startup shortcut: {0}" -f $shortcutPath)
}

function Uninstall-StartupShortcut {
  $shortcutPath = Get-StartupShortcutPath
  if (Test-Path -LiteralPath $shortcutPath) {
    Remove-Item -LiteralPath $shortcutPath -Force
    Write-Output ("Removed startup shortcut: {0}" -f $shortcutPath)
    return
  }
  Write-Output ("Startup shortcut not found: {0}" -f $shortcutPath)
}

function Start-Overlay {
  Ensure-AppDir
  $running = Get-RunningOverlayProcess
  if ($null -ne $running) {
    Write-Output ("Already running. PID: {0}" -f $running.ProcessId)
    return
  }

  $scriptPath = [System.IO.Path]::GetFullPath($PSCommandPath)
  $quotedScript = '"' + ($scriptPath -replace '"', '\"') + '"'
  $quotedCodexHome = '"' + ([System.IO.Path]::GetFullPath($CodexHome) -replace '"', '\"') + '"'
  $args = "-NoProfile -ExecutionPolicy Bypass -File $quotedScript -Command Run -UsagePollSeconds $UsagePollSeconds -PetPollMs $PetPollMs -HoverPaddingPx $HoverPaddingPx -CodexHome $quotedCodexHome"
  $process = Start-Process -FilePath "powershell.exe" -ArgumentList $args -WindowStyle Hidden -PassThru
  Set-Content -LiteralPath $PidPath -Value $process.Id -Encoding ASCII
  Write-Output ("Started Codex pet usage overlay. PID: {0}" -f $process.Id)
}

function Stop-Overlay {
  $running = @(Get-AllOverlayProcesses)
  if ($running.Count -eq 0) {
    if (Test-Path -LiteralPath $PidPath) { Remove-Item -LiteralPath $PidPath -Force }
    Write-Output "Codex pet usage overlay is not running."
    return
  }
  foreach ($process in $running) {
    Stop-Process -Id ([int]$process.ProcessId) -Force
    Write-Output ("Stopped Codex pet usage overlay. PID: {0}" -f $process.ProcessId)
  }
  if (Test-Path -LiteralPath $PidPath) { Remove-Item -LiteralPath $PidPath -Force }
}

function Read-CodexState {
  $statePath = Join-Path $CodexHome ".codex-global-state.json"
  if (-not (Test-Path -LiteralPath $statePath)) { return $null }
  try {
    return Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    Write-AppLog "State read failed: $($_.Exception.Message)"
    return $null
  }
}

function Get-PetRect {
  $state = Read-CodexState
  if ($null -eq $state) { return $null }
  $open = $state.'electron-avatar-overlay-open'
  $bounds = $state.'electron-avatar-overlay-bounds'
  if (-not $open -or $null -eq $bounds -or $null -eq $bounds.mascot) { return $null }
  return [PSCustomObject]@{
    Left = [double]$bounds.x + [double]$bounds.mascot.left
    Top = [double]$bounds.y + [double]$bounds.mascot.top
    Width = [double]$bounds.mascot.width
    Height = [double]$bounds.mascot.height
    DisplayLeft = if ($bounds.displayBounds) { [double]$bounds.displayBounds.x } else { 0.0 }
    DisplayTop = if ($bounds.displayBounds) { [double]$bounds.displayBounds.y } else { 0.0 }
    DisplayWidth = if ($bounds.displayBounds) { [double]$bounds.displayBounds.width } else { 1920.0 }
    DisplayHeight = if ($bounds.displayBounds) { [double]$bounds.displayBounds.height } else { 1080.0 }
  }
}

function Test-PointInRect {
  param($Point, $Rect, [int]$Padding = 0)
  if ($null -eq $Point -or $null -eq $Rect) { return $false }
  return (
    [double]$Point.X -ge ([double]$Rect.Left - $Padding) -and
    [double]$Point.X -le ([double]$Rect.Left + [double]$Rect.Width + $Padding) -and
    [double]$Point.Y -ge ([double]$Rect.Top - $Padding) -and
    [double]$Point.Y -le ([double]$Rect.Top + [double]$Rect.Height + $Padding)
  )
}

function Get-OverlayShowUntil {
  param([bool]$CursorInPet, [bool]$CursorWasInPet, [datetime]$CurrentShowUntil, [datetime]$Now, [int]$Seconds)
  if ($CursorInPet -and -not $CursorWasInPet -and $Now -gt $CurrentShowUntil) { return $Now.AddSeconds($Seconds) }
  return $CurrentShowUntil
}

function Test-ShouldShowOverlay {
  param([datetime]$ShowUntilAt, [datetime]$Now)
  return ($ShowUntilAt -ne [datetime]::MinValue -and $Now -le $ShowUntilAt)
}

function Convert-DevicePointToDip {
  param($Window, $Point)
  if ($null -eq $Point) { return $null }
  try {
    $devicePoint = New-Object System.Windows.Point -ArgumentList ([double]$Point.X), ([double]$Point.Y)
    $source = [System.Windows.PresentationSource]::FromVisual($Window)
    if ($source -and $source.CompositionTarget) {
      $dipPoint = $source.CompositionTarget.TransformFromDevice.Transform($devicePoint)
      return [PSCustomObject]@{ X = [double]$dipPoint.X; Y = [double]$dipPoint.Y; DeviceX = [double]$Point.X; DeviceY = [double]$Point.Y }
    }
    $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($Window)
    if ($dpi.DpiScaleX -gt 0 -and $dpi.DpiScaleY -gt 0) {
      return [PSCustomObject]@{ X = [double]$Point.X / [double]$dpi.DpiScaleX; Y = [double]$Point.Y / [double]$dpi.DpiScaleY; DeviceX = [double]$Point.X; DeviceY = [double]$Point.Y }
    }
  } catch {
  }
  return [PSCustomObject]@{ X = [double]$Point.X; Y = [double]$Point.Y; DeviceX = [double]$Point.X; DeviceY = [double]$Point.Y }
}

function Clamp-Percent {
  param($Value)
  if ($null -eq $Value) { return $null }
  return [Math]::Max(0.0, [Math]::Min(100.0, [double]$Value))
}

function Get-BucketRemaining {
  param($Bucket)
  if ($null -eq $Bucket) { return $null }
  if ($null -ne $Bucket.remaining_percent) { return Clamp-Percent $Bucket.remaining_percent }
  if ($null -ne $Bucket.used_percent) { return Clamp-Percent (100.0 - [double]$Bucket.used_percent) }
  return $null
}

function Get-BucketWindowSeconds {
  param($Bucket)
  if ($null -eq $Bucket) { return $null }
  if ($null -ne $Bucket.limit_window_seconds) { return [double]$Bucket.limit_window_seconds }
  if ($null -ne $Bucket.window_seconds) { return [double]$Bucket.window_seconds }
  return $null
}

function Convert-ResetAt {
  param($Bucket)
  if ($null -eq $Bucket) { return $null }
  if ($null -ne $Bucket.reset_after_seconds) {
    return (Get-Date).AddSeconds([double]$Bucket.reset_after_seconds)
  }
  if ($null -ne $Bucket.seconds_until_reset) {
    return (Get-Date).AddSeconds([double]$Bucket.seconds_until_reset)
  }
  foreach ($name in @("reset_at", "resets_at", "reset_time", "expires_at", "window_reset_at")) {
    $value = $Bucket.$name
    if ($null -eq $value) { continue }
    try {
      if ($value -is [int] -or $value -is [long] -or $value -is [double] -or "$value" -match "^\d+(\.\d+)?$") {
        return [DateTimeOffset]::FromUnixTimeSeconds([int64][double]$value).LocalDateTime
      }
      return ([datetime]::Parse([string]$value)).ToLocalTime()
    } catch {
    }
  }
  return $null
}

function Convert-UsagePayload {
  param($Payload, [string]$Source)
  if ($null -eq $Payload) { return $null }
  $rate = if ($Payload.rate_limit) { $Payload.rate_limit } elseif ($Payload.rate_limits) { $Payload.rate_limits } else { $null }
  if ($null -eq $rate) { return $null }
  $primary = if ($rate.primary_window) { $rate.primary_window } elseif ($rate.primary) { $rate.primary } else { $null }
  $secondary = if ($rate.secondary_window) { $rate.secondary_window } elseif ($rate.secondary) { $rate.secondary } else { $null }
  $primaryRemaining = Get-BucketRemaining $primary
  $secondaryRemaining = Get-BucketRemaining $secondary
  if ($null -eq $primaryRemaining -and $null -eq $secondaryRemaining) { return $null }
  return [PSCustomObject]@{
    Available = $true
    Source = $Source
    PrimaryRemaining = $primaryRemaining
    SecondaryRemaining = $secondaryRemaining
    PrimaryResetAt = Convert-ResetAt $primary
    SecondaryResetAt = Convert-ResetAt $secondary
    PrimaryWindowSeconds = Get-BucketWindowSeconds $primary
    SecondaryWindowSeconds = Get-BucketWindowSeconds $secondary
    ObservedAt = Get-Date
  }
}

function Get-LiveUsage {
  $authPath = Join-Path $CodexHome "auth.json"
  if (-not (Test-Path -LiteralPath $authPath)) { return $null }
  $auth = Get-Content -LiteralPath $authPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $token = $auth.tokens.access_token
  if ([string]::IsNullOrWhiteSpace($token)) { return $null }
  $payload = Invoke-RestMethod -Uri "https://chatgpt.com/backend-api/wham/usage" -Headers @{
    Authorization = "Bearer $token"
    Accept = "application/json"
  } -TimeoutSec 5
  return Convert-UsagePayload -Payload $payload -Source "live"
}

function Get-BalancedJsonObject {
  param([string]$Text, [int]$Start)
  $depth = 0
  $inString = $false
  $escaping = $false
  for ($i = $Start; $i -lt $Text.Length; $i++) {
    $ch = $Text[$i]
    if ($inString) {
      if ($escaping) {
        $escaping = $false
      } elseif ($ch -eq "\") {
        $escaping = $true
      } elseif ($ch -eq '"') {
        $inString = $false
      }
      continue
    }
    if ($ch -eq '"') {
      $inString = $true
    } elseif ($ch -eq "{") {
      $depth++
    } elseif ($ch -eq "}") {
      $depth--
      if ($depth -eq 0) { return $Text.Substring($Start, $i - $Start + 1) }
    }
  }
  return $null
}

function Convert-LogBodyToUsage {
  param([string]$Body)
  if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
  $marker = "codex.rate_limits"
  $markerIndex = $Body.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase)
  while ($markerIndex -ge 0) {
    $start = $Body.LastIndexOf("{", $markerIndex)
    while ($start -ge 0) {
      $json = Get-BalancedJsonObject -Text $Body -Start $start
      if ($json -and $json.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        try {
          $payload = $json | ConvertFrom-Json
          if ($payload.type -eq $marker -or $payload.rate_limit -or $payload.rate_limits) {
            $usage = Convert-UsagePayload -Payload $payload -Source "log"
            if ($null -ne $usage) { return $usage }
          }
        } catch {
        }
      }
      if ($start -eq 0) { break }
      $start = $Body.LastIndexOf("{", $start - 1)
    }
    $nextFrom = $markerIndex + $marker.Length
    if ($nextFrom -ge $Body.Length) { break }
    $markerIndex = $Body.IndexOf($marker, $nextFrom, [StringComparison]::OrdinalIgnoreCase)
  }
  return $null
}

function Get-LogUsage {
  param([string[]]$LogPaths)
  if ($null -eq $LogPaths -or $LogPaths.Count -eq 0) {
    $LogPaths = @(
      (Join-Path $CodexHome "logs_2.sqlite"),
      (Join-Path $CodexHome "logs_1.sqlite")
    )
  }
  $existing = @($LogPaths | Where-Object { Test-Path -LiteralPath $_ })
  if ($existing.Count -eq 0) { return $null }
  $python = Get-Command python -ErrorAction SilentlyContinue
  if ($null -eq $python) { return $null }

  $code = @'
import base64
import sqlite3
import sys

for path in sys.argv[1:]:
    try:
        con = sqlite3.connect("file:" + path + "?mode=ro", uri=True)
        try:
            row = con.execute(
                """
                SELECT feedback_log_body
                FROM logs
                WHERE feedback_log_body LIKE '%codex.rate_limits%'
                ORDER BY ts DESC, ts_nanos DESC, id DESC
                LIMIT 1
                """
            ).fetchone()
        finally:
            con.close()
        if row and row[0]:
            print(base64.b64encode(row[0].encode("utf-8")).decode("ascii"))
            raise SystemExit(0)
    except Exception:
        pass
print("")
'@
  try {
    $encoded = $code | & $python.Source - @existing 2>$null
    $encoded = ([string]$encoded).Trim()
    if ([string]::IsNullOrWhiteSpace($encoded)) { return $null }
    $body = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
    return Convert-LogBodyToUsage -Body $body
  } catch {
    Write-AppLog "Log usage lookup failed: $($_.Exception.Message)"
    return $null
  }
}

function Get-Usage {
  try {
    $usage = Get-LiveUsage
    if ($null -ne $usage) { return $usage }
  } catch {
    Write-AppLog "Live usage lookup failed: $($_.Exception.Message)"
  }
  $logUsage = Get-LogUsage
  if ($null -ne $logUsage) { return $logUsage }
  return [PSCustomObject]@{
    Available = $false
    Source = "none"
    ObservedAt = Get-Date
  }
}

function Format-Duration {
  param($ResetAt)
  if ($null -eq $ResetAt) { return "--" }
  $seconds = [int][Math]::Max(0, [Math]::Ceiling((([datetime]$ResetAt) - (Get-Date)).TotalSeconds))
  if ($seconds -ge 86400) {
    return ("{0}" -f [int][Math]::Floor($seconds / 86400)) + (U "\u5929 ") + ("{0}" -f [int][Math]::Floor(($seconds % 86400) / 3600)) + (U "\u5c0f\u65f6")
  }
  if ($seconds -ge 3600) {
    return ("{0}" -f [int][Math]::Floor($seconds / 3600)) + (U "\u5c0f\u65f6 ") + ("{0}" -f [int][Math]::Floor(($seconds % 3600) / 60)) + (U "\u5206\u949f")
  }
  if ($seconds -ge 60) {
    return ("{0}" -f [int][Math]::Floor($seconds / 60)) + (U "\u5206\u949f ") + ("{0}" -f ($seconds % 60)) + (U "\u79d2")
  }
  return ("{0}" -f $seconds) + (U "\u79d2")
}

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "SelfTest failed: $Message" }
}

function Invoke-SelfTest {
  $payload = [PSCustomObject]@{
    rate_limit = [PSCustomObject]@{
      primary_window = [PSCustomObject]@{ used_percent = 37; limit_window_seconds = 18000; reset_after_seconds = 90 }
      secondary_window = [PSCustomObject]@{ used_percent = 52; limit_window_seconds = 604800; reset_after_seconds = 120 }
    }
  }
  $usage = Convert-UsagePayload -Payload $payload -Source "test"
  Assert-True ([Math]::Abs($usage.PrimaryRemaining - 63.0) -lt 0.01) "used_percent should become remaining percent"
  Assert-True ([Math]::Abs($usage.SecondaryRemaining - 48.0) -lt 0.01) "secondary used_percent should become remaining percent"

  $payload2 = [PSCustomObject]@{
    rate_limits = [PSCustomObject]@{
      primary = [PSCustomObject]@{ remaining_percent = 12; reset_at = [DateTimeOffset]::Now.AddMinutes(10).ToUnixTimeSeconds() }
    }
  }
  $usage2 = Convert-UsagePayload -Payload $payload2 -Source "test"
  Assert-True ([Math]::Abs($usage2.PrimaryRemaining - 12.0) -lt 0.01) "remaining_percent should be used directly"
  Assert-True ((Format-Duration $usage2.PrimaryResetAt) -ne "--") "reset_at should format"
  Assert-True ($null -eq (Convert-UsagePayload -Payload ([PSCustomObject]@{}) -Source "test")) "missing payload should return null"

  $body = 'prefix {"type":"codex.rate_limits","rate_limits":{"primary_window":{"used_percent":25,"limit_window_seconds":18000,"reset_after_seconds":60},"secondary_window":{"remaining_percent":88,"limit_window_seconds":604800,"reset_after_seconds":120}}} suffix'
  $logParsed = Convert-LogBodyToUsage -Body $body
  Assert-True ([Math]::Abs($logParsed.PrimaryRemaining - 75.0) -lt 0.01) "log body primary parse"
  Assert-True ([Math]::Abs($logParsed.SecondaryRemaining - 88.0) -lt 0.01) "log body secondary parse"

  $tempDb = Join-Path ([System.IO.Path]::GetTempPath()) ("codex_pet_usage_overlay_test_{0}.sqlite" -f ([guid]::NewGuid().ToString("N")))
  $py = @'
import sqlite3
import sys
import base64
path = sys.argv[1]
body = base64.b64decode(sys.argv[2]).decode("utf-8")
con = sqlite3.connect(path)
con.execute("create table logs (id integer primary key, ts integer, ts_nanos integer, feedback_log_body text)")
con.execute("insert into logs (ts, ts_nanos, feedback_log_body) values (1, 1, ?)", (body,))
con.commit()
con.close()
'@
  try {
    $python = Get-Command python -ErrorAction Stop
    $body64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($body))
    $py | & $python.Source - $tempDb $body64 | Out-Null
  $sqliteParsed = Get-LogUsage -LogPaths @($tempDb)
    Assert-True ([Math]::Abs($sqliteParsed.PrimaryRemaining - 75.0) -lt 0.01) "sqlite fallback parse"
  } finally {
    if (Test-Path -LiteralPath $tempDb) { Remove-Item -LiteralPath $tempDb -Force }
  }

  $rect = [PSCustomObject]@{ Left = 10; Top = 20; Width = 30; Height = 40 }
  Assert-True (Test-PointInRect -Point ([PSCustomObject]@{ X = 15; Y = 25 }) -Rect $rect) "cursor inside pet rect should show"
  Assert-True (-not (Test-PointInRect -Point ([PSCustomObject]@{ X = 50; Y = 25 }) -Rect $rect)) "cursor outside pet rect should not show"
  Assert-True (Test-PointInRect -Point ([PSCustomObject]@{ X = 50; Y = 25 }) -Rect $rect -Padding 10) "padding should catch near-pet cursor"
  $now = Get-Date
  $firstUntil = Get-OverlayShowUntil -CursorInPet $true -CursorWasInPet $false -CurrentShowUntil ([datetime]::MinValue) -Now $now -Seconds 10
  Assert-True (Test-ShouldShowOverlay -ShowUntilAt $firstUntil -Now $now.AddSeconds(9)) "entering pet should show for 10 seconds"
  Assert-True (-not (Test-ShouldShowOverlay -ShowUntilAt $firstUntil -Now $now.AddSeconds(11))) "show should expire after 10 seconds"
  $stayUntil = Get-OverlayShowUntil -CursorInPet $true -CursorWasInPet $true -CurrentShowUntil $firstUntil -Now $now.AddSeconds(5) -Seconds 10
  Assert-True ($stayUntil -eq $firstUntil) "staying on pet should not extend display time"
  $activeReenterUntil = Get-OverlayShowUntil -CursorInPet $true -CursorWasInPet $false -CurrentShowUntil $firstUntil -Now $now.AddSeconds(5) -Seconds 10
  Assert-True ($activeReenterUntil -eq $firstUntil) "re-entering while already visible should not extend display time"
  $reenterUntil = Get-OverlayShowUntil -CursorInPet $true -CursorWasInPet $false -CurrentShowUntil $firstUntil -Now $now.AddSeconds(12) -Seconds 10
  Assert-True ($reenterUntil -gt $firstUntil) "leaving and re-entering should trigger a new 10-second display"
  $dipPoint = Convert-DevicePointToDip -Window $null -Point ([PSCustomObject]@{ X = 12; Y = 34 })
  Assert-True ($dipPoint.X -eq 12 -and $dipPoint.Y -eq 34) "DPI conversion should safely fall back without a WPF source"
  $startupPath = Get-StartupShortcutPath
  Assert-True (([System.IO.Path]::GetExtension($startupPath)) -ieq ".lnk") "startup shortcut path should point to a lnk file"

  Write-Output "SelfTest OK"
}

function Show-Status {
  $running = Get-RunningOverlayProcess
  $state = Read-CodexState
  $startupPath = Get-StartupShortcutPath
  $latestLog = ""
  if (Test-Path -LiteralPath $LogPath) {
    $latestLog = Get-Content -LiteralPath $LogPath -Tail 1
  }
  [PSCustomObject]@{
    Running = $null -ne $running
    ProcessId = if ($running) { $running.ProcessId } else { $null }
    PidFile = $PidPath
    LogFile = $LogPath
    StartupShortcut = Test-Path -LiteralPath $startupPath
    StartupShortcutPath = $startupPath
    CodexHome = [System.IO.Path]::GetFullPath($CodexHome)
    CodexStateFile = Test-Path -LiteralPath (Join-Path $CodexHome ".codex-global-state.json")
    PetOverlayOpen = if ($state) { [bool]$state.'electron-avatar-overlay-open' } else { $false }
    LatestLog = $latestLog
  } | Format-List
}

function New-Brush {
  param([string]$Hex, [byte]$Alpha = 255)
  $clean = $Hex.TrimStart("#")
  $r = [Convert]::ToByte($clean.Substring(0, 2), 16)
  $g = [Convert]::ToByte($clean.Substring(2, 2), 16)
  $b = [Convert]::ToByte($clean.Substring(4, 2), 16)
  return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb($Alpha, $r, $g, $b))
}

function Set-EllipseBounds {
  param($Ellipse, [double]$CenterX, [double]$CenterY, [double]$Radius)
  $Ellipse.Width = $Radius * 2.0
  $Ellipse.Height = $Radius * 2.0
  [System.Windows.Controls.Canvas]::SetLeft($Ellipse, $CenterX - $Radius)
  [System.Windows.Controls.Canvas]::SetTop($Ellipse, $CenterY - $Radius)
}

function Set-ArcPath {
  param($Path, [double]$CenterX, [double]$CenterY, [double]$Radius, $Percent)
  if ($null -eq $Percent -or [double]$Percent -le 0) {
    $Path.Data = $null
    return
  }
  $p = [Math]::Min(99.99, [Math]::Max(0.01, [double]$Percent)) / 100.0
  $startAngle = -90.0
  $endAngle = $startAngle + 360.0 * $p
  $toRad = [Math]::PI / 180.0
  $sx = $CenterX + $Radius * [Math]::Cos($startAngle * $toRad)
  $sy = $CenterY + $Radius * [Math]::Sin($startAngle * $toRad)
  $ex = $CenterX + $Radius * [Math]::Cos($endAngle * $toRad)
  $ey = $CenterY + $Radius * [Math]::Sin($endAngle * $toRad)
  $large = if ($p -gt 0.5) { 1 } else { 0 }
  $data = "M {0:N2},{1:N2} A {2:N2},{2:N2} 0 {3} 1 {4:N2},{5:N2}" -f $sx, $sy, $Radius, $large, $ex, $ey
  $Path.Data = [System.Windows.Media.Geometry]::Parse($data)
}

function Run-Overlay {
  Ensure-AppDir
  Set-Content -LiteralPath $PidPath -Value $PID -Encoding ASCII
  Write-AppLog "Overlay run started."

  Add-Type -AssemblyName PresentationFramework
  Add-Type -AssemblyName PresentationCore
  Add-Type -AssemblyName WindowsBase
  Add-Type -AssemblyName System.Windows.Forms
  if (-not ("CodexPetUsageOverlayNative" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class CodexPetUsageOverlayNative {
    private const int GWL_EXSTYLE = -20;
    private const long WS_EX_TRANSPARENT = 0x00000020L;
    private const long WS_EX_TOOLWINDOW = 0x00000080L;
    private const long WS_EX_NOACTIVATE = 0x08000000L;

    [DllImport("user32.dll", EntryPoint="GetWindowLongW", SetLastError=true)]
    private static extern int GetWindowLong32(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint="SetWindowLongW", SetLastError=true)]
    private static extern int SetWindowLong32(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW", SetLastError=true)]
    private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint="SetWindowLongPtrW", SetLastError=true)]
    private static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    public static void MakeClickThrough(IntPtr hWnd) {
        if (hWnd == IntPtr.Zero) { return; }
        if (IntPtr.Size == 8) {
            long style = GetWindowLongPtr64(hWnd, GWL_EXSTYLE).ToInt64();
            style |= WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
            SetWindowLongPtr64(hWnd, GWL_EXSTYLE, new IntPtr(style));
        } else {
            int style = GetWindowLong32(hWnd, GWL_EXSTYLE);
            style |= unchecked((int)(WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE));
            SetWindowLong32(hWnd, GWL_EXSTYLE, style);
        }
    }
}
"@
  }

  $script:UsageState = [PSCustomObject]@{ Available = $false; Source = "none"; ObservedAt = Get-Date }
  $script:ShowOverlayUntil = [datetime]::MinValue
  $script:CursorWasInPet = $false
  $script:OverlayWasVisible = $false

  $window = New-Object System.Windows.Window
  $window.WindowStyle = [System.Windows.WindowStyle]::None
  $window.ResizeMode = [System.Windows.ResizeMode]::NoResize
  $window.AllowsTransparency = $true
  $window.Background = [System.Windows.Media.Brushes]::Transparent
  $window.ShowInTaskbar = $false
  $window.Topmost = $true
  $window.Width = 360
  $window.Height = 150

  $canvas = New-Object System.Windows.Controls.Canvas
  $window.Content = $canvas

  $outerTrack = New-Object System.Windows.Shapes.Ellipse
  $outerTrack.Stroke = New-Brush "#FFFFFF" 35
  $outerTrack.StrokeThickness = 7
  $innerTrack = New-Object System.Windows.Shapes.Ellipse
  $innerTrack.Stroke = New-Brush "#FFFFFF" 28
  $innerTrack.StrokeThickness = 5
  $outerArc = New-Object System.Windows.Shapes.Path
  $outerArc.Stroke = New-Brush "#3CEBBD" 215
  $outerArc.StrokeThickness = 7
  $outerArc.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
  $outerArc.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
  $innerArc = New-Object System.Windows.Shapes.Path
  $innerArc.Stroke = New-Brush "#56B2FF" 205
  $innerArc.StrokeThickness = 5
  $innerArc.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
  $innerArc.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round

  foreach ($shape in @($outerTrack, $innerTrack, $outerArc, $innerArc)) {
    [void]$canvas.Children.Add($shape)
  }

  $panel = New-Object System.Windows.Controls.Border
  $panel.Width = 222
  $panel.Height = 88
  $panel.CornerRadius = New-Object System.Windows.CornerRadius 6
  $panel.Background = New-Brush "#0D181E" 205
  $panel.Padding = New-Object System.Windows.Thickness 10,8,10,8
  $stack = New-Object System.Windows.Controls.StackPanel
  $panel.Child = $stack

  $title = New-Object System.Windows.Controls.TextBlock
  $title.Text = U "\u0043\u006f\u0064\u0065\u0078 \u7528\u91cf"
  $title.Foreground = New-Brush "#FFFFFF" 230
  $title.FontSize = 12
  $title.FontWeight = [System.Windows.FontWeights]::SemiBold
  $line1 = New-Object System.Windows.Controls.TextBlock
  $line2 = New-Object System.Windows.Controls.TextBlock
  $status = New-Object System.Windows.Controls.TextBlock
  foreach ($text in @($line1, $line2)) {
    $text.Foreground = New-Brush "#FFFFFF" 238
    $text.FontSize = 12
    $text.TextWrapping = [System.Windows.TextWrapping]::NoWrap
    $text.Margin = New-Object System.Windows.Thickness 0,4,0,0
  }
  $status.Foreground = New-Brush "#B8C5CC" 215
  $status.FontSize = 10
  $status.Margin = New-Object System.Windows.Thickness 0,4,0,0
  foreach ($text in @($title, $line1, $line2, $status)) { [void]$stack.Children.Add($text) }
  [void]$canvas.Children.Add($panel)

  function Update-Text {
    if (-not $script:UsageState.Available) {
      $line1.Text = U "5\u5c0f\u65f6 \u7528\u91cf\u6682\u4e0d\u53ef\u7528"
      $line2.Text = U "7\u5929 \u7528\u91cf\u6682\u4e0d\u53ef\u7528"
      $status.Text = U "\u7b49\u5f85\u5b9e\u65f6\u7528\u91cf\u6216\u672c\u5730\u65e5\u5fd7"
      return
    }
    $p = if ($null -ne $script:UsageState.PrimaryRemaining) { $script:UsageState.PrimaryRemaining } else { 0 }
    $s = if ($null -ne $script:UsageState.SecondaryRemaining) { $script:UsageState.SecondaryRemaining } else { 0 }
    $line1.Text = (U "5\u5c0f\u65f6 \u5269\u4f59 {0:N0}% \u00b7 {1}\u540e\u5237\u65b0") -f $p, (Format-Duration $script:UsageState.PrimaryResetAt)
    $line2.Text = (U "7\u5929 \u5269\u4f59 {0:N0}% \u00b7 {1}\u540e\u5237\u65b0") -f $s, (Format-Duration $script:UsageState.SecondaryResetAt)
    $status.Text = (U "\u6765\u6e90 {0} \u00b7 {1:HH:mm:ss}") -f $script:UsageState.Source, $script:UsageState.ObservedAt
  }

  function Refresh-Usage {
    $script:UsageState = Get-Usage
    if ($script:UsageState.Available) {
      Write-AppLog ("Usage updated: source={0}, 5h={1:N0}, 7d={2:N0}" -f $script:UsageState.Source, $script:UsageState.PrimaryRemaining, $script:UsageState.SecondaryRemaining)
    } else {
      Write-AppLog "Usage unavailable."
    }
    Update-Text
  }

  function Update-Overlay {
    $pet = Get-PetRect
    if ($null -eq $pet) {
      $script:ShowOverlayUntil = [datetime]::MinValue
      $script:CursorWasInPet = $false
      $window.Hide()
      return
    }

    $cursor = Convert-DevicePointToDip -Window $window -Point ([System.Windows.Forms.Cursor]::Position)
    $now = Get-Date
    # ponytail: cursor polling can miss very fast fly-bys; replace with a mouse hook only if 100ms polling still misses real use.
    $cursorInPet = Test-PointInRect -Point $cursor -Rect $pet -Padding $HoverPaddingPx
    $script:ShowOverlayUntil = Get-OverlayShowUntil -CursorInPet $cursorInPet -CursorWasInPet $script:CursorWasInPet -CurrentShowUntil $script:ShowOverlayUntil -Now $now -Seconds $HoverShowSeconds
    if ($cursorInPet -and -not $script:CursorWasInPet) {
      Write-AppLog ("Hover trigger: show until {0:HH:mm:ss}, cursorDip=({1:N0},{2:N0}), cursorDevice=({3:N0},{4:N0}), pet=({5:N0},{6:N0},{7:N0},{8:N0}), padding={9}" -f $script:ShowOverlayUntil, $cursor.X, $cursor.Y, $cursor.DeviceX, $cursor.DeviceY, $pet.Left, $pet.Top, $pet.Width, $pet.Height, $HoverPaddingPx)
    }
    $script:CursorWasInPet = $cursorInPet
    if (-not (Test-ShouldShowOverlay -ShowUntilAt $script:ShowOverlayUntil -Now $now)) {
      if ($script:OverlayWasVisible) { Write-AppLog "Hover display expired; overlay hidden." }
      $script:OverlayWasVisible = $false
      $window.Hide()
      return
    }

    $ringSize = [Math]::Max(104.0, [Math]::Max($pet.Width, $pet.Height) + 52.0)
    $panelWidth = 222.0
    $gap = 10.0
    $height = [Math]::Max($ringSize, 96.0)
    $displayRight = $pet.DisplayLeft + $pet.DisplayWidth
    $ringLeftOnScreen = $pet.Left + ($pet.Width / 2.0) - ($ringSize / 2.0)
    $ringTopOnScreen = $pet.Top + ($pet.Height / 2.0) - ($ringSize / 2.0)
    $placeTextLeft = ($ringLeftOnScreen + $ringSize + $gap + $panelWidth) -gt $displayRight

    if ($placeTextLeft) {
      $window.Left = $ringLeftOnScreen - $gap - $panelWidth
      $ringX = $panelWidth + $gap
      $textX = 0.0
    } else {
      $window.Left = $ringLeftOnScreen
      $ringX = 0.0
      $textX = $ringSize + $gap
    }
    $window.Top = $ringTopOnScreen
    $window.Width = $ringSize + $gap + $panelWidth
    $window.Height = $height

    $cx = $ringX + ($ringSize / 2.0)
    $cy = $height / 2.0
    $outerRadius = ($ringSize / 2.0) - 7.0
    $innerRadius = $outerRadius - 13.0
    Set-EllipseBounds -Ellipse $outerTrack -CenterX $cx -CenterY $cy -Radius $outerRadius
    Set-EllipseBounds -Ellipse $innerTrack -CenterX $cx -CenterY $cy -Radius $innerRadius
    Set-ArcPath -Path $outerArc -CenterX $cx -CenterY $cy -Radius $outerRadius -Percent $script:UsageState.PrimaryRemaining
    Set-ArcPath -Path $innerArc -CenterX $cx -CenterY $cy -Radius $innerRadius -Percent $script:UsageState.SecondaryRemaining
    [System.Windows.Controls.Canvas]::SetLeft($panel, $textX)
    [System.Windows.Controls.Canvas]::SetTop($panel, [Math]::Max(0.0, ($height - $panel.Height) / 2.0))
    if (-not $window.IsVisible) { $window.Show() }
    $script:OverlayWasVisible = $true
  }

  $window.Add_SourceInitialized({
    $helper = New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $window
    [CodexPetUsageOverlayNative]::MakeClickThrough($helper.Handle)
  })

  $usageTimer = New-Object System.Windows.Threading.DispatcherTimer
  $usageTimer.Interval = [TimeSpan]::FromSeconds($UsagePollSeconds)
  $usageTimer.Add_Tick({
    try { Refresh-Usage; Update-Overlay } catch { Write-AppLog "Usage timer failed: $($_.Exception.Message)" }
  })
  $petTimer = New-Object System.Windows.Threading.DispatcherTimer
  $petTimer.Interval = [TimeSpan]::FromMilliseconds($PetPollMs)
  $petTimer.Add_Tick({
    try { Update-Text; Update-Overlay } catch { Write-AppLog "Pet timer failed: $($_.Exception.Message)" }
  })

  $app = New-Object System.Windows.Application
  $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
  $usageTimer.Start()
  $petTimer.Start()
  Refresh-Usage
  Update-Overlay
  [void]$app.Run($window)
}

switch ($Command) {
  "Start" { Start-Overlay }
  "Stop" { Stop-Overlay }
  "Status" { Show-Status }
  "SelfTest" { Invoke-SelfTest }
  "InstallStartup" { Install-StartupShortcut }
  "UninstallStartup" { Uninstall-StartupShortcut }
  "Run" { Run-Overlay }
}
