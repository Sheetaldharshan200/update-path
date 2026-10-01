"""The install record (``manifest.json``): the kit's only state store.

This module is pure: it holds the document and the rules for reading,
writing and migrating it. Loading and saving the file is
``adapters.fs.manifest_store``. Keys are addressed by dot path
(``components.mcp_server.version``), which is how every command and every
document about the kit already names them.

Schema history (always additive, so an older kit reads a newer file):

    1  the 0.1.0 / 0.2.0 shape: manifest_version, kit_level, installed_at, os, arch,
       runtime, components, data, steps_completed, log_dir (+ keys added at run time)
    2  adds schema_version, kit.python (the managed interpreter) and the
       persona block (absent until one is recorded)
"""

from __future__ import annotations

import copy
from datetime import datetime, UTC
from typing import Any

from .platform import Platform

SCHEMA_VERSION = 2
STEP_IDS: tuple[str, ...] = ("launcher", "runtime", "exapump", "mcp", "pyexasol", "exakit_helper")


def utc_now() -> str:
    """The timestamp format every record in the manifest uses."""
    return datetime.now(UTC).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


class Manifest:
    """A manifest document and the operations the kit performs on it."""

    def __init__(self, doc: dict[str, Any]) -> None:
        if not isinstance(doc, dict):
            raise TypeError("a manifest is a JSON object")
        self._doc = doc

    @classmethod
    def new(cls, *, platform: Platform, log_dir: str, steps_completed: list[str] | None = None) -> Manifest:
        """The document a fresh install starts from (the legacy initial shape, plus schema 2)."""
        return cls({
            "manifest_version": 1,
            "schema_version": SCHEMA_VERSION,
            "kit_level": 1,
            "installed_at": utc_now(),
            "os": platform.os,
            "arch": platform.arch,
            "runtime": {},
            "components": {},
            "data": {"loaded": False},
            "steps_completed": list(steps_completed or []),
            "log_dir": log_dir,
        })

    @property
    def doc(self) -> dict[str, Any]:
        """The record as a dict."""
        return self._doc

    @property
    def schema_version(self) -> int:
        """The record's schema version (1 when unset)."""
        value = self._doc.get("schema_version", 1)
        return value if isinstance(value, int) else 1

    def copy(self) -> Manifest:
        """A deep copy."""
        return Manifest(copy.deepcopy(self._doc))

    # --- dot-path access -------------------------------------------------------

    def get(self, path: str, default: Any = None) -> Any:
        """The value at a dot path, or ``default`` when any segment is missing."""
        node: Any = self._doc
        for part in path.split("."):
            if not isinstance(node, dict) or part not in node:
                return default
            node = node[part]
        return node

    def set(self, path: str, value: Any) -> None:
        """Write a value, creating intermediate objects; a scalar in the way is replaced."""
        parts = path.split(".")
        node = self._doc
        for part in parts[:-1]:
            child = node.get(part)
            if not isinstance(child, dict):
                child = {}
                node[part] = child
            node = child
        node[parts[-1]] = value

    def delete(self, path: str) -> bool:
        """Remove a key and everything under it. True when something was removed."""
        parts = path.split(".")
        node: Any = self._doc
        for part in parts[:-1]:
            node = node.get(part) if isinstance(node, dict) else None
            if node is None:
                return False
        if isinstance(node, dict) and parts[-1] in node:
            del node[parts[-1]]
            return True
        return False

    # --- the records commands share ---------------------------------------------

    def steps_completed(self) -> list[str]:
        """The install steps ticked so far, in order."""
        steps = self._doc.get("steps_completed")
        return [s for s in steps if isinstance(s, str)] if isinstance(steps, list) else []

    def mark_step(self, step_id: str) -> None:
        """Tick an install step once."""
        steps = self.steps_completed()
        if step_id not in steps:
            steps.append(step_id)
        self._doc["steps_completed"] = steps

    def unmark_step(self, step_id: str) -> None:
        """Untick an install step."""
        self._doc["steps_completed"] = [s for s in self.steps_completed() if s != step_id]

    def runtime_type(self) -> str | None:
        """The recorded runtime type, or None."""
        value = self.get("runtime.type")
        return value if isinstance(value, str) and value else None

    def persona_id(self) -> str | None:
        """The recorded persona id, or None."""
        value = self.get("persona.id")
        return value if isinstance(value, str) and value else None

    # --- migration ----------------------------------------------------------------

    def migrate(self) -> list[str]:
        """Bring the document to the current schema. Returns one note per change, empty when current."""
        notes: list[str] = []
        if self.schema_version < 2:
            self._doc["schema_version"] = 2
            notes.append("manifest schema 1 -> 2 (adds schema_version; persona and kit.python are recorded when known)")
        return notes
