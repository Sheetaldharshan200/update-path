"""What's-new cards, from help/whats-new.json (one key per kit version, one short line per highlight)."""

from __future__ import annotations

import json
from pathlib import Path

from exakit.domain.errors import Failed
from exakit.domain.result import Result
from exakit.domain.versions import compare

from . import Context
from .machine import kit_bundled_version, kit_root


def _load(root: Path) -> dict[str, list[str]] | None:
    path = root / "help" / "whats-new.json"
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(doc, dict):
        return None
    return {k: [str(item) for item in v] for k, v in doc.items() if not k.startswith("_") and isinstance(v, list)}


def versions(root: Path) -> list[str]:
    """Every version with notes, oldest first."""
    doc = _load(root) or {}
    return sorted(doc, key=lambda v: (compare(v, "0"), v) and _key(v))


def _key(version: str) -> tuple[int, ...]:
    return tuple(int(p) for p in version.split(".") if p.isdigit())


def points(root: Path, version: str) -> list[str] | None:
    """The card lines of a version, or None."""
    doc = _load(root)
    if doc is None:
        return None
    return doc.get(version)


def crossed(root: Path, from_version: str, to_version: str) -> list[str]:
    """Versions in (from, to], oldest first: the cards an upgrade should show."""
    return [v for v in versions(root) if compare(v, from_version) > 0 and compare(v, to_version) <= 0]


def run(ctx: Context, version: str | None) -> Result:
    """``exakit whats-new``."""
    root = kit_root(ctx)
    version = version or kit_bundled_version(ctx) or (ctx.manifest_or_none() or _NoManifest()).get("kit.version")
    if not version:
        raise Failed("Could not tell which kit version this is. Name one: exakit whats-new 0.2.0")
    lines = points(root, version)
    if lines:
        if not ctx.json:
            ctx.ui.text("")
            ctx.ui.panel(f"What's new in {version}", lines)
            ctx.ui.text("")
        return Result(True, "ok", data={"version": version, "notes": lines})
    if _load(root) is None:
        if not ctx.json:
            ctx.ui.info("This kit copy does not carry help/whats-new.json.")
        return Result(True, "ok", data={"version": version, "notes": [], "versions": []})
    known = versions(root)
    if not ctx.json:
        ctx.ui.info(f"No notes for {version}. Versions covered:")
        for known_version in known:
            ctx.ui.text(f"      {known_version}")
    return Result(True, "ok", data={"version": version, "notes": [], "versions": known})


class _NoManifest:
    def get(self, path: str, default=None):
        """The empty record answers the default."""
        return default
