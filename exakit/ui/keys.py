"""One key at a time from the terminal, for the arrow-key menus: names, never raw bytes.

POSIX reads the controlling terminal in cbreak mode (no echo, no line
buffering); Windows reads the console through msvcrt. A key arrives as a
name: ``up``, ``down``, ``space``, ``enter``, ``esc``, a single character
(``a``, ``n``, ``j``, ``k``, a digit), or ``other``.
"""

from __future__ import annotations

import os
import sys
from collections.abc import Callable

ARROWS = {"A": "up", "B": "down", "C": "right", "D": "left"}
WINDOWS_ARROWS = {"H": "up", "P": "down", "M": "right", "K": "left"}


def key_reader() -> Callable[[], str] | None:
    """A reader bound to the terminal, or None when there is no terminal to read keys from."""
    if os.name == "nt":
        try:
            import msvcrt
        except ImportError:
            return None
        return lambda: _windows_key(msvcrt)
    try:
        import termios
        import tty
        fd = os.open("/dev/tty", os.O_RDWR)
    except (ImportError, OSError):
        return None
    return lambda: _posix_key(fd, termios, tty)


def _posix_key(fd: int, termios, tty) -> str:
    saved = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        first = os.read(fd, 1)
        if first == b"\x1b":
            return _escape_sequence(fd)
        return _name(first.decode("utf-8", "replace"))
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)


def _escape_sequence(fd: int) -> str:
    """An ESC followed by ``[A``.. within a few milliseconds is an arrow; a lone ESC backs out."""
    import select

    ready, _, _ = select.select([fd], [], [], 0.05)
    if not ready:
        return "esc"
    rest = os.read(fd, 2)
    if len(rest) == 2 and rest[0:1] == b"[":
        return ARROWS.get(rest[1:2].decode("ascii", "replace"), "other")
    return "other"


def _windows_key(msvcrt) -> str:
    char = msvcrt.getwch()
    if char in ("\x00", "\xe0"):
        return WINDOWS_ARROWS.get(msvcrt.getwch(), "other")
    if char == "\x1b":
        return "esc"
    return _name(char)


def _name(char: str) -> str:
    if char in ("\r", "\n"):
        return "enter"
    if char == " ":
        return "space"
    if char in ("\x03", "\x04"):      # Ctrl-C, Ctrl-D: back out
        return "esc"
    return char if len(char) == 1 and char.isprintable() else "other"


def stdin_is_terminal() -> bool:
    """True when stdin is a terminal; False when it is a pipe or closed."""
    try:
        return sys.stdin.isatty()
    except (AttributeError, ValueError):
        return False
