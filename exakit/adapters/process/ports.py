"""Who is listening on a local TCP port, and what that process is."""

from __future__ import annotations

import re
import socket
from dataclasses import dataclass

from .runner import Runner


def port_in_use(port: int, host: str = "127.0.0.1", timeout: float = 0.7) -> bool:
    """True when something accepts a connection on the port."""
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def listener_pids(port: int, runner: Runner) -> list[int]:
    """Pids listening on the port, through ss, lsof or netstat, whichever exists."""
    if runner.which("lsof"):
        done = runner.run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"], timeout=10)
        return sorted({int(p) for p in done.out.split() if p.isdigit()})
    if runner.which("ss"):
        done = runner.run(["ss", "-ltnp"], timeout=10)
        pids = set()
        for line in done.out.splitlines():
            if re.search(rf":{port}\s", line):
                pids.update(int(m) for m in re.findall(r"pid=(\d+)", line))
        return sorted(pids)
    if runner.which("netstat"):
        done = runner.run(["netstat", "-ltnp"], timeout=10)
        pids = set()
        for line in done.out.splitlines():
            if re.search(rf":{port}\s", line):
                pids.update(int(m) for m in re.findall(r"\s(\d+)/", line))
        return sorted(pids)
    return []


def process_command(pid: int, runner: Runner) -> str:
    """The command line of a process, or an empty string."""
    done = runner.run(["ps", "-o", "command=", "-p", str(pid)], timeout=5)
    return done.out.strip() if done.ok else ""


def process_age_seconds(pid: int, runner: Runner) -> int | None:
    """How long the process has run, from ``ps -o etime``; None when unknown."""
    done = runner.run(["ps", "-o", "etime=", "-p", str(pid)], timeout=5)
    text = done.out.strip()
    if not done.ok or not text:
        return None
    days, _, clock = text.rpartition("-")
    parts = [int(p) for p in clock.split(":") if p.isdigit()]
    seconds = 0
    for part in parts:
        seconds = seconds * 60 + part
    return seconds + (int(days) * 86400 if days.isdigit() else 0)


@dataclass(frozen=True, slots=True)
class PortHolder:
    pid: int
    command: str

    @property
    def description(self) -> str:
        """The holder in words."""
        name = self.command.split()[0].rsplit("/", 1)[-1] if self.command else "unknown"
        return f"pid {self.pid} ({name})"


def port_holders(port: int, runner: Runner) -> list[PortHolder]:
    """The processes listening on a port."""
    return [PortHolder(pid, process_command(pid, runner)) for pid in listener_pids(port, runner)]
