import Foundation

/// Adding work afterwards, for time you worked without Lock In counting it. Backfill places a range on the timeline,
/// not on a day, so ranges and sessions can run past midnight. The range is recorded as work where nothing else was:
/// - Inside a session, pauses in the range become work. Work and breaks already there are left as they were.
/// - A range running into the start of a session moves the session's start earlier (you forgot to start).
/// - A range outside every session becomes a new, finished and reviewed session with no tasks.
/// Added intervals are marked `backfilled`. Work and overtime are relabelled afterwards, since earlier work moves
/// the point the target was reached.
public enum BackfillError: Error, Equatable {
    case empty
    case inFuture
    /// Everything in the range was already recorded as work or break.
    case nothingToAdd
    /// The range runs past the end of the session it starts in.
    case afterEnd(sessionEnd: Date)
    /// The range covers parts of two sessions: the first ends, then the next starts.
    case spansSessions(firstEnds: Date, nextStarts: Date)
}

public struct BackfillResult: Equatable, Sendable {
    public var addedSeconds: Double
    /// Time in the range that was already work, overtime or break.
    public var alreadyRecordedSeconds: Double
    public var sessionStartedAt: Date
    public var createdSession: Bool
    /// The session's start moved earlier.
    public var movedStart: Bool
}

/// The state before the last backfill, for undo.
public struct BackfillRecord: Codable, Sendable {
    public var sessionID: UUID
    public var createdSession: Bool
    public var previousStartedAt: Date
    public var previousIntervals: [WorkInterval]
    public var at: Date
}

extension JournalState {
    /// A range ending up to this long before a session starts still counts as running into it,
    /// since ranges are typed to the minute and sessions start to the second.
    static let startTolerance: TimeInterval = 60

    public mutating func backfill(from start: Date, to requestedEnd: Date, now: Date) throws -> BackfillResult {
        // The CLI reads its clock a moment before the app does.
        let end = min(requestedEnd, now)
        guard requestedEnd <= now.addingTimeInterval(5) else { throw BackfillError.inFuture }
        guard start < end else { throw BackfillError.empty }
        let touched = sessions.indices.filter {
            sessions[$0].startedAt < end.addingTimeInterval(Self.startTolerance) && (sessions[$0].endedAt ?? now) > start
        }
        if touched.count > 1 {
            let first = sessions[touched[0]], next = sessions[touched[1]]
            throw BackfillError.spansSessions(firstEnds: first.endedAt ?? now, nextStarts: next.startedAt)
        }
        guard let index = touched.first else {
            var log = WorkLog(todos: [], targetSeconds: end.timeIntervalSince(start), now: start)
            log.intervals[0].end = end
            log.intervals[0].backfilled = true
            log.endedAt = end; log.finishedNaturally = true; log.reviewed = true
            sessions.insert(log, at: sessions.firstIndex { $0.startedAt > start } ?? sessions.endIndex)
            lastBackfill = BackfillRecord(sessionID: log.id, createdSession: true, previousStartedAt: start, previousIntervals: [], at: now)
            return BackfillResult(addedSeconds: end.timeIntervalSince(start), alreadyRecordedSeconds: 0,
                                  sessionStartedAt: start, createdSession: true, movedStart: false)
        }

        var log = sessions[index]
        if let sessionEnd = log.endedAt, end > sessionEnd { throw BackfillError.afterEnd(sessionEnd: sessionEnd) }
        let previous = log
        var added = 0.0, already = 0.0
        var result: [WorkInterval] = []
        let movedStart = start < log.startedAt
        if movedStart {
            let gapEnd = log.startedAt
            result.append(WorkInterval(kind: .work, start: start, end: gapEnd, backfilled: true))
            added += gapEnd.timeIntervalSince(start)
            log.startedAt = start
        }
        for item in log.intervals {
            let itemEnd = item.end ?? now
            let lower = max(item.start, start), upper = min(itemEnd, end)
            guard upper > lower else { result.append(item); continue }
            guard item.kind == .pause else { already += upper.timeIntervalSince(lower); result.append(item); continue }
            // The part of the pause before the range is a new interval; the part after keeps the pause's identity,
            // since it may be the open interval (and `resumeAfterUpdateID` refers to it).
            if item.start < lower {
                var before = item; before.id = UUID(); before.end = lower
                result.append(before)
            }
            result.append(WorkInterval(kind: .work, start: lower, end: upper, backfilled: true))
            added += upper.timeIntervalSince(lower)
            if upper < itemEnd || item.end == nil {
                var after = item; after.start = upper
                result.append(after)
            }
        }
        guard added > 0 else { throw BackfillError.nothingToAdd }
        log.intervals = result
        log.relabelFocus(at: now)
        sessions[index] = log
        lastBackfill = BackfillRecord(sessionID: log.id, createdSession: false, previousStartedAt: previous.startedAt,
                                      previousIntervals: previous.intervals, at: now)
        return BackfillResult(addedSeconds: added, alreadyRecordedSeconds: already, sessionStartedAt: log.startedAt,
                              createdSession: false, movedStart: movedStart)
    }

    /// Reverses the last backfill, keeping anything recorded since. Returns false if there's nothing to undo.
    public mutating func undoBackfill(now: Date) -> Bool {
        defer { lastBackfill = nil }
        guard let record = lastBackfill, let index = sessions.firstIndex(where: { $0.id == record.sessionID }) else { return false }
        if record.createdSession { sessions.remove(at: index); return true }
        var log = sessions[index]
        let later = log.intervals.filter { $0.start > record.at }
        var restored = record.previousIntervals
        // The interval that was open at the time ends where the next one began, or when the session ended.
        if let last = restored.indices.last, restored[last].end == nil {
            restored[last].end = later.first?.start ?? log.endedAt
        }
        log.intervals = restored + later
        log.startedAt = record.previousStartedAt
        log.relabelFocus(at: now)
        sessions[index] = log
        return true
    }
}

extension WorkLog {
    /// Labels focused time as work until the target is reached and overtime after, splitting the interval that
    /// crosses it. An open interval that hasn't reached the target yet is left to `advance(at:)`.
    public mutating func relabelFocus(at now: Date) {
        var worked = 0.0
        var result: [WorkInterval] = []
        for var item in intervals {
            guard item.kind.isFocused else { result.append(item); continue }
            let length = item.seconds(at: now), remaining = targetSeconds - worked
            worked += length
            if remaining <= 0 { item.kind = .overtime; result.append(item) }
            else if length <= remaining { item.kind = .work; result.append(item) }
            else {
                var first = item; first.kind = .work; first.end = item.start.addingTimeInterval(remaining)
                var rest = item; rest.id = UUID(); rest.kind = .overtime; rest.start = first.end!
                result += [first, rest]
            }
        }
        intervals = result
    }
}
