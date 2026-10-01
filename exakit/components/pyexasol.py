"""pyexasol: the Python driver in its own venv under the kit home, checked with a real SELECT 1."""

from __future__ import annotations

import shutil
from pathlib import Path

from exakit.adapters.uv import UvTool, find_uv
from exakit.domain.errors import Failed

from .base import ComponentBase

LIVE_CHECK = """
import os, ssl, pyexasol
pw = open(os.environ["EXAKIT_PYX_PWFILE"]).read().strip()
kw = dict(dsn=os.environ["EXAKIT_PYX_DSN"], user=os.environ["EXAKIT_PYX_USER"], password=pw)
try:
    conn = pyexasol.connect(encryption=True, websocket_sslopt={"cert_reqs": ssl.CERT_NONE}, **kw)
except Exception:
    conn = pyexasol.connect(encryption=False, **kw)
try:
    value = conn.execute("SELECT 1").fetchval()
    raise SystemExit(0 if value == 1 else 1)
finally:
    conn.close()
"""


class Lifecycle(ComponentBase):
    id = "pyexasol"
    key = "pyexasol"
    step = "pyexasol"

    @property
    def venv(self) -> Path:
        """The pyexasol venv (EXAKIT_PYEXASOL_VENV overrides)."""
        return Path(self.ctx.env.get("EXAKIT_PYEXASOL_VENV") or self.ctx.paths.home / "pyexasol-venv")

    @property
    def python(self) -> Path:
        """The venv's interpreter."""
        return self.venv / ("Scripts/python.exe" if self.ctx.platform.os == "windows" else "bin/python")

    @property
    def package(self) -> str:
        """The package spec to install (EXAKIT_PYEXASOL_PACKAGE overrides the catalog's)."""
        return self.ctx.env.get("EXAKIT_PYEXASOL_PACKAGE") or str(self.ctx.catalog.component("pyexasol").source["package"])

    def installed_version(self) -> str | None:
        """The pyexasol version importable from the venv, or None."""
        if not self.python.exists():
            return None
        done = self.ctx.runner.run([str(self.python), "-c", "import pyexasol; print(pyexasol.__version__)"], timeout=20)
        text = done.out.strip().splitlines()[0] if done.ok and done.out.strip() else ""
        return text or None

    def uv(self) -> UvTool:
        """The uv tool, wired once per command."""
        if self.ctx.uv is not None:
            return self.ctx.uv
        bin_path = find_uv(self.ctx.env, self.ctx.paths.home, self.ctx.runner, windows=self.ctx.platform.os == "windows")
        if not bin_path:
            raise Failed("uv (the Python tool runner) is not available - install it from https://docs.astral.sh/uv/ and re-run",
                         remedy="exakit update pyexasol")
        self.ctx.uv = UvTool(bin_path, self.ctx.runner, python_version=self.ctx.catalog.kit.managed_python, windows=self.ctx.platform.os == "windows")
        return self.ctx.uv

    def install(self, version: str) -> None:
        """Create the venv and install the package at the version."""
        current = self.installed_version()
        if current == version and not self.force():
            self.ctx.ui.ok(f"pyexasol {current} already installed: {self.venv}")
        else:
            self.ctx.ui.info(f"Installing pyexasol {version} (Exasol Python driver)")
            uv = self.uv()
            if not self.python.exists():
                uv.venv(self.venv, seed=True)
            uv.pip_install(self.python, f"{self.package}=={version}")
            self.ctx.ui.ok(f"pyexasol installed: {self.venv}")
        self.record(version=version, venv=str(self.venv), python=str(self.python))

    def validate(self) -> None:
        """pyexasol imports and connects; records validated."""
        if not self.python.exists():
            return
        if not self.ctx.runner.run([str(self.python), "-c", "import pyexasol"], timeout=60).ok:
            self.ctx.ui.warn(f"pyexasol is installed but cannot be imported from {self.venv}. Why: exakit logs setup. Recorded validated=false; "
                             "remove the venv and re-run setup to retry.")
            self.record(validated=False)
            return
        host, port, user, pw_file = self.runtime_connection()
        if not host or not port or not pw_file or not Path(pw_file).exists():
            self.ctx.ui.warn("Runtime connection details are incomplete; skipping the pyexasol live check. Re-run setup to retry.")
            self.record(validated=False)
            return
        self.ctx.ui.info("Validating pyexasol against the database (SELECT 1)")
        done = self.ctx.runner.run([str(self.python), "-c", LIVE_CHECK], timeout=120,
                                   env={"EXAKIT_PYX_DSN": f"{host}:{port}", "EXAKIT_PYX_USER": user, "EXAKIT_PYX_PWFILE": pw_file})
        if done.ok:
            self.ctx.ui.ok("pyexasol works: SELECT 1 returned 1")
            self.record(validated=True)
        else:
            self.ctx.log.line("WARN", f"pyexasol live check: {(done.err or done.out).strip()[-300:]}")
            self.ctx.ui.warn("pyexasol is installed but SELECT 1 through it failed - see: exakit logs setup")
            self.record(validated=False)

    def update(self, options: list[str] | None = None) -> None:
        """Install the advertised version when it differs."""
        latest = self.target_version()
        current = self.installed_version()
        if current and current == latest:
            self.ctx.ui.ok(f"pyexasol is already current ({current})")
            return
        self.ctx.ui.info(f"Updating pyexasol {current or 'not installed'} -> {latest}")
        self.install(latest)
        self.validate()
        self.record_desired(latest)
        self.ctx.ui.ok("pyexasol updated; database data was not changed")

    def uninstall(self, *, dry_run: bool) -> list[str]:
        """Remove the venv."""
        if dry_run:
            self.ctx.ui.info(f"  will remove: pyexasol (the managed venv at {self.venv})")
            return [str(self.venv)] if self.venv.exists() else []
        self.ctx.ui.info("Removing the pyexasol venv")
        existed = self.venv.exists()
        shutil.rmtree(self.venv, ignore_errors=True)
        self.forget()
        return [str(self.venv)] if existed else []
