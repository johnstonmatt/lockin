import Foundation

/// Lock In's files, all in ~/.lockin:
/// - `settings.json`: profiles, the next session's plan and the app's bookkeeping (`SettingsFile`).
/// - `sessions/<id>.json`: one file per session (`SessionFile`). These are the record of your work.
/// - `legacy/`: files from before 1.0 (`state.json`, the YAML journals, the old preferences), kept after migrating.
/// The app writes these; the `lockin` CLI only reads them.
public enum Storage {
    public static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lockin")
    /// Where builds before 1.0 kept profiles.
    public static let legacyPreferencesFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LockIn/state.json")

    public static func settingsFile(in directory: URL) -> URL { directory.appendingPathComponent("settings.json") }
    public static func sessionsDirectory(in directory: URL) -> URL { directory.appendingPathComponent("sessions", isDirectory: true) }
    public static func sessionFile(_ id: UUID, in directory: URL) -> URL {
        sessionsDirectory(in: directory).appendingPathComponent("\(id.uuidString).json")
    }
    static func legacyJournal(in directory: URL) -> URL { directory.appendingPathComponent("state.json") }

    /// Everything Lock In has saved.
    public struct Contents {
        public var preferences = SavedState()
        public var journal = JournalState()
        /// When the app last confirmed the open session was running; nil if there's no open session.
        public var checkpoint: Date?
        /// Read from the pre-1.0 files, which the app migrates on its first save.
        public var isLegacy = false
        /// Session files that couldn't be read. They're left exactly as they are.
        public var skipped: [String] = []
        /// Where each session was read from, so changes are written back to the same file even if it was renamed.
        public var sessionFiles: [UUID: URL] = [:]
    }

    /// Reads ~/.lockin, or the pre-1.0 files if it hasn't been migrated yet. Throws if settings can't be read,
    /// since saving over them would lose data; a session file that can't be read is skipped and reported instead.
    public static func load(from directory: URL, legacyPreferences: URL?) throws -> Contents {
        let settings = settingsFile(in: directory)
        guard FileManager.default.fileExists(atPath: settings.path) else { return try loadLegacy(from: directory, legacyPreferences: legacyPreferences) }
        let file: SettingsFile
        do { file = try FileFormat.decode(SettingsFile.self, from: Data(contentsOf: settings), supported: FileFormat.settingsVersion) }
        catch { throw ReadError(file: settings, underlying: error) }
        var contents = Contents(preferences: file.preferences, journal: file.journal)
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

    private static func loadLegacy(from directory: URL, legacyPreferences: URL?) throws -> Contents {
        var contents = Contents()
        let journal = legacyJournal(in: directory)
        if FileManager.default.fileExists(atPath: journal.path) {
            do { contents.journal = try JSONDecoder().decode(JournalState.self, from: Data(contentsOf: journal)) }
            catch { throw ReadError(file: journal, underlying: error) }
            contents.isLegacy = true
            if contents.journal.openSession != nil { contents.checkpoint = modified(journal) }
        }
        if let preferences = legacyPreferences, FileManager.default.fileExists(atPath: preferences.path) {
            do { contents.preferences = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: preferences)) }
            catch { throw ReadError(file: preferences, underlying: error) }
            contents.isLegacy = true
        }
        return contents
    }

    /// Moves the pre-1.0 files into ~/.lockin/legacy once the new files are written. Nothing is deleted.
    public static func archiveLegacyFiles(in directory: URL, legacyPreferences: URL?) throws {
        let manager = FileManager.default
        var moves: [(URL, String)] = []
        if manager.fileExists(atPath: legacyJournal(in: directory).path) { moves.append((legacyJournal(in: directory), "state.json")) }
        let yaml = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        moves += yaml.filter { $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "yaml" }.map { ($0, $0.lastPathComponent) }
        if let preferences = legacyPreferences, manager.fileExists(atPath: preferences.path) { moves.append((preferences, "preferences.json")) }
        guard !moves.isEmpty else { return }
        let archive = directory.appendingPathComponent("legacy", isDirectory: true)
        try manager.createDirectory(at: archive, withIntermediateDirectories: true)
        for (source, name) in moves {
            var destination = archive.appendingPathComponent(name)
            // A second archive (say, after running an older build again) never replaces the first.
            if manager.fileExists(atPath: destination.path) {
                let stamp = Int(Date().timeIntervalSince1970)
                destination = archive.appendingPathComponent("\(destination.deletingPathExtension().lastPathComponent)-\(stamp).\(destination.pathExtension)")
            }
            try manager.moveItem(at: source, to: destination)
        }
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

    /// `contents` is what was read, which is already on disk; pass nil to write everything, as when migrating.
    public init(directory: URL, contents: Storage.Contents?) {
        self.directory = directory
        written = Dictionary((contents?.journal.sessions ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        writtenSettings = contents.map { SettingsFile(preferences: $0.preferences, journal: $0.journal) }
        files = contents?.sessionFiles ?? [:]
    }
    private func file(_ id: UUID) -> URL { files[id] ?? Storage.sessionFile(id, in: directory) }

    /// Session files first, then settings: if writing stops partway, the sessions are the more important record,
    /// and everything settings refers to already exists.
    public func write(preferences: SavedState, journal: JournalState, checkpoint: Date) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: Storage.sessionsDirectory(in: directory), withIntermediateDirectories: true)
        for log in journal.sessions where log.endedAt == nil || written[log.id] != log {
            try data(SessionFile(log, checkpoint: checkpoint)).write(to: file(log.id), options: .atomic)
            written[log.id] = log
        }
        // Sessions removed from the journal, e.g. by undoing a backfill. Only files this writer knows are removed.
        let current = Set(journal.sessions.map(\.id))
        for id in written.keys where !current.contains(id) {
            try? manager.removeItem(at: file(id))
            written[id] = nil; files[id] = nil
        }
        let settings = SettingsFile(preferences: preferences, journal: journal)
        guard settings != writtenSettings || !manager.fileExists(atPath: Storage.settingsFile(in: directory).path) else { return }
        try data(settings).write(to: Storage.settingsFile(in: directory), options: .atomic)
        writtenSettings = settings
    }

    private func data<T: Encodable>(_ value: T) throws -> Data { try FileFormat.encoder.encode(value) + Data("\n".utf8) }
}
