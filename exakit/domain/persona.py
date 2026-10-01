"""Personas: from a persona file to the installer's answers, and to a plan for this machine.

A persona is exactly a named set of the answers the installer already takes
from the environment. ``answers_for`` folds a persona and the environment
together (an explicit ``EXAKIT_*`` value wins, per variable). ``plan_for``
turns a persona and a description of the machine into a plan whose steps are
done, pending or skipped with a reason. Both are pure: probing the machine is
``app.machine``.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field

from .catalog import Persona
from .ids import is_skip_word, parse_client_selection
from .plan import Plan, Step, StepState

# Add-on states as app.machine reports them; the plan turns them into step states.
ADDON_INSTALLED = "installed"          # kit-managed, present
ADDON_AVAILABLE = "available"          # can be installed here
ADDON_SYSTEM = "system"                # already on the machine outside the kit
ADDON_UNAVAILABLE = "unavailable"      # cannot run here; reason says why
ADDON_MISSING_MODULE = "missing-module"  # registered, but this kit copy cannot install it

CLIENT_CONNECTED = "connected"
CLIENT_PENDING = "pending"
CLIENT_MISSING = "missing"


@dataclass(frozen=True, slots=True)
class Answers:
    """The installer's answers, resolved."""

    datasets: tuple[str, ...] | None     # None = no sample data (EXAKIT_LOAD_SAMPLE=0)
    mcp_clients: str                     # "all" | "skip" | csv of client ids
    addons: tuple[str, ...] | str        # ids, or "all" | "none"
    explicit: frozenset[str] = frozenset()   # which of datasets/mcp_clients/addons came from the environment

    def env(self) -> dict[str, str]:
        """The environment variables that make the legacy installer give these answers."""
        out: dict[str, str] = {}
        if self.datasets is None:
            out["EXAKIT_LOAD_SAMPLE"] = "0"
        else:
            out["EXAKIT_DATASETS"] = ",".join(self.datasets)
        out["EXAKIT_MCP_CLIENTS"] = self.mcp_clients
        out["EXAKIT_MARKETPLACE_ADDONS"] = self.addons if isinstance(self.addons, str) else ",".join(self.addons) or "none"
        return out


def answers_for(persona: Persona, env: Mapping[str, str], *, all_datasets: list[str]) -> Answers:
    """Fold the persona and the environment; an explicit environment answer wins per variable."""
    explicit: set[str] = set()

    datasets: tuple[str, ...] | None
    if env.get("EXAKIT_DATASETS"):
        datasets = tuple(t for t in env["EXAKIT_DATASETS"].replace(" ", "").split(",") if t)
        explicit.add("datasets")
    elif env.get("EXAKIT_LOAD_SAMPLE") in ("0", "1"):
        datasets = None if env["EXAKIT_LOAD_SAMPLE"] == "0" else ("tpch",)
        explicit.add("datasets")
    elif persona.datasets == "none":
        datasets = None
    elif persona.datasets == "all":
        datasets = tuple(all_datasets) or ("tpch",)
    else:
        datasets = tuple(persona.datasets)

    if env.get("EXAKIT_SKIP_MCP") == "1":
        clients = "skip"
        explicit.add("mcp_clients")
    elif env.get("EXAKIT_MCP_CLIENTS"):
        clients = "skip" if is_skip_word(env["EXAKIT_MCP_CLIENTS"]) else env["EXAKIT_MCP_CLIENTS"].strip()
        explicit.add("mcp_clients")
    elif isinstance(persona.mcp_clients, str):
        clients = persona.mcp_clients
    else:
        clients = ",".join(persona.mcp_clients)

    addons: tuple[str, ...] | str
    if env.get("EXAKIT_MARKETPLACE_ADDONS"):
        raw = env["EXAKIT_MARKETPLACE_ADDONS"].replace(" ", "").lower()
        addons = raw if raw in ("all", "none") else tuple(t for t in raw.split(",") if t)
        explicit.add("addons")
    else:
        addons = persona.addons if isinstance(persona.addons, str) else tuple(persona.addons)

    return Answers(datasets, clients, addons, frozenset(explicit))


@dataclass(frozen=True, slots=True)
class MachineState:
    """What is on THIS machine, as far as a persona cares. Built by app.machine.probe."""

    all_datasets: tuple[str, ...]
    loaded_datasets: frozenset[str]
    client_states: Mapping[str, str] | None          # None = detection unavailable
    addon_states: Mapping[str, tuple[str, str]]       # id -> (state, reason)
    all_addons: tuple[str, ...]
    skills_current: bool
    skipped_note: str = field(default="")


def plan_for(persona: Persona, machine: MachineState, answers: Answers | None = None) -> Plan:
    """What applying the persona would do here. Nothing is probed or changed."""
    answers = answers or answers_for(persona, {}, all_datasets=list(machine.all_datasets))
    steps: list[Step] = []
    steps += _dataset_steps(answers, machine)
    steps += _client_steps(answers, machine)
    steps += _addon_steps(answers, machine)
    steps.append(Step("skills", "skills", StepState.DONE if machine.skills_current else StepState.PENDING))
    return Plan(f"Persona: {persona.title} ({persona.id})", steps, remedy_command=f"exakit persona apply {persona.id}")


def _dataset_steps(answers: Answers, machine: MachineState) -> list[Step]:
    if answers.datasets is None:
        return []
    return [
        Step("datasets", ds, StepState.DONE if ds in machine.loaded_datasets else StepState.PENDING)
        for ds in answers.datasets
    ]


def _client_steps(answers: Answers, machine: MachineState) -> list[Step]:
    if answers.mcp_clients == "skip":
        return []
    states = machine.client_states
    if answers.mcp_clients == "all":
        if states is None:
            return [Step("mcp_clients", "all", StepState.PENDING, "client detection is unavailable; the setup menu decides")]
        return [
            Step("mcp_clients", cid, StepState.DONE if state == CLIENT_CONNECTED else StepState.PENDING)
            for cid, state in states.items() if state in (CLIENT_CONNECTED, CLIENT_PENDING)
        ]
    steps: list[Step] = []
    for cid in parse_client_selection(answers.mcp_clients):
        state = (states or {}).get(cid)
        if state == CLIENT_CONNECTED:
            steps.append(Step("mcp_clients", cid, StepState.DONE))
        elif state == CLIENT_MISSING:
            steps.append(Step("mcp_clients", cid, StepState.PENDING,
                              "not detected on this machine; configured anyway because the persona names it"))
        else:
            steps.append(Step("mcp_clients", cid, StepState.PENDING))
    return steps


def _addon_steps(answers: Answers, machine: MachineState) -> list[Step]:
    if answers.addons == "none":
        return []
    ids = list(machine.all_addons) if answers.addons == "all" else list(answers.addons)
    steps: list[Step] = []
    for aid in ids:
        state, reason = machine.addon_states.get(aid, (ADDON_MISSING_MODULE, "not a marketplace add-on this kit knows"))
        if state == ADDON_INSTALLED:
            steps.append(Step("addons", aid, StepState.DONE))
        elif state == ADDON_AVAILABLE:
            steps.append(Step("addons", aid, StepState.PENDING, remedy=f"exakit marketplace {aid}"))
        elif state == ADDON_SYSTEM:
            steps.append(Step("addons", aid, StepState.SKIPPED, "already on this system, the kit leaves it alone"))
        elif state == ADDON_MISSING_MODULE:
            steps.append(Step("addons", aid, StepState.SKIPPED, reason or "the module is not part of this kit copy (exakit update)"))
        else:
            steps.append(Step("addons", aid, StepState.SKIPPED, f"not available on this machine{': ' + reason if reason else ''}"))
    return steps
