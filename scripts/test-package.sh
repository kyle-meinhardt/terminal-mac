#!/bin/bash
set -euo pipefail
[[ $# -eq 1 ]] || { echo 'Usage: bash scripts/test-package.sh /absolute/path/to/release.zip' >&2; exit 1; }
archive="$1"
work="$(mktemp -d "${TMPDIR:-/tmp}/terminal-mac-package-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
ditto -x -k "$archive" "$work/unpacked"
installer="$(find "$work/unpacked" -name install.sh -type f | head -1)"
[[ -n "$installer" ]] || { echo 'Release installer is missing.' >&2; exit 1; }
prefix="$work/prefix with spaces"
bash "$installer" --prefix "$prefix"
bash "$installer" --prefix "$prefix"
launcher="$prefix/bin/terminal-mac"
# The version must come from the installed bundle, not a fallback.
expected="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(dirname "$installer")/TerminalMac.app/Contents/Info.plist")"
[[ "$("$launcher" --version)" == "terminal-mac $expected" ]] || { echo "Version mismatch: $("$launcher" --version), expected $expected" >&2; exit 1; }
# Exercise the installed C bridge loader at a relocated path, without Keychain
# access or a session connection. The complete runtime must travel with the app.
TERMINAL_MAC_HOME="$work/unused-data" "$launcher" doctor > "$work/doctor.json"
TERMINAL_MAC_HOME="$work/unused-data" "$launcher" session mcp agent --config > "$work/session-config.json"
python3 - "$launcher" "$work/doctor.json" "$work/session-config.json" <<'PYSESSION'
import json, pathlib, subprocess, sys

launcher, doctor_file, config_file = sys.argv[1:]
doctor = json.load(open(doctor_file))
assert doctor['sessionLibraryAvailable'] == 'true', doctor
binary = pathlib.Path(launcher).resolve()
app = binary.parents[2]
frameworks = app / 'Contents/Frameworks'
libraries = list(frameworks.glob('*.dylib'))
assert (frameworks / 'libvncclient-session.dylib').is_file()
assert any(path.name.startswith('libcrypto.') for path in libraries), libraries
for library in libraries:
    listing = subprocess.check_output(['otool', '-L', str(library)], text=True).splitlines()[2:]
    for row in listing:
        dependency = row.strip().split(' (', 1)[0]
        if dependency.startswith('@loader_path/'):
            assert (library.parent / dependency[len('@loader_path/'):]).is_file(), dependency
        else:
            assert dependency.startswith(('/usr/lib/', '/System/Library/')), dependency
licenses = app / 'Contents/Resources/licenses'
for relative in ['LICENSE', 'THIRD_PARTY_NOTICES.md', 'GPL-2.0.txt', 'GPL-3.0.txt',
                 'OpenSSL-Apache-2.0.txt', 'libvncclient-source.tar.gz',
                 'build-session-library.sh', 'patches/libvncclient-virtual-session.patch']:
    file = licenses / relative
    assert file.is_file() and file.stat().st_size > 0, file
config = json.load(open(config_file))['mcpServers']['terminal-mac-session-agent']
assert pathlib.Path(config['command']).resolve() == binary, config
assert config['args'] == ['session', 'mcp', 'agent'], config
PYSESSION
TERMINAL_MAC_HOME="$work/unused-data" "$launcher" up test --plan > "$work/plan.json"
[[ ! -e "$work/unused-data" ]] || { echo 'Plan unexpectedly created VM data.' >&2; exit 1; }
python3 - "$work/plan.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
assert plan['name'] == 'test'
assert plan['steps'][0] == 'download-or-reuse-apple-restore-image'
PY
# The guard refuses physical Macs. CI runners are themselves virtual Macs, where it must allow.
if [[ "$(sysctl -n hw.model)" == VirtualMac* ]]; then
  "$launcher" guest --check | grep -q '^virtual-mac$' || { echo 'Guest guard rejected a virtual Mac.' >&2; exit 1; }
else
  if "$launcher" guest --check > "$work/guard.log" 2>&1; then echo 'Guest guard unexpectedly allowed the physical host.' >&2; exit 1; fi
  grep -q 'only runs inside a virtual Mac' "$work/guard.log"
fi
TERMINAL_MAC_HOME="$work/unused-data" "$launcher" skills get | grep -q '^name: terminal-mac$'
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | TERMINAL_MAC_HOME="$work/unused-data" "$launcher" mcp | grep -q '"screenshot"'
python3 - "$launcher" "$work/unused-data" <<'PYTEST'
import json, os, subprocess, sys

launcher, data_root = sys.argv[1:]
coordinates = (1e30, -1e30, 0.5, True, "12", 12, 12.0)
requests = [
    {"jsonrpc": "2.0", "id": index, "method": "tools/call",
     "params": {"name": "click", "arguments": {"x": x, "y": 0}}}
    for index, x in enumerate(coordinates)
]
requests.append({"jsonrpc": "2.0", "id": len(coordinates), "method": "ping"})
result = subprocess.run(
    [launcher, "mcp"], input="".join(json.dumps(request) + "\n" for request in requests),
    env={**os.environ, "TERMINAL_MAC_HOME": data_root}, capture_output=True,
    text=True, check=True, timeout=10,
)
responses = {reply["id"]: reply["result"] for reply in map(json.loads, result.stdout.splitlines())}
for index, x in enumerate(coordinates):
    response = responses[index]
    assert response["isError"], response
    message = response["content"][0]["text"]
    expected = "No virtual Mac named" if index >= 5 else "Expected an integer in range for 'x'"
    assert expected in message, (x, message)
assert responses[len(coordinates)] == {}, responses
PYTEST
if "$launcher" up ../escape --plan > "$work/name.log" 2>&1; then echo 'Invalid machine name was accepted.' >&2; exit 1; fi
conflict="$work/conflict"
mkdir -p "$conflict/bin"
echo 'preserve me' > "$conflict/bin/terminal-mac"
if bash "$installer" --prefix "$conflict" > "$work/conflict.log" 2>&1; then echo 'Unrelated executable was overwritten.' >&2; exit 1; fi
[[ "$(cat "$conflict/bin/terminal-mac")" = 'preserve me' ]]
codesign --verify --deep --strict "$(dirname "$installer")/TerminalMac.app"
echo 'Package checks passed: clean extraction, repeated installation, paths with spaces, relocated session runtime/dependencies/licenses, session MCP configuration without credentials, plan without writes, host guard, invalid names, unrelated executable preservation, signatures, bundled skill, MCP tool list.'
