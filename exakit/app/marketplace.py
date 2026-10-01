"""``exakit marketplace``: browse, list and install optional add-ons; ``exakit uninstall <addon>`` removes one.

The state vocabulary is fixed: installed / available / managed outside the
kit / not in this kit copy / not available on this machine. Bare and without
a terminal the menu installs NOTHING; installing non-interactively takes an
explicit answer (ids on the command line, or EXAKIT_MARKETPLACE_ADDONS).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from exakit.domain.catalog import Addon
from exakit.domain.errors import BadInput, ExakitError, Failed, NotConfirmed
from exakit.domain.persona import ADDON_AVAILABLE, ADDON_INSTALLED, ADDON_MISSING_MODULE, ADDON_SYSTEM, ADDON_UNAVAILABLE
from exakit.domain.result import Result
from exakit.lifecycles import for_addon
from exakit.ui.silent import SilentRenderer
from exakit.ui.widgets import Option

from . import Context, about, services, skills
from .machine import addon_state

STATUS_WORDS = {
    ADDON_INSTALLED: "installed", ADDON_AVAILABLE: "available", ADDON_SYSTEM: "managed outside the kit",
    ADDON_MISSING_MODULE: "not in this kit copy", ADDON_UNAVAILABLE: "not available on this machine",
}


@dataclass(frozen=True, slots=True)
class Row:
    addon: Addon
    state: str
    version: str | None
    reason: str

    @property
    def status(self) -> str:
        """The status word the listing shows."""
        return STATUS_WORDS[self.state]

    def to_dict(self) -> dict[str, Any]:
        """The row as ``marketplace --list --json`` prints it."""
        doc: dict[str, Any] = {"id": self.addon.id, "status": self.status, "installed": self.state == ADDON_INSTALLED}
        if self.version:
            doc["version"] = self.version
        if self.reason:
            doc["reason"] = self.reason
        return doc


def known_ids(ctx: Context) -> str:
    """The add-on ids, space-separated, for messages."""
    return " ".join(ctx.catalog.addon_ids())


def row_for(ctx: Context, addon: Addon) -> Row:
    """The listing row of one add-on: state, reason, versions."""
    state, reason = addon_state(ctx, addon, ctx.manifest_or_none())
    version = None
    if state == ADDON_INSTALLED:
        version = for_addon(ctx, addon).installed_version() or str(ctx.manifest().get(f"components.{addon.manifest_key}.version") or "?")
    elif state == ADDON_AVAILABLE:
        try:
            version = for_addon(ctx, addon).target_version()
        except ExakitError:
            version = None
    return Row(addon, state, version, reason if state == ADDON_UNAVAILABLE else "")


def rows(ctx: Context) -> list[Row]:
    """Every add-on's listing row."""
    return [row_for(ctx, a) for a in ctx.catalog.addons()]


def description(ctx: Context, addon: Addon) -> str:
    """The add-on's own GitHub About (cached a day), else its help tagline."""
    return about.description(ctx, addon)


# --- the read-only surface ----------------------------------------------------------------


def listing(ctx: Context) -> Result:
    """``exakit marketplace --list [--json]``: one row per add-on, whatever its state; nothing is written."""
    table = rows(ctx)
    if not ctx.json:
        for row in table:
            ctx.ui.text(f"{row.addon.id:<16} {row.status}{' ' + row.version if row.version else ''}")
            if row.reason:
                ctx.ui.text(f"{'':<16} ({row.reason})")
    return Result(True, "ok", data={"addons": [r.to_dict() for r in table]}, raw=True)


# --- choosing ---------------------------------------------------------------------------------


def _env_answer(ctx: Context, answer: str, table: list[Row]) -> list[str] | None:
    """The scripted answer: ids csv, all, or none. None means nothing to do (already said why)."""
    answer = answer.replace(" ", "").lower()
    if answer == "none":
        ctx.ui.info("EXAKIT_MARKETPLACE_ADDONS=none - installing nothing.")
        return None
    by_id = {r.addon.id: r for r in table}
    if answer == "all":
        picked = [r.addon.id for r in table if r.state == ADDON_AVAILABLE]
    else:
        picked = []
        for token in [t for t in answer.split(",") if t]:
            row = by_id.get(token)
            if row is None:
                raise BadInput(f"Unknown marketplace add-on in EXAKIT_MARKETPLACE_ADDONS: '{token}' (known: {known_ids(ctx)})")
            if row.state == ADDON_AVAILABLE:
                picked.append(token)
            elif row.state == ADDON_INSTALLED:
                ctx.ui.info(f"{token} is already installed - update it with: exakit update")
            elif row.state == ADDON_SYSTEM:
                ctx.ui.info(f"{token} is already on this system - the kit leaves it alone")
            elif row.state == ADDON_UNAVAILABLE:
                raise Failed(f"{token} is not available on this machine{': ' + row.reason if row.reason else ''}")
            else:
                raise Failed(f"The {token} module is not part of this kit copy - update the kit first: exakit update", remedy="exakit update")
    if not picked:
        ctx.ui.info("Nothing to install - every requested add-on is already present.")
        ctx.ui.info("If one of them is present but not working, repair it with: exakit update <id>")
        return None
    return picked


def _covered_lines(ctx: Context, table: list[Row]) -> None:
    ctx.ui.info("Everything available is already covered.")
    for row in table:
        if row.state == ADDON_UNAVAILABLE:
            continue
        why = "Installed" if row.state == ADDON_INSTALLED else row.status
        ctx.ui.info(f"{row.addon.id:<14} {why}{' ' + row.version if row.state == ADDON_INSTALLED and row.version else ''}")


def _menu_answer(ctx: Context, table: list[Row]) -> list[str] | None:
    """The interactive answer; without a terminal the answer is skip, out loud."""
    offer = [r for r in table if r.state == ADDON_AVAILABLE]
    ctx.ui.text("")
    if not offer:
        _covered_lines(ctx, table)
        return None
    if not ctx.ui.interactive:
        ctx.ui.info("No terminal to ask on - nothing was installed.")
        ctx.ui.info("See what is available (read-only): exakit marketplace --list   (--json for scripts)")
        ctx.ui.info("Install explicitly: exakit marketplace <id>   or EXAKIT_MARKETPLACE_ADDONS=<ids>|all exakit marketplace")
        return None
    options = []
    for row in table:
        if row.state == ADDON_UNAVAILABLE:
            continue
        if row.state == ADDON_AVAILABLE:
            hint = f"{row.version or 'unknown'}  {description(ctx, row.addon)}"
            options.append(Option(row.addon.id, row.addon.id, hint=hint))
        else:
            hint = "Installed" + (f" {row.version}" if row.version else "") if row.state == ADDON_INSTALLED else row.status
            options.append(Option(row.addon.id, row.addon.id, hint=hint, disabled=True))
    chosen = ctx.ui.checkboxes("Marketplace add-ons", options, defaults=[r.addon.id for r in offer])
    if not chosen:
        ctx.ui.info("Nothing selected - nothing was installed.")
        return None
    return [c for c in chosen if c in {r.addon.id for r in offer}]


def choose(ctx: Context, explicit: list[str] | None = None) -> list[str] | None:
    """The add-on ids to install: the explicit list, the persona's or environment's answer, or the menu."""
    with ctx.ui.busy("Checking which add-ons can run here"):
        table = rows(ctx)
    answer = ",".join(explicit) if explicit else ctx.env.get("EXAKIT_MARKETPLACE_ADDONS", "")
    if answer:
        return _env_answer(ctx, answer, table)
    return _menu_answer(ctx, table)


# --- installing -------------------------------------------------------------------------------


def install_one(ctx: Context, addon: Addon) -> bool:
    """install -> validate -> its skills -> autostart (when on) -> start. False when the install itself failed."""
    lifecycle = for_addon(ctx, addon)
    if addon.directory is None:
        ctx.ui.warn(f"The {addon.id} module is not part of this kit copy - update the kit first: exakit update")
        return False
    try:
        lifecycle.install(lifecycle.target_version())
    except ExakitError as err:
        lifecycle.note_failure(err.message)
        ctx.log.line("WARN", f"{addon.id} did not finish installing: {err.message}")
        return False
    try:
        lifecycle.validate()
    except ExakitError as err:
        ctx.log.line("WARN", f"{addon.id} validation: {err.message}")
    try:
        skills.install_for_addon(ctx, addon.id)
    except ExakitError as err:
        ctx.log.line("WARN", f"{addon.id} skills: {err.message}")
    hooks = lifecycle.service()
    if hooks is not None:
        if services.autostart_wanted(ctx):
            services.register_autostart(ctx, services.Service(addon.id, hooks))
        try:
            hooks.start()
        except ExakitError:
            ctx.ui.warn(f"{addon.id} installed but did not start - start it with: exakit start")
    return True


def apply(ctx: Context, ids: list[str]) -> Result:
    """Install the chosen add-ons one by one; the answer names what landed and what failed."""
    installed, failed = [], []
    for addon_id in ids:
        addon = ctx.catalog.addon(addon_id)
        ctx.ui.info(f"Installing add-on: {addon_id}")
        if install_one(ctx, addon):
            note = for_addon(ctx, addon).summary()
            ctx.ui.ok(f"{addon_id} installed{' - ' + note if note else ''}")
            installed.append(addon_id)
        else:
            ctx.log.line("WARN", f"{addon_id} did not finish installing")
            failed.append(addon_id)
    data = {"installed": installed, "failed": failed}
    if failed:
        return Result(True, "partial", remedy=f"exakit update {failed[0]}", data=data, exit_code=1)
    return Result(True, "applied", data=data)


def run(ctx: Context, args: list[str]) -> Result:
    """The command body: options, then list or menu."""
    ctx.manifest()
    want_list, ids = False, []
    for arg in args:
        if arg == "--list":
            want_list = True
        elif arg.startswith("-"):
            raise BadInput(f"Unknown option '{arg}' for marketplace (supported: --list, --json, or add-on ids to install).")
        elif ctx.catalog.has_addon(arg):
            ids.append(arg)
        else:
            raise BadInput(f"Unknown marketplace add-on '{arg}' (known: {known_ids(ctx)}).")
    if want_list or ctx.json:
        if ids:
            raise BadInput("marketplace --list is read-only and cannot be combined with add-on ids to install.")
        return listing(ctx)
    picked = choose(ctx, ids or None)
    if not picked:
        return Result(True, "skipped", data={"installed": [], "failed": []})
    return apply(ctx, picked)


def install_addon_quietly(ctx: Context, addon_id: str) -> bool:
    """An add-on another command needs (json-tables for a .json file): its narration goes to the log only."""
    addon = ctx.catalog.addon(addon_id)
    loud = ctx.ui
    ctx.ui = SilentRenderer(ctx.log)
    try:
        return install_one(ctx, addon)
    finally:
        ctx.ui = loud


# --- removing one ---------------------------------------------------------------------------------


def uninstall_addon(ctx: Context, addon_id: str) -> Result:
    """``exakit uninstall <addon> [--yes|--dry-run]``: one add-on, its own hook narrating; exit 5 when declined."""
    ctx.manifest()
    addon = ctx.catalog.addon(addon_id)
    lifecycle = for_addon(ctx, addon)
    if addon_state(ctx, addon, ctx.manifest_or_none())[0] != ADDON_INSTALLED:
        ctx.ui.info(f"{addon_id} is not installed - nothing to remove.")
        return Result(True, "not-installed", data={"addon": addon_id, "removed": []})
    if ctx.dry_run:
        ctx.ui.info(f"Dry run - removing the {addon_id} add-on would:")
        removed = lifecycle.uninstall(dry_run=True)
        return Result(True, "dry-run", data={"addon": addon_id, "removed": removed})
    if not ctx.yes and not ctx.ui.confirm(f"Remove the {addon_id} add-on?", default=False):
        raise NotConfirmed("Nothing was removed.", remedy=f"exakit uninstall {addon_id} --yes")
    skills.remove_for_addon(ctx, addon_id)
    removed = lifecycle.uninstall(dry_run=False)
    if lifecycle.service() is not None:
        services.unregister_autostart(ctx, addon_id)
    ctx.ui.ok(f"{addon_id} removed. Reinstall any time with: exakit marketplace {addon_id}")
    return Result(True, "removed", data={"addon": addon_id, "removed": removed})
