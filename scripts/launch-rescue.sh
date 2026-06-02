#!/bin/zsh

set -u

readonly APP_DIR="${HOME}/Library/Application Support/SidecarRescue"
readonly LOG_FILE="${HOME}/Library/Logs/SidecarRescue.log"
readonly CONFIG_FILE="${APP_DIR}/config.plist"

TIMEOUT_SECONDS="$(/usr/bin/plutil -extract timeoutSeconds raw "${CONFIG_FILE}" 2>/dev/null || true)"
if [[ -z "${TIMEOUT_SECONDS}" ]]; then
  TIMEOUT_SECONDS=180
fi

exec "${APP_DIR}/bin/sidecar-rescue" rescue \
  --config "${CONFIG_FILE}" \
  --timeout "${TIMEOUT_SECONDS}" \
  --interval 1 >> "${LOG_FILE}" 2>&1
