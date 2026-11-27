import Foundation

/// How task links are read, in one place: which URLs count as links, and which point at a Linear issue or a
/// GitHub pull request. Nothing here touches the network.
public enum Link {
    /// `text` as an http(s) URL with a host: the only kind of link a task accepts.
    public static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmed), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// The URL's path segments, without slashes.
    static func parts(_ url: URL) -> [String] { url.pathComponents.filter { $0 != "/" } }

    /// The issue a Linear link points at: its identifier ("ENG-12") and the title slug that follows it, if any.
    public static func linearIssue(_ text: String) -> (identifier: String, slug: String)? {
        guard let url = webURL(text), LinkService(url: url) == .linear else { return nil }
        let parts = parts(url)
        guard let index = parts.firstIndex(of: "issue"), index + 1 < parts.count, isLinearIdentifier(parts[index + 1]) else { return nil }
        return (parts[index + 1].uppercased(), index + 2 < parts.count ? parts[index + 2] : "")
    }

    /// A Linear issue identifier such as ENG-12, in any case.
    public static func isLinearIdentifier(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z][A-Za-z0-9]*-[0-9]+$"#, options: .regularExpression) != nil
    }
}
