"""An older kit's container database: where it is, what it holds, and copying its tables out and back in."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from exakit.adapters.exapump import Profile, write_profile
from exakit.adapters.process import containers
from exakit.adapters.process.containers import Engine

from . import Context, data
from .runtime_ops import exapump, profile_name

LEGACY_TYPES = ("nano",)
PROFILE = "starter-kit-legacy"
SYSTEM_SCHEMAS = "'SYS','EXA_STATISTICS'"


@dataclass(slots=True)
class LegacyDb:
    container: str
    engine: Engine | None
    engine_name: str
    volume: str
    dsn: str
    user: str
    password_file: str | None
    password: str | None = None

    def state(self, ctx: Context) -> str:
        """The container's state: running, stopped, absent, or unknown when the engine does not answer."""
        return containers.container_state(ctx.runner, self.engine, self.container, timeout=ctx.catalog.kit.container_probe_timeout)

    def remove_command(self) -> str | None:
        """The command that removes the legacy container, or None when there is none."""
        if not self.container:
            return None
        engine = self.engine_name or "podman"
        return f"{engine} rm -f {self.container}" + (f" && {engine} volume rm {self.volume}" if self.volume else "")


@dataclass(slots=True)
class Classified:
    own: list[str] = field(default_factory=list)
    sample: list[str] = field(default_factory=list)
    sample_ids: list[str] = field(default_factory=list)


@dataclass(slots=True)
class Imported:
    ok: int = 0
    skipped: int = 0
    failed: int = 0
    skipped_names: list[str] = field(default_factory=list)


def export_dir(ctx: Context) -> Path:
    """Where a migration exports the legacy tables (EXAKIT_LEGACY_EXPORT_DIR overrides)."""
    return Path(ctx.env.get("EXAKIT_LEGACY_EXPORT_DIR") or ctx.paths.home / "migration")


def recorded_type(ctx: Context) -> str | None:
    """The legacy runtime type the record names, or None."""
    manifest = ctx.manifest_or_none()
    rtype = manifest.runtime_type() if manifest else None
    return rtype if rtype in LEGACY_TYPES else None


def value(ctx: Context, key: str, *, old_kit: bool = True) -> str:
    """One legacy setting from the record: the current one, or the old kit's when ``old_kit``."""
    manifest = ctx.manifest_or_none()
    if manifest is None:
        return ""
    legacy = manifest.get(f"legacy.{key}")
    if legacy:
        return str(legacy)
    return str(manifest.get(f"runtime.{key}") or "") if old_kit else ""


def from_record(ctx: Context, **overrides: str) -> LegacyDb:
    """The old database as recorded (legacy.*, then the old install's runtime.*), with command-line overrides on top."""
    container = overrides.get("container") or value(ctx, "container") or "exasol-nano"
    engine_name = overrides.get("engine") or value(ctx, "engine")
    engine = containers.find_engine(ctx.runner, container, timeout=ctx.catalog.kit.container_probe_timeout, prefer=engine_name or None)
    if engine and not engine_name:
        engine_name = engine.name
    dsn = overrides.get("dsn") or value(ctx, "dsn")
    if not dsn and engine:
        port = containers.published_port(ctx.runner, engine, container, timeout=ctx.catalog.kit.container_probe_timeout) or ctx.catalog.kit.db_port
        dsn = f"127.0.0.1:{port}"
    return LegacyDb(container=container, engine=engine, engine_name=engine_name, volume=value(ctx, "volume"), dsn=dsn,
                    user=overrides.get("user") or value(ctx, "user") or "sys",
                    password_file=overrides.get("password_file") or value(ctx, "password_file") or None,
                    password=ctx.env.get("EXAKIT_LEGACY_PASSWORD") or None)


def remember(ctx: Context, db: LegacyDb) -> None:
    """Write the legacy database's details into the record for the crossing."""
    def change(m):
        for key, val in (("container", db.container), ("engine", db.engine_name), ("volume", db.volume), ("dsn", db.dsn),
                         ("password_file", db.password_file or ""), ("user", db.user)):
            if val:
                m.set(f"legacy.{key}", val)
    ctx.manifest_store.update(change)


def start_container(ctx: Context, db: LegacyDb) -> bool:
    """Start the legacy container; False when there is no engine."""
    return bool(db.engine) and containers.start_container(ctx.runner, db.engine, db.container, timeout=ctx.catalog.kit.container_action_timeout)


def stop_container(ctx: Context, db: LegacyDb) -> bool:
    """Stop the legacy container when it runs."""
    if not db.container or db.state(ctx) != "running" or not db.engine:
        return True
    ctx.ui.info(f"Stopping the old database container ({db.container}) so the new deployment can take the port")
    if not containers.stop_container(ctx.runner, db.engine, db.container, timeout=ctx.catalog.kit.container_action_timeout):
        ctx.ui.warn(f"Could not stop the container {db.container} - the new deployment may find its port busy")
        return False
    ctx.manifest_store.update(lambda m: m.set("legacy.container_stopped", True))
    return True


# --- talking to it ------------------------------------------------------------------------


def password_of(db: LegacyDb) -> str | None:
    """The legacy password from the record or its file, or None."""
    if db.password:
        return db.password
    if db.password_file and Path(db.password_file).is_file():
        text = Path(db.password_file).read_text(encoding="utf-8").strip()
        return text or None
    return None


def write_legacy_profile(ctx: Context, db: LegacyDb) -> bool:
    """Write the exapump profile that reaches the legacy database."""
    host, _, port = db.dsn.rpartition(":")
    password = password_of(db)
    if not host or not port.isdigit() or not password:
        return False
    pump = exapump(ctx)
    if pump is None:
        return False
    write_profile(pump.config_path, Profile(PROFILE, host, int(port), db.user, password))
    return True


def db_answers(ctx: Context) -> bool:
    """True when the legacy database answers a query."""
    pump = exapump(ctx)
    return bool(pump) and "EXAKIT_LEGACY_OK" in pump.sql(PROFILE, "SELECT 'EXAKIT_LEGACY_OK' AS P").out


def wait_db(ctx: Context, budget: int) -> bool:
    """Wait up to ``budget`` seconds for the legacy database to answer."""
    import time
    waited = 0
    while not db_answers(ctx):
        waited += 5
        if waited >= budget:
            return db_answers(ctx)
        time.sleep(5)
    return True


def tables(ctx: Context) -> list[str]:
    """Every user table of the legacy database as schema.table."""
    pump = exapump(ctx)
    if pump is None:
        return []
    done = pump.sql(PROFILE, "SELECT 'EXAKIT_LT[' || TABLE_SCHEMA || '.' || TABLE_NAME || ']' AS T FROM EXA_ALL_TABLES "
                             f"WHERE TABLE_SCHEMA NOT IN ({SYSTEM_SCHEMAS}) ORDER BY TABLE_SCHEMA, TABLE_NAME")
    import re
    return re.findall(r"EXAKIT_LT\[([^\]]*)\]", done.out) if done.ok else []


def table_ddl(ctx: Context, schema: str, table: str) -> str | None:
    """The CREATE TABLE of one legacy table, or None."""
    pump = exapump(ctx)
    if pump is None:
        return None
    done = pump.sql(PROFILE, "SELECT 'EXAKIT_LC[' || COLUMN_NAME || '<<:>>' || COLUMN_TYPE || ']' AS C FROM EXA_ALL_COLUMNS "
                             f"WHERE COLUMN_SCHEMA = '{schema}' AND COLUMN_TABLE = '{table}' ORDER BY COLUMN_ORDINAL_POSITION")
    import re
    columns = re.findall(r"EXAKIT_LC\[([^\]]*)\]", done.out) if done.ok else []
    parts = [f'"{c.split("<<:>>", 1)[0]}" {c.split("<<:>>", 1)[1]}' for c in columns if "<<:>>" in c]
    return f'CREATE TABLE "{schema}"."{table}" ({", ".join(parts)})' if parts else None


def sample_catalog(ctx: Context) -> dict[str, tuple[str, int | None]]:
    """SCHEMA.TABLE -> (dataset id, rows in the shipped CSV, or None for a marker table)."""
    catalog: dict[str, tuple[str, int | None]] = {}
    for ds in data.bundled(ctx):
        for csv in sorted((ds.directory / "data").glob("*.csv")):
            rows = max(sum(1 for _ in csv.open("rb")) - 1, 0)
            catalog[f"{ds.schema}.{csv.stem.upper()}"] = (ds.id, rows)
        for marker in ds.markers:
            catalog.setdefault(f"{ds.schema}.{marker.upper()}", (ds.id, None))
    return catalog


def table_rows(ctx: Context, schemas: list[str]) -> dict[str, int]:
    """Row counts of every table in those schemas."""
    pump = exapump(ctx)
    if pump is None or not schemas:
        return {}
    quoted = ",".join(f"'{s}'" for s in schemas)
    done = pump.sql(PROFILE, "SELECT 'EXAKIT_LR[' || TABLE_SCHEMA || '.' || TABLE_NAME || '<<:>>' || CAST(TABLE_ROW_COUNT AS VARCHAR(40)) || ']' AS R "
                             f"FROM EXA_ALL_TABLES WHERE TABLE_SCHEMA IN ({quoted})")
    import re
    out: dict[str, int] = {}
    for item in re.findall(r"EXAKIT_LR\[([^\]]*)\]", done.out) if done.ok else []:
        name, _, count = item.partition("<<:>>")
        if count.isdigit():
            out[name] = int(count)
    return out


def classify(ctx: Context, all_tables: list[str]) -> Classified:
    """The kit's own bundled sample, unchanged, is not the user's data; everything else is."""
    catalog = sample_catalog(ctx)
    schemas = sorted({t.split(".", 1)[0] for t in all_tables if t in catalog})
    rows = table_rows(ctx, schemas)
    result = Classified()
    for table in all_tables:
        entry = catalog.get(table)
        same = bool(entry) and (entry[1] is None or rows.get(table) == entry[1])
        if same:
            result.sample.append(table)
            if entry[0] not in result.sample_ids:
                result.sample_ids.append(entry[0])
        else:
            result.own.append(table)
    return result


# --- moving the data -------------------------------------------------------------------------


def export(ctx: Context, directory: Path, own: list[str]) -> int:
    """Each table to <dir>/tN.csv with its DDL in <dir>/index (TSV). Returns how many came out."""
    pump = exapump(ctx)
    directory.mkdir(parents=True, exist_ok=True)
    directory.chmod(0o700)
    index = directory / "index"
    index.write_text("", encoding="utf-8")
    ok, bad_names = 0, []
    for n, table in enumerate(own, 1):
        schema, name = table.split(".", 1)
        file = directory / f"t{n}.csv"
        with ctx.ui.busy(f"Copying out {table} ({n} of {len(own)})"):
            done = pump.export_query(PROFILE, f'SELECT * FROM "{schema}"."{name}"', file) if pump else None
        if done is not None and done.ok:
            with index.open("a", encoding="utf-8") as handle:
                handle.write(f"t{n}.csv\t{schema}\t{name}\t{table_ddl(ctx, schema, name) or ''}\n")
            ok += 1
        else:
            file.unlink(missing_ok=True)
            ctx.ui.warn(f"Could not copy {table} out of the old database - it is left there, untouched")
            bad_names.append(table)
    ctx.ui.ok(f"Copied {ok} of {len(own)} table(s) out")
    def change(m):
        m.set("legacy.exported", ok)
        if bad_names:
            m.set("legacy.export_failed", len(bad_names))
            m.set("legacy.export_failed_names", " ".join(bad_names))
    ctx.manifest_store.update(change)
    return ok


def import_(ctx: Context, directory: Path) -> Imported | None:
    """Every table in the index into the new database; the kit's sample tables are left to the kit."""
    pump = exapump(ctx)
    index = directory / "index"
    if pump is None or not index.is_file() or not index.read_text(encoding="utf-8").strip():
        return None
    if "EXAKIT_NEW_OK" not in pump.sql(profile_name(ctx), "SELECT 'EXAKIT_NEW_OK' AS P").out:
        return None
    catalog = sample_catalog(ctx)
    outcome = Imported()
    for line in index.read_text(encoding="utf-8").splitlines():
        parts = line.split("\t")
        if len(parts) < 3 or not (directory / parts[0]).is_file():
            continue
        file, schema, table, ddl = parts[0], parts[1], parts[2], parts[3] if len(parts) > 3 else ""
        if f"{schema}.{table}" in catalog:
            outcome.skipped += 1
            outcome.skipped_names.append(f"{schema}.{table}")
            continue
        pump.sql(profile_name(ctx), f'CREATE SCHEMA IF NOT EXISTS "{schema}"')
        if ddl and not pump.sql(profile_name(ctx), ddl).ok:
            outcome.skipped += 1
            outcome.skipped_names.append(f"{schema}.{table}")
            continue
        with ctx.ui.busy(f"Restoring {schema}.{table}"):
            done = pump.upload(directory / file, f'"{schema}"."{table}"', profile_name(ctx))
        if done.ok:
            outcome.ok += 1
        else:
            ctx.ui.warn(f"Could not restore {schema}.{table} - the copy is kept at {directory / file}")
            outcome.failed += 1
    def change(m):
        m.set("legacy.restored", outcome.ok)
        if outcome.skipped:
            m.set("legacy.restore_skipped", outcome.skipped)
        if outcome.failed:
            m.set("legacy.restore_failed", outcome.failed)
    ctx.manifest_store.update(change)
    return outcome


def report_restore(ctx: Context, directory: Path, why: str, imported: Imported, db: LegacyDb) -> bool:
    """Say how the restore went; True when every table landed."""
    ctx.ui.ok(f"Restored {imported.ok} table(s) from your previous database")
    if imported.skipped:
        ctx.ui.info(f"Left alone ({why}): {' '.join(imported.skipped_names)}")
    if imported.failed:
        ctx.ui.warn(f"{imported.failed} table(s) did not restore - the copies are still at {directory}")
        return False
    manifest = ctx.manifest()
    failed_out = manifest.get("legacy.export_failed") or 0
    if failed_out:
        names = manifest.get("legacy.export_failed_names") or ""
        ctx.ui.warn(f"{failed_out} table(s) could NOT be copied out of the old database{': ' + names if names else ''}")
        ctx.ui.warn("Those tables exist ONLY in the old container. Do not remove it until you have them.")
        ctx.ui.info("Try the copy again with: exakit migrate docker-nano")
        return False
    ctx.ui.info(f"The copy at {directory} is no longer needed; remove it whenever you like.")
    command = db.remove_command()
    if command:
        ctx.ui.info(f"The old container still holds the original. To remove it: {command}")
    return True
