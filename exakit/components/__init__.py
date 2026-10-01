"""The kit's own parts, one lifecycle each: the launcher, exapump, the MCP server, pyexasol, the kit copy, the skill set.

``for_component`` answers by id. Every lifecycle knows its installed and
target versions, installs one version, validates, updates (the install
plus the record) and removes itself; the use cases never touch a component
any other way.
"""

from __future__ import annotations

import importlib
from typing import Protocol

MODULES = {"exapump": "exapump", "mcp": "mcp_server", "pyexasol": "pyexasol", "personal": "personal", "runtime": "personal",
           "exakit": "kit", "skills": "skill_set"}


class ComponentLifecycle(Protocol):
    id: str
    def installed_version(self) -> str | None: ...
    def target_version(self) -> str: ...
    def install(self, version: str) -> None: ...
    def validate(self) -> None: ...
    def update(self, options: list[str] | None = None) -> None: ...
    def uninstall(self, *, dry_run: bool) -> list[str]: ...


def for_component(ctx, cid: str) -> ComponentLifecycle:
    module = importlib.import_module(f"exakit.components.{MODULES[cid]}")
    return module.Lifecycle(ctx)


def known(cid: str) -> bool:
    return cid in MODULES


__all__ = ["ComponentLifecycle", "for_component", "known"]
