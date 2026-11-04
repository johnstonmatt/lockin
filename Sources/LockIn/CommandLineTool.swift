import Foundation

/// The `lockin` CLI ships inside the app; installing it links it into ~/.local/bin, as Scripts/install.sh does.
/// It's a link into the app, so updating the app updates the command too.
enum CommandLineTool {
    enum Status: Equatable {
        /// This build has no CLI, e.g. when run with `swift run` rather than as the packaged app.
        case unavailable
        case notInstalled
        case installed
        /// A link to another copy of the CLI, e.g. a different app location. Installing replaces it.
        case linkedElsewhere(String)
        /// Something that isn't a link is in the way. It's never overwritten.
        case blocked
    }

    static var helper: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lockin")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
    static let link = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/lockin")

    static func status(helper: URL? = helper, link: URL = link) -> Status {
        guard let helper else { return .unavailable }
        let manager = FileManager.default
        if let destination = try? manager.destinationOfSymbolicLink(atPath: link.path) {
            return destination == helper.path ? .installed : .linkedElsewhere(destination)
        }
        return manager.fileExists(atPath: link.path) ? .blocked : .notInstalled
    }

    static func install(helper: URL? = helper, link: URL = link) throws {
        guard let helper else { throw Failure("This build of Lock In doesn't include the command line tool.") }
        switch status(helper: helper, link: link) {
        case .installed: return
        case .blocked: throw Failure("\(link.path) already exists and isn't a link to Lock In, so it was left alone.")
        case .linkedElsewhere: try FileManager.default.removeItem(at: link)
        case .notInstalled, .unavailable: break
        }
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: helper)
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
