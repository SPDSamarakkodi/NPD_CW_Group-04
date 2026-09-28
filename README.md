# NetWatch - Network Programming Design Coursework

**Group ID:** [FILL IN - e.g. G03]
**Members:** [FILL IN - full names]
**Module:** HNDNE-25.2F Network Programming Design

## Work allocation (summary - see Appendix B in the report for full detail)

| Requirement area | Owner(s) | Approx. share |
|---|---|---|
| Part A - Shell Script (FR-S01-S05) | H R C D Samaranayake | 33.3% |
| Part B - Python (FR-P01-P07) | S P D Samarakkodi | 33.3% |
| Integration (INT-01-03) | H R C D Samaranayake, S P D Samarakkodi | 50% | 50% |
| Testing, debugging evidence | G A Himakelum, H R C D Samaranayake | 50% | 50% |
| Report, diagrams, documentation | G A Himakelum | 50% |

---

## What this is

NetWatch is a two-part network monitoring toolkit built for the Serendib
Logistics scenario in the coursework brief:

- **Part A** (`ShellScript/netwatch.sh`) - reads the shared device
  inventory, checks ICMP reachability for each host, records every check
  to a growing history file, invokes Part B as a pipeline stage, and
  produces a consolidated availability report.
- **Part B** (`Python/netwatch.py`, `Python/status_server.py`) - checks
  whether services are actually answering on their ports (TCP sockets),
  runs checks both sequentially and concurrently, detects what changed
  since the last run, and publishes the current status over HTTP.

Both components read the **same** `ShellScript/config/inventory.csv` and
apply the same validation rules (INT-01). Part A invokes Part B as part
of its own run and shares one exit-code scheme with it (INT-02). Part
A's final report merges Part B's live service-state data into its own
reachability/availability figures (INT-03).

## Prerequisites

- Bash 4+ (Linux; `ping`, `awk`, `sort`, `find` from a standard install -
  nothing extra to install)
- Python 3.8+ (standard library only - no `pip install` needed anywhere)
- No lab servers or VMs required for local testing

## Authorised scanning boundary

Only ever point this at `127.0.0.1` / `localhost`, addresses within
`127.0.0.0/8`, or the specific lab IP range issued by your lecturer in
writing. The sample `config/inventory.csv` included here uses only
loopback addresses (`127.0.0.1`, `127.0.0.2`) and one RFC 5737
documentation address (`192.0.2.55`) as a deliberately-unreachable test
target - it is non-routable by design and never sends real traffic
anywhere.

## Quick start (from a clean extract, ~5 minutes)

### 1. Stand up the simulated Serendib estate

Three terminals (or background each with `&`), one HTTP server per port
referenced in `config/inventory.csv`:

```bash
cd /tmp && mkdir -p dummy_intranet dummy_warehouse dummy_fileserver
python3 -m http.server 8091 --directory dummy_intranet &
python3 -m http.server 8092 --directory dummy_warehouse &
python3 -m http.server 8093 --directory dummy_fileserver &
```

Ports `8094` and `8099` are deliberately left with nothing listening
(closed-port test cases), and `192.0.2.55` is deliberately unreachable -
this is intentional, matching the brief's requirement to include both
cases in the test estate.

### 2. Run Part A (this also invokes Part B automatically - INT-02)

```bash
cd ShellScript
./netwatch.sh
```

Run with `-h` to see all options (`-i` inventory path, `-o` output
directory, `-t` probe timeout, `-r` report-only mode). Exit code `0` =
all OK, `3` = at least one issue detected, `1`/`2` = a real error - see
`netwatch.sh -h` for the full documented scheme.

### 3. Run Part B standalone (optional - Part A already does this for you)

```bash
cd Python
python3 netwatch.py -h                    # see all options
python3 netwatch.py                       # runs sequential + concurrent, both timed
```

### 4. Run the status server

```bash
cd Python
python3 status_server.py                  # http://127.0.0.1:8100/ by default
```

Binds to `127.0.0.1` only by default (a deliberate security choice - see
the report's Security Considerations section); pass `--host 0.0.0.0` to
expose it more widely if genuinely needed.

### 5. Where output lands

| Path | What |
|---|---|
| `ShellScript/data/history.csv` | Every reachability check ever run (append-only) |
| `ShellScript/logs/netwatch.log` | Run narrative (timestamped INFO/ERROR) |
| `ShellScript/reports/netwatch_<timestamp>.csv` | Consolidated report (Part A + merged Part B data) |
| `Python/data/results.json` | Latest service-check snapshot (overwritten each run) |
| `Python/reports/py_results_<timestamp>.csv` | Timestamped per-run service results (feeds INT-03) |

## Scheduling (cron)

See `Evidence/crontab_evidence.txt` for the exact crontab line and how
to capture proof of a scheduled run.

## Editing the inventory

`ShellScript/config/inventory.csv` is the single shared file both
components read - edit it in place (it is intentionally plain CSV with a
header row, editable by someone who isn't a programmer). Malformed rows
are rejected individually with a line number and reason; the tools never
stop on the first bad row.

## A note on this skeleton's sample data

The `data/`, `logs/` and `reports/` folders in this skeleton contain real
sample output from a working run, generated in a sandboxed build
environment that had no `ping` binary available (and no network access
to install one) - a clearly-labelled mock `ping` was used only to
generate this placeholder sample data. **`ping` is a standard
pre-installed utility on virtually every real Linux machine (it's what
Dilani does manually in the brief's own scenario), so no mocking is
needed on your actual lab/dev machine.** Regenerate this sample data with
a real run on your own machine before final submission, so the evidence
in the archive reflects genuine `ping` output.

## Still outstanding before submission

- `Documentation/Coursework_Report.pdf`, `Network_Architecture.png`,
  `Program_Architecture.png` (see placeholder notes in `Documentation/`)
- Real screenshots for every test case (see placeholder note in
  `Evidence/screenshots/`)
- `Evidence/crontab_evidence.txt` completed with real evidence
- A clean `shellcheck ShellScript/netwatch.sh ShellScript/lib/*.sh` run
  (or warnings justified in the report)
- Work allocation table and member names at the top of this file
