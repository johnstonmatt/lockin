import Foundation
import LockInCore

// The UI can dismiss after starting work; command callers await this operation’s own result.
enum WorkOperation {
    case saved(String)
    case importing(Task<String, Error>)

    var value: String {
        get async throws {
            switch self {
            case .saved(let message): return message
            case .importing(let task): return try await task.value
            }
        }
    }
}

extension Store {
    @discardableResult
    func importWork(_ input: String, addToSession: Bool = true, using importer: WorkImporter = WorkConnections.importer) throws -> WorkOperation {
        guard !workImporting, workGraphWritable else { throw WorkImportError("Work can't be imported right now. Try again shortly.") }
        let targetSession = workLog?.id
        workImportMessage = "Loading work and dependencies…"
        let task = Task<String, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            defer { self.workImportTask = nil }
            do {
                let result = try await importer.fetch(input, preserving: Set(self.workGraph.imports.map(\.id)))
                let message = try self.applyWorkImport(result, addToSession: addToSession, targetSession: targetSession)
                self.workImportMessage = message
                return message
            } catch {
                let failure = error is CancellationError
                    ? WorkImportError("Import canceled. Saved work is unchanged.")
                    : WorkImportError(error.localizedDescription)
                self.workImportMessage = failure.localizedDescription
                throw failure
            }
        }
        workImportTask = task
        return .importing(task)
    }

    func refreshWork(_ input: String, addToSession: Bool = false) {
        do { try importWork(input, addToSession: addToSession) }
        catch { workImportMessage = error.localizedDescription }
    }

    @discardableResult
    func applyWorkImport(_ result: WorkImportResult, addToSession: Bool, targetSession: UUID?) throws -> String {
        let addsToSession = addToSession && workLog?.id == targetSession && (workLog != nil || journal.pendingReviewID == nil)
        var candidate = workGraph
        candidate.merge(result)
        if addsToSession, let ancestor = candidate.selectedAncestor(of: result.snapshot.id, among: sessionWorkIDs) {
            throw WorkImportError(parentEntryMessage(ancestor))
        }
        try saveWorkGraph(candidate)
        if addsToSession {
            do { try saveWorkSelection(result.nodes.filter { $0.id == result.snapshot.id }) }
            catch { throw WorkImportError("Graph saved, but session tasks couldn't be saved. Add the saved work again to retry.") }
        }
        guard normalizeSessionEntries() else {
            throw WorkImportError("Graph saved, but session tasks couldn't be saved. Refresh the work to retry.")
        }
        if addToSession && !addsToSession {
            throw WorkImportError("Graph saved. The session changed during import; add its URL again to include it.")
        }
        return result.snapshot.warnings.isEmpty
            ? "Imported \(result.nodes.count) work items."
            : result.snapshot.warnings.joined(separator: "\n")
    }
}
