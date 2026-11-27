import Foundation

public struct PullRequestReference: Hashable, Sendable {
    public var repository: String
    public var number: Int
    public var url: String { "https://github.com/\(repository)/pull/\(number)" }
    public var key: String { "\(repository.lowercased())#\(number)" }
    public var nodeID: String { "github:\(key)" }
    public init?(url: String) {
        guard let parsed = Link.webURL(url), ["github.com", "www.github.com"].contains(parsed.host?.lowercased()) else { return nil }
        let parts = Link.parts(parsed)
        guard parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]), number > 0,
              parts.prefix(2).allSatisfy({ $0.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil }) else { return nil }
        repository = "\(parts[0])/\(parts[1])"; self.number = number
    }
}
