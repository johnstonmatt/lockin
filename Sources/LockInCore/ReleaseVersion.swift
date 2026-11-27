import Foundation

public enum ReleaseVersion {
    public static let repository = "johnstonmatt/lockin"
    /// GitHub's latest published release. Drafts aren't listed, so a release appears here once its download is attached.
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    /// Lock In is built for Apple silicon only. release.yml packages the app under this name.
    public static func assetName(tag: String) -> String { "LockIn-\(tag)-macos-arm64.zip" }

    public struct Failure: LocalizedError {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public struct Release: Equatable, Sendable {
        public struct Asset: Equatable, Sendable {
            public var name: String
            public var url: URL
        }
        public var tag: String
        public var version: String
        public var assets: [Asset]
        /// This release's app download.
        public var appAsset: Asset? { assets.first { $0.name == ReleaseVersion.assetName(tag: tag) } }
    }

    /// The request for `latestReleaseURL`, as the app and the CLI both send it.
    public static func latestReleaseRequest() -> URLRequest {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("lockin", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    /// Reads GitHub's answer to `latestReleaseRequest`.
    public static func latestRelease(from data: Data, statusCode: Int) throws -> Release {
        guard (200..<300).contains(statusCode) else {
            throw Failure("GitHub couldn't return the latest release (HTTP \(statusCode)). Please try again later.")
        }
        struct Payload: Decodable {
            struct Asset: Decodable { var name: String; var browser_download_url: URL }
            var tag_name: String
            var assets: [Asset]?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw Failure("Couldn't read the latest release from GitHub.")
        }
        guard let version = version(fromTag: payload.tag_name) else {
            throw Failure("GitHub returned an invalid release version (\(payload.tag_name)).")
        }
        return Release(tag: payload.tag_name, version: version,
                       assets: (payload.assets ?? []).map { Release.Asset(name: $0.name, url: $0.browser_download_url) })
    }

    /// The version a release tag names: "v1.2.3" and "1.2.3" are "1.2.3". Nil unless every part is a number.
    public static func version(fromTag tag: String) -> String? {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !version.isEmpty, version.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ Int($0) != nil }) else {
            return nil
        }
        return version
    }

    /// Dotted release versions, compared numerically rather than lexicographically: 0.10.0 is newer than 0.9.1.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
