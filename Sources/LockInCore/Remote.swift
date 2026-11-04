import Foundation

/// The `lockin` command line tool drives the running app with distributed notifications: one request, one reply.
/// The app owns the journal and checkpoints it continuously, so the CLI never writes the journal files itself.
public enum RemoteCommand: Codable, Equatable, Sendable {
    /// No-op used to check the app is listening, e.g. while it launches.
    case ping
    case start(hours: Double?)
    case pause(reason: String)
    case takeBreak
    case resume
    case finish
    case end(reason: String)
    case addTask(title: String, link: String)
    /// Nil keeps the task's current value.
    case updateTask(id: UUID, title: String?, link: String?)
    case setTaskCompleted(id: UUID, completed: Bool)
    case deleteTask(id: UUID)
    /// Records the range as work afterwards; see `JournalState.backfill`.
    case backfill(start: Date, end: Date)
    case undoBackfill
    /// Records a note on the running session.
    case addEvent(text: String)
}

public struct RemoteReply: Codable, Equatable, Sendable {
    public var ok: Bool
    public var message: String
    public init(ok: Bool, message: String) { self.ok = ok; self.message = message }
    public static func success(_ message: String) -> RemoteReply { RemoteReply(ok: true, message: message) }
    public static func failure(_ message: String) -> RemoteReply { RemoteReply(ok: false, message: message) }
}

/// Wire format. Distributed notifications only carry property-list values, so payloads are JSON strings.
/// The notification `object` is the request ID, which the reply echoes so concurrent CLI calls don't cross.
///
/// Distributed notifications are system-wide, so the channel's name is what keeps listeners apart:
/// the CLI and the app use `.app`, and tests use a channel of their own so a running Lock In can't hear them.
public struct RemoteChannel: Sendable {
    public static let app = RemoteChannel(name: "app.lockin.mac.remote")
    public let request: Notification.Name
    public let reply: Notification.Name
    public init(name: String) {
        request = Notification.Name(name + ".request")
        reply = Notification.Name(name + ".reply")
    }
    public static let payloadKey = "payload"

    public static func encode<T: Encodable>(_ value: T) -> [String: String] {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return [payloadKey: String(decoding: data, as: UTF8.self)]
    }
    public static func decode<T: Decodable>(_ type: T.Type, from userInfo: [AnyHashable: Any]?) -> T? {
        guard let text = userInfo?[payloadKey] as? String else { return nil }
        return try? JSONDecoder().decode(type, from: Data(text.utf8))
    }
}
