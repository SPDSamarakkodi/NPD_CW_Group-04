#!/usr/bin/env bash
#
# lib/logging.sh
# Purpose : Shared logging helpers for NetWatch. Informational messages go
#           to standard output; error messages go to standard error. Both
#           are timestamped and also appended to the run's log file when
#           NETWATCH_LOG_FILE has been set by the caller.
# Used by : netwatch.sh and other lib/*.sh files (sourced, never executed
#           directly).
#
# Guard against being run directly instead of sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "lib/logging.sh is a library and must be sourced, not executed." >&2
    exit 1
fi

# log_timestamp
#   Prints the current time in a fixed, sortable format used throughout
#   NetWatch's logs, history and reports.
log_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# log_info MESSAGE
#   Writes an informational line to stdout and, if NETWATCH_LOG_FILE is set
#   and its directory exists, appends the same line to that log file.
log_info() {
    local message="$1"
    local line
    line="[$(log_timestamp)] [INFO] ${message}"
    printf '%s\n' "$line"
    if [[ -n "${NETWATCH_LOG_FILE:-}" ]]; then
        printf '%s\n' "$line" >> "$NETWATCH_LOG_FILE" 2>/dev/null || true
    fi
}

# log_error MESSAGE
#   Writes an error line to stderr and, if NETWATCH_LOG_FILE is set,
#   appends the same line to that log file.
log_error() {
    local message="$1"
    local line
    line="[$(log_timestamp)] [ERROR] ${message}"
    printf '%s\n' "$line" >&2
    if [[ -n "${NETWATCH_LOG_FILE:-}" ]]; then
        printf '%s\n' "$line" >> "$NETWATCH_LOG_FILE" 2>/dev/null || true
    fi
}
