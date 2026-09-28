#!/usr/bin/env bash
#
# lib/history.sh
# Purpose : Writes timestamped, delimited check records to data/history.csv,
#           always appending (never overwriting), and recreating the header
#           if the file is missing or empty. Implements FR-S04's history
#           side (the log-narrative side is already handled by
#           lib/logging.sh, sourced separately).
# Depends : lib/logging.sh (must be sourced first)
#
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "lib/history.sh is a library and must be sourced, not executed." >&2
    exit 1
fi

readonly HISTORY_HEADER="timestamp,hostname,ip_address,service,port,status,rtt_ms"

# init_history_file HISTORY_PATH
#   Ensures HISTORY_PATH's directory exists and the file has a header row.
#   Safe to call every run: if the file already has content (a previous
#   run's records), the header is NOT rewritten - this is what makes
#   "append rather than overwrite" hold across multiple runs. If the file
#   was deleted since the last run, this recreates it with a fresh header,
#   handling that error condition without the run failing.
#   Returns 1 (with a logged error) if the directory cannot be created or
#   the header cannot be written - e.g. no write permission.
init_history_file() {
    local history_path="$1"
    local history_dir
    history_dir="$(dirname -- "$history_path")"

    if [[ ! -d "$history_dir" ]]; then
        if ! mkdir -p -- "$history_dir" 2>/dev/null; then
            log_error "History directory missing and could not be created: ${history_dir}"
            return 1
        fi
    fi

    if [[ ! -s "$history_path" ]]; then
        if ! printf '%s\n' "$HISTORY_HEADER" >> "$history_path" 2>/dev/null; then
            log_error "Cannot write history header (check permissions): ${history_path}"
            return 1
        fi
    fi

    return 0
}

# write_history_record HISTORY_PATH HOSTNAME IP SERVICE PORT STATUS RTT
#   Appends one timestamped record to HISTORY_PATH. Never overwrites -
#   always uses >>. On failure (e.g. the file was removed and its
#   directory is now unwritable), logs the error via the library and
#   returns 1 rather than raising an unhandled failure, so a single bad
#   write does not need to stop the whole run.
write_history_record() {
    local history_path="$1"
    local hostname="$2"
    local ip_address="$3"
    local service="$4"
    local port="$5"
    local status="$6"
    local rtt="$7"
    local record
    record="$(log_timestamp),${hostname},${ip_address},${service},${port},${status},${rtt}"

    if ! printf '%s\n' "$record" >> "$history_path" 2>/dev/null; then
        log_error "Failed to append history record for ${hostname} (history file missing or unwritable: ${history_path})"
        return 1
    fi

    return 0
}
