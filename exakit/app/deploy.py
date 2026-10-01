"""The local database deployment step: reuse what runs, start what is stopped, replace only with consent, else deploy."""

from __future__ import annotations

import time

from exakit.adapters.process.ports import port_in_use

from . import Context
from .requirements import install_podman, note_failure, podman_running
from .runtime_ops import credentials, runtime


def _env_answer(ctx: Context, name: str) -> bool | None:
    value = ctx.env.get(name, "").strip().lower()
    return True if value in ("1", "y", "yes") else False if value in ("0", "n", "no") else None


def confirm_env(ctx: Context, name: str, question: str, *, default: bool) -> bool:
    """The environment answers first; a terminal is asked; no terminal takes the default."""
    answer = _env_answer(ctx, name)
    if answer is not None:
        return answer
    return ctx.ui.confirm(question, default=default) if ctx.ui.interactive else default


def record(ctx: Context, status: str | None = None) -> None:
    """Write the runtime's details into the record."""
    rt = runtime(ctx)
    warning = None
    def change(m):
        nonlocal warning
        for key in ("container", "engine", "volume"):
            old = m.get(f"runtime.{key}")
            if old and not m.get(f"legacy.{key}"):
                m.set(f"legacy.{key}", old)
        warning = rt.record(m, credentials(ctx), status)
    ctx.manifest_store.update(change)
    if warning:
        ctx.ui.warn(warning)


def foreign_db_hint(ctx: Context) -> str:
    """A hint when another Exasol listens on the port."""
    rt = runtime(ctx)
    if not rt.tls_answers():
        return ""
    manifest = ctx.manifest_or_none()
    container = manifest.get("legacy.container") if manifest else None
    if container:
        engine = manifest.get("legacy.engine") or "docker"
        return (f" It is the container database of your previous starter kit ({container}), which this kit no longer manages. "
                f"Stop it ({engine} stop {container}) and re-run the installer, which then offers to copy its data across.")
    hint = " It answers like an Exasol database this kit did not deploy: stop that database first, then re-run."
    if ctx.platform.is_wsl:
        hint += " WSL and Windows share this port, so one deployed on the Windows side holds it here too (stop it there with: exakit stop)."
    return hint


def _reuse_running(ctx: Context) -> bool:
    rt = runtime(ctx)
    ctx.ui.info(f"An Exasol database is already running on port {rt.db_port()}.")
    if confirm_env(ctx, "EXAKIT_REUSE_DB", "Use it instead of deploying a new one?", default=True):
        ctx.ui.ok("Reusing the existing Exasol deployment")
        record(ctx, "healthy")
        return True
    ctx.ui.info(f"Stop it first ('exakit stop', or 'exasol stop'), then re-run the installer to deploy a fresh one - port {rt.db_port()} "
                f"stays in use while it is running: {ctx.install_command()}")
    note_failure(ctx, f"Declined to reuse the database already running on port {rt.db_port()}")
    return False


def _start_existing(ctx: Context) -> bool | None:
    """An existing, stopped deployment: retry a failed deploy, or start it and keep its data. None = fall through to replace."""
    rt = runtime(ctx)
    if rt.launcher_state() == "deployment_failed":
        ctx.ui.info("The launcher records this deployment as failed - retrying its deploy.")
        with ctx.ui.busy("Retrying the deployment"):
            recovered = rt.deploy_again() or rt.recover_slow_first_boot(ctx.ui.info)
        if recovered:
            ctx.ui.ok("Reusing the existing Exasol deployment (deployed again)")
            if not rt.wait_ready_or_deploy(ctx.ui.info):
                return False
            record(ctx, "healthy")
            return True
        ctx.ui.warn(f"The failed deployment could not be brought up.{foreign_db_hint(ctx)}")
    ctx.ui.info("An Exasol deployment was found, not running.")
    if not confirm_env(ctx, "EXAKIT_REUSE_DB", "Start the existing database and keep its data?", default=True):
        return None
    manifest = ctx.manifest_or_none()
    if rt.guest_rebuild_expected(manifest.get("runtime.guest_rebuilt_for") if manifest else None, ctx.env.get("EXAKIT_PERSONAL_VERSION")):
        ctx.ui.info("This deployment was created by an earlier launcher, so the first start rebuilds its VM guest - slower than usual, once. Your data is kept.")
    for attempt in ("started", "started after clearing an orphaned runner"):
        try:
            if attempt.endswith("runner") and not rt.reap_orphan(rt.db_port(), ctx.ui.info):
                continue
            rt.start(ctx.ui.info)
        except Exception as err:
            ctx.log.line("WARN", f"the deployment did not start ({attempt}): {err}")
            continue
        ctx.ui.ok(f"Reusing the existing Exasol deployment ({attempt})")
        if not rt.wait_ready_or_deploy(ctx.ui.info):
            return False
        record(ctx, "healthy")
        return True
    ctx.ui.warn("The existing deployment could not be started, even after clearing orphaned runners.")
    return None


def _replace_or_refuse(ctx: Context) -> bool:
    rt = runtime(ctx)
    if not confirm_env(ctx, "EXAKIT_REPLACE_DB", "DELETE the stopped deployment and its data, and deploy a fresh one? This cannot be undone.", default=False):
        ctx.ui.info("Nothing was deleted. Start it yourself with 'exakit start', diagnose with 'exakit status', repair with 'exakit repair-runtime' - "
                    "or re-run with EXAKIT_REPLACE_DB=1 to replace it, deleting its data.")
        note_failure(ctx, "A stopped deployment could not be started, and deleting it was declined")
        return False
    ctx.ui.info("Replacing the existing deployment - its previous data is not recoverable.")
    if not rt.destroy():
        ctx.ui.warn("Could not fully remove the old deployment; the launcher will deploy over it.")
    return True


def _deploy_fresh(ctx: Context) -> bool:
    rt = runtime(ctx)
    if port_in_use(rt.db_port()) and not rt.reap_orphan(rt.db_port(), ctx.ui.info):
        ctx.ui.warn(f"Port {rt.db_port()} is in use by a process that is not a reachable Exasol Personal deployment.{foreign_db_hint(ctx)}")
        ctx.ui.info(f"Stop that application, then re-run the installer (EXAKIT_DB_PORT does not choose the port of a personal deployment): {ctx.install_command()}")
        note_failure(ctx, f"Port {rt.db_port()} is held by something that is not an Exasol Personal deployment")
        return False
    ctx.ui.info("Exasol Personal is free to use and ships under Exasol's own licence terms, not the kit's MIT licence. The launcher shows them below.")
    ctx.ui.info("Deploying Exasol Personal locally - about 2 minutes")
    started = time.monotonic()
    with ctx.ui.busy("Deploying the local database"):
        ok, tail = rt.install_local()
    if not ok and not (rt.deployment_exists() and rt.recover_slow_first_boot(ctx.ui.info)):
        for line in tail.splitlines():
            ctx.ui.text(f"      | {line}")
        ctx.ui.warn(f"Local deployment failed.{foreign_db_hint(ctx)}")
        ctx.ui.info(f"Retry it by re-running the installer - completed steps are skipped: {ctx.install_command()}")
        note_failure(ctx, "The launcher could not deploy the database locally")
        return False
    if not rt.wait_ready_or_deploy(ctx.ui.info):
        ctx.ui.info(f"Retry it by re-running the installer ({ctx.install_command()}), or read the state with 'exakit status'.")
        return False
    ctx.ui.ok(f"Exasol Personal deployed and answering on 127.0.0.1:{rt.db_port()} ({int(time.monotonic() - started)}s)")
    record(ctx, "healthy")
    return True


def deploy_local(ctx: Context) -> bool:
    """The step body. False means the reason was said and noted; the install carries on without a database."""
    if not install_podman(ctx) or not podman_running(ctx):
        return False
    rt = runtime(ctx)
    if rt.running():
        return _reuse_running(ctx)
    if rt.deployment_exists():
        outcome = _start_existing(ctx)
        if outcome is not None:
            return outcome
        if not _replace_or_refuse(ctx):
            return False
    return _deploy_fresh(ctx)
