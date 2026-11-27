import Foundation

/// A refusal or failure whose message is shown to the user as it is, in the app or by the CLI.
public struct LockInError: LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
