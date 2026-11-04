import AppKit
import LockInCore

/// Talks to the Lock In app: reads its files for status, and sends it commands to change anything.
enum AppClient {
    static let bundleID = "app.lockin.mac"
    static let journalDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lockin")
    static let preferencesFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LockIn/state.json")

    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    /// The journal as the app last saved it. A missing file means Lock In hasn't been used yet.
    static func snapshot() throws -> Snapshot {
        let file = journalDirectory.appendingPathComponent("state.json")
        var journal = JournalState()
        var checkpoint = Date()
        if FileManager.default.fileExists(atPath: file.path) {
            do { journal = try JSONDecoder().decode(JournalState.self, from: Data(contentsOf: file)) }
            catch { throw UsageError("Couldn't read \(file.path): \(error.localizedDescription)") }
            checkpoint = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? checkpoint
        }
        let preferences = (try? Data(contentsOf: preferencesFile)).flatMap { try? JSONDecoder().decode(SavedState.self, from: $0) }
        let running = isRunning
        // Without the app, nothing is counting: on relaunch the gap since the checkpoint becomes a pause.
        return Snapshot(journal: journal, locked: preferences?.session?.locked == true, appRunning: running, asOf: running ? Date() : checkpoint)
    }

    static func open(background: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = (background ? ["-g"] : []) + ["-b", bundleID]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UsageError("Couldn't open Lock In. Is it installed?") }
    }

    /// Sends a command to the app, launching it in the background first if needed.
    static func send(_ command: RemoteCommand) throws -> RemoteReply {
        if !isRunning {
            try open(background: true)
            // Wait for the app to finish launching and start listening.
            let deadline = Date().addingTimeInterval(15)
            while request(.ping, timeout: 0.5) == nil {
                guard Date() < deadline else { throw UsageError("Lock In didn't respond after launching.") }
            }
        }
        guard let reply = request(command, timeout: 5) else {
            throw UsageError("Lock In didn't respond. Builds older than the CLI ignore its commands: reinstall with ./install-app.")
        }
        return reply
    }

    /// One request/reply round trip, or nil if no reply arrives in time.
    private static func request(_ command: RemoteCommand, timeout: TimeInterval) -> RemoteReply? {
        let center = DistributedNotificationCenter.default()
        let id = UUID().uuidString
        let box = ReplyBox()
        let observer = center.addObserver(forName: RemoteChannel.reply, object: id, queue: nil) { note in
            box.reply = RemoteChannel.decode(RemoteReply.self, from: note.userInfo)
        }
        defer { center.removeObserver(observer) }
        center.postNotificationName(RemoteChannel.request, object: id, userInfo: RemoteChannel.encode(command), deliverImmediately: true)
        let deadline = Date().addingTimeInterval(timeout)
        while box.reply == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.05)))
        }
        return box.reply
    }
}

/// The reply, set on this thread's run loop by the notification observer.
private final class ReplyBox: @unchecked Sendable { var reply: RemoteReply? }
