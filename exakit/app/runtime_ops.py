"""The database as every SQL-speaking command sees it: is it up, and the self-heal when it is not."""

from __future__ import annotations

from pathlib import Path

from exakit.adapters.exapump import DEFAULT_PROFILE, ExapumpCli
from exakit.adapters.fs.credentials import CredentialStore
from exakit.adapters.runtime.personal import PersonalLauncher, PersonalRuntime
from exakit.domain.errors import NotRunning

from . import Context


def credentials(ctx: Context) -> CredentialStore:
    """The credential store, wired once per command."""
    if ctx.credentials is None:
        ctx.credentials = CredentialStore(ctx.paths.credentials)
    return ctx.credentials


def runtime(ctx: Context) -> PersonalRuntime:
    """The runtime adapter, wired once per command."""
    if ctx.runtime is None:
        deploy_dir = Path(ctx.env.get("EXAKIT_PERSONAL_DEPLOY_DIR") or Path(ctx.env.get("HOME") or Path.home()) / ".exasol" / "personal" / "deployments" / "default")
        kit = ctx.catalog.kit
        ctx.runtime = PersonalLauncher(bin_dir=ctx.paths.bin_dir, deploy_dir=deploy_dir, runner=ctx.runner, log=ctx.log, env=dict(ctx.env),
                                       db_port=kit.db_port, probe_timeout=kit.probe_timeout, ready_timeout=kit.ready_timeout,
                                       rebuild_timeout=kit.rebuild_timeout, reap_min_age=kit.reap_min_age)
    return ctx.runtime


def exapump(ctx: Context):
    """The exapump CLI the install recorded, or the one on PATH; None when there is none."""
    if ctx.exapump is not None:
        return ctx.exapump
    manifest = ctx.manifest_or_none()
    recorded = manifest.get("components.exapump.path") if manifest else None
    candidates = [recorded, str(ctx.paths.bin_dir / "exapump"), ctx.runner.which("exapump")]
    for candidate in candidates:
        if candidate and Path(candidate).exists():
            config = Path(ctx.env.get("EXAKIT_EXAPUMP_CONFIG_DIR") or Path(ctx.env.get("HOME") or Path.home()) / ".exapump") / "config.toml"
            return ExapumpCli(candidate, ctx.runner, config_path=config)
    return None


def profile_name(ctx: Context) -> str:
    """The exapump profile the kit uses."""
    return ctx.env.get("EXAKIT_EXAPUMP_PROFILE") or DEFAULT_PROFILE


def is_running(ctx: Context) -> bool:
    """True when the database answers."""
    manifest = ctx.manifest_or_none()
    if manifest is None or manifest.runtime_type() != "personal":
        return False
    return runtime(ctx).running()


def ensure_running(ctx: Context, *, deploy: bool = False) -> None:
    """The legacy decision tree: running -> nothing; deployed -> start and wait; else deploy or refuse."""
    manifest = ctx.manifest_or_none()
    if manifest is None or manifest.runtime_type() != "personal":
        return
    rt = runtime(ctx)
    if rt.running():
        return
    say = ctx.ui.info
    if rt.deployment_exists():
        say("Self-heal: the database is deployed but not running - starting it")
        rt.start(say)
        if not rt.wait_ready_or_deploy(say):
            raise NotRunning("The database is deployed but did not come up. Read the state with 'exakit status', or repair with: exakit repair-runtime",
                             remedy="exakit repair-runtime")
        return
    if deploy:
        say("Self-heal: no database deployment found - deploying one")
        rt.deploy(say)
        return
    raise NotRunning("No database found. Start one with: exakit start (or re-run the installer)", remedy="exakit start")


def runtime_remedy(ctx: Context) -> str:
    """The command that brings the database back."""
    rt = runtime(ctx)
    return "exakit repair-runtime" if rt.wedged() is not None else "exakit start"
