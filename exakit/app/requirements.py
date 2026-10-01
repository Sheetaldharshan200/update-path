"""Can this machine run the kit? The compatibility gate, Podman on Linux, and the read-only preflight report."""

from __future__ import annotations

import os
from pathlib import Path

from exakit.adapters.fs.notes import write_failure_note
from exakit.adapters.platform import machine
from exakit.domain.errors import Failed
from exakit.domain.manifest import utc_now
from exakit.domain.result import Result

from . import Context
from .runtime_ops import runtime



def user_home(ctx: Context) -> Path:
    """The user's home directory, as the environment names it."""
    return Path(ctx.env.get("HOME") or Path.home())


def note_failure(ctx: Context, reason: str) -> None:
    """Leave the failure note status shows."""
    write_failure_note(ctx.paths.failure_note, reason, utc_now())


def _refuse(ctx: Context, message: str, *lines: str, reason: str) -> Failed:
    ctx.ui.error(message)
    for line in lines:
        ctx.ui.info(line)
    return Failed(reason)


PLATFORM_WORDS = {"macos-aarch64": "macOS on Apple silicon", "macos-x86_64": "macOS on Intel", "linux-x86_64": "Linux x86_64",
                  "linux-aarch64": "Linux arm64 (native or WSL 2)", "windows-x86_64": "Windows x86_64", "windows-aarch64": "Windows arm64"}


def supported_platforms(ctx: Context) -> tuple[str, ...]:
    """The platform keys the local database runs on: the Personal component's catalog entry."""
    return ctx.catalog.component("personal").platforms


def platform_words(keys: tuple[str, ...]) -> str:
    """The platform keys in words, comma-separated."""
    return ", ".join(PLATFORM_WORDS.get(k, k) for k in keys)


def this_platform_word(ctx: Context) -> str:
    """This machine's platform in words."""
    p = ctx.platform
    return PLATFORM_WORDS.get(p.platform_key, f"{p.os}/{p.arch}") + (" under WSL" if p.is_wsl else "")


def _check_platform(ctx: Context) -> None:
    p = ctx.platform
    supported = supported_platforms(ctx)
    if supported and p.platform_key not in supported:
        raise _refuse(ctx, f"The local Exasol database runs on {platform_words(supported)}. This machine is {this_platform_word(ctx)}, "
                      "so the database cannot run here.",
                      "Nothing was installed. Use a supported machine for the local database, or point the kit's tools at an Exasol "
                      "database elsewhere (exapump and the MCP server take any DSN).",
                      reason=f"Unsupported platform for the local database: {this_platform_word(ctx)}.")
    if p.is_wsl and p.wsl_version == 1:
        raise _refuse(ctx, "This is a WSL 1 distro. Exasol Personal runs the database in a container, and WSL 1 has no Linux kernel to run one with.",
                      "Convert this distro to WSL 2, from PowerShell on the Windows side:",
                      "  wsl --list --verbose          (find this distro's name and see its version)",
                      "  wsl --set-version <distro> 2  (converts it; your files are kept)",
                      f"Then reopen the distro and re-run the installer: {ctx.install_command()}",
                      reason="WSL 1 is not supported: Exasol Personal needs a real Linux kernel.")
    if p.arch not in ("aarch64", "x86_64"):
        raise _refuse(ctx, f"This machine is not compatible: no Exasol Personal build exists for the '{p.arch}' CPU architecture.",
                      "Supported architectures: Apple Silicon (arm64) and Intel (x86_64).", reason=f"Incompatible CPU architecture: {p.arch}.")


def _check_resources(ctx: Context, ram: int, disk: int) -> None:
    if ctx.env.get("EXAKIT_FORCE") == "1":
        return
    if ram == 0:
        raise Failed("Could not determine this machine's memory. Fix the environment or set EXAKIT_FORCE=1 to install anyway.")
    if ram < ctx.catalog.kit.min_ram_gb:
        ctx.ui.error(f"This machine is not compatible: Exasol Personal needs at least {ctx.catalog.kit.min_ram_gb} GB RAM and this machine has {ram} GB.")
        if ctx.platform.is_wsl:
            for line in ("That is what WSL was given, not what this PC has. Raise it in %USERPROFILE%\\.wslconfig on the WINDOWS side:",
                         "  [wsl2]", "  memory=8GB", "Then apply it from PowerShell: wsl --shutdown  (reopen this distro afterwards)",
                         "Already sized correctly? Force past this check with EXAKIT_FORCE=1."):
                ctx.ui.info(line)
        else:
            ctx.ui.info(f"Nothing was installed. Re-run on a machine with {ctx.catalog.kit.min_ram_gb}+ GB RAM (or force at your own risk with EXAKIT_FORCE=1).")
        raise Failed(f"Insufficient memory: {ram} GB.")
    if disk == 0:
        raise Failed(f"Could not determine free disk space at {user_home(ctx)}. Free up space or set EXAKIT_FORCE=1 to install anyway.")
    if disk < ctx.catalog.kit.min_disk_gb:
        ctx.ui.error(f"This machine is not compatible right now: the database needs at least {ctx.catalog.kit.min_disk_gb} GB free disk and {user_home(ctx)} has {disk} GB.")
        note = machine.free_disk_note(ctx.platform, ctx.runner, user_home(ctx))
        if note:
            ctx.ui.info(f"Why: {note}")
        ctx.ui.info("Nothing was installed. Free up disk space and re-run (or force at your own risk with EXAKIT_FORCE=1).")
        raise Failed(f"Insufficient free disk space: {disk} GB.")


def check(ctx: Context) -> None:
    """The legacy compatibility gate: platform, architecture, memory, disk, Podman on Linux."""
    _check_platform(ctx)
    if ctx.platform.os == "linux" and not ctx.runner.which("podman") and not podman_installable(ctx):
        where = "in WSL" if ctx.platform.is_wsl else "on Linux"
        ctx.ui.warn(f"Podman is not installed {where}, and the kit cannot install it on this machine.")
        ctx.ui.info("The database step will be skipped; everything that does not need it still installs.")
        if ctx.platform.is_wsl:
            ctx.ui.info(f"Install it inside this distro (Debian/Ubuntu: 'sudo apt-get install -y podman uidmap'), then re-run the installer: {ctx.install_command()}")
            ctx.ui.info("Podman Desktop or Docker Desktop on the WINDOWS side does not count - the launcher runs in here and looks on this PATH.")
        else:
            ctx.ui.info(f"Install it with your package manager (e.g. 'sudo apt-get install -y podman' or 'sudo dnf install -y podman'), then re-run the installer: {ctx.install_command()}")
    if ctx.platform.os == "linux" and ctx.runner.which("podman"):
        heal_rootless_podman(ctx)
    ram = machine.ram_gb(ctx.platform, ctx.runner)
    disk = machine.free_disk_gb(ctx.platform, ctx.runner, user_home(ctx))
    _check_resources(ctx, ram, disk)
    wanted_port = ctx.env.get("EXAKIT_DB_PORT")
    if wanted_port and wanted_port != str(runtime(ctx).db_port()):
        ctx.ui.warn(f"EXAKIT_DB_PORT does not choose the port of an Exasol Personal deployment: the launcher selects it and the kit uses whatever it selected (currently {runtime(ctx).db_port()}).")
    if ram < ctx.catalog.kit.comfort_ram_gb:
        ctx.ui.warn(f"Memory is at the bare minimum ({ram} GB; comfortable: {ctx.catalog.kit.comfort_ram_gb}+ GB) - the database will run, but expect slower queries and keep other heavy apps closed.")
    if disk < ctx.catalog.kit.comfort_disk_gb:
        ctx.ui.warn(f"Free disk is tight ({disk} GB; comfortable: {ctx.catalog.kit.comfort_disk_gb}+ GB) - fine for the bundled datasets, but watch space before loading large files.")
    word = "wsl" if ctx.platform.is_wsl else ctx.platform.os
    ctx.ui.ok(f"Compatibility check passed ({word} {ctx.platform.arch}, {ram} GB RAM, {disk} GB free)")


# --- Podman on Linux --------------------------------------------------------------------


def _is_root() -> bool:
    return hasattr(os, "geteuid") and os.geteuid() == 0


def podman_installable(ctx: Context) -> bool:
    """True when the kit knows how to install Podman here."""
    return bool(machine.podman_install_command(ctx.runner)) and (_is_root() or bool(ctx.runner.which("sudo")))


def install_podman(ctx: Context) -> bool:
    """Podman through the package manager, as administrator; False (with the note) when it cannot be."""
    if ctx.runner.which("podman") or ctx.platform.os != "linux":
        return True
    command = machine.podman_install_command(ctx.runner)
    where = "inside this distro" if ctx.platform.is_wsl else "on this machine"
    ctx.ui.warn(f"Podman is not installed {where}, and the database runs through it.")
    if not command:
        ctx.ui.info("This machine's package manager is not one the kit knows, so install Podman yourself and re-run.")
        note_failure(ctx, "Podman is not installed and the kit does not know this machine's package manager")
        return False
    sudo = "" if _is_root() else "sudo "
    if sudo and not ctx.runner.which("sudo"):
        ctx.ui.info(f"The kit can install it, but 'sudo' is not on PATH. Run this as root, then re-run the installer:\n  {command}")
        note_failure(ctx, f"Podman is not installed and 'sudo' is not on PATH ({command})")
        return False
    if ctx.env.get("EXAKIT_INSTALL_PODMAN", "").lower() in ("0", "n", "no"):
        ctx.ui.info(f"Not installed (EXAKIT_INSTALL_PODMAN=0). To do it yourself:  {sudo}{command}")
        note_failure(ctx, "Podman was not installed (EXAKIT_INSTALL_PODMAN=0); the database needs it")
        return False
    if sudo and not _sudo_ready(ctx, command):
        return False
    prefix = ["sudo", "-n"] if sudo else []
    with ctx.ui.busy("Installing Podman"):
        done = ctx.runner.run([*prefix, "sh", "-c", machine.podman_install_command_unattended(command)], timeout=1800)
    if not done.ok:
        ctx.log.line("ERR", (done.err or done.out).strip()[-600:])
        ctx.ui.info(f"Run it yourself and re-run the installer:  {sudo}{command}")
        note_failure(ctx, f"Podman could not be installed ({sudo}{command})")
        return False
    if not ctx.runner.which("podman"):
        ctx.ui.warn("The install reported success, but 'podman' is still not on PATH.")
        ctx.ui.info("Open a new shell and re-run the installer.")
        note_failure(ctx, "Podman installed but not on PATH in this shell")
        return False
    version = (ctx.runner.run(["podman", "--version"], timeout=10).out.strip().splitlines() or [""])[0]
    ctx.ui.ok(f"Podman installed ({version})")
    heal_rootless_podman(ctx)
    return True


def _sudo_ready(ctx: Context, command: str) -> bool:
    """A cached sudo, or the password typed on a terminal; False (with the note) when neither is possible."""
    if ctx.runner.run(["sudo", "-n", "true"], timeout=10).ok:
        return True
    if not ctx.ui.interactive:
        ctx.ui.info(f"This run has no terminal to type an administrator password on. Run it yourself, then re-run:  sudo {command}")
        note_failure(ctx, "Podman needs an administrator password and this run has no terminal to ask for one")
        return False
    ctx.ui.info("Your password, to install Podman as administrator (this grants sudo for the rest of its usual timeout):")
    if ctx.runner.interactive(["sudo", "-v"]) != 0:
        ctx.ui.info(f"Not installed. To do it yourself:  sudo {command}")
        note_failure(ctx, "The administrator password for the Podman install was not given")
        return False
    return True


def heal_rootless_podman(ctx: Context) -> None:
    """Fix the rootless-Podman gaps the kit can fix (uidmap, subuid ranges)."""
    gap = machine.rootless_podman_gap(ctx.platform, ctx.runner)
    if gap is None:
        return
    kind, why = gap
    if kind == "cgroups":
        ctx.ui.warn(f"Rootless Podman: {why}")
        return
    user = ctx.env.get("USER") or ctx.runner.run(["id", "-un"], timeout=5).out.strip()
    if kind == "subid":
        fix, what = f"usermod --add-subuids 100000-165535 --add-subgids 100000-165535 {user}", f"add a user-namespace range for {user}"
    else:
        fix, what = machine.uidmap_install_command(ctx.runner) or "", "install the uidmap package rootless Podman needs"
        if not fix:
            ctx.ui.warn(f"Rootless Podman: {why}")
            return
    ctx.ui.warn(f"Rootless Podman is not ready: {why}")
    if not ctx.runner.which("sudo"):
        ctx.ui.info(f"The kit can fix this, but 'sudo' is not on PATH. Run this as root, then re-run the installer:\n  {fix}")
        return
    answer = ctx.env.get("EXAKIT_PODMAN_SELFHEAL", "").lower()
    if answer in ("0", "n", "no") or (answer not in ("1", "y", "yes") and (not ctx.ui.interactive or not ctx.ui.confirm(
            f"Let the kit {what}? It runs a command as administrator and will ask for your password", default=True))):
        ctx.ui.info(f"Not changed. To do it yourself:  sudo {fix}")
        return
    if ctx.runner.interactive(["sudo", "sh", "-c", fix]) != 0:
        ctx.ui.warn(f"That did not work - run it yourself:  sudo {fix}")
        return
    if kind == "subid":
        ctx.runner.run(["podman", "system", "migrate"], timeout=120)
    ctx.ui.ok("Rootless Podman is ready")


def podman_running(ctx: Context) -> bool:
    """True when Podman answers on Linux."""
    if ctx.platform.os != "linux" or not ctx.runner.which("podman"):
        return True
    rt = runtime(ctx)
    ok, said = rt.podman_answers()
    if ok:
        return True
    heal_rootless_podman(ctx)
    ok, said = rt.podman_answers()
    if ok:
        return True
    ctx.ui.warn("Podman is installed, but it cannot run containers on this machine.")
    if said:
        ctx.ui.info(f"What it said: {said}")
    ctx.ui.info(f"Check it with 'podman info'; once that answers, re-run the installer to finish the install: {ctx.install_command()}")
    note_failure(ctx, f"Podman is installed but not usable ('podman info' failed): {said or 'no output'}")
    return False


# --- the preflight report -----------------------------------------------------------------


def preflight(ctx: Context) -> Result:
    """``exakit preflight``: one line per check, nothing written; exit 1 when anything blocks an install."""
    failures: list[str] = []
    notes: list[str] = []
    p = ctx.platform

    def ok(text: str) -> None:
        ctx.ui.text(f"  [ok] {text}")

    def bad(text: str) -> None:
        ctx.ui.text(f"  [x] {text}")
        failures.append(text)

    def note(text: str) -> None:
        ctx.ui.text(f"  - {text}")
        notes.append(text)

    ctx.ui.text("Preflight check")
    _preflight_platform(ctx, ok, bad, note)
    ram, disk = machine.ram_gb(p, ctx.runner), machine.free_disk_gb(p, ctx.runner, user_home(ctx))
    ok(f"Memory: {ram} GB (Exasol Personal needs {ctx.catalog.kit.min_ram_gb}+)") if ram >= ctx.catalog.kit.min_ram_gb else bad(f"Memory: {ram} GB - Exasol Personal needs at least {ctx.catalog.kit.min_ram_gb} GB")
    ok(f"Free disk at {user_home(ctx)}: {disk} GB ({ctx.catalog.kit.min_disk_gb}+ recommended)") if disk >= ctx.catalog.kit.min_disk_gb else \
        bad(f"Free disk at {user_home(ctx)}: {disk} GB - free up space ({ctx.catalog.kit.min_disk_gb} GB recommended for the local database)")
    disk_note = machine.free_disk_note(p, ctx.runner, user_home(ctx))
    if disk_note:
        note(f"Free disk: {disk_note}")
    for tool in ("curl", "tar", "bash"):
        ok(f"{tool} available") if ctx.runner.which(tool) else bad(f"{tool} missing - install it with your package manager")
    ok("the kit's managed Python runtime is in use (no system Python needed)")
    _preflight_linux(ctx, ok, bad)
    ctx.ui.text("")
    if failures:
        ctx.ui.text(f"{len(failures)} check(s) failed - fix them, then run the installer.")
    else:
        ctx.ui.text("Ready to install.")
    return Result(True, "ready" if not failures else "blocked", data={"failures": failures, "notes": notes}, exit_code=0 if not failures else 1)


def _preflight_platform(ctx: Context, ok, bad, note) -> None:
    p = ctx.platform
    word = "wsl" if p.is_wsl else p.os
    ok(f"Operating system: {word}") if p.os in ("macos", "linux", "windows") else bad(f"Operating system: {p.os} is not supported")
    if machine.macos_translated(p, ctx.runner):
        note("This shell is running under Rosetta 2, so it reports itself as Intel. The kit has looked past that and will install the native arm64 build.")
    ok(f"CPU architecture: {p.arch}") if p.arch in ("aarch64", "x86_64") else bad(f"CPU architecture: {p.arch} is not supported (arm64 or x86_64 required)")
    supported = supported_platforms(ctx)
    if supported and p.platform_key not in supported:
        bad(f"Platform: {this_platform_word(ctx)} - the local Exasol database runs on {platform_words(supported)} only")
    if machine.wsl_drvfs_path(p, ctx.runner, ctx.paths.home):
        bad(f"Kit home {ctx.paths.home} is on a Windows drive: WSL mounts those without Linux file permissions, so the database passwords stored there "
            "cannot be protected - set EXAKIT_HOME to a path on the Linux filesystem, e.g. EXAKIT_HOME=$HOME/.exasol-starter-kit")


def _preflight_linux(ctx: Context, ok, bad) -> None:
    p = ctx.platform
    if p.is_wsl and p.wsl_version == 1:
        bad("WSL 1: Exasol Personal needs a real Linux kernel to run containers, and WSL 1 does not have one. Convert this distro from PowerShell: "
            "wsl --set-version <distro> 2   then re-run the installer.")
        return
    if p.os != "linux":
        return
    if ctx.runner.which("podman"):
        ok("Podman: available (the Exasol Personal deployment runs through it)")
        gap = machine.rootless_podman_gap(p, ctx.runner)
        if gap:
            bad(f"Rootless Podman: {gap[1]}")
    elif p.is_wsl:
        bad("Podman is required and is not on PATH inside this distro - install it here (Debian/Ubuntu: 'sudo apt-get install -y podman uidmap'); "
            "Podman or Docker Desktop on the Windows side does not count")
    else:
        bad("Podman is required on Linux and is not on PATH - install it with your package manager (e.g. 'sudo apt-get install -y podman' or 'sudo dnf install -y podman')")
