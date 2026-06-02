#!/bin/zsh

set -eu

readonly ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly APP_DIR="${HOME}/Library/Application Support/SidecarRescue"
readonly BIN_DIR="${APP_DIR}/bin"
readonly SERVICE_SOURCE="${ROOT_DIR}/templates/Connect iPad Display.workflow"
readonly SERVICE_DIR="${HOME}/Library/Services/Connect iPad Display.workflow"
readonly CONFIG_FILE="${APP_DIR}/config.plist"

DEVICE_NAME="${1:-}"
TIMEOUT_SECONDS="${2:-}"

if [[ -z "${DEVICE_NAME}" ]]; then
  echo "Building SidecarRescue..."
  /usr/bin/swift build --package-path "${ROOT_DIR}" -c release
  BIN_PATH="$(/usr/bin/swift build --package-path "${ROOT_DIR}" -c release --show-bin-path)"
  echo
  echo "Reachable Sidecar devices:"
  "${BIN_PATH}/sidecar-rescue" list || true
  echo
  printf "Enter the exact iPad name: "
  read -r DEVICE_NAME
fi

if [[ -z "${DEVICE_NAME}" ]]; then
  echo "An iPad name is required." >&2
  exit 1
fi

if [[ -z "${TIMEOUT_SECONDS}" ]]; then
  printf "Retry timeout in seconds [180]: "
  read -r TIMEOUT_SECONDS
  TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-180}"
fi

if [[ ! "${TIMEOUT_SECONDS}" =~ '^[1-9][0-9]*$' ]]; then
  echo "Retry timeout must be a positive integer in seconds." >&2
  exit 1
fi

echo "Building SidecarRescue..."
/usr/bin/swift build --package-path "${ROOT_DIR}" -c release
BIN_PATH="$(/usr/bin/swift build --package-path "${ROOT_DIR}" -c release --show-bin-path)"

if [[ -e "${CONFIG_FILE}" || -e "${SERVICE_DIR}" ]]; then
  echo
  echo "Replacing the existing SidecarRescue configuration and Quick Action."
fi

/bin/mkdir -p "${BIN_DIR}" "${HOME}/Library/Services" "${HOME}/Library/Logs"
/usr/bin/install -m 755 "${BIN_PATH}/sidecar-rescue" "${BIN_DIR}/sidecar-rescue"
/usr/bin/install -m 755 "${ROOT_DIR}/scripts/launch-rescue.sh" "${APP_DIR}/launch-rescue.sh"

/usr/bin/plutil -create xml1 "${CONFIG_FILE}"
/usr/bin/plutil -insert deviceName -string "${DEVICE_NAME}" "${CONFIG_FILE}"
/usr/bin/plutil -insert timeoutSeconds -integer "${TIMEOUT_SECONDS}" "${CONFIG_FILE}"

/bin/rm -rf "${SERVICE_DIR}"
/bin/cp -R "${SERVICE_SOURCE}" "${SERVICE_DIR}"

echo
echo "Installed SidecarRescue for: ${DEVICE_NAME}"
echo "Retry timeout: ${TIMEOUT_SECONDS} seconds"
echo "Assign a shortcut in System Settings > Keyboard > Keyboard Shortcuts > Services > General."
echo "The service name is: Connect iPad Display"
