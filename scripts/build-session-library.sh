#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Pinned LibVNCClient source, with the separate-session handshake in the reviewed patch.
# This script deliberately builds no VNC server, examples or file-transfer capability.
revision=9b54b1ec32731bd23158ca014dc18014db4194c3
sha256=662c311e0d4a8fc71bae6cf4759308948e4681c2e23987583ff2121cb1f1aedf
base="$PWD/.build/session-library"
output="$PWD/.build/session-libs"
patch_file="$PWD/patches/libvncclient-virtual-session.patch"
command -v cmake >/dev/null || { echo 'Install build dependencies: brew install cmake openssl@4' >&2; exit 1; }
openssl_prefix="$(brew --prefix openssl@4)"
mkdir -p "$base" "$output"
staging="$(mktemp -d "$base/runtime.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
archive="$base/source.tar.gz"
if [[ ! -f "$archive" ]]; then
  curl --fail --location --silent --show-error "https://codeload.github.com/LibVNC/libvncserver/tar.gz/$revision" --output "$archive.download"
  mv "$archive.download" "$archive"
fi
echo "$sha256  $archive" | shasum -a 256 --check --status || { echo 'LibVNCClient source checksum failed' >&2; exit 1; }
patch_hash="$(shasum -a 256 "$patch_file" | cut -d ' ' -f 1)"
if [[ ! -f "$base/patch-hash" ]] || [[ "$(cat "$base/patch-hash")" != "$patch_hash" ]]; then
  rm -rf "$base/source" "$base/build"
  mkdir -p "$base/source"
  tar -xzf "$archive" -C "$base/source" --strip-components=1
  patch --directory "$base/source" -p1 < "$patch_file"
  echo "$patch_hash" > "$base/patch-hash"
fi
cmake -S "$base/source" -B "$base/build" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DOPENSSL_ROOT_DIR="$openssl_prefix" -DWITH_OPENSSL=ON -DWITH_GNUTLS=OFF -DWITH_GCRYPT=OFF \
  -DWITH_JPEG=OFF -DWITH_PNG=OFF -DWITH_LZO=OFF -DWITH_SASL=OFF \
  -DWITH_EXAMPLES=OFF -DWITH_TESTS=OFF -DWITH_SDL=OFF -DWITH_GTK=OFF -DWITH_QT=OFF \
  -DWITH_LIBSSHTUNNEL=OFF -DWITH_FFMPEG=OFF -DWITH_WEBSOCKETS=OFF -DWITH_XCB=OFF \
  -DWITH_TIGHTVNC_FILETRANSFER=OFF -DBUILD_SHARED_LIBS=ON
cmake --build "$base/build" --target vncclient --parallel 4
cp "$base/build/libvncclient.0.9.15.dylib" "$staging/libvncclient-session.dylib"
# Make the optional session library self-contained, including its crypto dependency.
python3 - "$staging" <<'PY'
import pathlib, subprocess, sys
out = pathlib.Path(sys.argv[1])
pending = [out / 'libvncclient-session.dylib']
seen = set()
while pending:
    lib = pending.pop()
    if lib.name in seen:
        continue
    seen.add(lib.name)
    listing = subprocess.check_output(['otool', '-L', str(lib)], text=True).splitlines()[2:]
    for row in listing:
        dependency = row.strip().split(' (', 1)[0]
        if not dependency.startswith(('/opt/homebrew/', '/usr/local/')):
            continue
        source = pathlib.Path(dependency)
        destination = out / source.name
        if not destination.exists():
            destination.write_bytes(source.read_bytes())
        subprocess.run(['install_name_tool', '-change', dependency, '@loader_path/' + source.name, str(lib)], check=True)
        pending.append(destination)
    subprocess.run(['install_name_tool', '-id', '@rpath/' + lib.name, str(lib)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(lib)], check=True)
PY
for library in "$staging"/*.dylib; do mv -f "$library" "$output/"; done
echo "Built session library: $output/libvncclient-session.dylib"
