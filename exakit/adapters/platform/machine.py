"""What this machine has: memory, free disk (with the WSL backing drive), Rosetta, rootless Podman readiness."""

from __future__ import annotations

import os
import re
from pathlib import Path

from exakit.adapters.process.runner import Runner
from exakit.domain.platform import Platform


def ram_gb(platform: Platform, runner: Runner) -> int:
    """Installed memory in whole GB; 0 when the machine will not say."""
    if platform.os == "macos":
        done = runner.run(["sysctl", "-n", "hw.memsize"], timeout=5)
        return int(done.out.strip()) // 1073741824 if done.ok and done.out.strip().isdigit() else 0
    if platform.os == "windows":
        return _windows_ram_gb()
    try:
        for line in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
            if line.startswith("MemTotal"):
                kb = int(line.split()[1])
                return int(kb / 1048576 + 0.5)
    except (OSError, ValueError, IndexError):
        pass
    return 0


def _windows_ram_gb() -> int:
    """GlobalMemoryStatusEx through ctypes: the figure Task Manager shows, rounded to whole GB."""
    import ctypes

    class MemoryStatus(ctypes.Structure):
        _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong), ("ullTotalPhys", ctypes.c_ulonglong),
                    ("ullAvailPhys", ctypes.c_ulonglong), ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                    ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong), ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]

    status = MemoryStatus()
    status.dwLength = ctypes.sizeof(MemoryStatus)
    try:
        if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)):  # type: ignore[attr-defined]
            return 0
    except (AttributeError, OSError):
        return 0
    return int(status.ullTotalPhys / 1073741824 + 0.5)


def _free_gb_raw(path: Path, runner: Runner) -> int:
    done = runner.run(["df", "-Pk", str(path)], timeout=10)
    lines = done.out.strip().splitlines() if done.ok else []
    if len(lines) < 2:
        return 0
    fields = lines[1].split()
    try:
        return int(fields[3]) // 1048576
    except (IndexError, ValueError):
        return 0


def wsl_backing_drive(platform: Platform, runner: Runner) -> Path | None:
    """The Windows drive a WSL distro's virtual disk lives on, when it is mounted."""
    if not platform.is_wsl:
        return None
    for mount in (Path("/mnt/c"), Path("/mnt/d")):
        if not mount.is_dir():
            continue
        done = runner.run(["df", "-PT", str(mount)], timeout=10)
        lines = done.out.strip().splitlines() if done.ok else []
        if len(lines) >= 2 and lines[1].split()[1:2] and lines[1].split()[1] in ("drvfs", "9p", "virtiofs"):
            return mount
    return None


def free_disk_gb(platform: Platform, runner: Runner, path: Path) -> int:
    """Free space at the path; on WSL the smaller of that and the Windows drive behind the virtual disk."""
    here = _free_gb_raw(path, runner)
    drive = wsl_backing_drive(platform, runner)
    if drive is None or str(path).startswith("/mnt/"):
        return here
    backing = _free_gb_raw(drive, runner)
    return min(here, backing) if backing > 0 else here


def free_disk_note(platform: Platform, runner: Runner, path: Path) -> str | None:
    """A note about where the free disk really is (WSL's backing drive), or None."""
    drive = wsl_backing_drive(platform, runner)
    if drive is None or str(path).startswith("/mnt/"):
        return None
    here, backing = _free_gb_raw(path, runner), _free_gb_raw(drive, runner)
    if backing <= 0 or backing >= here:
        return None
    return f"this distro's virtual disk reports {here} GB free, but it is a sparse file on {drive}, which has {backing} GB - that is the real limit"


def wsl_drvfs_path(platform: Platform, runner: Runner, path: Path) -> bool:
    """True when the path is on a Windows drive mounted into WSL (no Linux permissions there)."""
    if not platform.is_wsl:
        return False
    if re.match(r"^/mnt/[A-Za-z](/|$)", str(path)):
        return True
    done = runner.run(["df", "-P", str(path)], timeout=10)
    lines = done.out.strip().splitlines() if done.ok else []
    source = lines[1].split()[0] if len(lines) >= 2 and lines[1].split() else ""
    return bool(re.match(r"^[A-Za-z]:", source)) or "drvfs" in source.lower()


def macos_translated(platform: Platform, runner: Runner) -> bool:
    """True when this shell runs under Rosetta 2 and reports itself as Intel."""
    if platform.os != "macos":
        return False
    done = runner.run(["sysctl", "-n", "sysctl.proc_translated"], timeout=5)
    return done.ok and done.out.strip() == "1"


def cpu_advertises_sve(platform: Platform) -> bool:
    """True when an arm64 Linux CPU advertises SVE (which the database needs off)."""
    if platform.os != "linux" or platform.arch != "aarch64":
        return False
    try:
        for line in Path("/proc/cpuinfo").read_text(encoding="utf-8").splitlines():
            if line.startswith("Features"):
                return bool(re.search(r"(^| )sve", line))
    except OSError:
        pass
    return False


def rootless_podman_gap(platform: Platform, runner: Runner) -> tuple[str, str] | None:
    """(kind, why) when rootless Podman cannot work for this user: subid | uidmap | cgroups; None when it can."""
    if platform.os == "macos" or os.geteuid() == 0:
        return None
    user = os.environ.get("USER") or runner.run(["id", "-un"], timeout=5).out.strip()
    if not user:
        return None
    for file in ("/etc/subuid", "/etc/subgid"):
        try:
            text = Path(file).read_text(encoding="utf-8")
        except OSError:
            continue
        if not any(line.startswith(f"{user}:") for line in text.splitlines()):
            return "subid", (f"no user-namespace range for {user} in {file} - add one with: sudo usermod --add-subuids 100000-165535 "
                             f"--add-subgids 100000-165535 {user} && podman system migrate")
    if not runner.which("newuidmap"):
        return "uidmap", ("the setuid helper newuidmap is missing, so rootless Podman cannot map your subuid range - install it with your "
                          "package manager (Debian/Ubuntu: sudo apt-get install uidmap; Fedora/RHEL: sudo dnf install shadow-utils; "
                          "Arch: sudo pacman -S shadow; Alpine: sudo apk add shadow-uidmap)")
    if not Path("/sys/fs/cgroup/cgroup.controllers").is_file():
        why = "cgroups v2 is not mounted, so rootless Podman cannot limit or track containers"
        if platform.is_wsl:
            why += " - enable it with a [boot] systemd=true line in /etc/wsl.conf, then restart the distro (wsl --shutdown from PowerShell)"
        return "cgroups", why
    return None


def podman_install_command(runner: Runner) -> str | None:
    """The package-manager line that installs Podman here, or None when the manager is not one the kit knows."""
    table = (("apt-get", "apt-get install -y podman uidmap"), ("dnf", "dnf install -y podman"), ("yum", "yum install -y podman"),
             ("zypper", "zypper install -y podman"), ("pacman", "pacman -S --noconfirm podman"), ("apk", "apk add --no-cache podman"))
    for tool, command in table:
        if runner.which(tool):
            return command
    return None


def podman_install_command_unattended(command: str) -> str:
    """The Podman install command with its prompts answered."""
    if command.startswith("apt-get"):
        return (f"DEBIAN_FRONTEND=noninteractive apt-get update -qq </dev/null && DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a "
                f"NEEDRESTART_SUSPEND=1 {command} -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold </dev/null")
    return f"{command} </dev/null"


def uidmap_install_command(runner: Runner) -> str | None:
    """The command that installs uidmap here, or None."""
    table = (("apt-get", "apt-get install -y uidmap"), ("dnf", "dnf install -y shadow-utils"), ("zypper", "zypper install -y shadow"),
             ("pacman", "pacman -S --noconfirm shadow"))
    for tool, command in table:
        if runner.which(tool):
            return command
    return None
