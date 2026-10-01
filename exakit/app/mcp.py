"""AI clients over MCP: the read-only database user, client configuration, status, doctor, removal.

The kit's ``mcp`` package (through ``adapters.clients``) owns the client
config files; this module owns the database side (the dedicated read-only
user and its posture), the selection, the screens and the manifest record.
"""

from __future__ import annotations

from typing import Any

from exakit.adapters.clients import CLIENT_IDS, ClientCall, client_states, managed_clients
from exakit.domain.errors import BadInput, Failed, NotInstalled, NotRunning
from exakit.domain.ids import CLIENT_WORDS_HELP, is_skip_word, parse_client_selection
from exakit.domain.result import Result
from exakit.ui.widgets import Option

from . import Context
from .machine import kit_root
from .mcp_readonly import configure_readonly_access
from .runtime_ops import ensure_running, is_running, runtime_remedy

LABELS = {"claude_desktop": "Claude", "claude_code": "Claude Code (CLI)", "cursor": "Cursor", "codex": "Codex",
          "vscode_copilot": "GitHub Copilot", "gemini_cli": "Gemini CLI", "opencode": "OpenCode", "continue": "Continue"}
REPAIRABLE_CODES = {"permission_drift", "manifest_drift_hash_mismatch", "manifest_drift_missing_artifact",
                    "managed_artifact_missing", "managed_entry_outdated"}


def _clients(ctx: Context):
    if ctx.clients is None:
        from exakit.adapters.clients import InProcessClientOps
        ctx.clients = InProcessClientOps(kit_root(ctx))
    return ctx.clients


# --- selection and setup --------------------------------------------------------------


def detected_clients(ctx: Context) -> dict[str, str] | None:
    """The AI clients on this machine and their state, or None when detection is unavailable."""
    return client_states(_clients(ctx).discover(ctx.paths.home))


def _select(ctx: Context) -> list[str] | None:
    """The clients to configure: from the environment, or the interactive menu. None means nothing to do."""
    raw = ctx.env.get("EXAKIT_MCP_CLIENTS", "")
    return _select_from_env(ctx, raw) if raw else _select_from_menu(ctx)


def _select_from_env(ctx: Context, raw: str) -> list[str] | None:
    if is_skip_word(raw):
        ctx.ui.info(f"Skipping AI client setup (EXAKIT_MCP_CLIENTS={raw}) - run 'exakit mcp-setup' any time.")
        return None
    try:
        chosen = parse_client_selection(raw)
    except BadInput:
        ctx.ui.warn(f"EXAKIT_MCP_CLIENTS='{raw}' is not valid (use {CLIENT_WORDS_HELP}, or numbers 1-7).")
        raise
    if raw.strip().lower() == "all":
        states = detected_clients(ctx)
        present = [c for c in chosen if states and states.get(c) in ("connected", "pending")]
        if present:
            skipped = [c for c in chosen if c not in present]
            chosen = present
            if skipped:
                ctx.ui.info(f"EXAKIT_MCP_CLIENTS=all - not installed here, skipped: {','.join(skipped)} (name one explicitly to configure it anyway)")
    ctx.ui.info(f"Configuring MCP clients from EXAKIT_MCP_CLIENTS: {','.join(chosen)}")
    return chosen


def _select_from_menu(ctx: Context) -> list[str] | None:
    states = detected_clients(ctx) or dict.fromkeys(CLIENT_IDS, "pending")
    pending = [c for c in CLIENT_IDS if states.get(c) == "pending"]
    if not pending:
        if not any(s == "connected" for s in states.values()):
            ctx.ui.info("No AI client was found on this machine, so there is nothing to connect yet.")
            ctx.ui.info("Install one (Claude, Codex, Cursor, Copilot, Gemini CLI, OpenCode, Continue) and run 'exakit mcp-setup'.")
        else:
            ctx.ui.ok("All AI clients found on this machine are already connected over MCP.")
            ctx.ui.info("Check them with 'exakit mcp-status'; new clients appear here once installed.")
        return None
    options = []
    for cid in CLIENT_IDS:
        state = states.get(cid, "missing")
        hint = "already connected" if state == "connected" else "not installed" if state == "missing" else ""
        options.append(Option(cid, LABELS[cid], hint=hint, disabled=state != "pending"))
    chosen = ctx.ui.checkboxes("AI clients to connect", options, defaults=pending)
    if not chosen:
        ctx.ui.info("No AI client selected - connect one any time with: exakit mcp-setup")
        return None
    return chosen


def setup(ctx: Context) -> Result:
    """``exakit mcp-setup``: heal the database, provision the read-only user, write the client configs."""
    ensure_running(ctx)
    ctx.ui.info("MCP setup will edit the selected AI client config files.")
    chosen = _select(ctx)
    if chosen is None:
        return Result(True, "skipped", data={"configured_clients": [], "skipped_clients": []})
    configure_readonly_access(ctx)
    ctx.ui.info("Applying MCP setup")
    call = _clients(ctx).setup(ctx.paths.home, chosen)
    return _report_setup(ctx, call)


def _report_setup(ctx: Context, call: ClientCall) -> Result:
    doc = call.doc or {}
    details = doc.get("details") or {}
    configured = list(details.get("configured_clients") or [])
    skipped = details.get("skipped_clients") or []
    status = doc.get("status", "failed")
    if call.code != 0 and not configured:
        ctx.log.line("ERROR", f"mcp setup: {call.stderr.strip()[-400:]}")
        raise Failed("Could not write the MCP entry for this AI client. What failed: exakit logs setup. Retry with: exakit mcp-setup",
                     remedy="exakit mcp-setup")
    labels = ", ".join(LABELS.get(c, c) for c in configured) or "no clients"
    if str(status).startswith("success"):
        ctx.ui.ok(f"MCP configured for {labels}")
    else:
        ctx.ui.warn(f"MCP setup finished as '{status}' for {labels}")
    for skip in skipped:
        ctx.ui.warn(f"Skipped {LABELS.get(skip.get('client'), skip.get('client'))}: {skip.get('reason')}")
    for finding in doc.get("findings") or []:
        if finding.get("code") == "plaintext_credential_reference":
            ctx.log.line("INFO", finding.get("message", ""))
        elif finding.get("severity") == "info":
            ctx.ui.info(finding.get("message", ""))
        else:
            ctx.ui.warn(finding.get("message", ""))
    manifest = ctx.manifest()
    dsn, user = manifest.get("runtime.dsn"), manifest.get("components.mcp_server.connection.user") or "mcp_readonly"
    ctx.ui.ok(f"MCP server 'exasol' - {dsn} as {user} (read-only), started by your AI client on demand")
    ctx.log.line("INFO", "Config file paths and per-client state: exakit mcp-status")
    data = {"configured_clients": configured, "skipped_clients": [s.get("client") for s in skipped], "mcp_status": status}
    return Result(True, "configured" if configured else "partial", data=data, exit_code=0 if configured else 1)


# --- status, doctor, remove ---------------------------------------------------------------


def _stamp(doc: dict[str, Any]) -> dict[str, Any]:
    """Add ``installed`` and the best ``remedy`` (the most severe finding's recommended action)."""
    doc.setdefault("installed", True)
    rank = {"critical": 0, "error": 1, "warning": 2}
    best = None
    for index, finding in enumerate(doc.get("findings") or []):
        severity = finding.get("severity")
        action = finding.get("recommended_action")
        if severity in rank and action:
            key = (rank[severity], 0 if finding.get("scope") else 1, index)
            if best is None or key < best[0]:
                best = (key, action)
    doc["remedy"] = best[1] if best else None
    return doc


def _clients_from_args(args: list[str]) -> list[str]:
    if not args:
        return []
    try:
        return parse_client_selection(" ".join(args))
    except BadInput:
        raise BadInput("Please choose valid AI clients: claude, claude_desktop, claude_code, codex, cursor, copilot, gemini, opencode, continue, or all.") from None


def status(ctx: Context, args: list[str]) -> Result:
    """``exakit mcp-status``: the managed clients and their config files."""
    ctx.manifest()
    clients = _clients_from_args(args)
    call = _clients(ctx).operation("status", ctx.paths.home, clients)
    if call.doc is None:
        raise Failed("the MCP status operation produced no result; what it printed is in: exakit logs setup", remedy="exakit logs setup")
    doc = _stamp(dict(call.doc))
    if not ctx.json:
        _render_status(ctx, doc)
    return Result(True, str(doc.get("status", "unknown")), remedy=doc.get("remedy"), data=doc, raw=True,
                  exit_code=0 if call.code == 0 else 1)


def _render_status(ctx: Context, doc: dict[str, Any]) -> None:
    rows = (doc.get("details") or {}).get("clients") or []
    configured = [r for r in rows if r.get("state") == "configured"]
    home = ctx.env.get("HOME") or ""
    lines = [f"{'Client':<20} {'State':<12} Config"]
    for row in configured:
        path = str(row.get("path") or "")
        if home and path.startswith(home):
            path = "~" + path[len(home):]
        lines.append(f"{LABELS.get(row['client'], row['client']):<20} {'configured':<12} {path}")
    if not configured:
        lines.append("Nothing configured yet. Connect a client with: exakit mcp-setup")
    ctx.ui.panel("MCP clients", lines)
    notes = [f.get("message", "") for f in doc.get("findings") or []]
    if notes:
        ctx.ui.text("  Notes:")
        for note in notes:
            ctx.ui.text(f"  - {note}")


def doctor(ctx: Context, args: list[str]) -> Result:
    """``exakit mcp-doctor``: check and repair the configuration."""
    manifest = ctx.manifest_or_none()
    if manifest is None:
        raise NotInstalled("No installation found.", remedy=ctx.install_command())
    if not manifest.runtime_type():
        raise NotRunning("No runtime is recorded in the manifest yet, so there is no database to diagnose against.",
                         remedy=ctx.install_command(), hint="no runtime is recorded yet; the installer resumes at the unfinished step",
                         data={"installed": True, "status": "no database", "database": "not installed"})
    if not is_running(ctx):
        remedy = runtime_remedy(ctx)
        raise NotRunning(f"The database is not running - fix that first: {remedy}", remedy=remedy,
                         hint="MCP diagnostics need a live database (the read-only user and its grants are checked against it)",
                         data={"installed": True, "status": "stopped", "database": "not running"})
    clients = _clients_from_args(args)
    configure_readonly_access(ctx)
    call = _clients(ctx).operation("doctor", ctx.paths.home, clients)
    if call.doc is None:
        raise Failed("Could not run MCP diagnostics", remedy="exakit logs setup")
    doc = _stamp(dict(call.doc))
    repairable = any(f.get("code") in REPAIRABLE_CODES and f.get("severity") in ("warning", "error", "critical")
                     for f in doc.get("findings") or [])
    if not ctx.json:
        _render_operation(ctx, doc)
        if repairable:
            ctx.ui.info("Repairing the managed client config - re-checking")
            repair = _clients(ctx).operation("repair", ctx.paths.home, clients)
            if repair.doc and repair.doc.get("status") == "no_change":
                ctx.ui.info("Nothing to repair: the managed client config is already consistent.")
            recheck = _clients(ctx).operation("doctor", ctx.paths.home, clients)
            doc = _stamp(dict(recheck.doc or doc))
            call = recheck
            if recheck.code == 0:
                ctx.ui.ok("Everything the repair could fix is fixed.")
            else:
                ctx.ui.warn("Some findings are not config drift and remain - see the notes above.")
        ctx.ui.info("Connect or re-connect AI clients any time with:  exakit mcp-setup")
    return Result(True, str(doc.get("status", "unknown")), remedy=doc.get("remedy"), data=doc, raw=True,
                  exit_code=0 if call.code == 0 else 1)


def _render_operation(ctx: Context, doc: dict[str, Any]) -> None:
    ctx.ui.text("")
    ctx.ui.text("  MCP operation summary")
    ctx.ui.text(f"  Operation: {doc.get('operation')}")
    ctx.ui.text(f"  Status:    {doc.get('status')}")
    ctx.ui.text(f"  Summary:   {doc.get('summary')}")
    states = (doc.get("details") or {}).get("clients") or []
    if states:
        ctx.ui.text("  Client state:")
        groups: dict[str, list[str]] = {}
        for row in states:
            groups.setdefault(str(row.get("state")), []).append(LABELS.get(row.get("client"), str(row.get("client"))))
        for state, names in groups.items():
            ctx.ui.text(f"    {state.replace('_', ' '):<26} {', '.join(names)}")
    findings = doc.get("findings") or []
    if findings:
        ctx.ui.text("  Notes:")
        for finding in findings:
            ctx.ui.text(f"  - {finding.get('message')}")
    actions = doc.get("next_actions") or []
    if actions:
        ctx.ui.text("  Next:")
        for action in actions:
            ctx.ui.text(f"  - {action.get('message')}")


def remove(ctx: Context, args: list[str]) -> Result:
    """``exakit mcp-remove <client>...``: take the kit's entries out."""
    if not args:
        raise BadInput("Name the client(s) to remove the kit's MCP entries from: exakit mcp-remove cursor (see: exakit mcp-status)")
    if any(a.lower() == "all" for a in args):
        raise BadInput("mcp-remove takes client names, not 'all' - the full removal is: exakit uninstall")
    ctx.manifest()
    clients = _clients_from_args(args)
    call = _clients(ctx).operation("uninstall", ctx.paths.home, clients)
    if call.doc is None or (call.code not in (0,) and (call.doc or {}).get("status") not in ("no_change",)):
        raise Failed("Could not remove the MCP entries", remedy="exakit mcp-status")
    doc = _stamp(dict(call.doc))
    if not ctx.json:
        _render_operation(ctx, doc)
        for change in doc.get("changes") or []:
            ctx.ui.text(f"  - {change.get('kind')} {change.get('path')}")
    return Result(True, str(doc.get("status")), remedy=doc.get("remedy"), data=doc, raw=True)


# --- add-on endpoints and pin refresh ----------------------------------------------------


def managed(ctx: Context) -> list[str]:
    """The client ids the kit manages."""
    return managed_clients(_clients(ctx).operation("status", ctx.paths.home, []))


def register_addon_servers(ctx: Context, label: str) -> bool:
    """Add an add-on's MCP server to every managed client; True when it took."""
    clients = managed(ctx)
    if not clients:
        ctx.ui.info("No AI client is connected yet - connect one any time with: exakit mcp-setup")
        return True
    call = _clients(ctx).register_addon_servers(ctx.paths.home, clients)
    if call.code != 0:
        ctx.ui.warn(f"Could not register the {label} MCP endpoint with your AI clients - run: exakit mcp-setup")
        return False
    configured = ((call.doc or {}).get("dash_server") or {}).get("configured_clients") or []
    if configured:
        ctx.log.line("OK", f"{label} MCP endpoint registered with: {','.join(configured)}")
    else:
        ctx.ui.info(f"No connected AI client can take a remote MCP endpoint - drive {label} with: exakit help {label}")
    return True


def unregister_server_entry(ctx: Context, server: str, label: str) -> bool:
    """Remove one server entry from every managed client; True when it took."""
    clients = managed(ctx)
    if not clients:
        return True
    call = _clients(ctx).operation("uninstall", ctx.paths.home, clients, servers=[server])
    if call.code != 0:
        ctx.ui.warn(f"The {label} MCP entry may still be in your AI client configs - check with: exakit mcp-status")
        return False
    return True


def refresh_client_pins(ctx: Context, version: str) -> bool:
    """Rewrite the MCP server version pin in every managed client; True when it took."""
    clients = managed(ctx)
    if not clients:
        ctx.ui.info("No AI client is connected yet - connect one any time with: exakit mcp-setup")
        return True
    ctx.ui.info(f"Refreshing AI client configs to exasol-mcp-server@{version}")
    configure_readonly_access(ctx)
    call = _clients(ctx).setup(ctx.paths.home, clients)
    if call.code != 0:
        ctx.ui.warn("Could not refresh the AI client configs - run exakit mcp-setup to finish the update.")
        return False
    ctx.ui.ok(f"AI client configs now launch exasol-mcp-server@{version}")
    return True
