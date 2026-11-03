import Foundation

public enum WebsiteRule {
    /// Host boundaries prevent `notreddit.com` from matching `reddit.com`.
    /// Paths are prefix matched; a leading *. is optional for subdomains.
    public static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("*.") { text.removeFirst(2) }
        guard let url = URLComponents(string: text.contains("://") ? text : "https://" + text),
              let host = url.host?.lowercased(), !host.isEmpty,
              !host.contains(" "), url.user == nil, url.password == nil,
              url.scheme == "http" || url.scheme == "https" else { return nil }
        let path = url.percentEncodedPath == "/" ? "" : url.percentEncodedPath
        return host + path + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
    }
    public static func matches(_ rule: String, url: URL) -> Bool {
        guard let normalized = normalize(rule),
              let parsed = URLComponents(string: "https://" + normalized),
              let ruleHost = parsed.host, let host = url.host?.lowercased(),
              host == ruleHost || host.hasSuffix("." + ruleHost) else { return false }
        let target = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard (target?.percentEncodedPath ?? "").hasPrefix(parsed.percentEncodedPath) else { return false }
        return parsed.percentEncodedQuery == nil || parsed.percentEncodedQuery == target?.percentEncodedQuery
    }
    public static func shouldBlock(_ url: URL, rules: [String], mode: BlockingMode) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        let match = rules.contains { matches($0, url: url) }
        return mode == .block ? match : !match
    }
}
