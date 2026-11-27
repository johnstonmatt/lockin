import Foundation
import LockInCore

/// `lockin upgrade`: installs the latest GitHub release, using the install script that ships inside it.
/// That's the same script `./install-app` runs, so an upgrade pauses and resumes a session exactly like a local install.
enum Upgrade {
    static let installedApp = URL(fileURLWithPath: "/Applications/Lock In.app")

    static func run() throws -> Int32 {
        #if !arch(arm64)
        throw UsageError("Lock In runs on Apple silicon Macs only.")
        #endif
        let latest = try release()
        let version = latest.version
        if let installed = bundleVersion(of: installedApp) {
            switch ReleaseVersion.compare(installed, version) {
            case .orderedSame: print("Lock In \(installed) is the latest release."); return 0
            case .orderedDescending: print("Lock In \(installed) is newer than the latest release (\(version))."); return 0
            case .orderedAscending: print("Upgrading Lock In \(installed) → \(version)")
            }
        } else {
            print("Installing Lock In \(version)")
        }

        let assetName = ReleaseVersion.assetName(tag: latest.tag)
        guard let asset = latest.appAsset else { throw UsageError("\(latest.tag) has no \(assetName) download.") }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("lockin-upgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let zip = work.appendingPathComponent(assetName)
        try download(asset.url, to: zip)
        try tool("/usr/bin/ditto", "-x", "-k", zip.path, work.path)

        let app = work.appendingPathComponent("Lock In.app")
        guard bundleVersion(of: app) == version else { throw UsageError("The \(latest.tag) download doesn't contain Lock In \(version).") }
        // Only a Developer ID signed, notarized build is installed, as Gatekeeper would require of a download.
        do {
            try tool("/usr/bin/codesign", "--verify", "--deep", "--strict", app.path)
            try tool("/usr/sbin/spctl", "--assess", "--type", "execute", app.path)
        } catch { throw UsageError("The \(latest.tag) download failed signature checks, so it wasn't installed.") }
        let script = app.appendingPathComponent("Contents/Resources/install.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw UsageError("\(latest.tag) predates lockin upgrade. Download it from https://github.com/\(ReleaseVersion.repository)/releases.")
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

    private static func release() throws -> ReleaseVersion.Release {
        let (data, status) = try fetch(ReleaseVersion.latestReleaseRequest())
        do { return try ReleaseVersion.latestRelease(from: data, statusCode: status) }
        catch { throw UsageError(error.localizedDescription) }
    }

    private static func fetch(_ request: URLRequest) throws -> (Data, Int) {
        let result = Box<Result<(Data, Int), Error>?>(nil)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data, let response = response as? HTTPURLResponse { result.value = .success((data, response.statusCode)) }
            else { result.value = .failure(error ?? UsageError("GitHub didn't answer \(request.url?.absoluteString ?? "")")) }
            done.signal()
        }.resume()
        done.wait()
        return try result.value!.get()
    }

    private static func download(_ url: URL, to destination: URL) throws {
        var request = URLRequest(url: url)
        request.setValue("lockin", forHTTPHeaderField: "User-Agent")
        let (data, status) = try fetch(request)
        guard (200..<300).contains(status) else { throw UsageError("GitHub answered \(status) for \(url.absoluteString)") }
        try data.write(to: destination)
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
