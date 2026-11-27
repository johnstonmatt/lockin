import Foundation

public enum ReleaseVersion {
    public static let repository = "johnstonmatt/lockin"
    /// GitHub's latest published release. Drafts aren't listed, so a release appears here once its download is attached.
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

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
