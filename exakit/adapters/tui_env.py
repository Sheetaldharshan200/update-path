"""The screens' toolkit (Textual) in a venv of its own under the kit home, created by uv; never in the core interpreter.

A marker file in the venv holds the spec that was installed, so the venv is built
once, rebuilt when the pin in versions.json changes, and left alone otherwise.
"""

from __future__ import annotations

from pathlib import Path

from exakit.domain.errors import Failed

from .fs.atomic import atomic_write_text
from .uv import Uv

MARKER = ".exakit-spec"


def site_packages(venv: Path, *, windows: bool) -> Path | None:
    """The venv's site-packages folder, or None before the venv exists."""
    if windows:
        candidate = venv / "Lib" / "site-packages"
        return candidate if candidate.is_dir() else None
    hits = sorted((venv / "lib").glob("python3.*/site-packages")) if (venv / "lib").is_dir() else []
    return hits[-1] if hits else None


def ready(venv: Path, spec: str, *, windows: bool) -> Path | None:
    """The site-packages when the venv already holds exactly ``spec``; None when it must be (re)built."""
    try:
        if (venv / MARKER).read_text(encoding="utf-8").strip() != spec:
            return None
    except OSError:
        return None
    return site_packages(venv, windows=windows)


def ensure(venv: Path, uv: Uv, spec: str, *, windows: bool) -> Path:
    """The site-packages with ``spec`` installed: the venv created when missing, the spec installed when the marker names another."""
    site = ready(venv, spec, windows=windows)
    if site is not None:
        return site
    if not uv.python_of(venv).exists():
        uv.venv(venv, seed=False)
    uv.pip_install(uv.python_of(venv), spec)
    site = site_packages(venv, windows=windows)
    if site is None:
        raise Failed(f"the environment at {venv} has no site-packages folder")
    atomic_write_text(venv / MARKER, spec + "\n", mode=0o644)
    return site
