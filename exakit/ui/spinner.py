"""The live line of the console renderer: a spinner with a detail and the time so far, and its plain-mode stand-in."""

from __future__ import annotations

import threading
import time
from typing import IO

from .widgets import progress_bar

SPIN_FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"


class Milestones:
    """Plain-mode download progress: one line at each quarter, so a log reader sees it move without a redraw."""

    def __init__(self, console, label: str) -> None:
        self.console = console
        self.label = label
        self.shown = 0

    def report(self, done: int, total: int | None) -> None:
        """Print the quarter just crossed, once."""
        if not total:
            return
        quarter = min(4, done * 4 // total)
        while self.shown < quarter:
            self.shown += 1
            self.console._w(f"      {self.console.p.dim}{self.label}: {progress_bar(done, total)}{self.console.p.reset}")


def elapsed_text(seconds: float) -> str:
    """``12s`` or ``1m 05s``; nothing in the first two seconds."""
    if seconds < 2:
        return ""
    whole = int(seconds)
    return f"{whole}s" if whole < 60 else f"{whole // 60}m {whole % 60:02d}s"


class Spinner:
    """Redraws one line on a thread until stopped: the frame, the label, a detail that can change, the time so far."""

    def __init__(self, out: IO[str], template: str) -> None:
        self.out = out
        self.template = template
        self.detail = ""
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._t0 = time.monotonic()

    def start(self) -> None:
        """Start the spinner."""
        self.out.write("\x1b[?25l")
        self._thread.start()

    def _run(self) -> None:
        i = 0
        while not self._stop.is_set():
            line = self.template.format(frame=SPIN_FRAMES[i % len(SPIN_FRAMES)], detail=self.detail, elapsed=elapsed_text(time.monotonic() - self._t0))
            self.out.write("\r\x1b[K  " + line.rstrip())
            self.out.flush()
            i += 1
            self._stop.wait(0.1)

    def stop(self) -> None:
        """Stop the spinner and clear its line."""
        self._stop.set()
        self._thread.join(timeout=1)
        self.out.write("\r\x1b[K\x1b[?25h")
        self.out.flush()
