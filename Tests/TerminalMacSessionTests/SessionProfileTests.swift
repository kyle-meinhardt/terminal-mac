import Foundation
import XCTest
@testable import TerminalMac
import TerminalMacCore

final class SessionProfileTests: XCTestCase {
    private func profile(host: String = "127.0.0.1", port: Int = 5901,
                         username: String = "terminal-mac-test-agent", name: String = "agent") -> SessionProfile {
        SessionProfile(name: name, host: host, port: port, username: username)
    }

    func testOnlyLoopbackEndpointsAreAccepted() throws {
        for host in ["127.0.0.1", "::1", "localhost"] {
            XCTAssertNoThrow(try profile(host: host).validate())
        }
        for host in ["192.168.1.2", "example.com", "127.0.0.2", "localhost.example.com", ""] {
            XCTAssertThrowsError(try profile(host: host).validate(), host)
        }
    }

    func testPhysicalUserAndMalformedProfilesAreRejected() throws {
        XCTAssertThrowsError(try profile(username: NSUserName()).validate())
        for username in ["", "agent user", "agent\n", "agent\0user", String(repeating: "a", count: 64)] {
            XCTAssertThrowsError(try profile(username: username).validate())
        }
        for port in [-1, 0, 65536] { XCTAssertThrowsError(try profile(port: port).validate()) }
        for name in ["../agent", "agent/session", "", ".", String(repeating: "a", count: 49)] {
            XCTAssertThrowsError(try profile(name: name).validate())
        }
    }

    func testProfilesRoundTripWithPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = SessionProfiles(store: Store(root: root))
        var configured = profile()
        configured.inputApproved = true
        try profiles.save(configured)
        let loaded = try profiles.load("agent")
        XCTAssertEqual(loaded.name, configured.name)
        XCTAssertEqual(loaded.host, configured.host)
        XCTAssertEqual(loaded.port, configured.port)
        XCTAssertEqual(loaded.username, configured.username)
        XCTAssertTrue(loaded.inputApproved)

        let directory = try profiles.directory("agent")
        let file = directory.appendingPathComponent("session.json")
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("password"))
    }

    func testStoredProfileMustMatchDirectoryAndValidateEndpoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = SessionProfiles(store: Store(root: root))
        try profiles.save(profile())
        let file = try profiles.directory("agent").appendingPathComponent("session.json")
        try JSONEncoder().encode(profile(name: "other")).write(to: file)
        XCTAssertThrowsError(try profiles.load("agent"))
        try JSONEncoder().encode(profile(host: "example.com")).write(to: file)
        XCTAssertThrowsError(try profiles.load("agent"))
        XCTAssertThrowsError(try profiles.load("missing"))
    }

    func testInvalidCredentialsAreRejectedBeforeKeychainAccess() {
        let profiles = SessionProfiles(store: Store(root: URL(fileURLWithPath: "/unused-test-root")))
        for password in ["", String(repeating: "a", count: 64), "secret\0suffix"] {
            XCTAssertThrowsError(try profiles.savePassword(password, name: "agent"))
        }
    }
}
