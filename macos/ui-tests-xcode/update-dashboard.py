#!/usr/bin/env python3
"""Update the persistent UI test dashboard after a run.

Reads:
    --xcresult       The .xcresult bundle just produced by xcodebuild
    --tests-source   HexEditorUITests.swift (canonical list of tests in source)
    --history        run-history.json (created if missing)

Writes:
    --md             dashboard.md   (Markdown view)
    --html           dashboard.html (HTML view)
    --history        run-history.json (updated)

Dashboard content:
    Section 1: every `func test*` in the Swift source, with last status,
               last duration, total runs, pass rate, last-failure timestamp.
    Section 2: last 20 runs, newest first, with date, duration, pass/fail.

Best-effort: any parsing error logs to stderr and exits 0 (the test suite's
exit status is the source of truth, not this script).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

HISTORY_LIMIT = 20


# ---- xcresult parsing (mirrors summarize-results.py) -----------------------

def run_xcresulttool(xcresult_path: str, kind: str) -> dict | None:
    cmd = ["xcrun", "xcresulttool", "get", "test-results", kind, "--path", xcresult_path]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        print(f"warning: xcresulttool {kind} failed (rc={result.returncode}):", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        print(f"warning: could not parse xcresulttool {kind} output: {exc}", file=sys.stderr)
        return None


def walk_test_cases(node, out: list[dict]) -> None:
    if isinstance(node, dict):
        if node.get("nodeType") == "Test Case":
            # xcresulttool reports test case names as "testFoo()", but the
            # canonical Swift source list parser produces "testFoo" (no parens).
            # Normalize here so both views key the same dict.
            raw = node.get("name", "(unknown)")
            normalized = raw[:-2] if raw.endswith("()") else raw
            out.append({
                "name": normalized,
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


def parse_duration_seconds(value) -> float | None:
    """xcresulttool returns durations as either floats (seconds), bare-number
    strings, or human-formatted strings like "13s", "1m 26s", "1h 5m 12s".
    Sum every <number><unit> pair so we handle all three shapes uniformly —
    a naive leading-number regex turns "4m 22s" into 4.0, which is the
    bug this function is replacing.
    """
    if value is None or value == "":
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value).strip()
    try:
        return float(text)
    except ValueError:
        pass
    total = 0.0
    found = False
    for num, unit in re.findall(r"([\d.]+)\s*([hms])", text):
        try:
            n = float(num)
        except ValueError:
            continue
        total += n * {"h": 3600.0, "m": 60.0, "s": 1.0}[unit]
        found = True
    return total if found else None


# ---- Source parsing --------------------------------------------------------

def list_tests_in_source(source_path: str) -> list[str]:
    """Find every `func testFoo(...)` in the Swift source, in declaration order."""
    out: list[str] = []
    pattern = re.compile(r"^\s+func\s+(test[A-Za-z0-9_]+)\s*\(")
    try:
        with open(source_path, encoding="utf-8") as fp:
            for line in fp:
                m = pattern.match(line)
                if m:
                    out.append(m.group(1))
    except OSError as exc:
        print(f"warning: could not read tests source {source_path}: {exc}", file=sys.stderr)
    return out


# ---- History I/O -----------------------------------------------------------

def load_history(history_path: str) -> list[dict]:
    if not os.path.exists(history_path):
        return []
    try:
        with open(history_path, encoding="utf-8") as fp:
            data = json.load(fp)
        if isinstance(data, list):
            return data
    except (OSError, json.JSONDecodeError) as exc:
        print(f"warning: could not load history {history_path}: {exc}", file=sys.stderr)
    return []


def save_history(history_path: str, history: list[dict]) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(history_path)) or ".", exist_ok=True)
    with open(history_path, "w", encoding="utf-8") as fp:
        json.dump(history, fp, indent=2, sort_keys=True)


# ---- Dashboard renderers ---------------------------------------------------

def per_test_aggregate(history: list[dict], all_tests: list[str]) -> list[dict]:
    """For each known test, compute last status / duration / total runs / passes."""
    rows = []
    for name in all_tests:
        last_status = "—"
        last_duration: float | None = None
        last_run: str | None = None
        last_failure: str | None = None
        runs = 0
        passes = 0
        for entry in reversed(history):
            tests = entry.get("tests", {})
            if name not in tests:
                continue
            info = tests[name]
            status = info.get("result", "Unknown")
            runs += 1
            if status == "Passed":
                passes += 1
            if last_status == "—":
                last_status = status
                last_duration = parse_duration_seconds(info.get("duration"))
                last_run = entry.get("timestamp")
            if status == "Failed" and last_failure is None:
                last_failure = entry.get("timestamp")
        rows.append({
            "name": name,
            "last_status": last_status,
            "last_duration": last_duration,
            "last_run": last_run,
            "last_failure": last_failure,
            "runs": runs,
            "passes": passes,
        })
    return rows


def status_emoji(status: str) -> str:
    return {"Passed": "✅", "Failed": "❌", "Skipped": "⊘", "—": "—"}.get(status, "❓")


def status_class(status: str) -> str:
    return {"Passed": "pass", "Failed": "fail", "Skipped": "skip", "—": "never"}.get(status, "unknown")


def fmt_duration(seconds: float | None) -> str:
    if seconds is None:
        return "—"
    if seconds < 1:
        return f"{seconds:.2f}s"
    if seconds < 60:
        return f"{seconds:.1f}s"
    minutes, secs = divmod(int(seconds), 60)
    return f"{minutes}m {secs}s"


def fmt_timestamp(iso: str | None) -> str:
    if not iso:
        return "—"
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except ValueError:
        return iso
    # Render in local time so a human reading the dashboard sees their wall clock.
    local = dt.astimezone()
    return local.strftime("%Y-%m-%d %H:%M")


def _entry_kind(entry: dict, max_total_in_history: int) -> str:
    """
    Return "full" / "partial" / "unknown" for a history entry.

    Backwards compat: pre-2026-05-02 entries don't carry a `kind` field.
    Derive from total: full-suite runs are always at least half the size of
    the largest run we've ever seen. Below that, mark "unknown" — old short
    runs were a mix of partial and full, and we can't tell apart, so we
    refuse to attribute commit-readiness to them.
    """
    explicit = entry.get("kind")
    if explicit in ("full", "partial"):
        return explicit
    total = int(entry.get("total", 0))
    if max_total_in_history > 0 and total >= max_total_in_history * 0.5:
        return "full"
    return "unknown"


def _latest_full_entry(history: list[dict]) -> dict | None:
    """Most recent history entry tagged kind=full (or derived as full for old entries)."""
    if not history:
        return None
    max_total = max((int(h.get("total", 0)) for h in history), default=0)
    for entry in reversed(history):
        if _entry_kind(entry, max_total) == "full":
            return entry
    return None


def _format_run_summary(entry: dict) -> str:
    """One-line `<icon> N passed · M failed · ...` summary used for headlines."""
    passed = entry.get("passed", 0)
    failed = entry.get("failed", 0)
    skipped = entry.get("skipped", 0)
    total = entry.get("total", passed + failed + skipped)
    icon = "✅" if failed == 0 and passed > 0 else ("❌" if failed > 0 else "❓")
    return (f"{icon} {passed} passed · {failed} failed · {skipped} skipped · "
            f"{total} total — {fmt_duration(entry.get('duration_seconds'))} "
            f"at {fmt_timestamp(entry.get('timestamp'))}")


def render_markdown(per_test: list[dict], history: list[dict], screenshots: list[dict]) -> str:
    lines: list[str] = []
    lines.append("# HexEditor UI Test Dashboard")
    lines.append("")
    lines.append(f"_Updated: {datetime.now().astimezone().strftime('%Y-%m-%d %H:%M %Z')}_")
    lines.append("")

    if history:
        latest = history[-1]
        max_total = max((int(h.get("total", 0)) for h in history), default=0)
        latest_kind = _entry_kind(latest, max_total)
        latest_full = _latest_full_entry(history)

        # Headline anchors to the latest *full* run — that's the canonical
        # commit-readiness signal. A debug `test-ui.sh testFoo` run that
        # happens to pass after a failing full-suite run must NOT become the
        # green headline that hides the earlier failure.
        if latest_full is not None:
            lines.append(f"**Latest full-suite run:** {_format_run_summary(latest_full)}")
        else:
            lines.append("**Latest full-suite run:** _no full-suite run on record yet._")
        lines.append("")

        # If the most recent entry is a partial / debug run distinct from
        # the latest full run, surface it on its own line so it's visible
        # without claiming commit-readiness.
        if latest_kind != "full" and latest is not latest_full:
            label = "Latest partial run" if latest_kind == "partial" else "Latest run (kind unknown)"
            lines.append(f"**{label}:** {_format_run_summary(latest)}")
            lines.append("")

    lines.append(f"## All tests ({len(per_test)})")
    lines.append("")
    lines.append("| Test | Last | Duration | Last run | Runs | Pass rate |")
    lines.append("|------|------|----------|----------|-----:|----------:|")
    for row in per_test:
        rate = ""
        if row["runs"] > 0:
            pct = (row["passes"] / row["runs"]) * 100
            rate = f"{pct:.0f}% ({row['passes']}/{row['runs']})"
        else:
            rate = "—"
        lines.append(
            f"| `{row['name']}` "
            f"| {status_emoji(row['last_status'])} {row['last_status']} "
            f"| {fmt_duration(row['last_duration'])} "
            f"| {fmt_timestamp(row['last_run'])} "
            f"| {row['runs']} "
            f"| {rate} |"
        )
    lines.append("")

    if screenshots:
        lines.append(f"## Screenshots from latest run ({len(screenshots)})")
        lines.append("")
        for shot in screenshots:
            lines.append(f"- [`{shot['name']}`](screenshots/{shot['filename']})")
        lines.append("")

    lines.append(f"## Run history (last {len(history)})")
    lines.append("")
    if not history:
        lines.append("_No runs yet._")
        lines.append("")
    else:
        max_total = max((int(h.get("total", 0)) for h in history), default=0)
        lines.append("| When | Kind | Duration | Result | Failures |")
        lines.append("|------|------|---------:|--------|----------|")
        for entry in reversed(history):
            failed = entry.get("failed", 0)
            passed = entry.get("passed", 0)
            total = entry.get("total", passed + failed)
            res = "✅ all pass" if failed == 0 else f"❌ {failed} of {total} failed"
            fail_names = entry.get("failed_tests", [])
            fails_md = ", ".join(f"`{n}`" for n in fail_names) if fail_names else "—"
            kind = _entry_kind(entry, max_total)
            kind_label = {"full": "full", "partial": "subset", "unknown": "—"}[kind]
            lines.append(
                f"| {fmt_timestamp(entry.get('timestamp'))} "
                f"| {kind_label} "
                f"| {fmt_duration(entry.get('duration_seconds'))} "
                f"| {res} "
                f"| {fails_md} |"
            )
        lines.append("")

    return "\n".join(lines)


def list_screenshots(screenshot_dir: str) -> list[dict]:
    """List PNGs in `screenshot_dir`, sorted by mtime descending.

    Returns dicts with `name` (filename without extension), `filename` (full
    filename), and `mtime` (seconds since epoch). The dashboard HTML embeds
    these via relative paths so the file works when opened locally without a
    web server.
    """
    if not screenshot_dir or not os.path.isdir(screenshot_dir):
        return []
    rows: list[dict] = []
    for entry in os.scandir(screenshot_dir):
        if not entry.is_file() or not entry.name.lower().endswith(".png"):
            continue
        rows.append({
            "name": os.path.splitext(entry.name)[0],
            "filename": entry.name,
            "mtime": entry.stat().st_mtime,
        })
    rows.sort(key=lambda r: r["mtime"], reverse=True)
    return rows


def render_html(per_test: list[dict], history: list[dict], screenshots: list[dict]) -> str:
    head = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>HexEditor UI Test Dashboard</title>
<style>
body { font: 14px -apple-system, BlinkMacSystemFont, sans-serif; max-width: 1100px; margin: 24px auto; padding: 0 20px; color: #222; }
h1, h2 { font-weight: 600; }
h1 { margin-bottom: 0; }
.subtle { color: #777; }
table { border-collapse: collapse; width: 100%; margin: 12px 0 28px; }
th, td { padding: 6px 10px; text-align: left; border-bottom: 1px solid #eee; vertical-align: top; }
th { background: #f7f7f7; font-weight: 600; }
tr:hover td { background: #fafafa; }
code { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; background: #f3f3f3; padding: 1px 5px; border-radius: 3px; }
.pass  { color: #2e7d32; }
.fail  { color: #c62828; font-weight: 600; }
.skip  { color: #7b6500; }
.never { color: #999; }
.mono  { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; }
.right { text-align: right; }
.banner { padding: 10px 14px; border-radius: 6px; margin: 12px 0 24px; }
.banner.pass { background: #e6f4ea; border: 1px solid #c8e6c9; }
.banner.fail { background: #fdecea; border: 1px solid #f5c6c6; }
.banner.empty { background: #f3f3f3; border: 1px solid #e0e0e0; color: #666; }
</style>
</head>
<body>
"""
    out: list[str] = [head]
    out.append("<h1>HexEditor UI Test Dashboard</h1>")
    out.append(f'<p class="subtle">Updated {datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z")}</p>')

    if history:
        latest = history[-1]
        max_total = max((int(h.get("total", 0)) for h in history), default=0)
        latest_kind = _entry_kind(latest, max_total)
        latest_full = _latest_full_entry(history)

        # Same logic as the markdown headline: anchor commit-readiness to
        # the latest *full* run, not the latest run of any size, so a debug
        # subset run can't paint over a real failure.
        def _banner_class(entry: dict | None) -> str:
            if entry is None:
                return "empty"
            f = entry.get("failed", 0)
            p = entry.get("passed", 0)
            return "pass" if f == 0 and p > 0 else ("fail" if f > 0 else "empty")

        if latest_full is not None:
            out.append(f'<div class="banner {_banner_class(latest_full)}">')
            f = latest_full.get("failed", 0)
            p = latest_full.get("passed", 0)
            s = latest_full.get("skipped", 0)
            tot = latest_full.get("total", p + f + s)
            icon = "✅" if f == 0 and p > 0 else ("❌" if f > 0 else "❓")
            out.append(
                f"<b>Latest full-suite run:</b> {icon} {p} passed · {f} failed · "
                f"{s} skipped · {tot} total — {fmt_duration(latest_full.get('duration_seconds'))} "
                f"at {fmt_timestamp(latest_full.get('timestamp'))}"
            )
            out.append("</div>")
        else:
            out.append('<div class="banner empty"><b>Latest full-suite run:</b> none on record yet.</div>')

        # Surface a partial / debug run separately so it's visible without
        # being mistaken for the canonical status.
        if latest_kind != "full" and latest is not latest_full:
            label = "Latest partial run" if latest_kind == "partial" else "Latest run (kind unknown)"
            f = latest.get("failed", 0)
            p = latest.get("passed", 0)
            s = latest.get("skipped", 0)
            tot = latest.get("total", p + f + s)
            icon = "✅" if f == 0 and p > 0 else ("❌" if f > 0 else "❓")
            out.append(f'<div class="banner {_banner_class(latest)}">')
            out.append(
                f"<b>{label}:</b> {icon} {p} passed · {f} failed · "
                f"{s} skipped · {tot} total — {fmt_duration(latest.get('duration_seconds'))} "
                f"at {fmt_timestamp(latest.get('timestamp'))}"
            )
            out.append("</div>")
    else:
        out.append('<div class="banner empty"><b>No runs recorded yet.</b></div>')

    out.append(f"<h2>All tests ({len(per_test)})</h2>")
    out.append("<table>")
    out.append("<tr><th>Test</th><th>Last</th><th>Duration</th><th>Last run</th>"
               "<th class='right'>Runs</th><th class='right'>Pass rate</th></tr>")
    for row in per_test:
        rate_str = "—"
        if row["runs"] > 0:
            pct = (row["passes"] / row["runs"]) * 100
            rate_str = f"{pct:.0f}% ({row['passes']}/{row['runs']})"
        out.append(
            "<tr>"
            f"<td><code>{row['name']}</code></td>"
            f"<td class='{status_class(row['last_status'])}'>{status_emoji(row['last_status'])} {row['last_status']}</td>"
            f"<td>{fmt_duration(row['last_duration'])}</td>"
            f"<td class='mono'>{fmt_timestamp(row['last_run'])}</td>"
            f"<td class='right'>{row['runs']}</td>"
            f"<td class='right'>{rate_str}</td>"
            "</tr>"
        )
    out.append("</table>")

    if screenshots:
        out.append(f"<h2>Screenshots from latest run ({len(screenshots)})</h2>")
        out.append('<p class="subtle">Visual evidence captured by tests via captureToDashboard(name). Embedded with relative paths so the file works offline.</p>')
        out.append('<div style="display:grid; grid-template-columns:repeat(auto-fit, minmax(360px, 1fr)); gap:16px; margin-bottom:28px;">')
        for shot in screenshots:
            # Two-line caption: filename (which encodes test + assertion stage),
            # then the mtime so the human can confirm freshness.
            mtime_str = datetime.fromtimestamp(shot["mtime"]).astimezone().strftime("%Y-%m-%d %H:%M:%S")
            out.append('<figure style="margin:0; border:1px solid #ddd; border-radius:6px; padding:8px; background:#fafafa;">')
            out.append(f'<img src="screenshots/{shot["filename"]}" style="max-width:100%; height:auto; display:block; border-radius:4px;" alt="{shot["name"]}">')
            out.append(f'<figcaption style="font-size:12px; color:#555; margin-top:6px; word-break:break-all;"><code>{shot["name"]}</code><br><span class="subtle">{mtime_str}</span></figcaption>')
            out.append('</figure>')
        out.append('</div>')

    out.append(f"<h2>Run history (last {len(history)})</h2>")
    if not history:
        out.append("<p class='subtle'>No runs yet.</p>")
    else:
        max_total = max((int(h.get("total", 0)) for h in history), default=0)
        out.append("<table>")
        out.append("<tr><th>When</th><th>Kind</th><th>Duration</th><th>Result</th><th>Failures</th></tr>")
        for entry in reversed(history):
            failed = entry.get("failed", 0)
            passed = entry.get("passed", 0)
            total = entry.get("total", passed + failed)
            if failed == 0:
                res_html = "<span class='pass'>✅ all pass</span>"
            else:
                res_html = f"<span class='fail'>❌ {failed} of {total} failed</span>"
            fail_names = entry.get("failed_tests", []) or []
            fails_html = ", ".join(f"<code>{n}</code>" for n in fail_names) or "—"
            kind = _entry_kind(entry, max_total)
            kind_label = {"full": "full", "partial": "subset", "unknown": "—"}[kind]
            out.append(
                "<tr>"
                f"<td class='mono'>{fmt_timestamp(entry.get('timestamp'))}</td>"
                f"<td>{kind_label}</td>"
                f"<td>{fmt_duration(entry.get('duration_seconds'))}</td>"
                f"<td>{res_html}</td>"
                f"<td>{fails_html}</td>"
                "</tr>"
            )
        out.append("</table>")
    out.append("</body></html>")
    return "\n".join(out)


# ---- Main ------------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--xcresult", required=True)
    p.add_argument("--tests-source", required=True)
    p.add_argument("--history", required=True)
    p.add_argument("--md", required=True)
    p.add_argument("--html", required=True)
    p.add_argument("--screenshots-dir", default=None,
                   help="Optional directory containing PNGs written by captureToDashboard(). When set, screenshots are embedded in dashboard.html and listed in dashboard.md.")
    p.add_argument("--kind", choices=["full", "partial"], default="full",
                   help="Whether this run executed the full UI suite or a -only-testing: subset. The dashboard's headline status reflects the latest *full* run, so a debug subset run can't mask an earlier full-suite failure.")
    args = p.parse_args()

    history = load_history(args.history)

    # Parse the run we just completed and append to history.
    if os.path.exists(args.xcresult):
        summary = run_xcresulttool(args.xcresult, "summary") or {}
        tests = run_xcresulttool(args.xcresult, "tests") or {}
        cases: list[dict] = []
        walk_test_cases(tests, cases)
        passed = int(summary.get("passedTests", 0))
        failed = int(summary.get("failedTests", 0))
        skipped = int(summary.get("skippedTests", 0))
        total = int(summary.get("totalTestCount", passed + failed + skipped))
        start = summary.get("startTime") or 0
        finish = summary.get("finishTime") or 0
        duration = (finish - start) if (finish and start) else None
        # xcresulttool startTime is unix epoch seconds (number).
        if isinstance(start, (int, float)) and start > 0:
            ts = datetime.fromtimestamp(start, tz=timezone.utc).isoformat()
        else:
            ts = datetime.now(tz=timezone.utc).isoformat()

        per_test_map: dict[str, dict] = {}
        for case in cases:
            per_test_map[case["name"]] = {
                "result": case["result"],
                "duration": case.get("duration"),
            }
        failed_names = [c["name"] for c in cases if c.get("result") == "Failed"]

        new_entry = {
            "timestamp": ts,
            "passed": passed,
            "failed": failed,
            "skipped": skipped,
            "total": total,
            "duration_seconds": duration,
            "tests": per_test_map,
            "failed_tests": failed_names,
            "kind": args.kind,
        }
        # Idempotence: if the most recent entry has the same start timestamp
        # AND identical pass/fail/total counts, this is a re-render of the
        # same xcresult bundle (e.g. running update-dashboard.py twice during
        # development). Don't double-record — replace the previous entry so
        # any new fields (like the new `kind` tag on a re-run) land cleanly.
        if history and history[-1].get("timestamp") == ts and \
           history[-1].get("total") == total and \
           history[-1].get("passed") == passed and \
           history[-1].get("failed") == failed:
            history[-1] = new_entry
        else:
            history.append(new_entry)
        history = history[-HISTORY_LIMIT:]
        save_history(args.history, history)
    else:
        print(f"warning: xcresult not found at {args.xcresult}; dashboard rendered from history alone", file=sys.stderr)

    # Build the per-test aggregate from full history + canonical source list.
    all_tests = list_tests_in_source(args.tests_source)
    per_test = per_test_aggregate(history, all_tests)

    # Tests that exist in history but are no longer in source go to a tail
    # section so we can spot stale entries (e.g. renamed tests) without
    # losing their history. Filter to real Swift test-method shapes so
    # xcresult runner-error pseudo-names like "HexEditorUITests-Runner
    # (1744) encountered an error" don't get promoted as test rows.
    seen_in_source = set(all_tests)
    test_name_shape = re.compile(r"^test[A-Za-z0-9_]+$")
    extra_names: list[str] = []
    for entry in history:
        for name in (entry.get("tests") or {}).keys():
            if (name not in seen_in_source
                    and name not in extra_names
                    and test_name_shape.match(name)):
                extra_names.append(name)
    per_test += per_test_aggregate(history, extra_names)

    screenshots = list_screenshots(args.screenshots_dir) if args.screenshots_dir else []

    md = render_markdown(per_test, history, screenshots)
    Path(args.md).parent.mkdir(parents=True, exist_ok=True)
    Path(args.md).write_text(md, encoding="utf-8")

    html = render_html(per_test, history, screenshots)
    Path(args.html).parent.mkdir(parents=True, exist_ok=True)
    Path(args.html).write_text(html, encoding="utf-8")

    return 0


if __name__ == "__main__":
    sys.exit(main())
