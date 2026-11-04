import Foundation

/// Lock In's files, all in ~/.lockin:
/// - `settings.json`: profiles, the next session's plan and the app's bookkeeping (`SettingsFile`).
/// - `sessions/*.json`: one file per session (`SessionFile`). These are the record of your work.
///   A file is named after when its session started, in local time to the minute, e.g. `2026-11-04T09-00.json`.
///   The name is for people: sessions are identified by the `id` inside, so a renamed file still loads.
/// The app writes these; the `lockin` CLI only reads them.
public enum Storage {
    public static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lockin")

    public static func settingsFile(in directory: URL) -> URL { directory.appendingPathComponent("settings.json") }
    public static func sessionsDirectory(in directory: URL) -> URL { directory.appendingPathComponent("sessions", isDirectory: true) }

    /// Everything Lock In has saved.
    public struct Contents {
        public var preferences = SavedState()
        public var journal = JournalState()
        /// When the app last confirmed the open session was running; nil if there's no open session.
        public var checkpoint: Date?
        /// Session files that couldn't be read. They're left exactly as they are.
        public var skipped: [String] = []
        /// Where each session was read from, so changes are written back to the same file.
        public var sessionFiles: [UUID: URL] = [:]
        public init() {}
    }

    /// Reads ~/.lockin. Throws if settings can't be read, since saving over them would lose data;
    /// a session file that can't be read is skipped and reported instead. Nothing saved yet reads as a fresh start.
    public static func load(from directory: URL) throws -> Contents {
        var contents = Contents()
        let settings = settingsFile(in: directory)
        if FileManager.default.fileExists(atPath: settings.path) {
            do {
                let file = try FileFormat.decode(SettingsFile.self, from: Data(contentsOf: settings), supported: FileFormat.settingsVersion)
                contents.preferences = file.preferences
                contents.journal = file.journal
            } catch { throw ReadError(file: settings, underlying: error) }
        }
        var seen = Set<UUID>()
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDirectory(in: directory), includingPropertiesForKeys: nil)) ?? []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "json" {
            do {
                let session = try FileFormat.decode(SessionFile.self, from: Data(contentsOf: url), supported: FileFormat.sessionVersion)
                // The schema requires one; the timeline code assumes it.
                guard !session.intervals.isEmpty else {
                    contents.skipped.append("\(url.lastPathComponent): a session needs at least one interval.")
                    continue
                }
                guard seen.insert(session.id).inserted else {
                    contents.skipped.append("\(url.lastPathComponent): another file has the same session id.")
                    continue
                }
                contents.journal.sessions.append(session.log)
                contents.sessionFiles[session.id] = url
                if session.endedAt == nil {
                    // A hand-edited file may have lost its checkpoint; when it was last written is the next best thing.
                    contents.checkpoint = session.checkpointAt ?? modified(url)
                }
            } catch {
                contents.skipped.append("\(url.lastPathComponent): \(describe(error))")
            }
        }
        contents.journal.sessions.sort { $0.startedAt < $1.startedAt }
        return contents
    }

    public struct ReadError: LocalizedError {
        public let file: URL
        public let underlying: Error
        public var errorDescription: String? { "Couldn't read \(file.path): \(Storage.describe(underlying))" }
    }

    /// Decoding errors name the field that's wrong, not just "the data couldn't be read".
    static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return keys.isEmpty ? "" : " at \(keys.joined(separator: "."))"
        }
        switch error {
        case .keyNotFound(let key, let context): return "missing “\(key.stringValue)”\(path(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return context.debugDescription + path(context)
        @unknown default: return error.localizedDescription
        }
    }

    private static func modified(_ url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}

/// Writes ~/.lockin, touching only what changed: a finished session's file is written once, and the open
/// session's on every checkpoint. Files it didn't write, such as ones that couldn't be read, are never touched.
public final class StorageWriter {
    public let directory: URL
    /// Each session as last written (or read), so unchanged sessions are skipped.
    private var written: [UUID: WorkLog]
    private var writtenSettings: SettingsFile?
    private var files: [UUID: URL]
    private let names: DateFormatter

    /// `contents` is what was read, which is already on disk. `timeZone` is for naming new session files.
    public init(directory: URL, contents: Storage.Contents = Storage.Contents(), timeZone: TimeZone = .current) {
        self.directory = directory
        written = Dictionary(contents.journal.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        writtenSettings = SettingsFile(preferences: contents.preferences, journal: contents.journal)
        files = contents.sessionFiles
        names = DateFormatter()
        names.locale = Locale(identifier: "en_US_POSIX")
        names.timeZone = timeZone
        // Hyphens, not colons: Finder shows a colon in a file name as a slash.
        names.dateFormat = "yyyy-MM-dd'T'HH-mm"
    }

    /// The file a session is saved in, once it has been written or read.
    public func file(for id: UUID) -> URL? { files[id] }

    /// Session files first, then settings: if writing stops partway, the sessions are the more important record,
    /// and everything settings refers to already exists.
    public func write(preferences: SavedState, journal: JournalState, checkpoint: Date) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: Storage.sessionsDirectory(in: directory), withIntermediateDirectories: true)
        for log in journal.sessions where log.endedAt == nil || written[log.id] != log {
            let url = files[log.id] ?? newFile(startedAt: log.startedAt)
            try data(SessionFile(log, checkpoint: checkpoint)).write(to: url, options: .atomic)
            written[log.id] = log; files[log.id] = url
        }
        // Sessions removed from the journal, e.g. by undoing a backfill. Only files this writer knows are removed.
        let current = Set(journal.sessions.map(\.id))
        for id in written.keys where !current.contains(id) {
            if let url = files[id] { try? manager.removeItem(at: url) }
            written[id] = nil; files[id] = nil
        }
        let settings = SettingsFile(preferences: preferences, journal: journal)
        guard settings != writtenSettings || !manager.fileExists(atPath: Storage.settingsFile(in: directory).path) else { return }
        try data(settings).write(to: Storage.settingsFile(in: directory), options: .atomic)
        writtenSettings = settings
    }

    /// Named after the start, e.g. `2026-11-04T09-00.json`; a second session started the same minute is
    /// `2026-11-04T09-00.2.json`. The name is never changed afterwards, even if a backfill moves the start.
    private func newFile(startedAt: Date) -> URL {
        let base = names.string(from: startedAt)
        let taken = Set(files.values.map(\.lastPathComponent))
        let folder = Storage.sessionsDirectory(in: directory)
        var number = 1
        while true {
            let name = number == 1 ? "\(base).json" : "\(base).\(number).json"
            let url = folder.appendingPathComponent(name)
            if !taken.contains(name) && !FileManager.default.fileExists(atPath: url.path) { return url }
            number += 1
        }
    }

    private func data<T: Encodable>(_ value: T) throws -> Data { try FileFormat.encoder.encode(value) + Data("\n".utf8) }
}
