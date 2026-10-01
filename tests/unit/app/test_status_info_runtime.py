"""status, info, start, stop, autostart over a fake runtime: every state the JSON and the exit code distinguish."""

from __future__ import annotations

import unittest
from unittest import mock

from exakit.adapters.process.services import RegisterOutcome
from exakit.app import info, runtime as runtime_app, status
from exakit.domain.errors import BadInput, Failed, NotInstalled
from tests.unit.app.harness import MANIFEST, Sandbox
from tests.unit.fakes import FakeRuntime


class FakeServices:
    def __init__(self) -> None:
        self.ids: set[str] = set()

    def register(self, spec):
        self.ids.add(spec.id)
        return RegisterOutcome(True, ())

    def unregister(self, service_id):
        return bool(self.ids.discard(service_id) is None and True)

    def registered(self, service_id):
        return service_id in self.ids


def box_with(state: str = "running", manifest: dict | None = None, **kw) -> Sandbox:
    box = Sandbox(manifest=manifest or MANIFEST, **kw)
    box.ctx.runtime = FakeRuntime(state)
    box.ctx.services = FakeServices()
    return box


class StatusJsonTest(unittest.TestCase):
    def test_not_installed_is_exit_4_with_the_state_keys(self):
        box = Sandbox(json_mode=True)
        try:
            with self.assertRaises(NotInstalled) as caught:
                status.run(box.ctx)
            doc = caught.exception.refusal()
            self.assertEqual(list(doc)[:3], ["installed", "status", "remedy"])
            self.assertEqual((doc["installed"], doc["status"], doc["reason"], doc["platform"]), (False, "not installed", "no install record", "macos"))
            self.assertEqual(doc["remedy"], box.ctx.install_command())
        finally:
            box.close()

    def test_running_is_exit_0_with_no_remedy_and_the_documented_keys(self):
        box = box_with("running", json_mode=True)
        try:
            with mock.patch("exakit.app.status.data.listing", lambda ctx: {"TPCH.LINEITEM": 5}), \
                 mock.patch("exakit.app.status.data.loaded", lambda ctx, tables, heal: {"tpch"}):
                result = status.run(box.ctx)
            self.assertEqual((result.status, result.exit_code, result.remedy), ("running", 0, None))
            for key in ("installing", "install_step", "kit_level", "runtime", "platform", "wsl_version", "running", "services", "urls",
                        "autostart", "datasets_loaded", "datasets_source", "steps_completed", "steps_missing", "pyexasol", "remedies",
                        "remedy_hints", "last_failure", "last_failure_at", "manifest", "persona", "schema_version"):
                self.assertIn(key, result.data, key)
            self.assertEqual((result.data["datasets_loaded"], result.data["datasets_source"]), (["tpch"], "database"))
            self.assertEqual(result.data["runtime"], {"type": "personal", "status": "running"})
            self.assertEqual(result.data["remedies"], {"pyexasol": "exakit update"})
            self.assertEqual(result.data["steps_missing"], [])
        finally:
            box.close()

    def test_stopped_names_start_and_falls_back_to_the_manifest_for_datasets(self):
        box = box_with("stopped", json_mode=True)
        try:
            result = status.run(box.ctx)
            self.assertEqual((result.status, result.exit_code, result.remedy), ("stopped", 3, "exakit start"))
            self.assertEqual((result.data["datasets_loaded"], result.data["datasets_source"]), (["tpch"], "manifest"))
        finally:
            box.close()

    def test_each_runtime_state_has_its_own_remedy(self):
        expect = {"interrupted": "exakit repair-runtime", "not deployed": "exakit repair-runtime", "conflict": "exakit start"}
        for state, remedy in expect.items():
            box = box_with(state, json_mode=True)
            try:
                result = status.run(box.ctx)
                self.assertEqual((result.status, result.exit_code, result.data["remedies"]["database"]), (state, 3, remedy), state)
                if state == "conflict":
                    self.assertIn("another process", result.data["remedy_hints"]["database"])
            finally:
                box.close()

    def test_no_runtime_recorded_is_no_database_with_the_installer_as_remedy(self):
        doc = {**MANIFEST, "runtime": {}}
        box = box_with("running", manifest=doc, json_mode=True)
        try:
            result = status.run(box.ctx)
            self.assertEqual((result.status, result.exit_code), ("no database", 3))
            self.assertEqual(result.remedy, box.ctx.install_command())
            self.assertEqual(result.data["runtime"], {"type": None, "status": "not installed"})
        finally:
            box.close()

    def test_installing_while_the_lock_holder_lives_and_dead_installer_afterwards(self):
        doc = {**MANIFEST, "install": {"current_step": "mcp"}}
        box = box_with("running", manifest=doc, json_mode=True)
        try:
            with mock.patch("exakit.app.status.lock_holder_alive", lambda path, runner: True):
                result = status.run(box.ctx)
            self.assertEqual((result.status, result.exit_code, result.remedy), ("installing", 3, "exakit status --json"))
            self.assertTrue(result.data["installing"])
            with mock.patch("exakit.app.status.lock_holder_alive", lambda path, runner: False):
                result = status.run(box.ctx)
            self.assertEqual((result.status, result.exit_code, result.data["installing"], result.data["install_step"]), ("running", 0, False, "mcp"))
            self.assertEqual(result.remedy, box.ctx.install_command())
            self.assertIn("died at step 'mcp'", result.data["remedy_hints"]["install"])
        finally:
            box.close()

    def test_unfinished_steps_name_their_repair(self):
        doc = {**MANIFEST, "steps_completed": ["launcher", "runtime", "exapump"]}
        box = box_with("running", manifest=doc, json_mode=True)
        try:
            result = status.run(box.ctx)
            self.assertEqual(result.data["steps_missing"], ["mcp", "pyexasol", "exakit_helper"])
            self.assertEqual(result.data["remedies"]["mcp"], "exakit mcp-setup")
            self.assertEqual(result.data["remedies"]["exakit_helper"], box.ctx.install_command())
            self.assertEqual((result.remedy, result.exit_code), ("exakit mcp-setup", 0))
        finally:
            box.close()

    def test_failure_note_and_legacy_database_ride_along(self):
        doc = {**MANIFEST, "legacy": {"container": "exasol-nano", "engine": "docker", "choice": "skip"}}
        box = box_with("running", manifest=doc, json_mode=True)
        try:
            box.ctx.paths.failure_note.write_text("the AI client configuration did not finish\n2026-09-30T10:00:00Z\n")
            result = status.run(box.ctx)
            self.assertEqual((result.data["last_failure"], result.data["last_failure_at"]),
                             ("the AI client configuration did not finish", "2026-09-30T10:00:00Z"))
            self.assertEqual(result.data["legacy_database"]["command"], "exakit migrate docker-nano")
            self.assertFalse(result.data["legacy_database"]["copied"])
            self.assertTrue(box.ctx.paths.failure_note.exists(), "a read-only query never touches the note")
        finally:
            box.close()


class StatusScreenTest(unittest.TestCase):
    def test_four_panels_and_the_next_step(self):
        doc = {**MANIFEST, "components": {**MANIFEST["components"], "mcp_server": {"version": "2.2.0", "client_setup": {"configured_clients": ["claude_code"]}},
                                            "pyexasol": {"validated": True}},
               "data": {"loaded": True, "datasets": {"tpch": {"loaded": True, "schema": "TPCH", "tables": 8, "rows": 1234}}}}
        box = box_with("stopped", manifest=doc)
        try:
            status.run(box.ctx)
            screen = box.screen()
            for word in ("Kit", "Add-ons", "AI clients (MCP)", "Data", "personal · stopped", "not reachable", "Claude Code (CLI) configured",
                         "8 tables, 1,234 rows", "available         dash-server", "Missing:     pyexasol  repair: exakit update", "Start it:    exakit start"):
                self.assertIn(word, screen, word)
        finally:
            box.close()


class InfoTest(unittest.TestCase):
    def test_json_is_the_record_plus_the_state_keys(self):
        box = box_with("stopped", json_mode=True)
        try:
            result = info.run(box.ctx)
            self.assertEqual((result.status, result.remedy, result.exit_code), ("stopped", "exakit start", 3))
            self.assertEqual(result.data["database"], "not running")
            self.assertEqual(result.data["runtime"]["dsn"], "127.0.0.1:8563")
            self.assertEqual(result.data["skills"]["installed_version"], "1.12.2")
            self.assertIn(result.data["skills"]["status"], ("current", "update_pending"))
            box.ctx.runtime = FakeRuntime("running")
            self.assertEqual(info.run(box.ctx).exit_code, 0)
        finally:
            box.close()

    def test_no_runtime_is_no_database(self):
        box = box_with("running", manifest={**MANIFEST, "runtime": {}}, json_mode=True)
        try:
            result = info.run(box.ctx)
            self.assertEqual((result.status, result.remedy), ("no database", box.ctx.install_command()))
        finally:
            box.close()

    def test_screen_names_the_files_without_the_password(self):
        doc = {**MANIFEST, "runtime": {**MANIFEST["runtime"], "password_file": "/u/creds/sys_password"}}
        box = box_with("running", manifest=doc)
        try:
            info.run(box.ctx)
            screen = box.screen()
            for word in ("Setup details", "DSN:          127.0.0.1:8563", "Admin pass:   /u/creds/sys_password", "TLS:          enabled",
                         "Skills:       1.12.2", "exakit info --json", "Guide:        exakit guide"):
                self.assertIn(word, screen, word)
        finally:
            box.close()


class StartStopTest(unittest.TestCase):
    def test_start_when_running_says_so_and_clears_a_runtime_note(self):
        box = box_with("running")
        try:
            box.ctx.paths.failure_note.write_text("Port 8563 is held by another process\n2026\n")
            result = runtime_app.start(box.ctx)
            self.assertEqual(result.status, "running")
            self.assertIn("Database is already running", box.screen())
            self.assertFalse(box.ctx.paths.failure_note.exists())
            self.assertEqual(box.manifest().get("runtime.status"), "running")
        finally:
            box.close()

    def test_start_when_stopped_starts_and_when_starting_waits(self):
        box = box_with("stopped")
        try:
            runtime_app.start(box.ctx)
            self.assertEqual(box.ctx.runtime.started, 1)
        finally:
            box.close()
        box = box_with("starting")
        try:
            runtime_app.start(box.ctx)
            self.assertEqual(box.ctx.runtime.started, 0)
            self.assertIn("already starting", box.screen())
        finally:
            box.close()

    def test_conflict_reaps_our_orphan_or_refuses_a_foreign_holder(self):
        box = box_with("conflict")
        try:
            box.ctx.runtime.reap_ok = True
            runtime_app.start(box.ctx)
            self.assertEqual((box.ctx.runtime.reaped, box.ctx.runtime.started), (1, 1))
        finally:
            box.close()
        box = box_with("conflict")
        try:
            with self.assertRaises(Failed) as caught:
                runtime_app.start(box.ctx)
            self.assertIn("not by Exasol", caught.exception.message)
            self.assertEqual(box.ctx.runtime.started, 0)
        finally:
            box.close()

    def test_stop_stops_the_database_and_records_it(self):
        box = box_with("running")
        try:
            result = runtime_app.stop(box.ctx)
            self.assertEqual((result.status, box.ctx.runtime.stopped), ("stopped", 1))
            self.assertEqual(box.manifest().get("runtime.status"), "stopped")
        finally:
            box.close()


class AutostartTest(unittest.TestCase):
    def test_arguments_are_refused(self):
        box = box_with("running")
        try:
            with self.assertRaises(BadInput):
                runtime_app.autostart(box.ctx, ["on"])
        finally:
            box.close()

    def test_env_answer_turns_it_on_then_off(self):
        box = box_with("running", env={"EXAKIT_AUTOSTART_CHANGE": "yes"})
        try:
            result = runtime_app.autostart(box.ctx, [])
            self.assertEqual(result.status, "enabled")
            self.assertTrue(box.ctx.services.registered("database"))
            self.assertIs(box.manifest().get("autostart.enabled"), True)
            self.assertIn("database  disabled", box.screen())
            result = runtime_app.autostart(box.ctx, [])
            self.assertEqual(result.status, "disabled")
            self.assertFalse(box.ctx.services.registered("database"))
            self.assertIn("database  enabled", box.screen())
        finally:
            box.close()

    def test_without_an_answer_nothing_changes(self):
        box = box_with("running")
        try:
            result = runtime_app.autostart(box.ctx, [])
            self.assertEqual(result.status, "disabled")
            self.assertFalse(box.ctx.services.registered("database"))
            self.assertIsNone(box.manifest().get("autostart.enabled"))
        finally:
            box.close()
