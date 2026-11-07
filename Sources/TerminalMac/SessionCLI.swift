import AppKit
import Darwin
import TerminalMacCore

extension CLI {
    func session(_ input: [String]) async throws {
        let command = input.first ?? "help"
        let tail = Array(input.dropFirst())
        let profiles = SessionProfiles(store: store)
        switch command {
        case "help", "--help", "-h": print(Self.sessionHelp)
        case "configure":
            let args = try Arguments(tail, options: ["host", "port", "user"])
            let name = try sessionName(args)
            let existing = try? profiles.load(name)
            let profile = SessionProfile(name: name, host: args.options["host"] ?? existing?.host ?? "127.0.0.1",
                                         port: try args.integer("port", default: existing?.port ?? 5901, range: 1...65535),
                                         username: args.options["user"] ?? existing?.username ?? "agent", inputApproved: false)
            try profile.validate()
            let password = try SessionProfiles.promptPassword()
            try profiles.savePassword(password, name: name)
            try profiles.save(profile)
            try printJSON(["session": name, "host": profile.host, "port": String(profile.port), "username": profile.username,
                           "inputApproved": "false", "credential": "Keychain"])
            stderr("Next: terminal-mac session view \(name) --read-only. Confirm it shows the separate \(profile.username) desktop, then run session approve \(name).")
        case "approve":
            let args = try Arguments(tail)
            let name = try sessionName(args)
            var profile = try profiles.load(name)
            guard isatty(STDIN_FILENO) == 1 else { throw Failure("Session approval requires an interactive terminal") }
            stderr("Approve input only after viewing this connection with `terminal-mac session view \(name) --read-only`.")
            stderr("Confirm the desktop belongs to '\(profile.username)' and your physical desktop stays independent.")
            stderr("This is a user-account session on your Mac, not a VM. Type the account short username to approve input:")
            guard readLine() == profile.username else { throw Failure("Session input was not approved") }
            profile.inputApproved = true
            try profiles.save(profile)
            try printJSON(["session": name, "inputApproved": "true"])
        case "revoke":
            let args = try Arguments(tail)
            let name = try sessionName(args)
            var profile = try profiles.load(name)
            profile.inputApproved = false
            try profiles.save(profile)
            try printJSON(["session": name, "inputApproved": "false"])
        case "view":
            let args = try Arguments(tail, flags: ["read-only"], options: ["protocol"])
            let name = try sessionName(args)
            let profile = try profiles.load(name)
            let readOnly = args.flags.contains("read-only")
            guard readOnly || profile.inputApproved else {
                throw Failure("First view with --read-only and run: terminal-mac session approve \(name)")
            }
            let backend = VNCDesktopBackend(profile: profile, profiles: profiles, connection: KeychainSessionConnection(profile: profile, profiles: profiles))
            let viewer = try TerminalViewer(backend: backend, name: name, graphics: args.options["protocol"], readOnly: readOnly)
            try await viewer.run()
        case "action": try await sessionAction(tail, profiles: profiles)
        case "mcp":
            let args = try Arguments(tail, flags: ["config"])
            let name = try sessionName(args)
            if args.flags.contains("config") {
                var server: [String: Any] = ["command": launcherPath, "args": ["session", "mcp", name]]
                if ProcessInfo.processInfo.environment["TERMINAL_MAC_HOME"] != nil {
                    server["env"] = ["TERMINAL_MAC_HOME": store.root.path]
                }
                let data = try JSONSerialization.data(withJSONObject: ["mcpServers": ["terminal-mac-session-\(name)": server]],
                                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                print(String(decoding: data, as: UTF8.self)); return
            }
            let profile = try profiles.load(name)
            let backend = VNCDesktopBackend(profile: profile, profiles: profiles, connection: KeychainSessionConnection(profile: profile, profiles: profiles))
            try await AgentServer(backend: backend, name: name).run()
        default: throw Failure("Unknown session command: \(command). Run: terminal-mac session help")
        }
    }

    private func sessionName(_ args: Arguments) throws -> String {
        guard args.positionals.count <= 1 else { throw Failure("Expected one session name") }
        let name = args.positionals.first ?? "agent"
        try validateName(name)
        return name
    }

    private func sessionAction(_ input: [String], profiles: SessionProfiles) async throws {
        let args = try Arguments(input, flags: ["double"], options: ["x", "y", "x2", "y2", "dx", "dy", "text", "key", "button", "count", "output", "timeout"])
        let actions: Set<String> = ["status", "screenshot", "snapshot", "click", "move", "drag", "scroll", "type", "key"]
        var positions = args.positionals
        let name: String
        if let first = positions.first, actions.contains(first) { name = "agent" }
        else {
            guard !positions.isEmpty else { throw Failure("Usage: terminal-mac session action [NAME] status|screenshot|click|type|key|scroll") }
            name = positions.removeFirst()
        }
        let profile = try profiles.load(name)
        guard !positions.isEmpty, actions.contains(positions[0]) else { throw Failure("Unknown or missing session action") }
        let verb = positions.removeFirst()
        var parameters = args.options
        parameters.removeValue(forKey: "output"); parameters.removeValue(forKey: "timeout")
        if verb == "type", !positions.isEmpty { parameters["text"] = positions.joined(separator: " "); positions.removeAll() }
        if verb == "key", positions.count == 1 { parameters["key"] = positions.removeFirst() }
        if ["click", "move"].contains(verb), positions.count == 2 { parameters["x"] = positions.removeFirst(); parameters["y"] = positions.removeFirst() }
        if verb == "drag", positions.count == 4 {
            for key in ["x", "y", "x2", "y2"] { parameters[key] = positions.removeFirst() }
        }
        guard positions.isEmpty else { throw Failure("Unexpected session action arguments") }
        if args.flags.contains("double") { parameters["double"] = "true" }
        let timeout = try args.integer("timeout", default: 15, range: 1...120)
        let backend = VNCDesktopBackend(profile: profile, profiles: profiles, connection: KeychainSessionConnection(profile: profile, profiles: profiles))
        let request = Request(action: verb, arguments: parameters, timeout: Double(timeout))
        let imageName = "image-\(request.id.uuidString).png"
        defer { backend.remove(imageName) }
        let reply = try await backend.call(request)
        var values = reply.values
        if verb == "screenshot" || verb == "snapshot" {
            guard values["image"] == imageName, let png = try backend.read(imageName, limit: 64 * 1024 * 1024) else { throw Failure("Invalid session image response") }
            let output = URL(fileURLWithPath: ((args.options["output"] ?? "terminal-mac-session-\(name).png") as NSString).expandingTildeInPath)
            try png.write(to: output, options: .atomic)
            values["image"] = output.path
        }
        try printJSON(values)
    }

    static let sessionHelp = """
    terminal-mac session — a separate user desktop through local Screen Sharing

    configure [NAME] [--host 127.0.0.1 --port 5901 --user agent]
                                  Hidden password prompt; save credential in Keychain
    view [NAME] --read-only        Verify the separate desktop before approving input
      [--protocol kitty|iterm]     Requires Ghostty, Kitty or iTerm2; Ctrl+] exits
    approve [NAME]                Interactively approve input to the verified desktop
    revoke [NAME]                 Disable input for existing and new connections
    view [NAME]                   View and control the approved desktop in a terminal
    action [NAME] status|screenshot|click|move|drag|scroll|type|key
                                  Same action arguments as the VM action command
    mcp [NAME] [--config]          Agent tools over stdio, or print MCP configuration

    Default NAME is agent. Create and log into a separate standard macOS user first.
    Enable Screen Sharing for that user. For a same-Mac connection, keep this running:
      ssh -N -L 127.0.0.1:5901:127.0.0.1:5900 agent@127.0.0.1
    Authentication uses the macOS account, not the legacy VNC password option.
    Apple session selection is not guaranteed by the username alone: verify the desktop.
    This session shares your Mac's OS and is not a virtual-machine security boundary.
    """
}
