import Foundation
import Security
import LockInCore

enum LinearCredential {
    private static let service = "app.lockin.mac.linear"
    private static let account = "personal-api-key"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func read() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw LockInError("Couldn't read the Linear key from Keychain (\(status)).")
        }
        return key
    }
    static func save(_ key: String) throws {
        let data = Data(key.trimmed.utf8)
        guard !data.isEmpty else { throw LockInError("Enter a Linear personal API key.") }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw LockInError("Couldn't save the Linear key in Keychain.") }
        } else if status != errSecSuccess { throw LockInError("Couldn't update the Linear key in Keychain.") }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LockInError("Couldn't remove the Linear key from Keychain.") }
    }
}

enum WorkConnections {
    static var importer: WorkImporter {
        WorkImporter(fetchLinear: { input in
            guard let key = try LinearCredential.read() else {
                throw LockInError("Add your Linear personal API key in Connections first.")
            }
            return try await linear(key: key).fetch(input)
        }, enrichGitHub: { try await github.enrich($0) })
    }

    static func linear(key: String) -> LinearGraphClient {
        LinearGraphClient { query, variables in
            try Task.checkCancellation()
            var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
            request.httpMethod = "POST"; request.timeoutInterval = 30
            request.setValue(key, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw LockInError(code == 429 ? "Linear is rate limiting requests. Wait before refreshing." : "Linear request failed (HTTP \(code)). Check the key and connection.")
            }
            return data
        }
    }

    static var github: GitHubGraphClient {
        GitHubGraphClient(request: { route in
            try await gitHub(["--method", "GET", route])
        }, readinessRequest: { reference in
            let parts = reference.repository.split(separator: "/").map(String.init)
            return try await gitHub(["graphql", "--paginate", "--slurp", "-f", "query=" + GitHubReadinessResponse.query,
                                     "-f", "owner=" + parts[0], "-f", "name=" + parts[1],
                                     "-F", "number=\(reference.number)"])
        })
    }

    /// Runs `gh api` off the main actor; gh blocks until it exits, so cancellation is checked on either side.
    private static func gitHub(_ arguments: [String]) async throws -> Data {
        try Task.checkCancellation()
        let data = try await Task.detached(priority: .userInitiated) { try runGitHub(arguments) }.value
        try Task.checkCancellation()
        return data
    }

    /// gh owns its credentials; only JSON from read-only endpoints crosses into the app.
    private static func runGitHub(_ arguments: [String]) throws -> Data {
        let manager = FileManager.default
        let directories = ["/opt/homebrew/bin", "/usr/local/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        guard let executable = directories.map({ URL(fileURLWithPath: $0).appendingPathComponent("gh") })
            .first(where: { manager.isExecutableFile(atPath: $0.path) }) else {
            throw LockInError("Install GitHub CLI and run gh auth login to load pull requests.")
        }
        let folder = manager.temporaryDirectory.appendingPathComponent("lockin-github-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: folder) }
        let output = folder.appendingPathComponent("response")
        manager.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["api", "--hostname", "github.com"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_PAGER"] = "cat"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 35) == .timedOut {
            process.terminate()
            throw LockInError("GitHub request timed out. Check your connection.")
        }
        guard process.terminationStatus == 0 else {
            throw LockInError("GitHub couldn't read this repository. Run gh auth login and check repository access.")
        }
        return try Data(contentsOf: output)
    }
}
