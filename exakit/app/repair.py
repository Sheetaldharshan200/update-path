"""``exakit repair-runtime``: rebuild a database that cannot be started. Destructive, asked first, exit 5 when declined."""

from __future__ import annotations

from exakit.domain.errors import BadInput, ExakitError, NotConfirmed, NotRunning
from exakit.domain.result import Result

from . import Context, data, install


def _confirmed(ctx: Context, yes: bool) -> bool:
    if yes or ctx.env.get("EXAKIT_CONFIRM_RUNTIME_REPAIR") == "1":
        return True
    return ctx.ui.interactive and ctx.ui.confirm("Delete everything in the database and rebuild it empty?", default=False)


def _explain(ctx: Context) -> None:
    ctx.ui.warn("This rebuilds your database from empty. Every table in it is deleted and cannot be recovered.")
    if ctx.json:
        return
    profile = ctx.env.get("EXAKIT_EXAPUMP_PROFILE") or "starter-kit"
    ctx.ui.info("The bundled sample datasets are reloaded afterwards. Anything you loaded yourself is not.")
    ctx.ui.info("If the database still answers, copy out anything you want to keep first, one table at a time:")
    ctx.ui.info(f"  exapump sql -p {profile} -f csv 'SELECT * FROM <SCHEMA>.<TABLE>' > <TABLE>.csv")
    ctx.ui.info("  ...and load it back afterwards with: exakit data-load <TABLE>.csv  (the file name becomes the table name, so keep it)")


def reset_dataset_flags(ctx: Context) -> None:
    """Forget which datasets were loaded."""
    datasets = data.bundled(ctx)
    def change(m):
        for ds in datasets:
            m.set(ds.flag, False)
            m.set(f"data.datasets.{ds.id}.loaded", False)
        m.unmark_step("runtime")
    ctx.manifest_store.update(change)


def run(ctx: Context, args: list[str]) -> Result:
    """``exakit repair-runtime``: rebuild the deployment with consent."""
    yes = ctx.yes
    for arg in args:
        if arg in ("--yes", "-y"):
            yes = True
        elif arg not in ("--json", "-j"):
            raise BadInput(f"Unknown option '{arg}' for repair-runtime (supported: --yes, --json).")
    ctx.manifest()
    _explain(ctx)
    if not _confirmed(ctx, yes):
        ctx.ui.info("Repair cancelled - nothing was changed.")
        ctx.ui.info("When you are ready: exakit repair-runtime --yes (or set EXAKIT_CONFIRM_RUNTIME_REPAIR=1)")
        raise NotConfirmed("not confirmed", remedy="exakit repair-runtime --yes",
                           hint="this DESTROYS the database and its data - ask the user before running it",
                           data={"status": "declined", "reason": "not confirmed", "changed": False})
    reset_dataset_flags(ctx)
    ctx.ui.info("Re-running the installer to rebuild the database")
    ctx.env = {**dict(ctx.env), "EXAKIT_BANNER_SHOWN": "1", "EXAKIT_REUSE_DB": "0", "EXAKIT_REPLACE_DB": "1"}
    ctx.dry_run = False
    try:
        outcome = install.run(ctx)
    except ExakitError as err:
        raise NotRunning("the rebuild did not finish (see exakit logs)", remedy=ctx.install_command(),
                         data={"status": "failed", "changed": True, "reason": err.message}) from None
    if outcome.status == "installed" or "runtime" not in outcome.data.get("soft_failures", {}):
        return Result(True, "repaired", data={"ok": True, "changed": True})
    raise NotRunning("the rebuild did not finish (see exakit logs)", remedy=ctx.install_command(), data={"status": "failed", "changed": True})
