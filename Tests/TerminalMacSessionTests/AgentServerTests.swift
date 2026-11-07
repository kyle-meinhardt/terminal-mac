import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import TerminalMacCore
@testable import TerminalMac

@MainActor
final class AgentServerTests: XCTestCase {
    private func fixture(approved: Bool = true) throws -> (AgentServer, VNCDesktopBackend, StubSessionConnection, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profiles = SessionProfiles(store: Store(root: root))
        let profile = SessionProfile(name: "mcp-fixture", host: "127.0.0.1", port: 5901,
                                     username: "mcp-test-agent", inputApproved: approved)
        try profiles.save(profile)
        let connection = StubSessionConnection()
        let backend = VNCDesktopBackend(profile: profile, profiles: profiles, connection: connection)
        return (AgentServer(backend: backend, name: profile.name), backend, connection, root)
    }

    private func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    func testStatusAndScreenshotUseSessionBackendWithoutVM() async throws {
        let (server, backend, connection, root) = try fixture(approved: false)
        defer { try? FileManager.default.removeItem(at: root) }
        connection.response = VNCResponse(values: ["sessionIdentity": "fixture"])
        let status = try await server.call("status", [:])
        let text = try XCTUnwrap(status.first?["text"] as? String)
        XCTAssertTrue(text.contains("Session 'mcp-fixture' is connected."))
        XCTAssertTrue(text.contains("inputApproved: false"))
        XCTAssertFalse(text.contains("VM '"))

        connection.response = VNCResponse(values: ["width": "3", "height": "2"], png: try png())
        let content = try await server.call("screenshot", [:])
        XCTAssertEqual(content.first?["mimeType"] as? String, "image/jpeg")
        let base64 = try XCTUnwrap(content.first?["data"] as? String)
        let jpeg = try XCTUnwrap(Data(base64Encoded: base64))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
        XCTAssertTrue((content.last?["text"] as? String)?.contains("3×2") == true)
        XCTAssertEqual(connection.requests.map(\.action), ["status", "screenshot"])
        let screenshotRequest = try XCTUnwrap(connection.requests.last)
        XCTAssertNil(try backend.read("image-\(screenshotRequest.id.uuidString).png", limit: 1024 * 1024), "MCP must clean up the backend image after encoding")
    }

    func testMultiClickAndDragPreserveRemoteCoordinates() async throws {
        let (server, _, connection, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await server.call("click", ["x": 40, "y": 60, "button": "right", "clicks": 3])
        XCTAssertEqual(connection.requests.count, 3)
        XCTAssertEqual(connection.requests.map { $0.arguments["count"] ?? "1" }, ["1", "2", "3"])
        XCTAssertTrue(connection.requests.allSatisfy { $0.arguments["x"] == "40" && $0.arguments["y"] == "60" && $0.arguments["button"] == "right" })
        _ = try await server.call("drag", ["x": 4, "y": 6, "toX": 104, "toY": 206])
        let drag = try XCTUnwrap(connection.requests.last)
        XCTAssertEqual(drag.action, "drag")
        XCTAssertEqual(drag.arguments, ["x": "4", "y": "6", "x2": "104", "y2": "206"])
    }

    func testMalformedToolsAndUnapprovedMutationsNeverReachConnection() async throws {
        let (server, _, connection, root) = try fixture(approved: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for arguments: [String: Any] in [["x": true, "y": 1], ["x": 1.5, "y": 1], ["x": 1], ["x": "1", "y": 1]] {
            do { _ = try await server.call("click", arguments); XCTFail("Malformed coordinates were accepted") }
            catch {}
        }
        do { _ = try await server.call("type", ["text": ""]); XCTFail("Empty text was accepted") }
        catch {}
        do { _ = try await server.call("unknown", [:]); XCTFail("Unknown tool was accepted") }
        catch {}
        do { _ = try await server.call("click", ["x": 1, "y": 1]); XCTFail("Unapproved mutation was accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("input is disabled")) }
        XCTAssertTrue(connection.requests.isEmpty)
    }

    func testInvalidScreenshotIsRejectedAndCleanedUp() async throws {
        let (server, backend, connection, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        connection.response = VNCResponse(png: Data([0, 1, 2]))
        do { _ = try await server.call("screenshot", [:]); XCTFail("Invalid image was returned to the model") }
        catch { XCTAssertTrue(error.localizedDescription.contains("invalid screenshot")) }
        let request = try XCTUnwrap(connection.requests.last)
        XCTAssertNil(try backend.read("image-\(request.id.uuidString).png", limit: 10))
    }

    func testSessionToolDiscoveryDoesNotNeedCredentialOrConnection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profiles = SessionProfiles(store: Store(root: root))
        let profile = SessionProfile(name: "never-configured", host: "127.0.0.1", port: 65535, username: "mcp-test-agent")
        // This profile has never been saved and has no Keychain item or listener.
        let backend = VNCDesktopBackend(profile: profile, profiles: profiles,
                                        connection: KeychainSessionConnection(profile: profile, profiles: profiles))
        let server = AgentServer(backend: backend, name: profile.name)
        XCTAssertEqual(server.toolDefinitions.count, AgentServer.tools.count)
        XCTAssertTrue(server.serverInstructions.contains("It is not a VM"))
        let screenshot = try XCTUnwrap(server.toolDefinitions.first { $0["name"] as? String == "screenshot" })
        XCTAssertTrue((screenshot["description"] as? String)?.contains("separate macOS user desktop") == true)
    }
}
