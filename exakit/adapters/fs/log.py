"""One log file per run, in the legacy format (``YYYY-MM-DD HH:MM:SS LEVEL message``).

Logging never fails a command: a missing directory (uninstall removes the
kit home mid-run) silently stops the log.
"""

from __future__ import annotations

import os
from datetime import datetime
from pathlib import Path

from exakit.domain.log import Log, NullLog

__all__ = ["FileLog", "Log", "NullLog"]


class FileLog:
    """Appends to a file under the logs directory, created on first use."""

    def __init__(self, logs_dir: Path, *, prefix: str = "install", path: Path | None = None) -> None:
        self.path = path or logs_dir / f"{prefix}-{datetime.now().strftime('%Y%m%d-%H%M%S')}.log"

    def line(self, level: str, message: str) -> None:
        """Append one line; a missing directory ends the log silently."""
        if self.path is None:
            return
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            fresh = not self.path.exists()
            with self.path.open("a", encoding="utf-8") as handle:
                handle.write(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} {level:<5} {message}\n")
            if fresh:
                os.chmod(self.path, 0o600)
        except OSError:
            self.path = None
