"""``exakit status``: what is true right now. Exit 0 running, 3 not running or installing, 4 not installed.

Nothing here writes state: a read-only query never records a failure note
and never heals the manifest. The JSON carries every remedy as a runnable
command (``remedies``) with its prose beside it (``remedy_hints``).
"""

from __future__ import annotations

from typing import Any

from exakit.adapters.fs.notes import lock_holder_alive, read_failure_note
from exakit.domain.errors import NotInstalled
from exakit.domain.manifest import Manifest
from exakit.domain.result import Result

from . import Context, data, services
from .machine import addon_installed_version, installed_version
from .mcp import LABELS
from .runtime_ops import runtime

STEP_REMEDIES = [("launcher", None), ("runtime", None), ("exapump", None), ("mcp", "exakit mcp-setup"),
                 ("pyexasol", "exakit update"), ("exakit_helper", None)]
SOFT_COMPONENTS = [("exapump", "components.exapump.validated"), ("mcp", "components.mcp_server.validated"),
                   ("pyexasol", "components.pyexasol.validated")]
LEGACY_RUNTIME_TYPES = ("nano",)


def platform_fields(ctx: Context) -> dict[str, Any]:
    """The platform keys of the status document."""
    return {"platform": "wsl" if ctx.platform.is_wsl else ctx.platform.os, "wsl_version": ctx.platform.wsl_version}


def not_installed(ctx: Context) -> NotInstalled:
    """The one answer every state query gives without an install record: exit 4, the installer as the remedy."""
    return NotInstalled(f"Not installed (no manifest at {ctx.paths.manifest}). Run the installer first.", remedy=ctx.install_command(),
                        data={"manifest": str(ctx.paths.manifest), "reason": "no install record", **platform_fields(ctx)})


def database_state(ctx: Context, manifest: Manifest) -> str:
    """The runtime's own words: running | stopped | starting | conflict | interrupted | not deployed | not installed."""
    if manifest.runtime_type() != "personal":
        return "not installed"
    return runtime(ctx).status().state


def datasets_loaded(ctx: Context, manifest: Manifest, *, ask_db: bool) -> tuple[list[str], str]:
    """Verified against the database when it answers, else the manifest; the source is named."""
    tables = data.listing(ctx) if ask_db else None
    loaded = data.loaded(ctx, tables=tables or {}, heal=False) if tables is not None else None
    if loaded is None:
        return sorted(d for d, doc in (manifest.get("data.datasets") or {}).items() if isinstance(doc, dict) and doc.get("loaded")), "manifest"
    return sorted(loaded), "database"


def install_progress(ctx: Context, manifest: Manifest) -> tuple[bool, str | None]:
    """(installing, step): installing only while the step is recorded AND the lock's process is the one that took it."""
    step = manifest.get("install.current_step") or None
    return bool(step) and lock_holder_alive(ctx.paths.install_lock, ctx.runner), step


def remedies_for(ctx: Context, db: str, running: bool, installing: bool, step: str | None, steps: list[str],
                 pyexasol: str | None) -> tuple[dict[str, str], dict[str, str], list[str]]:
    """(remedies, hints, missing steps): one runnable command per thing that is wrong, and the sentence behind it."""
    install_cmd = ctx.install_command()
    remedies: dict[str, str] = {}
    hints: dict[str, str] = {}
    if not pyexasol:
        remedies["pyexasol"] = "exakit update"
    fix, hint = _database_remedy(db, running, install_cmd)
    if fix:
        remedies["database"] = fix
    if hint:
        hints["database"] = hint
    if installing:
        remedies["install"] = "exakit status --json"
        hints["install"] = f"the installer is still running (step: {step or 'unknown'}) - poll the remedy until status is running"
    elif step:
        remedies["install"] = install_cmd
        hints["install"] = f"the installer died at step '{step}' - re-running resumes there"
    missing = [] if installing else _missing_steps(steps, remedies, hints, install_cmd)
    return remedies, hints, missing


def _database_remedy(db: str, running: bool, install_cmd: str) -> tuple[str | None, str | None]:
    """The one command that brings the database back, and the sentence that explains it; nothing when it runs."""
    if db.startswith("conflict"):
        return "exakit start", "another process is listening on the database port - stop it first, then run the remedy"
    if running:
        return None, None
    if db.startswith("interrupted"):
        return "exakit repair-runtime", None
    if db.startswith("not installed"):
        return install_cmd, "no database is deployed; the installer resumes at the unfinished step"
    if db.startswith("not deployed"):
        return "exakit repair-runtime", "the launcher is installed but no database is deployed; this deploys one"
    return "exakit start", None


def _missing_steps(steps: list[str], remedies: dict[str, str], hints: dict[str, str], install_cmd: str) -> list[str]:
    """The install steps that never finished, each with its remedy unless a more specific one is already there."""
    missing: list[str] = []
    for step_id, fix in STEP_REMEDIES:
        if step_id not in steps:
            missing.append(step_id)
            if step_id not in remedies:
                remedies[step_id] = fix or install_cmd
                if fix is None:
                    hints[step_id] = "this install step never finished; the installer resumes at it"
    return missing


def legacy_database(manifest: Manifest, install_cmd: str) -> dict[str, Any] | None:
    """The legacy database block of the document, or None."""
    container = manifest.get("legacy.container")
    if not container:
        return None
    restored = manifest.get("legacy.restored")
    choice = manifest.get("legacy.choice")
    copied = bool(restored)
    command = None
    if not copied and choice == "skip":
        command = "exakit migrate docker-nano"
    elif not copied and choice == "migrate":
        command = install_cmd
    sample = manifest.get("legacy.sample_left_out")
    return {"container": container, "engine": manifest.get("legacy.engine") or None, "choice": choice or None, "copied": copied,
            "restored_tables": int(restored) if isinstance(restored, int) or (isinstance(restored, str) and restored.isdigit()) else None,
            "sample_left_out": sample.split(",") if isinstance(sample, str) and sample else list(sample or []),
            "command": command}


def service_rows(ctx: Context) -> tuple[dict[str, str], dict[str, str]]:
    """(states, urls) of the add-on services."""
    states, urls = {}, {}
    for service in services.service_ids(ctx):
        if service.id == "database":
            continue
        states[service.id] = services.status_of(ctx, service)
        url = service.hooks.url() if service.hooks else None
        if url:
            urls[service.id] = url
    return states, urls


def autostart_on(ctx: Context) -> bool:
    """True when every service's login item is registered."""
    ids = services.service_ids(ctx)
    return bool(ids) and all(services.autostart_registered(ctx, s.id) for s in ids)


def stray_launchers(ctx: Context) -> list[str]:
    """Launchers in the bin dir that belong to no installed add-on."""
    if not ctx.paths.bin_dir.is_dir():
        return []
    return sorted(str(p) for p in ctx.paths.bin_dir.glob("exasol.backup-*") if p.is_file())


def run(ctx: Context) -> Result:
    """``exakit status``: the state, exit 3 when the database is not running."""
    manifest = ctx.manifest_or_none()
    if manifest is None:
        raise not_installed(ctx)
    db = database_state(ctx, manifest)
    running = db.startswith("running")
    installing, step = install_progress(ctx, manifest)
    steps = list(manifest.get("steps_completed") or [])
    pyexasol = installed_version(ctx, "pyexasol", manifest)[0]
    remedies, hints, missing = remedies_for(ctx, db, running, installing, step, steps, pyexasol)
    loaded, source = datasets_loaded(ctx, manifest, ask_db=running)
    service_states, urls = service_rows(ctx)
    note, note_at = read_failure_note(ctx.paths.failure_note)
    top = "installing" if installing else "no database" if db.startswith("not installed") else db
    remedy = remedies.get("install") or remedies.get("database") or (remedies.get(missing[0]) if missing else None)
    payload: dict[str, Any] = {
        "installing": installing, "install_step": step, "kit_level": manifest.get("kit_level"),
        "runtime": {"type": manifest.runtime_type(), "status": db}, **platform_fields(ctx), "running": running,
        "services": service_states, "urls": urls, "autostart": autostart_on(ctx), "datasets_loaded": loaded, "datasets_source": source,
        "steps_completed": steps, "steps_missing": missing, "pyexasol": pyexasol, "remedies": remedies, "remedy_hints": hints,
        "last_failure": note, "last_failure_at": note_at, "manifest": str(ctx.paths.manifest),
        "persona": manifest.persona_id(), "schema_version": manifest.get("schema_version"),
    }
    legacy = legacy_database(manifest, ctx.install_command())
    if legacy:
        payload["legacy_database"] = legacy
    if not ctx.json:
        _render(ctx, manifest, db, running, installing, step, loaded, service_states)
    return Result(True, top, remedy=remedy, remedy_hint=hints.get("install") or hints.get("database"), data=payload,
                  exit_code=0 if running and not installing else 3)


# --- the screen: four panels, nothing queried beyond what the JSON already asked -------------


def _pad(label: str, value: str) -> str:
    return f"{label:<17} {value}"


def _render(ctx: Context, manifest: Manifest, db: str, running: bool, installing: bool, step: str | None, loaded: list[str],
            service_states: dict[str, str]) -> None:
    ctx.ui.panel("Kit", _kit_lines(ctx, manifest, db, running, installing, step))
    ctx.ui.text("")
    ctx.ui.panel("Add-ons", _addon_lines(ctx, manifest, service_states))
    ctx.ui.text("")
    ctx.ui.panel("AI clients (MCP)", _client_lines(manifest))
    ctx.ui.text("")
    ctx.ui.panel("Data", _data_lines(manifest, loaded))
    ctx.ui.text("")
    _soft_lines(ctx, manifest)
    strays = stray_launchers(ctx)
    if strays:
        ctx.ui.text(f"{'Stray:':<12} {len(strays)} superseded launcher(s) in {ctx.paths.bin_dir} - safe to delete: rm {' '.join(strays)}")
    if not running:
        _next_line(ctx, db)


def _kit_lines(ctx: Context, manifest: Manifest, db: str, running: bool, installing: bool, step: str | None) -> list[str]:
    rtype = manifest.runtime_type()
    lines = []
    if rtype in LEGACY_RUNTIME_TYPES:
        lines.append(_pad("Runtime", f"{rtype} · from an older kit, not managed here"))
    else:
        lines.append(_pad("Runtime", f"{rtype or 'none'} · {db}"))
    if manifest.get("legacy.container") and not manifest.get("legacy.restored") and manifest.get("legacy.choice") == "migrate":
        lines.append(_pad("Old database", f"container '{manifest.get('legacy.container')}' ({manifest.get('legacy.engine')}) · copied out, "
                                          f"not yet restored - finish with: {ctx.install_command()}"))
    reach = " · reachable" if running else (" · port held by another process (not Exasol) - stop it, then: exakit start" if db == "conflict"
                                             else " · not reachable")
    lines.append(_pad("Database", f"{manifest.get('runtime.dsn') or 'unknown'}{reach}"))
    if installing:
        lines.append(_pad("Install", f"in progress · step: {step} - poll: exakit status"))
    elif step:
        lines.append(_pad("Install", f"did not finish at step: {step} - re-run: {ctx.install_command()}"))
    lines.append(_pad("Autostart", "enabled" if autostart_on(ctx) else "disabled - change it with: exakit autostart"))
    return lines


def _addon_lines(ctx: Context, manifest: Manifest, service_states: dict[str, str]) -> list[str]:
    lines, absent = [], []
    for addon in ctx.catalog.addons():
        if addon_installed_version(ctx, addon, manifest)[1]:
            state = service_states.get(addon.id, "installed")
            port = manifest.get(f"components.{addon.manifest_key}.port")
            lines.append(_pad(addon.id, f"{state} · http://127.0.0.1:{port}" if port and addon.id in service_states else state))
        else:
            absent.append(addon.id)
    if not lines:
        lines.append(_pad("none", "add one with: exakit marketplace"))
    if absent:
        lines.append(_pad("available", ", ".join(absent)))
    return lines


def _client_lines(manifest: Manifest) -> list[str]:
    configured = manifest.get("components.mcp_server.client_setup.configured_clients") or []
    lines = [_pad(LABELS.get(cid, cid), "configured") for cid in LABELS if cid in configured]
    return lines or [_pad("none", "connect one with: exakit mcp-setup")]


def _data_lines(manifest: Manifest, loaded: list[str]) -> list[str]:
    if not loaded:
        return ["none loaded - load some with: exakit data-load"]
    lines = []
    for ds in loaded:
        schema = manifest.get(f"data.datasets.{ds}.schema") or ds.upper()
        tables = manifest.get(f"data.datasets.{ds}.tables")
        rows = manifest.get(f"data.datasets.{ds}.rows")
        text = "loaded"
        if tables:
            text = f"{tables} table{'s' if tables != 1 else ''}" + (f", {rows:,} rows" if isinstance(rows, int) else "")
        lines.append(f"{ds:<11} {schema:<11} {text}")
    return lines


def _soft_lines(ctx: Context, manifest: Manifest) -> None:
    label = "Missing:"
    for cid, key in SOFT_COMPONENTS:
        if manifest.get(key) is None or installed_version(ctx, cid, manifest)[1]:
            continue
        ctx.ui.text(f"{label:<12} {cid:<9} repair: exakit update")
        label = ""


def _next_line(ctx: Context, db: str) -> None:
    if db.startswith("interrupted"):
        ctx.ui.text(f"{'Repair it:':<12} exakit repair-runtime   (replaces the database; its data is not recoverable)")
    elif db.startswith("conflict"):
        ctx.ui.text(f"{'Free the port:':<12} another process is listening on the database port - stop it, then: exakit start")
    elif db.startswith("not installed"):
        ctx.ui.text(f"{'Deploy it:':<12} {ctx.install_command()}   (it resumes at the unfinished step)")
    elif db.startswith("not deployed"):
        ctx.ui.text(f"{'Deploy it:':<12} exakit repair-runtime   (the launcher is installed but no database is deployed; this deploys one)")
    else:
        ctx.ui.text(f"{'Start it:':<12} exakit start")
