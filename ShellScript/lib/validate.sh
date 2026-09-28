#!/usr/bin/env bash
#
# lib/validate.sh
# Purpose : Field-level validation helpers for NetWatch. These implement
#           the same rules Part B (Python) applies to the inventory, so
#           both components accept or reject the same row (INT-01).
# Used by : lib/inventory.sh
#
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "lib/validate.sh is a library and must be sourced, not executed." >&2
    exit 1
fi

# trim STRING
#   Strips leading and trailing whitespace using pure parameter expansion
#   (no external sed/awk call). Prints the trimmed string.
trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

# is_valid_ipv4 ADDRESS
#   Returns 0 if ADDRESS is a syntactically and numerically valid IPv4
#   dotted-quad address (each octet 0-255, exactly four octets).
#   Returns 1 otherwise. Uses bash's native =~ regex operator first to
#   reject anything with the wrong shape, then arithmetic comparisons to
#   catch out-of-range octets like 192.168.1.256.
is_valid_ipv4() {
    local address="$1"
    local ipv4_pattern='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
    local octet

    if [[ ! "$address" =~ $ipv4_pattern ]]; then
        return 1
    fi

    local IFS='.'
    local -a octets=($address)
    unset IFS

    if [[ "${#octets[@]}" -ne 4 ]]; then
        return 1
    fi

    for octet in "${octets[@]}"; do
        # Reject leading zeros like "01" as a defensive extra, except "0" itself
        if [[ "$octet" =~ ^0[0-9]+$ ]]; then
            return 1
        fi
        if (( octet < 0 || octet > 255 )); then
            return 1
        fi
    done

    return 0
}

# is_valid_port PORT
#   Returns 0 if PORT is a whole number in the range 1-65535.
#   Returns 1 for anything non-numeric (e.g. "8O80" with a letter O) or
#   out of range (e.g. 99999 or 0).
is_valid_port() {
    local port="$1"
    local port_pattern='^[0-9]+$'

    if [[ ! "$port" =~ $port_pattern ]]; then
        return 1
    fi

    if (( port < 1 || port > 65535 )); then
        return 1
    fi

    return 0
}

# is_valid_hostname NAME
#   Minimal sanity check: not empty after trimming, and contains no
#   whitespace or comma (which would indicate a parsing problem upstream).
is_valid_hostname() {
    local name="$1"
    if [[ -z "$name" ]]; then
        return 1
    fi
    if [[ "$name" =~ [[:space:],] ]]; then
        return 1
    fi
    return 0
}
