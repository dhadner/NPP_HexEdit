#!/usr/bin/env python3
"""Update the committed 5-tier test-status dashboard.

Read per-tier results captured by `pre-commit-tests.sh` plus the UI tier's
per-test history from `macos/ui-tests-xcode/build/run-history.json`, then
re-render `docs/test-status.md` and `docs/test-status/state.json`.

This dashboard is generated on the developer machine (the test suite locks
the keyboard for ~22 minutes via the VM-routed UI tier and is unsuitable
for CI), then committed to the repo so GitHub renders the latest state
without needing live CI runs.

Inputs (via CLI):
    --tier-results PATH   JSON file with the just-completed run's tier results.
                          Shape: see the writer in pre-commit-tests.sh.
    --ui-history PATH     run-history.json from the UI tier (optional;
                          only present after a UI run).
    --repo-root PATH      Repo root. Defaults to inferring from this script.

Outputs:
    docs/test-status.md
    docs/test-status/state.json
    docs/test-status/screenshots/  (curated subset, copied if available)

Schema for --tier-results JSON:
    {
        "started_at":  "2026-05-06T20:25:00Z",
        "finished_at": "2026-05-06T20:51:00Z",
        "commit_sha":  "abc123...",
        "kind":        "full" | "skip-fuzz" | "skip-ui" | "skip-fuzz+ui",
        "tiers": {
            "unit":      { "status": "pass"|"fail"|"skipped", "duration_sec": 0.01, "log_tail": "..." },
            "unit_asan": { ... },
            "smoke":     { ... },
            "fuzz":      { "status": "...", "duration_sec": 240.0,
                           "harnesses": [ {"name": "...", "execs": N, "peak_rss_mb": N}, ... ] },
            "ui":        { "status": "...", "duration_sec": 1320.0,
                           "passed": N, "failed": N, "skipped": N, "total": N }
        }
    }

A `kind` of "skip-fuzz" / "skip-ui" results in `status: "skipped"` for the
named tiers; the dashboard renders those rows with a dash and notes the
last passing run separately so a partial run never overwrites a cleaner
prior state.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1

# Curated screenshot whitelist — keep this short. The full UI run produces
# ~25 diagnostic PNGs (~50 MB at native retina resolution) which is too
# much to commit. Pick the ones that are most representative across
# feature surfaces. Images are resized + recompressed to JPEG so the
# committed total stays under ~1 MB.
SCREENSHOT_WHITELIST = [
    ("diag-row0-initialOpen.png",                            "hex-view-default.jpg",        "Hex view (default state)"),
    ("setNppAppearanceMode-Dark-afterClick.png",             "dark-appearance.jpg",         "Dark appearance"),
    ("test-wideContent-horizontalScroll.png",                "wide-content-scroll.jpg",     "Wide-content horizontal scroll"),
    ("testOptionsHelpPopover-01-dialog-without-popover.png", "options-dialog.jpg",          "Options dialog"),
]
# Target longest-edge in pixels and JPEG quality. 1024 / quality 65 keeps
# UI screenshots readable while landing each image under ~250 KB.
SCREENSHOT_MAX_PX = 1024
SCREENSHOT_JPEG_QUALITY = 65

TIER_ORDER = [
    ("unit",      "1. Unit"),
    ("unit_asan", "2. Unit + ASan/UBSan"),
    ("smoke",     "3. Plugin smoke"),
    ("fuzz",      "4. Fuzz / robustness"),
    ("ui",        "5. XCTest UI (VM)"),
]

STATUS_ICON = {
    "pass":    "✅",
    "fail":    "❌",
    "skipped": "⊘",
    "unknown": "❓",
}


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tier-results", required=True,
                    help="Path to the JSON written by pre-commit-tests.sh")
    ap.add_argument("--ui-history", default=None,
                    help="Optional UI run-history.json for per-test detail")
    ap.add_argument("--repo-root", default=None,
                    help="Repo root (default: two levels above this script)")
    return ap.parse_args()


def repo_root_from_script() -> Path:
    return Path(__file__).resolve().parents[2]


def load_json(path: str | Path) -> Any:
    with open(path, encoding="utf-8") as fp:
        return json.load(fp)


def save_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fp:
        json.dump(data, fp, indent=2, sort_keys=True)
        fp.write("\n")


def load_existing_state(state_path: Path) -> dict:
    """Existing state lets us preserve last-passed timestamps for skipped tiers."""
    if not state_path.exists():
        return {}
    try:
        return load_json(state_path)
    except (OSError, json.JSONDecodeError):
        return {}


def merge_tier_into_state(state: dict, tier_key: str, this_run: dict, run_started_at: str) -> dict:
    """Update the merged-state record for one tier from the latest run.

    Skipped tiers keep their previous last-pass timestamp; non-skipped tiers
    overwrite. The on-disk state therefore always shows the most recent pass
    for each tier even after partial runs.
    """
    prior = state.get("tiers", {}).get(tier_key, {})
    merged = dict(prior)
    status = this_run.get("status", "unknown")
    duration = this_run.get("duration_sec")
    merged["status"] = status
    if duration is not None:
        merged["duration_sec"] = duration
    merged["ran_at"] = run_started_at
    if status == "pass":
        merged["last_passed_at"] = run_started_at
    # Carry tier-specific extras forward (fuzz harnesses, UI counts).
    for key in ("harnesses", "passed", "failed", "skipped", "total"):
        if key in this_run:
            merged[key] = this_run[key]
    return merged


def fmt_duration(seconds: float | None) -> str:
    if seconds is None:
        return "—"
    if seconds < 1:
        return f"{seconds:.2f}s"
    if seconds < 60:
        return f"{seconds:.1f}s"
    minutes, secs = divmod(int(round(seconds)), 60)
    return f"{minutes}m {secs}s"


def fmt_timestamp(iso: str | None) -> str:
    if not iso:
        return "—"
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except ValueError:
        return iso
    return dt.astimezone().strftime("%Y-%m-%d %H:%M %Z")


def short_sha(sha: str | None) -> str:
    return (sha or "")[:8] or "—"


def tier_note(tier_key: str, tier_state: dict) -> str:
    """One-line description of what the tier does + most useful detail."""
    if tier_key == "unit":
        return "HexCore C++ assertions"
    if tier_key == "unit_asan":
        return "Same suite, AddressSanitizer + UndefinedBehaviorSanitizer"
    if tier_key == "smoke":
        return "Plugin `dlopen` contract"
    if tier_key == "fuzz":
        harnesses = tier_state.get("harnesses") or []
        if harnesses:
            total_execs = sum(h.get("execs", 0) for h in harnesses)
            return f"{len(harnesses)} libFuzzer harnesses, {total_execs:,} iterations this run"
        return "8 libFuzzer harnesses × 30 s, ASan + UBSan"
    if tier_key == "ui":
        passed = tier_state.get("passed")
        total  = tier_state.get("total")
        if passed is not None and total is not None:
            return f"{passed} / {total} passing on Parallels VM"
        return "XCTest UI on Parallels VM"
    return ""


# ---- Rendering -------------------------------------------------------------

def render_markdown(state: dict, ui_history: list[dict] | None,
                    screenshots_present: list[tuple[str, str]]) -> str:
    lines: list[str] = []
    lines.append("# HexEditor test status")
    lines.append("")
    generated_at = state.get("generated_at")
    commit_sha   = state.get("commit_sha")
    lines.append(f"_Generated: {fmt_timestamp(generated_at)} · "
                 f"commit `{short_sha(commit_sha)}` · "
                 f"developer machine (no CI — UI tier needs the Parallels VM)._")
    lines.append("")

    last_kind = state.get("last_kind", "unknown")
    if last_kind != "full":
        lines.append(f"> **Note:** the most recent run was a `{last_kind}` run. "
                     f"Tiers it skipped show their last-passed timestamp, not a fresh result.")
        lines.append("")

    lines.append("## Tier status")
    lines.append("")
    lines.append("| Tier | Status | Duration | Last passed | Notes |")
    lines.append("|------|--------|---------:|-------------|-------|")
    tiers = state.get("tiers", {})
    for tier_key, tier_label in TIER_ORDER:
        t = tiers.get(tier_key, {})
        status = t.get("status", "unknown")
        icon = STATUS_ICON.get(status, "❓")
        # Shell timer is integer-second; sub-second tiers (unit, asan unit, smoke)
        # report as 0 even though they did run. Render those as "<1s" rather than
        # the misleading "0.00s". Skipped tiers render as a dash regardless.
        duration_raw = t.get("duration_sec")
        if status == "skipped":
            duration = "—"
        elif duration_raw == 0 and status == "pass":
            duration = "<1s"
        else:
            duration = fmt_duration(duration_raw)
        last_passed = fmt_timestamp(t.get("last_passed_at"))
        note = tier_note(tier_key, t)
        lines.append(f"| {tier_label} | {icon} {status} | {duration} | {last_passed} | {note} |")
    lines.append("")

    # Fuzz harness breakdown (only when we have data from a recent fuzz run).
    fuzz = tiers.get("fuzz") or {}
    harnesses = fuzz.get("harnesses") or []
    if harnesses:
        lines.append("## Fuzz harness detail")
        lines.append("")
        lines.append("| Harness | Iterations | Peak RSS | Status |")
        lines.append("|---------|-----------:|---------:|--------|")
        for h in harnesses:
            name   = h.get("name", "—")
            execs  = h.get("execs")
            rss_mb = h.get("peak_rss_mb")
            hstat  = h.get("status", "pass")
            execs_s = f"{execs:,}" if isinstance(execs, int) else "—"
            rss_s   = f"{rss_mb} MB" if isinstance(rss_mb, int) else "—"
            lines.append(f"| `{name}` | {execs_s} | {rss_s} | {STATUS_ICON.get(hstat, '❓')} {hstat} |")
        lines.append("")

    # UI tier per-test summary (only if history file is present).
    if ui_history:
        lines.append("## XCTest UI tier")
        lines.append("")
        latest = ui_history[-1] if ui_history else {}
        passed = latest.get("passed", 0)
        failed = latest.get("failed", 0)
        skipped = latest.get("skipped", 0)
        total = latest.get("total", passed + failed + skipped)
        lines.append(f"Latest run: **{passed}** passed · **{failed}** failed · "
                     f"**{skipped}** skipped · **{total}** total · "
                     f"{fmt_duration(latest.get('duration_seconds'))} at {fmt_timestamp(latest.get('timestamp'))}")
        lines.append("")
        # Include a short-tail of recent runs (last 5) for trend visibility.
        if len(ui_history) > 1:
            lines.append("**Recent UI runs**")
            lines.append("")
            lines.append("| Date | Total | Pass | Fail | Skip | Duration |")
            lines.append("|------|------:|-----:|-----:|-----:|---------:|")
            for entry in list(reversed(ui_history))[:5]:
                ts = fmt_timestamp(entry.get("timestamp"))
                t  = entry.get("total", 0)
                p  = entry.get("passed", 0)
                f  = entry.get("failed", 0)
                s  = entry.get("skipped", 0)
                d  = fmt_duration(entry.get("duration_seconds"))
                lines.append(f"| {ts} | {t} | {p} | {f} | {s} | {d} |")
            lines.append("")
        lines.append("For a full per-test breakdown including pass-rates and "
                     "last-failure timestamps, run `macos/scripts/test-ui.sh --dashboard` "
                     "locally (the per-test view is too large to commit).")
        lines.append("")

    if screenshots_present:
        lines.append("## Representative UI screenshots")
        lines.append("")
        lines.append("_A small curated subset. The full UI run produces ~25 diagnostic "
                     "screenshots; committing all of them would balloon the repo. Run "
                     "`macos/scripts/test-ui.sh --dashboard` locally for the full set._")
        lines.append("")
        for filename, caption in screenshots_present:
            lines.append(f"### {caption}")
            lines.append("")
            lines.append(f"![{caption}](test-status/screenshots/{filename})")
            lines.append("")

    lines.append("---")
    lines.append("")
    lines.append("This dashboard is regenerated by `macos/scripts/pre-commit-tests.sh` "
                 "after each full pre-commit run and committed to the repo. There is no CI "
                 "equivalent — the UI tier requires a Parallels VM that GitHub-hosted runners "
                 "can't provide.")
    lines.append("")
    return "\n".join(lines)


# ---- Screenshot curation ---------------------------------------------------

def shrink_screenshot(src: Path, dst: Path) -> bool:
    """Resize + recompress a PNG into a JPEG under SCREENSHOT_MAX_PX wide.

    Uses `sips` (built into macOS) so we don't add a third-party image
    dependency. Returns True on success. Falls back to a plain copy if
    sips isn't available (e.g. running on Linux for a doc preview).
    """
    if shutil.which("sips") is None:
        shutil.copy2(src, dst)
        return True
    try:
        subprocess.run(
            ["sips", "--setProperty", "format", "jpeg",
             "--setProperty", "formatOptions", str(SCREENSHOT_JPEG_QUALITY),
             "--resampleHeightWidthMax", str(SCREENSHOT_MAX_PX),
             str(src), "--out", str(dst)],
            check=True, capture_output=True,
        )
        return True
    except subprocess.CalledProcessError as exc:
        print(f"warning: sips failed on {src.name}: {exc.stderr.decode(errors='replace').strip()}",
              file=sys.stderr)
        return False


def curate_screenshots(repo_root: Path) -> list[tuple[str, str]]:
    """Resize + commit a curated subset of UI screenshots.

    For each entry in SCREENSHOT_WHITELIST: if the high-res source PNG is
    available under macos/ui-tests-xcode/build/screenshots/, shrink it to a
    repo-friendly JPEG under docs/test-status/screenshots/. If the source
    is missing but a previously curated JPEG exists, keep that — the
    dashboard stays populated with last-known-good imagery even when the
    developer has cleaned the UI build dir. Returns the list of
    (output_filename, caption) pairs that are actually present in the
    destination after this call so the Markdown references real files.
    """
    src_dir = repo_root / "macos" / "ui-tests-xcode" / "build" / "screenshots"
    dst_dir = repo_root / "docs" / "test-status" / "screenshots"
    dst_dir.mkdir(parents=True, exist_ok=True)

    present: list[tuple[str, str]] = []
    for src_name, dst_name, caption in SCREENSHOT_WHITELIST:
        src = src_dir / src_name
        dst = dst_dir / dst_name
        if src.exists():
            if shrink_screenshot(src, dst):
                present.append((dst_name, caption))
        elif dst.exists():
            present.append((dst_name, caption))
    return present


# ---- Main ------------------------------------------------------------------

def main() -> int:
    args = parse_args()
    repo_root = Path(args.repo_root) if args.repo_root else repo_root_from_script()

    state_path = repo_root / "docs" / "test-status" / "state.json"
    md_path    = repo_root / "docs" / "test-status.md"

    try:
        run_results = load_json(args.tier_results)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"error: could not read --tier-results {args.tier_results}: {exc}", file=sys.stderr)
        return 2

    state = load_existing_state(state_path)
    state.setdefault("schema_version", SCHEMA_VERSION)
    state["generated_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    state["commit_sha"]   = run_results.get("commit_sha", state.get("commit_sha"))
    state["last_kind"]    = run_results.get("kind", "unknown")

    run_started_at = run_results.get("started_at") or state["generated_at"]
    incoming_tiers = run_results.get("tiers", {}) or {}
    state.setdefault("tiers", {})
    for tier_key, _ in TIER_ORDER:
        this_run = incoming_tiers.get(tier_key, {"status": "skipped"})
        state["tiers"][tier_key] = merge_tier_into_state(state, tier_key, this_run, run_started_at)

    ui_history: list[dict] | None = None
    if args.ui_history and Path(args.ui_history).exists():
        try:
            ui_history = load_json(args.ui_history)
        except (OSError, json.JSONDecodeError) as exc:
            print(f"warning: could not read --ui-history {args.ui_history}: {exc}", file=sys.stderr)

    screenshots = curate_screenshots(repo_root)
    md = render_markdown(state, ui_history, screenshots)

    save_json(state_path, state)
    md_path.parent.mkdir(parents=True, exist_ok=True)
    with open(md_path, "w", encoding="utf-8") as fp:
        fp.write(md)

    print(f"Dashboard updated: {md_path.relative_to(repo_root)}")
    print(f"State written:     {state_path.relative_to(repo_root)}")
    if screenshots:
        print(f"Screenshots:       {len(screenshots)} representative image(s) in "
              f"{(repo_root / 'docs' / 'test-status' / 'screenshots').relative_to(repo_root)}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
