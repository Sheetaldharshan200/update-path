"""Which machine this is, as tokens rather than prose.

``os`` is one of macos, linux, windows; ``arch`` one of x86_64, aarch64;
``wsl_version`` is set on Windows Subsystem for Linux, where ``os`` is linux.
``platform_key`` is the string ``versions.json`` keys its digests by.
"""

from __future__ import annotations

from dataclasses import dataclass

from .errors import BadInput

OS_NAMES = ("macos", "linux", "windows")
ARCH_NAMES = ("x86_64", "aarch64")

_ARCH_ALIASES = {
    "x86_64": "x86_64", "amd64": "x86_64", "x64": "x86_64",
    "aarch64": "aarch64", "arm64": "aarch64",
}
_OS_ALIASES = {"darwin": "macos", "macos": "macos", "linux": "linux", "windows": "windows", "win32": "windows"}


@dataclass(frozen=True, slots=True)
class Platform:
    os: str
    arch: str
    wsl_version: int | None = None

    @property
    def is_wsl(self) -> bool:
        """True under WSL."""
        return self.wsl_version is not None

    @property
    def platform_key(self) -> str:
        """The ``<os>-<arch>`` token digests are keyed by, e.g. ``macos-aarch64``."""
        return f"{self.os}-{self.arch}"

    def to_dict(self) -> dict[str, str | int | None]:
        """The platform as the status document prints it."""
        return {"platform": self.os, "arch": self.arch, "wsl_version": self.wsl_version}


def normalize_os(name: str) -> str:
    """``Darwin`` -> ``macos``; refuses anything the kit does not run on."""
    key = name.strip().lower()
    if key not in _OS_ALIASES:
        raise BadInput(f"Unsupported operating system '{name}' (supported: macOS, Linux, WSL, Windows).")
    return _OS_ALIASES[key]


def normalize_arch(name: str) -> str:
    """``arm64`` -> ``aarch64``; refuses anything the kit does not ship for."""
    key = name.strip().lower()
    if key not in _ARCH_ALIASES:
        raise BadInput(f"Unsupported CPU architecture '{name}' (supported: x86_64, arm64).")
    return _ARCH_ALIASES[key]


def make_platform(os_name: str, arch_name: str, wsl_version: int | None = None) -> Platform:
    """Build a Platform from raw uname-style names, normalised and validated."""
    return Platform(normalize_os(os_name), normalize_arch(arch_name), wsl_version)
