"""Atomic file writes: a reader never sees a half-written file.

The temp name is unique, not a fixed ``.tmp``: two writers sharing one name
can interleave inside it, and the loser's rename can publish a truncated
document (a bug the legacy shell fixed the hard way).
"""

from __future__ import annotations

import os
import tempfile
from pathlib import Path
import contextlib


def atomic_write_text(path: Path, text: str, *, mode: int | None = 0o600) -> None:
    """Write ``text`` to ``path`` through a same-directory temp file and one rename."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        if mode is not None:
            os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise
