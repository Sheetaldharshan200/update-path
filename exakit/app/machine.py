"""What is on THIS machine: the probes every read-only answer and every plan start from.

Phase A keeps the probes light: the install record plus a disk check for
the binaries and venvs that can vanish under the record. The lifecycles
(Phase B) and the runtime adapter (Phase C) replace the per-component
branches here with their own ``installed_version`` hooks.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

from exakit.domain.catalog import Addon
from exakit.domain.ids import CLIENT_IDS
from exakit.domain.manifest import Manifest
from exakit.domain.persona import (
    ADDON_AVAILABLE, ADDON_INSTALLED, ADDON_MISSING_MODULE, ADDON_SYSTEM, ADDON_UNAVAILABLE, MachineState,
)

from . import Context

_VERSION_IN_TEXT = re.compile(r"[0-9]+\.[0-9]+[0-9A-Za-z._+-]*")


def kit_root(ctx: Context) -> Path:
    """The kit copy: the installed one, or this checkout when running from source."""
    if (ctx.paths.kit / "exakit").is_dir():
        return ctx.paths.kit
    return Path(__file__).resolve().parents[2]


# --- datasets ------------------------------------------------------------------------


def all_datasets(ctx: Context) -> list[str]:
    """Bundled dataset ids in their declared order, from data/datasets/*/dataset.conf."""
    rows: list[tuple[int, str]] = []
    for conf in kit_root(ctx).glob("data/datasets/*/dataset.conf"):
        fields: dict[str, str] = {}
        try:
            for line in conf.read_text(encoding="utf-8").splitlines():
                if "=" in line and not line.startswith("#"):
                    key, value = line.split("=", 1)
                    fields[key.strip()] = value.strip()
        except OSError:
            continue
        if fields.get("id") and fields.get("label"):
            order = int(fields["order"]) if fields.get("order", "").isdigit() else 50
            rows.append((order, fields["id"]))
    return [ds for _, ds in sorted(rows)]


def loaded_datasets(manifest: Manifest) -> set[str]:
    """The datasets the record says are loaded (the database is asked in Phase B)."""
    loaded: set[str] = set()
    datasets = manifest.get("data.datasets") or {}
    if isinstance(datasets, dict):
        loaded.update(name for name, rec in datasets.items() if isinstance(rec, dict) and rec.get("loaded"))
    if manifest.get("data.loaded") is True:
        loaded.add("tpch")
    return loaded


# --- AI clients ---------------------------------------------------------------------


def client_states(ctx: Context) -> dict[str, str] | None:
    """id -> connected | pending | missing, from the client adapters' own detection; None when unavailable."""
    root = kit_root(ctx)
    if not (root / "mcp").is_dir():
        return None
    done = ctx.runner.run([sys.executable, "-m", "mcp", "discover-clients", "--runtime-root", str(ctx.paths.home)],
                          cwd=root, env={"PYTHONPATH": str(root)}, timeout=30)
    if not done.ok:
        return None
    try:
        doc = json.loads(done.out)
    except ValueError:
        return None
    states: dict[str, str] = {}
    for client in doc.get("clients", []):
        cid = client.get("id")
        if cid not in CLIENT_IDS:
            continue
        states[cid] = "connected" if client.get("configured") else "pending" if client.get("detected") else "missing"
    return states


# --- components -------------------------------------------------------------------------


def installed_version(ctx: Context, cid: str, manifest: Manifest | None) -> tuple[str | None, bool]:
    """(version, present). ``present`` False means provably absent from the disk."""
    if manifest is None:
        return None, False
    if cid == "exakit":
        return manifest.get("kit.version") or kit_bundled_version(ctx), True
    if cid in _RECORDED_VERSION_KEYS:
        version = manifest.get(_RECORDED_VERSION_KEYS[cid])
        return (version, True) if version else (None, False)
    if cid == "exapump":
        return _exapump_version(ctx, manifest)
    if cid == "pyexasol":
        return _pyexasol_version(ctx, manifest)
    if ctx.catalog.has_addon(cid):
        return addon_installed_version(ctx, ctx.catalog.addon(cid), manifest)
    return None, False


_RECORDED_VERSION_KEYS = {"personal": "runtime.version", "runtime": "runtime.version",
                          "mcp": "components.mcp_server.version", "skills": "components.skills.version"}


def _exapump_version(ctx: Context, manifest: Manifest) -> tuple[str | None, bool]:
    """The binary's own answer to --version, else the recorded one; absent when the file is gone."""
    path = manifest.get("components.exapump.path") or ctx.runner.which("exapump")
    if not path or not Path(path).exists():
        return None, False
    done = ctx.runner.run([str(path), "--version"], timeout=10)
    match = _VERSION_IN_TEXT.search(done.out.splitlines()[0] if done.out else "")
    return (match.group(0) if match else manifest.get("components.exapump.version")), True


def _pyexasol_version(ctx: Context, manifest: Manifest) -> tuple[str | None, bool]:
    """The module's own version from the kit's venv, else the recorded one; absent when the venv is gone."""
    python = manifest.get("components.pyexasol.python") or str(ctx.paths.home / "pyexasol-venv" / "bin" / "python")
    if not Path(python).exists():
        return None, False
    done = ctx.runner.run([python, "-c", "import pyexasol; print(pyexasol.__version__)"], timeout=20)
    text = done.out.strip().splitlines()[0] if done.ok and done.out.strip() else ""
    return (text if re.fullmatch(r"[A-Za-z0-9._+-]+", text) else manifest.get("components.pyexasol.version")), True


def addon_installed_version(ctx: Context, addon: Addon, manifest: Manifest) -> tuple[str | None, bool]:
    """The record says installed AND the add-on's lifecycle still finds it on disk."""
    if not manifest.get(f"components.{addon.manifest_key}.version"):
        return None, False
    from exakit.lifecycles import for_addon
    try:
        version = for_addon(ctx, addon).installed_version()
    except (ValueError, OSError):
        return None, False
    return (str(version), True) if version else (None, False)


def kit_bundled_version(ctx: Context) -> str | None:
    """The kit version the running copy's versions.json names, or None."""
    try:
        return json.loads((kit_root(ctx) / "versions.json").read_text(encoding="utf-8"))["kit"]["version"]
    except (OSError, ValueError, KeyError, TypeError):
        return None


def skills_local_version(ctx: Context) -> str | None:
    """The skill set in the kit copy: a skills/.version marker, else the kit's versions.json."""
    marker = kit_root(ctx) / "skills" / ".version"
    try:
        text = marker.read_text(encoding="utf-8").strip().splitlines()[0]
        if re.fullmatch(r"[A-Za-z0-9._+-]+", text):
            return text
    except (OSError, IndexError):
        pass
    try:
        return json.loads((kit_root(ctx) / "versions.json").read_text(encoding="utf-8"))["components"]["skills"]["version"]
    except (OSError, ValueError, KeyError, TypeError):
        return None


def skills_current(ctx: Context, manifest: Manifest | None) -> bool:
    """True when the placed skills match the kit's."""
    if manifest is None:
        return False
    have = manifest.get("components.skills.version")
    return bool(have) and have == (skills_local_version(ctx) or have)


# --- add-ons ----------------------------------------------------------------------------


def system_present(ctx: Context, addon: Addon) -> bool:
    """A copy the user installed themselves, as the add-on's lifecycle recognises it."""
    from exakit.lifecycles import for_addon
    try:
        return for_addon(ctx, addon).system_present()
    except (ValueError, OSError):
        return False


def applicable(ctx: Context, addon: Addon) -> tuple[bool, str]:
    """Can this add-on run here? The catalog's platforms first, then the lifecycle's own probe."""
    if not addon.supports(ctx.platform.platform_key):
        return False, f"no build is published for this platform ({ctx.platform.platform_key})"
    from exakit.lifecycles import for_addon
    try:
        return for_addon(ctx, addon).applicable()
    except ValueError as err:
        return False, str(err)


def addon_state(ctx: Context, addon: Addon, manifest: Manifest | None) -> tuple[str, str]:
    """(state, reason) of an add-on on this machine."""
    if manifest is not None and addon_installed_version(ctx, addon, manifest)[1]:
        return ADDON_INSTALLED, ""
    if system_present(ctx, addon):
        return ADDON_SYSTEM, ""
    ok, reason = applicable(ctx, addon)
    if not ok:
        return ADDON_UNAVAILABLE, reason
    if addon.directory is None:
        return ADDON_MISSING_MODULE, "the module is not part of this kit copy (exakit update)"
    return ADDON_AVAILABLE, ""


def addon_states(ctx: Context, manifest: Manifest | None) -> dict[str, tuple[str, str]]:
    """Every add-on's (state, reason)."""
    return {a.id: addon_state(ctx, a, manifest) for a in ctx.catalog.addons()}


# --- the probe ---------------------------------------------------------------------------


def probe(ctx: Context, manifest: Manifest | None, *, need: set[str] | None = None) -> MachineState:
    """Only the sections asked for are probed; the rest answer as empty."""
    need = need or {"datasets", "mcp_clients", "addons", "skills"}
    return MachineState(
        all_datasets=tuple(all_datasets(ctx)),
        loaded_datasets=frozenset(loaded_datasets(manifest)) if manifest and "datasets" in need else frozenset(),
        client_states=client_states(ctx) if "mcp_clients" in need else None,
        addon_states=addon_states(ctx, manifest) if "addons" in need else {},
        all_addons=tuple(ctx.catalog.addon_ids()),
        skills_current=skills_current(ctx, manifest) if "skills" in need else False,
    )
