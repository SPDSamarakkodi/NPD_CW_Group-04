#!/usr/bin/env bash
#
# lib/inventory.sh
# Purpose : Reads config/inventory.csv row by row, validates every field,
#           and builds a list of valid targets. Rejects malformed rows
#           individually (naming the line number and the field at fault)
#           without stopping the run. Implements FR-S01.
# Depends : lib/logging.sh, lib/validate.sh (must be sourced first)
#
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "lib/inventory.sh is a library and must be sourced, not executed." >&2
    exit 1
fi

# validate_inventory INVENTORY_PATH
#   Reads INVENTORY_PATH, skips the header row, validates every data row,
#   and populates three globals for the caller to use:
#     VALID_TARGETS  - array of "hostname|ip_address|service|port|critical"
#     VALID_COUNT    - number of rows accepted
#     REJECTED_COUNT - number of rows rejected (including blank lines)
#   Returns 1 if the file itself is missing, unreadable or empty.
#   Every individual bad row is reported via log_error/log_info and then
#   skipped with `continue` - it never stops the loop or the script.
validate_inventory() {
    local inventory_path="$1"
    local line_number=0
    local line
    local trimmed_line
    local field_count
    local hostname ip_address service port critical
    local -a fields

    VALID_TARGETS=()
    VALID_COUNT=0
    REJECTED_COUNT=0

    if [[ ! -f "$inventory_path" ]]; then
        log_error "Inventory file not found: ${inventory_path}"
        return 1
    fi

    if [[ ! -r "$inventory_path" ]]; then
        log_error "Inventory file not readable (permission denied): ${inventory_path}"
        return 1
    fi

    if [[ ! -s "$inventory_path" ]]; then
        log_error "Inventory file is empty: ${inventory_path}"
        return 1
    fi

    # `|| [[ -n "$line" ]]` catches a final line with no trailing newline.
    # Reading from a redirected file (not a pipe) so this loop can safely
    # set globals the caller reads afterwards.
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))

        if [[ "$line_number" -eq 1 ]]; then
            continue   # header row
        fi

        trimmed_line="$(trim "$line")"

        if [[ -z "$trimmed_line" ]]; then
            log_info "Line ${line_number}: skipped (blank line)"
            REJECTED_COUNT=$((REJECTED_COUNT + 1))
            continue
        fi

        IFS=',' read -r -a fields <<< "$trimmed_line"

        # bash's `read -a` silently drops a trailing empty field (e.g. a
        # line ending in a stray comma), so array length alone would miss
        # that case. Count delimiters instead, via parameter expansion
        # (no external tr/awk): comma_count + 1 is the true field count.
        local stripped_of_commas comma_count
        stripped_of_commas="${trimmed_line//,/}"
        comma_count=$(( ${#trimmed_line} - ${#stripped_of_commas} ))
        field_count=$(( comma_count + 1 ))

        if [[ "$field_count" -ne 5 ]]; then
            log_error "Line ${line_number}: rejected - expected 5 fields (hostname,ip_address,service,port,critical), found ${field_count}"
            REJECTED_COUNT=$((REJECTED_COUNT + 1))
            continue
        fi

        hostname="$(trim "${fields[0]}")"
        ip_address="$(trim "${fields[1]}")"
        service="$(trim "${fields[2]}")"
        port="$(trim "${fields[3]}")"
        critical="$(trim "${fields[4]}")"

        if ! is_valid_hostname "$hostname"; then
            log_error "Line ${line_number}: rejected - field 'hostname' is empty or contains invalid characters"
            REJECTED_COUNT=$((REJECTED_COUNT + 1))
            continue
        fi

        if ! is_valid_ipv4 "$ip_address"; then
            log_error "Line ${line_number}: rejected - field 'ip_address' ('${ip_address}') is not a valid IPv4 address"
            REJECTED_COUNT=$((REJECTED_COUNT + 1))
            continue
        fi

        if ! is_valid_port "$port"; then
            log_error "Line ${line_number}: rejected - field 'port' ('${port}') is not an integer in 1-65535"
            REJECTED_COUNT=$((REJECTED_COUNT + 1))
            continue
        fi

        if [[ -z "$service" ]]; then
            log_error "Line ${line_number}: rejected - field 'service' is empty"
            REJECTED_COUNT=$((REJECTED_COUNT + 1))
            continue
        fi

        case "${critical,,}" in
            yes|no) : ;;
            *)
                log_info "Line ${line_number}: field 'critical' ('${critical}') is not yes/no - defaulting to 'no'"
                critical="no"
                ;;
        esac

        VALID_TARGETS+=("${hostname}|${ip_address}|${service}|${port}|${critical}")
        VALID_COUNT=$((VALID_COUNT + 1))
    done < "$inventory_path"

    log_info "Inventory validation complete: ${VALID_COUNT} valid row(s), ${REJECTED_COUNT} rejected row(s)"
    return 0
}
