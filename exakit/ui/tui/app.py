"""The kit's full-screen app: the command runs in a worker thread, the screens draw on the main thread."""

from __future__ import annotations

import asyncio
from collections.abc import Callable
from typing import Any

from rich.text import Text
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Footer, RichLog

from exakit.domain.errors import ExakitError
from exakit.domain.plan import Plan, Step
from exakit.domain.result import Result

from .panels import PlanPanel, StatusBar, WordmarkHeader


class KitApp(App[None]):
    """Header, plan, log, status bar; ``job`` runs in a thread once the app is mounted."""

    CSS_PATH = "app.tcss"
    BINDINGS = [Binding("ctrl+c", "request_quit", "Quit", priority=True), Binding("ctrl+q", "request_quit", "Quit", show=False),
                Binding("enter", "close", "Close when finished", show=False), Binding("q", "close", "Close", show=False)]

    def __init__(self, *, title: str, subtitle: str = "", job: Callable[[], Result] | None = None) -> None:
        super().__init__()
        self.title_text = title
        self.subtitle_text = subtitle
        self.job = job
        self.done = False
        self._outcome: tuple[str, Any] | None = None

    # --- layout ---------------------------------------------------------------------

    def compose(self) -> ComposeResult:
        """The wordmark header, the plan beside the log, the status bar, the footer."""
        yield WordmarkHeader(self.title_text, self.subtitle_text)
        with Horizontal(id="body"):
            yield PlanPanel()
            with Vertical():
                yield RichLog(id="log", wrap=True, markup=False, highlight=False)
        yield StatusBar()
        yield Footer()

    def on_mount(self) -> None:
        """Start the command in a worker thread."""
        if self.job is not None:
            self.run_worker(self._work, thread=True, exit_on_error=False, name="command")

    def _work(self) -> None:
        try:
            self._outcome = ("result", self.job())      # type: ignore[misc]
        except ExakitError as err:
            self._outcome = ("error", err)
        except BaseException as err:    # carried to the main thread and re-raised there
            self._outcome = ("crash", err)
        self.call_from_thread(self._finished)

    def _finished(self) -> None:
        self.done = True
        kind = self._outcome[0] if self._outcome else "crash"
        self.status.set_final("Finished - press Enter to close" if kind == "result" else "Stopped - press Enter to close (the details follow)")

    # --- what the worker asks for (every call arrives through call_from_thread) ----------------

    @property
    def status(self) -> StatusBar:
        """The status bar."""
        return self.query_one(StatusBar)

    def write(self, text: Text) -> None:
        """Append a line to the log pane."""
        self.query_one(RichLog).write(text)

    def set_title(self, title: str, subtitle: str = "") -> None:
        """Replace the header's title and subtitle."""
        self.query_one(WordmarkHeader).set_title(title, subtitle)

    def set_plan(self, plan: Plan) -> None:
        """Show a plan in the plan panel."""
        self.query_one(PlanPanel).set_plan(plan)

    def step_begin(self, step: Step | str) -> None:
        """A step started."""
        self.query_one(PlanPanel).begin(step)

    def step_end(self, step: Step | str, *, ok: bool, detail: str) -> None:
        """A step finished."""
        self.query_one(PlanPanel).end(step, ok=ok, detail=detail)

    def set_busy(self, label: str, detail: str = "") -> None:
        """The status bar shows something running."""
        self.status.set_busy(label, detail)

    def clear_busy(self) -> None:
        """The status bar shows nothing running."""
        self.status.clear()

    async def ask(self, screen: ModalScreen) -> Any:
        """Show a modal question and wait for its answer."""
        future: asyncio.Future = asyncio.get_running_loop().create_future()
        self.push_screen(screen, callback=future.set_result)
        return await future

    # --- closing ---------------------------------------------------------------------------

    def action_close(self) -> None:
        """Enter or q close the app once the command finished."""
        if self.done:
            self.exit()

    def action_request_quit(self) -> None:
        """Ctrl-C: leave now; the process exits 130 as it did without the screens."""
        if not self.done:
            self._outcome = ("interrupt", None)
        self.exit()

    def outcome(self) -> Result:
        """The job's Result; its ExakitError raised; KeyboardInterrupt when the app was quit early."""
        kind, value = self._outcome or ("interrupt", None)
        if kind == "result":
            return value
        if kind == "interrupt":
            raise KeyboardInterrupt
        raise value
