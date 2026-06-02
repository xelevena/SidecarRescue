#!/bin/zsh

set -u

readonly APP_DIR="${HOME}/Library/Application Support/SidecarRescue"
readonly LOG_FILE="${HOME}/Library/Logs/SidecarRescue.log"
readonly CONFIG_FILE="${APP_DIR}/config.plist"

# Cap log growth at ~1MB. Each press writes well under a kilobyte normally
# and a worst-case failing rescue around 20KB, so this is plenty of history.
# When the log exceeds the cap, keep the most recent 5000 lines via an atomic
# rename so a crash mid-rotate can't truncate the live log.
readonly LOG_MAX_BYTES=1048576
readonly LOG_KEEP_LINES=5000
if [[ -f "${LOG_FILE}" ]]; then
  log_size=$(/usr/bin/stat -f '%z' "${LOG_FILE}" 2>/dev/null || echo 0)
  if (( log_size > LOG_MAX_BYTES )); then
    tmp_log="${LOG_FILE}.rotate.$$"
    if /usr/bin/tail -n "${LOG_KEEP_LINES}" "${LOG_FILE}" > "${tmp_log}" 2>/dev/null; then
      /bin/mv "${tmp_log}" "${LOG_FILE}"
    else
      /bin/rm -f "${tmp_log}"
    fi
  fi
fi

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
