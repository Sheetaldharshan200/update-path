import json
import unittest

from exakit.adapters.process.runner import Completed
from exakit.app import logs, sql
from exakit.domain.errors import BadInput, Failed, NotRunning
from tests.unit.app.harness import MANIFEST, Sandbox
from tests.unit.fakes import FakeExapump


class SqlParsingTest(unittest.TestCase):
    def test_options_and_statement_forms(self):
        self.assertEqual(sql.parse_args(["SELECT 1"]).statement, "SELECT 1")
        self.assertEqual(sql.parse_args(["--", "-- leading comment\nSELECT 1"]).statement, "-- leading comment\nSELECT 1")
        parsed = sql.parse_args(["--write", "--json", "INSERT INTO t VALUES (1)"])
        self.assertTrue(parsed.write)
        self.assertEqual(sql.parse_args(["--file", "q.sql"]).file, "q.sql")
        self.assertEqual(sql.parse_args(["--file=q.sql"]).file, "q.sql")

    def test_rejections(self):
        for bad in (["--nope"], ["a", "b"], ["--file"], ["--file", "x", "SELECT 1"]):
            with self.assertRaises(BadInput):
                sql.parse_args(bad)

    def test_clean_strips_comments_and_trailing_semicolon(self):
        self.assertEqual(sql.clean("-- c\n\nSELECT 1;\n"), "SELECT 1")

    def test_read_only_rule(self):
        for ok in ("SELECT 1", "with x as (select 1) select * from x", "DESCRIBE t", "EXPLAIN SELECT 1"):
            sql.check_read_only(ok)
        with self.assertRaises(BadInput) as ctx:
            sql.check_read_only("INSERT INTO t VALUES (1)")
        self.assertIn("--write", str(ctx.exception))
        with self.assertRaises(BadInput):
            sql.check_read_only("frobnicate")
        with self.assertRaises(BadInput):
            sql.check_read_only("SELECT 1; SELECT 2")

    def test_remedies(self):
        lines, cmd = sql.remedy_lines("Error: connection refused", "SELECT 1")
        self.assertEqual(cmd, "exakit start")
        lines, cmd = sql.remedy_lines("TLS handshake failed", "SELECT 1")
        self.assertEqual(cmd, "exakit status")
        lines, _ = sql.remedy_lines("syntax error", "SELECT TOP 5 * FROM t")
        self.assertTrue(any("LIMIT" in line for line in lines))
        lines, _ = sql.remedy_lines("object FOO not found", "SELECT * FROM STARTER_KIT.FOO")
        self.assertEqual(len(lines), 2)
        lines, _ = sql.remedy_lines("insufficient privileges", "DROP TABLE x")
        self.assertTrue(any("--write" in line for line in lines))
        self.assertEqual(sql.remedy_lines("fine", "SELECT 1"), ([], None))

    def test_error_detail(self):
        self.assertEqual(sql.error_detail("noise\nError: boom (Session: 1)"), "boom (Session: 1)")
        self.assertEqual(sql.error_detail("Hint: x\nquery failed here"), "query failed here")


class SqlRunTest(unittest.TestCase):
    def test_json_success_and_failure_shapes(self):
        box = Sandbox(manifest=MANIFEST, json_mode=True)
        try:
            box.ctx.exapump = FakeExapump(default=Completed(0, '[{"A": 1}]', ""))
            doc = json.loads(sql.run(box.ctx, ["SELECT 1"]).to_json())
            self.assertEqual(doc, {"ok": True, "rows": [{"A": 1}], "row_count": 1})
            box.ctx.exapump = FakeExapump(default=Completed(1, "Error: connection refused", ""))
            result = sql.run(box.ctx, ["SELECT 1"])
            doc = json.loads(result.to_json())
            self.assertEqual((doc["ok"], doc["remedy"]), (False, "exakit start"))
            self.assertIn("exakit start", doc["remedy_hint"])
            self.assertEqual(result.exit_code, 1)
        finally:
            box.close()

    def test_human_failure_prints_remedy_lines_first(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            box.ctx.exapump = FakeExapump(default=Completed(1, "Error: connection refused\nHint: ignore me", ""))
            result = sql.run(box.ctx, ["SELECT 1"])
            self.assertEqual(result.exit_code, 1)
            screen = box.screen()
            self.assertTrue(screen.startswith("! That is the database not answering"))
            self.assertNotIn("Hint: ignore me", screen)
        finally:
            box.close()

    def test_missing_exapump_is_not_running_with_update_remedy(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            with self.assertRaises(NotRunning) as ctx:
                sql.run(box.ctx, ["SELECT 1"])
            self.assertEqual(ctx.exception.remedy, "exakit update")
        finally:
            box.close()

    def test_write_bypasses_the_read_check(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            pump = FakeExapump()
            box.ctx.exapump = pump
            sql.run(box.ctx, ["--write", "CREATE SCHEMA X"])
            self.assertEqual(pump.calls[-1], ("starter-kit", "CREATE SCHEMA X"))
        finally:
            box.close()


class LogsTest(unittest.TestCase):
    def test_targets_and_json_listing(self):
        box = Sandbox(manifest=MANIFEST, json_mode=True)
        try:
            box.ctx.paths.logs.mkdir()
            (box.ctx.paths.logs / "install-20260930-100000.log").write_text("one\n")
            (box.ctx.paths.logs / "autostart-database.log").write_text("")
            doc = json.loads(logs.run(box.ctx, []).to_json())
            self.assertEqual(doc["count"], 2)
            self.assertEqual([t["target"] for t in doc["targets"]], ["setup", "autostart-database"])
            self.assertEqual(set(doc["targets"][0]), {"target", "what", "kind", "path", "command", "size", "updated"})
        finally:
            box.close()

    def test_target_options_and_refusals(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            box.ctx.paths.logs.mkdir()
            log = box.ctx.paths.logs / "install-20260930-100000.log"
            log.write_text("a\nb\nc\n")
            logs.run(box.ctx, ["setup", "--lines", "2"])
            self.assertEqual(box.screen().strip().splitlines(), ["b", "c"])
            box.out.truncate(0)
            box.out.seek(0)
            logs.run(box.ctx, ["setup", "--path"])
            self.assertEqual(box.screen().strip(), str(log))
            for bad in (["--lines", "x"], ["a", "b"], ["--nope"]):
                with self.assertRaises(BadInput):
                    logs.run(box.ctx, bad)
            with self.assertRaises(Failed):
                logs.run(box.ctx, ["nothing"])
            with self.assertRaises(Failed) as ctx:
                logs.run(box.ctx, ["dash-server"])
            self.assertEqual(ctx.exception.remedy, "exakit marketplace dash-server")
        finally:
            box.close()


if __name__ == "__main__":
    unittest.main()
