"""The widgets of the kit's screens: the wordmark header, the plan panel, the status bar."""

from __future__ import annotations

import time

from rich.text import Text
from textual.containers import VerticalScroll
from textual.widgets import Static

from exakit.domain.plan import Plan, Step, StepState
from exakit.ui.console import SECTION_LABELS
from exakit.ui.spinner import SPIN_FRAMES, elapsed_text
from exakit.ui.widgets import WORDMARK_E, WORDMARK_REST, WORDMARK_X_LEFT, WORDMARK_X_RIGHT

ACCENT = "#2fb34a"
WORDMARK_WIDTH = 70        # columns the wordmark needs; narrower terminals get the title alone
GLYPHS = {StepState.DONE: ("✓", "green"), StepState.PENDING: ("·", "dim"), StepState.SKIPPED: ("-", "dim"), StepState.FAILED: ("✗", "red")}


def step_label(step: Step | str) -> str:
    """What the screens show for a step: its label, else section and id as the console shows them."""
    if isinstance(step, str):
        return step
    return step.label or f"{SECTION_LABELS.get(step.section, step.section)}: {step.id}"


def step_key(step: Step | str) -> str:
    """The key a step's row is kept under."""
    return step if isinstance(step, str) else f"{step.section}/{step.id}"


class WordmarkHeader(Static):
    """The EXASOL wordmark with its green X, then the title and the subtitle."""

    def __init__(self, title: str, subtitle: str = "") -> None:
        super().__init__(id="header")
        self.title_text = title
        self.subtitle_text = subtitle

    def on_mount(self) -> None:
        """Draw the header once mounted."""
        self.redraw()

    def on_resize(self) -> None:
        """Redraw: the wordmark needs 70 columns, a narrower terminal gets the title alone."""
        self.redraw()

    def set_title(self, title: str, subtitle: str = "") -> None:
        """Replace the title and the subtitle."""
        self.title_text, self.subtitle_text = title, subtitle
        self.redraw()

    def redraw(self) -> None:
        """Compose the header text."""
        text = Text()
        if self.app.size.width >= WORDMARK_WIDTH:
            for e, xl, xr, rest in zip(WORDMARK_E, WORDMARK_X_LEFT, WORDMARK_X_RIGHT, WORDMARK_REST, strict=True):
                text.append(e, style="bold").append(xl, style=f"bold {ACCENT}").append(xr + rest + "\n", style="bold")
        text.append(self.title_text, style="bold")
        if self.subtitle_text:
            text.append("   " + self.subtitle_text, style="dim")
        self.update(text)


class PlanPanel(VerticalScroll):
    """One row per step: the state glyph, the label, the detail or the time it took."""

    def __init__(self) -> None:
        super().__init__(id="plan")
        self.border_title = "Plan"
        self.rows: dict[str, Static] = {}
        self.texts: dict[str, Text] = {}          # what each row shows, for the tests and the transcript
        self.started: dict[str, float] = {}

    def set_plan(self, plan: Plan) -> None:
        """Replace every row with the plan's steps."""
        self.border_title = plan.title or "Plan"
        self.remove_children()
        self.rows.clear()
        for step in plan.steps:
            text = self._row_text(step, *GLYPHS[step.state], step.reason)
            row = Static(text)
            self.rows[step_key(step)], self.texts[step_key(step)] = row, text
            self.mount(row)

    def _row_text(self, step: Step | str, glyph: str, style: str, detail: str) -> Text:
        text = Text.assemble((glyph, style), " ", step_label(step))
        if detail:
            text.append(f"  {detail}", style="dim")
        return text

    def begin(self, step: Step | str) -> None:
        """Mark a step as running (a spinner glyph) and start its clock."""
        self.started[step_key(step)] = time.monotonic()
        self._set(step, "▸", ACCENT, "running")

    def end(self, step: Step | str, *, ok: bool, detail: str) -> None:
        """Mark a step finished with its outcome and the time it took."""
        took = elapsed_text(time.monotonic() - self.started.pop(step_key(step), time.monotonic())) or "<1s"
        self._set(step, "✓" if ok else "✗", "green" if ok else "red", detail or f"({took})")

    def _set(self, step: Step | str, glyph: str, style: str, detail: str) -> None:
        key = step_key(step)
        row = self.rows.get(key)
        if row is None:
            row = Static()
            self.rows[key] = row
            self.mount(row)
        self.texts[key] = self._row_text(step, glyph, style, detail)
        row.update(self.texts[key])
        row.scroll_visible()


class StatusBar(Static):
    """The live line: a spinner while something runs, the current download's bar, the time so far."""

    def __init__(self) -> None:
        super().__init__("", id="status")
        self.label = ""
        self.detail = ""
        self.busy = False
        self.final = ""
        self._t0 = 0.0
        self._frame = 0

    def on_mount(self) -> None:
        """Tick ten times a second while something runs."""
        self.set_interval(0.1, self._tick)

    def set_busy(self, label: str, detail: str = "") -> None:
        """Show a running label (the clock restarts when the label changes)."""
        if label != self.label or not self.busy:
            self._t0 = time.monotonic()
        self.label, self.detail, self.busy = label, detail, True
        self._tick()

    def clear(self) -> None:
        """Nothing runs."""
        self.busy, self.label, self.detail = False, "", ""
        self._tick()

    def set_final(self, text: str) -> None:
        """The closing line once the command finished."""
        self.final = text
        self.clear()

    def _tick(self) -> None:
        if not self.busy:
            self.update(Text(self.final, style="bold") if self.final else Text(""))
            return
        self._frame += 1
        frame = SPIN_FRAMES[self._frame % len(SPIN_FRAMES)]
        text = Text.assemble((frame, ACCENT), " ", self.label)
        if self.detail:
            text.append(" " + self.detail)
        elapsed = elapsed_text(time.monotonic() - self._t0)
        if elapsed:
            text.append("  " + elapsed, style="dim")
        self.update(text)
