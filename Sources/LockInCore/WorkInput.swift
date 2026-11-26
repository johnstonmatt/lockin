import Foundation

public enum WorkInput {
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
