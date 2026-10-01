"""The once-a-day pending-update notice printed after a command, on stderr, on a terminal only."""

from __future__ import annotations

import json
import sys
import time

from exakit.adapters.fs.atomic import atomic_write_text
from exakit.domain.versions import VersionPolicy

from . import Context
from .version import HEAVY, rows
import contextlib

NOTICED_AFTER = frozenset({
    "status", "info", "guide", "start", "stop", "data-load", "preflight", "skills", "skills-install",
    "marketplace", "persona", "autostart", "logs", "mcp-setup", "mcp-doctor", "mcp-status",
})


def _due(ctx: Context) -> bool:
    state = ctx.paths.cache / "notice-state.json"
    interval_text = ctx.env.get("EXAKIT_NOTICE_INTERVAL", "")
    interval = int(interval_text) if interval_text.isdigit() else ctx.catalog.kit.notice_interval
    try:
        last = int(json.loads(state.read_text(encoding="utf-8")).get("last_shown", 0))
    except (OSError, ValueError, AttributeError, TypeError):
        return True
    return time.time() - last >= interval


def _record(ctx: Context) -> None:
    with contextlib.suppress(OSError):
        atomic_write_text(ctx.paths.cache / "notice-state.json", json.dumps({"last_shown": int(time.time())}) + "\n", mode=0o644)


def maybe_show(ctx: Context, command: str) -> None:
    """Never under --json, never off a terminal, never more than once a day."""
    if ctx.json or command not in NOTICED_AFTER or ctx.env.get("EXAKIT_NO_UPDATE_NOTICE") == "1":
        return
    if ctx.policy is not VersionPolicy.MANIFEST or not sys.stderr.isatty() or not ctx.manifest_store.exists():
        return
    if not _due(ctx):
        return
    try:
        ctx.versions.refresh()
        table = rows(ctx, refresh=False)
    except Exception:
        return
    light = [r for r in table if r.status == "update_available" and r.component not in HEAVY]
    heavy = [r for r in table if r.status == "update_available" and r.component in HEAVY]
    if not light and not heavy:
        return
    sys.stderr.write("\n")
    if light:
        names = ", ".join(r.component for r in light)
        word = "A critical" if any(r.severity == "critical" for r in light) else "A recommended" if any(r.severity == "recommended" for r in light) else "An"
        sys.stderr.write(f"{word} update is available for {names} - apply in seconds:  exakit update\n")
    if heavy:
        names = ", ".join(r.component for r in heavy)
        sys.stderr.write(f"An update is available for {names} - requires stopping the database, details:  exakit version\n")
    sys.stderr.flush()
    _record(ctx)
