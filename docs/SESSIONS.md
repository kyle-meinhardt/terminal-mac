# A separate user desktop on the same Mac

This fork adds a Screen Sharing backend alongside the original virtual-machine backend. A session uses another macOS user account on the same installation. There is no IPSW download, guest OS installation, or virtual disk. It shares the Mac's CPU, memory, operating system, network, and system-wide services; ordinary account permissions provide separation, rather than a VM boundary.

## Build

Install Xcode Command Line Tools / Swift 6 and Homebrew, then:

```sh
brew install cmake openssl@4
bash scripts/create-signing-identity.sh 'TerminalMac Session Local'
bash scripts/build.sh
```

Create the local signing identity **before the first build and session configuration**. `scripts/build.sh` automatically prefers `TerminalMac Session Local` when that identity is present. Reusing it lets Keychain recognize later builds as the same application. This is a local self-signed identity, not an Apple notarized release.

During the first signed build, macOS may ask whether `/usr/bin/codesign` can use that identity's private key. Confirm the named identity and tool, enter your Mac login password, and choose **Always Allow** to authorize subsequent builds. The session application may separately request access to its saved Screen Sharing credential on the first actual connection; choose **Always Allow** for that application to keep later connections noninteractive. These are two separate Keychain permissions. Never enter the agent account password into a code-signing-key prompt.

`scripts/build.sh` invokes `scripts/build-session-library.sh` automatically. The session build script downloads a pinned LibVNCClient source archive, verifies its SHA-256, applies this fork's virtual-session negotiation patch, and builds the optional library in `.build/session-libs`. A stock Homebrew LibVNCClient is deliberately rejected: it does not implement the required session selection. The script also places the OpenSSL runtime dependencies beside the library. The VM backend remains available without loading the session library. See [third-party notices](../THIRD_PARTY_NOTICES.md) for the linked program's license and redistribution requirements. Original upstream releases and the upstream curl installer do not include this fork's session commands. Session runtime compatibility also depends on the macOS minimum version of the installed Homebrew crypto libraries; a local build is not a claim of compatibility with every macOS version supported by the original VM backend.

For inline viewing, use Ghostty, Kitty, or iTerm2 outside tmux. Apple's Terminal.app does not support the graphics protocols this viewer uses.

## Prepare the account and connection

1. In System Settings → Users & Groups, create a **standard** account such as `agent`. Log in once to complete account setup.
2. In System Settings → General → Sharing, enable **Screen Sharing** and **Remote Login**. Add the account to each service's allowed users. These are separate access lists.
3. Keep your own account logged in. In Terminal, start a loopback tunnel:

   ```sh
   ssh -N -o ExitOnForwardFailure=yes \
     -L 127.0.0.1:5901:127.0.0.1:5900 agent@127.0.0.1
   ```

   Authenticate with the account's login password. A successful tunnel stays running without a prompt. The SSH account can be different from the Screen Sharing account.
4. In another terminal tab, open Apple's Screen Sharing client:

   ```sh
   open 'vnc://127.0.0.1:5901'
   ```

   Authenticate as `agent` and choose **Log In / a separate desktop** if offered, rather than sharing the physical console. Verify that your own desktop remains active and the remote window shows the other account. Once account setup is complete, close the native Screen Sharing window before using the terminal viewer, while leaving the account logged in. Another connected viewer can retain input control.

Apple documents [virtual desktop connections](https://support.apple.com/guide/remote-desktop/choose-how-to-control-and-observe-apd4f46319e/mac). The [same-Mac SSH tunnel technique](https://macmost.com/screen-share-with-another-account-on-the-same-mac.html) is a workaround for the native client's direct loopback restriction; it must be checked on the macOS version in use.

## Configure and inspect the terminal viewer

```sh
./dist/terminal-mac session configure agent \
  --host 127.0.0.1 --port 5901 --user agent
./dist/terminal-mac session view agent --read-only
```

Configuration prompts for the Screen Sharing account password without echoing it and stores it in the current user's macOS Keychain. Use the stable signing identity from the build steps above before saving this credential. An ad-hoc-signed build can require new Keychain authorization after each rebuild; switching identities can also require one new authorization from an interactive terminal. Passwords do not belong in command arguments, environment variables, profile JSON, shell history, or MCP settings. Session profiles live in `~/Library/Application Support/terminal-mac/sessions/NAME/session.json`; `TERMINAL_MAC_HOME` selects a different data root. Profiles are private to the current user. Reconfiguring a profile clears its input approval.

To open the viewer in a new Ghostty window from any terminal:

```sh
bash scripts/open-session.sh agent --read-only
```

After approving input, omit `--read-only` for an interactive viewer.

The viewer renders the VNC framebuffer inside the terminal using the existing terminal-mac graphics renderer. It does not capture the host desktop through ScreenCaptureKit or inject host HID events. **Ctrl+]** exits; the SSH tunnel and macOS user session remain running.

**Inspect the read-only preview before approving input.** Confirm that the desktop belongs to the `agent` account and that it differs from your physical desktop. If it shows your normal account, a login prompt, or a session-choice dialog, exit and resolve the target in Apple's Screen Sharing app first.

This fork's patched LibVNCClient preserves Apple's `003.889` protocol, requests the extended session picker, and asks for **command 2: a virtual user desktop**. It requires a successful virtual-session grant and rejects servers that offer only the physical console. It never falls back to sharing your normal desktop. Authentication and the session grant still do not independently prove the displayed account identity: inspect the preview and test simultaneous use on the target Mac. Keep the native client available for initial login and account setup.

After inspecting the target:

```sh
./dist/terminal-mac session approve agent
./dist/terminal-mac session view agent
```

`approve` asks you to type the configured username. Unapproved profiles allow observation but reject input. Approval is a user assertion about the configured target, not hardware attestation or a strong session-identity check. Recheck the target after a logout, restart, server change, or any unexpected desktop change. Do not approve a profile merely because authentication succeeded. Disable input immediately when the target is uncertain:

```sh
./dist/terminal-mac session revoke agent
```

The backend checks saved approval before each input action, including actions from an already-running viewer or MCP server. Revoke does not log out the account or close the SSH tunnel.

## Agent controls

Capture and inspect an image before using coordinates:

```sh
./dist/terminal-mac session action agent screenshot --output /tmp/agent-desktop.png
./dist/terminal-mac session action agent status
./dist/terminal-mac session action agent click 640 400
./dist/terminal-mac session action agent type 'Hello from the agent'
./dist/terminal-mac session action agent key cmd+space
```

Coordinates are pixels of the returned screenshot, with the origin at the top left. Screenshots and actions use the same VNC connection backend. Screen Sharing supplies the desktop pixels and handles remote input; this is independent of the original VM guest helper.

For an MCP client, print the connection configuration:

```sh
./dist/terminal-mac session mcp agent --config
```

Add that generated server entry to your MCP client's settings. The server offers `screenshot`, `status`, `click`, `move`, `drag`, `scroll`, `type`, and `key`. It uses the saved profile and Keychain item; MCP configuration contains no password. The agent should observe → act → observe, stop if the target changes, and leave login/permission dialogs to the user. The original `terminal-mac mcp` command continues to target a VM; use `session mcp` for this backend.

## Limits and validation

- The backend accepts loopback endpoints only. Use an SSH tunnel rather than exposing an unencrypted VNC connection.
- Apps, browser profiles, and sign-ins belong to the second user. They do not inherit your main account's authenticated sessions.
- Account separation does not protect system-wide resources like a VM. Use a standard account and grant only the files and services the agent needs.
- A macOS Space or a second monitor in your own account is not a separate user session.
- Apple authentication and separate-session behavior vary by macOS release. Mock protocol tests and a successful build do not establish live session isolation. Validate screenshots, typing, clicks, reconnects, and simultaneous local typing before unattended use.
- The implementation does not relay the host clipboard. Any native Screen Sharing clipboard synchronization is a separate setting in that application.
- Session scrolling is vertical only. Horizontal requests are rejected before input; drag a horizontal scrollbar instead.
- Session typing supports Basic Multilingual Plane text, including accented characters such as `café` and symbols such as `✓`. Supplementary Unicode characters, including most emoji, are rejected before any part of the supplied text is typed.
- If screenshots update but input has no effect, close other Screen Sharing viewers of that account and reconnect the terminal session. Handle the account login and permission prompts through the native client when necessary, then close its window again.
- A sleeping or closed-lid host can cause Keychain error `-25320` (`errSecInDarkWake`, no UI possible). Wake the physical Mac and retry before changing the saved password or account configuration.

## Session validation record

On November 6, 2026, the development build on Apple silicon / macOS 27.2 passed 33 Swift tests and 14 RFB protocol fixtures. The fixtures cover the Apple virtual-session handshake, real ARD Diffie–Hellman credential exchange against a local mock server, framebuffer behavior, encrypted keystroke and pointer decryption with rejection of plaintext input, button mapping, vertical wheel pulses and rejection of horizontal requests without input, Retina framebuffer pixel coordinates, complete first-frame coverage, and rejection of unsupported or denied session selection. A live MCP screenshot of the separate desktop was captured successfully on that Mac. These results do not establish compatibility with every macOS release.

Live checks on that Mac verified MCP screenshots, ordinary text and BMP Unicode entry (`café ✓`), clicks, dragging, and calibrated vertical scrolling. Before/after checks showed the agent desktop changing while the host desktop stayed unchanged. A 15-second read-only PTY viewer probe emitted five complete iTerm inline PNG images, exited through Ctrl+], and restored terminal state. The user also confirmed that the actual Ghostty window displayed the agent desktop. The PTY capture verifies emitted terminal graphics; the Ghostty confirmation is user-observed, without GUI automation.

Horizontal wheel scrolling is unavailable; drag a horizontal scrollbar instead. No idle CPU claim is made from the startup/rendering samples. These checks apply to this Mac and macOS build; a server grant or successful screenshot alone does not prove every input behavior on another system.
