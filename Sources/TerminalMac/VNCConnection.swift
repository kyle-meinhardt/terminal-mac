import CoreGraphics
import CVNCBridge
import Foundation
import ImageIO
import TerminalMacCore
import UniformTypeIdentifiers

struct VNCResponse {
    let values: [String: String]
    let png: Data?
    init(values: [String: String] = [:], png: Data? = nil) { self.values = values; self.png = png }
}

/// A connection owns one VNC socket. All socket/decoder access stays on its serial queue.
/// It neither captures the host screen nor posts host input events.
final class VNCConnection: @unchecked Sendable {
    static var available: Bool { tm_vnc_available() != 0 }
    private let queue = DispatchQueue(label: "terminal-mac.vnc", qos: .userInteractive)
    private var connection: OpaquePointer?
    private var connected = false
    private var failed = false
    private var capturedFrame = false
    private var pointer = (x: 0, y: 0)
    private let username: String

    init(host: String, port: Int, username: String, password: String) throws {
        let host = host == "localhost" ? "127.0.0.1" : host
        guard ["127.0.0.1", "::1"].contains(host), (1...65535).contains(port) else {
            throw Failure("Session connections must use a loopback address and port 1–65535")
        }
        guard !username.isEmpty, !password.isEmpty, username.utf8.count <= 63, password.utf8.count <= 63,
              !username.contains("\0"), !password.contains("\0") else {
            throw Failure("ARD requires a username and password of 1–63 UTF-8 bytes without NUL characters")
        }
        guard Self.available else { throw Failure("Session mode needs the patched LibVNCClient. Run: bash scripts/build-session-library.sh, then bash scripts/build.sh") }
        self.username = username
        connection = tm_vnc_create(host, Int32(port), username, password)
        guard connection != nil else { throw Failure("Cannot initialize Screen Sharing connection") }
    }
    deinit { if let connection { tm_vnc_destroy(connection) } }

    func connect() async throws {
        try await perform { try self.ensureConnected() }
    }

    func call(_ request: Request) async throws -> VNCResponse {
        try await perform {
            guard Date() < request.deadline else { throw Failure("Session request expired before execution") }
            // A first connection may create the user's virtual display. Give the
            // action its original budget after that one-time handshake, rather
            // than expiring the screenshot before it has even been requested.
            let wasConnected = self.connected, started = Date()
            try self.ensureConnected()
            let deadline = wasConnected ? request.deadline : request.deadline.addingTimeInterval(Date().timeIntervalSince(started))
            return try self.handle(request, deadline: deadline)
        }
    }

    private func perform<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
    private func ensureConnected() throws {
        guard let connection, !failed else { throw Failure("Screen Sharing connection closed. Reconnect and verify the agent desktop.") }
        guard !connected else { return }
        guard tm_vnc_connect(connection) != 0 else { failed = true; throw error() }
        connected = true
    }
    private func error() -> Failure {
        Failure(connection.map { String(cString: tm_vnc_error($0)) } ?? "Screen Sharing connection closed")
    }
    private func checked(_ result: Int32) throws {
        guard result != 0 else { failed = true; throw Failure("Screen Sharing connection failed. Reconnect and verify the agent desktop.") }
    }
    private var width: Int { Int(tm_vnc_width(connection)) }
    private var height: Int { Int(tm_vnc_height(connection)) }
    private func status() -> [String: String] {
        ["backend": "screen-sharing", "width": String(width), "height": String(height),
         "pointWidth": String(width), "pointHeight": String(height), "authenticatedUser": username,
         "sessionType": "virtual", "sessionIdentity": "virtual session granted; visually verify the account desktop", "screenRecording": "true", "accessibility": "true"]
    }
    private func handle(_ request: Request, deadline: Date) throws -> VNCResponse {
        let a = request.arguments
        func number(_ key: String, _ range: ClosedRange<Int>, fallback: Int? = nil) throws -> Int {
            if a[key] == nil, let fallback { return fallback }
            guard let raw = a[key], let n = Int(raw), range.contains(n) else { throw Failure("Invalid '\(key)' for session action") }
            return n
        }
        func point(_ x: String = "x", _ y: String = "y") throws -> (Int, Int) {
            guard width > 0, height > 0 else { throw Failure("No Screen Sharing framebuffer") }
            return (try number(x, 0...(width - 1)), try number(y, 0...(height - 1)))
        }
        func mouse(_ x: Int, _ y: Int, _ mask: Int32 = 0) throws {
            try checked(tm_vnc_pointer(connection, Int32(x), Int32(y), mask)); pointer = (x, y)
        }
        switch request.action {
        case "status": return VNCResponse(values: status())
        case "screenshot", "snapshot":
            let previous = tm_vnc_sequence(connection)
            try checked(tm_vnc_request_frame(connection))
            let frameDeadline = min(deadline, Date().addingTimeInterval(8))
            while tm_vnc_sequence(connection) == previous, Date() < frameDeadline {
                if tm_vnc_poll(connection, 50) < 0 { failed = true; throw error() }
            }
            guard tm_vnc_sequence(connection) > previous else { throw Failure("Timed out waiting for a fresh Screen Sharing frame") }
            // Apple sends the initial desktop as multiple framebuffer messages.
            // Drain that burst before encoding, rather than returning the first
            // tiny dirty rectangle against an otherwise empty framebuffer.
            let settleDeadline = min(deadline, Date().addingTimeInterval(capturedFrame ? 0.35 : 2))
            let minimumSettle = Date().addingTimeInterval(capturedFrame ? 0 : 1)
            let quietInterval = capturedFrame ? 0.075 : 0.20
            var sequence = tm_vnc_sequence(connection), lastChange = Date()
            while Date() < settleDeadline, Date() < minimumSettle || Date().timeIntervalSince(lastChange) < quietInterval {
                if tm_vnc_poll(connection, 25) < 0 { failed = true; throw error() }
                let current = tm_vnc_sequence(connection)
                if current != sequence { sequence = current; lastChange = Date() }
            }
            capturedFrame = true
            return VNCResponse(values: status(), png: try png())
        case "move":
            let (x, y) = try point(); try mouse(x, y)
        case "click":
            let (x, y) = try point()
            let mask: Int32 = a["button"] == "right" ? 4 : 1
            let clicks = a["double"] == "true" ? 2 : 1
            for _ in 0..<clicks { try mouse(x, y, mask); try mouse(x, y) }
        case "drag":
            let (x, y) = try point(), (x2, y2) = try point("x2", "y2")
            try mouse(x, y, 1)
            defer { _ = tm_vnc_pointer(connection, Int32(x2), Int32(y2), 0) }
            let steps = min(30, max(2, Int(hypot(Double(x2 - x), Double(y2 - y)) / 12)))
            for step in 1...steps {
                let px = x + (x2 - x) * step / steps, py = y + (y2 - y) * step / steps
                try mouse(px, py, 1); Thread.sleep(forTimeInterval: 0.008)
            }
            try mouse(x2, y2)
        case "scroll":
            if a["x"] != nil { let (x, y) = try point(); try mouse(x, y) }
            let dy = try number("dy", -1000...1000), dx = try number("dx", -1000...1000, fallback: 0)
            try checked(tm_vnc_scroll(connection, Int32(pointer.x), Int32(pointer.y), Int32(dx), Int32(dy)))
        case "type":
            guard let text = a["text"], text.utf8.count <= 32768 else { throw Failure("Provide text (maximum 32 KiB)") }
            for scalar in text.unicodeScalars {
                let key: UInt32
                switch scalar.value {
                case 10, 13: key = 0xff0d
                case 9: key = 0xff09
                default: key = scalar.value <= 0xff ? scalar.value : 0x01000000 | scalar.value
                }
                try checked(tm_vnc_key(connection, key, 1)); try checked(tm_vnc_key(connection, key, 0))
            }
        case "key": try chord(a["key"] ?? "")
        default: throw Failure("Unknown Screen Sharing action: \(request.action)")
        }
        return VNCResponse(values: status())
    }
    private func chord(_ chord: String) throws {
        let parts = chord.lowercased().split(separator: "+").map(String.init)
        guard let name = parts.last else { throw Failure("Provide a key or chord") }
        let keys: [String: UInt32] = ["return": 0xff0d, "enter": 0xff0d, "tab": 0xff09,
            "escape": 0xff1b, "esc": 0xff1b, "backspace": 0xff08, "delete": 0xffff,
            "left": 0xff51, "up": 0xff52, "right": 0xff53, "down": 0xff54,
            "home": 0xff50, "end": 0xff57, "pageup": 0xff55, "pagedown": 0xff56, "space": 0x20]
        let key: UInt32
        if let known = keys[name] { key = known }
        else if name.first == "f", let n = Int(name.dropFirst()), (1...20).contains(n) { key = 0xffbd + UInt32(n) }
        else if name.unicodeScalars.count == 1, let scalar = name.unicodeScalars.first {
            key = scalar.value <= 0xff ? scalar.value : 0x01000000 | scalar.value
        } else { throw Failure("Unknown session key: \(name)") }
        let modifiers: [String: UInt32] = ["cmd": 0xffe7, "command": 0xffe7, "ctrl": 0xffe3, "control": 0xffe3,
            "alt": 0xffe9, "option": 0xffe9, "shift": 0xffe1]
        let held = try parts.dropLast().map { modifier -> UInt32 in
            guard let code = modifiers[modifier] else { throw Failure("Unknown modifier: \(modifier)") }; return code
        }
        defer { for code in held.reversed() { _ = tm_vnc_key(connection, code, 0) } }
        for code in held { try checked(tm_vnc_key(connection, code, 1)) }
        try checked(tm_vnc_key(connection, key, 1)); try checked(tm_vnc_key(connection, key, 0))
    }
    private func png() throws -> Data {
        guard let pixels = tm_vnc_pixels(connection), width > 0, height > 0 else { throw Failure("No Screen Sharing frame") }
        let data = Data(bytes: pixels, count: width * height * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue).union(.byteOrder32Little),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Failure("Cannot decode Screen Sharing frame") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw Failure("Cannot encode Screen Sharing frame") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure("Cannot encode Screen Sharing frame") }
        return output as Data
    }
}
