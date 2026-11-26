import Foundation

public struct WorkImportError: LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct PullRequestReference: Hashable, Sendable {
    public var repository: String
    public var number: Int
    public var url: String { "https://github.com/\(repository)/pull/\(number)" }
    public var key: String { "\(repository.lowercased())#\(number)" }
    public var nodeID: String { "github:\(key)" }
    public init?(url: String) {
        guard let parsed = URL(string: url), parsed.scheme == "https", parsed.host?.lowercased() == "github.com" else { return nil }
        let parts = parsed.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]), number > 0,
              parts.prefix(2).allSatisfy({ $0.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil }) else { return nil }
        repository = "\(parts[0])/\(parts[1])"; self.number = number
    }
}
