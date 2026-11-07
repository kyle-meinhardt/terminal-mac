import XCTest
import TerminalMacCore
@testable import TerminalMac

final class StubSessionConnection: SessionConnection {
    var requests: [Request] = []
    var response = VNCResponse()
    func call(_ request: Request) async throws -> VNCResponse {
        requests.append(request)
        return response
    }
}

@MainActor
final class DesktopBackendTests: XCTestCase {
    private func fixture() throws -> (SessionProfiles, SessionProfile, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profiles = SessionProfiles(store: Store(root: root))
        let profile = SessionProfile(name: "test-agent", host: "127.0.0.1", port: 5901, username: "test-agent", inputApproved: false)
        try profiles.save(profile)
        return (profiles, profile, root)
    }
    func testUnapprovedInputNeverReachesConnection() async throws {
        let (profiles, profile, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = StubSessionConnection()
        let backend = VNCDesktopBackend(profile: profile, profiles: profiles, connection: connection)
        do { _ = try await backend.call(Request(action: "click", arguments: ["x":"1", "y":"1"])); XCTFail("Input was allowed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("input is disabled")) }
        XCTAssertTrue(connection.requests.isEmpty)
        _ = try await backend.call(Request(action: "status"))
        XCTAssertEqual(connection.requests.count, 1)
    }
    func testApprovalAndRevocationApplyToExistingBackend() async throws {
        let (profiles, original, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = StubSessionConnection()
        let backend = VNCDesktopBackend(profile: original, profiles: profiles, connection: connection)
        var current = original; current.inputApproved = true; try profiles.save(current)
        _ = try await backend.call(Request(action: "type", arguments: ["text":"fixture"]))
        current.inputApproved = false; try profiles.save(current)
        do { _ = try await backend.call(Request(action: "type", arguments: ["text":"must not send"])); XCTFail("Revoked input sent") }
        catch {}
        let status = try await backend.call(Request(action: "status"))
        XCTAssertEqual(status.values["inputApproved"], "false")
        XCTAssertEqual(connection.requests.filter { $0.action == "type" }.count, 1)
    }
    func testChangedEndpointInvalidatesApprovalForExistingConnection() async throws {
        let (profiles, original, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = StubSessionConnection()
        let backend = VNCDesktopBackend(profile: original, profiles: profiles, connection: connection)
        var changed = original; changed.inputApproved = true; changed.port = 5999
        try profiles.save(changed)
        do { _ = try await backend.call(Request(action: "key", arguments: ["key":"return"])); XCTFail("Stale target approved") }
        catch {}
        XCTAssertTrue(connection.requests.isEmpty)
    }
    func testImagesAreBoundToRequestAndBounded() async throws {
        let (profiles, profile, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = StubSessionConnection()
        connection.response = VNCResponse(values: ["width":"2", "height":"2"], png: Data([1,2,3]))
        let backend = VNCDesktopBackend(profile: profile, profiles: profiles, connection: connection)
        let request = Request(action: "screenshot")
        let result = try await backend.call(request)
        let name = try XCTUnwrap(result.values["image"])
        XCTAssertEqual(name, "image-\(request.id.uuidString).png")
        XCTAssertThrowsError(try backend.read(name, limit: 2))
        XCTAssertEqual(try backend.read(name, limit: 3), Data([1,2,3]))
        _ = try await backend.call(Request(action: "screenshot"))
        XCTAssertNil(try backend.read(name, limit: 3))
    }
    func testExpiredRequestDoesNotConnect() async throws {
        let (profiles, profile, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = StubSessionConnection()
        let backend = VNCDesktopBackend(profile: profile, profiles: profiles, connection: connection)
        do { _ = try await backend.call(Request(action: "screenshot", timeout: -1)); XCTFail("Expired request sent") }
        catch {}
        XCTAssertTrue(connection.requests.isEmpty)
    }
}
