#!/usr/bin/env python3
"""Run the kit's suites and write the test report: JUnit XML per suite, tests.json, test-report.md.

    python3 tools/run_tests.py                    # every suite
    python3 tools/run_tests.py unit contract      # some of them
    python3 tools/run_tests.py --coverage         # with coverage.py when it is installed (CI installs it)

Reports land in reports/ (or the directory named by --reports). The JUnit
files feed SonarQube and the CI summary; test-report.md is the human copy.
"""

from __future__ import annotations

import json
import platform
import sys
import time
import unittest
from datetime import datetime, UTC
from pathlib import Path
from xml.etree import ElementTree as ET

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

SUITES: dict[str, tuple[str, str]] = {
    "unit": ("tests/unit", "pure rules and adapters over fakes; no machine state"),
    "contract": ("tests/contract", "the frozen --json shapes and exit codes, against the real CLI in a sandbox"),
    "scenarios": ("tests/scenarios", "every command in every machine state, both output modes, the secret never printed"),
    "e2e": ("tests/e2e", "the installer dry run, the launcher, the bootstrap (network test opt-in)"),
    "mcp": ("mcp/tests", "the MCP subsystem: adapters, configure, validate, protection"),
    "sample-data": ("tests/test_sample_data_schema.py", "the sample dataset's schema, CSVs and verification SQL agree"),
}


class Recorder(unittest.TestResult):
    """One row per test: outcome, seconds, and the failure text when there is one."""

    def __init__(self) -> None:
        super().__init__()
        self.rows: list[dict] = []
        self._started: dict[str, float] = {}

    def startTest(self, test) -> None:
        super().startTest(test)
        self._started[test.id()] = time.perf_counter()

    def _row(self, test, outcome: str, detail: str = "") -> None:
        ident = test.id()
        module, _, name = ident.rpartition(".")
        self.rows.append({"id": ident, "classname": module, "name": name, "outcome": outcome, "detail": detail,
                          "seconds": round(time.perf_counter() - self._started.get(ident, time.perf_counter()), 3)})

    def addSuccess(self, test) -> None:
        super().addSuccess(test)
        self._row(test, "pass")

    def addFailure(self, test, err) -> None:
        super().addFailure(test, err)
        self._row(test, "fail", self._exc_info_to_string(err, test))

    def addError(self, test, err) -> None:
        super().addError(test, err)
        self._row(test, "error", self._exc_info_to_string(err, test))

    def addSkip(self, test, reason) -> None:
        super().addSkip(test, reason)
        self._row(test, "skip", reason)

    def addExpectedFailure(self, test, err) -> None:
        super().addExpectedFailure(test, err)
        self._row(test, "pass", "expected failure")

    def addUnexpectedSuccess(self, test) -> None:
        super().addUnexpectedSuccess(test)
        self._row(test, "fail", "unexpected success")

    def addSubTest(self, test, subtest, err) -> None:
        super().addSubTest(test, subtest, err)
        if err is not None:
            self.rows.append({"id": subtest.id(), "classname": test.id().rpartition(".")[0], "name": str(subtest),
                              "outcome": "fail" if issubclass(err[0], AssertionError) else "error",
                              "detail": self._exc_info_to_string(err, test), "seconds": 0.0})


def load(suite: str) -> unittest.TestSuite:
    target = SUITES[suite][0]
    loader = unittest.TestLoader()
    if target.endswith(".py"):
        module = target[:-3].replace("/", ".")
        return loader.loadTestsFromName(module)
    return loader.discover(start_dir=str(REPO / target), top_level_dir=str(REPO))


def run_suite(suite: str) -> dict:
    started = time.perf_counter()
    recorder = Recorder()
    load(suite).run(recorder)
    rows = recorder.rows
    counts = {k: sum(1 for r in rows if r["outcome"] == k) for k in ("pass", "fail", "error", "skip")}
    return {"suite": suite, "path": SUITES[suite][0], "about": SUITES[suite][1], "seconds": round(time.perf_counter() - started, 2),
            "tests": len(rows), **counts, "rows": rows}


def junit(result: dict, path: Path) -> None:
    suites = ET.Element("testsuites")
    suite = ET.SubElement(suites, "testsuite", name=result["suite"], tests=str(result["tests"]), failures=str(result["fail"]),
                          errors=str(result["error"]), skipped=str(result["skip"]), time=str(result["seconds"]))
    for row in result["rows"]:
        case = ET.SubElement(suite, "testcase", classname=row["classname"], name=row["name"], time=str(row["seconds"]))
        if row["outcome"] in ("fail", "error"):
            node = ET.SubElement(case, "failure" if row["outcome"] == "fail" else "error", message=row["detail"].strip().splitlines()[-1][:200])
            node.text = row["detail"]
        elif row["outcome"] == "skip":
            ET.SubElement(case, "skipped", message=row["detail"][:200])
    ET.ElementTree(suites).write(path, encoding="utf-8", xml_declaration=True)


def coverage_start():
    try:
        import coverage
    except ImportError:
        return None
    cov = coverage.Coverage(source=["exakit", "mcp"], omit=["*/tests/*"], data_file=str(REPO / "reports" / ".coverage"))
    cov.start()
    return cov


def coverage_finish(cov, out_dir: Path) -> dict | None:
    if cov is None:
        return None
    cov.stop()
    cov.save()
    cov.xml_report(outfile=str(out_dir / "coverage.xml"))
    cov.json_report(outfile=str(out_dir / "coverage.json"))
    doc = json.loads((out_dir / "coverage.json").read_text(encoding="utf-8"))
    files = sorted(((f, d["summary"]["percent_covered"]) for f, d in doc["files"].items()), key=lambda x: x[1])
    return {"percent": round(doc["totals"]["percent_covered"], 1), "statements": doc["totals"]["num_statements"],
            "missing": doc["totals"]["missing_lines"], "lowest": [{"file": f, "percent": round(p, 1)} for f, p in files[:10]]}


def markdown(results: list[dict], cov: dict | None, meta: dict) -> str:
    lines = ["# Test report", "", f"Recorded {meta['when']} on {meta['platform']}, Python {meta['python']}, commit `{meta['commit']}`.", ""]
    total = sum(r["tests"] for r in results)
    bad = sum(r["fail"] + r["error"] for r in results)
    lines += [f"**{total} tests, {bad} failing, {sum(r['skip'] for r in results)} skipped, {sum(r['seconds'] for r in results):.1f} s.**"
              + (f" Coverage of `exakit/` and `mcp/`: **{cov['percent']}%** of {cov['statements']} statements." if cov else ""), ""]
    lines += ["| Suite | What it proves | Tests | Pass | Fail | Error | Skip | Seconds |", "|---|---|---:|---:|---:|---:|---:|---:|"]
    for r in results:
        lines.append(f"| {r['suite']} | {r['about']} | {r['tests']} | {r['pass']} | {r['fail']} | {r['error']} | {r['skip']} | {r['seconds']} |")
    failing = [(r["suite"], row) for r in results for row in r["rows"] if row["outcome"] in ("fail", "error")]
    lines += ["", "## Failures", ""]
    if not failing:
        lines.append("None.")
    for suite, row in failing:
        lines += [f"### {suite}: {row['id']}", "", "```", row["detail"].rstrip(), "```", ""]
    if cov:
        lines += ["", "## Coverage: the ten least covered files", "", "| File | Covered |", "|---|---:|"]
        lines += [f"| {item['file']} | {item['percent']}% |" for item in cov["lowest"]]
    for r in results:
        lines += ["", f"## {r['suite']}: every case", "", "<details>", f"<summary>{r['tests']} cases</summary>", "", "| Case | Result | Seconds |", "|---|---|---:|"]
        lines += [f"| {row['id']} | {row['outcome']} | {row['seconds']} |" for row in r["rows"]]
        lines += ["", "</details>"]
    return "\n".join(lines) + "\n"


def git_commit() -> str:
    import subprocess
    try:
        return subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=REPO, capture_output=True, text=True, check=False).stdout.strip() or "unknown"
    except OSError:
        return "unknown"


def main(argv: list[str]) -> int:
    with_coverage = "--coverage" in argv
    out_dir = REPO / "reports"
    if "--reports" in argv:
        out_dir = REPO / argv[argv.index("--reports") + 1]
    chosen = [a for a in argv[1:] if not a.startswith("--") and a in SUITES] or list(SUITES)
    out_dir.mkdir(parents=True, exist_ok=True)
    cov = coverage_start() if with_coverage else None
    results = []
    for suite in chosen:
        result = run_suite(suite)
        results.append(result)
        junit(result, out_dir / f"junit-{suite}.xml")
        print(f"{suite:12} {result['tests']:4} tests  {result['fail'] + result['error']:3} failing  {result['skip']:3} skipped  {result['seconds']:6.1f}s")
    for result in results:
        for row in result["rows"]:
            if row["outcome"] in ("fail", "error"):
                last = [line for line in row["detail"].strip().splitlines() if line.strip()]
                print(f"  {row['outcome']:5} {row['id']}: {last[-1][:160] if last else ''}")
    cov_summary = coverage_finish(cov, out_dir)
    meta = {"when": datetime.now(UTC).strftime("%Y-%m-%d %H:%M UTC"), "platform": platform.platform(),
            "python": platform.python_version(), "commit": git_commit()}
    (out_dir / "tests.json").write_text(json.dumps({"meta": meta, "coverage": cov_summary,
                                                    "suites": [{k: v for k, v in r.items() if k != "rows"} for r in results],
                                                    "failing": [row for r in results for row in r["rows"] if row["outcome"] in ("fail", "error")]},
                                                   indent=2) + "\n", encoding="utf-8")
    (out_dir / "test-report.md").write_text(markdown(results, cov_summary, meta), encoding="utf-8")
    if cov_summary:
        print(f"coverage     {cov_summary['percent']}%")
    return 1 if any(r["fail"] or r["error"] for r in results) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
