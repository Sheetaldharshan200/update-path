"""The failure note (``.last-failure``) and the install lock's holder: two files the state queries read."""

from __future__ import annotations

from pathlib import Path

from exakit.adapters.process.runner import Runner
import contextlib

RUNTIME_NOTE_WORDS = ("exakit start", "cannot start", "held by another process", "not running")


def read_failure_note(path: Path) -> tuple[str | None, str | None]:
    """(reason, timestamp) from the note, or (None, None). Line 1 is the reason, line 2 when it happened."""
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return None, None
    reason = lines[0].strip() if lines else ""
    when = lines[1].strip() if len(lines) > 1 else ""
    return (reason or None), (when or None)


def write_failure_note(path: Path, reason: str, when: str) -> None:
    """Leave the note status reads after a failed run."""
    if not path.parent.is_dir():
        return
    with contextlib.suppress(OSError):
        path.write_text(f"{reason}\n{when}\n", encoding="utf-8")


def clear_failure_note(path: Path) -> None:
    """Remove the note."""
    path.unlink(missing_ok=True)


def clear_runtime_failure_note(path: Path) -> bool:
    """Retire the note only when it is about the database not starting; an install-step note stays."""
    reason, _ = read_failure_note(path)
    if reason and any(word in reason for word in RUNTIME_NOTE_WORDS):
        path.unlink(missing_ok=True)
        return True
    return False


def process_start_time(pid: int, runner: Runner) -> str:
    """When a process started, as ps prints it."""
    done = runner.run(["ps", "-o", "lstart=", "-p", str(pid)], timeout=5)
    return done.out.strip().splitlines()[0].strip() if done.ok and done.out.strip() else ""


def lock_holder_alive(path: Path, runner: Runner) -> bool:
    """True only when the pid in the lock is alive AND (when the lock recorded one) started when the lock says."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return False
    pid = lines[0].strip() if lines else ""
    started = lines[1].strip() if len(lines) > 1 else ""
    if not pid.isdigit() or not runner.run(["kill", "-0", pid], timeout=5).ok:
        return False
    return not started or process_start_time(int(pid), runner) == started
