import Foundation

public struct WorkInput: Equatable, Sendable {
    public let title: String?
    public let link: String?

    /// Blank fields are nil; others are trimmed.
    public init(title: String? = nil, link: String? = nil) {
        self.title = title.map(\.trimmed).flatMap { $0.isEmpty ? nil : $0 }
        self.link = link.map(\.trimmed).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "<title>", "<link>", or "<title> - <link>".
    public init(_ text: String) throws {
        let text = text.trimmed
        let separator = text.range(of: " - ", options: .backwards)
        let trailingLink = separator.map { String(text[$0.upperBound...]) }
        if !text.isEmpty, Todo.isValidLink(text) {
            self.init(link: text)
        } else if let separator, let trailingLink, !trailingLink.isBlank, Todo.isValidLink(trailingLink) {
            self.init(title: String(text[..<separator.lowerBound]), link: trailingLink)
        } else {
            self.init(title: text)
        }
        try validate()
    }

    public var source: String { link ?? title ?? "" }
    public var newTitle: String { title ?? link.map(Todo.title(fromLink:)) ?? "" }
    public var identity: String? { Self.linkIdentity(source) }
    public var importURL: String? {
        LinearGraphClient.issueIdentifier(from: source) != nil || PullRequestReference(url: source) != nil ? source : nil
    }

    public func validate() throws {
        guard !source.isEmpty else { throw WorkImportError("Enter a URL or task name.") }
        if let link {
            guard Todo.isValidLink(link) else { throw WorkImportError(Todo.linkRequirement) }
        } else if source.contains("://") || source.lowercased().hasPrefix("www.") {
            throw WorkImportError(Todo.linkRequirement)
        }
    }

    public static func linkIdentity(_ input: String) -> String? {
        let text = input.trimmed
        if let issue = LinearGraphClient.issueIdentifier(from: text) { return "linear:\(issue)" }
        if let pr = PullRequestReference(url: text) { return pr.nodeID }
        guard !text.isEmpty, Todo.isValidLink(text), var url = URLComponents(string: text) else { return nil }
        url.scheme = url.scheme?.lowercased()
        url.host = url.host?.lowercased()
        url.fragment = nil
        if url.path == "/" { url.path = "" }
        if (url.scheme == "https" && url.port == 443) || (url.scheme == "http" && url.port == 80) { url.port = nil }
        return url.string
    }
}
