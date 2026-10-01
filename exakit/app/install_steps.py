"""The installer's steps: each one idempotent, each ticked in the manifest, each soft-failable where the kit allows it."""

from __future__ import annotations

import shutil
from dataclasses import dataclass, field
from pathlib import Path

from exakit.adapters.fs.notes import clear_failure_note, read_failure_note
from exakit.components import for_component
from exakit.domain.errors import ExakitError, Failed
from exakit.domain.persona import Answers
from exakit.domain.versions import is_newer

from . import Context, data, mcp, skills
from .deploy import deploy_local, record as record_runtime
from .legacy_crossing import crossing_after
from .machine import installed_version, kit_root
from .runtime_ops import runtime

STEP_IDS = ("launcher", "runtime", "exapump", "mcp", "pyexasol", "exakit_helper")
DRIFT_COMPONENT = {"launcher": "personal", "exapump": "exapump", "mcp": "mcp", "pyexasol": "pyexasol"}


@dataclass(slots=True)
class SoftFailure:
    component: str
    repair: str
    reason: str
    label: str


@dataclass(slots=True)
class Session:
    ctx: Context
    answers: Answers
    root: Path
    soft: dict[str, SoftFailure] = field(default_factory=dict)
    current: str = ""

    def failed(self, component: str) -> bool:
        """True when this component failed softly in this run."""
        return component in self.soft

    def record_soft(self, component: str, repair: str, label: str) -> None:
        """The pending failure note is the reason; it is taken (cleared) so the next step cannot inherit it."""
        if component in self.soft:
            return
        reason, _ = read_failure_note(self.ctx.paths.failure_note)
        clear_failure_note(self.ctx.paths.failure_note)
        self.soft[component] = SoftFailure(component, repair, reason or "", label)

    def soft_step(self, component: str, repair: str, label: str, body) -> bool:
        """Run ``body`` as a step that may fail softly: a failure is recorded with its repair command and the install goes on."""
        clear_failure_note(self.ctx.paths.failure_note)
        try:
            body()
        except ExakitError as err:
            self.ctx.log.line("ERROR", f"{label}: {err.message}")
            if not read_failure_note(self.ctx.paths.failure_note)[0]:
                from exakit.adapters.fs.notes import write_failure_note
                from exakit.domain.manifest import utc_now
                write_failure_note(self.ctx.paths.failure_note, err.message, utc_now())
            self.record_soft(component, repair, label)
            self.ctx.ui.warn(f"{label} did not finish - carrying on so the rest of the install completes")
            return False
        clear_failure_note(self.ctx.paths.failure_note)
        return True


# --- step bookkeeping ------------------------------------------------------------------------


def artifact_missing(session: Session, step: str) -> bool:
    """File tests only: the step ran once, but what it produced is gone."""
    ctx = session.ctx
    if step == "launcher":
        own = ctx.paths.bin_dir / "exasol"
        if own.exists():
            return own.stat().st_size == 0
        return not ctx.runner.which("exasol")
    if step == "exakit_helper":
        return any(not target.exists() or target.stat().st_size == 0 for _source, target in helper_files(ctx, ctx.paths.kit))
    if step == "exapump":
        path = ctx.manifest().get("components.exapump.path")
        if not path:
            return False
        return not Path(path).exists() or Path(path).stat().st_size == 0
    return False


def version_drift(session: Session, step: str) -> str | None:
    """The advertised version a done step's recorded one drifted from, when the step must run again; None otherwise."""
    cid = DRIFT_COMPONENT.get(step)
    if not cid:
        return None
    try:
        want = for_component(session.ctx, cid).target_version()
    except ExakitError:
        return None
    have = installed_version(session.ctx, cid, session.ctx.manifest())[0]
    if have and have != "unknown" and is_newer(want, have):
        return f"{cid} {have} is installed and this kit installs {want} - updating it"
    return None


def begin(session: Session, step: str, title: str) -> bool:
    """True when the step must run; False when it is done and its work is still in place."""
    ctx = session.ctx
    session.current = step
    ctx.manifest_store.update(lambda m: m.set("install.current_step", step))
    if step in ctx.manifest().steps_completed():
        drift = version_drift(session, step)
        if drift:
            reason = drift
        elif artifact_missing(session, step):
            reason = "what it installed is missing - running it again"
        else:
            ctx.ui.ok(f"{title} - already done, skipping")
            return False
        ctx.ui.heading(title)
        ctx.ui.info(f"Recorded as done, but {reason}")
        return True
    ctx.ui.heading(title)
    ctx.log.line("STEP", title)
    return True


def mark(session: Session, step: str) -> None:
    """Tick a step in the record."""
    session.ctx.manifest_store.update(lambda m: m.mark_step(step))


# --- the steps ---------------------------------------------------------------------------------


def step_launcher(session: Session, title: str) -> None:
    """Step 1: the Exasol launcher binary."""
    if begin(session, "launcher", title):
        lifecycle = for_component(session.ctx, "personal")
        lifecycle.install(lifecycle.target_version())
        mark(session, "launcher")


def step_runtime(session: Session, title: str) -> None:
    """Step 2: the local database deployment (reuse, start, replace with consent, or deploy fresh)."""
    ctx = session.ctx
    if begin(session, "runtime", title):
        if session.soft_step("runtime", ctx.install_command(), "the local database", lambda: _deploy_or_fail(ctx)):
            mark(session, "runtime")
        return
    rt = runtime(ctx)
    record_runtime(ctx) if rt.deployment_exists() else None
    if not rt.deployment_exists():
        ctx.ui.info("Deployment marked done but not reachable - redeploying")
        session.soft_step("runtime", ctx.install_command(), "the local database", lambda: _deploy_or_fail(ctx))
    elif not rt.running():
        ctx.ui.info("Database is deployed but not running - starting it")
        def start() -> None:
            rt.start(ctx.ui.info)
            if not rt.wait_ready_or_deploy(ctx.ui.info):
                raise Failed("The database was not started")
        session.soft_step("runtime", "exakit start", "the local database", start)


def _deploy_or_fail(ctx: Context) -> None:
    if not deploy_local(ctx):
        raise Failed("The database was not installed")


def step_exapump(session: Session, title: str) -> None:
    """Step 3: exapump with the starter-kit profile, then the sample data."""
    if begin(session, "exapump", title):
        def body() -> None:
            lifecycle = for_component(session.ctx, "exapump")
            lifecycle.install(lifecycle.target_version())
            lifecycle.create_profile()
            lifecycle.validate()
        if session.soft_step("exapump", "exakit update", "exapump", body):
            mark(session, "exapump")


def sample_data(session: Session) -> None:
    """The sample-data section: the crossing's restore first, then what the answers name, then the menu."""
    ctx = session.ctx
    crossing_after(ctx, runtime_failed=session.failed("runtime"))
    def body() -> None:
        answers = session.answers
        if answers.datasets is None:
            ctx.ui.info("Skipping the sample data (EXAKIT_LOAD_SAMPLE=0). Load it any time with: exakit data-load")
            return
        if ctx.env.get("EXAKIT_DATA_FILE"):
            ctx.ui.info("Loading a local file (EXAKIT_DATA_FILE).")
            data.load_local_path(ctx, Path(ctx.env["EXAKIT_DATA_FILE"]).expanduser())
            return
        if "datasets" in answers.explicit or not ctx.ui.interactive or ctx.env.get("EXAKIT_PERSONA"):
            _load_named(ctx, list(answers.datasets))
            return
        if data.menu(ctx).exit_code:
            raise Failed("the bundled sample data did not finish loading (see the log)")
    if not session.soft_step("sample_data", "exakit data-load", "sample data", body):
        ctx.ui.warn("Sample data did not finish loading - carrying on so the rest of the install completes")


def _load_named(ctx: Context, ids: list[str]) -> None:
    known = {d.id for d in data.bundled(ctx)}
    done = data.loaded(ctx)
    failures = []
    for ds_id in ids:
        if ds_id not in known:
            ctx.ui.warn(f"Unknown dataset id '{ds_id}' in EXAKIT_DATASETS (available: {', '.join(sorted(known))}).")
            continue
        if ds_id in done:
            ctx.ui.ok(f"Dataset '{ds_id}' is already loaded")
            continue
        ctx.ui.info(f"Loading dataset '{ds_id}'.")
        try:
            data.load(ctx, data.dataset(ctx, ds_id))
        except ExakitError as err:
            ctx.log.line("ERROR", err.message)
            failures.append(ds_id)
    if failures:
        raise Failed(f"loading dataset(s) {', '.join(failures)} did not finish (see the log)")


def step_mcp(session: Session, title: str) -> None:
    """Step 4: the AI bridge: the MCP server, the read-only user, the chosen clients and the skills."""
    if begin(session, "mcp", title):
        def body() -> None:
            lifecycle = for_component(session.ctx, "mcp")
            lifecycle.install(lifecycle.target_version())
            lifecycle.validate()
        if session.soft_step("mcp", "exakit update", "the MCP server", body):
            mark(session, "mcp")


def mcp_clients(session: Session) -> None:
    """Configure the chosen AI clients as a soft step; nothing when the answer is ``skip``."""
    ctx = session.ctx
    if ctx.manifest().get("components.mcp_server.client_setup.completed") is True:
        return
    if ctx.env.get("EXAKIT_SKIP_MCP") == "1":
        ctx.ui.info("Skipping AI client setup (EXAKIT_SKIP_MCP=1). Run it any time with: exakit mcp-setup")
        return
    def body() -> None:
        result = mcp.setup(ctx)
        if result.exit_code:
            raise Failed("the AI client configuration did not finish (see the log)")
    if not session.soft_step("mcp_clients", "exakit mcp-setup", "AI client (MCP) setup", body):
        ctx.ui.warn("Your local database is installed, but AI client setup did not finish cleanly. Retry any time with: exakit mcp-setup")


def skills_place(session: Session) -> None:
    """Place the kit's skills for the AI agents, as a soft step."""
    def body() -> None:
        if not any((session.root / "skills").glob("*/SKILL.md")):
            raise Failed(f"this kit copy carries no skills/ directory (expected {session.root / 'skills'})")
        skills.install(session.ctx)
    session.soft_step("skills", "exakit skills-install", "AI skills", body)


def step_pyexasol(session: Session, title: str) -> None:
    """Step 5: pyexasol in its own venv, validated against the database."""
    if begin(session, "pyexasol", title):
        def body() -> None:
            lifecycle = for_component(session.ctx, "pyexasol")
            lifecycle.install(lifecycle.target_version())
            lifecycle.validate()
        if session.soft_step("pyexasol", "exakit update", "pyexasol", body):
            mark(session, "pyexasol")


def helper_files(ctx: Context, root: Path) -> list[tuple[Path, Path]]:
    """(source in the kit copy, target in the bin dir) for the exakit command: the sh launcher, or on Windows the .cmd shim and the PowerShell launcher it runs."""
    names = ("exakit.cmd", "exakit.ps1") if ctx.platform.os == "windows" else ("exakit",)
    return [(root / "setup" / name, ctx.paths.bin_dir / name) for name in names]


def step_helper(session: Session, title: str) -> None:
    """The exakit command in the bin dir, and the kit copy under the home when this run came from a checkout."""
    ctx = session.ctx
    files = helper_files(ctx, session.root)
    needed = begin(session, "exakit_helper", title)
    if not needed:
        if any(not target.exists() for _source, target in files):
            ctx.ui.info("exakit command is missing - reinstalling it")
            needed = True
        elif any(source.exists() and target.read_bytes() != source.read_bytes() for source, target in files):
            ctx.ui.info("exakit command is out of date - refreshing it")
            needed = True
    if not needed:
        return
    for source, _target in files:
        if not source.exists():
            raise Failed(f"This kit copy has no {source.name} launcher at {source}.")
    ctx.paths.bin_dir.mkdir(parents=True, exist_ok=True)
    for source, target in files:
        for_component(ctx, "exakit").install_binary(source, target)
    if session.root.resolve() != ctx.paths.kit.resolve():
        _copy_kit(session.root, ctx.paths.kit)
    mark(session, "exakit_helper")
    ctx.ui.ok(f"exakit command installed to {files[-1][1]}")


def _copy_kit(root: Path, kit: Path) -> None:
    if kit.exists():
        shutil.rmtree(kit, ignore_errors=True)
    shutil.copytree(root, kit, ignore=shutil.ignore_patterns(".git", "__pycache__", ".kit-stage.*"), symlinks=True)


def ensure_kit_root(ctx: Context) -> Path:
    """The kit copy this install runs from: the checkout, or the copy under the kit home."""
    return kit_root(ctx)
