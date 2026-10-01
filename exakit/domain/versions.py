"""``versions.json``: the tested set the maintainers publish, and how a version is chosen.

Four promises, kept here and proven by the tests:

1. A document is trusted only after validation; a newer schema is reported as
   "update the kit", never as corruption.
2. Every advertised version and digest is checked against a safe charset,
   because both end up in download URLs and command lines.
3. Comparison never raises and orders a pre-release below its release.
4. Resolution degrades in one fixed order: an explicit ``EXAKIT_<ID>_VERSION``,
   then the policy (manifest, latest, pinned), then the built-in fallback.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from enum import Enum
from typing import Any
from collections.abc import Callable

SCHEMA_VERSION = 1

_VERSION_RE = re.compile(r"^[A-Za-z0-9._+-]+$")
_DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")


class VersionsInvalid(ValueError):
    """The document is not one this kit can trust. ``reason`` says why."""


class VersionsSchemaAhead(VersionsInvalid):
    """Readable JSON that announces a newer schema than this kit reads."""


class VersionPolicy(str, Enum):
    MANIFEST = "manifest"   # the published tested set (default)
    LATEST = "latest"       # each component's own upstream
    PINNED = "pinned"       # the kit's built-in fallbacks, no network

    @classmethod
    def from_env(cls, value: str | None) -> VersionPolicy:
        """``manifest`` and ``latest`` by name; anything else, including unset-but-odd values, is pinned."""
        if value is None or value == "":
            return cls.MANIFEST
        return {"manifest": cls.MANIFEST, "latest": cls.LATEST}.get(value.strip().lower(), cls.PINNED)


# --- the document -----------------------------------------------------------------


def _check_block(name: str, block: Any) -> None:
    if not isinstance(block, dict):
        raise VersionsInvalid(f"{name} is not an object")
    version = block.get("version")
    if not isinstance(version, str) or not _VERSION_RE.match(version):
        raise VersionsInvalid(f"{name}.version is missing or carries unsafe characters")
    min_kit = block.get("min_kit_version")
    if min_kit is not None and (not isinstance(min_kit, str) or not _VERSION_RE.match(min_kit)):
        raise VersionsInvalid(f"{name}.min_kit_version carries unsafe characters")
    digests = block.get("sha256")
    if digests is not None:
        if not isinstance(digests, dict) or not digests:
            raise VersionsInvalid(f"{name}.sha256 must be a non-empty object")
        for key, value in digests.items():
            if not isinstance(value, str) or not _DIGEST_RE.match(value):
                raise VersionsInvalid(f"{name}.sha256.{key} is not a 64-hex digest")


def validate(doc: Any) -> None:
    """Raise VersionsInvalid (or VersionsSchemaAhead) unless the document is one this kit trusts."""
    if not isinstance(doc, dict):
        raise VersionsInvalid("not a JSON object")
    announced = doc.get("schema_version")
    if announced != SCHEMA_VERSION:
        if isinstance(announced, int) and announced > SCHEMA_VERSION:
            raise VersionsSchemaAhead(f"schema_version {announced} needs a newer kit")
        raise VersionsInvalid("schema_version is missing or not one this kit reads")
    _check_block("kit", doc.get("kit"))
    components = doc.get("components")
    if not isinstance(components, dict) or not components:
        raise VersionsInvalid("components is missing or empty")
    for cid, block in components.items():
        _check_block(f"components.{cid}", block)
    if doc.get("kit2") is not None:
        _check_block("kit2", doc["kit2"])
    tools = doc.get("tools")
    if tools is not None:
        if not isinstance(tools, dict):
            raise VersionsInvalid("tools is not an object")
        for tid, block in tools.items():
            _check_block(f"tools.{tid}", block)


@dataclass(frozen=True, slots=True)
class VersionsDoc:
    """A validated document. Construct through ``parse``."""

    raw: dict[str, Any]

    @classmethod
    def parse(cls, text: str) -> VersionsDoc:
        """A VersionsDoc from the manifest's text; invalid text is VersionsInvalid."""
        try:
            doc = json.loads(text)
        except ValueError as err:
            raise VersionsInvalid("not JSON") from err
        validate(doc)
        return cls(doc)

    def value(self, path: str) -> Any:
        """The value at a dot path, or None when it is not advertised."""
        node: Any = self.raw
        for part in path.split("."):
            if not isinstance(node, dict) or part not in node:
                return None
            node = node[part]
        return node

    def kit_version(self) -> str:
        """The kit version the manifest advertises."""
        return str(self.raw["kit"]["version"])

    def updated(self) -> str | None:
        """The manifest's updated date, or None."""
        value = self.raw.get("updated")
        return value if isinstance(value, str) else None

    def component(self, cid: str) -> dict[str, Any] | None:
        """A component's block, or None."""
        block = self.raw["components"].get(cid)
        return block if isinstance(block, dict) else None

    def component_version(self, cid: str) -> str | None:
        """The version advertised for a component, or None."""
        block = self.component(cid)
        return str(block["version"]) if block else None

    def sha256(self, cid: str, platform_key: str) -> str | None:
        """The digest for a component on a platform, or None."""
        value = self.value(f"components.{cid}.sha256.{platform_key}")
        return value if isinstance(value, str) else None

    def tool(self, tid: str) -> dict[str, Any] | None:
        """A tool's block (uv), or None."""
        block = self.value(f"tools.{tid}")
        return block if isinstance(block, dict) else None

    def severity(self, cid: str) -> str:
        """The update severity for a component (normal by default)."""
        value = self.value(f"components.{cid}.severity")
        return value if value in ("recommended", "critical") else "normal"

    def note(self, cid: str) -> str | None:
        """The note attached to a component's version, or None."""
        value = self.value(f"components.{cid}.note")
        return value if isinstance(value, str) and value else None

    def min_kit_version(self, cid: str) -> str | None:
        """The kit version a component's version needs, or None."""
        value = self.value(f"components.{cid}.min_kit_version")
        return value if isinstance(value, str) and value else None


def cache_outranks_baked(cache: VersionsDoc, baked: VersionsDoc | None) -> bool:
    """A cached document loses only when it is provably older than the kit's own copy.

    Dates are the ``updated`` field (ISO YYYY-MM-DD), so a string compare is a
    date compare. Same date still wins, and an unreadable date on either side
    keeps the cache (a fetch usually returns the document the kit shipped).
    """
    if baked is None:
        return True
    cache_date, baked_date = cache.updated(), baked.updated()
    if not cache_date or not baked_date:
        return True
    return not cache_date < baked_date


# --- comparison -------------------------------------------------------------------


def parse_version(text: str) -> tuple[tuple[int, ...], tuple[int, ...], int]:
    """A sort key where a pre-release sorts below its release and ``.postN`` above it.

    Build metadata after ``+`` carries no order. Every element is an int, so
    comparing two keys never raises.
    """
    v = text.strip().lstrip("v").split("+", 1)[0]
    post = 0
    m = re.search(r"\.post(\d+)$", v)
    if m:
        post = int(m.group(1))
        v = v[: m.start()]
    pre: tuple[int, ...] = ()
    m = re.match(r"^(.*?)[-_.]?(rc|alpha|beta|a|b)\.?(\d*)$", v)
    if m and m.group(2):
        v = m.group(1).rstrip(".-_")
        pre = ({"alpha": 0, "a": 0, "beta": 1, "b": 1, "rc": 2}[m.group(2)], int(m.group(3) or 0))
    nums = tuple(int(p) for p in re.findall(r"\d+", v))
    return (nums, (1,) if not pre else (0, *pre), post)


def compare(a: str, b: str) -> int:
    """-1, 0 or 1. Never raises."""
    ka, kb = parse_version(a), parse_version(b)
    return (ka > kb) - (ka < kb)


def is_newer(a: str, b: str) -> bool:
    """True when ``a`` is strictly newer than ``b``. Empty or equal strings are never newer."""
    if not a or not b or a == b:
        return False
    return compare(a, b) > 0


# --- resolution -------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class Resolved:
    version: str
    source: str   # env | manifest | latest | fallback


def resolve(
    component_id: str,
    *,
    policy: VersionPolicy,
    env_pin: str | None,
    doc: VersionsDoc | None,
    fallback: str | None,
    latest: Callable[[], str | None] | None = None,
) -> Resolved | None:
    """The version this kit would install NOW for a component, and where that answer came from.

    Order: an explicit pin wins; ``latest`` asks upstream (and falls back when
    upstream is silent); ``pinned`` never touches the document; ``manifest``
    reads the document and falls back when the component is not advertised.
    None means nothing is known at all.
    """
    if env_pin:
        return Resolved(env_pin, "env")
    if policy is VersionPolicy.LATEST:
        found = latest() if latest else None
        if found:
            return Resolved(found, "latest")
        return Resolved(fallback, "fallback") if fallback else None
    if policy is VersionPolicy.PINNED:
        return Resolved(fallback, "fallback") if fallback else None
    advertised = doc.component_version(component_id) if doc else None
    if advertised:
        return Resolved(advertised, "manifest")
    return Resolved(fallback, "fallback") if fallback else None


def metadata_applies(policy: VersionPolicy, env_pin: str | None) -> bool:
    """Severity, note and min_kit_version describe the ADVERTISED version only."""
    return policy is VersionPolicy.MANIFEST and not env_pin
