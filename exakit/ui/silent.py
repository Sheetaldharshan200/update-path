"""The renderer behind ``--json``: nothing reaches stdout, everything goes to the log.

Menus answer with their defaults and questions with their default answer,
so a use case never blocks under ``--json``; ``run_plan`` refuses to apply
without ``--yes`` before any question would be asked.
"""

from __future__ import annotations

from collections.abc import Callable, Iterator, Sequence
from contextlib import contextmanager

from exakit.domain.log import Log, NullLog
from exakit.domain.plan import Plan, Step

from .widgets import Option


class SilentRenderer:
    interactive = False
    fancy = False

    def __init__(self, log: Log | None = None) -> None:
        self.log = log or NullLog()

    def text(self, line: str) -> None:
        """Log the line; nothing is printed in JSON mode."""
        self.log.line("INFO", line)

    def banner(self, title: str, subtitle: str = "") -> None:
        """Log the title; nothing is drawn."""
        self.log.line("INFO", title)

    def heading(self, text: str) -> None:
        """Log the heading."""
        self.log.line("INFO", text)

    def info(self, text: str) -> None:
        """Log the line."""
        self.log.line("INFO", text)

    def ok(self, text: str) -> None:
        """Log the success."""
        self.log.line("OK", text)

    def warn(self, text: str) -> None:
        """Log the warning."""
        self.log.line("WARN", text)

    def error(self, text: str) -> None:
        """Log the error."""
        self.log.line("ERROR", text)

    def card(self, message: str, *, log_path: str | None = None, remedy: str | None = None) -> None:
        """Log the fatal message; the refusal object carries it to stdout."""
        self.log.line("FATAL", message)

    def rule(self) -> None:
        """No rule is drawn in JSON mode."""
        return

    def panel(self, title: str, lines: Sequence[str]) -> None:
        """Log the panel's title."""
        self.log.line("INFO", title)

    def plan(self, plan: Plan) -> None:
        """Log the plan's title and pending count."""
        self.log.line("INFO", f"{plan.title}: {len(plan.pending())} pending")

    def step_begin(self, step: Step | str) -> None:
        """Log the step's start."""
        self.log.line("INFO", f"begin {step if isinstance(step, str) else step.id}")

    def step_end(self, step: Step | str, *, ok: bool = True, detail: str = "") -> None:
        """Log the step's end and outcome."""
        self.log.line("INFO", f"end {step if isinstance(step, str) else step.id} {detail}".rstrip())

    def confirm(self, question: str, default: bool = True) -> bool:
        """Answer every question with its default."""
        return default

    def prompt(self, question: str, default: str = "") -> str:
        """Answer every prompt with its default."""
        return default

    def select(self, title: str, options: Sequence[Option], default: int = 1) -> str | None:
        """Answer a menu with its default option."""
        return options[default - 1].id if 1 <= default <= len(options) else None

    def checkboxes(self, title: str, options: Sequence[Option], defaults: Sequence[str]) -> list[str]:
        """Answer a checkbox list with its defaults."""
        return [o.id for o in options if o.id in set(defaults) and not o.disabled]

    @contextmanager
    def busy(self, label: str) -> Iterator[None]:
        """Log the label; nothing is drawn."""
        self.log.line("INFO", label)
        yield

    @contextmanager
    def progress(self, label: str) -> Iterator[Callable[[int, int | None], None]]:
        """Log the label; the bytes are not reported anywhere."""
        self.log.line("INFO", label)
        yield _ignore


def _ignore(_done: int, _total: int | None) -> None:
    """The reporter under --json: the bytes go nowhere."""
    return
