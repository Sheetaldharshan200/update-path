"""A folder of files into one schema: scan, decide per file (load, done, resume, clash), load, receipt, report."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from exakit.adapters.exapump import Exapump, LISTING_SQL, failure_reason, table_listing
from exakit.domain.errors import BadInput, Failed
from exakit.domain.result import Result

from . import Context
from .data_files import (
    COMPRESSED, Receipts, _log_tail, _record_last_load, _sha256, ensure_schema_for, file_kind, inspect_csv, load_json,
    table_name_from_path, upload_with_recovery,
)
from .runtime_ops import exapump, profile_name


# --- a folder ------------------------------------------------------------------------------------


@dataclass(slots=True)
class ScanEntry:
    action: str        # load | skip
    kind: str          # csv | parquet | json | unsupported | empty | header-only | extension | duplicate-table | duplicate-content
    table: str         # target table, or the first file's name for duplicates
    path: Path


def scan_folder(folder: Path) -> list[ScanEntry]:
    """What the folder holds, file by file, with the decision for each."""
    entries: list[ScanEntry] = []
    seen_tables: dict[str, Path] = {}
    seen_sizes: dict[int, list[tuple[Path, str]]] = {}
    for path in sorted(p for p in folder.iterdir() if p.is_file() and not p.name.startswith(".")):
        size = path.stat().st_size
        if not size:
            entries.append(ScanEntry("skip", "empty", "", path))
            continue
        kind = file_kind(path)
        lower = path.name.lower()
        if kind == "csv" and (lower.endswith((".txt", ".tsv")) or any(lower.endswith(".txt" + c) for c in COMPRESSED)):
            if (lower.endswith(".txt") and _looks_tabular(path)) or lower.endswith(".tsv"):
                entries.append(ScanEntry("skip", "extension", "", path))
            else:
                entries.append(ScanEntry("skip", "unsupported", "", path))
            continue
        if kind == "unknown":
            entries.append(ScanEntry("skip", "unsupported", "", path))
            continue
        if kind == "csv" and inspect_csv(path) is None:
            entries.append(ScanEntry("skip", "header-only", "", path))
            continue
        digest = None
        for other, other_digest in seen_sizes.get(size, []):
            digest = digest or _sha256(path)
            if other_digest == digest:
                entries.append(ScanEntry("skip", "duplicate-content", other.name, path))
                break
        else:
            table = table_name_from_path(path)
            if table in seen_tables:
                entries.append(ScanEntry("skip", "duplicate-table", seen_tables[table].name, path))
            else:
                seen_tables[table] = path
                seen_sizes.setdefault(size, []).append((path, digest or _sha256(path)))
                entries.append(ScanEntry("load", kind, table, path))
    return entries


def _looks_tabular(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            first, second = handle.readline(), handle.readline()
    except OSError:
        return False
    return any(sep in first for sep in (b",", b";", b"\t")) and bool(second.strip())


def load_folder(ctx: Context, folder: Path) -> Result:
    """Load a folder's files, skipping what already landed."""
    pump = exapump(ctx)
    if pump is None:
        raise Failed("exapump (the data-loading CLI) is not installed", remedy="exakit update")
    entries = scan_folder(folder)
    loadable = [e for e in entries if e.action == "load"]
    if not loadable:
        _refuse_empty_folder(folder, entries)
    schema = _choose_schema(ctx)
    if schema is None:
        return Result(True, "cancelled")
    _print_plan(ctx, entries)
    ensure_schema_for(ctx, pump, schema)
    tables = table_listing(pump.sql(profile_name(ctx), LISTING_SQL))
    receipts = Receipts.load(ctx.paths.cache / "load-receipts.tsv")
    inflight = ctx.paths.cache / "load-inflight"
    decisions = {e.path: _decide(e, schema, tables, receipts, inflight) for e in loadable}
    clashes = [e for e in loadable if decisions[e.path][0] == "clash"]
    on_existing = _clash_answer(ctx, schema, clashes, decisions)
    outcomes = [_load_entry(ctx, pump, entry, schema, decisions[entry.path], on_existing, receipts, inflight) for entry in loadable]
    after = table_listing(pump.sql(profile_name(ctx), LISTING_SQL)) or {}
    settled = _settle(outcomes, schema, after, receipts)
    _print_outcomes(ctx, schema, settled)
    loaded_count = sum(1 for s in settled if s[0] == "ok")
    _record_last_load(ctx, "local_folder", schema, str(folder), files=loaded_count)
    return _summarise(ctx, schema, settled)


def _refuse_empty_folder(folder: Path, entries: list[ScanEntry]) -> None:
    renames = [e for e in entries if e.kind == "extension"]
    if renames:
        raise Failed(f"{len(renames)} files in {folder} are tabular but named .txt/.tsv - exapump reads .csv and .parquet only. "
                     "Rename them to .csv to load them.")
    raise Failed(f"No CSV, Parquet or JSON files in {folder}.")


def _choose_schema(ctx: Context) -> str | None:
    """EXAKIT_SCHEMA, else STARTER_KIT; a terminal may change it. None when the user went back."""
    schema = (ctx.env.get("EXAKIT_SCHEMA") or ctx.catalog.kit.data_schema).upper()
    if not ctx.ui.interactive:
        return schema
    answer = ctx.ui.prompt("Target schema (back to return)", schema)
    if answer.lower() in ("b", "back"):
        return None
    if not re.fullmatch(r"[A-Za-z0-9_]+", answer):
        raise BadInput(f"'{answer}' is not a schema name (letters, digits and underscores).")
    return answer.upper()


Outcome = tuple[str, ScanEntry, str, str, str]   # mark, entry, table text, rows text, reason


def _load_entry(ctx: Context, pump: Exapump, entry: ScanEntry, schema: str, decision: tuple[str, str], on_existing: str,
                receipts: Receipts, inflight: Path) -> Outcome:
    """One file: skip, reset-then-load, or load; a failure leaves no half-table behind."""
    verdict, rows = decision
    target = f"{schema}.{entry.table}"
    if verdict == "done":
        return ("skip", entry, entry.table, f"{rows} rows", "already loaded from this file - left as it is")
    if verdict == "clash" and on_existing == "skip":
        return ("skip", entry, entry.table, "", "not loaded: the table already holds rows this kit did not put there")
    if verdict == "resume" or (verdict == "clash" and on_existing == "replace"):
        pump.sql(profile_name(ctx), f"DROP TABLE IF EXISTS {target}")
        receipts.forget(target)
        ctx.log.line("RESET", target)
    inflight.parent.mkdir(parents=True, exist_ok=True)
    inflight.write_text(target)
    try:
        landed = _land(ctx, pump, entry, target)
    except Failed as err:
        if verdict != "clash" and rows == "absent":
            after = table_listing(pump.sql(profile_name(ctx), LISTING_SQL)) or {}
            if after.get(target, 0) == 0:
                pump.sql(profile_name(ctx), f"DROP TABLE IF EXISTS {target}")
        inflight.unlink(missing_ok=True)
        return ("fail", entry, entry.table, "not loaded", err.message)
    inflight.unlink(missing_ok=True)
    return ("ok", entry, ",".join(t.rpartition(".")[2] for t in landed), "@ROWS@", "")


def _land(ctx: Context, pump: Exapump, entry: ScanEntry, target: str) -> list[str]:
    if entry.kind == "json":
        return load_json(ctx, pump, entry.path, target)
    info = inspect_csv(entry.path) if entry.kind == "csv" else None
    if not upload_with_recovery(ctx, pump, entry.path, target, delimiter=info.delimiter if info else None):
        raise Failed(failure_reason(_log_tail(ctx), delimiter_name=info.delimiter_name if info else "comma"))
    return [target]


def _settle(outcomes: list[Outcome], schema: str, after: dict[str, int], receipts: Receipts) -> list[Outcome]:
    """Fill in the row counts of what landed and write the receipts."""
    settled: list[Outcome] = []
    for mark, entry, table_text, placeholder, reason in outcomes:
        rows_text = placeholder
        if placeholder == "@ROWS@":
            total = 0
            for name in table_text.split(","):
                count = after.get(f"{schema}.{name}", 0)
                receipts.record(f"{schema}.{name}", entry.path, count)
                total += count
            rows_text = f"{total} rows"
        settled.append((mark, entry, table_text, rows_text, reason))
    return settled


def _summarise(ctx: Context, schema: str, settled: list[Outcome]) -> Result:
    loaded_count = sum(1 for s in settled if s[0] == "ok")
    skipped = sum(1 for s in settled if s[0] == "skip")
    failed = sum(1 for s in settled if s[0] == "fail")
    summary = f"{schema}: {loaded_count} file{'s' if loaded_count != 1 else ''} loaded"
    if skipped:
        summary += f", {skipped} already there and left alone"
    if failed:
        summary += f", {failed} not loaded"
        ctx.ui.warn(summary + " (each file's reason is against it above; full detail: exakit logs setup).")
        return Result(True, "partial", exit_code=1, data={"loaded": loaded_count, "failed": failed})
    if not loaded_count and skipped:
        ctx.ui.ok(f"{schema} already holds every file in that folder - nothing to load.")
    else:
        ctx.ui.ok(summary)
    return Result(True, "loaded", data={"loaded": loaded_count, "failed": 0})


def _decide(entry: ScanEntry, schema: str, tables: dict[str, int] | None, receipts: Receipts, inflight: Path) -> tuple[str, str]:
    """load | done | resume | clash, plus the rows the table holds now as text."""
    target = f"{schema}.{entry.table}"
    if tables is None:
        return "load", "unknown"
    rows = tables.get(target)
    if rows is None or rows == 0:
        return "load", "absent" if rows is None else "0"
    recorded = receipts.match(target, entry.path)
    if recorded is not None and recorded == rows:
        return "done", str(rows)
    try:
        if inflight.is_file() and inflight.read_text().strip() == target:
            return "resume", str(rows)
    except OSError:
        pass
    return "clash", str(rows)


def _clash_answer(ctx: Context, schema: str, clashes: list[ScanEntry], decisions) -> str:
    if not clashes:
        return "skip"
    answer = ctx.env.get("EXAKIT_ON_EXISTING", "").strip().lower()
    if answer in ("skip", "replace", "append"):
        return answer
    if answer:
        raise BadInput(f"EXAKIT_ON_EXISTING='{answer}' is not one of skip, replace, append.")
    ctx.ui.warn(f"{len(clashes)} table(s) in {schema} already holding rows this kit did not load:")
    for entry in clashes:
        ctx.ui.text(f"      - {entry.path.name} -> {decisions[entry.path][1]} rows already")
    if not ctx.ui.interactive:
        ctx.ui.info("Skipping those files. Re-run with EXAKIT_ON_EXISTING=replace or =append to decide otherwise.")
        return "skip"
    while True:
        reply = ctx.ui.prompt("Those files: (s)kip, (r)eplace what is there, or (a)ppend to it", "s").lower()
        if reply in ("s", "skip"):
            return "skip"
        if reply in ("r", "replace"):
            return "replace"
        if reply in ("a", "append"):
            return "append"


def _print_plan(ctx: Context, entries: list[ScanEntry]) -> None:
    for entry in entries:
        if entry.action == "load":
            ctx.ui.text(f"      - {entry.path.name} -> {entry.table}")
    for entry in entries:
        if entry.kind == "duplicate-content":
            ctx.ui.text(f"      ! {entry.path.name} skipped (identical to {entry.table})")
        elif entry.kind == "duplicate-table":
            ctx.ui.text(f"      ! {entry.path.name} skipped (same target table as {entry.table})")
    renames = sum(1 for e in entries if e.kind == "extension")
    if renames:
        ctx.ui.text(f"      ! {renames} files tabular but named .txt/.tsv - exapump reads .csv and .parquet only; rename to .csv to load")
    ignored = {k: sum(1 for e in entries if e.kind == k) for k in ("unsupported", "empty", "header-only")}
    if any(ignored.values()):
        ctx.ui.text(f"      ignored: {ignored['unsupported']} of other kinds, {ignored['empty']} empty, {ignored['header-only']} with a header and no rows")


def _print_outcomes(ctx: Context, schema: str, settled) -> None:
    marks = {"ok": "[ok]", "skip": "-", "fail": "[x]"}
    if ctx.ui.fancy:
        marks = {"ok": "✓", "skip": "•", "fail": "✗"}
    width = min(max([len(s[1].path.name) for s in settled] + [10]), 44)
    ctx.ui.text("")
    ctx.ui.text(f"     into {schema}")
    for mark, entry, table_text, rows_text, reason in settled:
        ctx.ui.text(f"     {marks[mark]:<4} {entry.path.name:<{width}} -> {table_text}  {rows_text}")
        if reason:
            ctx.ui.text(f"       {reason}")
    ctx.ui.text("")
