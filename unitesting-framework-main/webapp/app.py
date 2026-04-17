"""
app.py – Flask web application for the SQL Unit Testing Dashboard.

Provides a browser UI that lets a developer:
  1. Click "Run Unit Tests" to execute all SQL test cases against SQL Server.
  2. View per-test PASS/FAIL results with timing and failure details.
  3. Download the pytest-html report and JUnit XML report.

The test run executes in a background thread so the browser can poll for
status without blocking the HTTP worker.

NOTE: This application is intended for local development use only.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import threading
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

from flask import Flask, abort, jsonify, render_template, send_file

# ---------------------------------------------------------------------------
# Flask app setup
# ---------------------------------------------------------------------------
app = Flask(__name__)

APP_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPORTS_DIR = os.environ.get("REPORTS_DIR", os.path.join(APP_DIR, "reports"))

# Maximum characters kept from a failure message before truncation.
MAX_ERROR_MSG_LEN = 1000

# ---------------------------------------------------------------------------
# Shared run state (protected by _lock)
# ---------------------------------------------------------------------------
_lock = threading.Lock()
_state: dict = {
    "status": "idle",       # idle | running | done | error
    "started_at": None,
    "finished_at": None,
    "summary": None,        # dict with total/passed/failed/skipped/duration
    "tests": [],            # list of test result dicts
    "output": "",           # raw console output
    "error": None,          # error string when status == "error"
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _parse_junit_xml(xml_path: str) -> tuple[dict, list[dict]]:
    """Parse a JUnit XML file produced by pytest and return (summary, tests)."""
    tree = ET.parse(xml_path)
    root = tree.getroot()

    suites = root.findall("testsuite") if root.tag == "testsuites" else [root]

    tests: list[dict] = []
    total = passed = failed = skipped = 0
    total_time = 0.0

    for suite in suites:
        for case in suite.findall("testcase"):
            raw_name = case.get("name", "")
            time_sec = float(case.get("time", 0))
            total_time += time_sec

            failure_el = case.find("failure")
            error_el = case.find("error")
            skip_el = case.find("skipped")

            if failure_el is not None:
                status = "FAIL"
                message = failure_el.get("message", "") or (failure_el.text or "")
                failed += 1
            elif error_el is not None:
                status = "FAIL"
                message = error_el.get("message", "") or (error_el.text or "")
                failed += 1
            elif skip_el is not None:
                status = "SKIP"
                message = skip_el.get("message", "")
                skipped += 1
            else:
                status = "PASS"
                message = ""
                passed += 1

            total += 1

            # Build a readable display name from the parametrize ID
            # raw_name: "test_sql_case[test_usp_delta_folders__TC01_-_Empty_...]"
            inner = re.sub(r"^test_sql_case\[(.+)\]$", r"\1", raw_name)
            parts = inner.split("__", 1)
            if len(parts) == 2:
                group = parts[0].replace("test_", "").replace("_", " ").upper()
                # "TC01_-_Empty_staging..." → "TC01 - Empty staging..."
                test_label = re.sub(r"(?<=[A-Z0-9])_-_", " - ", parts[1])
                test_label = test_label.replace("_", " ")
            else:
                group = ""
                test_label = inner.replace("_", " ")

            tests.append({
                "raw_name": raw_name,
                "group": group,
                "display_name": test_label,
                "status": status,
                "time": round(time_sec, 3),
                "message": message[:MAX_ERROR_MSG_LEN] if message else "",
            })

    summary = {
        "total": total,
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "duration": round(total_time, 2),
    }
    return summary, tests


def _run_tests_thread() -> None:
    """Background thread: bootstrap DB, run pytest, parse results, update _state."""
    global _state
    os.makedirs(REPORTS_DIR, exist_ok=True)
    xml_path = os.path.join(REPORTS_DIR, "test-results.xml")
    html_path = os.path.join(REPORTS_DIR, "test-report.html")

    try:
        # ── Step 1: bootstrap the database ──────────────────────────────────
        setup_proc = subprocess.run(
            [sys.executable, os.path.join(APP_DIR, "tests", "setup_db.py")],
            capture_output=True,
            text=True,
            cwd=APP_DIR,
        )
        setup_out = setup_proc.stdout + setup_proc.stderr

        if setup_proc.returncode != 0:
            with _lock:
                _state.update({
                    "status": "error",
                    "finished_at": datetime.now(timezone.utc).isoformat(),
                    "error": f"Database setup failed:\n{setup_out}",
                    "output": setup_out,
                })
            return

        # ── Step 2: run pytest ───────────────────────────────────────────────
        pytest_proc = subprocess.run(
            [
                sys.executable, "-m", "pytest",
                "tests/",
                "-v",
                f"--junitxml={xml_path}",
                f"--html={html_path}",
                "--self-contained-html",
                "--tb=short",
            ],
            capture_output=True,
            text=True,
            cwd=APP_DIR,
        )
        output = setup_out + "\n" + pytest_proc.stdout + pytest_proc.stderr

        # ── Step 3: parse results ────────────────────────────────────────────
        if os.path.exists(xml_path):
            summary, tests = _parse_junit_xml(xml_path)
        else:
            summary = {"total": 0, "passed": 0, "failed": 0, "skipped": 0, "duration": 0}
            tests = []

        with _lock:
            _state.update({
                "status": "done",
                "finished_at": datetime.now(timezone.utc).isoformat(),
                "summary": summary,
                "tests": tests,
                "output": output,
                "error": None,
            })

    except Exception as exc:
        with _lock:
            _state.update({
                "status": "error",
                "finished_at": datetime.now(timezone.utc).isoformat(),
                "error": str(exc),
                "output": "",
            })


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.route("/")
def index():
    return render_template("index.html")


@app.route("/run", methods=["POST"])
def run_tests():
    with _lock:
        if _state["status"] == "running":
            return jsonify({"error": "Tests are already running"}), 409
        _state.update({
            "status": "running",
            "started_at": datetime.now(timezone.utc).isoformat(),
            "finished_at": None,
            "summary": None,
            "tests": [],
            "output": "",
            "error": None,
        })

    # Non-daemon thread: the test run finishes cleanly even if a shutdown
    # signal arrives while tests are executing.
    thread = threading.Thread(target=_run_tests_thread, daemon=False)
    thread.start()
    return jsonify({"status": "running"}), 202


@app.route("/status")
def get_status():
    with _lock:
        return jsonify(dict(_state))


@app.route("/download/<fmt>")
def download_report(fmt: str):
    if fmt == "html":
        path = os.path.join(REPORTS_DIR, "test-report.html")
        filename = "test-report.html"
        mimetype = "text/html"
    elif fmt == "xml":
        path = os.path.join(REPORTS_DIR, "test-results.xml")
        filename = "test-results.xml"
        mimetype = "application/xml"
    else:
        abort(404)

    if not os.path.exists(path):
        abort(404, description="Report not yet generated. Run the tests first.")

    return send_file(path, as_attachment=True, download_name=filename, mimetype=mimetype)


# ---------------------------------------------------------------------------
# Entry point
# NOTE: Flask's built-in development server is intentionally used here.
#       This application is designed for local development only and is NOT
#       intended for production deployment.
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)

