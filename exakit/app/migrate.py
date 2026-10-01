"""``exakit migrate docker-nano``: the after-the-install road of the crossing, for a skipped copy or a container the kit never saw."""

from __future__ import annotations

import shutil
import time
from dataclasses import dataclass
from pathlib import Path

from exakit.adapters.process.ports import port_in_use
from exakit.domain.errors import BadInput, NotConfirmed, NotRunning
from exakit.domain.manifest import utc_now
from exakit.domain.result import Result

from . import Context
from . import legacy_db as ldb
from .legacy_crossing import READY_BUDGET
from .runtime_ops import exapump, runtime




@dataclass(slots=True)
class MigrateOutcome:
    status: str = "failed"
    reason: str | None = None
    remedy: str | None = None
    exported: int = 0
    imported: ldb.Imported | None = None
    sample_ids: list[str] | None = None

    @property
    def ok(self) -> bool:
        """True when the migration finished or had nothing to do."""
        return self.status in ("done", "nothing")


def _fail(ctx: Context, outcome: MigrateOutcome, reason: str, remedy: str | None = None) -> MigrateOutcome:
    outcome.status, outcome.reason, outcome.remedy = "failed", reason, remedy
    ctx.ui.error(reason)
    if remedy:
        ctx.ui.info(f"Then: {remedy}")
    ctx.log.line("ERROR", f"legacy migrate: {reason}")
    return outcome


def _settle(ctx: Context, db: ldb.LegacyDb, started: bool, clash: bool, db_stopped: bool) -> bool:
    if started or clash:
        ldb.stop_container(ctx, db)
    rt = runtime(ctx)
    if db_stopped or not rt.running():
        with ctx.ui.busy("Starting your database again"):
            rt.start(ctx.ui.info)
            return rt.wait_ready(ctx.ui.info)
    return True


def _restore_waiting(ctx: Context, db: ldb.LegacyDb, directory: Path, outcome: MigrateOutcome) -> MigrateOutcome:
    ctx.ui.info(f"A copy from an earlier run is waiting at {directory} - restoring it first")
    imported = ldb.import_(ctx, directory)
    if imported is None:
        return _fail(ctx, outcome, f"The waiting copy could not be restored; it is kept at {directory}.")
    outcome.imported = imported
    ctx.manifest_store.update(lambda m: m.set("legacy.choice", "migrate"))
    if ldb.report_restore(ctx, directory, "the new database already had them", imported, db):
        ctx.manifest_store.update(lambda m: m.set("legacy.crossing_done", True))
        ctx.ui.info("Run the command again for a fresh copy of what is in the container now.")
        outcome.status = "done"
        return outcome
    outcome.status, outcome.remedy = "partial", "exakit migrate docker-nano"
    return outcome


def _stop_for_port(ctx: Context, db_port: int, outcome: MigrateOutcome) -> bool:
    rt = runtime(ctx)
    with ctx.ui.busy("Stopping your database for the copy"):
        try:
            rt.stop(ctx.ui.info)
        except Exception:
            _fail(ctx, outcome, "Your database could not be stopped, so the container cannot take the port.", "exakit stop, then exakit migrate docker-nano")
            return False
    for _ in range(15):
        if not port_in_use(db_port):
            return True
        time.sleep(1)
    rt.reap_orphan(db_port, ctx.ui.info)
    for _ in range(5):
        if not port_in_use(db_port):
            return True
        time.sleep(1)
    rt.start(ctx.ui.info)
    _fail(ctx, outcome, f"Your database was told to stop, but port {db_port} is still held, so the old container cannot take it.",
          f"exakit stop, then check the port (ss -ltnp | grep {db_port}) before: exakit migrate docker-nano")
    return False


def migrate_now(ctx: Context, db: ldb.LegacyDb, *, yes: bool) -> MigrateOutcome:
    """Run the migration: export, stop, import, report."""
    outcome = MigrateOutcome()
    if not db.container:
        return _fail(ctx, outcome, "No container is named. Say which one holds the old database: exakit migrate docker-nano --container <name>")
    if db.engine is None:
        return _fail(ctx, outcome, f"The container engine '{db.engine_name or '?'}' is not on this machine, so the container '{db.container}' cannot be reached.",
                     "exakit migrate docker-nano --engine docker|podman")
    state = db.state(ctx)
    if state == "absent":
        return _fail(ctx, outcome, f"There is no container named '{db.container}' in {db.engine_name}. List them with '{db.engine_name} ps -a' and name the right one with --container.")
    if state == "unknown":
        return _fail(ctx, outcome, f"{db.engine_name} did not answer about the container '{db.container}' - it looks stopped. Start it (Docker Desktop, or: podman machine start), then run: exakit migrate docker-nano")
    if exapump(ctx) is None:
        return _fail(ctx, outcome, "exapump is not installed, and it is what reads the tables out.", "exakit update")
    directory = ldb.export_dir(ctx)
    if (directory / "index").is_file() and (directory / "index").stat().st_size and ctx.manifest().get("legacy.restored") in (None, ""):
        return _restore_waiting(ctx, db, directory, outcome)
    rt = runtime(ctx)
    clash = db.dsn.rpartition(":")[2] == str(rt.db_port())
    db_running = rt.running()
    ctx.ui.text("")
    ctx.ui.info(f"Copying the tables of the container '{db.container}' ({db.engine_name}, {state}) into your database.")
    ctx.ui.info("The kit's bundled sample data is left out - the kit loads that itself. Nothing in the container is changed or removed.")
    ctx.ui.info("One caveat worth knowing: a text column that held an empty string arrives as NULL.")
    if clash and db_running:
        ctx.ui.warn(f"The container publishes port {db.dsn.rpartition(':')[2]}, the port your database uses, so the two cannot run at once.")
        ctx.ui.info("Your database is stopped while the tables are copied out, and started again before they are copied in.")
    if not yes and not (ctx.ui.interactive and ctx.ui.confirm("Go ahead?", default=True)):
        ctx.ui.info("Nothing was changed.")
        outcome.status = "declined"
        return outcome
    return _copy_and_restore(ctx, db, state, directory, outcome, clash=clash and db_running)


def _copy_and_restore(ctx: Context, db: ldb.LegacyDb, state: str, directory: Path, outcome: MigrateOutcome, *, clash: bool) -> MigrateOutcome:
    db_stopped = False
    if clash:
        if not _stop_for_port(ctx, runtime(ctx).db_port(), outcome):
            return outcome
        db_stopped = True
    started = False
    if state != "running":
        ctx.ui.info(f"Starting the container '{db.container}'")
        if not ldb.start_container(ctx, db):
            if db_stopped:
                runtime(ctx).start(ctx.ui.info)
            return _fail(ctx, outcome, f"The container '{db.container}' would not start (see '{db.engine_name} logs {db.container}').")
        started = True
    if not ldb.write_legacy_profile(ctx, db):
        _settle(ctx, db, started, clash, db_stopped)
        return _fail(ctx, outcome, "The password of the old database is not on file. Pass it with --password-file <path> (a file holding only the password), or answer the prompt on a terminal.")
    budget = READY_BUDGET if started else 10
    with ctx.ui.busy("Waiting for the old database to answer"):
        answered = ldb.wait_db(ctx, budget)
    if not answered:
        _settle(ctx, db, started, clash, db_stopped)
        return _fail(ctx, outcome, f"The old database did not answer within {budget}s. Is the password right, and is {db.dsn} where the container listens ('{db.engine_name} port {db.container}')?")
    found = ldb.classify(ctx, ldb.tables(ctx))
    outcome.sample_ids = found.sample_ids
    if found.sample:
        ctx.manifest_store.update(lambda m: m.set("legacy.sample_left_out", ",".join(found.sample_ids)))
    if not found.own:
        _nothing_of_yours(ctx, found)
        _settle(ctx, db, started, clash, db_stopped)
        ctx.manifest_store.update(lambda m: (m.set("legacy.choice", "migrate"), m.set("legacy.crossing_done", True)))
        outcome.status = "nothing"
        return outcome
    ctx.ui.info(f"The container holds {len(found.own) + len(found.sample)} table(s).")
    if found.sample:
        ctx.ui.info(f"{len(found.sample)} of them belong to the kit's bundled sample data ({','.join(found.sample_ids)}), unchanged - the kit loads that itself, so they are not copied. Your own: {len(found.own)} table(s).")
    return _export_then_restore(ctx, db, directory, outcome, found, started=started, clash=clash, db_stopped=db_stopped)


def _nothing_of_yours(ctx: Context, found: ldb.Classified) -> None:
    if found.sample:
        ctx.ui.info(f"The container holds {len(found.sample)} table(s), all of them the kit's bundled sample data ({','.join(found.sample_ids)}), unchanged - nothing of yours to copy.")
        ctx.ui.info("The kit loads that data itself: exakit data-load")
    else:
        ctx.ui.info("The old database has no tables in it - nothing to copy.")


def _export_then_restore(ctx: Context, db: ldb.LegacyDb, directory: Path, outcome: MigrateOutcome, found: ldb.Classified, *,
                         started: bool, clash: bool, db_stopped: bool) -> MigrateOutcome:
    shutil.rmtree(directory, ignore_errors=True)
    ctx.manifest_store.update(lambda m: [m.delete(k) for k in ("legacy.restored", "legacy.restore_skipped", "legacy.restore_failed")])
    ctx.ui.info(f"Copying {len(found.own)} table(s) out of the old database")
    outcome.exported = ldb.export(ctx, directory, found.own)
    if not outcome.exported:
        _settle(ctx, db, started, clash, db_stopped)
        return _fail(ctx, outcome, "Nothing could be copied out. The old database is untouched; nothing is lost.")
    ctx.manifest_store.update(lambda m: m.set("legacy.export_dir", str(directory)))
    ctx.ui.ok(f"Copied {outcome.exported} table(s) out; they are saved at {directory}")
    if not _settle(ctx, db, started, clash, db_stopped):
        return _fail(ctx, outcome, f"Your database did not come back, so the copy is not restored yet. It is kept at {directory}.", "exakit start, then exakit migrate docker-nano")
    ctx.ui.info("Restoring your data into the new database")
    imported = ldb.import_(ctx, directory)
    if imported is None:
        return _fail(ctx, outcome, f"Your data could not be restored. The copy is kept at {directory}.", "exakit migrate docker-nano")
    outcome.imported = imported
    ctx.manifest_store.update(lambda m: (m.set("legacy.choice", "migrate"), m.set("legacy.crossing_done", True), m.set("legacy.migrated_at", utc_now())))
    if ldb.report_restore(ctx, directory, "the new database already had them", imported, db):
        outcome.status = "done"
        return outcome
    failed_out = ctx.manifest().get("legacy.export_failed") or 0
    outcome.status = "partial"
    outcome.reason = (f"{failed_out} table(s) could not be copied out of the old database and are still only there" if failed_out
                      else f"{imported.failed} table(s) did not restore")
    outcome.remedy = "exakit migrate docker-nano"
    return outcome


# --- the command -------------------------------------------------------------------------------------


USAGE = "exakit migrate docker-nano [--container NAME] [--engine docker|podman] [--dsn HOST:PORT] [--user USER] [--password-file PATH] [--yes] [--json]"


def parse_args(args: list[str]) -> tuple[dict[str, str], bool]:
    """The overrides and the --yes flag."""
    source = args[0] if args else ""
    if source != "docker-nano":
        if not source or source.startswith("-"):
            raise BadInput(f"migrate needs a source. The one there is: {USAGE}")
        raise BadInput(f"Unknown migration source '{source}' (known: docker-nano).")
    overrides: dict[str, str] = {}
    yes = False
    rest = args[1:]
    i = 0
    while i < len(rest):
        arg = rest[i]
        key, _, inline = arg.partition("=")
        if key in ("--container", "--engine", "--dsn", "--user", "--password-file"):
            value = inline if "=" in arg else (rest[i + 1] if i + 1 < len(rest) else "")
            if not value:
                raise BadInput(f"{key} needs a value.")
            overrides[key.lstrip("-").replace("-", "_")] = value
            i += 1 if "=" in arg else 2
            continue
        if key in ("--password",):
            raise BadInput("A password does not go on the command line, where every process can read it. Put it in a file and pass --password-file <path>, set EXAKIT_LEGACY_PASSWORD, or answer the prompt.")
        if arg in ("--yes", "-y"):
            yes = True
        elif arg not in ("--json", "-j"):
            raise BadInput(f"Unknown option '{arg}' for migrate (supported: --container, --engine, --dsn, --user, --password-file, --yes, --json).")
        i += 1
    if overrides.get("engine") not in (None, "docker", "podman"):
        raise BadInput(f"--engine must be docker or podman, not '{overrides['engine']}'.")
    if "dsn" in overrides and not overrides["dsn"].rpartition(":")[2].isdigit():
        raise BadInput("--dsn must be HOST:PORT, e.g. 127.0.0.1:8563.")
    if "password_file" in overrides and not Path(overrides["password_file"]).is_file():
        raise BadInput(f"--password-file: {overrides['password_file']} is missing or empty.")
    return overrides, yes


def migrate(ctx: Context, args: list[str]) -> Result:
    """``exakit migrate docker-nano``."""
    overrides, yes = parse_args(args)
    ctx.manifest()
    if ctx.manifest().runtime_type() != "personal":
        raise NotRunning("This install has no Exasol Personal deployment to copy into yet.", remedy=ctx.install_command(), data={"installed": True, "status": "no database"})
    db = ldb.from_record(ctx, **overrides)
    if db.engine is None and not overrides.get("engine"):
        raise NotRunning(f"Neither docker nor podman on this machine has a container named '{db.container}'.",
                         remedy="exakit migrate docker-nano --engine docker --container <name>   (list them with: docker ps -a, or podman ps -a)",
                         data={"installed": True, "status": "no container"})
    if not ldb.password_of(db):
        if ctx.ui.interactive and not ctx.json:
            db.password = ctx.ui.prompt(f"Password of the {db.user} user in the old database", "") or None
            if not db.password:
                raise BadInput("No password was given.")
        else:
            raise NotRunning("The old database's password is not on file, and there is no terminal to ask on.",
                             remedy="exakit migrate docker-nano --password-file <path>   (a file holding only the password; or set EXAKIT_LEGACY_PASSWORD)",
                             data={"installed": True, "status": "no password"})
    outcome = migrate_now(ctx, db, yes=yes or ctx.yes)
    if outcome.status == "declined":
        raise NotConfirmed("Nothing was changed.", remedy="exakit migrate docker-nano --yes", data={"status": "declined"})
    imported = outcome.imported or ldb.Imported()
    data = {"ok": outcome.ok, "container": db.container, "engine": db.engine_name, "dsn": db.dsn, "copied_out": outcome.exported,
            "restored": imported.ok, "left_alone": imported.skipped, "failed": imported.failed, "sample_left_out": outcome.sample_ids or [],
            "reason": outcome.reason}
    return Result(True, outcome.status, remedy=outcome.remedy, data=data, exit_code=0 if outcome.ok else 1)
