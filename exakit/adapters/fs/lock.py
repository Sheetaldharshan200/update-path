"""A cross-process file lock, standard library only, on every platform the kit runs on."""

from __future__ import annotations

import os
import time
from pathlib import Path
from types import TracebackType

from exakit.domain.errors import Failed

if os.name == "nt":  # pragma: no cover - exercised on Windows CI
    import msvcrt

    def _lock(fd: int) -> None:
        msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)

    def _unlock(fd: int) -> None:
        msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
else:
    import fcntl

    def _lock(fd: int) -> None:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def _unlock(fd: int) -> None:
        fcntl.flock(fd, fcntl.LOCK_UN)


class FileLock:
    """``with FileLock(path): ...`` holds an exclusive lock, waiting up to ``timeout`` seconds."""

    def __init__(self, path: Path, *, timeout: float = 30.0, poll: float = 0.05) -> None:
        self.path = path
        self.timeout = timeout
        self.poll = poll
        self._fd: int | None = None

    def __enter__(self) -> FileLock:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._fd = os.open(str(self.path), os.O_RDWR | os.O_CREAT, 0o600)
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                _lock(self._fd)
                return self
            except OSError:
                if time.monotonic() >= deadline:
                    os.close(self._fd)
                    self._fd = None
                    raise Failed(
                        f"Another exakit process holds {self.path.name}; try again in a moment.",
                        hint="a previous install or update may still be running (exakit status shows it)",
                    ) from None
                time.sleep(self.poll)

    def __exit__(self, exc_type: type[BaseException] | None, exc: BaseException | None, tb: TracebackType | None) -> None:
        if self._fd is not None:
            try:
                _unlock(self._fd)
            finally:
                os.close(self._fd)
                self._fd = None
