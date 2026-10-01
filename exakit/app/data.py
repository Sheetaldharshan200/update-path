"""Bundled datasets: what is loaded, and loading one (schema script, uploads, load statements, verify, counts).

A dataset is ``data/datasets/<id>/``: ``dataset.conf``, ``01_create_schema.sql``,
``data/*.csv``, an optional ``02_load_data.sql`` and ``03_verify_setup.sql``.
"Loaded" is answered by the database first (the marker tables hold rows)
and by the manifest only when the database cannot be asked.
"""

from __future__ import annotations

import re
import time
from dataclasses import dataclass
from pathlib import Path

from exakit.adapters.exapump import LISTING_SQL, Exapump, table_listing
from exakit.domain.errors import BadInput, Failed
from exakit.domain.manifest import Manifest
from exakit.domain.result import Result
from exakit.ui.widgets import Option

from . import Context
from .data_files import load_local_path, upload_with_recovery
from .machine import kit_root
from .runtime_ops import ensure_running, exapump, profile_name


@dataclass(frozen=True, slots=True)
class Dataset:
    id: str
    label: str
    schema: str
    markers: tuple[str, ...]
    flag: str
    order: int
    directory: Path


def bundled(ctx: Context) -> list[Dataset]:
    """Every dataset with a conf, in declared order."""
    found: list[Dataset] = []
    for conf in kit_root(ctx).glob("data/datasets/*/dataset.conf"):
        fields: dict[str, str] = {}
        for line in conf.read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.startswith("#"):
                key, value = line.split("=", 1)
                fields[key.strip()] = value.strip()
        if not fields.get("id") or not fields.get("label"):
            continue
        found.append(Dataset(
            id=fields["id"], label=fields["label"], schema=fields.get("schema") or fields["id"].upper(),
            markers=tuple(m.strip() for m in fields.get("markers", "").split(",") if m.strip()),
            flag=fields.get("flag") or f"data.datasets.{fields['id']}.loaded",
            order=int(fields["order"]) if fields.get("order", "").isdigit() else 50, directory=conf.parent))
    return sorted(found, key=lambda d: (d.order, d.id))


def dataset(ctx: Context, dataset_id: str) -> Dataset:
    """The bundled dataset with that id; unknown is BadInput."""
    for ds in bundled(ctx):
        if ds.id == dataset_id:
            return ds
    raise BadInput(f"Unknown bundled dataset '{dataset_id}' (available: {', '.join(d.id for d in bundled(ctx))}).")


# --- what is loaded ----------------------------------------------------------------


def listing(ctx: Context) -> dict[str, int] | None:
    """SCHEMA.TABLE -> rows for every table, or None when the database did not answer."""
    pump = exapump(ctx)
    if pump is None:
        return None
    return table_listing(pump.sql(profile_name(ctx), LISTING_SQL))


def loaded(ctx: Context, *, tables: dict[str, int] | None = None, heal: bool = True) -> set[str]:
    """Datasets whose marker tables hold rows. Falls back to the manifest when the database cannot be asked."""
    manifest = ctx.manifest_or_none()
    if tables is None:
        tables = listing(ctx)
    result: set[str] = set()
    for ds in bundled(ctx):
        if tables is None:
            if manifest and manifest.get(ds.flag) is True:
                result.add(ds.id)
            continue
        present = all(tables.get(f"{ds.schema}.{marker}".upper(), 0) > 0 for marker in ds.markers) if ds.markers else False
        if not ds.markers and manifest and manifest.get(ds.flag) is True:
            present = True
        if present:
            result.add(ds.id)
        if heal and manifest is not None and manifest.get(ds.flag) is not present:
            def change(m: Manifest, ds=ds, present=present) -> None:
                m.set(ds.flag, present)
                m.set(f"data.datasets.{ds.id}.loaded", present)
            ctx.manifest_store.update(change)
    return result


def pending(ctx: Context) -> list[Dataset]:
    """The bundled datasets not loaded yet."""
    done = loaded(ctx)
    return [d for d in bundled(ctx) if d.id not in done]


# --- loading one ---------------------------------------------------------------------


def _sql_file(ctx: Context, pump: Exapump, path: Path, what: str) -> None:
    done = pump.sql_file(profile_name(ctx), path)
    ctx.log.line("CMD", f"exapump sql < {path.name} -> {done.code}")
    if not done.ok:
        ctx.log.line("ERROR", (done.err or done.out).strip()[-600:])
        raise Failed(f"The SQL in {path.name} did not run ({what}). What exapump said is in: exakit logs setup",
                     remedy="exakit logs setup")


def schema_present(ctx: Context, pump: Exapump, schema: str) -> bool:
    """True when the schema exists."""
    done = pump.sql(profile_name(ctx), f"SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_ALL_SCHEMAS WHERE SCHEMA_NAME = '{schema}') "
                                      "THEN 'EXAKIT_SCHEMA_PRESENT' ELSE 'EXAKIT_SCHEMA_MISSING' END AS STATUS")
    return done.ok and "EXAKIT_SCHEMA_PRESENT" in done.out


def ensure_schema(ctx: Context, pump: Exapump, schema: str) -> None:
    """Create the schema when it does not exist."""
    if not schema_present(ctx, pump, schema):
        done = pump.sql(profile_name(ctx), f"CREATE SCHEMA {schema}")
        if not done.ok:
            raise Failed(f"Could not create schema {schema}. What exapump said is in: exakit logs setup", remedy="exakit logs setup")


def count_rows(ctx: Context, pump: Exapump, table: str) -> int | None:
    """The row count of a table, or None."""
    done = pump.sql(profile_name(ctx), f"SELECT 'EXAKIT_RC[' || CAST(COUNT(*) AS VARCHAR(20)) || ']' AS R FROM {table}")
    match = re.search(r"EXAKIT_RC\[(\d+)\]", done.out) if done.ok else None
    return int(match.group(1)) if match else None


def load(ctx: Context, ds: Dataset, *, force: bool = False) -> Result:
    """Load one bundled dataset end to end. Raises Failed when a step did not finish."""
    pump = exapump(ctx)
    if pump is None:
        raise Failed("exapump (the data-loading CLI) is not installed", remedy="exakit update")
    if not force and ds.id in loaded(ctx):
        ctx.ui.ok(f"Dataset '{ds.id}' already loaded (pass --force to REPLACE it: its tables are dropped and rebuilt)")
        return Result(True, "already loaded", data={"dataset": ds.id})
    ctx.ui.info(f"Loading the '{ds.id}' dataset into schema {ds.schema}")
    started = time.monotonic()
    _create_schema(ctx, pump, ds)
    csvs = sorted(p for p in (ds.directory / "data").glob("*.csv") if p.stat().st_size)
    _upload_csvs(ctx, pump, ds, csvs)
    load_sql = ds.directory / "02_load_data.sql"
    if load_sql.is_file() and load_sql.stat().st_size:
        _sql_file(ctx, pump, load_sql, "load statements")
    _verify(ctx, pump, ds)
    tables, total = _count_and_record(ctx, pump, ds, csvs)
    took = int(time.monotonic() - started)
    rows_text = f"{total:,} rows" if total is not None else "rows counted in the log"
    ctx.ui.ok(f"Dataset '{ds.id}' loaded and verified - {len(tables)} table{'s' if len(tables) != 1 else ''}, {rows_text} ({took}s)")
    return Result(True, "loaded", data={"dataset": ds.id, "tables": len(tables), "rows": total})


def _create_schema(ctx: Context, pump: Exapump, ds: Dataset) -> None:
    """The dataset's own schema script (retried once), else a bare CREATE SCHEMA."""
    schema_sql = ds.directory / "01_create_schema.sql"
    if not (schema_sql.is_file() and schema_sql.stat().st_size):
        ensure_schema(ctx, pump, ds.schema)
        return
    _sql_file(ctx, pump, schema_sql, "schema")
    if schema_present(ctx, pump, ds.schema):
        return
    ctx.ui.warn(f"Schema {ds.schema} was not created on the first run - trying once more")
    _sql_file(ctx, pump, schema_sql, "schema")
    if not schema_present(ctx, pump, ds.schema):
        raise Failed(f"Schema {ds.schema} does not exist after running {schema_sql.name}.", remedy="exakit logs setup")


def _upload_csvs(ctx: Context, pump: Exapump, ds: Dataset, csvs: list[Path]) -> None:
    failed: list[str] = []
    for csv in csvs:
        table = f"{ds.schema}.{csv.stem.upper()}"
        if not upload_with_recovery(ctx, pump, csv, table):
            failed.append(f"{csv.name} -> {table}")
    if failed:
        raise Failed(f"Could not load {'; '.join(failed)}. The reason: exakit logs setup. Retry this step with: exakit data-load --force",
                     remedy="exakit data-load --force")


def _verify(ctx: Context, pump: Exapump, ds: Dataset) -> None:
    """The dataset's verification script: a ,FAIL, row means the data is there but not marked ready."""
    verify_sql = ds.directory / "03_verify_setup.sql"
    if not (verify_sql.is_file() and verify_sql.stat().st_size):
        return
    done = pump.sql_file(profile_name(ctx), verify_sql)
    ctx.log.line("DATA", f"verification of {ds.id}:\n{done.out}")
    if done.ok and ",FAIL," not in done.out:
        return
    ctx.ui.error(f"Verification failed for dataset '{ds.id}':")
    for line in done.out.splitlines():
        ctx.ui.text(f"      | {line}")
    raise Failed(f"Verification failed for dataset '{ds.id}' - see exakit logs setup. Data is loaded but not marked ready; "
                 "fix the underlying issue and re-run with --force.", remedy="exakit data-load --force")


def _count_and_record(ctx: Context, pump: Exapump, ds: Dataset, csvs: list[Path]) -> tuple[list[str], int | None]:
    """Row counts for every table (CSV-backed plus the markers), then the manifest flags."""
    tables = [f"{ds.schema}.{c.stem.upper()}" for c in csvs]
    for marker in ds.markers:
        if f"{ds.schema}.{marker}" not in tables:
            tables.append(f"{ds.schema}.{marker}")
    counts = {t: count_rows(ctx, pump, t) for t in tables}
    for table, rows in counts.items():
        ctx.log.line("DATA", f"{table:<30} {rows if rows is not None else '?'} rows")
    total = sum(counts.values()) if all(v is not None for v in counts.values()) else None

    def change(m: Manifest) -> None:
        m.set(ds.flag, True)
        m.set(f"data.datasets.{ds.id}.loaded", True)
        m.set(f"data.datasets.{ds.id}.schema", ds.schema)
        m.set(f"data.datasets.{ds.id}.tables", len(tables))
        if total is not None:
            m.set(f"data.datasets.{ds.id}.rows", total)
        m.set("data.last_load.source", f"dataset:{ds.id}")
    ctx.manifest_store.update(change)
    return tables, total


# --- the command and the menu -------------------------------------------------------


def parse_env_datasets(ctx: Context) -> list[Dataset] | None:
    """EXAKIT_DATASETS as datasets; unknown ids warn; None when the variable is unset; empty list = none valid."""
    raw = ctx.env.get("EXAKIT_DATASETS", "")
    if not raw:
        return None
    known = {d.id: d for d in bundled(ctx)}
    chosen: list[Dataset] = []
    for token in (t.strip() for t in raw.split(",") if t.strip()):
        if token in known:
            chosen.append(known[token])
        else:
            ctx.ui.warn(f"Unknown dataset id '{token}' in EXAKIT_DATASETS (available: {', '.join(known)}).")
    return chosen


def data_load(ctx: Context, args: list[str]) -> Result:
    """``exakit data-load [--force | <path>]``."""
    force, path = _parse_data_load_args(args)
    ctx.manifest()
    if path is not None and not path.exists():
        raise Failed(f"No such file or folder: {path}")
    ensure_running(ctx, deploy=True)
    if force:
        chosen = parse_env_datasets(ctx)
        return _load_datasets(ctx, [dataset(ctx, "tpch")] if chosen is None else chosen, force=True)
    if path is not None:
        return load_local_path(ctx, path)
    chosen = parse_env_datasets(ctx)
    if chosen is not None and not ctx.env.get("EXAKIT_DATA_FILE"):
        return _load_datasets(ctx, chosen, force=False)
    if ctx.env.get("EXAKIT_DATA_FILE"):
        ctx.ui.info("Loading a local file (EXAKIT_DATA_FILE).")
        return load_local_path(ctx, Path(ctx.env["EXAKIT_DATA_FILE"]).expanduser())
    return menu(ctx)


def _parse_data_load_args(args: list[str]) -> tuple[bool, Path | None]:
    force, path = False, None
    for arg in args:
        if arg == "--force":
            force = True
        elif arg.startswith("-"):
            raise BadInput(f"Unknown option '{arg}' for data-load (pass --force, or a file or folder path).")
        elif path is None:
            path = Path(arg).expanduser()
    return force, path


def _load_datasets(ctx: Context, chosen: list[Dataset], *, force: bool) -> Result:
    """The scripted path: every named dataset in turn; one failure does not stop the next."""
    if not chosen:
        raise Failed(f"EXAKIT_DATASETS='{ctx.env.get('EXAKIT_DATASETS')}' matched no bundled dataset - nothing was loaded.")
    done = loaded(ctx) if not force else set()
    failures = 0
    for ds in chosen:
        if ds.id in done:
            ctx.ui.ok(f"Dataset '{ds.id}' is already loaded - nothing to do (replace it with: exakit data-load --force)")
            continue
        if force:
            ctx.ui.info(f"Reloading dataset '{ds.id}' (--force)")
        try:
            load(ctx, ds, force=force)
        except Failed as err:
            ctx.ui.warn(err.message)
            failures += 1
    return Result(True, "loaded" if not failures else "partial", exit_code=1 if failures else 0)


def menu(ctx: Context) -> Result:
    """The datasets table: pending datasets pre-selected, a local-file row, a skip row."""
    todo = pending(ctx)
    options = [Option(d.id, re.sub(r" *\([^()]*\)$", "", d.label)) for d in todo]
    options.append(Option("local", "A local CSV / Parquet / JSON file, or a folder of them"))
    options.append(Option("skip", "Skip"))
    defaults = [d.id for d in todo] or ["local"]
    chosen = defaults if not ctx.ui.interactive else ctx.ui.checkboxes("Datasets to load", options, defaults=defaults)
    if not chosen or "skip" in chosen:
        ctx.ui.info("Data loading cancelled.")
        return Result(True, "cancelled")
    failures = 0
    for ds in todo:
        if ds.id in chosen:
            try:
                load(ctx, ds)
            except Failed as err:
                ctx.ui.warn(f"Loading '{ds.id}' did not finish. Retry any time with: exakit data-load")
                ctx.log.line("ERROR", err.message)
                failures += 1
    if "local" in chosen:
        if not ctx.ui.interactive:
            ctx.ui.warn("Please enter a file or folder path: exakit data-load <path>, or EXAKIT_DATA_FILE=<path>.")
            return Result(True, "partial", exit_code=1)
        answer = ctx.ui.prompt("Local CSV / Parquet / JSON file - or a folder of them (type back to return)", "")
        if answer and answer.lower() not in ("b", "back"):
            result = load_local_path(ctx, Path(answer).expanduser())
            failures += 1 if result.exit_code else 0
    return Result(True, "loaded" if not failures else "partial", exit_code=1 if failures else 0)
