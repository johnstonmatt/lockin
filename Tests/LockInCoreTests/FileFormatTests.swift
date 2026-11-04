import XCTest
@testable import LockInCore

/// The ~/.lockin files: what they contain, that they match `Schemas/`, and that nothing is lost reading them back,
/// migrating to them, or writing them.
final class FileFormatTests: XCTestCase {
    /// Whole seconds, so dates survive the microsecond timestamps exactly and models can be compared with ==.
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let utc = TimeZone(identifier: "UTC")!
    private var directory: URL!
    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    // MARK: fixtures, with every optional field set somewhere

    func finishedSession() -> WorkLog {
        var first = Todo(title: "Ship it"); first.link = "https://linear.app/acme/issue/ABC-1"
        first.completed = true; first.rollForward = true; first.sourceTodoID = UUID()
        var log = WorkLog(todos: [first, Todo(title: "Quote: \"x\"\nnext line")], targetSeconds: 3600, now: start)
        log.intervals[0].backfilled = true
        log.transition(to: .pause, at: start.addingTimeInterval(600), reason: "Call: urgent")
        log.transition(to: .work, at: start.addingTimeInterval(900))
        log.intervals[2].backfilled = false
        log.transition(to: .break, at: start.addingTimeInterval(1800))
        log.transition(to: .overtime, at: start.addingTimeInterval(2100))
        _ = log.addEvent("Deployed to staging", at: start.addingTimeInterval(1000))
        _ = log.endEarly(reason: "Starting a new day", at: start.addingTimeInterval(4000))
        log.reviewed = true
        return log
    }

    func openSession() -> WorkLog {
        var log = WorkLog(todos: [Todo(title: "Open")], targetSeconds: 7200, now: start.addingTimeInterval(86_400))
        _ = log.addEvent("Started late", at: start.addingTimeInterval(86_500))
        return log
    }

    func preferences() -> SavedState {
        var profile = Profile(name: "Deep work", symbol: "mountain.2")
        profile.applications = [BlockedApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap")]
        profile.blockingMode = .allow
        profile.hooks = ["start": "say go", "stop": ""]
        profile.passwordSalt = "salt"; profile.passwordHash = "hash"
        var state = SavedState()
        state.profiles = [profile, Profile(name: "Light", symbol: "sun.max")]
        state.selectedProfileID = profile.id
        state.session = FocusSession(profile: profile, locked: true)
        return state
    }

    func journal() -> JournalState {
        var journal = JournalState()
        let finished = finishedSession(), open = openSession()
        journal.sessions = [finished, open]
        var planned = Todo(title: "Next"); planned.link = "https://github.com/acme/app/pull/3"
        journal.draft = [planned, Todo()]
        journal.hours = 2.5
        journal.pendingReviewID = finished.id
        journal.resumeAfterUpdateID = open.intervals[0].id
        journal.lastBackfill = BackfillRecord(sessionID: finished.id, createdSession: false, previousStartedAt: start,
                                              previousIntervals: finished.intervals, at: start.addingTimeInterval(5000))
        return journal
    }

    // MARK: schemas

    func testFilesMatchTheSchemas() throws {
        let validator = SchemaValidator()
        let journal = journal()
        for log in journal.sessions {
            let data = try FileFormat.encoder.encode(SessionFile(log, checkpoint: start.addingTimeInterval(90_000)))
            XCTAssertEqual(try validator.errors(data, against: "session-v1.schema.json"), [], "\(log.id)")
        }
        // A fresh session: no end, no events, no optional task fields.
        let fresh = try FileFormat.encoder.encode(SessionFile(WorkLog(todos: [], targetSeconds: 60, now: start), checkpoint: nil))
        XCTAssertEqual(try validator.errors(fresh, against: "session-v1.schema.json"), [])
        for (preferences, journal) in [(preferences(), journal), (SavedState(), JournalState())] {
            let data = try FileFormat.encoder.encode(SettingsFile(preferences: preferences, journal: journal))
            XCTAssertEqual(try validator.errors(data, against: "settings-v1.schema.json"), [])
        }
        XCTAssertEqual(validator.unseen, [], "every property in the schemas is one the app writes")
    }

    func testTheSchemasRejectWhatTheAppCouldNotRead() throws {
        let validator = SchemaValidator()
        var session = try JSONSerialization.jsonObject(with: FileFormat.encoder.encode(SessionFile(finishedSession(), checkpoint: nil))) as! [String: Any]
        session["unknown"] = true
        session["intervals"] = []
        session["started_at"] = "yesterday"
        let errors = try validator.errors(JSONSerialization.data(withJSONObject: session), against: "session-v1.schema.json")
        XCTAssertEqual(errors.count, 3, "\(errors)")
    }

    func testFilesAreReadable() throws {
        let data = try FileFormat.encoder.encode(SessionFile(finishedSession(), checkpoint: nil))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""started_at" : "2023-11-14T22:13:20.000000Z""#), text)
        XCTAssertTrue(text.contains(#""link" : "https://linear.app/acme/issue/ABC-1""#), "slashes aren't escaped")
        XCTAssertTrue(text.contains(#""$schema" : "https://raw.githubusercontent.com/johnstonmatt/lockin/main/Schemas/session-v1.schema.json""#))
    }

    // MARK: round trips

    func testSessionsRoundTripExactly() throws {
        for log in journal().sessions {
            let data = try FileFormat.encoder.encode(SessionFile(log, checkpoint: start))
            let file = try FileFormat.decode(SessionFile.self, from: data, supported: FileFormat.sessionVersion)
            XCTAssertEqual(file.log, log)
            XCTAssertEqual(file.checkpointAt, log.endedAt == nil ? start : nil, "only the open session carries a checkpoint")
        }
    }

    func testSettingsRoundTripExactly() throws {
        let preferences = preferences()
        var journal = journal()
        let data = try FileFormat.encoder.encode(SettingsFile(preferences: preferences, journal: journal))
        let file = try FileFormat.decode(SettingsFile.self, from: data, supported: FileFormat.settingsVersion)
        XCTAssertEqual(file.preferences, preferences)
        journal.sessions = []
        XCTAssertEqual(file.journal, journal)
    }

    func testTimestampsKeepMicroseconds() throws {
        let date = Date(timeIntervalSince1970: 1_762_160_400.123456)
        XCTAssertEqual(Timestamp.string(date), "2025-11-03T09:00:00.123456Z")
        let read = try XCTUnwrap(Timestamp.date(Timestamp.string(date)))
        XCTAssertEqual(read.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1e-6)
        // Hand-edited forms.
        XCTAssertEqual(Timestamp.date("2025-11-03T09:00:00Z"), Date(timeIntervalSince1970: 1_762_160_400))
        XCTAssertEqual(Timestamp.date("2025-11-03T10:00:00.5+01:00"), Date(timeIntervalSince1970: 1_762_160_400.5))
        XCTAssertNil(Timestamp.date("2025-11-03 09:00"))
    }

    func testNewerFilesAreRefused() throws {
        let data = Data(#"{"schema_version": 2, "id": "nonsense"}"#.utf8)
        XCTAssertThrowsError(try FileFormat.decode(SessionFile.self, from: data, supported: 1)) { error in
            XCTAssertEqual(error as? FileFormat.Problem, .newerVersion(2))
        }
    }

    func testNothingSavedLoadsAsFresh() throws {
        let contents = try Storage.load(from: directory)
        XCTAssertTrue(contents.journal.sessions.isEmpty)
        XCTAssertEqual(contents.journal.draft.map(\.title), [""], "the planner's blank row")
        XCTAssertNil(contents.checkpoint)
    }

    // MARK: reading and writing ~/.lockin

    func testUnreadableSessionsAreSkippedAndNeverOverwritten() throws {
        let journal = journal()
        let writer = StorageWriter(directory: directory, timeZone: utc)
        try writer.write(preferences: preferences(), journal: journal, checkpoint: start)
        let sessions = Storage.sessionsDirectory(in: directory)
        let broken = sessions.appendingPathComponent("broken.json"), newer = sessions.appendingPathComponent("newer.json")
        let empty = sessions.appendingPathComponent("empty.json")
        try "{ not json".write(to: broken, atomically: true, encoding: .utf8)
        try #"{"schema_version": 9}"#.write(to: newer, atomically: true, encoding: .utf8)
        var noIntervals = SessionFile(WorkLog(todos: [], targetSeconds: 60, now: start), checkpoint: nil)
        noIntervals.intervals = []
        try FileFormat.encoder.encode(noIntervals).write(to: empty)

        let contents = try Storage.load(from: directory)
        XCTAssertEqual(contents.journal.sessions.map(\.id), journal.sessions.map(\.id))
        XCTAssertEqual(contents.skipped.count, 3, "\(contents.skipped)")
        XCTAssertTrue(contents.skipped.contains { $0.hasPrefix("newer.json") && $0.contains("newer version") })

        var changed = contents.journal
        changed.sessions[0].reviewed.toggle()
        try StorageWriter(directory: directory, contents: contents).write(preferences: contents.preferences, journal: changed, checkpoint: start)
        XCTAssertEqual(try String(contentsOf: broken, encoding: .utf8), "{ not json")
        XCTAssertEqual(try String(contentsOf: newer, encoding: .utf8), #"{"schema_version": 9}"#)
    }

    func testUnreadableSettingsStopEverything() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #"{"schema_version": 1, "profiles": "oops"}"#.write(to: Storage.settingsFile(in: directory), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Storage.load(from: directory)) { error in
            XCTAssertTrue(error.localizedDescription.contains("profiles"), error.localizedDescription)
        }
    }

    func testOnlyChangedSessionsAreWritten() throws {
        var journal = journal()
        let writer = StorageWriter(directory: directory, timeZone: utc)
        try writer.write(preferences: SavedState(), journal: journal, checkpoint: start)
        let finished = try XCTUnwrap(writer.file(for: journal.sessions[0].id))
        let open = try XCTUnwrap(writer.file(for: journal.sessions[1].id))
        try "edited elsewhere".write(to: finished, atomically: true, encoding: .utf8)
        try writer.write(preferences: SavedState(), journal: journal, checkpoint: start.addingTimeInterval(10))
        XCTAssertEqual(try String(contentsOf: finished, encoding: .utf8), "edited elsewhere", "an unchanged session is skipped")
        let checkpoint = try FileFormat.decode(SessionFile.self, from: Data(contentsOf: open), supported: 1).checkpointAt
        XCTAssertEqual(checkpoint, start.addingTimeInterval(10), "the open session is written on every checkpoint")

        // A removed session's file goes too, e.g. undoing a backfill that created it.
        journal.sessions.removeFirst()
        try writer.write(preferences: SavedState(), journal: journal, checkpoint: start)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finished.path))
    }

    func testRenamedSessionFilesAreWrittenInPlace() throws {
        var journal = journal()
        let writer = StorageWriter(directory: directory, timeZone: utc)
        try writer.write(preferences: SavedState(), journal: journal, checkpoint: start)
        let original = try XCTUnwrap(writer.file(for: journal.sessions[0].id))
        let renamed = Storage.sessionsDirectory(in: directory).appendingPathComponent("monday.json")
        try FileManager.default.moveItem(at: original, to: renamed)
        let contents = try Storage.load(from: directory)
        journal = contents.journal
        journal.sessions[0].endReason = "Renamed"
        try StorageWriter(directory: directory, contents: contents).write(preferences: SavedState(), journal: journal, checkpoint: start)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try FileFormat.decode(SessionFile.self, from: Data(contentsOf: renamed), supported: 1).endReason, "Renamed")
    }

    // MARK: file names

    func testSessionFilesAreNamedAfterTheirStart() throws {
        var journal = JournalState()
        let first = WorkLog(todos: [], targetSeconds: 60, now: start)                        // 22:13:20 UTC
        let sameMinute = WorkLog(todos: [], targetSeconds: 60, now: start.addingTimeInterval(30))
        let later = WorkLog(todos: [], targetSeconds: 60, now: start.addingTimeInterval(3600))
        journal.sessions = [first, sameMinute, later]
        let writer = StorageWriter(directory: directory, timeZone: utc)
        try writer.write(preferences: SavedState(), journal: journal, checkpoint: start)
        XCTAssertEqual(writer.file(for: first.id)?.lastPathComponent, "2023-11-14T22-13.json")
        XCTAssertEqual(writer.file(for: sameMinute.id)?.lastPathComponent, "2023-11-14T22-13.2.json", "a clash gets a number")
        XCTAssertEqual(writer.file(for: later.id)?.lastPathComponent, "2023-11-14T23-13.json")

        let local = StorageWriter(directory: directory.appendingPathComponent("tokyo"), timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        try local.write(preferences: SavedState(), journal: JournalState(), checkpoint: start)
        var tokyo = JournalState(); tokyo.sessions = [first]
        try local.write(preferences: SavedState(), journal: tokyo, checkpoint: start)
        XCTAssertEqual(local.file(for: first.id)?.lastPathComponent, "2023-11-15T07-13.json", "names use local time")
    }

    func testFileNamesDontFollowTheStart() throws {
        var journal = JournalState()
        journal.sessions = [WorkLog(todos: [], targetSeconds: 60, now: start)]
        let writer = StorageWriter(directory: directory, timeZone: utc)
        try writer.write(preferences: SavedState(), journal: journal, checkpoint: start)
        journal.sessions[0].startedAt = start.addingTimeInterval(-7200)   // as a backfill would
        try writer.write(preferences: SavedState(), journal: journal, checkpoint: start)
        let names = try FileManager.default.contentsOfDirectory(atPath: Storage.sessionsDirectory(in: directory).path)
        XCTAssertEqual(names, ["2023-11-14T22-13.json"])
    }

    func testExistingFilesAreNeverReused() throws {
        let folder = Storage.sessionsDirectory(in: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "not ours".write(to: folder.appendingPathComponent("2023-11-14T22-13.json"), atomically: true, encoding: .utf8)
        var journal = JournalState()
        journal.sessions = [WorkLog(todos: [], targetSeconds: 60, now: start)]
        let writer = StorageWriter(directory: directory, contents: try Storage.load(from: directory), timeZone: utc)
        try writer.write(preferences: SavedState(), journal: journal, checkpoint: start)
        XCTAssertEqual(writer.file(for: journal.sessions[0].id)?.lastPathComponent, "2023-11-14T22-13.2.json")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("2023-11-14T22-13.json"), encoding: .utf8), "not ours")
    }
}
