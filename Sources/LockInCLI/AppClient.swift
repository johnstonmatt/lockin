import AppKit
import LockInCore

/// Talks to the Lock In app: reads its files for status, and sends it commands to change anything.
enum AppClient {
    static let bundleID = "app.lockin.mac"

    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    /// The journal as the app last saved it. A missing file means Lock In hasn't been used yet.
    static func snapshot() throws -> Snapshot {
        let contents: Storage.Contents
        do { contents = try Storage.load(from: Storage.directory) }
        catch { throw UsageError(error.localizedDescription) }
        for problem in contents.skipped { FileHandle.standardError.write(Data("lockin: skipped sessions/\(problem)\n".utf8)) }
        let running = isRunning
        // Without the app, nothing is counting: on relaunch the gap since the checkpoint becomes a pause.
        return Snapshot(journal: contents.journal, locked: contents.preferences.session?.locked == true, appRunning: running,
                        asOf: running ? Date() : contents.checkpoint ?? Date())
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
        // Set on this thread's run loop by the observer.
        let reply = Box<RemoteReply?>(nil)
        let observer = center.addObserver(forName: RemoteChannel.app.reply, object: id, queue: nil) { note in
            reply.value = RemoteChannel.decode(RemoteReply.self, from: note.userInfo)
        }
        defer { center.removeObserver(observer) }
        center.postNotificationName(RemoteChannel.app.request, object: id, userInfo: RemoteChannel.encode(command), deliverImmediately: true)
        let deadline = Date().addingTimeInterval(timeout)
        while reply.value == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.05)))
        }
        return reply.value
    }
}

/// A mutable value shared with a callback that runs on another thread or later on this one.
/// Each use reads it only after the callback is done writing, which is why it can be `@unchecked Sendable`.
final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
