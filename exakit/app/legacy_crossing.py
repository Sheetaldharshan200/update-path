"""The crossing from an older kit's container database, asked once during the install (``exakit migrate`` is app.migrate)."""

from __future__ import annotations

from pathlib import Path

from exakit.ui.widgets import Option

from . import Context
from . import legacy_db as ldb
from .runtime_ops import exapump

READY_BUDGET = 120

__all__ = ["READY_BUDGET", "choose", "crossing_after", "crossing_before"]


def _forget_old_steps(ctx: Context) -> None:
    ctx.manifest_store.update(lambda m: [m.unmark_step(s) for s in ("runtime", "exapump", "mcp", "pyexasol", "exakit_helper")])


def _reachable(ctx: Context, db: ldb.LegacyDb, state: str) -> tuple[bool, bool, str]:
    """(can copy, worth retrying later, why not)."""
    if db.engine is None:
        return False, True, "the container engine this database needs is not on this machine any more"
    if state == "absent":
        return False, False, "the container is gone, so there is nothing left to copy"
    if state == "unknown":
        return False, True, f"{db.engine_name} is not answering (is Docker Desktop or the Podman machine running?)"
    if exapump(ctx) is None:
        return False, True, "exapump is not installed yet, and it is what reads the tables out"
    return True, False, ""


def crossing_before(ctx: Context) -> None:
    """Before step 1: an older kit's container database is stopped, and its tables copied out for the restore later."""
    if not ldb.recorded_type(ctx):
        return
    _forget_old_steps(ctx)
    manifest = ctx.manifest()
    db = ldb.from_record(ctx)
    if manifest.get("legacy.crossing_done") is True or manifest.get("legacy.choice"):
        ldb.stop_container(ctx, db)
        return
    state = db.state(ctx)
    ldb.remember(ctx, db)
    can, retry, why = _reachable(ctx, db, state)
    started = False
    if can and state == "stopped":
        started = ldb.start_container(ctx, db)
        if not started:
            can, retry, why = False, True, "the old container would not start"
    found: ldb.Classified = ldb.Classified()
    if can:
        if not ldb.write_legacy_profile(ctx, db):
            can, retry, why = False, True, "the password for the old database is not on file, so it cannot be read"
        elif not ldb.wait_db(ctx, READY_BUDGET if started else 10):
            can, retry, why = False, True, "the old database did not answer in time"
        else:
            found = ldb.classify(ctx, ldb.tables(ctx))
            if not found.own:
                can, retry = False, False
                why = (f"the old database holds only the kit's bundled sample data ({','.join(found.sample_ids)}), unchanged, which this install loads itself"
                       if found.sample else "the old database has no tables in it")
    if not can:
        _no_offer(ctx, db, retry, why, found, manifest.runtime_type() or "")
        return
    _copy_out(ctx, db, state, found, manifest.runtime_type() or "")


def _no_offer(ctx: Context, db: ldb.LegacyDb, retry: bool, why: str, found: ldb.Classified, crossed_from: str) -> None:
    ctx.log.line("INFO", f"legacy crossing: no offer made - {why}")
    ldb.stop_container(ctx, db)
    def change(m):
        if retry:
            m.set("legacy.offer_blocked", why)
            return
        m.set("legacy.choice", "skip")
        m.set("legacy.crossed_from", crossed_from)
        if found.sample:
            m.set("legacy.sample_left_out", ",".join(found.sample_ids))
        m.set("legacy.crossing_done", True)
    ctx.manifest_store.update(change)


def _copy_out(ctx: Context, db: ldb.LegacyDb, state: str, found: ldb.Classified, crossed_from: str) -> None:
    directory = ldb.export_dir(ctx)
    def change(m):
        m.set("legacy.crossed_from", crossed_from)
        m.set("legacy.tables_total", len(found.own) + len(found.sample))
        m.set("legacy.tables_own", len(found.own))
        m.set("legacy.tables_sample", len(found.sample))
        m.set("legacy.container_state", state)
        if found.sample:
            m.set("legacy.sample_left_out", ",".join(found.sample_ids))
    ctx.manifest_store.update(change)
    if (directory / "index").is_file() and (directory / "index").stat().st_size and not ctx.manifest().get("legacy.restored"):
        ctx.log.line("INFO", f"legacy crossing: a copy is already waiting at {directory}")
        ctx.manifest_store.update(lambda m: m.set("legacy.export_dir", str(directory)))
        ldb.stop_container(ctx, db)
        return
    ctx.ui.text("")
    if ldb.export(ctx, directory, found.own):
        ctx.manifest_store.update(lambda m: m.set("legacy.export_dir", str(directory)))
    else:
        ctx.log.line("WARN", f"legacy crossing: nothing could be copied out of {db.container}")
        ctx.manifest_store.update(lambda m: m.set("legacy.offer_blocked", "nothing could be copied out of the old database"))
    ldb.stop_container(ctx, db)
    ctx.ui.text("")


def choose(ctx: Context, count: int, can: bool, why: str) -> str:
    """migrate | skip: the environment's answer, else the question on a terminal, else skip."""
    answer = ctx.env.get("EXAKIT_LEGACY_DATA", "").lower()
    if answer in ("migrate", "yes", "1"):
        if can:
            return "migrate"
        ctx.ui.warn(f"EXAKIT_LEGACY_DATA asked for a migration, but {why}")
        return "skip"
    if answer in ("skip", "no", "0"):
        return "skip"
    if not can:
        ctx.ui.warn(f"Your data cannot be copied automatically: {why}")
        return "skip"
    if not ctx.ui.interactive:
        ctx.ui.info("Nothing is asked in an unattended run, so the old database is left alone.")
        ctx.ui.info("To copy it into the new one, re-run with EXAKIT_LEGACY_DATA=migrate - or afterwards: exakit migrate docker-nano")
        return "skip"
    picked = ctx.ui.select("Your existing database", [
        Option("migrate", f"Migrate my data - copy {count} table(s) into the new database"),
        Option("skip", "Skip and continue - set up the new database empty, and leave the old one alone")], default=1)
    return "skip" if picked == "skip" else "migrate"


def crossing_after(ctx: Context, *, runtime_failed: bool) -> None:
    """Once the new database is up: ask (once), then restore the copy that is waiting."""
    manifest = ctx.manifest_or_none()
    directory = Path(manifest.get("legacy.export_dir") or "") if manifest else Path("")
    if not manifest or not str(directory) or not (directory / "index").is_file() or manifest.get("legacy.restored") not in (None, ""):
        return
    db = ldb.from_record(ctx)
    if runtime_failed:
        ctx.ui.text("")
        if db.container and ldb.start_container(ctx, db):
            ctx.ui.info(f"Your previous database ({db.container}) is running again, with all its data, while the new one is not installed.")
        ctx.ui.info(f"Your data is safe: the copy is kept at {directory}, and nothing in the old database was changed.")
        ctx.ui.info(f"Re-run the installer to finish - it offers to copy your data in once the new database is up: {ctx.install_command()}")
        return
    if not manifest.get("legacy.choice"):
        if not _ask_once(ctx, db, directory):
            return
    else:
        ctx.ui.text("")
        ctx.ui.info("Restoring your data into the new database")
    imported = ldb.import_(ctx, directory)
    if imported is None:
        ctx.ui.warn(f"Your data could not be restored. The copy is kept at {directory}.")
        return
    ldb.report_restore(ctx, directory, "this install had already created them", imported, db)
    ctx.manifest_store.update(lambda m: m.set("legacy.crossing_done", True))




def _ask_once(ctx: Context, db: ldb.LegacyDb, directory: Path) -> bool:
    """The one question: migrate (True) or skip, which also throws the waiting copy away."""
    manifest = ctx.manifest()
    own, sample = manifest.get("legacy.tables_own") or 0, manifest.get("legacy.tables_sample") or 0
    where = f" in the container '{db.container}' (stopped for this install)" if db.container else ""
    rest = f" The other {sample} is the kit's own {manifest.get('legacy.sample_left_out')} sample, which this install loads itself." if sample else ""
    ctx.ui.text("")
    ctx.ui.info(f"Found your previous starter kit's database{where}: {own} table(s) of your own.{rest}")
    choice = choose(ctx, own, True, "")
    ctx.manifest_store.update(lambda m: m.set("legacy.choice", choice))
    if choice == "migrate":
        ctx.ui.info("Nothing in the old database is changed. One thing to know: a text column that held an empty string arrives as NULL.")
        return True
    import shutil
    shutil.rmtree(directory, ignore_errors=True)
    ctx.manifest_store.update(lambda m: (m.set("legacy.export_dir", ""), m.set("legacy.crossing_done", True)))
    ctx.ui.info("The old database is left exactly as it was, stopped, with its data.")
    ctx.ui.info("To copy it into the new database later: exakit migrate docker-nano")
    if db.remove_command():
        ctx.ui.info(f"When you no longer want it: {db.remove_command()}")
    return False
