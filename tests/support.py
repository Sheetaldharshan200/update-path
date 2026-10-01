"""The sandbox every suite that runs the real CLI shares: a throwaway kit home, a throwaway user home, a bare PATH.

The kit home (``EXAKIT_HOME``) holds the install record; the user home holds
what the kit writes outside it (``~/.claude``, ``~/.agents``, ``~/.exasol``,
``~/.config``); the PATH carries no launcher and no exapump, so no command can
reach a database or a client on the machine that runs the suite. Every
``EXAKIT_*`` variable of the caller's shell is dropped.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
MANIFEST = {
    "manifest_version": 1, "kit_level": 1, "installed_at": "2026-09-30T00:00:00Z", "os": "macos", "arch": "arm64",
    "runtime": {"type": "personal", "status": "running", "version": "2.3.0", "dsn": "127.0.0.1:1", "user": "sys"},
    "components": {"skills": {"version": "1.12.2"}, "mcp_server": {"version": "2.2.0"}},
    "data": {"loaded": True, "datasets": {"tpch": {"loaded": True}}},
    "steps_completed": ["launcher", "runtime", "exapump", "mcp", "pyexasol", "exakit_helper"], "log_dir": "/tmp/x",
}


def kit_settings():
    """The kit's own settings, as the catalog loads them."""
    from exakit.domain.settings import KitSettings
    return KitSettings.from_doc(json.loads((REPO / "catalog" / "kit.json").read_text(encoding="utf-8")))


def bare_path() -> str:
    """The interpreter's own directory plus the system directories: nothing the kit installed."""
    if os.name == "nt":
        return os.environ.get("PATH", "")
    return os.pathsep.join([str(Path(sys.executable).parent), "/usr/bin", "/bin", "/usr/sbin", "/sbin"])


class Sandbox:
    def __init__(self, *, manifest: dict | str | None, env: dict[str, str] | None = None) -> None:
        self.dir = tempfile.mkdtemp(prefix="exakit-sandbox-")
        self.home = Path(self.dir) / "home"
        self.home.mkdir()
        self.user_home = Path(self.dir) / "user"
        self.user_home.mkdir()
        if manifest is not None:
            (self.home / "manifest.json").write_text(manifest if isinstance(manifest, str) else json.dumps(manifest), encoding="utf-8")
        inherited = {k: v for k, v in os.environ.items() if not k.startswith("EXAKIT_")}
        self.env = {**inherited, "HOME": str(self.user_home), "USERPROFILE": str(self.user_home), "PATH": bare_path(),
                    "EXAKIT_HOME": str(self.home), "EXAKIT_BIN_DIR": str(Path(self.dir) / "bin"),
                    "EXAKIT_VERSIONS_TTL": "999999", "EXAKIT_NO_UPDATE_NOTICE": "1", "EXAKIT_ABOUT_OFFLINE": "1", "NO_COLOR": "1",
                    "PYTHONPATH": str(REPO), **(env or {})}

    def run(self, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-m", "exakit", *args], cwd=REPO, env={**self.env, **(env or {})},
                              capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL, check=False)

    def close(self) -> None:
        shutil.rmtree(self.dir, ignore_errors=True)


def one_object(text: str) -> dict:
    """The one JSON object a ``--json`` call prints, and nothing else."""
    lines = [line for line in text.splitlines() if line.strip()]
    assert len(lines) == 1, f"expected one JSON line, got {len(lines)}: {text[:200]!r}"
    return json.loads(lines[0])
