"""``exakit logs``: every log the kit can show, by target."""

from __future__ import annotations

import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from exakit.domain.errors import BadInput, Failed
from exakit.domain.result import Result

from . import Context
from .machine import addon_installed_version


@dataclass(frozen=True, slots=True)
class LogTarget:
    id: str
    what: str
    path: Path


def targets(ctx: Context) -> list[LogTarget]:
    """The logs the kit knows about here."""
    out: list[LogTarget] = []
    installs = sorted(ctx.paths.logs.glob("install-*.log"), key=lambda p: p.stat().st_mtime) if ctx.paths.logs.is_dir() else []
    if installs:
        out.append(LogTarget("setup", "Installer and setup runs", installs[-1]))
    manifest = ctx.manifest_or_none()
    for addon in ctx.catalog.addons():
        if (manifest and addon_installed_version(ctx, addon, manifest)[1] and addon.service is not None) or addon.id == "json-tables":
            path = ctx.paths.logs / f"{addon.id}.log"
            if manifest and addon_installed_version(ctx, addon, manifest)[1]:
                out.append(LogTarget(addon.id, f"{addon.id} service", path))
    for path in sorted(ctx.paths.logs.glob("autostart-*.log")) if ctx.paths.logs.is_dir() else []:
        service = path.name[len("autostart-"):-len(".log")]
        out.append(LogTarget(f"autostart-{service}", f"{service} at login", path))
    return out


def _size(path: Path) -> str:
    try:
        n = path.stat().st_size
    except OSError:
        return "-"
    return f"{n}B" if n < 1024 else f"{n // 1024}K" if n < 1024 * 1024 else f"{n // (1024 * 1024)}M"


def _updated(path: Path) -> str:
    try:
        return datetime.fromtimestamp(path.stat().st_mtime).strftime("%Y-%m-%d %H:%M")
    except OSError:
        return "-"


def run(ctx: Context, args: list[str]) -> Result:
    """``exakit logs``."""
    follow, path_only, lines, target = _parse_logs_args(args)
    known = targets(ctx)
    if target is None:
        return _list_targets(ctx, known)
    if ctx.json:
        raise BadInput("--json lists the targets; it cannot be combined with a target name.")
    match = [t for t in known if t.id == target]
    if not match:
        if ctx.catalog.has_addon(target):
            raise Failed(f"{target} is not installed - add it with: exakit marketplace {target}", remedy=f"exakit marketplace {target}")
        raise Failed(f"No log called '{target}'. Available: {', '.join(t.id for t in known) or 'none yet'}")
    path = match[0].path
    if path_only:
        ctx.ui.text(str(path))
        return Result(True, "ok")
    if not path.is_file():
        raise Failed(f"The {target} log has not been written yet ({path}).")
    _show(ctx, path, follow=follow, lines=lines)
    return Result(True, "ok")


def _parse_logs_args(args: list[str]) -> tuple[bool, bool, int, str | None]:
    follow, path_only, lines, target = False, False, 200, None
    i = 0
    while i < len(args):
        arg = args[i]
        if arg in ("-f", "--follow"):
            follow = True
        elif arg == "--path":
            path_only = True
        elif arg in ("--json", "-j"):
            pass
        elif arg in ("--lines", "-n"):
            if i + 1 >= len(args) or not args[i + 1].isdigit():
                raise BadInput("--lines needs a number: exakit logs setup --lines 50")
            lines = int(args[i + 1])
            i += 1
        elif arg.startswith("-"):
            raise BadInput(f"Unknown option '{arg}' for logs (supported: -f, --lines N, --path, --json).")
        elif target is None:
            target = arg
        else:
            raise BadInput("logs takes one target at most.")
        i += 1
    return follow, path_only, lines, target


def _list_targets(ctx: Context, known) -> Result:
    rows = [{"target": t.id, "what": t.what, "kind": "file", "path": str(t.path), "command": None,
             "size": _size(t.path), "updated": _updated(t.path)} for t in known]
    if not ctx.json:
        if not rows:
            ctx.ui.info("No logs yet - they appear here once the installer or a service has run.")
        else:
            ctx.ui.heading("Component logs")
            ctx.ui.text(f"  {'Target':<22} {'What':<26} {'Size':<8} Updated")
            for row in rows:
                ctx.ui.text(f"  {row['target']:<22} {row['what']:<26} {row['size']:<8} {row['updated']}")
            ctx.ui.info("Show one: exakit logs <target>   Follow it: exakit logs <target> -f")
    return Result(True, "ok", data={"count": len(rows), "targets": rows}, raw=True)


def _show(ctx: Context, path: Path, *, follow: bool, lines: int) -> None:
    if follow:
        ctx.ui.info(f"Following {path} - Ctrl-C to stop")
        sys.stdout.flush()
        ctx.runner.interactive(["tail", "-n", str(lines), "-f", str(path)])
        return
    text = path.read_text(encoding="utf-8", errors="replace").splitlines()
    ctx.ui.text("\n".join(text[-lines:]))
