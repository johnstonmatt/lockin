import Foundation

public struct WorkInput: Equatable, Sendable {
    public let title: String?
    public let link: String?

    public init(title: String? = nil, link: String? = nil) {
        self.title = title?.trimmed.isEmpty == true ? nil : title?.trimmed
        self.link = link?.trimmed.isEmpty == true ? nil : link?.trimmed
    }

    public init(_ text: String) throws {
        let text = text.trimmed
        if !text.isEmpty, Todo.isValidLink(text) {
            self.init(link: text)
        } else if let separator = text.range(of: " - ", options: .backwards),
                  Todo.isValidLink(String(text[separator.upperBound...])),
                  !text[separator.upperBound...].isEmpty {
            let title = String(text[..<separator.lowerBound]).trimmed
            self.init(title: title.isEmpty ? nil : title, link: String(text[separator.upperBound...]))
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
