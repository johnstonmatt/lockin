import Foundation

public enum WebsiteRule {
    /// Host boundaries prevent `notreddit.com` from matching `reddit.com`, and path boundaries `youtube.com/shorts`
    /// from matching `/shortstack`. A rule's path covers the pages below it; a leading *. is optional for subdomains.
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
    public static func matches(_ rule: String, url: URL) -> Bool { Parsed(rule)?.matches(url) ?? false }

    /// A rule read once, so checking many tabs doesn't re-read it for each.
    struct Parsed: Sendable {
        let host: String, path: String, query: String?
        init?(_ rule: String) {
            guard let normalized = normalize(rule), let parsed = URLComponents(string: "https://" + normalized),
                  let host = parsed.host else { return nil }
            self.host = host; path = parsed.percentEncodedPath; query = parsed.percentEncodedQuery
        }
        func matches(_ url: URL) -> Bool {
            guard let urlHost = url.host?.lowercased(), urlHost == host || urlHost.hasSuffix("." + host) else { return false }
            let target = URLComponents(url: url, resolvingAgainstBaseURL: false)
            guard covers(path, target?.percentEncodedPath ?? "") else { return false }
            return query == nil || query == target?.percentEncodedQuery
        }
    }
    /// Whether `path` is `rulePath` or a page below it, by whole path segments.
    private static func covers(_ rulePath: String, _ path: String) -> Bool {
        guard path.hasPrefix(rulePath) else { return false }
        return rulePath.isEmpty || rulePath.hasSuffix("/") || path.count == rulePath.count
            || path.dropFirst(rulePath.count).first == "/"
    }
    public static func shouldBlock(_ url: URL, rules: [String], mode: BlockingMode) -> Bool {
        WebsiteRules(rules, mode: mode).shouldBlock(url)
    }
}

/// A profile's website rules, read once for a session's repeated tab checks.
public struct WebsiteRules: Sendable {
    private let rules: [WebsiteRule.Parsed]
    private let mode: BlockingMode
    public init(_ rules: [String], mode: BlockingMode) {
        self.rules = rules.compactMap(WebsiteRule.Parsed.init)
        self.mode = mode
    }
    /// Block mode blocks matching pages; allow mode blocks every other web page. Non-web pages are never blocked.
    public func shouldBlock(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        let match = rules.contains { $0.matches(url) }
        return mode == .block ? match : !match
    }
}

/// The local page blocked tabs are redirected to. It carries the original URL so a refresh can return to it.
public enum BlockPage {
    /// Unreserved characters only: `&`, `=`, `#` and `?` in the original URL must not leak into the outer query.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    public static func destination(base: String, original: String) -> String {
        guard let encoded = original.addingPercentEncoding(withAllowedCharacters: unreserved) else { return base }
        return base + "?url=" + encoded
    }
}
