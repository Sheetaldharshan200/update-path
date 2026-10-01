"""``exakit uninstall``: one add-on by name, the menu with a typed gate, or the scripted full removal (``--yes``)."""

from __future__ import annotations

import shutil
import tempfile
import time
from pathlib import Path

from exakit.components import for_component
from exakit.domain.errors import BadInput, ExakitError, Failed
from exakit.domain.result import Result
from exakit.lifecycles import for_addon
from exakit.ui.widgets import Option

from . import Context, marketplace, services
from .machine import addon_installed_version

HOME_MARKERS = ("manifest.json", "logs", "cache", "credentials", "kit", "mcp", "backups", "libexec", "workflows", "migration",
                ".last-failure", ".install.lock", "python", "tools")


def safe_target(home: Path, user_home: Path) -> bool:
    """An absolute path to a kit home the kit created: never /, never the user's home, never a folder of other things."""
    if not home.is_absolute() or home == Path("/") or home.resolve() == user_home.resolve():
        return False
    if not home.is_dir():
        return True
    if any((home / marker).exists() for marker in HOME_MARKERS):
        return True
    return not any(home.iterdir())


def _say(ctx: Context, dry: bool, what: str) -> None:
    ctx.ui.info(f"  will remove: {what}" if dry else what)


def remove_everything(ctx: Context, *, dry: bool) -> list[str]:
    """The full removal in the legacy order. Returns what went (or would go)."""
    user_home = Path(ctx.env.get("HOME") or Path.home())
    if ctx.paths.home.exists() and not safe_target(ctx.paths.home, user_home):
        ctx.ui.error(f"Refusing to remove {ctx.paths.home}: it is not an absolute path to a kit home the kit created.")
        ctx.ui.info("EXAKIT_HOME must be an absolute path holding the kit's manifest.json, and cannot be your home directory.")
        ctx.ui.info("Nothing was removed. Check EXAKIT_HOME, or unset it to use the default ~/.exasol-starter-kit.")
        raise Failed(f"Unsafe EXAKIT_HOME: {ctx.paths.home}")
    gone: list[str] = []
    manifest = ctx.manifest_or_none()
    for service in services.service_ids(ctx):
        if services.autostart_registered(ctx, service.id):
            _say(ctx, dry, f"the automatic-start entry for {service.id}")
            if not dry:
                services.unregister_autostart(ctx, service.id)
    ctx.env = {**dict(ctx.env), "EXAKIT_UNINSTALL_FULL": "1"}
    addons_gone = []
    for addon in ctx.catalog.addons():
        if manifest and addon_installed_version(ctx, addon, manifest)[1]:
            try:
                for_addon(ctx, addon).uninstall(dry_run=dry)
                addons_gone.append(addon.id)
            except ExakitError as err:
                ctx.ui.warn(f"Removing the {addon.id} add-on reported issues (continuing uninstall): {err.message}")
    if addons_gone:
        gone.append(f"add-ons: {', '.join(addons_gone)}")
    _remove_database(ctx, dry, gone)
    if manifest and manifest.get("components.mcp_server"):
        for_component(ctx, "mcp").uninstall(dry_run=dry)
        gone.append("mcp configs")
    for_component(ctx, "skills").uninstall(dry_run=dry)
    exapump_dir = Path(ctx.env.get("EXAKIT_EXAPUMP_CONFIG_DIR") or user_home / ".exapump")
    if exapump_dir.exists():
        _say(ctx, dry, f"exapump profiles at {exapump_dir}")
        gone.append(str(exapump_dir))
        if not dry:
            shutil.rmtree(exapump_dir, ignore_errors=True)
    _remove_home(ctx, dry, gone)
    _remove_bins(ctx, dry, gone)
    return gone


def _remove_database(ctx: Context, dry: bool, gone: list[str]) -> None:
    manifest = ctx.manifest_or_none()
    rtype = manifest.runtime_type() if manifest else None
    if rtype == "personal":
        _say(ctx, dry, f"local Exasol {rtype} deployment and ALL its data")
        if not dry:
            try:
                for_component(ctx, "personal").uninstall(dry_run=False)
            except ExakitError as err:
                ctx.ui.warn(f"Database removal reported errors (continuing uninstall): {err.message}")
        gone.append("database")
        return
    if rtype:
        ctx.ui.warn(f"Unknown runtime type '{rtype}'; skipping database removal")
        return
    ctx.ui.warn("No runtime recorded in the manifest, so the database was NOT removed.")
    ctx.ui.info("If a local deployment exists it is still on disk, with all its data, at:")
    ctx.ui.info(f"  {ctx.env.get('EXAKIT_PERSONAL_DEPLOY_DIR') or Path(ctx.env.get('HOME') or Path.home()) / '.exasol/personal/deployments/default'}")
    ctx.ui.info("Remove it by hand, or re-install and then uninstall again to have the kit do it.")
    ctx.env = {**dict(ctx.env), "EXAKIT_UNINSTALL_DB_SKIPPED": "1"}


def _remove_home(ctx: Context, dry: bool, gone: list[str]) -> None:
    home = ctx.paths.home
    if not home.exists():
        return
    backups = home / "backups"
    if not dry and backups.is_dir() and any(backups.iterdir()):
        keep = home.with_name(f"{home.name}-backups-{time.strftime('%Y%m%d-%H%M%S')}")
        try:
            backups.rename(keep)
            ctx.ui.info(f"AI client config snapshots kept at {keep} (delete it when you are sure)")
        except OSError:
            pass
    _say(ctx, dry, f"kit home {home} (credentials, logs, manifest, snapshots, pyexasol venv, add-ons)")
    gone.append(str(home))
    if not dry:
        if ctx.platform.os == "windows":
            for child in home.iterdir():
                if child.name != "python":
                    shutil.rmtree(child, ignore_errors=True) if child.is_dir() else child.unlink(missing_ok=True)
            _remove_python_after_exit(ctx, home)
        else:
            shutil.rmtree(home, ignore_errors=True)


def _remove_python_after_exit(ctx: Context, home: Path) -> None:
    """Windows: the kit's Python runs this very command, so a detached shell removes it a few seconds after we exit."""
    python_dir = home / "python"
    script = f'timeout /t 5 /nobreak >nul & rmdir /s /q "{python_dir}" & rmdir "{home}"'
    log = Path(tempfile.gettempdir()) / "exakit-uninstall.log"
    try:
        ctx.runner.spawn(["cmd", "/c", script], log_path=log)
        ctx.ui.info(f"The kit's Python at {python_dir} runs this command; it is removed a few seconds after this command exits.")
    except OSError:
        ctx.ui.info(f"The kit's Python at {python_dir} is in use by this command - delete that folder afterwards.")


def _remove_bins(ctx: Context, dry: bool, gone: list[str]) -> None:
    names = ["exasol", "exasol.exe", "exakit", "exakit.ps1", "exakit.cmd", "exapump", "exapump.exe"] + [a.launcher or a.id for a in ctx.catalog.addons()]
    removed = []
    for name in names:
        path = ctx.paths.bin_dir / name
        if path.exists() or path.is_symlink():
            _say(ctx, dry, f"CLI binary {path}")
            removed.append(name)
            if not dry:
                path.unlink(missing_ok=True)
    if removed:
        gone.append(f"commands: {', '.join(removed)}")


# --- one piece -------------------------------------------------------------------------------


def remove_component(ctx: Context, key: str) -> None:
    """Remove one piece from the uninstall menu."""
    if key == "database":
        ctx.ui.info("Removing the local Exasol personal deployment and all data")
        for_component(ctx, "personal").uninstall(dry_run=False)
    elif key == "mcp_configs":
        for_component(ctx, "mcp").uninstall(dry_run=False)
    elif key == "skills":
        for_component(ctx, "skills").uninstall(dry_run=False)
    elif key in ("exapump", "pyexasol"):
        for_component(ctx, key).uninstall(dry_run=False)
    elif key == "everything":
        remove_everything(ctx, dry=False)
    elif ctx.catalog.has_addon(key):
        from . import skills
        for_addon(ctx, ctx.catalog.addon(key)).uninstall(dry_run=False)
        skills.remove_for_addon(ctx, key)
        services.unregister_autostart(ctx, key)
    else:
        ctx.ui.warn(f"Unknown uninstall target: {key}")


# --- the command -----------------------------------------------------------------------------------


def _menu(ctx: Context) -> Result:
    manifest = ctx.manifest_or_none()
    options = [Option("database", "Database - the local Exasol deployment and ALL its data"),
               Option("mcp_configs", "MCP configs - the kit's entry in each AI client"),
               Option("skills", "AI skills - the kit's skills in the agents' folders"),
               Option("exapump", "exapump - the CLI and its profiles"), Option("pyexasol", "pyexasol - the managed venv")]
    addons = [a.id for a in ctx.catalog.addons() if manifest and addon_installed_version(ctx, a, manifest)[1]]
    options += [Option(aid, f"Add-on: {aid}") for aid in addons]
    options.append(Option("everything", "EVERYTHING - keeps: nothing"))
    if not ctx.ui.interactive:
        raise Failed("uninstall needs an interactive terminal to confirm; use --yes for the scripted full uninstall.")
    picked = ctx.ui.checkboxes("Select what to uninstall", options, defaults=[])
    if not picked:
        ctx.ui.info("Nothing selected - nothing was uninstalled.")
        return Result(True, "nothing")
    if "everything" in picked:
        picked = ["everything"]
    lines = [{o.id: o.label for o in options}[key] for key in picked]
    if "database" in picked or "everything" in picked:
        lines += ["", "Database: the local Exasol Personal deployment", "The deployment IS the database - removing it cannot be undone."]
    ctx.ui.text("")
    ctx.ui.panel("This will PERMANENTLY remove", lines)
    ctx.ui.warn("This is IRREVERSIBLE. Removed data cannot be recovered.")
    if ctx.ui.prompt("Type UNINSTALL to remove the items above (anything else cancels)", "") != "UNINSTALL":
        ctx.ui.info("Uninstall cancelled - nothing was removed.")
        return Result(True, "cancelled")
    for key in picked:
        remove_component(ctx, key)
    if "everything" in picked:
        _done_everything(ctx)
    else:
        ctx.ui.ok("Done. See where you stand with: exakit info")
    return Result(True, "removed", data={"removed": picked})


def _done_everything(ctx: Context) -> None:
    if ctx.env.get("EXAKIT_UNINSTALL_DB_SKIPPED") == "1":
        ctx.ui.ok("Done. The kit is gone - but the database was left in place (see the note above).")
    else:
        ctx.ui.ok("Done. The kit is gone.")
    ctx.ui.info(f"Install it again any time: {ctx.install_command()}")


def run(ctx: Context, args: list[str]) -> Result:
    """``exakit uninstall``."""
    targets = [a for a in args if not a.startswith("-")]
    for arg in args:
        if arg.startswith("-") and arg not in ("-y", "--yes", "-n", "--dry-run"):
            raise BadInput(f"Unknown option '{arg}' for uninstall (supported: --yes, --dry-run, or one add-on id).")
    dry = ctx.dry_run or "-n" in args or "--dry-run" in args
    yes = ctx.yes or "-y" in args or "--yes" in args
    if len(targets) > 1:
        raise BadInput("uninstall takes at most one add-on id.")
    if targets:
        if not ctx.catalog.has_addon(targets[0]):
            raise BadInput(f"Unknown uninstall target '{targets[0]}' (known add-ons: {marketplace.known_ids(ctx)}; bare 'exakit uninstall' removes the kit).")
        ctx.yes, ctx.dry_run = yes, dry
        return marketplace.uninstall_addon(ctx, targets[0])
    if not ctx.manifest_store.exists() and not (ctx.paths.bin_dir / "exasol").exists() and not (ctx.paths.bin_dir / "exakit").exists() \
            and not ctx.paths.home.is_dir():
        ctx.ui.info("Nothing to uninstall - no manifest, kit home, or installed binaries were found.")
        return Result(True, "nothing")
    if dry:
        ctx.ui.text("")
        ctx.ui.warn("exakit uninstall PERMANENTLY removes the Exasol Personal Local Starter Kit.")
        ctx.ui.info("A full uninstall (the EVERYTHING row, or --yes) removes:")
        gone = remove_everything(ctx, dry=True)
        ctx.ui.text("")
        ctx.ui.info("Not touched: uv/uvx (shared tool), any PATH line in your shell profile, and anything the kit did not install.")
        ctx.ui.info("Dry run only - nothing was removed. Pick individual pieces interactively with: exakit uninstall")
        return Result(True, "dry-run", data={"would_remove": gone})
    if yes:
        return _full(ctx)
    return _menu(ctx)


def _full(ctx: Context) -> Result:
    ctx.ui.text("")
    ctx.ui.warn("exakit uninstall --yes removes the FULL kit (all local database data included).")
    ctx.ui.info("About to remove:")
    remove_everything(ctx, dry=True)
    ctx.ui.text("")
    ctx.ui.info("There is no export step: the kit cannot copy your tables out, and this does not stop to ask.")
    ctx.ui.info("To keep anything, stop now (Ctrl-C) and copy it out first, one table at a time:")
    ctx.ui.info(f"  exapump sql -p {ctx.env.get('EXAKIT_EXAPUMP_PROFILE') or 'starter-kit'} -f csv 'SELECT * FROM <SCHEMA>.<TABLE>' > <TABLE>.csv")
    ctx.ui.info("  ...which exakit data-load <TABLE>.csv loads back into a new install (the file name becomes the table name).")
    ctx.ui.text("")
    gone = remove_everything(ctx, dry=False)
    ctx.ui.text("")
    ctx.ui.ok("Uninstall complete - the Exasol Personal Local Starter Kit has been removed.")
    ctx.ui.info(f"If a PATH entry for {ctx.paths.bin_dir} remains in your shell profile (~/.zshrc, ~/.bashrc, ~/.profile), remove it manually if you no longer need it.")
    return Result(True, "removed", data={"removed": gone})
