"""The log every layer may write to: a protocol, and the null log that records nothing.

The file-backed log is an adapter (``exakit.adapters.fs.log.FileLog``); the
UI and the app only ever see this protocol.
"""

from __future__ import annotations

from pathlib import Path
from typing import Protocol


class Log(Protocol):
    path: Path | None
    def line(self, level: str, message: str) -> None: ...


class NullLog:
    """For read-only queries and tests: records nothing, never touches the disk."""

    path: Path | None = None

    def line(self, level: str, message: str) -> None:
        """Accept the line and drop it."""
        return
