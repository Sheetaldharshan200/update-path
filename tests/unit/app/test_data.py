import unittest
from pathlib import Path

from exakit.adapters.process.runner import Completed
from exakit.app import data, data_files, data_folder
from exakit.domain.errors import BadInput, Failed
from tests.unit.app.harness import MANIFEST, Sandbox
from tests.unit.fakes import FakeExapump, FakeRuntime

LISTING_EMPTY = Completed(0, "EXAKIT.LISTING_ANSWERED|1\n", "")


def _listing(rows: dict[str, int]) -> Completed:
    return Completed(0, "EXAKIT.LISTING_ANSWERED|1\n" + "".join(f"{k}|{v}\n" for k, v in rows.items()), "")


def _box(pump: FakeExapump, **kw) -> Sandbox:
    box = Sandbox(manifest=MANIFEST, **kw)
    box.ctx.exapump = pump
    box.ctx.runtime = FakeRuntime()
    return box


class BundledTest(unittest.TestCase):
    def test_bundled_datasets_in_order(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            found = data.bundled(box.ctx)
            self.assertEqual([d.id for d in found], ["tpch", "energy", "weather"])
            self.assertEqual(found[0].flag, "data.loaded")
            self.assertEqual(found[1].flag, "data.datasets.energy.loaded")
            self.assertEqual(found[0].markers, ("CUSTOMER", "ORDERS", "LINEITEM"))
            with self.assertRaises(BadInput):
                data.dataset(box.ctx, "nope")
        finally:
            box.close()

    def test_loaded_asks_the_database_and_heals_the_manifest(self):
        pump = FakeExapump([("LISTING_ANSWERED", _listing({"TPCH.CUSTOMER": 1, "TPCH.ORDERS": 1, "TPCH.LINEITEM": 1, "ENERGY.ENERGY_METERS": 50}))])
        box = _box(pump)
        try:
            self.assertEqual(data.loaded(box.ctx), {"tpch"})
            m = box.manifest()
            self.assertTrue(m.get("data.loaded"))
            self.assertFalse(m.get("data.datasets.energy.loaded"))
            self.assertEqual([d.id for d in data.pending(box.ctx)], ["energy", "weather"])
        finally:
            box.close()

    def test_loaded_falls_back_to_the_manifest_when_the_database_is_silent(self):
        box = _box(FakeExapump(default=Completed(1, "", "refused")))
        try:
            self.assertEqual(data.loaded(box.ctx), {"tpch"})
        finally:
            box.close()


class LoadTest(unittest.TestCase):
    def _pump(self, verify="CHECK,OK,fine\n"):
        return FakeExapump([
            ("LISTING_ANSWERED", LISTING_EMPTY),
            ("EXA_ALL_SCHEMAS", Completed(0, "EXAKIT_SCHEMA_PRESENT", "")),
            ("EXAKIT_RC[", Completed(0, "EXAKIT_RC[10]", "")),
            ("STATUS", Completed(0, verify, "")),
        ])

    def test_load_runs_schema_uploads_statements_verify_and_records(self):
        pump = self._pump()
        box = _box(pump)
        try:
            result = data.load(box.ctx, data.dataset(box.ctx, "weather"))
            self.assertEqual(result.status, "loaded")
            self.assertEqual(len(pump.uploads), 2)
            self.assertEqual({u[1] for u in pump.uploads}, {"WEATHER.WEATHER_CITIES", "WEATHER.WEATHER_DAILY"})
            m = box.manifest()
            self.assertTrue(m.get("data.datasets.weather.loaded"))
            self.assertEqual(m.get("data.datasets.weather.tables"), 2)
            self.assertEqual(m.get("data.datasets.weather.rows"), 20)
            self.assertEqual(m.get("data.last_load.source"), "dataset:weather")
            self.assertIn("Dataset 'weather' loaded and verified - 2 tables, 20 rows", box.screen())
        finally:
            box.close()

    def test_verification_failure_is_reported_and_not_marked(self):
        box = _box(self._pump(verify="CHECK,FAIL,bad\n"))
        try:
            with self.assertRaises(Failed) as ctx:
                data.load(box.ctx, data.dataset(box.ctx, "weather"))
            self.assertIn("--force", str(ctx.exception))
            self.assertFalse(box.manifest().get("data.datasets.weather.loaded"))
        finally:
            box.close()

    def test_already_loaded_skips_unless_forced(self):
        pump = FakeExapump([("LISTING_ANSWERED", _listing({"WEATHER.WEATHER_CITIES": 10, "WEATHER.WEATHER_DAILY": 10}))])
        box = _box(pump)
        try:
            self.assertEqual(data.load(box.ctx, data.dataset(box.ctx, "weather")).status, "already loaded")
            self.assertEqual(pump.uploads, [])
        finally:
            box.close()


class CommandTest(unittest.TestCase):
    def test_env_datasets_and_force(self):
        pump = FakeExapump([("LISTING_ANSWERED", LISTING_EMPTY), ("EXA_ALL_SCHEMAS", Completed(0, "EXAKIT_SCHEMA_PRESENT", "")),
                            ("EXAKIT_RC[", Completed(0, "EXAKIT_RC[1]", "")), ("STATUS", Completed(0, "x,OK,y", ""))])
        box = _box(pump, env={"EXAKIT_DATASETS": "weather,nope"})
        try:
            result = data.data_load(box.ctx, [])
            self.assertEqual(result.status, "loaded")
            self.assertEqual({u[1] for u in pump.uploads}, {"WEATHER.WEATHER_CITIES", "WEATHER.WEATHER_DAILY"})
            with self.assertRaises(BadInput):
                data.data_load(box.ctx, ["--nope"])
        finally:
            box.close()

    def test_non_interactive_menu_loads_pending_defaults(self):
        pump = FakeExapump([("LISTING_ANSWERED", _listing({"TPCH.CUSTOMER": 1, "TPCH.ORDERS": 1, "TPCH.LINEITEM": 1})),
                            ("EXA_ALL_SCHEMAS", Completed(0, "EXAKIT_SCHEMA_PRESENT", "")),
                            ("EXAKIT_RC[", Completed(0, "EXAKIT_RC[1]", "")), ("STATUS", Completed(0, "x,OK,y", ""))])
        box = _box(pump)
        try:
            data.data_load(box.ctx, [])
            targets = {u[1].split(".")[0] for u in pump.uploads}
            self.assertEqual(targets, {"ENERGY", "WEATHER"})
        finally:
            box.close()


class FilesTest(unittest.TestCase):
    def test_table_names_and_kinds(self):
        self.assertEqual(data_files.table_name_from_path(Path("Sales Data-2024.csv")), "SALES_DATA_2024")
        self.assertEqual(data_files.table_name_from_path(Path("x.csv.gz")), "X_CSV")
        self.assertEqual(data_files.table_name_from_path(Path("__.csv")), "MY_TABLE")
        self.assertEqual(data_files.file_kind(Path("a.GeoJSON")), "json")
        self.assertEqual(data_files.file_kind(Path("a.parquet")), "parquet")
        self.assertEqual(data_files.file_kind(Path("a.csv.gz")), "csv")
        self.assertEqual(data_files.file_kind(Path("a.png")), "unknown")

    def test_inspect_csv(self):
        box = Sandbox()
        try:
            p = Path(box.tmp.name) / "a.csv"
            p.write_bytes(b"\xef\xbb\xbfa;b\r\n1;2\r\n")
            info = data_files.inspect_csv(p)
            self.assertEqual((info.delimiter, info.flags), (";", ("bom", "crlf")))
            p.write_bytes(b"a\tb\n1\t2\n")
            self.assertEqual(data_files.inspect_csv(p).delimiter, "\t")
            p.write_bytes(b"a,b\n")
            self.assertIsNone(data_files.inspect_csv(p))
        finally:
            box.close()

    def test_scan_folder_classifies_files(self):
        box = Sandbox()
        try:
            folder = Path(box.tmp.name) / "f"
            (folder / "sub").mkdir(parents=True)
            (folder / "aaa.csv").write_text("a,b\n1,2\n")
            (folder / "sales.csv").write_text("a,b\n1,2\n")
            (folder / "orders.csv").write_text("x,y\n3,4\n")
            (folder / "orders.parquet").write_bytes(b"PAR1xxxx")
            (folder / "empty.csv").write_text("")
            (folder / "head.csv").write_text("a,b\n")
            (folder / "stops.txt").write_text("a,b\n1,2\n")
            (folder / "readme.txt").write_text("hello\n")
            (folder / "pic.png").write_bytes(b"x")
            (folder / ".hidden.csv").write_text("a\n1\n")
            (folder / "sub" / "inner.csv").write_text("a\n1\n")
            entries = {e.path.name: e for e in data_folder.scan_folder(folder)}
            self.assertEqual(entries["aaa.csv"].action, "load")
            self.assertEqual((entries["sales.csv"].kind, entries["sales.csv"].table), ("duplicate-content", "aaa.csv"))
            self.assertEqual(entries["orders.csv"].action, "load")
            self.assertEqual((entries["orders.parquet"].kind, entries["orders.parquet"].table), ("duplicate-table", "orders.csv"))
            self.assertEqual(entries["empty.csv"].kind, "empty")
            self.assertEqual(entries["head.csv"].kind, "header-only")
            self.assertEqual(entries["stops.txt"].kind, "extension")
            self.assertEqual(entries["readme.txt"].kind, "unsupported")
            self.assertEqual(entries["pic.png"].kind, "unsupported")
            self.assertNotIn(".hidden.csv", entries)
            self.assertNotIn("inner.csv", entries)
        finally:
            box.close()

    def test_receipts_and_decisions(self):
        box = Sandbox()
        try:
            f = Path(box.tmp.name) / "sales.csv"
            f.write_text("a,b\n1,2\n")
            receipts = data_files.Receipts.load(Path(box.tmp.name) / "receipts.tsv")
            entry = data_folder.ScanEntry("load", "csv", "SALES", f)
            inflight = Path(box.tmp.name) / "inflight"
            self.assertEqual(data_folder._decide(entry, "S", None, receipts, inflight), ("load", "unknown"))
            self.assertEqual(data_folder._decide(entry, "S", {}, receipts, inflight), ("load", "absent"))
            self.assertEqual(data_folder._decide(entry, "S", {"S.SALES": 0}, receipts, inflight), ("load", "0"))
            self.assertEqual(data_folder._decide(entry, "S", {"S.SALES": 5}, receipts, inflight), ("clash", "5"))
            receipts.record("S.SALES", f, 5)
            self.assertEqual(data_folder._decide(entry, "S", {"S.SALES": 5}, receipts, inflight), ("done", "5"))
            self.assertEqual(data_folder._decide(entry, "S", {"S.SALES": 7}, receipts, inflight), ("clash", "7"))
            inflight.write_text("S.SALES")
            self.assertEqual(data_folder._decide(entry, "S", {"S.SALES": 7}, receipts, inflight), ("resume", "7"))
            receipts.forget("S.SALES")
            self.assertEqual(receipts.rows, [])
        finally:
            box.close()

    def test_pieces_keep_the_header_and_even_quotes(self):
        box = Sandbox()
        try:
            f = Path(box.tmp.name) / "big.csv"
            rows = ["h1,h2"] + [f'{i},"multi\nline"' if i % 7 == 0 else f"{i},v{i}" for i in range(200)]
            f.write_text("\n".join(rows) + "\n")
            pieces = data_files._split_pieces(f, 400, Path(box.tmp.name))
            self.assertGreater(len(pieces), 1)
            body = ""
            for piece in pieces:
                text = piece.read_text()
                self.assertTrue(text.startswith("h1,h2\n"))
                self.assertEqual(text.count('"') % 2, 0)
                body += text[len("h1,h2\n"):]
            self.assertEqual(body, "\n".join(rows[1:]) + "\n")
        finally:
            box.close()

    def test_upload_recovery_retries_only_cut_transfers(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            f = Path(box.tmp.name) / "a.csv"
            f.write_text("a\n1\n")
            pump = FakeExapump(default=Completed(1, "Error: ETL-5105 transfer closed", ""))
            box.env["EXAKIT_UPLOAD_RETRIES"] = "1"
            self.assertFalse(data_files.upload_with_recovery(box.ctx, pump, f, "S.A"))
            self.assertEqual(len(pump.uploads), 2)
            pump = FakeExapump(default=Completed(1, "Error: parse error row=3", ""))
            self.assertFalse(data_files.upload_with_recovery(box.ctx, pump, f, "S.A"))
            self.assertEqual(len(pump.uploads), 1)
        finally:
            box.close()

    def test_load_folder_end_to_end(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            folder = Path(box.tmp.name) / "exports"
            folder.mkdir()
            (folder / "sales.csv").write_text("a,b\n1,2\n")
            (folder / "orders.csv").write_text("a;b\n1;2\n")
            listing_after = _listing({"STARTER_KIT.SALES": 1, "STARTER_KIT.ORDERS": 1})

            class StatefulPump(FakeExapump):
                listings = 0

                def sql(self, profile, text, **kw):
                    if "LISTING_ANSWERED" in text:
                        self.listings += 1
                        return LISTING_EMPTY if self.listings == 1 else listing_after
                    return super().sql(profile, text, **kw)

            pump = StatefulPump([("EXA_ALL_SCHEMAS", Completed(0, "EXAKIT_SCHEMA_PRESENT", ""))])
            box.ctx.exapump = pump
            box.ctx.runtime = FakeRuntime()
            result = data_folder.load_folder(box.ctx, folder)
            self.assertEqual(result.status, "loaded")
            self.assertEqual({(u[1], u[3]) for u in pump.uploads}, {("STARTER_KIT.SALES", ","), ("STARTER_KIT.ORDERS", ";")})
            self.assertIn("STARTER_KIT: 2 files loaded", box.screen())
            m = box.manifest()
            self.assertEqual(m.get("data.last_load.type"), "local_folder")
            self.assertEqual(m.get("data.last_load.files"), 2)
            receipts = data_files.Receipts.load(box.ctx.paths.cache / "load-receipts.tsv")
            self.assertEqual({r[0] for r in receipts.rows}, {"STARTER_KIT.SALES", "STARTER_KIT.ORDERS"})
            box.out.truncate(0)
            box.out.seek(0)
            pump.uploads.clear()
            result = data_folder.load_folder(box.ctx, folder)
            self.assertEqual(pump.uploads, [])
            self.assertIn("already holds every file", box.screen())
        finally:
            box.close()

    def test_clash_without_terminal_skips(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            folder = Path(box.tmp.name) / "exports"
            folder.mkdir()
            (folder / "sales.csv").write_text("a,b\n1,2\n")
            pump = FakeExapump([("EXA_ALL_SCHEMAS", Completed(0, "EXAKIT_SCHEMA_PRESENT", "")), ("LISTING_ANSWERED", _listing({"STARTER_KIT.SALES": 9}))])
            box.ctx.exapump = pump
            data_folder.load_folder(box.ctx, folder)
            self.assertEqual(pump.uploads, [])
            self.assertIn("not loaded: the table already holds rows this kit did not put there", box.screen())
            self.assertIn("already holds every file", box.screen())
            box.env["EXAKIT_ON_EXISTING"] = "replace"
            data_folder.load_folder(box.ctx, folder)
            self.assertTrue(any("DROP TABLE IF EXISTS STARTER_KIT.SALES" in t for _, t in pump.calls))
            self.assertEqual(len(pump.uploads), 1)
        finally:
            box.close()


if __name__ == "__main__":
    unittest.main()
