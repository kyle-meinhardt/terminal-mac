#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
name="${1:-agent}"
if [[ $# -gt 0 ]]; then shift; fi
if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$ ]]; then
  echo 'Invalid session name.' >&2; exit 1
fi
if [[ ! -x dist/terminal-mac ]]; then
  echo 'Build first: bash scripts/build.sh' >&2; exit 1
fi
if [[ ! -d /Applications/Ghostty.app ]]; then
  echo 'Install Ghostty: brew install --cask ghostty' >&2; exit 1
fi
open -na Ghostty.app --args --title="Agent Desktop — $name" -e "$PWD/dist/terminal-mac" session view "$name" "$@"
