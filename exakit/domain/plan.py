"""Plans: what a command would do on this machine, before it does it.

A plan is a list of steps grouped by section. A read-only command (``plan``)
returns it as is; a mutating command hands it to ``app.run_plan``, which runs
the pending steps in order and records what happened on the same objects.
States are the vocabulary the JSON answers and the screens share.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class StepState(str, Enum):
    DONE = "done"          # already on the machine, nothing to do
    PENDING = "pending"    # would be done by apply
    SKIPPED = "skipped"    # cannot or must not be done here; ``reason`` says why
    FAILED = "failed"      # apply ran it and it did not finish; ``reason`` says why


@dataclass(slots=True)
class Step:
    """One unit of work, or the record of one already done.

    ``run`` is set by the use case for pending steps and is None in a
    plan-only answer. ``remedy`` is the one command that retries this step.
    """

    section: str
    id: str
    state: StepState
    reason: str = ""
    run: Callable[[], None] | None = field(default=None, repr=False, compare=False)
    remedy: str | None = None
    label: str = ""                        # what a screen shows for the step; the id stays the contract

    def to_dict(self) -> dict[str, Any]:
        """The step as the plan document prints it."""
        doc: dict[str, Any] = {"id": self.id, "state": self.state.value}
        if self.reason:
            doc["reason"] = self.reason
        return doc


@dataclass(slots=True)
class Plan:
    """The steps a command found, in the order apply would run them."""

    title: str
    steps: list[Step] = field(default_factory=list)
    remedy_command: str = ""   # the command that applies this plan, without --yes

    def pending(self, section: str | None = None) -> list[Step]:
        """The pending steps, in one section when named."""
        return [s for s in self.steps if s.state is StepState.PENDING and (section is None or s.section == section)]

    def failed(self) -> list[Step]:
        """The failed steps."""
        return [s for s in self.steps if s.state is StepState.FAILED]

    def by_section(self) -> dict[str, list[Step]]:
        """Sections in first-seen order, each with its steps in plan order."""
        groups: dict[str, list[Step]] = {}
        for step in self.steps:
            groups.setdefault(step.section, []).append(step)
        return groups

    @property
    def complete(self) -> bool:
        """True when nothing is pending."""
        return not self.pending()

    def to_dict(self) -> dict[str, Any]:
        """Sections as arrays of step objects, plus the pending count."""
        doc: dict[str, Any] = {name: [s.to_dict() for s in steps] for name, steps in self.by_section().items()}
        doc["pending"] = len(self.pending())
        doc["failed"] = [
            {"section": s.section, "id": s.id, "reason": s.reason} for s in self.failed()
        ]
        return doc
