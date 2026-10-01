"""Which machine this is: os, cpu, and whether this Linux is WSL."""

from __future__ import annotations

import platform as _platform
import re
from pathlib import Path

from exakit.domain.platform import Platform, make_platform


def wsl_version() -> int | None:
    """2 for WSL2, 1 for WSL1, None off WSL. Read from the kernel banner, never guessed."""
    try:
        text = Path("/proc/version").read_text(encoding="utf-8", errors="replace").lower()
    except OSError:
        return None
    if "microsoft" not in text and "wsl" not in text:
        return None
    return 2 if re.search(r"wsl2|microsoft-standard", text) else 1


def detect() -> Platform:
    """This machine's platform."""
    return make_platform(_platform.system(), _platform.machine(), wsl_version() if _platform.system() == "Linux" else None)
