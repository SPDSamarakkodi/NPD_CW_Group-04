#!/usr/bin/env bash
#
# lib/integration.sh
# Purpose : Invokes Part B (netwatch.py) as a stage of Part A's run and
#           captures its exit code (INT-02). Both components share one
#           documented exit-code scheme (the EXIT_* constants in
#           netwatch.sh, mirrored in netwatch.py), so PY_EXIT_CODE can be
#           compared directly against Part A's own constants.
# Depends : lib/logging.sh (must be sourced first)
#
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "lib/integration.sh is a library and must be sourced, not executed." >&2
    exit 1
fi

# run_python_component INVENTORY_PATH TIMEOUT PYTHON_SCRIPT
#   Runs Part B's netwatch.py with the SAME inventory path and timeout
#   Part A itself used (INT-01: one source of truth), in concurrent mode.
#
#   Sets the global PY_EXIT_CODE for the caller to act on - following the
#   same pattern as probe_host's PROBE_STATUS/PROBE_RTT - and always
#   returns 0 itself. This is deliberate: Part B legitimately exiting 1,
#   2 or 3 is information for Part A to react to, not a failure of this
#   function, so a bare call here must never trip set -e.
run_python_component() {
    local inventory_path="$1"
    local timeout="$2"
    local python_script="$3"

    PY_EXIT_CODE="$EXIT_GENERAL_ERROR"

    local python_bin
    python_bin="$(command -v python3 || true)"
    if [[ -z "$python_bin" ]]; then
        log_error "python3 not found on PATH - cannot run the Python component"
        return 0
    fi

    if [[ ! -f "$python_script" ]]; then
        log_error "Python component not found: ${python_script}"
        return 0
    fi

    log_info "Invoking Part B: ${python_bin} ${python_script} -i ${inventory_path} -t ${timeout} -m concurrent"

    if "$python_bin" "$python_script" -i "$inventory_path" -t "$timeout" -m concurrent; then
        PY_EXIT_CODE=0
    else
        PY_EXIT_CODE=$?
    fi

    case "$PY_EXIT_CODE" in
        0) log_info "Part B completed: all services open." ;;
        1) log_error "Part B reported a general error (exit 1) - the consolidated report will fall back to Part A data only for the merge." ;;
        2) log_error "Part B reported a usage error (exit 2) - check the invocation arguments." ;;
        3) log_info "Part B completed: at least one service is not open (exit 3)." ;;
        *) log_error "Part B exited with an unexpected code: ${PY_EXIT_CODE}" ;;
    esac

    return 0
}
