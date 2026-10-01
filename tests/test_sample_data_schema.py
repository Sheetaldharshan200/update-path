"""Offline consistency checks for the sample dataset schema and load pipeline.

No database connection required — these guard against the kind of drift a
live smoke test cannot catch quickly: sql/01_create_schema.sql silently
falling out of sync with data/*.csv (column renamed, reordered, or a table
dropped from one side but not the other), or a table losing verification
coverage in sql/03_verify_setup.sql.

Run with: python3 -m unittest discover -s tests -p 'test_*.py'
"""

from __future__ import annotations

import csv
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data" / "datasets" / "tpch" / "data"
SCHEMA_SQL = ROOT / "data" / "datasets" / "tpch" / "01_create_schema.sql"
LOAD_SQL = ROOT / "data" / "datasets" / "tpch" / "02_load_data.sql"
VERIFY_SQL = ROOT / "data" / "datasets" / "tpch" / "03_verify_setup.sql"

# Fixed row counts at TPC-H scale factor 0.02, per data/README.md and
# data/data-dictionary.md. lineitem is generator-dependent (~120K) and is
# checked separately with a bound rather than an exact count.
EXPECTED_ROW_COUNTS = {
    "region": 5,
    "nation": 25,
    "customer": 3000,
    "supplier": 200,
    "part": 4000,
    "partsupp": 16000,
    "orders": 30000,
}

CREATE_TABLE_RE = re.compile(
    r"CREATE OR REPLACE TABLE\s+(\w+)\s*\((.*?)\n\);",
    re.IGNORECASE | re.DOTALL,
)


def _parse_schema_columns() -> dict[str, list[str]]:
    """table_name (lowercase) -> ordered list of column names (lowercase)."""
    sql = SCHEMA_SQL.read_text(encoding="utf-8")
    tables: dict[str, list[str]] = {}
    for match in CREATE_TABLE_RE.finditer(sql):
        table_name = match.group(1).lower()
        body = match.group(2)
        columns = []
        for raw in body.splitlines():
            line = raw.strip().rstrip(",")
            if not line or line.upper().startswith("CONSTRAINT"):
                continue
            columns.append(line.split()[0].lower())
        tables[table_name] = columns
    return tables


def _csv_header(table_name: str) -> list[str]:
    csv_path = DATA_DIR / f"{table_name}.csv"
    with csv_path.open(newline="", encoding="utf-8") as handle:
        return next(csv.reader(handle))


def _function_block(text: str, function_name: str, end_marker: str | None = None) -> str:
    start = text.index(function_name)
    next_function = text.find(end_marker, start + len(function_name)) if end_marker is not None else text.find("\nfunction ", start + len(function_name))
    if next_function == -1:
        next_function = len(text)
    return text[start:next_function]


class SchemaMatchesCsvTests(unittest.TestCase):
    """sql/01_create_schema.sql must declare exactly the columns each CSV has, in order."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.schema_tables = _parse_schema_columns()

    def test_schema_file_declares_every_dataset_table(self) -> None:
        expected_tables = {p.stem for p in DATA_DIR.glob("*.csv")}
        self.assertTrue(expected_tables, "No CSV files found under data/ — dataset missing.")
        missing = expected_tables - set(self.schema_tables)
        self.assertFalse(
            missing,
            f"sql/01_create_schema.sql is missing CREATE TABLE statements for: {sorted(missing)}",
        )

    def test_schema_columns_match_csv_header_order(self) -> None:
        for table_name, schema_columns in self.schema_tables.items():
            csv_path = DATA_DIR / f"{table_name}.csv"
            if not csv_path.exists():
                continue
            with self.subTest(table=table_name):
                csv_columns = [c.lower() for c in _csv_header(table_name)]
                self.assertEqual(
                    schema_columns,
                    csv_columns,
                    f"Column order/names for {table_name} differ between "
                    "sql/01_create_schema.sql and data/{table_name}.csv "
                    "(exapump loads positionally, so this must match exactly).",
                )

    def test_every_table_has_a_primary_key(self) -> None:
        sql = SCHEMA_SQL.read_text(encoding="utf-8").upper()
        for table_name in self.schema_tables:
            with self.subTest(table=table_name):
                self.assertIn(
                    f"{table_name.upper()}_PK",
                    sql,
                    f"Table {table_name} has no PRIMARY KEY constraint declared.",
                )


class RowCountRegressionTests(unittest.TestCase):
    """Catch a truncated or partially-regenerated CSV before it reaches the database."""

    def test_fixed_size_tables_match_expected_row_counts(self) -> None:
        for table_name, expected in EXPECTED_ROW_COUNTS.items():
            csv_path = DATA_DIR / f"{table_name}.csv"
            with self.subTest(table=table_name):
                self.assertTrue(csv_path.exists(), f"{csv_path} is missing.")
                with csv_path.open(newline="", encoding="utf-8") as handle:
                    row_count = sum(1 for _ in handle) - 1  # minus header
                self.assertEqual(
                    row_count,
                    expected,
                    f"{csv_path.name} has {row_count} data rows, expected {expected}.",
                )

    def test_lineitem_row_count_is_within_expected_bounds(self) -> None:
        csv_path = DATA_DIR / "lineitem.csv"
        with csv_path.open(newline="", encoding="utf-8") as handle:
            row_count = sum(1 for _ in handle) - 1
        # 1-7 line items per order, 30000 orders.
        self.assertGreaterEqual(row_count, 30000)
        self.assertLessEqual(row_count, 210000)


class LoadPipelineFilesTests(unittest.TestCase):
    """The loader's three consumed SQL files must exist, be non-empty,
    and 03_verify_setup.sql must not silently drop coverage for a table."""

    def test_all_pipeline_sql_files_exist_and_are_non_empty(self) -> None:
        for path in (SCHEMA_SQL, LOAD_SQL, VERIFY_SQL):
            with self.subTest(path=path):
                self.assertTrue(path.exists(), f"{path} is missing.")
                self.assertGreater(path.stat().st_size, 0, f"{path} is empty.")

    def test_verify_script_checks_every_table(self) -> None:
        verify_sql = VERIFY_SQL.read_text(encoding="utf-8").upper()
        schema_tables = _parse_schema_columns()
        for table_name in schema_tables:
            with self.subTest(table=table_name):
                self.assertIn(
                    table_name.upper(),
                    verify_sql,
                    f"sql/03_verify_setup.sql does not mention table {table_name.upper()} "
                    "— it was likely added to the schema without adding verification coverage.",
                )


if __name__ == "__main__":
    unittest.main()
