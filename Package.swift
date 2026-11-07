// swift-tools-version: 6.0
import PackageDescription
import Foundation

let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vncIncludes = [repositoryRoot + "/.build/session-library/build/include",
                   repositoryRoot + "/.build/session-library/source/include"]

let package = Package(
    name: "terminal-mac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "terminal-mac", targets: ["TerminalMac"])],
    targets: [
        .target(name: "TerminalMacCore"),
        .target(name: "CPhoneShim"),
        .target(name: "CVNCBridge", cSettings: [.unsafeFlags(vncIncludes.flatMap { ["-I", $0] })]),
        .target(name: "TerminalUI", dependencies: ["CPhoneShim"]),
        .executableTarget(name: "TerminalMac", dependencies: ["TerminalMacCore", "TerminalUI", "CPhoneShim", "CVNCBridge"],
            linkerSettings: [.linkedFramework("Virtualization"), .linkedFramework("AppKit"),
                             .linkedFramework("ScreenCaptureKit"), .linkedFramework("ApplicationServices"), .linkedFramework("ServiceManagement"), .linkedFramework("CoreMedia")]),
        .testTarget(name: "TerminalMacCoreTests", dependencies: ["TerminalMacCore"]),
        .testTarget(name: "TerminalMacSessionTests", dependencies: ["TerminalMac", "TerminalMacCore", "CVNCBridge"])
    ],
    swiftLanguageModes: [.v5]
)
