import AppKit
import Foundation
import Darwin

struct Options {
    var command = "start"
    var usagePollSeconds: TimeInterval = 30
    var petPollMilliseconds: TimeInterval = 100
    var hoverPadding: CGFloat = 24
    var codexHome = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 1

        if index < arguments.count, !arguments[index].hasPrefix("-") {
            options.command = normalizeCommand(arguments[index])
            index += 1
        }

        while index < arguments.count {
            let key = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch key {
            case "--usage-poll-seconds", "-UsagePollSeconds":
                if let value, let number = Double(value) {
                    options.usagePollSeconds = max(10, number)
                    index += 2
                } else {
                    index += 1
                }
            case "--pet-poll-ms", "-PetPollMs":
                if let value, let number = Double(value) {
                    options.petPollMilliseconds = max(50, number)
                    index += 2
                } else {
                    index += 1
                }
            case "--hover-padding-px", "-HoverPaddingPx":
                if let value, let number = Double(value) {
                    options.hoverPadding = CGFloat(max(0, min(200, number)))
                    index += 2
                } else {
                    index += 1
                }
            case "--codex-home", "-CodexHome":
                if let value {
                    options.codexHome = URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
                    index += 2
                } else {
                    index += 1
                }
            default:
                index += 1
            }
        }

        return options
    }

    private static func normalizeCommand(_ raw: String) -> String {
        let compact = raw.replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        switch compact {
        case "start": return "start"
        case "stop": return "stop"
        case "status": return "status"
        case "run": return "run"
        case "selftest": return "self-test"
        case "installstartup": return "install-startup"
        case "uninstallstartup": return "uninstall-startup"
        default: return raw.lowercased()
        }
    }

    func runArguments() -> [String] {
        [
            "run",
            "--usage-poll-seconds", "\(Int(usagePollSeconds))",
            "--pet-poll-ms", "\(Int(petPollMilliseconds))",
            "--hover-padding-px", "\(Int(hoverPadding))",
            "--codex-home", codexHome.path
        ]
    }
}

struct Paths {
    let appDir: URL
    let pidFile: URL
    let logFile: URL
    let installedExecutable: URL
    let appBundle: URL
    let appBundleExecutable: URL
    let appBundleInfoPlist: URL
    let launchAgentFile: URL

    static func current() -> Paths {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let appDir = home.appendingPathComponent("Library/Application Support/CodexPetUsageOverlay", isDirectory: true)
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return Paths(
            appDir: appDir,
            pidFile: appDir.appendingPathComponent("overlay.pid"),
            logFile: appDir.appendingPathComponent("overlay.log"),
            installedExecutable: appDir.appendingPathComponent("codex-pet-usage-overlay-mac"),
            appBundle: appDir.appendingPathComponent("CodexPetUsageOverlay.app", isDirectory: true),
            appBundleExecutable: appDir.appendingPathComponent("CodexPetUsageOverlay.app/Contents/MacOS/codex-pet-usage-overlay-mac"),
            appBundleInfoPlist: appDir.appendingPathComponent("CodexPetUsageOverlay.app/Contents/Info.plist"),
            launchAgentFile: launchAgents.appendingPathComponent("dev.jimmyasksai.codex-pet-usage-overlay.plist")
        )
    }

    func ensureAppDir() throws {
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
    }
}

struct Logger {
    let paths: Paths

    func write(_ message: String) {
        do {
            try paths.ensureAppDir()
            if !FileManager.default.fileExists(atPath: paths.logFile.path) {
                FileManager.default.createFile(atPath: paths.logFile.path, contents: nil)
            }
            let formatter = ISO8601DateFormatter()
            let line = "\(formatter.string(from: Date())) \(message)\n"
            let handle = try FileHandle(forWritingTo: paths.logFile)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
        } catch {
        }
    }
}

struct UsageState {
    let available: Bool
    let source: String
    let primaryRemaining: Double?
    let secondaryRemaining: Double?
    let primaryResetAt: Date?
    let secondaryResetAt: Date?
    let observedAt: Date

    static func unavailable(source: String = "none") -> UsageState {
        UsageState(
            available: false,
            source: source,
            primaryRemaining: nil,
            secondaryRemaining: nil,
            primaryResetAt: nil,
            secondaryResetAt: nil,
            observedAt: Date()
        )
    }
}

struct PetRect {
    let left: CGFloat
    let top: CGFloat
    let width: CGFloat
    let height: CGFloat
    let displayLeft: CGFloat
    let displayTop: CGFloat
    let displayWidth: CGFloat
    let displayHeight: CGFloat
    let primaryDisplayHeight: CGFloat

    var electronRect: CGRect {
        CGRect(x: left, y: top, width: width, height: height)
    }

    var electronDisplayBounds: CGRect {
        CGRect(x: displayLeft, y: displayTop, width: displayWidth, height: displayHeight)
    }

    var appKitDisplayFrame: CGRect {
        CGRect(
            x: displayLeft,
            y: primaryDisplayHeight - displayTop - displayHeight,
            width: displayWidth,
            height: displayHeight
        )
    }
}

enum Json {
    static func dictionary(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func readDictionary(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return dictionary(from: data)
    }

    static func dict(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["true", "1", "yes"].contains(string.lowercased()) }
        return false
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }
}

final class CodexStateReader {
    let codexHome: URL

    init(codexHome: URL) {
        self.codexHome = codexHome
    }

    var stateURL: URL {
        codexHome.appendingPathComponent(".codex-global-state.json")
    }

    func isPetOpen() -> Bool {
        guard let state = Json.readDictionary(stateURL) else { return false }
        return Json.bool(state["electron-avatar-overlay-open"])
    }

    func readPetRect() -> PetRect? {
        guard let state = Json.readDictionary(stateURL),
              Json.bool(state["electron-avatar-overlay-open"]) else { return nil }

        if let bounds = Json.dict(state["electron-avatar-overlay-bounds"]),
           let rect = petRect(from: bounds, primaryDisplayHeight: primaryDisplayHeight(from: bounds)) {
            return rect
        }

        if let bounds = Json.dict(state["electron-avatar-overlay-bounds"]),
           let byDisplay = Json.dict(bounds["byDisplayId"]) {
            for value in byDisplay.values {
                if let rect = petRect(from: Json.dict(value), primaryDisplayHeight: primaryDisplayHeight(from: bounds)) {
                    return rect
                }
            }
        }

        return nil
    }

    private func petRect(from bounds: [String: Any]?, primaryDisplayHeight: CGFloat) -> PetRect? {
        guard let bounds,
              let x = Json.double(bounds["x"]),
              let y = Json.double(bounds["y"]),
              let mascot = Json.dict(bounds["mascot"]),
              let mascotLeft = Json.double(mascot["left"]),
              let mascotTop = Json.double(mascot["top"]),
              let mascotWidth = Json.double(mascot["width"]),
              let mascotHeight = Json.double(mascot["height"]) else {
            return nil
        }

        let display = Json.dict(bounds["displayBounds"]) ?? [:]
        let displayLeft = Json.double(display["x"]) ?? 0
        let displayTop = Json.double(display["y"]) ?? 0
        let displayWidth = Json.double(display["width"]) ?? 1920
        let displayHeight = Json.double(display["height"]) ?? 1080

        return PetRect(
            left: CGFloat(x + mascotLeft),
            top: CGFloat(y + mascotTop),
            width: CGFloat(mascotWidth),
            height: CGFloat(mascotHeight),
            displayLeft: CGFloat(displayLeft),
            displayTop: CGFloat(displayTop),
            displayWidth: CGFloat(displayWidth),
            displayHeight: CGFloat(displayHeight),
            primaryDisplayHeight: primaryDisplayHeight
        )
    }

    private func primaryDisplayHeight(from bounds: [String: Any]) -> CGFloat {
        if let byDisplay = Json.dict(bounds["byDisplayId"]) {
            for value in byDisplay.values {
                guard let display = Json.dict(Json.dict(value)?["displayBounds"]),
                      let x = Json.double(display["x"]),
                      let y = Json.double(display["y"]),
                      let height = Json.double(display["height"]) else { continue }
                if abs(x) < 0.5 && abs(y) < 0.5 {
                    return CGFloat(height)
                }
            }
        }

        if let display = Json.dict(bounds["displayBounds"]),
           let y = Json.double(display["y"]),
           abs(y) < 0.5,
           let height = Json.double(display["height"]) {
            return CGFloat(height)
        }

        return CoordinateSpace.mainScreenForConversion()?.frame.height ?? 0
    }
}

enum CoordinateSpace {
    static func mainScreenForConversion() -> NSScreen? {
        NSScreen.screens.first(where: { abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func appKitRect(fromElectronTopLeft rect: CGRect, displayBounds: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        if primaryDisplayHeight > 0 {
            return CGRect(
                x: rect.minX,
                y: primaryDisplayHeight - rect.minY - rect.height,
                width: rect.width,
                height: rect.height
            )
        }

        if let screen = screen(matchingElectronDisplayBounds: displayBounds) {
            let localX = rect.minX - displayBounds.minX
            let localTop = rect.minY - displayBounds.minY
            return CGRect(
                x: screen.frame.minX + localX,
                y: screen.frame.maxY - localTop - rect.height,
                width: rect.width,
                height: rect.height
            )
        }

        let main = mainScreenForConversion()
        let mainTop = main?.frame.maxY ?? main?.frame.height ?? 0
        return CGRect(
            x: rect.minX,
            y: mainTop - rect.minY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    static func screen(matchingElectronDisplayBounds displayBounds: CGRect) -> NSScreen? {
        NSScreen.screens.first(where: {
            abs($0.frame.minX - displayBounds.minX) < 2 &&
            abs($0.frame.width - displayBounds.width) < 2 &&
            abs($0.frame.height - displayBounds.height) < 2
        }) ?? NSScreen.screens.first(where: {
            abs($0.frame.width - displayBounds.width) < 2 &&
            abs($0.frame.height - displayBounds.height) < 2
        })
    }

    static func screen(containing rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(rect) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

final class UsageReader {
    let codexHome: URL
    let logger: Logger

    init(codexHome: URL, logger: Logger) {
        self.codexHome = codexHome
        self.logger = logger
    }

    func getUsage() -> UsageState {
        if let live = getLiveUsage() {
            return live
        }
        if let log = getLogUsage() {
            return log
        }
        return .unavailable()
    }

    private func getLiveUsage() -> UsageState? {
        let authURL = codexHome.appendingPathComponent("auth.json")
        guard let auth = Json.readDictionary(authURL),
              let tokens = Json.dict(auth["tokens"]),
              let token = Json.string(tokens["access_token"]),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var payload: [String: Any]?
        var failed: Error?

        URLSession(configuration: .ephemeral).dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            if let error {
                failed = error
                return
            }
            guard let data else { return }
            payload = Json.dictionary(from: data)
        }.resume()

        if semaphore.wait(timeout: .now() + 22) == .timedOut {
            logger.write("Live usage lookup timed out.")
            return nil
        }

        if let failed {
            logger.write("Live usage lookup failed: \(failed.localizedDescription)")
            return nil
        }

        return UsageParser.convert(payload: payload, source: "live")
    }

    private func getLogUsage() -> UsageState? {
        let logURLs = [
            codexHome.appendingPathComponent("logs_2.sqlite"),
            codexHome.appendingPathComponent("logs_1.sqlite")
        ]

        for url in logURLs where FileManager.default.fileExists(atPath: url.path) {
            guard let body = latestRateLimitLogBody(from: url), !body.isEmpty else { continue }
            if let usage = UsageParser.convertLogBodyToUsage(body) {
                return usage
            }
        }

        return nil
    }

    private func latestRateLimitLogBody(from url: URL) -> String? {
        let query = """
        SELECT feedback_log_body
        FROM logs
        WHERE feedback_log_body LIKE '%codex.rate_limits%'
        ORDER BY ts DESC, ts_nanos DESC, id DESC
        LIMIT 1;
        """
        let result = Shell.capture("/usr/bin/sqlite3", arguments: ["-readonly", url.path, query])
        if result.status != 0 {
            logger.write("Log usage lookup failed for \(url.path): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            return nil
        }
        return result.stdout.trimmingCharacters(in: .newlines)
    }
}

enum UsageParser {
    static func convert(payload: [String: Any]?, source: String) -> UsageState? {
        guard let payload else { return nil }
        let rate = Json.dict(payload["rate_limit"]) ?? Json.dict(payload["rate_limits"])
        guard let rate else { return nil }

        let primary = Json.dict(rate["primary_window"]) ?? Json.dict(rate["primary"])
        let secondary = Json.dict(rate["secondary_window"]) ?? Json.dict(rate["secondary"])
        let primaryRemaining = bucketRemaining(primary)
        let secondaryRemaining = bucketRemaining(secondary)

        if primaryRemaining == nil && secondaryRemaining == nil {
            return nil
        }

        return UsageState(
            available: true,
            source: source,
            primaryRemaining: primaryRemaining,
            secondaryRemaining: secondaryRemaining,
            primaryResetAt: resetDate(primary),
            secondaryResetAt: resetDate(secondary),
            observedAt: Date()
        )
    }

    static func convertLogBodyToUsage(_ body: String) -> UsageState? {
        let marker = "codex.rate_limits"
        let ns = body as NSString
        var searchRange = NSRange(location: 0, length: ns.length)

        while true {
            let markerRange = ns.range(of: marker, options: [.caseInsensitive], range: searchRange)
            if markerRange.location == NSNotFound { break }

            var startSearchLength = markerRange.location
            while startSearchLength > 0 {
                let braceRange = ns.range(of: "{", options: [.backwards], range: NSRange(location: 0, length: startSearchLength))
                if braceRange.location == NSNotFound { break }

                if let json = balancedJSONObject(in: ns, start: braceRange.location),
                   json.range(of: marker, options: .caseInsensitive) != nil,
                   let data = json.data(using: .utf8),
                   let payload = Json.dictionary(from: data),
                   (Json.string(payload["type"]) == marker || payload["rate_limit"] != nil || payload["rate_limits"] != nil),
                   let usage = convert(payload: payload, source: "log") {
                    return usage
                }

                startSearchLength = braceRange.location
            }

            let nextLocation = markerRange.location + markerRange.length
            if nextLocation >= ns.length { break }
            searchRange = NSRange(location: nextLocation, length: ns.length - nextLocation)
        }

        return nil
    }

    private static func bucketRemaining(_ bucket: [String: Any]?) -> Double? {
        guard let bucket else { return nil }
        if let remaining = Json.double(bucket["remaining_percent"]) {
            return clampPercent(remaining)
        }
        if let used = Json.double(bucket["used_percent"]) {
            return clampPercent(100 - used)
        }
        return nil
    }

    private static func resetDate(_ bucket: [String: Any]?) -> Date? {
        guard let bucket else { return nil }
        if let seconds = Json.double(bucket["reset_after_seconds"]) ?? Json.double(bucket["seconds_until_reset"]) {
            return Date().addingTimeInterval(seconds)
        }

        for key in ["reset_at", "resets_at", "reset_time", "expires_at", "window_reset_at"] {
            guard let value = bucket[key] else { continue }
            if let number = Json.double(value) {
                let seconds = number > 10_000_000_000 ? number / 1000 : number
                return Date(timeIntervalSince1970: seconds)
            }
            if let string = value as? String {
                let iso = ISO8601DateFormatter()
                if let date = iso.date(from: string) {
                    return date
                }
            }
        }

        return nil
    }

    private static func clampPercent(_ value: Double) -> Double {
        max(0, min(100, value))
    }

    private static func balancedJSONObject(in ns: NSString, start: Int) -> String? {
        var depth = 0
        var inString = false
        var escaping = false

        for index in start..<ns.length {
            let ch = ns.character(at: index)
            if inString {
                if escaping {
                    escaping = false
                } else if ch == 92 {
                    escaping = true
                } else if ch == 34 {
                    inString = false
                }
                continue
            }

            if ch == 34 {
                inString = true
            } else if ch == 123 {
                depth += 1
            } else if ch == 125 {
                depth -= 1
                if depth == 0 {
                    return ns.substring(with: NSRange(location: start, length: index - start + 1))
                }
            }
        }

        return nil
    }
}

final class OverlayView: NSView {
    var usage = UsageState.unavailable() {
        didSet { needsDisplay = true }
    }
    var ringSize: CGFloat = 112 {
        didSet { needsDisplay = true }
    }
    var ringX: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    var panelX: CGFloat = 122 {
        didSet { needsDisplay = true }
    }
    var panelWidth: CGFloat = 238 {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let height = bounds.height
        let center = CGPoint(x: ringX + ringSize / 2, y: height / 2)
        let outerRadius = ringSize / 2 - 7
        let innerRadius = outerRadius - 13

        drawCircle(center: center, radius: outerRadius, color: NSColor.black.withAlphaComponent(0.42), width: 16)
        drawCircle(center: center, radius: outerRadius, color: NSColor.white.withAlphaComponent(0.36), width: 10)
        drawCircle(center: center, radius: innerRadius, color: NSColor.white.withAlphaComponent(0.26), width: 7)
        drawArc(center: center, radius: outerRadius, percent: usage.primaryRemaining, color: NSColor(calibratedRed: 0.08, green: 1.0, blue: 0.70, alpha: 1.0), width: 10)
        drawArc(center: center, radius: innerRadius, percent: usage.secondaryRemaining, color: NSColor(calibratedRed: 0.18, green: 0.62, blue: 1.0, alpha: 1.0), width: 7)

        let panelHeight: CGFloat = 110
        let panel = NSRect(x: panelX, y: max(0, (height - panelHeight) / 2), width: panelWidth, height: panelHeight)
        let panelPath = NSBezierPath(roundedRect: panel, xRadius: 8, yRadius: 8)
        NSColor(calibratedRed: 0.02, green: 0.04, blue: 0.05, alpha: 0.96).setFill()
        panelPath.fill()
        NSColor.white.withAlphaComponent(0.28).setStroke()
        panelPath.lineWidth = 1
        panelPath.stroke()

        drawText(in: panel.insetBy(dx: 13, dy: 9))
    }

    private func drawCircle(center: CGPoint, radius: CGFloat, color: NSColor, width: CGFloat) {
        let rect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }

    private func drawArc(center: CGPoint, radius: CGFloat, percent: Double?, color: NSColor, width: CGFloat) {
        guard let percent, percent > 0 else { return }
        let clamped = CGFloat(max(0.01, min(99.99, percent))) / 100
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: 90 - 360 * clamped,
            clockwise: true
        )
        color.setStroke()
        path.stroke()
    }

    private func drawText(in rect: NSRect) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let lineAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let statusAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(calibratedRed: 0.78, green: 0.86, blue: 0.90, alpha: 0.95)
        ]

        let lines = textLines()
        NSString(string: "Codex /pet 用量").draw(in: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 20), withAttributes: titleAttrs)
        NSString(string: lines.0).draw(in: NSRect(x: rect.minX, y: rect.minY + 30, width: rect.width, height: 18), withAttributes: lineAttrs)
        NSString(string: lines.1).draw(in: NSRect(x: rect.minX, y: rect.minY + 54, width: rect.width, height: 18), withAttributes: lineAttrs)
        NSString(string: lines.2).draw(in: NSRect(x: rect.minX, y: rect.minY + 82, width: rect.width, height: 16), withAttributes: statusAttrs)
    }

    private func textLines() -> (String, String, String) {
        guard usage.available else {
            return ("5小时 用量暂不可用", "7天 用量暂不可用", "等待实时用量或本地日志")
        }

        let primary = Int(round(usage.primaryRemaining ?? 0))
        let secondary = Int(round(usage.secondaryRemaining ?? 0))
        let primaryReset = Format.duration(until: usage.primaryResetAt)
        let secondaryReset = Format.duration(until: usage.secondaryResetAt)
        return (
            "5小时 剩余 \(primary)% · \(primaryReset)后刷新",
            "7天 剩余 \(secondary)% · \(secondaryReset)后刷新",
            "来源 \(usage.source) · \(Format.clock(usage.observedAt))"
        )
    }
}

enum Format {
    static func duration(until resetAt: Date?) -> String {
        guard let resetAt else { return "--" }
        let seconds = max(0, Int(ceil(resetAt.timeIntervalSinceNow)))
        if seconds >= 86_400 {
            return "\(seconds / 86_400)天 \((seconds % 86_400) / 3_600)小时"
        }
        if seconds >= 3_600 {
            return "\(seconds / 3_600)小时 \((seconds % 3_600) / 60)分钟"
        }
        if seconds >= 60 {
            return "\(seconds / 60)分钟 \(seconds % 60)秒"
        }
        return "\(seconds)秒"
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

final class OverlayController {
    let options: Options
    let paths: Paths
    let logger: Logger
    let stateReader: CodexStateReader
    let usageReader: UsageReader
    let window: NSWindow
    let overlayView: OverlayView

    var usageState = UsageState.unavailable()
    var usageRefreshInFlight = false
    var showUntil = Date.distantPast
    var cursorWasInPet = false
    var overlayWasVisible = false
    var signalSources: [DispatchSourceSignal] = []
    var didShowLaunchPreview = false
    var lastPetMissingLog = Date.distantPast
    var lastVisibleLog = Date.distantPast

    init(options: Options, paths: Paths) {
        self.options = options
        self.paths = paths
        self.logger = Logger(paths: paths)
        self.stateReader = CodexStateReader(codexHome: options.codexHome)
        self.usageReader = UsageReader(codexHome: options.codexHome, logger: logger)
        self.overlayView = OverlayView(frame: NSRect(x: 0, y: 0, width: 374, height: 150))
        self.window = NSWindow(
            contentRect: overlayView.frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Codex Pet Usage Overlay"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.canHide = false
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = overlayView
    }

    func run() throws {
        try paths.ensureAppDir()
        try "\(getpid())\n".write(to: paths.pidFile, atomically: true, encoding: .utf8)
        logger.write("Overlay run started.")

        NSApp.setActivationPolicy(.regular)
        installSignalHandler()

        Timer.scheduledTimer(withTimeInterval: max(0.05, options.petPollMilliseconds / 1000), repeats: true) { [weak self] _ in
            self?.tickPet()
        }
        Timer.scheduledTimer(withTimeInterval: max(10, options.usagePollSeconds), repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }

        refreshUsage()
        tickPet()
        NSApp.run()
    }

    private func installSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in
            self?.logger.write("Overlay received SIGTERM.")
            NSApp.terminate(nil)
        }
        term.resume()

        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { [weak self] in
            self?.logger.write("Overlay received SIGINT.")
            NSApp.terminate(nil)
        }
        interrupt.resume()

        signalSources = [term, interrupt]
    }

    private func refreshUsage() {
        if usageRefreshInFlight { return }
        usageRefreshInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let usage = self.usageReader.getUsage()
            DispatchQueue.main.async {
                self.usageRefreshInFlight = false
                self.usageState = usage
                self.overlayView.usage = usage
                if usage.available {
                    self.logger.write("Usage updated: source=\(usage.source), 5h=\(Int(round(usage.primaryRemaining ?? 0))), 7d=\(Int(round(usage.secondaryRemaining ?? 0)))")
                } else {
                    self.logger.write("Usage unavailable.")
                }
            }
        }
    }

    private func tickPet() {
        guard let pet = stateReader.readPetRect() else {
            let now = Date()
            if now.timeIntervalSince(lastPetMissingLog) > 5 {
                lastPetMissingLog = now
                logger.write("Pet rect unavailable; overlay hidden.")
            }
            showUntil = Date.distantPast
            cursorWasInPet = false
            overlayWasVisible = false
            window.orderOut(nil)
            return
        }

        let petRect = CoordinateSpace.appKitRect(
            fromElectronTopLeft: pet.electronRect,
            displayBounds: pet.electronDisplayBounds,
            primaryDisplayHeight: pet.primaryDisplayHeight
        )
        let cursor = NSEvent.mouseLocation
        let padded = petRect.insetBy(dx: -options.hoverPadding, dy: -options.hoverPadding)
        let cursorInPet = padded.contains(cursor)
        let now = Date()

        if !didShowLaunchPreview {
            didShowLaunchPreview = true
            showUntil = Date.distantFuture
            logger.write("Launch preview: pet=(\(Int(petRect.minX)),\(Int(petRect.minY)),\(Int(petRect.width)),\(Int(petRect.height))).")
        }

        if cursorInPet && !cursorWasInPet && now > showUntil {
            showUntil = Date.distantFuture
            logger.write("Hover trigger: pet=(\(Int(petRect.minX)),\(Int(petRect.minY)),\(Int(petRect.width)),\(Int(petRect.height))), cursor=(\(Int(cursor.x)),\(Int(cursor.y))), padding=\(Int(options.hoverPadding))")
        }
        cursorWasInPet = cursorInPet

        positionOverlay(around: petRect, in: pet.appKitDisplayFrame)
        if !window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            logger.write("Overlay visible.")
        } else if now.timeIntervalSince(lastVisibleLog) > 10 {
            window.orderFrontRegardless()
            logger.write("Overlay still visible: window=(\(Int(window.frame.minX)),\(Int(window.frame.minY)),\(Int(window.frame.width)),\(Int(window.frame.height))), pet=(\(Int(petRect.minX)),\(Int(petRect.minY)),\(Int(petRect.width)),\(Int(petRect.height))).")
            lastVisibleLog = now
        }
        overlayWasVisible = true
    }

    private func positionOverlay(around petRect: CGRect, in screenFrame: CGRect) {
        let ringSize = max(CGFloat(140), max(petRect.width, petRect.height) + 80)
        let panelWidth: CGFloat = 286
        let gap: CGFloat = 12
        let height = max(ringSize, CGFloat(124))
        let totalWidth = ringSize + gap + panelWidth
        let ringLeftOnScreen = petRect.midX - ringSize / 2
        let ringBottomOnScreen = petRect.midY - ringSize / 2

        var windowX: CGFloat
        var ringX: CGFloat
        var panelX: CGFloat

        if ringLeftOnScreen + totalWidth > screenFrame.maxX {
            windowX = ringLeftOnScreen - gap - panelWidth
            ringX = panelWidth + gap
            panelX = 0
        } else {
            windowX = ringLeftOnScreen
            ringX = 0
            panelX = ringSize + gap
        }

        windowX = min(max(windowX, screenFrame.minX), screenFrame.maxX - totalWidth)
        let windowY = min(max(ringBottomOnScreen, screenFrame.minY), screenFrame.maxY - height)

        overlayView.ringSize = ringSize
        overlayView.ringX = ringX
        overlayView.panelX = panelX
        overlayView.panelWidth = panelWidth
        overlayView.frame = NSRect(x: 0, y: 0, width: totalWidth, height: height)
        window.setFrame(NSRect(x: windowX, y: windowY, width: totalWidth, height: height), display: true)
    }
}

enum Shell {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func capture(_ executable: String, arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return Result(status: 127, stdout: "", stderr: error.localizedDescription)
        }

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Result(status: process.terminationStatus, stdout: out, stderr: err)
    }
}

enum AppBundle {
    static func install(paths: Paths) throws {
        try paths.ensureAppDir()
        let contents = paths.appBundle.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        let source = ProcessControl.executableURL()
        let destination = paths.appBundleExecutable
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: destination.path
        )

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleIdentifier</key>
          <string>dev.jimmyasksai.codex-pet-usage-overlay</string>
          <key>CFBundleName</key>
          <string>Codex Pet Usage Overlay</string>
          <key>CFBundleExecutable</key>
          <string>codex-pet-usage-overlay-mac</string>
          <key>CFBundlePackageType</key>
          <string>APPL</string>
          <key>CFBundleVersion</key>
          <string>1</string>
          <key>CFBundleShortVersionString</key>
          <string>1.0</string>
          <key>LSUIElement</key>
          <true/>
        </dict>
        </plist>
        """
        try plist.write(to: paths.appBundleInfoPlist, atomically: true, encoding: .utf8)
    }
}

enum ProcessControl {
    static func executableURL() -> URL {
        let raw = CommandLine.arguments[0]
        let url = URL(fileURLWithPath: raw)
        if raw.hasPrefix("/") {
            return url.standardizedFileURL
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(raw)
            .standardizedFileURL
    }

    static func runningPid(paths: Paths) -> pid_t? {
        guard let text = try? String(contentsOf: paths.pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else {
            return nil
        }
        if processExists(pid) {
            let command = commandLine(pid: pid)
            if command.isEmpty || command.contains("codex-pet-usage-overlay-mac") {
                return pid
            }
        }
        return nil
    }

    static func processExists(_ pid: pid_t) -> Bool {
        errno = 0
        let probe = kill(pid, 0)
        return probe == 0 || errno == EPERM
    }

    static func commandLine(pid: pid_t) -> String {
        let result = Shell.capture("/bin/ps", arguments: ["-p", "\(pid)", "-o", "command="])
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func start(options: Options, paths: Paths) throws {
        try paths.ensureAppDir()
        if let pid = runningPid(paths: paths) {
            print("Already running. PID: \(pid)")
            return
        }

        try AppBundle.install(paths: paths)
        let openResult = Shell.capture("/usr/bin/open", arguments: ["-n", paths.appBundle.path, "--args"] + options.runArguments())
        if openResult.status == 0 {
            for _ in 0..<30 {
                usleep(100_000)
                if let pid = runningPid(paths: paths) {
                    print("Started Codex pet usage overlay. PID: \(pid)")
                    return
                }
            }
            print("Started Codex pet usage overlay via app bundle.")
            return
        }

        let executable = executableURL()
        let process = Process()
        process.executableURL = executable
        process.arguments = options.runArguments()

        if !FileManager.default.fileExists(atPath: paths.logFile.path) {
            FileManager.default.createFile(atPath: paths.logFile.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: paths.logFile)
        log.seekToEndOfFile()
        process.standardOutput = log
        process.standardError = log

        try process.run()
        try "\(process.processIdentifier)\n".write(to: paths.pidFile, atomically: true, encoding: .utf8)
        print("Started Codex pet usage overlay. PID: \(process.processIdentifier)")
    }

    static func stop(paths: Paths) {
        guard let pid = runningPid(paths: paths) else {
            try? FileManager.default.removeItem(at: paths.pidFile)
            print("Codex pet usage overlay is not running.")
            return
        }

        if kill(pid, SIGTERM) != 0 {
            _ = Shell.capture("/bin/kill", arguments: ["-TERM", "\(pid)"])
        }
        for _ in 0..<20 {
            usleep(100_000)
            if !processExists(pid) { break }
        }
        if processExists(pid) {
            if kill(pid, SIGKILL) != 0 {
                _ = Shell.capture("/bin/kill", arguments: ["-KILL", "\(pid)"])
            }
        }
        try? FileManager.default.removeItem(at: paths.pidFile)
        print("Stopped Codex pet usage overlay. PID: \(pid)")
    }

    static func status(options: Options, paths: Paths) {
        let state = CodexStateReader(codexHome: options.codexHome)
        let running = runningPid(paths: paths)
        let startupExists = FileManager.default.fileExists(atPath: paths.launchAgentFile.path)
        let latestLog = (try? String(contentsOf: paths.logFile, encoding: .utf8))?
            .split(separator: "\n")
            .last
            .map(String.init) ?? ""

        print("Running: \(running != nil)")
        print("ProcessId: \(running.map(String.init) ?? "-")")
        print("PidFile: \(paths.pidFile.path)")
        print("LogFile: \(paths.logFile.path)")
        print("StartupEnabled: \(startupExists)")
        print("StartupPlist: \(paths.launchAgentFile.path)")
        print("CodexHome: \(options.codexHome.path)")
        print("CodexStateFile: \(FileManager.default.fileExists(atPath: state.stateURL.path))")
        print("PetOverlayOpen: \(state.isPetOpen())")
        if !latestLog.isEmpty {
            print("LatestLog: \(latestLog)")
        }
    }
}

enum Startup {
    static let label = "dev.jimmyasksai.codex-pet-usage-overlay"

    static func install(options: Options, paths: Paths) throws {
        try installExecutable(paths: paths)
        let executable = paths.installedExecutable.path
        let plist = launchAgentPlist(executable: executable, options: options, paths: paths)
        try FileManager.default.createDirectory(at: paths.launchAgentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist.write(to: paths.launchAgentFile, atomically: true, encoding: .utf8)

        _ = Shell.capture("/bin/launchctl", arguments: ["bootout", "gui/\(getuid())", paths.launchAgentFile.path])
        let result = Shell.capture("/bin/launchctl", arguments: ["bootstrap", "gui/\(getuid())", paths.launchAgentFile.path])
        if result.status != 0 {
            print("Installed startup plist: \(paths.launchAgentFile.path)")
            print("launchctl bootstrap failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            return
        }
        print("Installed startup plist: \(paths.launchAgentFile.path)")
    }

    private static func installExecutable(paths: Paths) throws {
        try paths.ensureAppDir()
        let source = ProcessControl.executableURL()
        let destination = paths.installedExecutable

        if source.standardizedFileURL.path != destination.standardizedFileURL.path {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: destination.path
        )
        print("Installed executable: \(destination.path)")
    }

    static func uninstall(paths: Paths) {
        _ = Shell.capture("/bin/launchctl", arguments: ["bootout", "gui/\(getuid())", paths.launchAgentFile.path])
        if FileManager.default.fileExists(atPath: paths.launchAgentFile.path) {
            try? FileManager.default.removeItem(at: paths.launchAgentFile)
            print("Removed startup plist: \(paths.launchAgentFile.path)")
        } else {
            print("Startup plist not found: \(paths.launchAgentFile.path)")
        }
    }

    private static func launchAgentPlist(executable: String, options: Options, paths: Paths) -> String {
        let args = [
            executable,
            "run",
            "--usage-poll-seconds", "\(Int(options.usagePollSeconds))",
            "--pet-poll-ms", "\(Int(options.petPollMilliseconds))",
            "--hover-padding-px", "\(Int(options.hoverPadding))",
            "--codex-home", options.codexHome.path
        ]
        let argXml = args.map { "<string>\(xmlEscape($0))</string>" }.joined(separator: "\n        ")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(label)</string>
          <key>ProgramArguments</key>
          <array>
            \(argXml)
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>StandardOutPath</key>
          <string>\(xmlEscape(paths.logFile.path))</string>
          <key>StandardErrorPath</key>
          <string>\(xmlEscape(paths.logFile.path))</string>
        </dict>
        </plist>
        """
    }

    private static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

enum SelfTest {
    static func run() throws {
        let payload: [String: Any] = [
            "rate_limit": [
                "primary_window": ["used_percent": 37.0, "limit_window_seconds": 18_000.0, "reset_after_seconds": 90.0],
                "secondary_window": ["used_percent": 52.0, "limit_window_seconds": 604_800.0, "reset_after_seconds": 120.0]
            ]
        ]
        guard let usage = UsageParser.convert(payload: payload, source: "test"),
              abs((usage.primaryRemaining ?? 0) - 63) < 0.01,
              abs((usage.secondaryRemaining ?? 0) - 48) < 0.01 else {
            throw NSError(domain: "SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "usage payload parse failed"])
        }

        let body = #"prefix {"type":"codex.rate_limits","rate_limits":{"primary_window":{"used_percent":25,"limit_window_seconds":18000,"reset_after_seconds":60},"secondary_window":{"remaining_percent":88,"limit_window_seconds":604800,"reset_after_seconds":120}}} suffix"#
        guard let logUsage = UsageParser.convertLogBodyToUsage(body),
              abs((logUsage.primaryRemaining ?? 0) - 75) < 0.01,
              abs((logUsage.secondaryRemaining ?? 0) - 88) < 0.01 else {
            throw NSError(domain: "SelfTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "log body parse failed"])
        }

        let converted = CoordinateSpace.appKitRect(
            fromElectronTopLeft: CGRect(x: 10, y: 20, width: 30, height: 40),
            displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            primaryDisplayHeight: 1080
        )
        if converted.width != 30 || converted.height != 40 {
            throw NSError(domain: "SelfTest", code: 3, userInfo: [NSLocalizedDescriptionKey: "coordinate conversion failed"])
        }

        print("SelfTest OK")
    }
}

@main
struct Main {
    static func main() {
        let options = Options.parse(CommandLine.arguments)
        let paths = Paths.current()

        do {
            switch options.command {
            case "start":
                try ProcessControl.start(options: options, paths: paths)
            case "stop":
                ProcessControl.stop(paths: paths)
            case "status":
                ProcessControl.status(options: options, paths: paths)
            case "install-startup":
                try Startup.install(options: options, paths: paths)
            case "uninstall-startup":
                Startup.uninstall(paths: paths)
            case "self-test":
                try SelfTest.run()
            case "run":
                let controller = OverlayController(options: options, paths: paths)
                try controller.run()
            default:
                print("Unknown command: \(options.command)")
                print("Commands: start, stop, status, install-startup, uninstall-startup, self-test")
                exit(2)
            }
        } catch {
            FileHandle.standardError.write("Error: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
