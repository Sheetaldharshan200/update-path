"""Your own data: one file, a folder of files, JSON through the json-tables engine, and the receipts.

Uploads go through exapump, which infers the schema, creates the table if
needed and appends. A cut-short transfer is retried; a large CSV is re-sent
in pieces through a staging table so one bad chunk never leaves a half
table behind. A folder load remembers what it loaded (receipts keyed by
size and content hash), so re-running it is safe.
"""

from __future__ import annotations

import hashlib
import json
import re
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

from exakit.adapters.exapump import Exapump, failure_reason
from exakit.domain.errors import BadInput, Failed
from exakit.domain.manifest import Manifest
from exakit.domain.result import Result

from . import Context
from .runtime_ops import exapump, profile_name

CUT_SHORT = ("ETL-5105", "transfer closed with outstanding read data", "Transferred a partial file", "Connection reset by peer",
             "connection was aborted")
COMPRESSED = (".gz", ".bz2", ".zst", ".xz")


# --- names and kinds -------------------------------------------------------------------


def table_name_from_path(path: Path) -> str:
    """The table name a file loads into: its stem, upper-cased and made an identifier."""
    stem = path.name.split("?")[0].rsplit(".", 1)[0] if "." in path.name else path.name
    name = re.sub(r"[^A-Z0-9_]", "_", stem.upper()).strip("_")
    name = re.sub(r"_+", "_", name)
    return name or "MY_TABLE"


def file_kind(path: Path) -> str:
    """csv, parquet, json or unknown, from the file's extensions (compression included)."""
    name = path.name.lower()
    for ext in COMPRESSED:
        if name.endswith(ext):
            name = name[: -len(ext)]
            break
    if name.endswith((".json", ".geojson", ".ndjson", ".jsonl")):
        return "json"
    if name.endswith((".parquet", ".pq")):
        return "parquet"
    if name.endswith((".csv", ".tsv", ".txt")):
        return "csv"
    return "unknown"


def valid_target(text: str) -> bool:
    """True when ``text`` is SCHEMA.TABLE made of identifier characters."""
    return bool(re.fullmatch(r"[A-Za-z0-9_]+\.[A-Za-z0-9_]+", text))


@dataclass(frozen=True, slots=True)
class CsvInfo:
    delimiter: str
    flags: tuple[str, ...]

    @property
    def delimiter_name(self) -> str:
        """The delimiter's name for messages."""
        return {",": "comma", ";": "semicolon", "\t": "tab"}[self.delimiter]


def inspect_csv(path: Path) -> CsvInfo | None:
    """Delimiter and flags (bom, crlf) from the header; None for a header with no rows."""
    if path.name.lower().endswith(COMPRESSED):
        return CsvInfo(",", ())
    with path.open("rb") as handle:
        first = handle.readline()
        second = handle.readline()
    flags: list[str] = []
    if first.startswith(b"\xef\xbb\xbf"):
        flags.append("bom")
        first = first[3:]
    if first.endswith(b"\r\n"):
        flags.append("crlf")
    if not second.strip():
        return None
    header = first.decode("utf-8", errors="replace")
    delimiter = "," if "," in header else ";" if ";" in header else "\t"
    return CsvInfo(delimiter, tuple(flags))


# --- uploads with recovery -------------------------------------------------------------------


def _cut_short(text: str) -> bool:
    return any(s in text for s in CUT_SHORT)


def _split_pieces(path: Path, piece_bytes: int, out_dir: Path) -> list[Path]:
    """Cut a CSV at line boundaries where the running quote count is even; every piece keeps the header."""
    pieces: list[Path] = []
    with path.open("rb") as handle:
        header = handle.readline()
        index, size, quotes, chunk = 0, 0, 0, []
        for line in handle:
            chunk.append(line)
            size += len(line)
            quotes += line.count(b'"')
            if size >= piece_bytes and quotes % 2 == 0:
                piece = out_dir / f"{path.stem}.piece{index:04d}{path.suffix}"
                piece.write_bytes(header + b"".join(chunk))
                pieces.append(piece)
                index, size, chunk = index + 1, 0, []
        if chunk:
            piece = out_dir / f"{path.stem}.piece{index:04d}{path.suffix}"
            piece.write_bytes(header + b"".join(chunk))
            pieces.append(piece)
    return pieces


def upload_with_recovery(ctx: Context, pump: Exapump, file: Path, table: str, *, delimiter: str | None = None) -> bool:
    """Upload one file; on a cut-short transfer retry, in pieces for a large CSV. True when the rows landed."""
    retries_text = ctx.env.get("EXAKIT_UPLOAD_RETRIES", "")
    retries = int(retries_text) if retries_text.isdigit() else 2
    done = pump.upload(file, table, profile_name(ctx), delimiter=delimiter)
    ctx.log.line("CMD", f"exapump upload {file.name} --table {table} -> {done.code}")
    if done.ok:
        return True
    ctx.log.line("ERROR", (done.err or done.out).strip()[-800:])
    retryable = _cut_short(done.out + done.err) or not (done.out + done.err).strip()
    if not retryable or retries == 0:
        return False
    piece_kb_text = ctx.env.get("EXAKIT_UPLOAD_PIECE_KB", "")
    piece_kb = int(piece_kb_text) if piece_kb_text.isdigit() else 128
    size = file.stat().st_size
    if file.suffix.lower() in (".csv", ".tsv", ".txt") and piece_kb and size > piece_kb * 1024 and size <= 64 * 1024 * 1024:
        return _upload_pieces(ctx, pump, file, table, piece_kb * 1024, retries, delimiter)
    for attempt in range(2, retries + 2):
        ctx.log.line("WARN", f"{file.name}: the import connection was cut mid-transfer - attempt {attempt} of {retries + 1}")
        time.sleep(attempt - 1)
        done = pump.upload(file, table, profile_name(ctx), delimiter=delimiter)
        if done.ok:
            return True
        if not _cut_short(done.out + done.err) and (done.out + done.err).strip():
            return False
    return False


def _upload_pieces(ctx: Context, pump: Exapump, file: Path, table: str, piece_bytes: int, retries: int, delimiter: str | None) -> bool:
    stage = f"{table}__EXAKIT_PIECES"
    profile = profile_name(ctx)
    with tempfile.TemporaryDirectory(prefix="exakit-pieces-") as tmp:
        pieces = _split_pieces(file, piece_bytes, Path(tmp))
        if not pump.sql(profile, f"DROP TABLE IF EXISTS {stage}").ok or not pump.sql(profile, f"CREATE TABLE {stage} LIKE {table}").ok:
            return False
        for piece in pieces:
            ok = False
            for attempt in range(retries + 1):
                if attempt:
                    time.sleep(attempt)
                if pump.upload(piece, stage, profile, delimiter=delimiter).ok:
                    ok = True
                    break
            if not ok:
                pump.sql(profile, f"DROP TABLE IF EXISTS {stage}")
                return False
        moved = pump.sql(profile, f"INSERT INTO {table} SELECT * FROM {stage}")
        pump.sql(profile, f"DROP TABLE {stage}")
        return moved.ok


# --- receipts (what a folder load already put where) ---------------------------------------


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


@dataclass(slots=True)
class Receipts:
    path: Path
    rows: list[list[str]] = field(default_factory=list)

    @classmethod
    def load(cls, path: Path) -> Receipts:
        """The receipts file as rows; missing means none."""
        rows = []
        if path.is_file():
            rows = [line.split("\t") for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
        return cls(path, rows)

    def record(self, target: str, file: Path, rows: int) -> None:
        """Note that a file landed in a table, with its size and row count."""
        self.rows.append([target.upper(), str(file.stat().st_size), _sha256(file), str(rows), str(int(time.time())), file.name])
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.open("a", encoding="utf-8") as handle:
            handle.write("\t".join(self.rows[-1]) + "\n")

    def forget(self, target: str) -> None:
        """Drop the receipts of one table."""
        self.rows = [r for r in self.rows if r[0] != target.upper()]
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text("".join("\t".join(r) + "\n" for r in self.rows), encoding="utf-8")

    def match(self, target: str, file: Path) -> int | None:
        """The recorded row count when the newest receipt for the target is this exact file."""
        size = str(file.stat().st_size)
        for row in reversed(self.rows):
            if row[0] == target.upper():
                if row[1] == size and row[2] == _sha256(file):
                    return int(row[3])
                return None
        return None


# --- JSON through the json-tables engine ---------------------------------------------------


def json_tables_bin(ctx: Context) -> Path | None:
    """The exasol-json-tables launcher to use, or None when the add-on is absent."""
    bin_path = Path(ctx.env.get("EXAKIT_JSON_TABLES_BIN") or ctx.paths.bin_dir / "exasol-json-tables")
    return bin_path if bin_path.exists() else None


def normalise_json(path: Path, out_dir: Path) -> Path:
    """One JSON document (or array) to NDJSON; NDJSON stays as it is; malformed raises BadInput."""
    text = path.read_text(encoding="utf-8-sig")
    try:
        doc = json.loads(text)
    except ValueError:
        lines = [line for line in text.splitlines() if line.strip()]
        try:
            for line in lines:
                json.loads(line)
            return path
        except ValueError:
            raise BadInput(f"{path} is not valid JSON") from None
    out = out_dir / (path.stem + ".ndjson")
    with out.open("w", encoding="utf-8") as handle:
        for item in (doc if isinstance(doc, list) else [doc]):
            handle.write(json.dumps(item) + "\n")
    return out


def load_json(ctx: Context, pump: Exapump, path: Path, target: str) -> list[str]:
    """Shred a JSON file into tables with the json-tables engine. Returns the targets loaded."""
    engine = json_tables_bin(ctx)
    if engine is None:
        from .marketplace import install_addon_quietly
        if not install_addon_quietly(ctx, "json-tables") or json_tables_bin(ctx) is None:
            raise Failed("JSON loading needs the JSON Tables add-on, which could not be installed - see: exakit logs setup",
                         remedy="exakit marketplace json-tables")
        engine = json_tables_bin(ctx)
    with tempfile.TemporaryDirectory(prefix="exakit-json-") as tmp:
        work = Path(tmp)
        source = normalise_json(path, work)
        out_dir = work / "out"
        done = ctx.runner.run([str(engine), "ingest", "--input", str(source), "--output-dir", str(out_dir)], timeout=3600)
        ctx.log.line("CMD", f"exasol-json-tables ingest {source.name} -> {done.code}")
        if not done.ok:
            ctx.log.line("ERROR", (done.err or done.out).strip()[-800:])
            raise Failed(f"JSON Tables could not shred {path.name} - see: exakit logs json-tables", remedy="exakit logs json-tables")
        parquets = sorted(out_dir.rglob("*.parquet")) if out_dir.exists() else []
        if not parquets:
            raise Failed(f"JSON Tables produced no tables from {path.name}.")
        schema, _, table = target.rpartition(".")
        ensure_schema_for(ctx, pump, schema)
        targets: list[str] = []
        for parquet in parquets:
            dest = target if len(parquets) == 1 else f"{schema}.{table}_{table_name_from_path(parquet)}"
            if not upload_with_recovery(ctx, pump, parquet, dest):
                raise Failed(f"Could not load {parquet.name} into {dest} - see: exakit logs setup", remedy="exakit logs setup")
            targets.append(dest)
        return targets


def ensure_schema_for(ctx: Context, pump: Exapump, schema: str) -> None:
    """Create the schema when it does not exist."""
    from .data import ensure_schema
    ensure_schema(ctx, pump, schema)


# --- one file ----------------------------------------------------------------------------------


def load_local_path(ctx: Context, path: Path) -> Result:
    """Load a file or a folder the user named; the dispatch behind ``exakit data-load <path>``."""
    if path.is_dir():
        from .data_folder import load_folder
        return load_folder(ctx, path)
    return load_file(ctx, path)


def load_file(ctx: Context, path: Path) -> Result:
    """Load one file into the schema: CSV and Parquet through exapump, JSON through json-tables."""
    pump = exapump(ctx)
    if pump is None:
        raise Failed("exapump (the data-loading CLI) is not installed", remedy="exakit update")
    if not path.is_file() or not path.stat().st_size:
        raise Failed(f"File not found or empty: {path}")
    kind = file_kind(path)
    if kind == "csv" and not path.name.lower().endswith((".csv", ".csv.gz")):
        raise Failed(f"{path.name} looks tabular but exapump reads .csv and .parquet only - rename it to .csv and retry.")
    if kind == "unknown":
        raise Failed(f"{path.name} is not a CSV, Parquet or JSON file the kit can load.")
    schema = (ctx.env.get("EXAKIT_SCHEMA") or ctx.catalog.kit.data_schema).upper()
    default_target = ctx.env.get("EXAKIT_DATA_TABLE") or f"{schema}.{table_name_from_path(path)}"
    target = ctx.ui.prompt("Target table (SCHEMA.TABLE, back to return)", default_target) if ctx.ui.interactive else default_target
    if target.lower() in ("b", "back"):
        return Result(True, "cancelled")
    if not valid_target(target):
        raise BadInput(f"'{target}' is not SCHEMA.TABLE (letters, digits and underscores).")
    target = target.upper()
    if kind == "json":
        targets = load_json(ctx, pump, path, target)
        _record_last_load(ctx, "local_json", ",".join(targets), str(path))
        ctx.ui.ok(f"Loaded {path} into {', '.join(targets)}")
        return Result(True, "loaded", data={"targets": targets})
    info = inspect_csv(path) if kind == "csv" else None
    if kind == "csv" and info is None:
        raise Failed(f"{path.name} has a header and no rows - nothing to load.")
    ensure_schema_for(ctx, pump, target.rpartition(".")[0])
    delimiter = info.delimiter if info else None
    if not upload_with_recovery(ctx, pump, path, target, delimiter=delimiter):
        reason = failure_reason(_log_tail(ctx), delimiter_name=info.delimiter_name if info else "comma", crlf=bool(info and "crlf" in info.flags))
        raise Failed(f"Could not load {path.name} into {target} - {reason}", remedy="exakit logs setup")
    if info and "crlf" in info.flags:
        ctx.ui.warn("The file has Windows line endings, so every value in the last column ends in a carriage return.")
    _record_last_load(ctx, "local_file", target, str(path))
    ctx.ui.ok(f"Loaded {path} into {target}")
    return Result(True, "loaded", data={"targets": [target]})


def _log_tail(ctx: Context) -> str:
    try:
        return ctx.log.path.read_text(encoding="utf-8", errors="replace")[-4000:] if ctx.log.path else ""
    except OSError:
        return ""


def _record_last_load(ctx: Context, kind: str, target: str, source: str, files: int | None = None) -> None:
    def change(m: Manifest) -> None:
        m.set("data.last_load.type", kind)
        m.set("data.last_load.target", target)
        m.set("data.last_load.source", source)
        if files is not None:
            m.set("data.last_load.files", files)
    ctx.manifest_store.update(change)
