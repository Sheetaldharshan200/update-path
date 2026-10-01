"""Start-at-login registration per OS: launchd, systemd --user, the Windows Startup folder.

One label per service, ``com.exasol.exakit.<id>``. A ``handoff`` service
runs once and hands the work to something else (the database launcher); a
``longrunning`` one is kept alive.
"""

from __future__ import annotations

import shlex
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol
from xml.sax.saxutils import escape

from exakit.adapters.fs.atomic import atomic_write_text
from exakit.adapters.fs.log import Log, NullLog
from exakit.domain.platform import Platform

from .runner import Runner

PREFIX = "com.exasol.exakit"


@dataclass(frozen=True, slots=True)
class ServiceSpec:
    id: str
    argv: tuple[str, ...]
    kind: str = "longrunning"      # longrunning | handoff

    @property
    def label(self) -> str:
        """The service's name as the OS sees it."""
        return f"{PREFIX}.{self.id}"


@dataclass(frozen=True, slots=True)
class RegisterOutcome:
    ok: bool
    notes: tuple[str, ...] = ()


class Services(Protocol):
    def register(self, spec: ServiceSpec) -> RegisterOutcome: ...
    def unregister(self, service_id: str) -> bool: ...
    def registered(self, service_id: str) -> bool: ...


class LaunchdServices:
    def __init__(self, agents_dir: Path, logs_dir: Path, runner: Runner, log: Log | None = None) -> None:
        self.agents_dir, self.logs_dir, self.runner, self.log = agents_dir, logs_dir, runner, log or NullLog()

    def _plist(self, service_id: str) -> Path:
        return self.agents_dir / f"{PREFIX}.{service_id}.plist"

    def register(self, spec: ServiceSpec) -> RegisterOutcome:
        """Install the login item for the service; the outcome says whether it took and why not."""
        plist = self._plist(spec.id)
        log_path = self.logs_dir / f"autostart-{spec.id}.log"
        args = "".join(f"      <string>{escape(a)}</string>\n" for a in spec.argv)
        atomic_write_text(plist, (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0">\n<dict>\n'
            f"  <key>Label</key><string>{spec.label}</string>\n"
            f"  <key>ProgramArguments</key>\n  <array>\n{args}  </array>\n"
            "  <key>RunAtLoad</key><true/>\n"
            f"  <key>StandardOutPath</key><string>{escape(str(log_path))}</string>\n"
            f"  <key>StandardErrorPath</key><string>{escape(str(log_path))}</string>\n"
            "</dict>\n</plist>\n"), mode=0o644)
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.touch(mode=0o600, exist_ok=True)
        self.runner.run(["launchctl", "unload", str(plist)], timeout=30)
        done = self.runner.run(["launchctl", "load", str(plist)], timeout=30)
        if not done.ok:
            self.log.line("ERROR", f"launchctl load {plist}: {done.err.strip()}")
            return RegisterOutcome(False, (
                f"{spec.id}: the login entry was written, but launchd refused to load it.",
                f"Nothing will start at login until that is fixed. See what launchd makes of it with: launchctl load {plist}"))
        self.log.line("OK", f"{spec.id}: starts at login ({plist})")
        return RegisterOutcome(True)

    def unregister(self, service_id: str) -> bool:
        """Remove the service's login item; True when one was there."""
        plist = self._plist(service_id)
        if not plist.exists():
            return False
        self.runner.run(["launchctl", "unload", str(plist)], timeout=30)
        plist.unlink(missing_ok=True)
        return True

    def registered(self, service_id: str) -> bool:
        """True when the service has a login item."""
        return self._plist(service_id).exists()


class SystemdUserServices:
    def __init__(self, units_dir: Path, runner: Runner, log: Log | None = None, *, wsl: bool = False) -> None:
        self.units_dir, self.runner, self.log, self.wsl = units_dir, runner, log or NullLog(), wsl

    def _unit(self, service_id: str) -> Path:
        return self.units_dir / f"{PREFIX}.{service_id}.service"

    def _available(self) -> bool:
        return bool(self.runner.which("systemctl")) and self.runner.run(["systemctl", "--user", "show-environment"], timeout=10).ok

    def register(self, spec: ServiceSpec) -> RegisterOutcome:
        """Install the login item for the service; the outcome says whether it took and why not."""
        if not self._available():
            notes = [f"{spec.id}: this session has no systemd --user, so nothing was registered."]
            if self.wsl:
                notes += ["On WSL, systemd is off by default. Turn it on, then register again:",
                          "  1. add to /etc/wsl.conf:  [boot]  systemd=true", "  2. from Windows: wsl --shutdown",
                          "  3. then: exakit autostart", "Until then, start it by hand after a reboot with: exakit start"]
            else:
                notes.append("Start it by hand after a reboot with: exakit start")
            return RegisterOutcome(False, tuple(notes))
        service = ("Type=oneshot\nRemainAfterExit=yes\n" if spec.kind == "handoff" else "Type=simple\nRestart=on-failure\nRestartSec=5\n")
        exec_start = " ".join(shlex.quote(a) if any(c in a for c in ' "\\') else a for a in spec.argv)
        atomic_write_text(self._unit(spec.id), (
            f"[Unit]\nDescription=Exasol Starter Kit: {spec.id}\n\n[Service]\n{service}ExecStart={exec_start}\n\n"
            "[Install]\nWantedBy=default.target\n"), mode=0o644)
        self.runner.run(["systemctl", "--user", "daemon-reload"], timeout=30)
        done = self.runner.run(["systemctl", "--user", "enable", f"{spec.label}.service"], timeout=30)
        if not done.ok:
            return RegisterOutcome(False, (f"Could not enable {spec.label}.service",))
        notes: list[str] = []
        if self.runner.which("loginctl"):
            user = self.runner.run(["id", "-un"], timeout=5).out.strip()
            linger = self.runner.run(["loginctl", "show-user", user, "--property=Linger", "--value"], timeout=10).out.strip()
            if linger != "yes" and not self.runner.run(["loginctl", "enable-linger"], timeout=10).ok:
                notes = [f"{spec.id} starts at login, but only while you stay logged in: enabling lingering was refused.",
                         f"On a headless or shared box, have an admin run: loginctl enable-linger {user}"]
        return RegisterOutcome(True, tuple(notes))

    def unregister(self, service_id: str) -> bool:
        """Remove the service's login item; True when one was there."""
        unit = self._unit(service_id)
        if not unit.exists():
            return False
        self.runner.run(["systemctl", "--user", "disable", f"{PREFIX}.{service_id}.service"], timeout=30)
        unit.unlink(missing_ok=True)
        self.runner.run(["systemctl", "--user", "daemon-reload"], timeout=30)
        return True

    def registered(self, service_id: str) -> bool:
        """True when the service has a login item."""
        if not self._unit(service_id).exists():
            return False
        state = self.runner.run(["systemctl", "--user", "is-enabled", f"{PREFIX}.{service_id}.service"], timeout=10).out.strip()
        return state not in ("disabled", "masked")


class WindowsStartupServices:
    """A ``.cmd`` in the Startup folder; nothing is started now."""

    def __init__(self, startup_dir: Path, log: Log | None = None) -> None:
        self.startup_dir, self.log = startup_dir, log or NullLog()

    def _entry(self, service_id: str) -> Path:
        return self.startup_dir / f"{PREFIX}.{service_id}.cmd"

    def register(self, spec: ServiceSpec) -> RegisterOutcome:
        """Install the login item for the service; the outcome says whether it took and why not."""
        command = " ".join(f'"{a}"' if " " in a else a for a in spec.argv)
        atomic_write_text(self._entry(spec.id), "\r\n".join([
            "@echo off", f"rem Starts {spec.id} at login - written by the Exasol Personal Local Starter Kit.",
            "rem Remove it with: exakit autostart", f'start "" /min {command}', ""]), mode=None)
        return RegisterOutcome(True)

    def unregister(self, service_id: str) -> bool:
        """Remove the service's login item; True when one was there."""
        entry = self._entry(service_id)
        if not entry.exists():
            return False
        entry.unlink()
        return True

    def registered(self, service_id: str) -> bool:
        """True when the service has a login item."""
        return self._entry(service_id).exists()


def for_platform(platform: Platform, *, home: Path, logs_dir: Path, runner: Runner, env: dict[str, str], log: Log | None = None) -> Services:
    """The services adapter for this platform: launchd, a systemd user unit, or the Windows Startup folder."""
    if platform.os == "macos":
        return LaunchdServices(Path(env.get("EXAKIT_LAUNCHAGENT_DIR") or home / "Library" / "LaunchAgents"), logs_dir, runner, log)
    if platform.os == "linux":
        return SystemdUserServices(Path(env.get("EXAKIT_SYSTEMD_USER_DIR") or home / ".config" / "systemd" / "user"),
                                   runner, log, wsl=platform.is_wsl)
    appdata = Path(env.get("APPDATA") or home / "AppData" / "Roaming")
    return WindowsStartupServices(Path(env.get("EXAKIT_STARTUP_DIR") or appdata / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "Startup"), log)
