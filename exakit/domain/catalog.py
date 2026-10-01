"""The catalog: what the kit is made of, as data.

Three kinds of document, all under ``catalog/`` in the kit copy:

    components/<id>.json      the fixed components every install has
    addons/<id>/addon.json    optional add-ons (the marketplace)
    personas/<id>.json        named bundles of the install's optional choices

Plus a user's own personas under ``$EXAKIT_HOME/personas/``, which shadow the
shipped ones by id. The directory is the registry: nothing in code names a
component, an add-on or a persona. Validation returns a list of problems so a
shipped file that is wrong fails CI, and a user's file that is wrong is
skipped with one warning, never fatal.
"""

from __future__ import annotations

import json
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .errors import BadInput
from .catalog_rules import (ADDON_KINDS, COMPONENT_KINDS, Problems, _check_choice, _check_clients, _check_id, _check_id_list,
                            _check_platforms, _check_schema, _check_source, _is_str)
from .settings import KitSettings, load_settings

@dataclass(frozen=True, slots=True)
class Component:
    id: str
    title: str
    kind: str
    source: dict[str, Any]
    install_order: int
    step_id: str | None
    fallback_version: str | None
    requires: tuple[str, ...]
    help: str | None
    manifest_key: str
    platforms: tuple[str, ...] = ()      # empty = every platform the kit runs on

    @classmethod
    def from_doc(cls, doc: dict[str, Any]) -> Component:
        """A Component from a validated document."""
        return cls(
            id=doc["id"], title=doc["title"], kind=doc["kind"], source=dict(doc.get("source") or {"type": "kit"}),
            install_order=int(doc.get("install_order", 100)), step_id=doc.get("step_id"),
            fallback_version=doc.get("fallback_version"), requires=tuple(doc.get("requires") or ()),
            help=doc.get("help"), manifest_key=doc.get("manifest_key") or doc["id"].replace("-", "_"),
            platforms=tuple(doc.get("platforms") or ()),
        )


def validate_component(doc: Any, *, expected_id: str | None = None) -> Problems:
    """Every problem with a component document, empty when it is valid; ``expected_id`` must match the file name."""
    problems: Problems = []
    if not _check_schema(doc, problems):
        return problems
    _check_id(doc, expected_id, problems)
    if not _is_str(doc.get("title"), max_len=60):
        problems.append("title must be a non-empty ASCII string of at most 60 characters")
    if doc.get("kind") not in COMPONENT_KINDS:
        problems.append(f"kind must be one of {', '.join(COMPONENT_KINDS)}")
    if "source" in doc:
        _check_source(doc["source"], problems)
    if not isinstance(doc.get("install_order", 100), int):
        problems.append("install_order must be an integer")
    for key in ("step_id", "fallback_version", "help", "manifest_key"):
        if key in doc and not _is_str(doc[key]):
            problems.append(f"{key} must be a non-empty string")
    if "requires" in doc:
        _check_id_list(doc, "requires", problems)
    _check_platforms(doc, problems)
    return problems


# --- add-ons ------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class Addon:
    id: str
    title: str
    kind: str
    source: dict[str, Any]
    platforms: tuple[str, ...]          # empty = every platform
    requires: tuple[str, ...]
    provides: tuple[str, ...]
    service: dict[str, Any] | None
    launcher: str | None
    skill: str | None
    help: str | None
    fallback_version: str | None
    manifest_key: str
    config: dict[str, Any] = field(default_factory=dict)      # the add-on's own knobs (a profile name, a schema, a service user)
    directory: Path | None = field(default=None, compare=False)

    @classmethod
    def from_doc(cls, doc: dict[str, Any], directory: Path | None = None) -> Addon:
        """An Addon from a validated document; ``directory`` is where its files live."""
        return cls(
            id=doc["id"], title=doc["title"], kind=doc["kind"], source=dict(doc["source"]),
            platforms=tuple(doc.get("platforms") or ()), requires=tuple(doc.get("requires") or ()),
            provides=tuple(doc.get("provides") or ()), service=doc.get("service"),
            launcher=doc.get("launcher"), skill=doc.get("skill"), help=doc.get("help"),
            fallback_version=doc.get("fallback_version"),
            manifest_key=doc.get("manifest_key") or doc["id"].replace("-", "_"), config=dict(doc.get("config") or {}),
            directory=directory,
        )

    def supports(self, platform_key: str) -> bool:
        """True when the add-on runs on that platform key; an empty list means everywhere."""
        return not self.platforms or platform_key in self.platforms


def validate_addon(doc: Any, *, expected_id: str | None = None) -> Problems:
    """Every problem with an add-on document, empty when it is valid."""
    problems: Problems = []
    if not _check_schema(doc, problems):
        return problems
    _check_id(doc, expected_id, problems)
    if not _is_str(doc.get("title"), max_len=60):
        problems.append("title must be a non-empty ASCII string of at most 60 characters")
    if doc.get("kind") not in ADDON_KINDS:
        problems.append(f"kind must be one of {', '.join(ADDON_KINDS)}")
    _check_source(doc.get("source"), problems)
    _check_platforms(doc, problems)
    for key in ("requires", "provides"):
        if key in doc:
            _check_id_list(doc, key, problems)
    service = doc.get("service")
    if service is not None and (not isinstance(service, dict) or not isinstance(service.get("port", 0), int)):
        problems.append("service must be an object with an integer port")
    for key in ("launcher", "skill", "help", "fallback_version", "manifest_key"):
        if key in doc and not _is_str(doc[key]):
            problems.append(f"{key} must be a non-empty string")
    return problems


# --- personas -----------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class Persona:
    id: str
    title: str
    summary: str
    datasets: str | tuple[str, ...]      # "all" | "none" | ids
    mcp_clients: str | tuple[str, ...]   # "all" | "skip" | client ids
    addons: str | tuple[str, ...]        # "all" | "none" | ids
    skills: str
    source: str                          # kit | user
    path: Path | None = field(default=None, compare=False)

    @classmethod
    def from_doc(cls, doc: dict[str, Any], *, source: str, path: Path | None = None) -> Persona:
        """A Persona from a validated document; ``source`` is kit or user."""
        def norm(value: Any) -> str | tuple[str, ...]:
            return value if isinstance(value, str) else tuple(value)
        return cls(
            id=doc["id"], title=doc["title"], summary=doc["summary"], datasets=norm(doc["datasets"]),
            mcp_clients=norm(doc["mcp_clients"]), addons=norm(doc["addons"]), skills=doc["skills"],
            source=source, path=path,
        )

    def to_dict(self) -> dict[str, Any]:
        """The persona as the document it was read from: what ``persona show --json`` prints."""
        def raw(value: str | tuple[str, ...]) -> Any:
            return value if isinstance(value, str) else list(value)
        return {
            "schema_version": 1, "id": self.id, "title": self.title, "summary": self.summary,
            "datasets": raw(self.datasets), "mcp_clients": raw(self.mcp_clients),
            "addons": raw(self.addons), "skills": self.skills,
        }


def validate_persona(
    doc: Any,
    *,
    expected_id: str | None = None,
    known_datasets: Iterable[str] | None = None,
    known_addons: Iterable[str] | None = None,
) -> Problems:
    """Schema 1. Cross-checks against the known ids only when they are given."""
    problems: Problems = []
    if not _check_schema(doc, problems):
        return problems
    _check_id(doc, expected_id, problems)
    if not _is_str(doc.get("title"), max_len=40):
        problems.append("title must be a non-empty ASCII string of at most 40 characters")
    if not _is_str(doc.get("summary"), max_len=120):
        problems.append("summary must be a non-empty ASCII string of at most 120 characters")
    _check_choice(doc, "datasets", ("all", "none"), known_datasets, "dataset", problems)
    _check_clients(doc, problems)
    _check_choice(doc, "addons", ("all", "none"), known_addons, "add-on", problems)
    if doc.get("skills") != "all":
        problems.append('skills must be "all" in schema 1')
    return problems


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


class Catalog:
    """Everything the kit knows about, loaded once per command."""

    def __init__(self, components: dict[str, Component], addons: dict[str, Addon], personas: dict[str, Persona], kit: KitSettings) -> None:
        self._components = components
        self._addons = addons
        self._personas = personas
        self.kit = kit

    @classmethod
    def load(cls, kit_root: Path, user_root: Path | None, *, warn: Callable[[str], None]) -> Catalog:
        """Read the kit's settings, catalog and the user's personas. A bad catalog file is skipped with one warning."""
        kit = load_settings(kit_root / "catalog" / "kit.json")
        components = _load_components(kit_root / "catalog" / "components", warn)
        addons = _load_addons(kit_root / "catalog" / "addons", warn)
        personas: dict[str, Persona] = {}
        dirs = [(user_root, "user")] if user_root else []
        dirs.append((kit_root / "catalog" / "personas", "kit"))
        for directory, source in dirs:
            for persona in _load_personas(directory, source, set(addons), warn):
                personas.setdefault(persona.id, persona)   # user first, so the user's copy wins
        return cls(components, addons, dict(sorted(personas.items())), kit)

    # --- lookups; unknown ids are BadInput naming the known ones ----------------------

    def component(self, cid: str) -> Component:
        """The component with that id; an unknown id is BadInput naming the known ones."""
        return self._lookup(self._components, cid, "component")

    def addon(self, aid: str) -> Addon:
        """The add-on with that id; an unknown id is BadInput naming the known ones."""
        return self._lookup(self._addons, aid, "marketplace add-on")

    def persona(self, pid: str) -> Persona:
        """The persona with that id; an unknown id is BadInput naming the known ones."""
        return self._lookup(self._personas, pid, "persona")

    def has_addon(self, aid: str) -> bool:
        """True when an add-on with that id is registered."""
        return aid in self._addons

    def component_ids(self) -> list[str]:
        """Component ids in install order."""
        return [c.id for c in sorted(self._components.values(), key=lambda c: (c.install_order, c.id))]

    def addon_ids(self) -> list[str]:
        """Add-on ids, sorted."""
        return sorted(self._addons)

    def persona_ids(self) -> list[str]:
        """Persona ids, sorted; a user's file shadows the kit's of the same id."""
        return list(self._personas)

    def personas(self) -> list[Persona]:
        """Every persona, in id order."""
        return list(self._personas.values())

    def addons(self) -> list[Addon]:
        """Every add-on, in id order."""
        return [self._addons[a] for a in self.addon_ids()]

    @staticmethod
    def _lookup(table: dict[str, Any], key: str, noun: str) -> Any:
        if key in table:
            return table[key]
        known = " ".join(sorted(table)) or "none"
        raise BadInput(f"Unknown {noun} '{key}' (known: {known}).")


def _load_components(directory: Path, warn: Callable[[str], None]) -> dict[str, Component]:
    result: dict[str, Component] = {}
    for path in sorted(directory.glob("*.json")) if directory.is_dir() else []:
        doc = _read_json(path)
        problems = validate_component(doc, expected_id=path.stem)
        if problems:
            warn(f"Ignoring component file {path}: {problems[0]}")
            continue
        result[path.stem] = Component.from_doc(doc)
    return result


def _load_addons(directory: Path, warn: Callable[[str], None]) -> dict[str, Addon]:
    result: dict[str, Addon] = {}
    for path in sorted(directory.glob("*/addon.json")) if directory.is_dir() else []:
        doc = _read_json(path)
        problems = validate_addon(doc, expected_id=path.parent.name)
        if problems:
            warn(f"Ignoring add-on file {path}: {problems[0]}")
            continue
        result[path.parent.name] = Addon.from_doc(doc, directory=path.parent)
    return result


def _load_personas(directory: Path, source: str, known_addons: set[str], warn: Callable[[str], None]) -> list[Persona]:
    result: list[Persona] = []
    for path in sorted(directory.glob("*.json")) if directory.is_dir() else []:
        doc = _read_json(path)
        problems = validate_persona(doc, expected_id=path.stem, known_addons=known_addons or None)
        if problems:
            warn(f"Ignoring persona file {path}: {problems[0]}")
            continue
        result.append(Persona.from_doc(doc, source=source, path=path))
    return result
