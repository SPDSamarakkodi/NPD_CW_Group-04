#!/usr/bin/env bash
#
# lib/probe.sh
# Purpose : Sends a single bounded-wait reachability probe (ICMP ping) to
#           one host and reports UP/DOWN plus round-trip time. Implements
#           FR-S03. Deliberately never returns non-zero for a DOWN host -
#           that is a valid finding, not a script error (see comments).
# Depends : lib/logging.sh (must be sourced first)
#
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "lib/probe.sh is a library and must be sourced, not executed." >&2
    exit 1
fi

# probe_host HOSTNAME IP_ADDRESS TIMEOUT
#   Sends exactly one ICMP echo request to IP_ADDRESS, bounded by TIMEOUT
#   seconds. Sets two globals for the caller:
#     PROBE_STATUS - "UP" or "DOWN"
#     PROBE_RTT    - round-trip time in ms as text, or "" if not available
#
#   Design note (the set -e / "keep going on a down host" conflict):
#   `ping` exits non-zero when a host does not respond. We capture that
#   inside an `if var=$(cmd); then ... else ... fi` construct, which is a
#   conditional context - set -e explicitly does not abort the script for
#   a command whose exit status is being tested this way. On top of that,
#   this function always finishes with an explicit `return 0`, even when
#   the host is DOWN, because a DOWN result is exactly what a monitoring
#   tool is supposed to be able to report, not a failure of the function
#   itself. Bare (untested) calls to probe_host are therefore safe under
#   set -euo pipefail.
probe_host() {
    local hostname="$1"
    local ip_address="$2"
    local timeout="$3"
    local ping_output
    local ping_exit_status

    PROBE_STATUS="DOWN"
    PROBE_RTT=""

    if ping_output=$(ping -c 1 -W "$timeout" -- "$ip_address" 2>&1); then
        ping_exit_status=0
    else
        ping_exit_status=$?
    fi

    if [[ "$ping_exit_status" -eq 0 ]]; then
        PROBE_STATUS="UP"
        local rtt_pattern='time=([0-9]+(\.[0-9]+)?)[[:space:]]*ms'
        if [[ "$ping_output" =~ $rtt_pattern ]]; then
            PROBE_RTT="${BASH_REMATCH[1]}"
        fi
    else
        PROBE_STATUS="DOWN"
        PROBE_RTT=""
        if [[ "$ping_output" == *"Name or service not known"* \
           || "$ping_output" == *"Temporary failure in name resolution"* \
           || "$ping_output" == *"unknown host"* ]]; then
            log_error "Probe: ${hostname} (${ip_address}) - name not resolvable"
        elif [[ "$ping_output" == *"Operation not permitted"* \
             || "$ping_output" == *"Permission denied"* ]]; then
            log_error "Probe: ${hostname} (${ip_address}) - blocked by local policy"
        else
            log_error "Probe: ${hostname} (${ip_address}) - unreachable / no reply within ${timeout}s"
        fi
    fi

    return 0
}
