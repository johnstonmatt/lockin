import Foundation
import Combine
import LockInCore

@MainActor final class AppUpdater: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var status = "Check for the latest release of Lock In."
    let currentVersion: String?
    let canInstall: Bool
    private let fetchLatest: () async throws -> String
    private let installLatest: () async throws -> String

    init(currentVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         helper: URL? = CommandLineTool.helper,
         fetchLatest: @escaping () async throws -> String = AppUpdater.latestVersion,
         installLatest: (() async throws -> String)? = nil) {
        self.currentVersion = currentVersion
        canInstall = helper != nil
        self.fetchLatest = fetchLatest
        self.installLatest = installLatest ?? {
            guard let helper else { throw CommandLineTool.Failure("This build doesn't include the updater. Install a packaged release to update from the app.") }
            // Keep the installer outside the app process: it must survive the app quitting for replacement.
            return try await Task.detached {
                // A pipe would lose its reader when the app quits and could terminate the installer
                // with SIGPIPE. A file keeps receiving output after the parent exits.
                let log = FileManager.default.temporaryDirectory.appendingPathComponent("lockin-update-\(UUID().uuidString).log")
                FileManager.default.createFile(atPath: log.path, contents: nil)
                let output = try FileHandle(forWritingTo: log)
                defer {
                    try? output.close()
                    try? FileManager.default.removeItem(at: log)
                }
                let process = Process()
                process.executableURL = helper
                process.arguments = ["upgrade"]
                process.standardOutput = output
                process.standardError = output
                try process.run()
                process.waitUntilExit()
                let data = try Data(contentsOf: log)
                let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard process.terminationStatus == 0 else {
                    throw CommandLineTool.Failure(message.isEmpty ? "The update couldn't be installed. Please try again." : message)
                }
                return message.isEmpty ? "Update finished." : message
            }.value
        }
    }

    func check() async {
        guard !busy else { return }
        availableVersion = nil
        guard let currentVersion else {
            status = "This development build has no release version. Install a packaged release to check for updates."
            return
        }
        busy = true
        status = "Checking for updates…"
        defer { busy = false }
        do {
            let latest = try await fetchLatest()
            if ReleaseVersion.compare(currentVersion, latest) == .orderedAscending {
                availableVersion = latest
                status = "Lock In \(latest) is available. You’re running \(currentVersion)."
            } else {
                status = "You’re up to date. Lock In \(currentVersion) is installed."
            }
        } catch { status = "Couldn't check for updates: \(error.localizedDescription)" }
    }

    func install(locked: Bool) async {
        guard !busy, availableVersion != nil, canInstall else { return }
        guard !locked else {
            status = Store.hardcoreQuitMessage
            return
        }
        busy = true
        status = "Downloading and installing the latest release… Lock In will restart."
        defer { busy = false }
        do {
            status = try await installLatest()
            availableVersion = nil
        } catch { status = "Couldn't install the update: \(error.localizedDescription)" }
    }

    nonisolated static func latestVersion() async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: ReleaseVersion.latestReleaseRequest())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try ReleaseVersion.latestRelease(from: data, statusCode: status).version
    }
}
