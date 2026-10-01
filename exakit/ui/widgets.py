"""Text helpers and the two palettes every renderer draws from.

The fancy palette is byte-for-byte the legacy ``ui.sh`` one, so screens look
the same as before; the plain palette is what a pipe, CI, a log or a
non-UTF-8 terminal gets.
"""

from __future__ import annotations

import os
import re
import shutil
from dataclasses import dataclass

_CSI = re.compile("\x1b\\[[0-9;]*m")
_OSC8 = re.compile("\x1b]8;;[^\x07\x1b]*(?:\x07|\x1b\\\\)")


def visible_len(text: str) -> int:
    """Character length ignoring colour and hyperlink escape sequences."""
    return len(_OSC8.sub("", _CSI.sub("", text)))


def term_cols(default: int = 80) -> int:
    """The terminal width, never below 40."""
    try:
        cols = shutil.get_terminal_size((default, 24)).columns
    except (OSError, ValueError):
        cols = default
    env = os.environ.get("COLUMNS", "")
    if env.isdigit() and int(env) >= 40:
        cols = int(env)
    return max(40, cols)


def wrap(text: str, width: int) -> list[str]:
    """Word-wrap a line to ``width`` visible columns; a word longer than the width is split."""
    if visible_len(text) <= width:
        return [text]
    lines: list[str] = []
    current = ""
    for token in text.split(" "):
        word = token
        while visible_len(word) > width:
            room = width - (visible_len(current) + 1 if current else 0)
            if room <= 0:
                lines.append(current)
                current = ""
                room = width
            current = (current + " " if current else "") + word[:room]
            word = word[room:]
            lines.append(current)
            current = ""
        candidate = (current + " " + word) if current else word
        if visible_len(candidate) > width and current:
            lines.append(current)
            current = word
        else:
            current = candidate
    if current:
        lines.append(current)
    return lines or [""]


def tilde(path: str, home: str) -> str:
    """Shorten the home directory to ``~`` so panels do not balloon."""
    if path == home:
        return "~"
    if path.startswith(home + os.sep):
        return "~" + path[len(home):]
    return path


@dataclass(frozen=True, slots=True)
class Palette:
    fancy: bool
    reset: str = ""
    bold: str = ""
    dim: str = ""
    accent: str = ""
    green: str = ""
    fg: str = ""
    ok: str = ""
    warn: str = ""
    err: str = ""
    info: str = ""
    ask: str = ""
    tick: str = "[ok]"
    cross: str = "[x]"
    bullet: str = "-"
    arrow: str = ">"
    hr: str = "-"
    tl: str = "+"
    tr: str = "+"
    bl: str = "+"
    br: str = "+"
    vb: str = "|"
    tee: str = "|-"
    corner: str = "`-"
    bar_full: str = "#"
    bar_empty: str = "."


PLAIN = Palette(fancy=False)

# The EXASOL wordmark (ANSI Shadow style), drawn in fancy mode above the title.
# Split so the X carries the logo's two-tone look: its left strokes and the
# crossing peak in Exasol green, the rest in the terminal's default colour.
WORDMARK_E = ("███████╗", "██╔════╝", "█████╗  ", "██╔══╝  ", "███████╗", "╚══════╝")
WORDMARK_X_LEFT = ("██╗ ", "╚██╗", " ╚███", " ██╔", "██╔╝", "╚═╝ ")
WORDMARK_X_RIGHT = (" ██╗", "██╔╝", "╔╝ ", "██╗ ", " ██╗", " ╚═╝")
WORDMARK_REST = (" █████╗ ███████╗ ██████╗ ██╗", "██╔══██╗██╔════╝██╔═══██╗██║", "███████║███████╗██║   ██║██║",
                 "██╔══██║╚════██║██║   ██║██║", "██║  ██║███████║╚██████╔╝███████╗", "╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚══════╝")


def wordmark_lines(palette: Palette) -> list[str]:
    """The six lines of the wordmark with the palette's colours; empty in plain mode."""
    if not palette.fancy:
        return []
    return [f"  {palette.bold}{palette.fg}{e}{palette.green}{xl}{palette.fg}{xr}{rest}{palette.reset}"
            for e, xl, xr, rest in zip(WORDMARK_E, WORDMARK_X_LEFT, WORDMARK_X_RIGHT, WORDMARK_REST, strict=True)]

FANCY = Palette(
    fancy=True,
    reset="\x1b[0m", bold="\x1b[1m", dim="\x1b[2m",
    accent="\x1b[38;5;35m", green="\x1b[38;5;77m", fg="\x1b[39m",
    ok="\x1b[1;32m", warn="\x1b[1;33m", err="\x1b[1;31m", info="\x1b[1;34m", ask="\x1b[1;36m",
    tick="✓", cross="✗", bullet="•", arrow="▸",
    hr="─", tl="╭", tr="╮", bl="╰", br="╯", vb="│",
    tee="├─", corner="└─", bar_full="█", bar_empty="░",
)


@dataclass(frozen=True, slots=True)
class Option:
    """One row of a menu."""

    id: str
    label: str
    hint: str = ""
    disabled: bool = False


def human_size(count: int) -> str:
    """``118 KB``, ``12.4 MB``, ``1.2 GB``."""
    if count < 1024 * 1024:
        return f"{max(1, count // 1024)} KB"
    if count < 1024 * 1024 * 1024:
        return f"{count / (1024 * 1024):.1f} MB"
    return f"{count / (1024 * 1024 * 1024):.2f} GB"


def progress_bar(done: int, total: int | None, width: int = 20) -> str:
    """``[########............] 42%  12.4/29.0 MB``; the bytes alone when the total is unknown."""
    if not total:
        return human_size(done)
    share = min(1.0, done / total)
    filled = round(share * width)
    return f"[{'#' * filled}{'.' * (width - filled)}] {int(share * 100):3d}%  {human_size(done)}/{human_size(total)}"
