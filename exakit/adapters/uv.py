"""uv: the Python tool runner the kit installs venvs and packages with."""

from __future__ import annotations

from collections.abc import Mapping
from pathlib import Path
from typing import Protocol

from exakit.domain.errors import Failed

from .process.runner import Runner



class Uv(Protocol):
    bin: str
    def venv(self, path: Path, *, seed: bool) -> None: ...
    def pip_install(self, python: Path, spec: str) -> None: ...
    def python_of(self, venv: Path) -> Path: ...
    def bin_of(self, venv: Path, name: str) -> Path: ...


def find_uv(env: Mapping[str, str], home: Path, runner: Runner, windows: bool = False) -> str | None:
    """EXAKIT_UV_BIN, the kit's own copy under tools/uv, then PATH."""
    exe = "uv.exe" if windows else "uv"
    for candidate in (env.get("EXAKIT_UV_BIN"), str(home / "tools" / "uv" / exe)):
        if candidate and Path(candidate).exists():
            return candidate
    return runner.which("uv")


class UvTool:
    def __init__(self, binary: str, runner: Runner, *, python_version: str, windows: bool = False) -> None:
        self.bin = binary
        self.runner = runner
        self.windows = windows
        self.python_version = python_version

    def venv(self, path: Path, *, seed: bool) -> None:
        """Create a venv with the managed Python."""
        cmd = [self.bin, "venv", "--python", self.python_version, str(path)]
        if seed:
            cmd.insert(2, "--seed")
        done = self.runner.run(cmd, timeout=600)
        if not done.ok:
            raise Failed(f"uv could not create the environment at {path}.", hint=done.err.strip()[-300:])

    def pip_install(self, python: Path, spec: str) -> None:
        """Install a spec into a venv."""
        done = self.runner.run([self.bin, "pip", "install", "--python", str(python), spec], timeout=1800)
        if not done.ok:
            raise Failed(f"uv could not install {spec}.", hint=done.err.strip()[-300:])

    def python_of(self, venv: Path) -> Path:
        """The venv's interpreter."""
        return venv / ("Scripts" if self.windows else "bin") / ("python.exe" if self.windows else "python")

    def bin_of(self, venv: Path, name: str) -> Path:
        """A script in the venv's bin folder."""
        return venv / ("Scripts" if self.windows else "bin") / (f"{name}.exe" if self.windows else name)


def package_version(python: Path, package: str, runner: Runner) -> str | None:
    """The installed distribution version inside a venv, or None."""
    if not python.exists():
        return None
    done = runner.run([str(python), "-c", f"from importlib.metadata import version; print(version({package!r}))"], timeout=30)
    text = done.out.strip().splitlines()[0] if done.ok and done.out.strip() else ""
    return text or None
