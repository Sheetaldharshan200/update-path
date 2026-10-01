#!/usr/bin/env python3
"""Assemble the QA report from what the other tools wrote: reports/qa-report.md.

    python3 tools/qa_report.py                          # from reports/
    python3 tools/qa_report.py --from artifacts/        # CI: every downloaded reports-* directory, one test run per platform
    python3 tools/qa_report.py --real-install artifacts/real-install-ubuntu-latest

Inputs (each optional; a missing one is reported as "not run"):
  standard.json   tools/check_standard.py     lint.json      ruff --output-format json
  tests.json      tools/run_tests.py          release.json   tools/release_check.py
  real-install    the artifact of .github/workflows/real-install.yml (status.json, version.json, manifest.json)
"""

from __future__ import annotations

import json
import platform
import sys
from datetime import datetime, UTC
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


def read(path: Path):
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else None


def gate(name: str, ok: bool | None, detail: str) -> str:
    verdict = "not run" if ok is None else ("pass" if ok else "FAIL")
    return f"| {name} | {verdict} | {detail} |"


def standard_rows(doc) -> list[str]:
    if not doc:
        return [gate("coding standard", None, "tools/check_standard.py did not run")]
    rows = []
    for rule in doc["rules"]:
        ok = None if rule["status"] == "note" else rule["status"] == "pass"
        text = f"{rule['count']} finding(s)" if rule["count"] else "clean"
        if rule["status"] == "note":
            text = f"{rule['count']} noted, not gating"
        rows.append(gate(f"standard: {rule['id']}", ok if ok is not None else True, f"{rule['title']}: {text}"))
    return rows


def lint_rows(doc) -> list[str]:
    if doc is None:
        return [gate("lint (ruff)", None, "no reports/lint.json")]
    by_rule: dict[str, int] = {}
    for item in doc:
        by_rule[item.get("code") or "syntax"] = by_rule.get(item.get("code") or "syntax", 0) + 1
    detail = "clean" if not doc else ", ".join(f"{k} x{v}" for k, v in sorted(by_rule.items()))
    return [gate("lint (ruff, the SonarQube-aligned rule set in ruff.toml)", not doc, detail)]


def tests_rows(runs: list[tuple[str, dict]]) -> list[str]:
    if not runs:
        return [gate("tests", None, "tools/run_tests.py did not run")]
    rows = []
    for label, doc in runs:
        for suite in doc["suites"]:
            bad = suite["fail"] + suite["error"]
            rows.append(gate(f"tests/{suite['suite']} [{label}]", bad == 0, f"{suite['tests']} tests, {bad} failing, {suite['skip']} skipped, {suite['seconds']} s"))
        cov = doc.get("coverage")
        if cov:
            rows.append(gate(f"coverage [{label}]", cov["percent"] >= 70, f"{cov['percent']}% of {cov['statements']} statements (gate: 70%)"))
    return rows


def release_rows(doc) -> list[str]:
    if not doc:
        return [gate("release check", None, "tools/release_check.py did not run")]
    rows = []
    for check in doc["checks"]:
        ok = None if check["status"] == "warn" else check["status"] == "pass"
        detail = "; ".join(check["findings"][:3]) or "clean"
        if len(check["findings"]) > 3:
            detail += f" (+{len(check['findings']) - 3} more)"
        rows.append(gate(f"release: {check['id']}", True if ok is None else ok, ("warning: " if ok is None else "") + detail))
    return rows


def real_install_rows(dirs: list[Path]) -> list[str]:
    if not dirs:
        return [gate("real install (scratch machine)", None, "no artifact given; run the real-install workflow")]
    rows = []
    for folder in dirs:
        status = read(folder / "status.json") or {}
        version = read(folder / "version.json") or {}
        manifest = read(folder / "manifest.json") or {}
        ok = bool(status.get("running")) and status.get("status") == "running"
        comps = {r["component"]: r.get("installed") or r.get("current") for r in version.get("components", [])} if version else {}
        detail = (f"status {status.get('status')}, datasets {status.get('datasets_loaded')}, persona {status.get('persona') or manifest.get('persona', {}).get('id')}, "
                  f"kit {manifest.get('kit', {}).get('version')}, components {comps}")
        rows.append(gate(f"real install [{folder.name}]", ok, detail[:300]))
    return rows


def main(argv: list[str]) -> int:
    base = REPO / "reports"
    runs: list[tuple[str, dict]] = []
    real: list[Path] = []
    if "--from" in argv:
        root = Path(argv[argv.index("--from") + 1])
        for folder in sorted(root.glob("reports-*")):
            doc = read(folder / "tests.json")
            if doc:
                runs.append((folder.name.removeprefix("reports-"), doc))
        real = sorted(p for p in root.glob("real-install-*") if p.is_dir())
        first = next(iter(sorted(root.glob("reports-*"))), None)
        base = first if first else base
    elif (base / "tests.json").exists():
        runs.append((f"{platform.system().lower()}-{platform.python_version()}", read(base / "tests.json")))
    if "--real-install" in argv:
        real.append(Path(argv[argv.index("--real-install") + 1]))
    standard = read(base / "standard.json") or read(REPO / "reports" / "standard.json")
    lint = read(base / "lint.json") if (base / "lint.json").exists() else read(REPO / "reports" / "lint.json")
    release = read(base / "release.json") or read(REPO / "reports" / "release.json")
    rows = standard_rows(standard) + lint_rows(lint) + tests_rows(runs) + release_rows(release) + real_install_rows(real)
    failing = [r for r in rows if "| FAIL |" in r]
    not_run = [r for r in rows if "| not run |" in r]
    when = datetime.now(UTC).strftime("%Y-%m-%d %H:%M UTC")
    version = (release or {}).get("version") or "unknown"
    lines = [f"# QA report: kit {version}", "", f"Assembled {when}. Verdict: **{'NOT READY: ' + str(len(failing)) + ' gate(s) failing' if failing else 'every gate that ran passed'}**"
             + (f", {len(not_run)} not run" if not_run else "") + ".", "",
             "Gates in order: the coding standard (size, complexity, layers, boundary, stdlib, shell), the lint, every test",
             "suite per platform with coverage, the release checks, and the real install on a scratch machine.", "",
             "| Gate | Verdict | Detail |", "|---|---|---|", *rows, "",
             "## What the suites cover", "",
             "- **unit**: every rule and adapter over fakes (no machine state); the three upstream fallback orders (GitHub, cache, ours).",
             "- **contract**: the frozen `--json` shapes and exit codes against the real CLI in a hermetic sandbox.",
             "- **scenarios**: every command in every machine state (fresh, recorded running, stopped, no database, interrupted install,",
             "  persona recorded, corrupt record), both output modes, the refusal paths of every mutating command, the password never printed.",
             "- **e2e**: the installer dry run, the launcher, the bootstrap (the real uv + CPython download opt-in).",
             "- **mcp**: the MCP subsystem's own suite.",
             "- **real install**: `.github/workflows/real-install.yml` on a fresh runner: install with a persona, status, the agent commands,",
             "  a second run that skips every step, stop/start/update/data-load, uninstall.", "",
             "## Known deviations, accepted", "",
             "- `exakit help <unknown>` exits 1 (a not-found page) while `--json` answers a search with `count: 0` and exit 0.",
             "- `exakit logs <unknown>` exits 1 (no such log) while `--json` refuses a target with exit 2: `--json` lists targets only.",
             "- macOS hosted runners cannot virtualise, so the real-install job there proves everything except the database itself.", ""]
    (base if base.exists() else REPO / "reports").mkdir(parents=True, exist_ok=True)
    out = REPO / "reports" / "qa-report.md"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines), encoding="utf-8")
    print("\n".join(rows))
    print(f"\nqa-report: {out} ({'FAIL' if failing else 'pass'})")
    return 1 if failing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
