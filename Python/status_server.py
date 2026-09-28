#!/usr/bin/env python3
"""
status_server.py

Script  : status_server.py
Purpose : NetWatch (Python) status server for Serendib Logistics.
          Publishes the most recently persisted service-check results
          (data/results.json, written by netwatch.py) as a readable HTML
          status page over HTTP. Implements FR-P07.
Authors : <YOUR NAMES HERE>
Date    : September 2026
Usage   : python3 status_server.py [-p PORT] [--host HOST]
                                    [-r RESULTS_PATH] [-h]
          Run with no arguments to use sensible defaults
          (http://127.0.0.1:8100/).
"""

import sys
import json
import html
import errno
from pathlib import Path
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

EXIT_SUCCESS = 0          # clean shutdown (e.g. Ctrl+C)
EXIT_GENERAL_ERROR = 1    # could not start (port in use, permission denied, etc.)
EXIT_USAGE_ERROR = 2      # bad command-line arguments

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_RESULTS_PATH = SCRIPT_DIR / "data" / "results.json"
DEFAULT_PORT = 8100

# Deliberately localhost-only by default. This service publishes
# internal hostnames, addresses and open/closed ports - binding to every
# interface (0.0.0.0) by default would widen who can see that far beyond
# what Dilani's requirement ("see current status without a terminal")
# actually needs. See the report's Security Considerations / Exposure
# section for the full trade-off; --host lets this be changed explicitly
# and deliberately if the deployment genuinely needs it.
DEFAULT_HOST = "127.0.0.1"


def usage_text():
    return f"""NetWatch (Python) status server - publishes current status over HTTP

Usage: python3 status_server.py [OPTIONS]

Options:
  -p, --port PORT       Listen port (default: {DEFAULT_PORT})
      --host HOST       Interface to bind to (default: {DEFAULT_HOST} - localhost only)
  -r, --results PATH    Path to results.json to serve (default: {DEFAULT_RESULTS_PATH})
  -h, --help            Show this help message and exit

Exit codes:
  0  clean shutdown (e.g. via Ctrl+C)
  1  general error (could not start - port in use, permission denied, etc.)
  2  usage error (bad command-line arguments)
"""


def parse_arguments(argv):
    """
    Parses argv directly (no argparse), mirroring netwatch.py's style for
    consistency across the Python component. Pure function - no
    sys.exit()/printing - keeps the module safely importable.
    Returns (config, error_message).
    """
    config = {
        "port": DEFAULT_PORT,
        "host": DEFAULT_HOST,
        "results_path": DEFAULT_RESULTS_PATH,
        "show_help": False,
    }

    i = 0
    n = len(argv)
    while i < n:
        arg = argv[i]

        if arg in ("-h", "--help"):
            config["show_help"] = True
            return config, None

        elif arg in ("-p", "--port"):
            if i + 1 >= n:
                return None, f"Option {arg} requires a value"
            i += 1
            raw_port = argv[i]
            try:
                port_value = int(raw_port)
            except ValueError:
                return None, f"Invalid port value: '{raw_port}' (must be a whole number)"
            if not (1 <= port_value <= 65535):
                return None, f"Invalid port value: '{raw_port}' (must be 1-65535)"
            config["port"] = port_value

        elif arg == "--host":
            if i + 1 >= n:
                return None, f"Option {arg} requires a value"
            i += 1
            config["host"] = argv[i]

        elif arg in ("-r", "--results"):
            if i + 1 >= n:
                return None, f"Option {arg} requires a value"
            i += 1
            config["results_path"] = Path(argv[i])

        else:
            return None, f"Unknown argument: '{arg}'"

        i += 1

    return config, None


def load_current_status(results_path):
    """
    Loads the most recently persisted results for serving. Never raises -
    this runs inside a request handler, so a missing/corrupt file must
    become a normal, readable response, not a crashed request (FR-P07's
    "no results file to serve yet" condition).

    Returns (data_or_None, error_message).
    """
    try:
        with open(results_path, "r", encoding="utf-8") as handle:
            return json.load(handle), None
    except FileNotFoundError:
        return None, "No results have been persisted yet - run netwatch.py first."
    except json.JSONDecodeError:
        return None, "The results file is corrupt and could not be read."
    except PermissionError:
        return None, "The results file could not be read (permission denied)."


def render_status_page(data, error_message):
    """
    Builds a simple, readable HTML status page from the loaded results
    (or an explanatory message when there is nothing to serve yet).

    Every value that originates from the results/inventory file is passed
    through html.escape() before being embedded - that file is ultimately
    derived from an inventory non-programmers edit by hand, and should
    never be trusted to be safe to drop directly into HTML.
    """
    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    if error_message:
        run_timestamp = "n/a"
        body = f"<p><strong>{html.escape(error_message)}</strong></p>"
    else:
        run_timestamp = html.escape(str(data.get("run_timestamp", "unknown")))
        results = sorted(data.get("results", []), key=lambda r: (r.get("hostname", ""), r.get("port", 0)))
        row_lines = []
        for result in results:
            state = str(result.get("state", ""))
            row_lines.append(
                "<tr>"
                f"<td>{html.escape(str(result.get('hostname', '')))}</td>"
                f"<td>{html.escape(str(result.get('ip_address', '')))}</td>"
                f"<td>{html.escape(str(result.get('service', '')))}</td>"
                f"<td>{html.escape(str(result.get('port', '')))}</td>"
                f'<td class="state-{html.escape(state)}">{html.escape(state)}</td>'
                f"<td>{html.escape(str(result.get('response_time_ms', '')))}</td>"
                "</tr>"
            )
        rows_html = "\n".join(row_lines)
        body = (
            "<table>"
            "<thead><tr><th>Host</th><th>Address</th><th>Service</th>"
            "<th>Port</th><th>State</th><th>RTT (ms)</th></tr></thead>"
            f"<tbody>{rows_html}</tbody>"
            "</table>"
        )

    return f"""<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>NetWatch Status - Serendib Logistics</title>
  <style>
    body {{ font-family: sans-serif; margin: 2em; }}
    table {{ border-collapse: collapse; width: 100%; }}
    th, td {{ border: 1px solid #ccc; padding: 0.4em 0.8em; text-align: left; }}
    th {{ background: #eee; }}
    .state-open {{ color: green; font-weight: bold; }}
    .state-closed, .state-timeout, .state-error {{ color: #b00020; font-weight: bold; }}
  </style>
</head>
<body>
  <h1>NetWatch Status - Serendib Logistics</h1>
  <p>Last check run: {run_timestamp}</p>
  {body}
  <p><small>Page generated: {generated_at}</small></p>
</body>
</html>
"""


class StatusRequestHandler(BaseHTTPRequestHandler):
    """
    BaseHTTPRequestHandler creates one instance per request, so the
    results path to serve is injected via a class attribute set by
    main() before the server starts, rather than through __init__.
    """

    results_path = DEFAULT_RESULTS_PATH

    def do_GET(self):
        data, error_message = load_current_status(self.results_path)
        page = render_status_page(data, error_message)
        body = page.encode("utf-8")

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format_string, *args):
        # Overrides BaseHTTPRequestHandler's default (which writes an
        # Apache-style line straight to stderr) with our own format, so
        # every request served gets one clear, timestamped log line -
        # exactly what FR-P07 requires.
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        client_address = self.client_address[0]
        print(f"[{timestamp}] [INFO] Request served: {client_address} - {format_string % args}")


def main():
    config, error = parse_arguments(sys.argv[1:])

    if error:
        print(f"[ERROR] {error}", file=sys.stderr)
        print(usage_text(), file=sys.stderr)
        sys.exit(EXIT_USAGE_ERROR)

    if config["show_help"]:
        print(usage_text())
        sys.exit(EXIT_SUCCESS)

    StatusRequestHandler.results_path = config["results_path"]

    try:
        server = ThreadingHTTPServer((config["host"], config["port"]), StatusRequestHandler)
    except PermissionError:
        print(
            f"[ERROR] Permission denied binding to port {config['port']} "
            f"(ports below 1024 usually need elevated privileges)",
            file=sys.stderr,
        )
        sys.exit(EXIT_GENERAL_ERROR)
    except OSError as exc:
        if exc.errno == errno.EADDRINUSE:
            print(f"[ERROR] Port {config['port']} is already in use", file=sys.stderr)
        else:
            print(f"[ERROR] Could not start server: {exc}", file=sys.stderr)
        sys.exit(EXIT_GENERAL_ERROR)

    print(f"[INFO] NetWatch status server listening on http://{config['host']}:{config['port']}/")
    print(f"[INFO] Serving results from: {config['results_path']}")
    print("[INFO] Press Ctrl+C to stop.")

    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        # Technical requirement: Ctrl+C must exit cleanly with a message,
        # never a raw traceback.
        print("\n[INFO] Interrupted by user - server stopped.", file=sys.stderr)
        sys.exit(EXIT_SUCCESS)
