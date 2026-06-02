#!/bin/zsh

set -eu

readonly ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

/usr/bin/swift build --package-path "${ROOT_DIR}" -c release
BIN_PATH="$(/usr/bin/swift build --package-path "${ROOT_DIR}" -c release --show-bin-path)"

echo
echo "Reachable Sidecar devices:"
"${BIN_PATH}/sidecar-rescue" list
