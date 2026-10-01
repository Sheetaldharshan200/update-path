"""``exakit version``: installed, advertised and status, one row per component.

The rows are the update set (kit, runtime, the core components, skills, the
add-ons on this machine) plus the add-ons this machine could install. The
status vocabulary is the one AGENTS.md documents:
current, ahead, unsupported, unknown, available, blocked_on_kit, missing, update_available.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, UTC
from typing import Any

from exakit.domain.ids import env_var
from exakit.domain.persona import ADDON_AVAILABLE, ADDON_INSTALLED
from exakit.domain.result import Result
from exakit.domain.versions import Resolved, VersionPolicy, is_newer, metadata_applies, resolve

from . import Context
from .machine import addon_state, installed_version, skills_local_version

CORE_ROWS = ("exakit", "personal", "exapump", "mcp", "pyexasol", "skills")
HEAVY = {"personal", "runtime"}


@dataclass(slots=True)
class Row:
    component: str
    addon: bool
    installed: str | None          # None = not installed
    installed_label: str
    advertised: str | None
    status: str
    remedy: str | None
    severity: str
    note: str | None
    platform_note: str | None

    def to_dict(self) -> dict[str, Any]:
        """The row as ``exakit version --json`` prints it."""
        return {"component": self.component, "addon": self.addon, "installed": self.installed,
                "installed_label": self.installed_label, "advertised": self.advertised, "status": self.status,
                "remedy": self.remedy, "severity": self.severity, "note": self.note, "platform_note": self.platform_note}


def available(ctx: Context, cid: str) -> Resolved | None:
    """The version this kit would install now, under the policy in force."""
    doc = ctx.versions.current()
    pin_name = env_var("personal" if cid == "runtime" else cid, "VERSION")
    if cid == "exakit":
        advertised = doc.kit_version() if doc else None
        return Resolved(advertised, "manifest") if advertised else None
    if ctx.catalog.has_addon(cid):
        fallback = ctx.catalog.addon(cid).fallback_version
    elif cid == "skills":
        fallback = skills_local_version(ctx)
    elif cid in ctx.catalog.component_ids():
        fallback = ctx.catalog.component(cid).fallback_version
    else:
        fallback = None
    return resolve(cid, policy=ctx.policy, env_pin=ctx.env.get(pin_name), doc=doc, fallback=fallback)


def supported(ctx: Context, cid: str) -> bool:
    """False only when the document publishes digests for this component and none is for this platform."""
    doc = ctx.versions.current()
    block = doc.component(cid) if doc else None
    digests = block.get("sha256") if block else None
    if not isinstance(digests, dict) or not digests:
        return True
    keys = {key.replace("arm64", "aarch64") for key in digests}
    if any("-" not in key for key in keys):     # wheel, vsix: not platform keyed
        return True
    return ctx.platform.platform_key in keys


def _metadata(ctx: Context, cid: str) -> tuple[str, str | None, str | None]:
    doc = ctx.versions.current()
    if doc is None or not metadata_applies(ctx.policy, ctx.env.get(env_var(cid, "VERSION"))):
        return "normal", None, None
    return doc.severity(cid), doc.note(cid), doc.min_kit_version(cid)


def kit_current(ctx: Context) -> str | None:
    """The installed kit version, or None."""
    version, _ = installed_version(ctx, "exakit", ctx.manifest_or_none())
    return version


def _min_kit_satisfied(ctx: Context, needed: str) -> bool:
    kit = kit_current(ctx)
    return not kit or kit == needed or is_newer(kit, needed)


def build_row(ctx: Context, cid: str) -> Row:
    """The version row for one component or add-on: installed, advertised, status, remedy."""
    manifest = ctx.manifest_or_none()
    is_addon = ctx.catalog.has_addon(cid)
    version, present = installed_version(ctx, cid, manifest)
    installed = version if present and version else None
    label = installed if installed else ("unknown" if present else "not installed")
    resolved = available(ctx, cid)
    advertised = resolved.version if resolved else None
    severity, note, min_kit = _metadata(ctx, cid)
    status, remedy, platform_note = "current", None, None
    if not supported(ctx, cid):
        label, status, severity, platform_note = "not available", "unsupported", "normal", f"no {cid} build exists for this platform"
        installed = None
    elif installed is None and is_addon and present is False:
        status, remedy, severity = "available", f"exakit marketplace {cid}", "normal"
    elif advertised is None or label == "unknown" or (installed is None and cid in HEAVY):
        status = "unknown"
    elif installed is not None and is_newer(installed, advertised):
        status, severity = "ahead", "normal"
    elif installed != advertised:
        if min_kit and not _min_kit_satisfied(ctx, min_kit):
            status, remedy = "blocked_on_kit", "exakit update exakit"
        elif installed is None:
            status, remedy = "missing", f"exakit update {cid}"
        else:
            status, remedy = "update_available", f"exakit update {cid}"
    return Row(cid, is_addon, installed, label, advertised, status, remedy, severity, note, platform_note)


def targets(ctx: Context) -> list[str]:
    """The components and add-ons the table lists."""
    manifest = ctx.manifest_or_none()
    rows = [c for c in CORE_ROWS if c != "personal" or (manifest and manifest.runtime_type() == "personal")]
    for addon in ctx.catalog.addons():
        state, _ = addon_state(ctx, addon, manifest)
        if state in (ADDON_INSTALLED, ADDON_AVAILABLE):
            rows.append(addon.id)
    return rows


def rows(ctx: Context, *, refresh: bool) -> list[Row]:
    """Every row, after refreshing the manifest when asked."""
    if refresh and ctx.policy is VersionPolicy.MANIFEST and not ctx.readonly:
        ctx.versions.refresh(force=True)
    return [build_row(ctx, cid) for cid in targets(ctx)]


def pending_count(table: list[Row]) -> int:
    """How many rows have an update available."""
    return sum(1 for r in table if r.status in ("update_available", "missing"))


def source_line(ctx: Context) -> str:
    """Where the advertised versions came from, in words."""
    policy = ctx.policy
    if policy is VersionPolicy.LATEST:
        return "Available versions come from live upstream lookups (EXAKIT_VERSION_POLICY=latest)"
    if policy is VersionPolicy.PINNED:
        return f"Available versions come from this kit's built-in fallbacks (EXAKIT_VERSION_POLICY={ctx.env.get('EXAKIT_VERSION_POLICY')}, no network)"
    label = ctx.versions.source_label()
    text = {"fetched": "published manifest, fetched just now", "cache": "cached manifest copy",
            "baked": "manifest shipped with this kit, no network"}.get(label, "this kit's built-in fallbacks")
    return f"Available versions come from the {text}"


def local_time(stamp: str | None) -> str:
    """A timestamp in the local time zone, for the human table."""
    if not stamp:
        return "unknown"
    try:
        parsed = datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)
    except ValueError:
        return stamp
    return parsed.astimezone().strftime("%Y-%m-%d %H:%M")


def run(ctx: Context) -> Result:
    """``exakit version``: the table or the JSON document."""
    manifest = ctx.manifest()
    table = rows(ctx, refresh=True)
    pending = pending_count(table)
    data = {
        "pending": pending,
        "kit": {"version": kit_current(ctx) or "unknown", "installed_at": manifest.get("installed_at")},
        "versions_source": ctx.versions.source_label(),
        "components": [r.to_dict() for r in table],
    }
    result = Result(True, "update_pending" if pending else "current", remedy="exakit update" if pending else None, data=data)
    if not ctx.json:
        _render(ctx, manifest, table, pending)
    return result


def _render(ctx: Context, manifest, table: list[Row], pending: int) -> None:
    ctx.ui.panel("Kit", [f"{'Version':<14} {kit_current(ctx) or 'unknown'}",
                         f"{'Installed':<14} {local_time(manifest.get('installed_at'))}"])
    ctx.ui.text("")
    cw = max([9] + [len(r.component) for r in table])
    vw = max([7] + [len(r.installed_label) for r in table])
    lines = [f"{'Component':<{cw}} {'Version':<{vw}} Status"]
    for r in table:
        cell = {"current": "current", "ahead": "none", "unsupported": "-", "unknown": "inspect",
                "available": "exakit marketplace", "blocked_on_kit": "update exakit first",
                "missing": f"{r.advertised} available (repair)", "update_available": f"{r.advertised} available"}[r.status]
        if r.severity in ("critical", "recommended") and r.status == "update_available":
            cell = f"{cell} ({r.severity})"
        lines.append(f"{r.component:<{cw}} {r.installed_label:<{vw}} {cell}")
        for note in (r.platform_note, r.note):
            if note:
                lines.append(f"  {note}")
    ctx.ui.panel("Components", lines)
    ctx.ui.text("")
    ctx.ui.info(source_line(ctx))
    if pending:
        ctx.ui.info("Bring everything up to date with: exakit update")


def min_kit_needed(ctx: Context, cid: str) -> str | None:
    """The kit version the advertised component needs, when the manifest says so and the policy honours it."""
    return _metadata(ctx, cid)[2]
