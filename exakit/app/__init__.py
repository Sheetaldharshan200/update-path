"""Use cases. Every command is one of these: build a Result, or build a Plan and run it.

``Context`` is everything a use case may touch, built once per command by
the CLI from the adapters for this machine. ``run_plan`` is the ONE apply
loop in the kit: show the plan, confirm (or ``--yes``, or refuse with exit
5), run each pending step in its own try, and answer with one Result.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Any, Protocol

from exakit.adapters.clients import ClientOps
from exakit.adapters.exapump import Exapump
from exakit.adapters.fs.credentials import CredentialStore
from exakit.adapters.fs.log import Log, NullLog
from exakit.adapters.fs.manifest_store import ManifestStore
from exakit.adapters.fs.paths import Paths
from exakit.adapters.net.http import Downloader
from exakit.adapters.net.versions_cache import VersionsSource
from exakit.adapters.process.runner import Runner
from exakit.adapters.process.services import Services
from exakit.adapters.runtime.personal import PersonalRuntime
from exakit.adapters.uv import Uv
from exakit.domain.catalog import Catalog
from exakit.domain.errors import ExakitError, NotConfirmed, NotInstalled
from exakit.domain.manifest import Manifest
from exakit.domain.plan import Plan, StepState
from exakit.domain.platform import Platform
from exakit.domain.result import Result
from exakit.domain.versions import VersionPolicy
from exakit.ui import Renderer

@dataclass
class Context:
    paths: Paths
    platform: Platform
    env: Mapping[str, str]
    catalog: Catalog
    manifest_store: ManifestStore
    versions: VersionsSource
    runner: Runner
    net: Downloader
    ui: Renderer
    log: Log = field(default_factory=NullLog)
    json: bool = False
    yes: bool = False
    dry_run: bool = False
    readonly: bool = False
    kit_repo_override: str | None = None      # EXAKIT_KIT_REPO; the settings name the repository otherwise
    # Machine-facing adapters the CLI wires; tests pass fakes. None means "not wired yet".
    credentials: CredentialStore | None = None
    clients: ClientOps | None = None
    runtime: PersonalRuntime | None = None
    services: Services | None = None
    uv: Uv | None = None
    exapump: Exapump | None = None

    @property
    def policy(self) -> VersionPolicy:
        return VersionPolicy.from_env(self.env.get("EXAKIT_VERSION_POLICY"))

    @property
    def kit_repo(self) -> str:
        """The repository the kit updates from: EXAKIT_KIT_REPO, else catalog/kit.json."""
        return self.kit_repo_override or self.catalog.kit.repository

    def install_command(self) -> str:
        """The one command that (re)runs the installer on this platform, runnable as written."""
        override = self.env.get("EXAKIT_INSTALL_URL")
        if self.platform.os == "windows":
            return f"irm {override or self.catalog.kit.install_ps1_url} | iex"
        return f"curl -fsSL {override or self.catalog.kit.install_sh_url} | sh"

    def manifest(self) -> Manifest:
        """The install record. Raises NotInstalled, with the installer as the remedy, when there is none."""
        try:
            return self.manifest_store.load()
        except NotInstalled as err:
            raise NotInstalled(err.message, remedy=err.remedy or self.install_command(), hint=err.hint, data=err.data) from None

    def manifest_or_none(self) -> Manifest | None:
        return self.manifest_store.load() if self.manifest_store.exists() else None


class UseCase(Protocol):
    def plan(self, ctx: Context, **args: Any) -> Plan: ...
    def apply(self, ctx: Context, plan: Plan) -> Result: ...


def plan_data(plan: Plan) -> dict[str, Any]:
    return plan.to_dict()


def run_plan(ctx: Context, plan: Plan, *, confirm_question: str, extra: dict[str, Any] | None = None) -> Result:
    """Apply a plan. Returns a Result with status applied | partial | complete; raises NotConfirmed."""
    extra = extra or {}
    if plan.complete:
        return Result(True, "complete", data={**extra, **plan_data(plan)})
    remedy = f"{plan.remedy_command} --yes" if plan.remedy_command else None
    if not ctx.yes:
        ctx.ui.plan(plan)
        if ctx.json or not ctx.ui.interactive:
            raise NotConfirmed("Nothing changed: confirm the plan to apply it.", remedy=remedy,
                               data={**extra, **plan_data(plan)})
        if not ctx.ui.confirm(confirm_question, default=True):
            raise NotConfirmed("Nothing changed.", remedy=remedy, data={**extra, **plan_data(plan)})
    for step in plan.pending():
        ctx.ui.step_begin(step)
        try:
            if step.run is not None:
                step.run()
            step.state = StepState.DONE
        except ExakitError as err:
            step.state = StepState.FAILED
            step.reason = err.message
            step.remedy = err.remedy or step.remedy
            ctx.log.line("ERROR", f"{step.section} {step.id}: {err.message}")
        ctx.ui.step_end(step)
    failed = plan.failed()
    if not failed:
        return Result(True, "applied", data={**extra, **plan_data(plan)})
    return Result(True, "partial", remedy=failed[0].remedy, remedy_hint=failed[0].reason,
                  data={**extra, **plan_data(plan)}, exit_code=1)
