#!/usr/bin/env bash
#
# netwatch.sh
#
# Script   : netwatch.sh
# Purpose  : NetWatch - a small network monitoring toolkit for Serendib
#            Logistics (Pvt) Ltd. Reads a device inventory, checks whether
#            each host is reachable, records every check to a history
#            file, and turns that history into a readable report.
# Authors  : <YOUR NAMES HERE>
# Date     : September 2026
# Usage    : ./netwatch.sh [-i inventory_path] [-o output_dir] [-t timeout]
#                           [-r] [-h]
#            Run with no arguments to use sensible defaults (see usage()
#            below). Exit codes are documented in the constants below and
#            shared with Python's netwatch.py for INT-02.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Documented exit-code scheme (shared with Python's netwatch.py, see INT-02)
# ---------------------------------------------------------------------------
readonly EXIT_SUCCESS=0          # completed, nothing wrong found
readonly EXIT_GENERAL_ERROR=1    # could not run at all (missing/unreadable file, etc.)
readonly EXIT_USAGE_ERROR=2      # bad command-line invocation
readonly EXIT_ISSUES_DETECTED=3  # completed, but at least one target is down/closed

# ---------------------------------------------------------------------------
# Path resolution: always locate lib/ and config/ relative to this script's
# own location, never relative to the caller's current working directory.
# This is what makes it safe to run from cron or from any directory.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
readonly SCRIPT_DIR
LIB_DIR="${SCRIPT_DIR}/lib"
PYTHON_DIR="${SCRIPT_DIR}/../Python"
PYTHON_SCRIPT="${PYTHON_DIR}/netwatch.py"
PY_REPORTS_DIR="${PYTHON_DIR}/reports"

# ---------------------------------------------------------------------------
# Defaults - each overridable by a command-line option (FR-S02)
# ---------------------------------------------------------------------------
INVENTORY_FILE="${SCRIPT_DIR}/config/inventory.csv"
OUTPUT_DIR="${SCRIPT_DIR}"
PROBE_TIMEOUT=2
REPORT_ONLY=false

# ---------------------------------------------------------------------------
# Source the shared function library. Each lib file guards against being
# executed directly, so sourcing is the only valid way to bring them in.
# ---------------------------------------------------------------------------
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/validate.sh"
source "${LIB_DIR}/inventory.sh"
source "${LIB_DIR}/probe.sh"
source "${LIB_DIR}/history.sh"
source "${LIB_DIR}/report.sh"
source "${LIB_DIR}/integration.sh"

# ---------------------------------------------------------------------------
# Trap-based cleanup. TMP_FILES will be populated once probing (FR-S03)
# needs scratch files. Declared now so the trap is live from the very start
# of execution, on normal exit, interruption (Ctrl+C) and termination.
# ---------------------------------------------------------------------------
declare -a TMP_FILES=()

cleanup() {
    local exit_status=$?
    local file
    for file in "${TMP_FILES[@]:-}"; do
        [[ -n "$file" && -f "$file" ]] && rm -f -- "$file"
    done
    return "$exit_status"
}
trap cleanup EXIT INT TERM

# usage
#   Prints the usage message. Called on -h (exits 0) and on any argument
#   error (sent to stderr, exits with EXIT_USAGE_ERROR).
usage() {
    cat <<EOF
NetWatch - network monitoring toolkit for Serendib Logistics

Usage: $(basename "${BASH_SOURCE[0]}") [OPTIONS]

Options:
  -i PATH   Path to the inventory CSV file
            (default: ${SCRIPT_DIR}/config/inventory.csv)
  -o DIR    Base output directory; data/, logs/ and reports/ subfolders
            are created under it (default: ${SCRIPT_DIR})
  -t SEC    Probe timeout in whole seconds, minimum 1 (default: 2)
  -r        Report-only mode: skip probing, regenerate the report from
            the existing history file
  -h        Show this help message and exit

Exit codes:
  0  success
  1  general error (could not run - missing/unreadable file, etc.)
  2  usage error (bad command-line arguments)
  3  completed, but at least one monitored target is down or closed
EOF
}

# parse_arguments "$@"
#   Parses command-line options with bash's getopts builtin (native, no
#   external getopt call). Leading ':' in the optstring puts getopts into
#   silent-error mode so we can produce our own consistent messages for
#   both an unknown option (?) and a missing option-argument (:).
parse_arguments() {
    local opt
    while getopts ":i:o:t:rh" opt; do
        case "$opt" in
            i) INVENTORY_FILE="$OPTARG" ;;
            o) OUTPUT_DIR="$OPTARG" ;;
            t) PROBE_TIMEOUT="$OPTARG" ;;
            r) REPORT_ONLY=true ;;
            h) usage; exit "$EXIT_SUCCESS" ;;
            \?)
                log_error "Unknown option: -${OPTARG}"
                usage >&2
                exit "$EXIT_USAGE_ERROR"
                ;;
            :)
                log_error "Option -${OPTARG} requires an argument"
                usage >&2
                exit "$EXIT_USAGE_ERROR"
                ;;
        esac
    done
    shift $((OPTIND - 1))

    if [[ $# -gt 0 ]]; then
        log_error "Unexpected argument(s): $*"
        usage >&2
        exit "$EXIT_USAGE_ERROR"
    fi

    if ! [[ "$PROBE_TIMEOUT" =~ ^[0-9]+$ ]] || (( PROBE_TIMEOUT < 1 )); then
        log_error "Invalid -t timeout value: '${PROBE_TIMEOUT}' (must be a positive whole number of seconds)"
        usage >&2
        exit "$EXIT_USAGE_ERROR"
    fi
}

# prepare_output_dirs
#   Creates data/, logs/ and reports/ under OUTPUT_DIR if they do not
#   already exist, and confirms each is writable. Sets DATA_DIR, LOG_DIR,
#   REPORT_DIR and NETWATCH_LOG_FILE for the rest of the script/library
#   to use.
prepare_output_dirs() {
    DATA_DIR="${OUTPUT_DIR}/data"
    LOG_DIR="${OUTPUT_DIR}/logs"
    REPORT_DIR="${OUTPUT_DIR}/reports"

    local dir
    for dir in "$DATA_DIR" "$LOG_DIR" "$REPORT_DIR"; do
        if ! mkdir -p -- "$dir" 2>/dev/null; then
            log_error "Cannot create output directory: ${dir}"
            exit "$EXIT_USAGE_ERROR"
        fi
        if [[ ! -w "$dir" ]]; then
            log_error "Output directory not writable: ${dir}"
            exit "$EXIT_USAGE_ERROR"
        fi
    done

    NETWATCH_LOG_FILE="${LOG_DIR}/netwatch.log"
    HISTORY_FILE="${DATA_DIR}/history.csv"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_arguments "$@"
    prepare_output_dirs

    log_info "NetWatch starting - inventory: ${INVENTORY_FILE}"
    log_info "Output directory: ${OUTPUT_DIR}  (timeout=${PROBE_TIMEOUT}s, report_only=${REPORT_ONLY})"

    if [[ "$REPORT_ONLY" == true ]]; then
        log_info "Report-only mode: skipping probing, generating report from existing history."
        generate_report "$HISTORY_FILE" "$REPORT_DIR" "$PY_REPORTS_DIR"
        exit "$EXIT_SUCCESS"
    fi

    if ! validate_inventory "$INVENTORY_FILE"; then
        log_error "Could not proceed: inventory could not be read."
        exit "$EXIT_GENERAL_ERROR"
    fi

    log_info "Valid targets loaded: ${VALID_COUNT}"
    log_info "Rejected rows: ${REJECTED_COUNT}"

    if ! init_history_file "$HISTORY_FILE"; then
        log_error "Could not proceed: history file could not be initialised."
        exit "$EXIT_GENERAL_ERROR"
    fi

    local target
    local t_host t_ip t_service t_port t_critical
    local any_down=false

    for target in "${VALID_TARGETS[@]}"; do
        IFS='|' read -r t_host t_ip t_service t_port t_critical <<< "$target"

        # Bare call, no `if` needed: probe_host always returns 0 (see
        # lib/probe.sh) - a DOWN host is a finding, not a script error.
        probe_host "$t_host" "$t_ip" "$PROBE_TIMEOUT"

        if [[ "$PROBE_STATUS" == "UP" ]]; then
            log_info "  -> ${t_host} (${t_ip}) reachability=UP rtt=${PROBE_RTT:-n/a}ms service=${t_service}:${t_port} critical=${t_critical}"
        else
            any_down=true
            log_info "  -> ${t_host} (${t_ip}) reachability=DOWN service=${t_service}:${t_port} critical=${t_critical}"
        fi

        # `|| true`: a single failed history write is logged (inside
        # write_history_record) but must not abort the whole run - the
        # same fail-fast-vs-keep-going resolution as probing.
        write_history_record "$HISTORY_FILE" "$t_host" "$t_ip" "$t_service" "$t_port" "$PROBE_STATUS" "${PROBE_RTT:-}" || true
    done

    # INT-02: invoke Part B as a stage of this run, using the SAME
    # inventory and timeout Part A itself used (INT-01), and fold its
    # outcome into this run's own overall exit-code decision - a service
    # Part B found closed is exactly as much "an issue detected" as a
    # host Part A found unreachable.
    run_python_component "$INVENTORY_FILE" "$PROBE_TIMEOUT" "$PYTHON_SCRIPT"
    if [[ "$PY_EXIT_CODE" -eq "$EXIT_ISSUES_DETECTED" ]]; then
        any_down=true
    fi

    generate_report "$HISTORY_FILE" "$REPORT_DIR" "$PY_REPORTS_DIR"

    if [[ "$any_down" == true ]]; then
        exit "$EXIT_ISSUES_DETECTED"
    fi
}

main "$@"
