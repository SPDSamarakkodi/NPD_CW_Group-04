#!/usr/bin/env bash
#
# lib/report.sh
# Purpose : Analyses the accumulated check history (data/history.csv) and
#           produces both a formatted on-screen report and a timestamped
#           CSV report file, computed in a single pass over the same
#           data (FR-S05). The Part B merge (INT-03) is added in the
#           integration step alongside this file.
# Depends : lib/logging.sh (must be sourced first)
#
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "lib/report.sh is a library and must be sourced, not executed." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# INT-03 data contract with Part B (netwatch.py's write_csv_report()):
#   File        : PY_REPORTS_DIR/py_results_<YYYYmmdd_HHMMSS>.csv
#                 (most recent by filename = most recent by content, since
#                 the timestamp is zero-padded and sorts lexicographically
#                 in chronological order)
#   Delimiter   : comma
#   Quoting     : Python's csv.writer default (QUOTE_MINIMAL) - a field is
#                 only quoted if it contains a comma, quote or newline.
#                 ASSUMPTION: none of Part B's current fields (hostname,
#                 ip_address, service, state, error_detail) ever contain a
#                 comma, so this simple parser below splits on comma
#                 directly without unescaping quotes. If that assumption
#                 ever changed (e.g. a service name containing a comma),
#                 this parser would misread that one field - noted here
#                 and in the report's assumptions section.
#   Timestamp   : "%Y-%m-%d %H:%M:%S" (identical format to Part A's own
#                 log_timestamp(), so timestamps from both components are
#                 directly comparable without reformatting)
#   Field order : timestamp,hostname,ip_address,service,port,state,
#                 response_time_ms,error_detail
# ---------------------------------------------------------------------------

# find_latest_py_results PY_REPORTS_DIR
#   Prints the path of the most recent py_results_*.csv in PY_REPORTS_DIR,
#   or nothing (with a non-zero return) if the directory or any matching
#   file does not exist - handling FR-S05's "Part B's results file
#   absent" condition without raising.
find_latest_py_results() {
    local py_reports_dir="$1"
    local latest

    if [[ ! -d "$py_reports_dir" ]]; then
        return 1
    fi

    latest="$(find "$py_reports_dir" -maxdepth 1 -type f -name 'py_results_*.csv' 2>/dev/null | sort | tail -n 1)"
    if [[ -z "$latest" ]]; then
        return 1
    fi

    printf '%s' "$latest"
    return 0
}

# generate_report HISTORY_PATH REPORT_DIR PY_REPORTS_DIR
#   Reads HISTORY_PATH (Part A's full check history, every run to date),
#   computes total checks, counts by status, availability % per host,
#   and the three most frequently failing hosts; locates Part B's most
#   recent results (PY_REPORTS_DIR) and merges its per-host service state
#   into the same rows (INT-03); then prints an aligned on-screen table
#   and writes the same consolidated figures as a timestamped CSV under
#   REPORT_DIR - all from one computed dataset (FR-S05: "written together
#   in a single pass").
#
#   An empty or missing history file is reported clearly as "nothing to
#   report yet" and returns 0 - a normal condition, not an error. A
#   missing Part B results file is likewise not fatal: the report is
#   still produced using Part A's reachability data alone, with an
#   explicit note that the Part B columns are unavailable.
generate_report() {
    local history_path="$1"
    local report_dir="$2"
    local py_reports_dir="$3"

    if [[ ! -f "$history_path" || ! -s "$history_path" ]]; then
        log_info "No history to report on yet (history file missing or empty): ${history_path}"
        return 0
    fi

    local report_filename_stamp
    report_filename_stamp="$(date '+%Y%m%d_%H%M%S')"
    local report_path="${report_dir}/netwatch_${report_filename_stamp}.csv"
    local report_timestamp
    report_timestamp="$(log_timestamp)"

    # --- Single pass over history.csv with awk: tallies total checks,
    # counts per status, and per-host totals/up/down. NF < 6 defensively
    # skips any short/corrupt line rather than letting awk error out on
    # it, mirroring the "reject the bad row, keep going" principle used
    # throughout Part A. Division by zero is guarded explicitly (a host
    # could in principle appear with host_total 0 only if this loop logic
    # changes later, so the guard is kept even though it cannot currently
    # trigger from real data). ---------------------------------------
    local stats_tmp
    stats_tmp="$(mktemp)"
    TMP_FILES+=("$stats_tmp")

    awk -F',' '
        NR == 1 { next }
        NF < 6  { next }
        {
            total++
            status_count[$6]++
            host_total[$2]++
            host_ip[$2] = $3
            if ($6 == "UP") host_up[$2]++
            else host_down[$2]++
        }
        END {
            print "TOTAL " total
            for (s in status_count) print "STATUS " s " " status_count[s]
            for (h in host_total) {
                up = (h in host_up) ? host_up[h] : 0
                down = (h in host_down) ? host_down[h] : 0
                pct = (host_total[h] > 0) ? (up / host_total[h] * 100) : 0
                printf "HOST %s %s %d %d %d %.1f\n", h, host_ip[h], host_total[h], up, down, pct
            }
        }
    ' "$history_path" > "$stats_tmp"

    local total_checks=0
    local up_count=0
    local down_count=0
    local -a host_lines=()
    local kind a b c d e f

    while read -r kind a b c d e f; do
        case "$kind" in
            TOTAL)  total_checks="$a" ;;
            STATUS) [[ "$a" == "UP" ]] && up_count="$b"; [[ "$a" == "DOWN" ]] && down_count="$b" ;;
            HOST)   host_lines+=("${a}|${b}|${c}|${d}|${e}|${f}") ;;
        esac
    done < "$stats_tmp"

    # --- Rank hosts by DOWN count (descending), tie-broken alphabetically
    # by hostname for a deterministic order regardless of awk's
    # unordered array iteration - via sort, not by relying on any
    # incidental ordering. -------------------------------------------
    local failing_tmp
    failing_tmp="$(mktemp)"
    TMP_FILES+=("$failing_tmp")

    local entry host ip total up down pct
    for entry in "${host_lines[@]}"; do
        IFS='|' read -r host ip total up down pct <<< "$entry"
        printf '%d|%s|%s|%d|%d|%d|%.1f\n' "$down" "$host" "$ip" "$total" "$up" "$down" "$pct" >> "$failing_tmp"
    done

    local -a top_failing=()
    while IFS='|' read -r _ host ip total up down pct; do
        top_failing+=("${host}|${ip}|${total}|${up}|${down}|${pct}")
    done < <(sort -t'|' -k1,1nr -k2,2 "$failing_tmp" | head -3)

    # --- INT-03: locate and merge Part B's most recent per-host service
    # results. A missing file is not fatal - py_state/py_rtt simply stay
    # empty, and every lookup below falls back to "n/a" via the ${...:-}
    # pattern, so the report still generates using Part A data alone. ---
    local -A py_state=()
    local -A py_rtt=()
    local py_results_file=""

    if py_results_file="$(find_latest_py_results "$py_reports_dir")"; then
        log_info "Merging Part B results from: ${py_results_file}"
        local py_is_header=true
        local py_ts py_host py_ip py_svc py_port py_state_val py_rtt_val py_err
        while IFS=',' read -r py_ts py_host py_ip py_svc py_port py_state_val py_rtt_val py_err; do
            if [[ "$py_is_header" == true ]]; then
                py_is_header=false
                continue
            fi
            [[ -z "$py_host" ]] && continue
            py_state["$py_host"]="$py_state_val"
            py_rtt["$py_host"]="$py_rtt_val"
        done < "$py_results_file"
    else
        log_info "Part B's results file not found - consolidated report will show Part A reachability data only."
    fi

    # --- Emit the on-screen table and the CSV report from the SAME
    # host_lines + py_state/py_rtt data, in one loop (FR-S05: "written
    # together in a single pass"). -----------------------------------
    local svc_state svc_rtt
    {
        echo "timestamp,hostname,ip_address,total_checks,up_count,down_count,availability_pct,service_state,service_rtt_ms"
        for entry in "${host_lines[@]}"; do
            IFS='|' read -r host ip total up down pct <<< "$entry"
            svc_state="${py_state[$host]:-n/a}"
            svc_rtt="${py_rtt[$host]:-n/a}"
            echo "${report_timestamp},${host},${ip},${total},${up},${down},${pct},${svc_state},${svc_rtt}"
        done
    } > "$report_path"

    printf '\n%s\n' "NetWatch Consolidated Availability Report"
    printf '%s\n' "============================================================"
    printf '%-16s %-10d\n' "Total checks:" "$total_checks"
    printf '%-16s %-10d\n' "  UP:" "$up_count"
    printf '%-16s %-10d\n' "  DOWN:" "$down_count"
    printf '\n'
    printf '%-16s %-15s %-7s %-5s %-6s %-9s %-9s %-8s\n' \
        "Host" "Address" "Total" "Up" "Down" "Avail %" "Svc" "Svc RTT"
    printf '%s\n' "------------------------------------------------------------------------"
    for entry in "${host_lines[@]}"; do
        IFS='|' read -r host ip total up down pct <<< "$entry"
        svc_state="${py_state[$host]:-n/a}"
        svc_rtt="${py_rtt[$host]:-n/a}"
        printf '%-16s %-15s %-7s %-5s %-6s %-9s %-9s %-8s\n' \
            "$host" "$ip" "$total" "$up" "$down" "${pct}%" "$svc_state" "$svc_rtt"
    done
    printf '\n%s\n' "Top failing hosts (most DOWN checks):"
    if [[ "${#top_failing[@]}" -eq 0 ]]; then
        printf '  (none - every host has 0 DOWN checks)\n'
    else
        for entry in "${top_failing[@]}"; do
            IFS='|' read -r host ip total up down pct <<< "$entry"
            printf '  %-16s %d DOWN check(s) out of %d\n' "$host" "$down" "$total"
        done
    fi
    printf '============================================================\n'
    log_info "Report written: ${report_path}"

    return 0
}
