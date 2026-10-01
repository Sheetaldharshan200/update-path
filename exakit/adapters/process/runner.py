"""Running other programs: the only place ``subprocess`` is imported for tool calls."""

from __future__ import annotations

import os
import shutil
import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol


@dataclass(frozen=True, slots=True)
class Completed:
    code: int
    out: str
    err: str

    @property
    def ok(self) -> bool:
        """True when the exit code is zero."""
        return self.code == 0


class Runner(Protocol):
    def run(self, cmd: Sequence[str], *, env: Mapping[str, str] | None = None, cwd: Path | None = None,
            timeout: float | None = None, stdin: str | None = None) -> Completed: ...
    def which(self, name: str) -> str | None: ...
    def interactive(self, cmd: Sequence[str], *, env: Mapping[str, str] | None = None) -> int: ...
    def spawn(self, cmd: Sequence[str], *, log_path: Path) -> int: ...


class SubprocessRunner:
    """Captures both streams, never raises on a non-zero exit, times out with code 124."""

    def run(self, cmd: Sequence[str], *, env: Mapping[str, str] | None = None, cwd: Path | None = None,
            timeout: float | None = None, stdin: str | None = None) -> Completed:
        """Run a command and capture both streams; a timeout answers code 124."""
        full_env = dict(os.environ)
        if env:
            full_env.update(env)
        try:
            done = subprocess.run(list(cmd), env=full_env, cwd=str(cwd) if cwd else None, timeout=timeout,
                                  input=stdin, capture_output=True, text=True, check=False)
        except FileNotFoundError:
            return Completed(127, "", f"{cmd[0]}: not found")
        except subprocess.TimeoutExpired:
            return Completed(124, "", f"{cmd[0]}: timed out after {timeout}s")
        except OSError as err:
            return Completed(126, "", str(err))
        return Completed(done.returncode, done.stdout, done.stderr)

    def which(self, name: str) -> str | None:
        """The path of a command on PATH, or None."""
        return shutil.which(name)

    def spawn(self, cmd: Sequence[str], *, log_path: Path) -> int:
        """Start a daemon in its own session, both streams appended to ``log_path``; the pid is the answer."""
        log_path.parent.mkdir(parents=True, exist_ok=True)
        detached = {"creationflags": subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt" else {"start_new_session": True}
        with log_path.open("a", encoding="utf-8") as log:
            child = subprocess.Popen(list(cmd), stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, **detached)
        return child.pid

    def interactive(self, cmd: Sequence[str], *, env: Mapping[str, str] | None = None) -> int:
        """Run with the terminal attached (a password prompt, a licence screen); the exit code is the answer."""
        full_env = dict(os.environ)
        if env:
            full_env.update(env)
        try:
            return subprocess.call(list(cmd), env=full_env)
        except FileNotFoundError:
            return 127
        except OSError:
            return 126
