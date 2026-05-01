#!/usr/bin/env python3
"""Summarize an Xcode .xcresult bundle into a human-readable Markdown report.

Called from run-tests.sh after xcodebuild completes. Writes a stable path that
is identical regardless of where the suite runs (host, Parallels VM, CI), so
the result is always available to read at:

    macos/ui-tests-xcode/build/test-results.md

Usage:
    summarize-results.py <path-to-.xcresult> <output-path.md>

The script never fails xcodebuild — it exits 0 on every parsing error and
prints diagnostics to stderr instead. Empty / missing fields render as "?".
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime, timezone


def run_xcresulttool(xcresult_path: str, kind: str) -> dict | None:
    """Run `xcrun xcresulttool get test-results <kind>` and return parsed JSON.

    `kind` is "summary" or "tests". Returns None if the tool fails — caller
    should treat that section as empty rather than abort.
    """
    cmd = ["xcrun", "xcresulttool", "get", "test-results", kind, "--path", xcresult_path]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        print(f"warning: xcresulttool {kind} failed (rc={result.returncode}):",
              file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        print(f"warning: could not parse xcresulttool {kind} output: {exc}",
              file=sys.stderr)
        return None


def format_duration(seconds: float) -> str:
    seconds = int(seconds)
    if seconds <= 0:
        return "?"
    minutes, secs = divmod(seconds, 60)
    if minutes:
        return f"{minutes}m {secs}s"
    return f"{secs}s"


def walk_test_cases(node, out: list[dict]) -> None:
    """Depth-first walk of the xcresulttool tests tree, collecting leaf cases."""
    if isinstance(node, dict):
        if node.get("nodeType") == "Test Case":
            out.append({
                "name": node.get("name", "(unknown)"),
                "result": node.get("result", "Unknown"),
                "duration": node.get("duration", ""),
            })
        for child in node.get("children", []) or []:
            walk_test_cases(child, out)
        for child in node.get("testNodes", []) or []:
            walk_test_cases(child, out)
    elif isinstance(node, list):
        for item in node:
            walk_test_cases(item, out)


def render(summary: dict, tests: dict | None) -> str:
    passed = int(summary.get("passedTests", 0))
    failed = int(summary.get("failedTests", 0))
    skipped = int(summary.get("skippedTests", 0))
    total = int(summary.get("totalTestCount", passed + failed + skipped))
    result = summary.get("result", "Unknown")

    start = summary.get("startTime", 0) or 0
    finish = summary.get("finishTime", 0) or 0
    duration = format_duration(finish - start) if finish and start else "?"

    devices = summary.get("devicesAndConfigurations", []) or []
    device = (devices[0] or {}).get("device", {}) if devices else {}
    platform_str = (
        f"macOS {device.get('osVersion', '?')} "
        f"({device.get('architecture', '?')}) on "
        f"{device.get('modelName', '?')}"
    )

    status_icon = {"Passed": "✅", "Failed": "❌"}.get(result, "❓")
    parts = [f"{passed} passed", f"{failed} failed"]
    if skipped:
        parts.append(f"{skipped} skipped")
    parts.append(f"{total} total")
    summary_line = f"{status_icon} **{result.upper()}** — {', '.join(parts)}"

    lines: list[str] = []
    lines.append("# HexEditor UI Test Results")
    lines.append("")
    lines.append(f"**Generated:** {datetime.now(timezone.utc).isoformat(timespec='seconds')}")
    lines.append(f"**Result:** {summary_line}")
    lines.append(f"**Duration:** {duration}")
    lines.append(f"**Platform:** {platform_str}")
    lines.append("")

    failures = summary.get("testFailures", []) or []
    if failures:
        lines.append("---")
        lines.append("")
        lines.append(f"## Failures ({len(failures)})")
        lines.append("")
        for fail in failures:
            name = fail.get("testName", "(unknown)")
            text = fail.get("failureText", "(no message)").strip()
            lines.append(f"### `{name}`")
            lines.append("")
            lines.append("```text")
            lines.append(text)
            lines.append("```")
            lines.append("")

    rows: list[dict] = []
    if tests is not None:
        walk_test_cases(tests, rows)

    if rows:
        rows.sort(key=lambda r: r["name"].lower())
        lines.append("---")
        lines.append("")
        lines.append(f"## All tests ({len(rows)})")
        lines.append("")
        for row in rows:
            mark = {"Passed": "✅", "Failed": "❌", "Skipped": "⊘"}.get(row["result"], "❓")
            dur = f" — {row['duration']}" if row.get("duration") else ""
            lines.append(f"- {mark} `{row['name']}`{dur}")
        lines.append("")

    return "\n".join(lines)


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2

    xcresult_path = sys.argv[1]
    output_path = sys.argv[2]

    if not os.path.exists(xcresult_path):
        print(f"error: xcresult bundle not found at {xcresult_path}", file=sys.stderr)
        return 1

    summary = run_xcresulttool(xcresult_path, "summary") or {}
    tests = run_xcresulttool(xcresult_path, "tests")

    if not summary:
        print("error: empty summary; xcresulttool may have changed format",
              file=sys.stderr)
        return 1

    markdown = render(summary, tests)

    os.makedirs(os.path.dirname(os.path.abspath(output_path)) or ".", exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as fp:
        fp.write(markdown)

    return 0


if __name__ == "__main__":
    sys.exit(main())
