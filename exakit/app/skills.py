"""AI skills: place the kit's skills where agents look, retire what left the kit, keep the allowlist.

The registry is the filesystem: ``<kit>/skills/<id>/SKILL.md``. A skill with
an ``addon:`` line belongs to that add-on and is placed only while the add-on
is installed. Placing replaces the destination directory; retiring removes
only names the previous record listed that the kit no longer ships.
"""

from __future__ import annotations

import json
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from exakit.adapters.fs.atomic import atomic_write_text
from exakit.domain.errors import Failed
from exakit.domain.manifest import Manifest
from exakit.domain.result import Result

from . import Context
from .machine import addon_installed_version, kit_root, skills_local_version

READONLY_COMMANDS = ("status", "info", "version", "mcp-doctor", "logs", "catalog", "preflight", "guide", "mcp-status", "help")
PREFIXES = ("exakit", "~/.local/bin/exakit", "$HOME/.local/bin/exakit")


@dataclass(frozen=True, slots=True)
class Skill:
    id: str
    name: str
    description: str
    addon: str | None
    path: Path


def frontmatter(path: Path) -> dict[str, str]:
    """``key: value`` lines between the first two ``---`` lines; first match wins."""
    fields: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return fields
    if not lines or lines[0].rstrip("\r") != "---":
        return fields
    for line in lines[1:]:
        if line.rstrip("\r") == "---":
            break
        if ": " in line and not line.startswith(" "):
            key, value = line.split(": ", 1)
            fields.setdefault(key, value.rstrip("\r"))
    return fields


def summary_of(description: str) -> str:
    """The one-line summary of a skill, from its description without the triggers."""
    text = description.split("Triggers")[0].split('". ')[0].rstrip(" —-")
    if len(text) <= 64:
        return text
    out = ""
    for word in text.split():
        if len(out) + len(word) + 1 > 61:
            break
        out = f"{out} {word}".strip()
    return out.rstrip("—-,:") + "..."


def shipped(ctx: Context) -> list[Skill]:
    """Every valid skill in the kit copy, in name order; invalid ones are skipped."""
    root = kit_root(ctx) / "skills"
    skills: list[Skill] = []
    for directory in sorted(p for p in root.glob("*/") if p.is_dir() and not p.name.startswith(".")):
        skill_md = directory / "SKILL.md"
        if not skill_md.is_file():
            continue
        fields = frontmatter(skill_md)
        if not fields.get("name"):
            continue
        skills.append(Skill(directory.name, fields["name"], fields.get("description", ""), fields.get("addon") or None, directory))
    return skills


def roots(ctx: Context) -> list[Path]:
    """Where skills are placed: EXAKIT_SKILL_ROOTS, else the Claude and open-standard folders."""
    raw = ctx.env.get("EXAKIT_SKILL_ROOTS", "")
    home = Path(ctx.env.get("HOME") or Path.home())
    if raw.strip():
        return [Path(p).expanduser() for p in raw.split() if p]
    return [home / ".claude" / "skills", home / ".agents" / "skills"]


def state_of(ctx: Context, skill_id: str) -> str:
    """installed (in every root) | partial | available."""
    present = sum(1 for r in roots(ctx) if (r / skill_id / "SKILL.md").is_file())
    return "installed" if present == len(roots(ctx)) else "partial" if present else "available"


def wanted(ctx: Context, skill: Skill, manifest: Manifest | None) -> bool:
    """True when the skill belongs on this machine (its add-on is installed, or it has none)."""
    if not skill.addon:
        return True
    if manifest is None or not ctx.catalog.has_addon(skill.addon):
        return False
    return addon_installed_version(ctx, ctx.catalog.addon(skill.addon), manifest)[1]


def place(ctx: Context, skill: Skill) -> None:
    """Copy a skill into every root."""
    for root in roots(ctx):
        dest = root / skill.id
        shutil.rmtree(dest, ignore_errors=True)
        shutil.copytree(skill.path, dest)


def unplace(ctx: Context, skill_id: str) -> None:
    """Remove a skill from every root."""
    for root in roots(ctx):
        shutil.rmtree(root / skill_id, ignore_errors=True)


def record(ctx: Context) -> None:
    """``components.skills.installed`` from what is on disk, and the local skill-set version."""
    if not ctx.manifest_store.exists():
        return
    placed = [s.id for s in shipped(ctx) if state_of(ctx, s.id) != "available"]
    doc = ctx.versions.current()
    version = skills_local_version(ctx) or (doc.component_version("skills") if doc else None) or "unknown"

    def change(m: Manifest) -> None:
        m.set("components.skills.version", version)
        m.set("components.skills.installed", placed)
    ctx.manifest_store.update(change)


def install(ctx: Context) -> int:
    """Place every wanted skill, retire what left the kit, record, keep the allowlist. Returns the count placed."""
    root = kit_root(ctx) / "skills"
    if not root.is_dir():
        raise Failed("No skills/ directory in this kit build yet - nothing to install.")
    manifest = ctx.manifest_or_none()
    previous = manifest.get("components.skills.installed") if manifest else None
    previous_names = [n for n in previous if isinstance(n, str)] if isinstance(previous, list) else []
    placed = 0
    for skill in shipped(ctx):
        if not wanted(ctx, skill, manifest):
            continue
        place(ctx, skill)
        ctx.log.line("OK", f"Installed skill: {skill.id}")
        placed += 1
    if placed == 0:
        raise Failed(f"No SKILL.md files found under {root} - nothing to install.")
    ctx.ui.ok(f"Installed {placed} AI skill{'s' if placed != 1 else ''} for Claude Code (~/.claude/skills) and open-standard agents (~/.agents/skills)")
    still_shipped = {s.id for s in shipped(ctx)}
    retired = 0
    for name in previous_names:
        if name not in still_shipped:
            unplace(ctx, name)
            ctx.log.line("OK", f"Retired skill: {name} (no longer in the kit's skill set)")
            retired += 1
    if retired:
        ctx.ui.ok(f"Retired {retired} skill{'s' if retired != 1 else ''} the new set no longer carries")
    record(ctx)
    report_allowlist(ctx, apply_allowlist(ctx))
    ctx.ui.info("Restart or reload your AI client to pick them up.")
    return placed


def install_for_addon(ctx: Context, addon_id: str) -> int:
    """Place the skills of one add-on; the count placed."""
    count = 0
    for skill in shipped(ctx):
        if skill.addon == addon_id:
            place(ctx, skill)
            ctx.log.line("OK", f"Installed skill: {skill.id} (with {addon_id})")
            count += 1
    if count:
        record(ctx)
    return count


def remove_for_addon(ctx: Context, addon_id: str) -> int:
    """Remove the skills of one add-on; the count removed."""
    count = 0
    for skill in shipped(ctx):
        if skill.addon == addon_id:
            unplace(ctx, skill.id)
            count += 1
    if count:
        record(ctx)
    return count


# --- the Claude Code read-only allowlist ---------------------------------------


def allowlist_entries() -> tuple[list[str], list[str]]:
    """(allow, keep gated): the exakit commands the Claude settings allow without a prompt."""
    allow = []
    for prefix in PREFIXES:
        allow += [f"Bash({prefix} {cmd}:*)" for cmd in READONLY_COMMANDS]
        allow += [f"Bash({prefix} skills)", f"Bash({prefix} skills --json)"]
    allow.append("mcp__exasol")
    deny = [f"Bash({prefix} uninstall:*)" for prefix in PREFIXES]
    return allow, deny


def settings_path(ctx: Context) -> Path:
    """Claude Code's settings file for this user."""
    return Path(ctx.env.get("HOME") or Path.home()) / ".claude" / "settings.json"


def apply_allowlist(ctx: Context) -> str:
    """``ADDED n`` or ``SKIP <reason>``; never removes or reorders a user's entries."""
    path = settings_path(ctx)
    doc: Any = {}
    if path.exists():
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return "SKIP unreadable"
    if not isinstance(doc, dict):
        return "SKIP not-an-object"
    permissions = doc.setdefault("permissions", {})
    if not isinstance(permissions, dict):
        return "SKIP permissions-not-an-object"
    added = 0
    for key, wanted_entries in zip(("allow", "deny"), allowlist_entries(), strict=False):
        existing = permissions.setdefault(key, [])
        if not isinstance(existing, list):
            continue
        for entry in wanted_entries:
            if entry not in existing:
                existing.append(entry)
                added += 1
    if added:
        atomic_write_text(path, json.dumps(doc, indent=2) + "\n", mode=0o600)
    return f"ADDED {added}"


def remove_allowlist(ctx: Context) -> str:
    """Take the kit's entries out of the allowlist; the outcome word."""
    path = settings_path(ctx)
    if not path.exists():
        return "REMOVED 0"
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return "SKIP unreadable"
    permissions = doc.get("permissions") if isinstance(doc, dict) else None
    if not isinstance(permissions, dict):
        return "REMOVED 0"
    removed = 0
    for key, ours in zip(("allow", "deny"), allowlist_entries(), strict=False):
        existing = permissions.get(key)
        if isinstance(existing, list):
            kept = [e for e in existing if e not in ours]
            removed += len(existing) - len(kept)
            permissions[key] = kept
    if removed:
        atomic_write_text(path, json.dumps(doc, indent=2) + "\n", mode=0o600)
    return f"REMOVED {removed}"


def report_allowlist(ctx: Context, outcome: str) -> None:
    """Say what happened to the allowlist."""
    if outcome == "ADDED 0":
        ctx.log.line("INFO", "Read-only command allowlist already present in ~/.claude/settings.json.")
    elif outcome.startswith("ADDED"):
        ctx.ui.ok("Read-only exakit commands allowlisted in ~/.claude/settings.json (status, info, version, mcp-doctor, "
                  "logs, catalog, preflight, guide, mcp-status, skills; uninstall stays gated).")
    elif outcome.startswith("SKIP"):
        ctx.ui.warn(f"~/.claude/settings.json could not be merged safely ({outcome[5:]}) - the allowlist in "
                    "skills/reducing-agent-prompts.md shows what to add by hand.")


# --- listing --------------------------------------------------------------------


def gating_addon(ctx: Context, skill: Skill, manifest: Manifest | None) -> str | None:
    """The add-on a skill waits for, or None."""
    if skill.addon and not wanted(ctx, skill, manifest):
        return skill.addon
    return None


def list_skills(ctx: Context) -> Result:
    """``exakit skills``: every skill with its state and the next command."""
    if not (kit_root(ctx) / "skills").is_dir():
        raise Failed("No skills/ directory in this kit build - nothing to list.")
    manifest = ctx.manifest_or_none()
    have = manifest.get("components.skills.version") if manifest else None
    doc = ctx.versions.current()
    want = doc.component_version("skills") if doc else None
    rows = []
    missing = 0
    for skill in shipped(ctx):
        state = state_of(ctx, skill.id)
        gate = gating_addon(ctx, skill, manifest)
        row: dict[str, Any] = {"name": skill.id, "state": state, "summary": summary_of(skill.description)}
        if state == "available" and gate:
            row = {"name": skill.id, "state": "needs-addon", "addon": gate, "remedy": f"exakit marketplace {gate}", "summary": row["summary"]}
        elif state != "installed":
            missing += 1
        rows.append(row)
    if have and want and have != want:
        status, nxt = "update_pending", "exakit update"
    elif missing:
        status, nxt = "missing", "exakit skills-install"
    else:
        status, nxt = "current", None
    data = {"skills": rows, "installed_version": have, "advertised_version": want, "status": status, "next": nxt}
    if not ctx.json:
        _render(ctx, rows, have, want, missing)
    return Result(True, status, remedy=nxt, data=data, raw=True)


def _render(ctx: Context, rows: list[dict[str, Any]], have: str | None, want: str | None, missing: int) -> None:
    ctx.ui.text("")
    if not rows:
        ctx.ui.panel("Exasol skills", ["No SKILL.md files found in this kit copy."])
        ctx.ui.text("")
        return
    lines = []
    for row in rows:
        state = f"with {row['addon']}" if row["state"] == "needs-addon" else row["state"]
        lines.append(f"{row['name']:<26} {state:<22} {row['summary']}")
    lines.append("")
    if have and want and have != want:
        lines += [f"Installed skill set {have}; the kit advertises {want}.", "Fetch and install them:  exakit update"]
    elif missing:
        lines.append("Install or refresh every skill:  exakit skills-install")
    lines.append("Agents load a skill only when its triggers match your request.")
    ctx.ui.panel("Exasol skills", lines)
    ctx.ui.text("")


def skills_install_command(ctx: Context) -> Result:
    """``exakit skills-install``: place the skills and merge the allowlist."""
    install(ctx)
    return Result(True, "ok")
