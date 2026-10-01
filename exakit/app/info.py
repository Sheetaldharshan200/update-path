"""``exakit info``: the connection details; ``--json`` is the install record plus the three state keys."""

from __future__ import annotations

from typing import Any

from exakit.domain.result import Result
from exakit.ui.widgets import tilde

from . import Context
from .machine import addon_installed_version, addon_state
from .runtime_ops import is_running
from .status import not_installed


def skills_verdict(ctx: Context, manifest) -> dict[str, Any]:
    """The skills block of the info document."""
    have = manifest.get("components.skills.version")
    doc = ctx.versions.current()
    want = doc.value("components.skills.version") if doc else None
    pending = bool(have and want and have != want)
    return {"installed_version": have, "advertised_version": want, "status": "update_pending" if pending else "current",
            "next": "exakit update" if pending else None}


def run(ctx: Context) -> Result:
    """``exakit info``: the panel, or the record under --json."""
    manifest = ctx.manifest_or_none()
    if manifest is None:
        raise not_installed(ctx)
    running = is_running(ctx)
    doc: dict[str, Any] = dict(manifest.doc)
    if running:
        status, remedy, hint = "running", None, None
    elif not manifest.runtime_type():
        status, remedy, hint = "no database", ctx.install_command(), "no runtime is recorded yet; the installer resumes at the unfinished step"
    else:
        status, remedy, hint = "stopped", "exakit start", None
        doc["database"] = "not running"
    doc["skills"] = skills_verdict(ctx, manifest)
    if not ctx.json:
        ctx.ui.panel("Setup details", _lines(ctx, manifest, doc["skills"]))
        ctx.ui.text("")
    return Result(True, status, remedy=remedy, remedy_hint=hint, data=doc, exit_code=0 if running else 3)


def _lines(ctx: Context, manifest, skills: dict[str, Any]) -> list[str]:
    home = ctx.env.get("HOME", "")
    lines = [f"Runtime:      {manifest.runtime_type() or 'unknown'}", f"DSN:          {manifest.get('runtime.dsn') or 'unknown'}",
             f"Admin user:   {manifest.get('runtime.user') or 'sys'}"]
    if manifest.get("runtime.password_file"):
        lines.append(f"Admin pass:   {tilde(str(manifest.get('runtime.password_file')), home)}")
    if manifest.get("components.mcp_server.connection.user"):
        lines.append(f"MCP user:     {manifest.get('components.mcp_server.connection.user')}")
    if manifest.get("components.mcp_server.connection.password_file"):
        lines.append(f"MCP pass:     {tilde(str(manifest.get('components.mcp_server.connection.password_file')), home)}")
    lines.append("TLS:          enabled (self-signed certificate)")
    exapump = manifest.get("components.exapump.path")
    if exapump:
        lines.append(f"exapump:      {tilde(str(exapump), home)} (profile: {manifest.get('components.exapump.profile') or ''})")
        if manifest.get("components.exapump.glibc_shim") is True:
            lines.append("              runs in a container shim; sees files under ~, /tmp and your current directory")
    if manifest.get("components.mcp_server.configs"):
        lines.append("MCP configs:  in each AI client's config (list: exakit mcp-status)")
        lines.append(f"MCP backups:  {tilde(str(ctx.paths.home / 'mcp'), home)}")
    if skills["installed_version"]:
        if skills["status"] == "update_pending":
            lines.append(f"Skills:       {skills['installed_version']} ({skills['advertised_version']} available: exakit update)")
        else:
            lines.append(f"Skills:       {skills['installed_version']} (list: exakit skills)")
    lines.append(f"Manifest:     {tilde(str(ctx.paths.manifest), home)}   ·  exakit info --json")
    lines.append(f"Logs:         {tilde(str(ctx.paths.logs), home)}")
    vscode = ctx.catalog.has_addon("exasol-vscode") and addon_installed_version(ctx, ctx.catalog.addon("exasol-vscode"), manifest)[1]
    clients = "VS Code (Exasol extension), DBeaver (https://dbeaver.io/download/) or DbVisualizer (https://www.dbvis.com/download/)" if vscode \
        else "DBeaver (https://dbeaver.io/download/) or DbVisualizer (https://www.dbvis.com/download/)"
    lines.append(f"SQL client:   {clients}")
    lines.append("Guide:        exakit guide")
    if any(addon_state(ctx, a, manifest)[0] == "available" for a in ctx.catalog.addons()):
        lines.append("Add-ons:      exakit marketplace (dashboards, editor tools and more)")
    return lines
