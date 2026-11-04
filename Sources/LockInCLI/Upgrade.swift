import Foundation

/// `lockin upgrade`: installs the latest GitHub release, using the install script that ships inside it.
/// That's the same script `./install-app` runs, so an upgrade pauses and resumes a session exactly like a local install.
enum Upgrade {
    static let repository = "johnstonmatt/lockin"
    static let installedApp = URL(fileURLWithPath: "/Applications/Lock In.app")
    #if arch(arm64)
    static let architecture = "arm64"
    #else
    static let architecture = "x86_64"
    #endif

    private struct Release: Decodable {
        struct Asset: Decodable { var name: String; var browser_download_url: URL }
        var tag_name: String
        var assets: [Asset]
    }

    static func run() throws -> Int32 {
        let latest = try release()
        let version = latest.tag_name.hasPrefix("v") ? String(latest.tag_name.dropFirst()) : latest.tag_name
        if let installed = bundleVersion(of: installedApp) {
            switch compare(installed, version) {
            case .orderedSame: print("Lock In \(installed) is the latest release."); return 0
            case .orderedDescending: print("Lock In \(installed) is newer than the latest release (\(version))."); return 0
            case .orderedAscending: print("Upgrading Lock In \(installed) → \(version)")
            }
        } else {
            print("Installing Lock In \(version)")
        }

        let assetName = "LockIn-\(latest.tag_name)-macos-\(architecture).zip"
        guard let asset = latest.assets.first(where: { $0.name == assetName }) else {
            throw UsageError("\(latest.tag_name) has no \(assetName) download.")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("lockin-upgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let zip = work.appendingPathComponent(assetName)
        try download(asset.browser_download_url, to: zip)
        try tool("/usr/bin/ditto", "-x", "-k", zip.path, work.path)

        let app = work.appendingPathComponent("Lock In.app")
        guard bundleVersion(of: app) == version else { throw UsageError("The \(latest.tag_name) download doesn't contain Lock In \(version).") }
        // Only a Developer ID signed, notarized build is installed, as Gatekeeper would require of a download.
        do {
            try tool("/usr/bin/codesign", "--verify", "--deep", "--strict", app.path)
            try tool("/usr/sbin/spctl", "--assess", "--type", "execute", app.path)
        } catch { throw UsageError("The \(latest.tag_name) download failed signature checks, so it wasn't installed.") }
        let script = app.appendingPathComponent("Contents/Resources/install.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw UsageError("\(latest.tag_name) predates lockin upgrade. Download it from https://github.com/\(repository)/releases.")
        }

        let install = Process()
        install.executableURL = URL(fileURLWithPath: "/bin/bash")
        install.arguments = [script.path, app.path]
        try install.run()
        install.waitUntilExit()
        return install.terminationStatus == 0 ? 0 : 1
    }

    static func bundleVersion(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        return (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"]) as? String
    }

    /// Dotted versions compared number by number: 0.10.0 is newer than 0.9.1.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func release() throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("lockin-cli", forHTTPHeaderField: "User-Agent")
        let data = try fetch(request)
        do { return try JSONDecoder().decode(Release.self, from: data) }
        catch { throw UsageError("Couldn't read the latest release from GitHub.") }
    }

    private static func fetch(_ request: URLRequest) throws -> Data {
        let result = Box<Result<Data, Error>?>(nil)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let data, (200..<300).contains(status) { result.value = .success(data) }
            else { result.value = .failure(error ?? UsageError("GitHub answered \(status) for \(request.url?.absoluteString ?? "")")) }
            done.signal()
        }.resume()
        done.wait()
        return try result.value!.get()
    }

    private static func download(_ url: URL, to destination: URL) throws {
        var request = URLRequest(url: url)
        request.setValue("lockin-cli", forHTTPHeaderField: "User-Agent")
        try fetch(request).write(to: destination)
    }

    private static func tool(_ path: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UsageError("\((path as NSString).lastPathComponent) failed.") }
    }
}
