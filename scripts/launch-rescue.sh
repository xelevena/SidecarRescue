#!/bin/zsh

set -u

readonly APP_DIR="${HOME}/Library/Application Support/SidecarRescue"
readonly LOG_FILE="${HOME}/Library/Logs/SidecarRescue.log"
readonly CONFIG_FILE="${APP_DIR}/config.plist"

# Mark every shortcut press in the log up-front so it's easy to tell whether
# the Quick Action actually fired. If you press the shortcut and never see
# a new "shortcut fired" line, the workflow itself isn't reaching the script.
/bin/echo "----- shortcut fired at $(/bin/date '+%Y-%m-%d %H:%M:%S') -----" >> "${LOG_FILE}"

TIMEOUT_SECONDS="$(/usr/bin/plutil -extract timeoutSeconds raw "${CONFIG_FILE}" 2>/dev/null || true)"
if [[ -z "${TIMEOUT_SECONDS}" ]]; then
  TIMEOUT_SECONDS=180
fi

exec "${APP_DIR}/bin/sidecar-rescue" rescue \
  --config "${CONFIG_FILE}" \
  --timeout "${TIMEOUT_SECONDS}" \
  --interval 1 >> "${LOG_FILE}" 2>&1
