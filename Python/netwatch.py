#!/usr/bin/env python3
"""
netwatch.py

Script  : netwatch.py
Purpose : NetWatch (Python component) for Serendib Logistics. Checks
          whether services are actually answering on their ports using
          sockets, runs those checks concurrently, works out what has
          changed since the last run, and persists results for
          status_server.py to publish.
Authors : <YOUR NAMES HERE>
Date    : September 2026
Usage   : python3 netwatch.py [-m sequential|concurrent|both]
                               [-i inventory_path] [-t timeout] [-h]
          Run with no arguments to use sensible defaults.
"""

import sys
import re
import socket
import time
import threading
import errno
import json
import csv
from collections import Counter
from datetime import datetime
from pathlib import Path
from dataclasses import dataclass, asdict

# ---------------------------------------------------------------------------
# Documented exit-code scheme - identical to Bash's netwatch.sh (INT-02)
# ---------------------------------------------------------------------------
EXIT_SUCCESS = 0          # completed, nothing wrong found
EXIT_GENERAL_ERROR = 1    # could not run at all (missing/unreadable file, etc.)
EXIT_USAGE_ERROR = 2      # bad command-line invocation
EXIT_ISSUES_DETECTED = 3  # completed, but at least one service is closed/unreachable

# ---------------------------------------------------------------------------
# Defaults. The inventory default assumes the standard submission layout
# (Python/ and ShellScript/ as sibling folders) so the SAME physical
# config/inventory.csv is read by both components without duplication.
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_INVENTORY_PATH = (SCRIPT_DIR / ".." / "ShellScript" / "config" / "inventory.csv").resolve()
DEFAULT_TIMEOUT = 2
VALID_MODES = ("sequential", "concurrent", "both")

DATA_DIR = SCRIPT_DIR / "data"
REPORTS_DIR = SCRIPT_DIR / "reports"
RESULTS_JSON_PATH = DATA_DIR / "results.json"

IPV4_PATTERN = re.compile(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$")
PORT_PATTERN = re.compile(r"^\d+$")
HOSTNAME_INVALID_PATTERN = re.compile(r"[\s,]")


@dataclass
class Target:
    """One validated inventory row. Fields are accessed by name (hostname,
    ip_address, ...), never by position, per the technical requirements."""
    hostname: str
    ip_address: str
    service: str
    port: int
    critical: bool


@dataclass
class CheckResult:
    """Result of one socket check. Fields accessed by name throughout, per
    the technical requirements. `state` is one of:
      "open"    - connected successfully
      "closed"  - connection actively refused (a valid finding, not a failure)
      "timeout" - no response within the configured timeout
      "error"   - anything else (e.g. address could not be resolved)
    """
    hostname: str
    ip_address: str
    service: str
    port: int
    state: str
    response_time_ms: float
    timestamp: str
    error_detail: str = ""


def usage_text():
    return f"""NetWatch (Python) - service availability checker for Serendib Logistics

Usage: python3 netwatch.py [OPTIONS]

Options:
  -m, --mode {{sequential|concurrent|both}}  Which scan(s) to run (default: both)
  -i, --inventory PATH                      Inventory CSV path
                                             (default: {DEFAULT_INVENTORY_PATH})
  -t, --timeout SEC                         Socket timeout in whole seconds,
                                             minimum 1 (default: {DEFAULT_TIMEOUT})
  -h, --help                                Show this help message and exit

Exit codes:
  0  success
  1  general error (could not run - missing/unreadable file, etc.)
  2  usage error (bad command-line arguments)
  3  completed, but at least one service is closed/unreachable
"""


def parse_arguments(argv):
    """
    Parses argv (normally sys.argv[1:]) into a configuration dict.

    Deliberately reads the argument list directly (no argparse) so that
    numeric conversion is explicit and each failure mode is under our own
    control, per FR-P01. This is a pure function - it never calls
    sys.exit() or prints - which is what keeps netwatch.py safely
    importable without side effects (also FR-P01).

    Returns (config, error_message). error_message is None on success.
    """
    config = {
        "mode": "both",
        "inventory": str(DEFAULT_INVENTORY_PATH),
        "timeout": DEFAULT_TIMEOUT,
        "show_help": False,
    }

    i = 0
    n = len(argv)
    while i < n:
        arg = argv[i]

        if arg in ("-h", "--help"):
            config["show_help"] = True
            return config, None

        elif arg in ("-m", "--mode"):
            if i + 1 >= n:
                return None, f"Option {arg} requires a value"
            i += 1
            mode_value = argv[i]
            if mode_value not in VALID_MODES:
                return None, f"Unknown mode: '{mode_value}' (expected one of {', '.join(VALID_MODES)})"
            config["mode"] = mode_value

        elif arg in ("-i", "--inventory"):
            if i + 1 >= n:
                return None, f"Option {arg} requires a value"
            i += 1
            config["inventory"] = argv[i]

        elif arg in ("-t", "--timeout"):
            if i + 1 >= n:
                return None, f"Option {arg} requires a value"
            i += 1
            raw_timeout = argv[i]
            try:
                timeout_value = int(raw_timeout)
            except ValueError:
                return None, f"Invalid timeout value: '{raw_timeout}' (must be a whole number of seconds)"
            if timeout_value < 1:
                return None, f"Invalid timeout value: '{raw_timeout}' (must be >= 1)"
            config["timeout"] = timeout_value

        else:
            return None, f"Unknown argument: '{arg}'"

        i += 1

    return config, None


def is_valid_ipv4(address):
    """Mirrors lib/validate.sh's is_valid_ipv4 field-for-field, so Part A
    and Part B accept/reject exactly the same rows (INT-01)."""
    match = IPV4_PATTERN.match(address)
    if not match:
        return False
    for octet_str in match.groups():
        if len(octet_str) > 1 and octet_str[0] == "0":
            return False
        octet = int(octet_str)
        if octet < 0 or octet > 255:
            return False
    return True


def is_valid_port(port_str):
    """Mirrors lib/validate.sh's is_valid_port (INT-01)."""
    if not PORT_PATTERN.match(port_str):
        return False
    port = int(port_str)
    return 1 <= port <= 65535


def is_valid_hostname(name):
    """Mirrors lib/validate.sh's is_valid_hostname (INT-01)."""
    if not name:
        return False
    if HOSTNAME_INVALID_PATTERN.search(name):
        return False
    return True


def load_inventory(inventory_path):
    """
    Reads inventory_path row by row and validates every field, using the
    same rules as Bash's lib/inventory.sh (INT-01). Malformed rows are
    rejected individually, naming the line number and reason, and
    processing continues - never stops on the first bad row (FR-P02).

    Returns (targets, valid_count, rejected_count).

    Raises FileNotFoundError / PermissionError if the file itself cannot
    be opened, and ValueError if it opens but is empty - the caller (main)
    decides how each maps to an exit code.
    """
    with open(inventory_path, "r", encoding="utf-8") as handle:
        lines = handle.readlines()

    if not lines:
        raise ValueError(f"Inventory file is empty: {inventory_path}")

    targets = []
    valid_count = 0
    rejected_count = 0

    for line_number, raw_line in enumerate(lines, start=1):
        if line_number == 1:
            continue  # header row

        line = raw_line.strip()
        if not line:
            print(f"[INFO] Line {line_number}: skipped (blank line)")
            rejected_count += 1
            continue

        fields = line.split(",")
        if len(fields) != 5:
            print(
                f"[ERROR] Line {line_number}: rejected - expected 5 fields "
                f"(hostname,ip_address,service,port,critical), found {len(fields)}",
                file=sys.stderr,
            )
            rejected_count += 1
            continue

        hostname, ip_address, service, port_str, critical_str = (f.strip() for f in fields)

        if not is_valid_hostname(hostname):
            print(f"[ERROR] Line {line_number}: rejected - field 'hostname' is empty or invalid", file=sys.stderr)
            rejected_count += 1
            continue

        if not is_valid_ipv4(ip_address):
            print(
                f"[ERROR] Line {line_number}: rejected - field 'ip_address' "
                f"('{ip_address}') is not a valid IPv4 address",
                file=sys.stderr,
            )
            rejected_count += 1
            continue

        if not is_valid_port(port_str):
            print(
                f"[ERROR] Line {line_number}: rejected - field 'port' "
                f"('{port_str}') is not an integer in 1-65535",
                file=sys.stderr,
            )
            rejected_count += 1
            continue

        if not service:
            print(f"[ERROR] Line {line_number}: rejected - field 'service' is empty", file=sys.stderr)
            rejected_count += 1
            continue

        critical_lower = critical_str.lower()
        if critical_lower not in ("yes", "no"):
            print(
                f"[INFO] Line {line_number}: field 'critical' ('{critical_str}') "
                f"is not yes/no - defaulting to 'no'"
            )
            critical = False
        else:
            critical = critical_lower == "yes"

        targets.append(
            Target(
                hostname=hostname,
                ip_address=ip_address,
                service=service,
                port=int(port_str),
                critical=critical,
            )
        )
        valid_count += 1

    return targets, valid_count, rejected_count


def check_service(hostname, ip_address, service, port, timeout):
    """
    Checks a single service on a single host by attempting a TCP connect.
    Implements FR-P03. Guaranteed to never raise an unhandled exception:
    every failure path is caught with a NAMED exception type (no bare
    except anywhere), and the socket is closed on every path via `finally`.

    `connect_ex` (rather than `connect`) is the key choice here: on a
    refused connection it returns an errno instead of raising, which is
    exactly what lets us record "closed" as a normal finding rather than
    treating it as an error. A genuine timeout still raises socket.timeout,
    which we catch separately so it is recorded distinctly from "closed",
    as the brief's error-handling table requires.

    Returns a CheckResult. Never returns None and never propagates an
    exception to the caller.
    """
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    start = time.monotonic()
    state = "error"
    error_detail = ""
    sock = None

    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        result_code = sock.connect_ex((ip_address, port))
        if result_code == 0:
            state = "open"
        elif result_code == errno.ECONNREFUSED:
            # An actual TCP-level active refusal from a real (if closed)
            # port - a fast, definitive answer. This is Dilani's "closed
            # port", not a failure of our tool.
            state = "closed"
            error_detail = "Connection actively refused"
        elif result_code in (errno.ETIMEDOUT, errno.EAGAIN, errno.EWOULDBLOCK):
            # connect_ex did not raise socket.timeout, but the errno it
            # returned still means "no answer arrived" - functionally a
            # timeout, and must be recorded distinctly from a refusal.
            state = "timeout"
            error_detail = f"No response within {timeout}s (errno {result_code})"
        elif result_code in (errno.EHOSTUNREACH, errno.ENETUNREACH):
            # The network stack gave a definitive "no route to host"
            # answer. This is neither a refusal nor a timeout - it is a
            # distinct network-level error, and forcing it into either of
            # the other two buckets would misrepresent what happened.
            # (Found via testing: this exact target alternated between
            # this errno and EAGAIN across repeated calls with very
            # different timings, which is what exposed the fact that a
            # duration-based heuristic here would be non-deterministic.)
            state = "error"
            error_detail = f"No route to host (errno {result_code})"
        else:
            state = "error"
            error_detail = f"Unexpected connect error (errno {result_code})"
    except socket.timeout:
        state = "timeout"
        error_detail = f"No response within {timeout}s"
    except socket.gaierror as exc:
        state = "error"
        error_detail = f"Address could not be resolved: {exc}"
    except OSError as exc:
        # Covers any other OS-level failure not captured by a specific
        # errno above.
        state = "error"
        error_detail = str(exc)
    finally:
        if sock is not None:
            sock.close()

    elapsed_ms = round((time.monotonic() - start) * 1000, 2)

    return CheckResult(
        hostname=hostname,
        ip_address=ip_address,
        service=service,
        port=port,
        state=state,
        response_time_ms=elapsed_ms,
        timestamp=timestamp,
        error_detail=error_detail,
    )


def run_sequential(targets, timeout):
    """
    Runs check_service for every target, one after another. Implements the
    sequential half of FR-P04. An empty target list simply produces an
    empty result list and a near-zero duration - no special-casing needed,
    which is itself the correct handling of that error condition.

    Returns (results, duration_seconds).
    """
    start = time.monotonic()
    results = [
        check_service(target.hostname, target.ip_address, target.service, target.port, timeout)
        for target in targets
    ]
    duration = time.monotonic() - start
    return results, duration


def run_concurrent(targets, timeout):
    """
    Runs check_service for every target using one worker thread per
    target, started without waiting for each other, then joined once all
    have been started. Implements the concurrent half of FR-P04.

    Concurrency-safety notes (for the report / demo question on what is
    shared and what could go wrong):
      - `results` is a single list shared by every worker thread. Each
        worker is given its own unique index up front and only ever
        writes to results[that_index] - no two threads ever write the
        same slot, so there is no read-modify-write race on the list's
        contents. This is what guarantees the "out of order completion"
        error condition cannot corrupt or misplace a result: the returned
        list is always in original target order regardless of which
        thread actually finishes first.
      - Threads are NOT given a lock, and deliberately so: since each
        thread's writes are confined to a disjoint index, a lock would
        add overhead without removing any real race. The one operation
        that IS technically shared read/write across threads - Python's
        list object itself - is protected at the bytecode level by the
        GIL for a single __setitem__ call, so this is safe in CPython
        without extra synchronisation.
      - We do not add a try/except around the worker body. check_service()
        is written so that it can never raise (every failure path inside
        it is caught with a named exception - see FR-P03), so there is no
        exception left for a worker to propagate. Handling this by
        eliminating the exception at its source is preferred over
        wrapping the worker in a broad except, which the technical
        requirements rule out ("no bare catch-all exception handler
        anywhere").
      - Threads are created with daemon=True so that, if the process is
        interrupted (Ctrl+C) while sockets are still open, Python does not
        block process exit waiting for a straggler thread.

    Returns (results, duration_seconds), with results in the same target
    order as the input list.
    """
    start = time.monotonic()
    results = [None] * len(targets)
    threads = []

    def worker(index, target):
        results[index] = check_service(target.hostname, target.ip_address, target.service, target.port, timeout)

    for index, target in enumerate(targets):
        thread = threading.Thread(target=worker, args=(index, target), name=f"probe-{target.hostname}", daemon=True)
        threads.append(thread)
        thread.start()

    for thread in threads:
        thread.join()

    duration = time.monotonic() - start
    return results, duration


def load_previous_results(results_path):
    """
    Loads the previous run's results from results_path. Implements the
    "previous results file missing or corrupt" error condition from
    FR-P05: both are treated as a first run, never a crash, and the
    caller is given an explicit human-readable reason to report.

    Returns (previous_results_or_None, note). note is None on success;
    otherwise it explains why there is nothing to compare against.
    previous_results, when present, is a list of plain dicts (as loaded
    from JSON) with the same keys as CheckResult's fields.
    """
    try:
        with open(results_path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        return data.get("results", []), None
    except FileNotFoundError:
        return None, "No previous results file found - this is the first run."
    except json.JSONDecodeError:
        return None, "Previous results file is corrupt - treating this run as the first run."
    except PermissionError:
        return None, "Previous results file could not be read (permission denied) - treating this run as the first run."


def save_results(results_path, results, run_timestamp):
    """
    Persists the current run's results as the single "latest status"
    snapshot, OVERWRITTEN every run - unlike Part A's append-only
    history.csv. This is a deliberate difference: history.csv exists to
    answer "how has this looked over time", so it must never lose a
    record, while results.json exists to answer "what is true right now"
    for FR-P07's status service, so last-write-wins is exactly correct.

    Returns True on success, False on failure. Failures (missing
    directory, no write permission) are logged with named exceptions and
    never raised - a report can still be produced even if persistence
    for the *next* run's comparison fails.
    """
    payload = {
        "run_timestamp": run_timestamp,
        "results": [asdict(result) for result in results],
    }
    try:
        results_path.parent.mkdir(parents=True, exist_ok=True)
        with open(results_path, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2)
        return True
    except PermissionError:
        print(f"[ERROR] Cannot write results file (permission denied): {results_path}", file=sys.stderr)
        return False
    except OSError as exc:
        print(f"[ERROR] Cannot write results file: {exc}", file=sys.stderr)
        return False


def write_csv_report(reports_dir, results, run_timestamp, filename_stamp):
    """
    Writes this run's results as a timestamped CSV for Part A's report
    stage to consume (INT-03). Column order, delimiter and quoting here
    ARE the data contract with Part A, and will be finalised together
    with Part A during integration - kept simple and explicit for now:
    comma-delimited, csv.writer's default quoting (quotes only fields
    that need it), one row per target, run timestamp repeated per row.

    Returns the Path written, or None on failure (logged, not raised).
    """
    report_path = reports_dir / f"py_results_{filename_stamp}.csv"
    try:
        reports_dir.mkdir(parents=True, exist_ok=True)
        with open(report_path, "w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle)
            writer.writerow(
                ["timestamp", "hostname", "ip_address", "service", "port", "state", "response_time_ms", "error_detail"]
            )
            for result in results:
                writer.writerow(
                    [
                        run_timestamp,
                        result.hostname,
                        result.ip_address,
                        result.service,
                        result.port,
                        result.state,
                        result.response_time_ms,
                        result.error_detail,
                    ]
                )
        return report_path
    except PermissionError:
        print(f"[ERROR] Cannot write report (permission denied): {report_path}", file=sys.stderr)
        return None
    except OSError as exc:
        print(f"[ERROR] Cannot write report: {exc}", file=sys.stderr)
        return None


def compute_changes(current_results, previous_results):
    """
    Change detection via set operations on (ip_address, port) pairs, as
    FR-P05 explicitly requires. Every monitored pair is classified into
    exactly one of three buckets relative to the previous run:
      newly_opened - closed/absent before, open now
      newly_closed - open before, not open now
      unchanged    - same open-vs-not-open state as before (this
                     deliberately covers "still open" AND "still closed",
                     using union/intersection/difference together)

    Returns a dict of three sets plus is_first_run (True when there is
    nothing to compare against - previous_results is None).
    """
    current_open = {(r.ip_address, r.port) for r in current_results if r.state == "open"}
    current_all = {(r.ip_address, r.port) for r in current_results}

    if previous_results is None:
        return {"newly_opened": set(), "newly_closed": set(), "unchanged": set(), "is_first_run": True}

    previous_open = {(item["ip_address"], item["port"]) for item in previous_results if item["state"] == "open"}
    previous_all = {(item["ip_address"], item["port"]) for item in previous_results}

    newly_opened = current_open - previous_open
    newly_closed = previous_open - current_open
    unchanged = (current_open & previous_open) | ((current_all - current_open) & (previous_all - previous_open))

    return {"newly_opened": newly_opened, "newly_closed": newly_closed, "unchanged": unchanged, "is_first_run": False}


def print_summary(results, run_duration, changes):
    """
    Prints an aligned, human-readable summary of one run and returns the
    exit code this run maps to. Implements FR-P06.

    Determinism note: every sort below uses a full tuple key (never a
    single field alone), so a tie on the primary key - e.g. two services
    with the identical response time - always falls through to hostname
    and port rather than depending on incidental list order. This is
    what the "tie in the ranking must still sort deterministically"
    error condition requires.

    An empty result set is handled explicitly rather than left to crash
    on an empty Counter/sorted() (which would not actually raise, but
    printing "0 of 0 services are up" is misleading) - it is currently
    unreachable in main()'s flow (valid_count==0 is caught earlier), but
    is handled here too so the function is correct in isolation.
    """
    print()
    print("=" * 60)
    print("NetWatch (Python) - Run Summary")
    print("=" * 60)

    if not results:
        print("No results to summarise - nothing was checked.")
        print("=" * 60)
        return EXIT_GENERAL_ERROR

    state_counts = Counter(result.state for result in results)
    print(f"{'Total checks:':<20}{len(results)}")
    for state in ("open", "closed", "timeout", "error"):
        print(f"{('  ' + state + ':'):<20}{state_counts.get(state, 0)}")

    print()
    print(f"{'Host':<16}{'Address:Port':<22}{'State':<10}{'RTT (ms)':<10}")
    print("-" * 60)
    for result in sorted(results, key=lambda r: (r.hostname, r.port)):
        address_port = f"{result.ip_address}:{result.port}"
        print(f"{result.hostname:<16}{address_port:<22}{result.state:<10}{result.response_time_ms:<10}")

    print()
    print("Slowest responses:")
    slowest = sorted(results, key=lambda r: (-r.response_time_ms, r.hostname, r.port))[:3]
    for result in slowest:
        print(f"  {result.hostname:<16} {result.response_time_ms}ms")

    print()
    print(f"Run duration: {run_duration:.3f}s")

    if not changes["is_first_run"]:
        print(
            f"Changes since last run: +{len(changes['newly_opened'])} opened, "
            f"-{len(changes['newly_closed'])} closed, "
            f"{len(changes['unchanged'])} unchanged"
        )

    open_count = state_counts.get("open", 0)
    all_open = open_count == len(results)
    exit_code = EXIT_SUCCESS if all_open else EXIT_ISSUES_DETECTED

    print("=" * 60)
    if all_open:
        print("STATUS: ALL SERVICES OK")
    else:
        print(f"STATUS: {len(results) - open_count} OF {len(results)} SERVICE(S) NOT OPEN")
    print("=" * 60)

    return exit_code


def main():
    config, error = parse_arguments(sys.argv[1:])

    if error:
        print(f"[ERROR] {error}", file=sys.stderr)
        print(usage_text(), file=sys.stderr)
        sys.exit(EXIT_USAGE_ERROR)

    if config["show_help"]:
        print(usage_text())
        sys.exit(EXIT_SUCCESS)

    print(f"[INFO] NetWatch (Python) starting - inventory: {config['inventory']}")
    print(f"[INFO] mode={config['mode']} timeout={config['timeout']}s")

    try:
        targets, valid_count, rejected_count = load_inventory(config["inventory"])
    except FileNotFoundError:
        print(f"[ERROR] Inventory file not found: {config['inventory']}", file=sys.stderr)
        sys.exit(EXIT_GENERAL_ERROR)
    except PermissionError:
        print(f"[ERROR] Inventory file not readable (permission denied): {config['inventory']}", file=sys.stderr)
        sys.exit(EXIT_GENERAL_ERROR)
    except ValueError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        sys.exit(EXIT_GENERAL_ERROR)

    print(f"[INFO] Inventory validation complete: {valid_count} valid row(s), {rejected_count} rejected row(s)")

    if valid_count == 0:
        print("[ERROR] No valid targets to check - nothing to report", file=sys.stderr)
        sys.exit(EXIT_GENERAL_ERROR)

    for target in targets:
        print(f"[INFO]   -> {target.hostname} ({target.ip_address}:{target.port}, {target.service}, critical={target.critical})")

    seq_results = conc_results = None
    seq_duration = conc_duration = None

    if config["mode"] in ("sequential", "both"):
        seq_results, seq_duration = run_sequential(targets, config["timeout"])
        print(f"[INFO] Sequential scan: {len(seq_results)} target(s) in {seq_duration:.3f}s")

    if config["mode"] in ("concurrent", "both"):
        conc_results, conc_duration = run_concurrent(targets, config["timeout"])
        print(f"[INFO] Concurrent scan: {len(conc_results)} target(s) in {conc_duration:.3f}s")

    if config["mode"] == "both":
        # Compare "open vs not open" per host, not the exact state string.
        # Testing exposed a real OS-level behaviour: the FIRST connection
        # attempt to an address with no route is slow (the kernel attempts
        # route/ARP resolution before giving up), while a SECOND attempt
        # moments later to the same address returns quickly with a
        # definitive "no route" answer, because that negative result is
        # now cached. Since sequential runs first and concurrent runs
        # second, an unreachable target can legitimately be classified
        # "timeout" in the sequential pass and "error" (no route) in the
        # concurrent pass a fraction of a second later - both are
        # correct, distinct, truthful descriptions of what actually
        # happened on each attempt. Requiring the exact state string to
        # match would flag a real, explainable network-timing effect as
        # a false "bug". What must match - and does - is the one thing
        # that actually matters for monitoring: whether the service was
        # found to be open or not.
        seq_signature = sorted((r.hostname, r.state == "open") for r in seq_results)
        conc_signature = sorted((r.hostname, r.state == "open") for r in conc_results)
        if seq_signature == conc_signature:
            print("[INFO] Sequential and concurrent results match (same open/closed determination per host).")
        else:
            print("[ERROR] Sequential and concurrent results DIFFER in open/closed determination - investigate.", file=sys.stderr)

        if conc_duration > 0:
            speedup = seq_duration / conc_duration
            print(f"[INFO] Speed-up (sequential / concurrent): {speedup:.2f}x")

    # The most recently computed result set becomes "this run's" results
    # for FR-P05 (persistence/change-detection) and FR-P06 (summary) -
    # concurrent is preferred when both ran, as it is the mode the tool
    # would actually use day-to-day.
    results = conc_results if conc_results is not None else seq_results

    for result in results:
        detail = f" ({result.error_detail})" if result.error_detail else ""
        print(
            f"[INFO]   {result.hostname:<15} {result.ip_address}:{result.port:<6} "
            f"state={result.state:<8} rtt={result.response_time_ms}ms{detail}"
        )

    now = datetime.now()
    run_timestamp = now.strftime("%Y-%m-%d %H:%M:%S")
    filename_stamp = now.strftime("%Y%m%d_%H%M%S")

    previous_results, note = load_previous_results(RESULTS_JSON_PATH)
    if note:
        print(f"[INFO] {note}")

    changes = compute_changes(results, previous_results)

    if not save_results(RESULTS_JSON_PATH, results, run_timestamp):
        print("[ERROR] Continuing without persisting this run's snapshot.", file=sys.stderr)

    report_path = write_csv_report(REPORTS_DIR, results, run_timestamp, filename_stamp)
    if report_path:
        print(f"[INFO] Report written: {report_path}")

    print("[INFO] Change detection (vs previous run):")
    if changes["is_first_run"]:
        print("[INFO]   No previous run available for comparison - nothing to compare (first run).")
    else:
        opened = sorted(changes["newly_opened"]) or "none"
        closed = sorted(changes["newly_closed"]) or "none"
        print(f"[INFO]   Newly opened : {opened}")
        print(f"[INFO]   Newly closed : {closed}")
        print(f"[INFO]   Unchanged    : {len(changes['unchanged'])} address:port pair(s)")

    run_duration = conc_duration if conc_duration is not None else seq_duration
    exit_code = print_summary(results, run_duration, changes)
    sys.exit(exit_code)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        # Technical requirement: Ctrl+C must exit cleanly with a message,
        # never a raw traceback. Worker threads are daemon=True (see
        # run_concurrent) so this exit is not blocked by any in-flight
        # socket check.
        print("\n[ERROR] Interrupted by user - shutting down.", file=sys.stderr)
        sys.exit(EXIT_GENERAL_ERROR)
