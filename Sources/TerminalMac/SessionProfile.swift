import Foundation
import LocalAuthentication
import Security
import Darwin
import TerminalMacCore

/// A local Screen Sharing connection. Credentials are stored separately in Keychain.
struct SessionProfile: Codable, Sendable {
    var name: String
    var host: String
    var port: Int
    var username: String
    var inputApproved: Bool = false

    func validate() throws {
        try validateName(name)
        guard ["127.0.0.1", "::1", "localhost"].contains(host) else {
            throw Failure("Session connections must use loopback. Use an SSH tunnel for other addresses.")
        }
        guard username != NSUserName() else {
            throw Failure("Use a separate macOS user account, not the account running this command")
        }
        guard (1...65535).contains(port), !username.isEmpty, username.utf8.count <= 63, !username.contains("\0"),
              !username.contains(where: { $0.isNewline || $0.isWhitespace }) else {
            throw Failure("Provide a valid port and macOS account short username")
        }
    }
}

struct SessionProfiles: Sendable {
    let root: URL
    init(store: Store) { root = store.root.appendingPathComponent("sessions") }
    func directory(_ name: String) throws -> URL {
        try validateName(name)
        return root.appendingPathComponent(name)
    }
    func load(_ name: String) throws -> SessionProfile {
        let file = try directory(name).appendingPathComponent("session.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw Failure("No session named '\(name)'. Run: terminal-mac session configure \(name) --user agent")
        }
        let profile = try JSONDecoder().decode(SessionProfile.self, from: Data(contentsOf: file))
        guard profile.name == name else { throw Failure("Session profile name does not match its directory") }
        try profile.validate()
        return profile
    }
    func save(_ profile: SessionProfile) throws {
        try profile.validate()
        let directory = try directory(profile.name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("session.json")
        let data = try JSONEncoder().encode(profile)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    /// Re-read at the point of execution, including after Keychain and network
    /// setup. Approval observed before either wait must not authorize later input.
    func requireInputApproval(for profile: SessionProfile) throws {
        let current = try load(profile.name)
        guard current.inputApproved, current.host == profile.host, current.port == profile.port,
              current.username == profile.username else {
            throw Failure("Session input is disabled or its target changed. Inspect `terminal-mac session view \(profile.name) --read-only`, then run `terminal-mac session approve \(profile.name)`.")
        }
    }
    private func query(_ name: String) -> [String: Any] {
        // Include the data root so alternate TERMINAL_MAC_HOME profiles do not share secrets.
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.terminal-mac.screen-sharing",
         kSecAttrAccount as String: root.standardizedFileURL.path + "/" + name]
    }
    func savePassword(_ password: String, name: String) throws {
        guard !password.isEmpty, password.utf8.count <= 63, !password.contains("\0") else { throw Failure("The Screen Sharing password must be 1–63 UTF-8 bytes without NUL characters") }
        let existing = query(name)
        let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8)]
        var result = SecItemUpdate(existing as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var item = existing.merging(attributes) { $1 }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            result = SecItemAdd(item as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw Failure("Cannot store session password in Keychain (\(result))") }
    }
    func readPassword(_ name: String) throws -> String {
        var item = query(name)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        // MCP runs without an interactive terminal. Fail promptly instead of
        // leaving an invisible Keychain authorization dialog blocking the tool.
        if isatty(STDIN_FILENO) == 0 {
            let context = LAContext()
            context.interactionNotAllowed = true
            item[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound {
                throw Failure("Keychain access requires authorization (\(status)). Run `terminal-mac session action \(name) status` in your own terminal and allow access to the saved agent password. Choose Always Allow to enable background agent tools.")
            }
            throw Failure("Session credential unavailable in Keychain (\(status)). Run: terminal-mac session configure \(name)")
        }
        return password
    }
    static func promptPassword() throws -> String {
        guard isatty(STDIN_FILENO) == 1 else { throw Failure("Configure requires an interactive terminal for the hidden password prompt") }
        guard let bytes = getpass("Screen Sharing account password (saved in Keychain): ") else {
            throw Failure("Unable to read the password")
        }
        defer { memset(bytes, 0, strlen(bytes)) }
        let password = String(cString: bytes)
        guard !password.isEmpty, password.utf8.count <= 63, !password.contains("\0") else { throw Failure("The Screen Sharing password must be 1–63 UTF-8 bytes without NUL characters") }
        return password
    }
}

/// MCP initialization and tool discovery must not prompt for credentials or open a socket.
/// The first actual operation reads Keychain and creates the underlying VNC connection.
@MainActor
final class KeychainSessionConnection: SessionConnection {
    private let profile: SessionProfile
    private let profiles: SessionProfiles
    private var connection: VNCConnection?
    init(profile: SessionProfile, profiles: SessionProfiles) {
        self.profile = profile; self.profiles = profiles
    }
    func call(_ request: Request) async throws -> VNCResponse {
        if connection == nil {
            let budget = request.deadline.timeIntervalSinceNow
            guard budget > 0 else { throw Failure("Session request expired before execution") }
            let opened = try VNCConnection(host: profile.host, port: profile.port, username: profile.username,
                                           password: profiles.readPassword(profile.name),
                                           inputAuthorization: { [profiles, profile] in try profiles.requireInputApproval(for: profile) })
            connection = opened
            // A Keychain authorization prompt can outlast the action timeout.
            // Start the first action's budget after that one-time authorization.
            return try await opened.call(Request(action: request.action, arguments: request.arguments, timeout: budget))
        }
        guard let connection else { throw Failure("Session connection unavailable") }
        return try await connection.call(request)
    }
}
