"""The field rules every catalog document is held to: strings, ids, schema, sources, platforms, choices, clients."""

from __future__ import annotations

from collections.abc import Iterable
from typing import Any

from .errors import BadInput
from .ids import is_token, parse_client_selection
from .platform import ARCH_NAMES, OS_NAMES

COMPONENT_KINDS = ("runtime", "binary", "python-tool", "python-venv", "skills", "helper")
ADDON_KINDS = ("python-venv", "binary", "host-extension", "custom")
SOURCE_TYPES = ("github_release", "github_tag", "pypi", "kit")
PLATFORM_KEYS = tuple(f"{o}-{a}" for o in OS_NAMES for a in ARCH_NAMES)
Problems = list[str]


def _is_str(value: Any, *, max_len: int | None = None, ascii_only: bool = True) -> bool:
    if not isinstance(value, str) or not value:
        return False
    if ascii_only and not value.isascii():
        return False
    return max_len is None or len(value) <= max_len


def _check_id(doc: dict[str, Any], expected_id: str | None, problems: Problems) -> None:
    cid = doc.get("id")
    if not isinstance(cid, str) or not is_token(cid) or "_" in cid:
        problems.append("id must be lowercase letters, digits and dashes")
    elif expected_id is not None and cid != expected_id:
        problems.append(f"id '{cid}' does not match the file name '{expected_id}'")


def _check_schema(doc: Any, problems: Problems) -> bool:
    if not isinstance(doc, dict):
        problems.append("not a JSON object")
        return False
    if doc.get("schema_version") != 1:
        announced = doc.get("schema_version")
        if isinstance(announced, int) and announced > 1:
            problems.append(f"schema_version {announced} needs a newer kit (exakit update)")
        else:
            problems.append("schema_version must be 1")
        return False
    return True


def _check_source(source: Any, problems: Problems) -> None:
    if not isinstance(source, dict) or source.get("type") not in SOURCE_TYPES:
        problems.append(f"source.type must be one of {', '.join(SOURCE_TYPES)}")
        return
    kind = source["type"]
    if kind in ("github_release", "github_tag") and not _is_str(source.get("repo")):
        problems.append("source.repo is required for a GitHub source")
    if kind == "pypi" and not _is_str(source.get("package")):
        problems.append("source.package is required for a PyPI source")
    _check_release_sites(source.get("releases"), problems)


def _check_release_sites(sites: Any, problems: Problems) -> None:
    """``source.releases``: each site a repository or ``mirror: kit``, a tag template, an assets map; optional checksums, member, pins."""
    if sites is None:
        return
    if not isinstance(sites, list) or not sites:
        problems.append("source.releases must be a non-empty list of release sites")
        return
    for index, site in enumerate(sites):
        where = f"source.releases[{index}]"
        if not isinstance(site, dict):
            problems.append(f"{where} must be an object")
            continue
        if site.get("mirror") not in (None, "kit") or (site.get("mirror") is None and not _is_str(site.get("repo"))):
            problems.append(f"{where} needs repo (owner/name) or mirror: kit")
        assets = site.get("assets")
        if not isinstance(assets, dict) or not assets or not all(_is_str(k) and _is_str(v) for k, v in assets.items()):
            problems.append(f"{where}.assets must map platform keys (or wheel) to asset name templates")
        elif any(k not in PLATFORM_KEYS and k != "wheel" for k in assets):
            problems.append(f"{where}.assets keys must be platform keys or wheel")
        for key in ("tag", "checksums", "member", "pins"):
            if key in site and not _is_str(site[key]):
                problems.append(f"{where}.{key} must be a string")


def _check_platforms(doc: dict[str, Any], problems: Problems) -> None:
    platforms = doc.get("platforms", [])
    if not isinstance(platforms, list) or any(p not in PLATFORM_KEYS for p in platforms):
        problems.append(f"platforms must list keys from {', '.join(PLATFORM_KEYS)}")


def _check_id_list(doc: dict[str, Any], key: str, problems: Problems, *, allow_words: tuple[str, ...] = ()) -> None:
    value = doc.get(key)
    if isinstance(value, str) and value in allow_words:
        return
    if not isinstance(value, list) or not all(isinstance(v, str) and is_token(v) for v in value):
        joined = '", "'.join(allow_words)
        words = f' or one of "{joined}"' if allow_words else ""
        problems.append(f"{key} must be a list of ids{words}")


# --- components -------------------------------------------------------------------


def _check_choice(doc: dict[str, Any], key: str, words: tuple[str, ...], known: Iterable[str] | None,
                  noun: str, problems: Problems) -> None:
    value = doc.get(key)
    if isinstance(value, str):
        if value not in words:
            problems.append(f'{key} must be "{words[0]}", "{words[1]}" or a list of {noun} ids')
        return
    if not isinstance(value, list) or not value:
        problems.append(f'{key} must be "{words[0]}", "{words[1]}" or a non-empty list of {noun} ids')
        return
    known_set = set(known) if known is not None else None
    for item in value:
        if not isinstance(item, str) or not is_token(item):
            problems.append(f"{key}: '{item}' is not a valid id")
        elif known_set is not None and item not in known_set:
            problems.append(f"{key}: '{item}' is not a {noun} this kit knows")


def _check_clients(doc: dict[str, Any], problems: Problems) -> None:
    value = doc.get("mcp_clients")
    if isinstance(value, str):
        if value not in ("all", "skip"):
            problems.append('mcp_clients must be "all", "skip" or a list of client names')
        return
    if not isinstance(value, list) or not value:
        problems.append('mcp_clients must be "all", "skip" or a non-empty list of client names')
        return
    for item in value:
        if not isinstance(item, str) or not item.replace("_", "").isalpha() or item.isdigit():
            problems.append(f"mcp_clients: '{item}' is not a client name (names, never numbers)")
            continue
        try:
            parse_client_selection(item)
        except BadInput:
            problems.append(f"mcp_clients: '{item}' is not one EXAKIT_MCP_CLIENTS accepts")


# --- the catalog ----------------------------------------------------------------------
