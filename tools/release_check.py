#!/usr/bin/env python3
"""The release gate: what must be true before a kit version is tagged.

    python3 tools/release_check.py             # every check, the verdict in reports/release.json and release-check.md
    python3 tools/release_check.py --strict    # a CHANGELOG section for the version is required (tagging time)

Checks (each a function; a failure names what is wrong):
  versions       exakit.__version__, versions.json kit.version, help/whats-new.json, sonar-project.properties agree
  changelog      CHANGELOG.md has a section for the version (Unreleased is a warning, --strict makes it a failure)
  settings-agree the shell layer's defaults (repository, thresholds, Python, installer URLs) equal catalog/kit.json
  launchers      setup/exakit* are byte-identical copies of bootstrap/exakit*
  commands       every command in help/exakit.json has a handler and every handler a help entry
  catalog        every catalog file validates, every persona names known datasets and add-ons
  fallbacks      each add-on's catalog fallback_version equals its versions.json version
  attribution    no AI attribution in the tree or the last 50 commits
  secrets        no token, key or password literal in the tree
  shell          the POSIX shell layer parses (sh -n) and is ASCII
  env-vars       every EXAKIT_* variable the code reads is documented (warning)
  docs           the four living documents exist and name the version
  tests          reports/tests.json (from tools/run_tests.py) shows no failure
Exits 1 when a check fails.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from datetime import datetime, UTC
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

Check = tuple[str, str, list[str]]     # (id, status, findings)
ATTRIBUTION = re.compile(r"Co-Authored-By: Claude|Generated with \[Claude|🤖 Generated|Co-authored-by: (Claude|Anthropic)", re.I)
SECRETS = [
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}"), "GitHub token"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "AWS access key"),
    (re.compile(r"-----BEGIN (RSA |EC |OPENSSH |)PRIVATE KEY-----"), "private key"),
    (re.compile(r"(?i)\b(password|passwd|secret)\s*[:=]\s*[\"'][^\"'\s]{8,}[\"']"), "password literal"),
]
TEXT_SUFFIXES = {".py", ".md", ".json", ".sh", ".ps1", ".cmd", ".yml", ".yaml", ".toml", ".properties", ".txt", ".sql", ".cfg", ""}
SKIP_DIRS = {".git", "__pycache__", "reports", "static", "test_data", ".claude"}


def version_of_kit() -> str:
    from exakit import __version__
    return __version__


def text_files() -> list[Path]:
    found = []
    for path in REPO.rglob("*"):
        if path.is_file() and not (SKIP_DIRS & set(path.relative_to(REPO).parts)) and path.suffix in TEXT_SUFFIXES:
            found.append(path)
    return found


def check_versions() -> Check:
    version = version_of_kit()
    problems = []
    manifest = json.loads((REPO / "versions.json").read_text(encoding="utf-8"))
    if manifest.get("kit", {}).get("version") != version:
        problems.append(f"versions.json kit.version is {manifest.get('kit', {}).get('version')}, exakit.__version__ is {version}")
    cards = json.loads((REPO / "help" / "whats-new.json").read_text(encoding="utf-8"))
    if version not in cards:
        problems.append(f"help/whats-new.json has no card for {version}")
    sonar = (REPO / "sonar-project.properties").read_text(encoding="utf-8")
    if f"sonar.projectVersion={version}" not in sonar:
        problems.append(f"sonar-project.properties does not name {version}")
    return "versions", "fail" if problems else "pass", problems


def check_changelog(strict: bool) -> Check:
    version = version_of_kit()
    text = (REPO / "CHANGELOG.md").read_text(encoding="utf-8")
    if re.search(rf"^## {re.escape(version)}\b", text, re.M):
        return "changelog", "pass", []
    if re.search(r"^## Unreleased", text, re.M):
        return "changelog", "fail" if strict else "warn", [f"CHANGELOG.md still says Unreleased; rename the section to {version} when tagging"]
    return "changelog", "fail", [f"CHANGELOG.md has no section for {version}"]


def check_settings_agree() -> Check:
    """The shell layer's own defaults (it runs before Python) equal catalog/kit.json."""
    doc = json.loads((REPO / "catalog" / "kit.json").read_text(encoding="utf-8"))
    problems = []
    sh = (REPO / "install.sh").read_text(encoding="utf-8")
    ps1 = (REPO / "install.ps1").read_text(encoding="utf-8")
    if f'EXAKIT_REPO="${{EXAKIT_REPO:-{doc["repository"]}}}"' not in sh:
        problems.append(f"install.sh's EXAKIT_REPO default is not {doc['repository']}")
    for name, needle in (("install.sh", f"-ge {doc['requirements']['min_ram_gb']} ]"), ("install.sh", f"-ge {doc['requirements']['min_disk_gb']} ]")):
        if needle not in sh:
            problems.append(f"{name}: the preflight threshold {needle.strip('-ge ]')} GB differs from kit.json")
    if f"else {{ {doc['requirements']['min_ram_gb']} }}" not in ps1:
        problems.append("install.ps1: the minimum RAM differs from kit.json")
    python = doc["python"]["managed_version"]
    for name, needle in (("bootstrap/ensure-python.sh", f":-{python}}}"), ("bootstrap/ensure-python.ps1", f'"{python}"')):
        if needle not in (REPO / name).read_text(encoding="utf-8"):
            problems.append(f"{name}: the managed Python is not {python}")
    for name in ("bootstrap/exakit", "bootstrap/exakit.ps1"):
        text = (REPO / name).read_text(encoding="utf-8")
        wanted = doc["install"]["sh_url"] if name.endswith("exakit") else doc["install"]["ps1_url"]
        if wanted not in text:
            problems.append(f"{name}: the installer URL is not {wanted}")
    return "settings-agree", "fail" if problems else "pass", problems


def check_launchers() -> Check:
    problems = [f"setup/{name} differs from bootstrap/{name}" for name in ("exakit", "exakit.ps1")
                if (REPO / "setup" / name).read_bytes() != (REPO / "bootstrap" / name).read_bytes()]
    return "launchers", "fail" if problems else "pass", problems


def check_commands() -> Check:
    from exakit.cli.main import ALIASES, HANDLERS
    documented = {c["command"] for c in json.loads((REPO / "help" / "exakit.json").read_text(encoding="utf-8"))["commands"]}
    handled = {name for name in HANDLERS if name not in ALIASES}
    problems = [f"documented but no handler: {c}" for c in sorted(documented - handled)]
    problems += [f"handler without a help entry: {c}" for c in sorted(handled - documented - {"persona"})]
    return "commands", "fail" if problems else "pass", problems


def check_catalog() -> Check:
    from exakit.domain.catalog import validate_addon, validate_component, validate_persona
    problems = []
    components = {p.stem for p in (REPO / "catalog" / "components").glob("*.json")}
    addons = {p.parent.name for p in (REPO / "catalog" / "addons").glob("*/addon.json")}
    for path in (REPO / "catalog" / "components").glob("*.json"):
        problems += [f"{path.name}: {p}" for p in validate_component(json.loads(path.read_text(encoding="utf-8")), expected_id=path.stem)]
    for path in (REPO / "catalog" / "addons").glob("*/addon.json"):
        problems += [f"{path.parent.name}: {p}" for p in validate_addon(json.loads(path.read_text(encoding="utf-8")), expected_id=path.parent.name)]
    datasets = {p.parent.name for p in (REPO / "data" / "datasets").glob("*/dataset.conf")}
    for path in (REPO / "catalog" / "personas").glob("*.json"):
        doc = json.loads(path.read_text(encoding="utf-8"))
        problems += [f"{path.name}: {p}" for p in validate_persona(doc, expected_id=path.stem, known_addons=addons, known_datasets=datasets)]
    if not components or not addons:
        problems.append("the catalog is empty")
    return "catalog", "fail" if problems else "pass", problems


def check_fallbacks() -> Check:
    manifest = json.loads((REPO / "versions.json").read_text(encoding="utf-8")).get("components", {})
    problems = []
    for path in sorted((REPO / "catalog").rglob("*.json")):
        doc = json.loads(path.read_text(encoding="utf-8"))
        cid, fallback = doc.get("id"), doc.get("fallback_version")
        pinned = (manifest.get(cid) or {}).get("version") if cid else None
        if fallback and pinned and fallback != pinned:
            problems.append(f"{path.relative_to(REPO)}: fallback_version {fallback} but versions.json says {pinned}")
    return "fallbacks", "fail" if problems else "pass", problems


def check_attribution() -> Check:
    problems = [f"{p.relative_to(REPO)}" for p in text_files() if p.name != "release_check.py" and ATTRIBUTION.search(p.read_text(encoding="utf-8", errors="replace"))]
    status = "fail" if problems else "pass"
    log = subprocess.run(["git", "log", "-50", "--format=%h%x00%s%x00%b%x1e"], cwd=REPO, capture_output=True, text=True, check=False).stdout
    tainted = [f"commit {entry.split(chr(0))[0]} ({entry.split(chr(0))[1][:50]})" for entry in log.split("\x1e") if entry.strip() and ATTRIBUTION.search(entry)]
    if tainted:                      # history already pushed: reported for the owner to rewrite, never rewritten here
        status = status if status == "fail" else "warn"
        problems += [f"{t}: an attribution trailer in a pushed commit; rewrite the history before tagging" for t in tainted]
    return "attribution", status, problems


def check_secrets() -> Check:
    problems = []
    for path in text_files():
        if path.name == "release_check.py":
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for pattern, label in SECRETS:
            for match in pattern.finditer(text):
                if "example" in match.group(0).lower() or "test" in str(path).lower() or "{" in match.group(0):
                    continue
                problems.append(f"{path.relative_to(REPO)}: {label}")
    return "secrets", "fail" if problems else "pass", sorted(set(problems))


def check_shell() -> Check:
    problems = []
    for name in ("install.sh", "bootstrap/ensure-python.sh", "bootstrap/exakit", "setup/exakit"):
        done = subprocess.run(["sh", "-n", str(REPO / name)], capture_output=True, text=True, check=False)
        if done.returncode != 0:
            problems.append(f"{name} does not parse: {done.stderr.strip()[:200]}")
        if any(b > 127 for b in (REPO / name).read_bytes()):
            problems.append(f"{name} is not ASCII")
    return "shell", "fail" if problems else "pass", problems


def check_env_vars() -> Check:
    reads = re.compile(r"""(?:env|environ)\.get\(\s*["'](EXAKIT_[A-Z0-9_]+)["']""")
    used = {m.group(1) for p in (REPO / "exakit").rglob("*.py") for m in reads.finditer(p.read_text(encoding="utf-8"))}
    docs = "".join((REPO / n).read_text(encoding="utf-8") for n in ("AGENTS.md", "docs/design.md", "docs/requirements.md", "README.md", "MARKETPLACE.md"))
    missing = sorted(v for v in used if v not in docs and not v.endswith(("_OK", "_PRESENT", "_MISSING")))
    return "env-vars", "warn" if missing else "pass", [f"read by the code, documented nowhere: {v}" for v in missing]


def check_docs() -> Check:
    version = version_of_kit()
    problems = []
    for name in ("docs/requirements.md", "docs/design.md", "docs/tasks.md", "docs/test-and-acceptance.md"):
        if not (REPO / name).exists():
            problems.append(f"{name} is missing")
    for name in ("docs/test-and-acceptance.md", "CHANGELOG.md"):
        if (REPO / name).exists() and version not in (REPO / name).read_text(encoding="utf-8"):
            problems.append(f"{name} does not mention {version}")
    return "docs", "fail" if problems else "pass", problems


def check_tests() -> Check:
    path = REPO / "reports" / "tests.json"
    if not path.exists():
        return "tests", "warn", ["reports/tests.json not found: run tools/run_tests.py first"]
    doc = json.loads(path.read_text(encoding="utf-8"))
    failing = doc.get("failing") or []
    suites = {s["suite"] for s in doc.get("suites", [])}
    problems = [f"failing: {row['id']}" for row in failing]
    problems += [f"suite not run: {s}" for s in ("unit", "contract", "scenarios", "e2e", "mcp") if s not in suites]
    return "tests", "fail" if problems else "pass", problems


def main(argv: list[str]) -> int:
    strict = "--strict" in argv
    out_dir = REPO / "reports"
    out_dir.mkdir(parents=True, exist_ok=True)
    checks = [check_versions(), check_changelog(strict), check_settings_agree(), check_launchers(), check_commands(), check_catalog(), check_fallbacks(),
              check_attribution(), check_secrets(), check_shell(), check_env_vars(), check_docs(), check_tests()]
    failed = any(status == "fail" for _, status, _ in checks)
    version = version_of_kit()
    lines = [f"# Release check for {version}", "", f"Run {datetime.now(UTC).strftime('%Y-%m-%d %H:%M UTC')}"
             f"{' in strict (tagging) mode' if strict else ''}. Verdict: **{'NOT READY' if failed else 'ready'}**.", "",
             "| Check | Result | Findings |", "|---|---|---|"]
    for cid, status, findings in checks:
        print(f"[{status:4}] {cid:12} {len(findings)}")
        for item in findings[:15]:
            print(f"         {item}")
        lines.append(f"| {cid} | {status} | {'<br>'.join(findings[:15]) or '-'} |")
    (out_dir / "release.json").write_text(json.dumps({"version": version, "strict": strict, "failed": failed,
                                                      "checks": [{"id": c, "status": s, "findings": f} for c, s, f in checks]}, indent=2) + "\n", encoding="utf-8")
    (out_dir / "release-check.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
