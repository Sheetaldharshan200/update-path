"""``exakit start``, ``stop`` and ``autostart``: the database and every service add-on, in the right order."""

from __future__ import annotations

from exakit.adapters.fs.notes import clear_runtime_failure_note
from exakit.domain.errors import BadInput, ExakitError, Failed
from exakit.domain.result import Result

from . import Context, services
from .runtime_ops import ensure_running, is_running, runtime


def _start_database(ctx: Context) -> None:
    """Self-heal semantics: a stopped database is started, a missing one deployed, an orphan of ours reaped first."""
    manifest = ctx.manifest()
    if manifest.runtime_type() != "personal":
        ensure_running(ctx, deploy=True)
        return
    rt = runtime(ctx)
    state = rt.status()
    if state.state == "running":
        ctx.ui.ok("Database is already running")
        return
    if state.state == "starting":
        ctx.ui.ok("The database is already starting - give it a moment.")
        ctx.ui.info("Watch it come up with: exakit status   (it answers 'running' when ready)")
        return
    if state.state == "conflict" and not rt.reap_orphan(state.port, ctx.ui.info):
        hint = f" ({state.detail})" if state.detail else ""
        raise Failed(f"Port {state.port} is held by another process{hint}, not by Exasol, so the database cannot start. "
                     "Stop that process, then: exakit start", remedy="exakit start")
    ensure_running(ctx, deploy=True)


def start(ctx: Context) -> Result:
    """``exakit start``."""
    _start_database(ctx)
    for service in services.service_ids(ctx):
        if service.id == "database":
            continue
        try:
            services.start(ctx, service)
        except ExakitError as err:
            ctx.ui.warn(err.message)
    running = is_running(ctx)
    if running:
        clear_runtime_failure_note(ctx.paths.failure_note)
        ctx.manifest_store.update(lambda m: m.set("runtime.status", "running"))
    return Result(True, "running" if running else "stopped")


def stop(ctx: Context) -> Result:
    """Add-on services first: they talk to the database, so they should be down before it goes."""
    ctx.manifest()
    for service in services.service_ids(ctx):
        if service.id == "database":
            continue
        try:
            services.stop(ctx, service)
        except ExakitError as err:
            ctx.ui.warn(err.message)
    if ctx.manifest().runtime_type() == "personal":
        runtime(ctx).stop(ctx.ui.info)
        ctx.manifest_store.update(lambda m: m.set("runtime.status", "stopped"))
        ctx.ui.ok("Database stopped")
    return Result(True, "stopped")


def _print_autostart(ctx: Context, ids: list[services.Service]) -> int:
    width = max([7] + [len(s.id) for s in ids])
    lines = [f"{'Service':<{width}}  Status"]
    on = 0
    for service in ids:
        registered = services.autostart_registered(ctx, service.id)
        on += registered
        lines.append(f"{service.id:<{width}}  {'enabled' if registered else 'disabled'}")
    ctx.ui.text("")
    ctx.ui.panel("Automatic start after a restart", lines)
    ctx.ui.text("")
    return on


def _answer(ctx: Context, question: str) -> bool:
    """EXAKIT_AUTOSTART_CHANGE pre-answers; --yes answers yes; otherwise the question, defaulting to no."""
    value = ctx.env.get("EXAKIT_AUTOSTART_CHANGE", "").strip().lower()
    if value in ("1", "y", "yes"):
        return True
    if value in ("0", "n", "no"):
        return False
    if ctx.yes:
        return True
    return ctx.ui.confirm(question, default=False)


def autostart(ctx: Context, args: list[str]) -> Result:
    """``exakit autostart``."""
    if args:
        raise BadInput("autostart takes no arguments - run 'exakit autostart' and answer the question.")
    ctx.manifest()
    ids = services.service_ids(ctx)
    on = _print_autostart(ctx, ids)
    if not ids:
        return Result(True, "none")
    if on == len(ids):
        if not _answer(ctx, "Turn it off?"):
            return Result(True, "enabled")
        services.autostart_disable(ctx)
        return Result(True, "disabled")
    if not _answer(ctx, "Turn it on?"):
        return Result(True, "disabled" if on == 0 else "partial")
    return Result(True, "enabled" if services.autostart_enable(ctx) else "disabled")
