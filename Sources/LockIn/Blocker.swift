import AppKit
import Carbon
import LockInCore

@MainActor final class Blocker: ObservableObject {
    @Published var status = "Ready · click Enable browser blocking to give Lock In browser access"
    @Published var blockedCount = 0
    @Published var needsAttention = false
    @Published var requestingPermission = false
    private var busy = false
    private var cadence = BrowserScanCadence()
    private var activeProfile: Profile?
    private var scanTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private let scripts = BrowserScanScripts()
    private var currentCheck: CancellationFlag?
    private let queue = DispatchQueue(label: "app.lockin.browser-control")
    /// Supported browsers by bundle ID. Safari's AppleScript addresses tabs by index; the Chromium browsers by id.
    struct Browser: Sendable {
        let name: String
        let isSafari: Bool
    }
    nonisolated static let browsers: [String: Browser] = [
        "com.apple.Safari": Browser(name: "Safari", isSafari: true),
        "com.google.Chrome": Browser(name: "Chrome", isSafari: false),
        "com.brave.Browser": Browser(name: "Brave", isSafari: false),
        "com.microsoft.edgemac": Browser(name: "Edge", isSafari: false),
        "com.vivaldi.Vivaldi": Browser(name: "Vivaldi", isSafari: false),
        "company.thebrowser.Browser": Browser(name: "Arc", isSafari: false)
    ]
    func requestBrowserAccess() {
        guard !requestingPermission else { return }
        let ids = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).filter { Self.browsers[$0] != nil }
        guard !ids.isEmpty else { status = "Open a supported browser, then enable browser blocking."; needsAttention = true; return }
        requestingPermission = true
        queue.async { [weak self] in
            let failures = ids.compactMap { id -> String? in
                let code = Self.permission(id, ask: true)
                return code == noErr ? nil : Self.permissionMessage(id, code: code)
            }
            Task { @MainActor [weak self] in
                self?.requestingPermission = false
                self?.needsAttention = !failures.isEmpty
                self?.status = failures.isEmpty ? "Browser access granted. Protection runs during work." : failures.joined(separator: " · ")
                self?.cadence.reset()
                self?.scan(force: true)
            }
        }
    }
    nonisolated private static func permission(_ id: String, ask: Bool) -> OSStatus {
        var descriptor = AEAddressDesc()
        let bytes = Array(id.utf8)
        let result = bytes.withUnsafeBytes { AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, bytes.count, &descriptor) }
        guard result == noErr else { return OSStatus(result) }
        defer { AEDisposeDesc(&descriptor) }
        return AEDeterminePermissionToAutomateTarget(&descriptor, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }
    nonisolated static func name(of id: String) -> String { browsers[id]?.name ?? id }
    nonisolated static func permissionMessage(_ id: String, code: OSStatus) -> String {
        let name = name(of: id)
        if code == -1744 { return "\(name): permission not requested. Click Enable browser blocking." }
        if code == -1743 { return "\(name): Automation access denied (-1743). Enable Lock In → \(name) in System Settings → Privacy & Security → Automation." }
        return "\(name): browser access failed (\(code))."
    }
    nonisolated private static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    /// A script that sends one tab to the block page, but only if it still shows `url`: the tab may have moved on
    /// since the scan. The script returns true if it redirected; a tab that has since closed (-1728) isn't an error.
    nonisolated private static func redirect(id: String, tab: String, from url: String, to destination: String) -> NSAppleScript? {
        NSAppleScript(source: """
        with timeout of 5 seconds
            tell application id "\(id)"
                try
                    set targetTab to \(tab)
                    if URL of targetTab is \(literal(url)) then
                        set URL of targetTab to \(literal(destination))
                        return true
                    end if
                on error errorText number errorCode
                    if errorCode is not -1728 then error errorText number errorCode
                end try
                return false
            end tell
        end timeout
        """)
    }
    nonisolated private static func failure(_ id: String, error: NSDictionary?) -> String {
        let code = error?[NSAppleScript.errorNumber] as? Int ?? 0
        let detail = error?[NSAppleScript.errorMessage] as? String ?? "AppleScript could not run"
        return "\(name(of: id)): \(detail) (\(code))"
    }
    func deactivate() {
        currentCheck?.cancel()
        activeProfile = nil
        scanTimer?.invalidate(); scanTimer = nil
        if let observer = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        activationObserver = nil
        cadence.reset()
        if !needsAttention { status = "Protection paused · no browser or app restrictions" }
    }
    func enforce(profile: Profile) {
        let changed = activeProfile != profile
        activeProfile = profile
        if scanTimer == nil {
            let timer = Timer(timeInterval: BrowserScanCadence.foregroundInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.scan() }
            }
            timer.tolerance = 0.025
            RunLoop.main.add(timer, forMode: .common)
            scanTimer = timer
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scan(force: true) }
            }
        }
        if changed { cadence.reset(); scan(force: true) }
        // Hide rather than force-quit: unsaved documents remain intact.
        for app in NSWorkspace.shared.runningApplications where profile.applications.contains(where: { $0.bundleID == app.bundleIdentifier }) {
            if !app.isHidden { app.hide(); blockedCount += 1 }
        }
    }
    private func scan(force: Bool = false) {
        guard let profile = activeProfile, !requestingPermission, !busy else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let allTabs = cadence.next(at: ProcessInfo.processInfo.systemUptime,
            browserIsFrontmost: frontmost.map { Self.browsers[$0] != nil } ?? false, force: force) else { return }
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            .filter { Self.browsers[$0] != nil && (allTabs || $0 == frontmost) }
            .sorted { $0 == frontmost && $1 != frontmost }
        guard !running.isEmpty else { return }
        busy = true
        let check = CancellationFlag()
        currentCheck = check
        let destination = Bundle.main.url(forResource: "blocked", withExtension: "html")?.absoluteString ?? "about:blank"
        let scripts = self.scripts
        let rules = WebsiteRules(profile.websites, mode: profile.blockingMode)
        queue.async { [weak self] in
            var failures: [String] = []; var blocked = 0
            for id in running {
                guard !check.isCancelled else { break }
                let permission = Self.permission(id, ask: false)
                guard permission == noErr else { failures.append(Self.permissionMessage(id, code: permission)); continue }
                let safari = Self.browsers[id]?.isSafari == true
                var error: NSDictionary?
                guard let script = scripts.scan(id: id, safari: safari, allTabs: allTabs) else { failures.append("\(Self.name(of: id)): could not prepare browser scan"); continue }
                let result = script.executeAndReturnError(&error)
                if error != nil { failures.append(Self.failure(id, error: error)); continue }
                let rows = (0..<result.numberOfItems).map { index in
                    (1...3).map { result.atIndex(index + 1)?.atIndex($0)?.stringValue }
                }
                let scanned = Self.tabsToBlock(rows, rules: rules)
                if scanned.unaddressable > 0 { failures.append("\(Self.name(of: id)): unexpected browser tab identifier") }
                for found in scanned.tabs {
                    guard !check.isCancelled else { break }
                    let tab = safari ? "tab \(found.tab) of window id \(found.window)" : "tab id \(Self.literal(found.tab)) of window id \(Self.literal(found.window))"
                    error = nil
                    guard let script = Self.redirect(id: id, tab: tab, from: found.url, to: BlockPage.destination(base: destination, original: found.url)) else { failures.append("\(Self.name(of: id)): could not prepare redirect"); continue }
                    let redirected = script.executeAndReturnError(&error)
                    if error != nil { failures.append(Self.failure(id, error: error)) }
                    else if redirected.booleanValue { blocked += 1 }
                }
            }
            let result = failures.isEmpty ? BrowserScanCadence.activeStatus : failures.joined(separator: " · ")
            Task { @MainActor [weak self] in
                self?.busy = false; self?.blockedCount += blocked
                if !check.isCancelled { self?.status = result; self?.needsAttention = !failures.isEmpty }
            }
        }
    }
}

extension Blocker {
    struct ScannedTab: Equatable {
        var window: String, tab: String, url: String
    }
    /// From a scan's rows of window ID, tab ID and URL: the tabs `rules` block, and how many of those had IDs that
    /// can't be safely put into a redirect script.
    nonisolated static func tabsToBlock(_ rows: [[String?]], rules: WebsiteRules) -> (tabs: [ScannedTab], unaddressable: Int) {
        var tabs: [ScannedTab] = [], unaddressable = 0
        for row in rows {
            guard row.count == 3, let window = row[0], let tab = row[1], let raw = row[2],
                  let url = URL(string: raw), rules.shouldBlock(url) else { continue }
            guard Int(window) != nil, Int(tab) != nil else { unaddressable += 1; continue }
            tabs.append(ScannedTab(window: window, tab: tab, url: raw))
        }
        return (tabs, unaddressable)
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// Pure cadence policy; the caller never advances it while a scan is still running.
struct BrowserScanCadence {
    static let foregroundInterval = 0.25
    static let backgroundInterval = 2.0
    static let activeStatus = "Browser protection active · foreground checks every \(Int(foregroundInterval * 1000)) ms; background sweep every \(Int(backgroundInterval)) seconds"
    private var lastForeground = -Double.infinity
    private var lastBackground = -Double.infinity
    mutating func reset() { lastForeground = -.infinity; lastBackground = -.infinity }
    /// nil = idle, false = front tab only, true = all tabs.
    mutating func next(at time: Double, browserIsFrontmost: Bool, force: Bool = false) -> Bool? {
        if time - lastBackground >= Self.backgroundInterval {
            lastBackground = time; lastForeground = time; return true
        }
        if browserIsFrontmost && (force || time - lastForeground >= Self.foregroundInterval) {
            lastForeground = time; return false
        }
        return nil
    }
}

/// Only accessed on Blocker's serial worker queue. Reuse compiled read scripts.
private final class BrowserScanScripts: @unchecked Sendable {
    private var cache: [String: NSAppleScript] = [:]
    func scan(id: String, safari: Bool, allTabs: Bool) -> NSAppleScript? {
        let key = id + (allTabs ? ":all" : ":front")
        if let existing = cache[key] { return existing }
        let body: String
        if allTabs {
            let tabID = safari ? "tabIndex as text" : "(id of browserTab) as text"
            body = """
            set foundTabs to {}
            repeat with browserWindow in windows
                repeat with tabIndex from 1 to (count of tabs of browserWindow)
                    set browserTab to tab tabIndex of browserWindow
                    set end of foundTabs to {(id of browserWindow) as text, \(tabID), URL of browserTab}
                end repeat
            end repeat
            return foundTabs
            """
        } else {
            let tab = safari ? "current tab" : "active tab"
            let tabID = safari ? "(index of browserTab) as text" : "(id of browserTab) as text"
            body = """
            if (count of windows) = 0 then return {}
            set browserWindow to front window
            set browserTab to \(tab) of browserWindow
            return {{(id of browserWindow) as text, \(tabID), URL of browserTab}}
            """
        }
        let source = """
        with timeout of \(allTabs ? 2 : 1) seconds
            tell application id "\(id)"
                \(body)
            end tell
        end timeout
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        cache[key] = script
        return script
    }
}
