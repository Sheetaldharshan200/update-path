#!/usr/bin/env python3
"""The coding standard of docs/design.md section 9, checked mechanically.

Rules, each a function below that yields ``(path, line, text)`` findings:

  1. size:        a module in exakit/ is at most 400 lines, a function at most 40
  2. complexity:  a function's cyclomatic complexity is at most 12
  3. layers:      layers point down only (domain -> nothing; ui, adapters -> domain;
                  app, lifecycles, components, addons -> adapters, ui, domain;
                  cli -> app, ui, domain, and adapters only from cli/_context.py)
  4. boundary:    no subprocess, urllib, builtin open() or os.environ write outside adapters/
  5. stdlib:      the standard library only in exakit/ (plus the kit's own packages)
  6. shell:       the shell layer (bootstrap/, install.sh, install.ps1, setup/exakit*) is ASCII
  7. docstrings:  every public function in exakit/ has one (reported, never failed)

Writes reports/standard.json and prints a summary; exits 1 when a rule fails.
"""

from __future__ import annotations

import ast
import json
import sys
from collections.abc import Iterator
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PACKAGE = REPO / "exakit"
MAX_MODULE_LINES, MAX_FUNCTION_LINES, MAX_COMPLEXITY = 400, 40, 12
LAYER_ALLOWS = {
    "domain": {"domain"},
    "ui": {"domain", "ui"},
    "adapters": {"domain", "adapters"},
    "app": {"domain", "adapters", "ui", "app", "lifecycles", "components", "addons"},
    "lifecycles": {"domain", "adapters", "ui", "app", "lifecycles", "components", "addons"},
    "components": {"domain", "adapters", "ui", "app", "lifecycles", "components", "addons"},
    "addons": {"domain", "adapters", "ui", "app", "lifecycles", "components", "addons"},
    "cli": {"domain", "ui", "app", "cli", "lifecycles", "components"},
}
OWN_PACKAGES = {"exakit", "mcp"}
TUI_PACKAGES = {"textual", "rich"}          # allowed in exakit/ui/tui/ only (architecture A3): the screens live in their own venv
# The one place outside adapters/ that opens a file: the terminal itself is the UI's device (design.md 9).
BOUNDARY_EXCEPTIONS = {"exakit/ui/__init__.py": "/dev/tty", "exakit/ui/keys.py": "/dev/tty"}
SHELL_FILES = ["install.sh", "install.ps1", "bootstrap/ensure-python.sh", "bootstrap/ensure-python.ps1",
               "bootstrap/exakit", "bootstrap/exakit.ps1", "bootstrap/exakit.cmd", "setup/exakit", "setup/exakit.ps1", "setup/exakit.cmd"]

Finding = tuple[str, int, str]


def modules() -> Iterator[tuple[Path, str, ast.Module]]:
    for path in sorted(PACKAGE.rglob("*.py")):
        text = path.read_text(encoding="utf-8")
        yield path, text, ast.parse(text, filename=str(path))


def rel(path: Path) -> str:
    return str(path.relative_to(REPO))


def functions(tree: ast.Module) -> Iterator[ast.FunctionDef | ast.AsyncFunctionDef]:
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            yield node


def complexity(node: ast.AST) -> int:
    """McCabe: one path plus one per decision point, the way ruff's C901 counts."""
    score = 1
    for child in ast.walk(node):
        if isinstance(child, (ast.If, ast.For, ast.AsyncFor, ast.While, ast.ExceptHandler, ast.match_case)):
            score += 1
    return score


def rule_size() -> Iterator[Finding]:
    for path, text, tree in modules():
        lines = len(text.splitlines())
        if lines > MAX_MODULE_LINES:
            yield rel(path), 1, f"module is {lines} lines (max {MAX_MODULE_LINES})"
        for fn in functions(tree):
            length = fn.end_lineno - fn.lineno + 1
            if length > MAX_FUNCTION_LINES:
                yield rel(path), fn.lineno, f"{fn.name} is {length} lines (max {MAX_FUNCTION_LINES})"


def rule_complexity() -> Iterator[Finding]:
    for path, _text, tree in modules():
        for fn in functions(tree):
            score = complexity(fn)
            if score > MAX_COMPLEXITY:
                yield rel(path), fn.lineno, f"{fn.name} has cyclomatic complexity {score} (max {MAX_COMPLEXITY})"


def _relative_target(package_parts: tuple[str, ...], node: ast.ImportFrom) -> list[str]:
    """The layer names a relative import reaches: the resolved module, or the imported names for ``from . import x``."""
    base = list(package_parts[: len(package_parts) - node.level + 1])
    module = node.module.split(".") if node.module else []
    if base or module:
        return [(base + module)[0]] if (base + module) else []
    return [alias.name for alias in node.names]


def imported_layers(path: Path, tree: ast.Module) -> Iterator[tuple[int, str]]:
    """(line, layer) for every import of another exakit layer, relative imports resolved."""
    package_parts = path.relative_to(PACKAGE).parts[:-1]
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name.startswith("exakit."):
                    yield node.lineno, alias.name.split(".")[1]
        elif isinstance(node, ast.ImportFrom) and node.level:
            for target in _relative_target(package_parts, node):
                yield node.lineno, target
        elif isinstance(node, ast.ImportFrom) and (node.module or "").startswith("exakit."):
            yield node.lineno, node.module.split(".")[1]
        elif isinstance(node, ast.ImportFrom) and node.module == "exakit":
            for alias in node.names:
                yield node.lineno, alias.name


def rule_layers() -> Iterator[Finding]:
    for path, _text, tree in modules():
        parts = path.relative_to(PACKAGE).parts
        if len(parts) < 2:
            continue
        layer = parts[0]
        allowed = LAYER_ALLOWS.get(layer)
        if allowed is None:
            continue
        if layer == "cli" and path.name == "_context.py":
            allowed = allowed | {"adapters"}
        for line, target in imported_layers(path, tree):
            if target in LAYER_ALLOWS and target not in allowed:
                yield rel(path), line, f"{layer} imports {target}: layers point down only"


def rule_boundary() -> Iterator[Finding]:
    for path, _text, tree in modules():
        parts = path.relative_to(PACKAGE).parts
        if parts[0] == "adapters":
            continue
        for node in ast.walk(tree):
            if (isinstance(node, ast.Import) and any(a.name.split(".")[0] in ("subprocess", "urllib") for a in node.names)) or (isinstance(node, ast.ImportFrom) and (node.module or "").split(".")[0] in ("subprocess", "urllib")):
                yield rel(path), node.lineno, "subprocess/urllib belong in adapters/"
            elif isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "open":
                allowed = BOUNDARY_EXCEPTIONS.get(rel(path))
                if not (allowed and node.args and ast.unparse(node.args[0]) == repr(allowed)):
                    yield rel(path), node.lineno, "builtin open() belongs in adapters/ (use the fs adapters or Path methods)"
            elif isinstance(node, (ast.Assign, ast.AugAssign, ast.Delete)):
                for target in getattr(node, "targets", [getattr(node, "target", None)]):
                    if isinstance(target, ast.Subscript) and ast.unparse(target.value) == "os.environ":
                        yield rel(path), node.lineno, "os.environ is written only in adapters/"


def rule_stdlib() -> Iterator[Finding]:
    stdlib = set(sys.stdlib_module_names)
    for path, _text, tree in modules():
        for node in ast.walk(tree):
            names = []
            if isinstance(node, ast.Import):
                names = [a.name.split(".")[0] for a in node.names]
            elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
                names = [node.module.split(".")[0]]
            for name in names:
                if name in TUI_PACKAGES and rel(path).startswith("exakit/ui/tui/"):
                    continue
                if name not in stdlib and name not in OWN_PACKAGES:
                    yield rel(path), node.lineno, f"third-party import '{name}': exakit/ is standard library only"


def rule_shell() -> Iterator[Finding]:
    for name in SHELL_FILES:
        path = REPO / name
        if not path.exists():
            yield name, 0, "shell file missing"
            continue
        for number, line in enumerate(path.read_bytes().splitlines(), 1):
            if any(b > 127 for b in line):
                yield name, number, "non-ASCII byte in the shell layer"


def _public_functions(tree: ast.Module) -> Iterator[ast.FunctionDef | ast.AsyncFunctionDef]:
    """Module-level functions and methods: closures nested in a function are not an interface."""
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            yield node
        elif isinstance(node, ast.ClassDef):
            for member in node.body:
                if isinstance(member, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    yield member


def rule_docstrings() -> Iterator[Finding]:
    for path, _text, tree in modules():
        for fn in _public_functions(tree):
            trivial = len(fn.body) == 1 and isinstance(fn.body[0], ast.Expr) and isinstance(getattr(fn.body[0], "value", None), ast.Constant)
            if not fn.name.startswith("_") and ast.get_docstring(fn) is None and path.name != "__init__.py" and not trivial:
                yield rel(path), fn.lineno, f"public function {fn.name} has no docstring"


RULES = [
    ("size", "a module is at most 400 lines, a function at most 40", rule_size, True),
    ("complexity", "cyclomatic complexity at most 12", rule_complexity, True),
    ("layers", "layers point down only", rule_layers, True),
    ("boundary", "process, network, files and the environment only in adapters/", rule_boundary, True),
    ("stdlib", "standard library only in exakit/", rule_stdlib, True),
    ("shell", "the shell layer is ASCII", rule_shell, True),
    ("docstrings", "public functions carry a docstring", rule_docstrings, False),
]


def main(argv: list[str]) -> int:
    out_dir = REPO / (argv[1] if len(argv) > 1 else "reports")
    out_dir.mkdir(parents=True, exist_ok=True)
    report = []
    failed = False
    for rule_id, title, fn, gating in RULES:
        findings = [{"file": f, "line": n, "text": t} for f, n, t in fn()]
        status = "pass" if not findings else ("fail" if gating else "note")
        failed = failed or status == "fail"
        report.append({"id": rule_id, "title": title, "gating": gating, "status": status, "count": len(findings), "findings": findings})
        print(f"[{status:4}] {rule_id:11} {title} ({len(findings)})")
        for item in findings[: 20 if gating else 5]:
            print(f"         {item['file']}:{item['line']} {item['text']}")
    (out_dir / "standard.json").write_text(json.dumps({"rules": report, "failed": failed}, indent=2) + "\n", encoding="utf-8")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
