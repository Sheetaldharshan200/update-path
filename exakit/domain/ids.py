"""Identifiers: the one place the kit's naming rules live.

Ids are kebab-case in data files and on the command line (``dash-server``)
and snake_case as manifest keys (``dash_server``). AI client ids are fixed
tokens with a few aliases users may type; menu numbers are accepted for
backwards compatibility but never documented, because display order changes.
"""

from __future__ import annotations

import re

from .errors import BadInput

CLIENT_IDS: tuple[str, ...] = (
    "claude_desktop", "claude_code", "cursor", "codex",
    "vscode_copilot", "gemini_cli", "opencode", "continue",
)

# What a user may type -> the client ids it means. "claude" is both Claude surfaces.
_CLIENT_ALIASES: dict[str, tuple[str, ...]] = {
    "claude": ("claude_desktop", "claude_code"), "1": ("claude_desktop", "claude_code"),
    "claude_desktop": ("claude_desktop",), "claude_code": ("claude_code",),
    "codex": ("codex",), "2": ("codex",),
    "cursor": ("cursor",), "3": ("cursor",),
    "copilot": ("vscode_copilot",), "vscode": ("vscode_copilot",), "vscode_copilot": ("vscode_copilot",), "4": ("vscode_copilot",),
    "gemini": ("gemini_cli",), "gemini_cli": ("gemini_cli",), "5": ("gemini_cli",),
    "opencode": ("opencode",), "6": ("opencode",),
    "continue": ("continue",), "7": ("continue",),
}

CLIENT_WORDS_HELP = "claude, codex, cursor, copilot, gemini, opencode, continue, all, skip"

_TOKEN = re.compile(r"^[a-z0-9][a-z0-9_-]*$")


def is_token(value: str) -> bool:
    """A safe id: lowercase letters, digits, dash, underscore. Nothing else ever reaches a command line."""
    return bool(_TOKEN.match(value))


def manifest_key(catalog_id: str) -> str:
    """``dash-server`` -> ``dash_server``."""
    return catalog_id.replace("-", "_")


def catalog_id(manifest_key_name: str) -> str:
    """``dash_server`` -> ``dash-server``."""
    return manifest_key_name.replace("_", "-")


def env_var(catalog_id_name: str, suffix: str) -> str:
    """``dash-server``, ``VERSION`` -> ``EXAKIT_DASH_SERVER_VERSION``."""
    return f"EXAKIT_{catalog_id_name.upper().replace('-', '_')}_{suffix}"


def parse_client_selection(text: str) -> list[str]:
    """Client ids from an ``EXAKIT_MCP_CLIENTS`` value, de-duplicated, in the kit's order.

    ``all`` means every client id (the caller narrows it to the ones detected
    on this machine). Raises BadInput for anything else it does not know.
    """
    raw = [t for t in re.split(r"[,/\s]+", text.strip()) if t]
    if not raw:
        raise BadInput(f"EXAKIT_MCP_CLIENTS is empty (use {CLIENT_WORDS_HELP}).")
    if len(raw) == 1 and raw[0].lower() == "all":
        return list(CLIENT_IDS)
    chosen: set[str] = set()
    for token in raw:
        ids = _CLIENT_ALIASES.get(token.lower())
        if ids is None:
            raise BadInput(f"'{token}' is not an AI client the kit knows (use {CLIENT_WORDS_HELP}).")
        chosen.update(ids)
    return [cid for cid in CLIENT_IDS if cid in chosen]


def is_skip_word(text: str) -> bool:
    """``skip`` / ``none`` in any case: the scripted way to say "no clients"."""
    return text.strip().lower() in {"skip", "none"}
