"""``exakit persona``: list, show, plan, and apply through the one plan runner."""

from __future__ import annotations

from typing import Any

from exakit.domain.catalog import Persona
from exakit.domain.persona import answers_for, plan_for
from exakit.domain.manifest import utc_now
from exakit.domain.plan import Plan, Step
from exakit.domain.result import Result

from . import Context, run_plan
from .machine import all_datasets, probe

SECTIONS = ("datasets", "mcp_clients", "addons", "skills")   # every plan document carries all four, empty or not


def recorded(ctx: Context) -> str | None:
    """The recorded persona id, or None."""
    manifest = ctx.manifest_or_none()
    return manifest.persona_id() if manifest else None


def list_personas(ctx: Context) -> Result:
    """``exakit persona list``."""
    current = recorded(ctx)
    personas = ctx.catalog.personas()
    data: dict[str, Any] = {
        "recorded": current,
        "personas": [{"id": p.id, "title": p.title, "summary": p.summary, "source": p.source, "recorded": p.id == current}
                     for p in personas],
    }
    if not ctx.json:
        _render_list(ctx, personas, current)
    return Result(True, "recorded" if current else "none", data=data)


def _render_list(ctx: Context, personas: list[Persona], current: str | None) -> None:
    if not personas:
        ctx.ui.warn("This kit copy ships no personas.")
        return
    for p in personas:
        mark = "* " if p.id == current else "  "
        yours = " (yours)" if p.source == "user" else ""
        ctx.ui.text(f"  {mark}{p.id:<16} {p.title}")
        ctx.ui.text(f"    {'':<16} {p.summary}{yours}")
    ctx.ui.text("")
    if current:
        ctx.ui.info(f"Recorded on this machine: {current}. See what is left: exakit persona plan {current}")
    else:
        ctx.ui.info("See what one would add: exakit persona plan <id>   Apply it: exakit persona apply <id>")


def show(ctx: Context, persona_id: str) -> Result:
    """``exakit persona show <id>``: the document."""
    persona = ctx.catalog.persona(persona_id)
    doc = persona.to_dict()
    if not ctx.json:
        def cell(value: Any) -> str:
            return value if isinstance(value, str) else ", ".join(value)
        origin = "your file: " if persona.source == "user" else "shipped with the kit: "
        ctx.ui.panel(f"Persona: {persona.title} ({persona.id})", [
            persona.summary, "",
            f"Sample data:  {cell(doc['datasets'])}", f"AI clients:   {cell(doc['mcp_clients'])}",
            f"Add-ons:      {cell(doc['addons'])}", f"AI skills:    {doc['skills']}", "",
            f"{origin}{persona.path}",
        ])
    return Result(True, "ok", data={**doc, "source": persona.source}, raw=True)


def build_plan(ctx: Context, persona: Persona) -> Plan:
    """The plan for a persona on this machine, from the probed state."""
    manifest = ctx.manifest_or_none()
    machine = probe(ctx, manifest)
    answers = answers_for(persona, ctx.env, all_datasets=list(machine.all_datasets))
    return plan_for(persona, machine, answers)


def plan(ctx: Context, persona_id: str) -> Result:
    """``exakit persona plan <id>``: the plan, nothing changed."""
    persona = ctx.catalog.persona(persona_id)
    the_plan = build_plan(ctx, persona)
    pending = len(the_plan.pending())
    data = {"persona": {"id": persona.id, "title": persona.title, "source": persona.source},
            **{section: [] for section in SECTIONS}, **the_plan.to_dict()}
    if not ctx.json:
        ctx.ui.plan(the_plan)
        if pending:
            ctx.ui.info(f"Apply it with: exakit persona apply {persona.id}")
        else:
            ctx.ui.ok("Everything this persona asks for is already on this machine.")
    return Result(True, "complete" if pending == 0 else "pending",
                  remedy=None if pending == 0 else f"exakit persona apply {persona.id} --yes", data=data)


def install_env(ctx: Context, persona_id: str) -> dict[str, str]:
    """The environment that makes the (legacy) installer follow this persona; explicit answers win."""
    persona = ctx.catalog.persona(persona_id)
    answers = answers_for(persona, ctx.env, all_datasets=all_datasets(ctx))
    env = answers.env()
    if "addons" not in answers.explicit and not isinstance(answers.addons, str):
        manifest = ctx.manifest_or_none()
        machine = probe(ctx, manifest, need={"addons"})
        runnable = [a for a in answers.addons if machine.addon_states.get(a, ("", ""))[0] in ("available", "installed")]
        env["EXAKIT_MARKETPLACE_ADDONS"] = ",".join(runnable) or "none"
    env["EXAKIT_PERSONA_ACTIVE"] = "1"
    return env


# --- apply -------------------------------------------------------------------------------


def _bind(ctx: Context, step: Step, answers) -> None:
    """Give a pending step the use case that does it; each one records its own manifest facts."""
    from . import data, marketplace, skills
    if step.section == "datasets":
        step.run = lambda: data.load(ctx, data.dataset(ctx, step.id))
        step.remedy = step.remedy or f"exakit data-load {step.id}"
    elif step.section == "mcp_clients":
        chosen = answers.mcp_clients if step.id == "all" else step.id
        step.run = lambda: _connect(ctx, chosen)
        step.remedy = step.remedy or f"EXAKIT_MCP_CLIENTS={chosen} exakit mcp-setup"
    elif step.section == "addons":
        step.run = lambda: _install_addon(ctx, marketplace, step.id)
        step.remedy = step.remedy or f"exakit marketplace {step.id}"
    elif step.section == "skills":
        step.run = lambda: skills.install(ctx)
        step.remedy = step.remedy or "exakit skills-install"


def _connect(ctx: Context, clients: str) -> None:
    from exakit.domain.errors import Failed
    from . import mcp
    env = {**dict(ctx.env), "EXAKIT_MCP_CLIENTS": clients}
    saved = ctx.env
    ctx.env = env
    try:
        result = mcp.setup(ctx)
    finally:
        ctx.env = saved
    if result.exit_code:
        raise Failed(f"MCP setup for {clients} did not finish", remedy=f"EXAKIT_MCP_CLIENTS={clients} exakit mcp-setup")


def _install_addon(ctx: Context, marketplace, addon_id: str) -> None:
    from exakit.domain.errors import Failed
    if not marketplace.install_one(ctx, ctx.catalog.addon(addon_id)):
        raise Failed(f"{addon_id} did not finish installing", remedy=f"exakit update {addon_id}")


def _record(ctx: Context, persona: Persona, the_plan: Plan) -> None:
    skipped = [s.id for s in the_plan.steps if s.state.value == "skipped"]
    def change(m):
        m.set("persona.id", persona.id)
        m.set("persona.source", "apply")
        m.set("persona.requested_at", m.get("persona.requested_at") or utc_now())
        m.set("persona.applied_at", utc_now())
        m.set("persona.skipped", skipped)
    ctx.manifest_store.update(change)


def apply(ctx: Context, persona_id: str) -> Result:
    """``exakit persona apply <id>``: plan for this machine, confirm, run, record."""
    persona = ctx.catalog.persona(persona_id)
    ctx.manifest()   # exit 4 without an install record
    manifest = ctx.manifest_or_none()
    machine = probe(ctx, manifest)
    answers = answers_for(persona, ctx.env, all_datasets=list(machine.all_datasets))
    the_plan = plan_for(persona, machine, answers)
    for step in the_plan.pending():
        _bind(ctx, step, answers)
    extra = {"persona": {"id": persona.id, "title": persona.title, "source": persona.source}, **{section: [] for section in SECTIONS}}
    result = run_plan(ctx, the_plan, confirm_question=f"Apply the {persona.title} persona now?", extra=extra)
    _record(ctx, persona, the_plan)
    if not ctx.json:
        if result.status == "complete":
            ctx.ui.ok("Everything this persona asks for is already on this machine.")
        elif result.status == "applied":
            ctx.ui.ok(f"Persona {persona.id} applied. Recorded on this machine; see it again with: exakit persona plan {persona.id}")
        else:
            ctx.ui.warn(f"Persona {persona.id} applied with failures - retry with: exakit persona apply {persona.id} --yes")
    return result
