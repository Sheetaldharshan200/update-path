"""Renderers: the same result objects drawn for a terminal, a pipe, or not at all (``--json``).

Fancy output (colour, glyphs, a spinner) appears only on an interactive
UTF-8 terminal that wants colour; everything else gets plain ASCII, one line
per event, safe for logs. That is the legacy ``ui_detect`` rule, unchanged.
"""

from __future__ import annotations

import os
import sys
from collections.abc import Callable, Mapping, Sequence
from contextlib import AbstractContextManager
from typing import IO, Protocol

from exakit.domain.log import Log
from exakit.domain.plan import Plan, Step

from .console import ConsoleRenderer
from .silent import SilentRenderer
from .keys import key_reader
from .widgets import FANCY, PLAIN, Option


class Renderer(Protocol):
    interactive: bool
    fancy: bool
    def text(self, line: str) -> None: ...
    def banner(self, title: str, subtitle: str = "") -> None: ...
    def heading(self, text: str) -> None: ...
    def info(self, text: str) -> None: ...
    def ok(self, text: str) -> None: ...
    def warn(self, text: str) -> None: ...
    def error(self, text: str) -> None: ...
    def card(self, message: str, *, log_path: str | None = None, remedy: str | None = None) -> None: ...
    def rule(self) -> None: ...
    def panel(self, title: str, lines: Sequence[str]) -> None: ...
    def plan(self, plan: Plan) -> None: ...
    def step_begin(self, step: Step | str) -> None: ...
    def step_end(self, step: Step | str, *, ok: bool = True, detail: str = "") -> None: ...
    def confirm(self, question: str, default: bool = True) -> bool: ...
    def prompt(self, question: str, default: str = "") -> str: ...
    def select(self, title: str, options: Sequence[Option], default: int = 1) -> str | None: ...
    def checkboxes(self, title: str, options: Sequence[Option], defaults: Sequence[str]) -> list[str]: ...
    def busy(self, label: str) -> AbstractContextManager[None]: ...
    def progress(self, label: str) -> AbstractContextManager[Callable[[int, int | None], None]]: ...


def wants_fancy(env: Mapping[str, str], out: IO[str]) -> bool:
    """The legacy rule: a terminal, colour not refused, not dumb, a UTF-8 locale."""
    try:
        if not out.isatty():
            return False
    except (AttributeError, ValueError):
        return False
    if env.get("NO_COLOR") or env.get("TERM", "") == "dumb" or env.get("EXAKIT_NO_FANCY") == "1":
        return False
    locale = env.get("LC_ALL") or env.get("LC_CTYPE") or env.get("LANG") or ""
    return "utf" in locale.lower()


def has_terminal(out: IO[str]) -> bool:
    """A terminal we can ASK on: stdout is a tty and stdin is one, or /dev/tty opens."""
    try:
        if not out.isatty():
            return False
        if sys.stdin.isatty():
            return True
    except (AttributeError, ValueError):
        return False
    if os.name != "nt":
        try:
            with open("/dev/tty", encoding="utf-8"):
                return True
        except OSError:
            return False
    return False


def _tty_reader():
    """Read a line from the terminal even when stdin is a pipe (the legacy /dev/tty reattach)."""
    def read() -> str:
        try:
            if sys.stdin.isatty():
                return sys.stdin.readline()
        except ValueError:
            pass
        if os.name != "nt":
            try:
                with open("/dev/tty", encoding="utf-8") as tty:
                    return tty.readline()
            except OSError:
                return ""
        return ""
    return read


def make_renderer(*, json: bool, env: Mapping[str, str], out: IO[str] | None = None, log: Log | None = None,
                  home: str = "") -> Renderer:
    """Silent under --json; otherwise the console with the palette this stream deserves."""
    out = out or sys.stdout
    if json:
        return SilentRenderer(log)
    palette = FANCY if wants_fancy(env, out) else PLAIN
    interactive = has_terminal(out)
    return ConsoleRenderer(palette=palette, out=out, interactive=interactive, log=log,
                           reader=_tty_reader(), home=home, keys=key_reader() if interactive else None)
