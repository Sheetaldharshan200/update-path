"""``exakit install``: the whole install, resumable, with the persona's answers folded in and soft failures reported once."""

from __future__ import annotations

import json
import os
import re
from pathlib import Path

from exakit.adapters.fs.log import FileLog, NullLog
from exakit.adapters.fs.manifest_store import CorruptManifest
from exakit.adapters.fs.notes import lock_holder_alive, process_start_time
from exakit.components import for_component
from exakit.domain.errors import BadInput, ExakitError, Failed
from exakit.domain.manifest import Manifest, utc_now
from exakit.domain.persona import Answers, answers_for
from exakit.domain.plan import Plan, Step, StepState
from exakit.domain.result import Result
from exakit.domain.versions import is_newer
from exakit.ui.widgets import Option

from . import Context, marketplace, services, whats_new
from . import install_steps as steps
from .components_kit import kit_version_at
from .legacy_crossing import crossing_before
from .machine import all_datasets, kit_root
from .marketplace import rows as marketplace_rows
from .requirements import check as check_requirements
import contextlib

TITLES = {"launcher": "Step 1/6  Exasol launcher", "runtime": "Step 2/6  Local database deployment", "exapump": "Step 3/6  exapump (data loading CLI)",
          "mcp": "Step 4/6  AI bridge (MCP server, clients and skills)", "pyexasol": "Step 5/6  pyexasol (Exasol Python driver)",
          "exakit_helper": "Step 6/6  exakit helper command"}


# --- preparation ----------------------------------------------------------------------------


def prepare_home(ctx: Context) -> None:
    """Create the kit home and its folders."""
    ctx.paths.home.mkdir(parents=True, exist_ok=True)
    ctx.paths.logs.mkdir(parents=True, exist_ok=True)
    (ctx.paths.home / "workflows").mkdir(exist_ok=True)
    if isinstance(ctx.log, NullLog):
        ctx.log = FileLog(ctx.paths.logs)


def init_manifest(ctx: Context) -> None:
    """A fresh record, or the existing one; a record that does not parse is kept aside and its ticks recovered."""
    if not ctx.manifest_store.exists():
        ctx.manifest_store.save(Manifest.new(platform=ctx.platform, log_dir=str(ctx.paths.logs)))
        return
    try:
        ctx.manifest_store.load()
        return
    except CorruptManifest:
        pass
    quarantine = ctx.paths.manifest.with_name(f"manifest.json.corrupt-{int(__import__('time').time())}")
    ctx.ui.warn(f"The install manifest at {ctx.paths.manifest} does not parse as JSON (interrupted run?) - kept as {quarantine} and rebuilt; "
                "existing components will be re-detected")
    ctx.paths.manifest.rename(quarantine)
    text = quarantine.read_text(encoding="utf-8", errors="replace")
    match = re.search(r'"steps_completed"\s*:\s*\[([^\]]*)\]', text)
    recovered = re.findall(r'"([a-z_]+)"', match.group(1)) if match else []
    ctx.manifest_store.save(Manifest.new(platform=ctx.platform, log_dir=str(ctx.paths.logs), steps_completed=recovered))


def acquire_lock(ctx: Context) -> None:
    """Take the install lock, or refuse when another install holds it."""
    lock = ctx.paths.install_lock
    if lock.exists():
        if lock_holder_alive(lock, ctx.runner):
            pid = lock.read_text(encoding="utf-8").splitlines()[0]
            raise Failed(f"Another setup run is already in progress (pid {pid}). Wait for it to finish; if you are sure it is dead, remove {lock} and re-run.")
        ctx.ui.warn("Found a lock from an interrupted run - removing it and continuing")
    lock.write_text(f"{os.getpid()}\n{process_start_time(os.getpid(), ctx.runner)}\n", encoding="utf-8")


def release_lock(ctx: Context) -> None:
    """Release the install lock."""
    ctx.paths.install_lock.unlink(missing_ok=True)
    if ctx.manifest_store.exists():
        ctx.manifest_store.update(lambda m: m.delete("install.current_step"))


def record_kit(ctx: Context, root: Path) -> None:
    """Where this kit came from, what version it is, and (once) the version the next what's-new box starts from."""
    source = ctx.env.get("EXAKIT_KIT_SOURCE") or f"checkout:{root}"
    version = kit_version_at(root)
    def change(m: Manifest) -> None:
        previous = m.get("kit.source")
        if previous and "@" in str(previous) and str(previous).split("@")[0] != source.split("@")[0]:
            ctx.ui.info(f"Updating the starter kit already installed here (from {str(previous).split('@')[0]}).")
            ctx.ui.info("The exakit command, the kit copy and the AI skills are replaced; your database, its credentials and the deployment are kept.")
            m.set("kit.updated_from", str(previous).split("@")[0])
        m.set("os", ctx.platform.os)
        m.set("arch", ctx.platform.arch)
        m.set("kit.source", source)
        was = m.get("kit.version")
        if version and not m.get("kit.whats_new_from"):
            if not was and m.steps_completed():
                m.set("kit.whats_new_from", "__unversioned__")
            elif was and was != version and is_newer(version, was):
                m.set("kit.whats_new_from", was)
        if version:
            m.set("kit.version", version)
        for cid in ("personal", "exapump", "mcp", "pyexasol"):
            with contextlib.suppress(ExakitError):
                m.set(f"desired.{cid}", for_component(ctx, cid).target_version())
    ctx.manifest_store.update(change)


def record_persona(ctx: Context) -> None:
    """The persona the install follows (EXAKIT_PERSONA, already validated) goes into the record as source ``install``."""
    persona_id = ctx.env.get("EXAKIT_PERSONA")
    if not persona_id:
        return

    def change(m: Manifest) -> None:
        m.set("persona.id", persona_id)
        m.set("persona.source", "install")
        m.set("persona.requested_at", m.get("persona.requested_at") or utc_now())
    ctx.manifest_store.update(change)


def resolve_answers(ctx: Context) -> Answers:
    """The persona's answers, with an explicit environment answer winning per variable; the environment carries them on."""
    persona_id = ctx.env.get("EXAKIT_PERSONA")
    if persona_id:
        if persona_id not in ctx.catalog.persona_ids():
            raise BadInput(f"Unknown persona '{persona_id}' (EXAKIT_PERSONA). Known personas: {' '.join(ctx.catalog.persona_ids())}.")
        answers = answers_for(ctx.catalog.persona(persona_id), ctx.env, all_datasets=all_datasets(ctx))
        ctx.env = {**dict(ctx.env), **answers.env(), "EXAKIT_PERSONA_ACTIVE": "1"}
        ctx.log.line("INFO", f"persona {persona_id}: {answers.env()}")
        return answers
    return answers_for(ctx.catalog.persona(ctx.catalog.persona_ids()[0]), ctx.env, all_datasets=all_datasets(ctx)) \
        if ctx.catalog.persona_ids() else Answers(("tpch",), "all", (), frozenset())


# --- the closing sequence ----------------------------------------------------------------------


def connection_summary(ctx: Context) -> None:
    """Print the connection panel: DSN, users, password files."""
    manifest = ctx.manifest()
    home = ctx.env.get("HOME", "")
    creds = str(ctx.paths.credentials).replace(home, "~", 1) if home else str(ctx.paths.credentials)
    ctx.ui.text("")
    ctx.ui.panel("Your local Exasol", [
        f"{'DSN':<13} {manifest.get('runtime.dsn') or 'unknown'}   (admin {manifest.get('runtime.user') or 'sys'}, TLS self-signed)",
        f"{'Passwords':<13} {creds}/",
        f"{'SQL client':<13} DBeaver (https://dbeaver.io/download/) or DbVisualizer (https://www.dbvis.com/download/)",
        f"{'Everything':<13} exakit info  ·  exakit guide",
    ])


def whats_new_box(ctx: Context, root: Path) -> None:
    """Print the what's-new cards for the versions this install crossed."""
    manifest = ctx.manifest()
    since = manifest.get("kit.whats_new_from")
    to = kit_version_at(root) or manifest.get("kit.version")
    if not since or not to:
        return
    versions = whats_new.crossed(root, "" if since == "__unversioned__" else since, to) if since != "__unversioned__" else whats_new.versions(root)
    shown = False
    for version in versions:
        points = whats_new.points(root, version)
        if points:
            ctx.ui.panel(f"What's new in {version}", [f"- {p}" for p in points])
            shown = True
    if shown or since:
        ctx.manifest_store.update(lambda m: m.delete("kit.whats_new_from"))


def report_soft_failures(session: steps.Session) -> None:
    """Say once which steps did not complete, with their repair commands."""
    ctx = session.ctx
    if not session.soft:
        ctx.ui.text("")
        ctx.ui.ok("Your starter kit is ready to use.")
        return
    count = len(session.soft)
    ctx.ui.text("")
    ctx.ui.warn(f"The install finished, but {'one step' if count == 1 else f'{count} steps'} did not complete:")
    for soft in session.soft.values():
        ctx.ui.text(f"      {soft.label} is not installed: {soft.reason or 'the step did not finish (see the log)'}")
        ctx.ui.text(f"        reinstall it with:  {soft.repair}")
    ctx.ui.text("")
    if "runtime" in session.soft:
        ctx.ui.info("Everything that does not need the database is ready, including the exakit command itself.")
    else:
        ctx.ui.info("Everything else is ready - the database, and the exakit command itself.")
    if ctx.log.path:
        ctx.ui.info(f"Full detail for each failure: {ctx.log.path}")
    ctx.ui.info("See where you stand any time with: exakit status")


def autostart_default_on(ctx: Context) -> None:
    """Enable autostart on a first install, when nothing was decided before."""
    if ctx.manifest().get("autostart.enabled") in (True, False):
        return
    loud = ctx.ui
    from exakit.ui.silent import SilentRenderer
    ctx.ui = SilentRenderer(ctx.log)
    try:
        services.autostart_enable(ctx)
    except ExakitError as err:
        ctx.log.line("WARN", f"autostart: {err.message}")
    finally:
        ctx.ui = loud


def marketplace_offer(session: steps.Session) -> None:
    """Offer the add-ons (the persona's answer, or the menu)."""
    ctx = session.ctx
    with ctx.ui.busy("Checking which add-ons can run here"):
        pending = [r for r in marketplace_rows(ctx) if r.state == "available"]
    if not pending:
        return
    if ctx.env.get("EXAKIT_MARKETPLACE_ADDONS"):
        picked = marketplace.choose(ctx)
        if picked:
            marketplace.apply(ctx, picked)
        return
    if session.soft or not ctx.ui.interactive:
        ctx.ui.info("Optional add-ons (dashboards & more): exakit marketplace")
        return
    ctx.ui.rule()
    ctx.ui.heading("Supercharge Exasol with add-ons from marketplace")
    if ctx.ui.select("Explore marketplace ?", [Option("yes", "Yes"), Option("no", "No")], default=1) == "yes":
        try:
            marketplace.run(ctx, [])
        except ExakitError as err:
            ctx.ui.warn(err.message)


def closing(session: steps.Session) -> None:
    """The closing sequence: summary, what's new, autostart, the marketplace, the next steps."""
    ctx = session.ctx
    if not session.failed("runtime"):
        connection_summary(ctx)
    whats_new_box(ctx, session.root)
    report_soft_failures(session)
    autostart_default_on(ctx)
    try:
        marketplace_offer(session)
    except ExakitError as err:
        ctx.log.line("WARN", f"marketplace offer: {err.message}")
    ctx.ui.rule()
    ctx.ui.heading('Run "exakit help" for support')
    ctx.ui.text("")


# --- the run -----------------------------------------------------------------------------------------


def plan(ctx: Context) -> Plan:
    """What an install would do now: every step done or pending. Nothing is changed."""
    manifest = ctx.manifest_or_none()
    done = set(manifest.steps_completed()) if manifest else set()
    items = [Step("install", step, StepState.DONE if step in done else StepState.PENDING, label=TITLES.get(step, step)) for step in steps.STEP_IDS]
    return Plan("Install: the Exasol Personal Local Starter Kit", items, remedy_command="exakit install")


def _steps(session: steps.Session) -> None:
    ctx = session.ctx
    steps.step_launcher(session, TITLES["launcher"])
    steps.step_runtime(session, TITLES["runtime"])
    if session.failed("runtime"):
        ctx.ui.info("Skipping exapump, the sample data, the AI bridge and pyexasol - they all need the database, which is not installed")
    else:
        steps.step_exapump(session, TITLES["exapump"])
        if session.failed("exapump"):
            ctx.ui.info("Skipping the sample data - it is loaded with exapump, which is not installed")
        else:
            steps.sample_data(session)
        steps.step_mcp(session, TITLES["mcp"])
        steps.mcp_clients(session)
    steps.skills_place(session)
    if not session.failed("runtime"):
        steps.step_pyexasol(session, TITLES["pyexasol"])
    steps.step_helper(session, TITLES["exakit_helper"])


def banner(ctx: Context, root: Path) -> None:
    """The install screen's head: the wordmark (in a terminal), the title, the platform, the target, the paths."""
    if ctx.env.get("EXAKIT_BANNER_SHOWN") == "1":
        return
    p = ctx.platform
    word = "wsl" if p.is_wsl else p.os
    target = "Exasol Personal (local deployment via Podman)" if p.os == "linux" else "Exasol Personal (local deployment)"
    home = ctx.env.get("HOME", "")

    def short(path: Path) -> str:
        return str(path).replace(home, "~", 1) if home else str(path)

    ctx.ui.banner("Exasol Personal Local Starter Kit", f"Platform: {word} ({p.arch})   Target: {target}")
    ctx.ui.text(f"  Kit: {short(root)}   Home: {short(ctx.paths.home)}")
    ctx.ui.text("")


def run(ctx: Context) -> Result:
    """``exakit install``: the whole install, resumable; a dry run shows the plan."""
    answers = resolve_answers(ctx)      # an unknown persona stops here, dry run or not
    banner(ctx, kit_root(ctx))
    if ctx.dry_run:
        the_plan = plan(ctx)
        ctx.ui.plan(the_plan)
        ctx.ui.info("Dry run: nothing was installed. Run the same command without the dry run to install.")
        return Result(True, "dry-run", data=the_plan.to_dict())
    prepare_home(ctx)
    init_manifest(ctx)
    acquire_lock(ctx)
    root = kit_root(ctx)
    session = steps.Session(ctx, answers, root)
    record_persona(ctx)
    try:
        record_kit(ctx, root)
        crossing_before(ctx)
        session.current = "requirements"
        check_requirements(ctx)
        _steps(session)
    except ExakitError as err:
        ctx.ui.error(f"Setup failed{' during step: ' + session.current if session.current else ''}")
        if ctx.log.path:
            ctx.ui.text(f"    | Log: {ctx.log.path}")
        ctx.ui.text("    | Re-running the installer is safe: completed steps are skipped.")
        ctx.ui.info("Keeping partial progress. Re-run the installer to resume.")
        release_lock(ctx)
        raise Failed(err.message, remedy=err.remedy or ctx.install_command(), hint=err.hint) from None
    release_lock(ctx)
    closing(session)
    data = {"steps_completed": ctx.manifest().steps_completed(),
            "soft_failures": {k: {"repair": v.repair, "reason": v.reason} for k, v in session.soft.items()}}
    return Result(True, "installed" if not session.soft else "partial", data=data)


def kit_version(root: Path) -> str | None:
    """The kit version a checkout's versions.json names, or None."""
    try:
        return json.loads((root / "versions.json").read_text(encoding="utf-8"))["kit"]["version"]
    except (OSError, ValueError, KeyError, TypeError):
        return None
