"""The help documents: loading help/*.json, the command rows every screen and search share, and the JSON payloads."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


def load_docs(help_dir: Path) -> dict[str, dict[str, Any]]:
    """Every help document under ``help_dir``, keyed by id; an unreadable file is skipped."""
    docs: dict[str, dict[str, Any]] = {}
    for path in sorted(help_dir.glob("*.json")) if help_dir.is_dir() else []:
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(doc, dict):
            docs[path.stem] = doc
    return docs


def commands_of(doc: dict[str, Any], include_hidden: bool = False) -> list[dict[str, Any]]:
    """The command entries of a document; hidden ones only on request."""
    entries = doc.get("commands", []) or []
    return entries if include_hidden else [e for e in entries if not e.get("hidden")]


def with_hidden_marked(doc: dict[str, Any]) -> dict[str, Any]:
    """A copy of the document with its hidden commands marked, for the JSON reader."""
    copy = dict(doc)
    copy["commands"] = [dict(e, hidden=bool(e.get("hidden"))) for e in commands_of(doc, include_hidden=True)]
    return copy


def catalog_rows(docs: dict[str, dict[str, Any]], include_hidden: bool = False) -> list[dict[str, Any]]:
    """One row per command across every document: the catalog screen and the search."""
    rows: list[dict[str, Any]] = []
    for key in sorted(docs):
        doc = docs[key]
        tool = "exakit" if key == "exakit" else key
        for entry in commands_of(doc, include_hidden=include_hidden):
            command = entry.get("command", "")
            parts = command.split()
            row_tool, row_command = tool, command
            if parts and parts[0] in ("exakit", "exapump", "exasol") and key != parts[0]:
                row_tool, row_command = parts[0], " ".join(parts[1:])
            rows.append({"tool": row_tool, "command": row_command, "options": entry.get("options", ""),
                         "description": entry.get("summary") or entry.get("description", ""),
                         "source": key, "hidden": bool(entry.get("hidden"))})
    at: dict[tuple[str, str], int] = {}
    unique: list[dict[str, Any]] = []
    for row in rows:
        key = (row["tool"], row["command"])
        if key not in at:
            at[key] = len(unique)
            unique.append(row)
            continue
        kept = unique[at[key]]
        if row["source"] == row["tool"] and kept["source"] != kept["tool"]:
            unique[at[key]] = row
    return unique


def _matches(row: dict[str, Any], needle: str) -> bool:
    return needle in " ".join([row["tool"], row["command"], row["options"], row["description"]]).lower()


def json_payload(docs: dict[str, dict[str, Any]], which: str) -> dict[str, Any]:
    """What ``exakit help --json`` prints for ``which``: everything, one document, or a search."""
    rows = catalog_rows(docs, include_hidden=True)
    for row in rows:
        row["invocation"] = f"{row['tool']} {row['command']}".strip()
    if which in ("", "all"):
        return {"schema_version": 1, "search": None, "count": len(rows), "commands": rows,
                "documents": {k: with_hidden_marked(d) for k, d in docs.items()}}
    if which in docs:
        return with_hidden_marked(docs[which])
    hit = [r for r in rows if _matches(r, which.lower())]
    return {"schema_version": 1, "search": which, "count": len(hit), "commands": hit}
