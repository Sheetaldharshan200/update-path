"""The frozen contracts, checked against the real CLI in a sandbox.

Every ``--json`` answer is one object on stdout and nothing else; every
state query carries installed, status and remedy; refusals exit 2 with the
refusal object; no install exits 4. The migrated set and the legacy set
cover every command exactly once. Where the legacy CLI is runnable (bash on
the machine), the document surfaces (catalog, help) must agree with it.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from tests.support import MANIFEST, REPO, Sandbox, one_object as _one_object


class StateQueryShapeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.box = Sandbox(manifest=MANIFEST)

    @classmethod
    def tearDownClass(cls):
        cls.box.close()

    def test_persona_list_json(self):
        done = self.box.run("persona", "list", "--json")
        self.assertEqual(done.returncode, 0, done.stderr)
        doc = _one_object(done.stdout)
        self.assertEqual(list(doc)[:3], ["installed", "status", "remedy"])
        self.assertEqual((doc["installed"], doc["status"], doc["remedy"], doc["recorded"]), (True, "none", None, None))
        self.assertEqual([p["id"] for p in doc["personas"]], ["analyst", "data-engineer", "data-scientist", "minimal"])
        self.assertEqual(set(doc["personas"][0]), {"id", "title", "summary", "source", "recorded"})

    def test_persona_plan_json_shape(self):
        done = self.box.run("persona", "plan", "data-scientist", "--json")
        self.assertEqual(done.returncode, 0, done.stderr)
        doc = _one_object(done.stdout)
        for key in ("installed", "status", "remedy", "persona", "datasets", "mcp_clients", "addons", "skills", "pending", "failed"):
            self.assertIn(key, doc)
        self.assertEqual(doc["persona"], {"id": "data-scientist", "title": "Data Scientist", "source": "kit"})
        self.assertEqual(doc["datasets"][0], {"id": "tpch", "state": "done"})
        self.assertEqual({d["id"] for d in doc["datasets"]}, {"tpch", "energy", "weather"})
        self.assertIn(doc["status"], ("pending", "complete"))
        if doc["status"] == "pending":
            self.assertEqual(doc["remedy"], "exakit persona apply data-scientist --yes")
        self.assertTrue(all(s["state"] in ("done", "pending", "skipped") for s in doc["addons"]))

    def test_persona_show_json_is_the_document(self):
        doc = _one_object(self.box.run("persona", "show", "minimal", "--json").stdout)
        self.assertEqual(doc["id"], "minimal")
        self.assertEqual(doc["schema_version"], 1)
        self.assertEqual(doc["source"], "kit")
        self.assertNotIn("installed", doc)

    def test_recorded_persona_is_marked(self):
        box = Sandbox(manifest={**MANIFEST, "persona": {"id": "analyst", "source": "install"}})
        try:
            doc = _one_object(box.run("persona", "list", "--json").stdout)
            self.assertEqual((doc["status"], doc["recorded"]), ("recorded", "analyst"))
            self.assertTrue(next(p for p in doc["personas"] if p["id"] == "analyst")["recorded"])
        finally:
            box.close()

    def test_version_json_shape(self):
        done = self.box.run("version", "--json")
        self.assertEqual(done.returncode, 0, done.stderr)
        doc = _one_object(done.stdout)
        self.assertEqual(list(doc)[:3], ["installed", "status", "remedy"])
        self.assertIn(doc["status"], ("current", "update_pending"))
        self.assertEqual(set(doc) - {"installed", "status", "remedy"}, {"pending", "kit", "versions_source", "components"})
        row = doc["components"][0]
        self.assertEqual(set(row), {"component", "addon", "installed", "installed_label", "advertised", "status",
                                    "remedy", "severity", "note", "platform_note"})
        self.assertEqual(row["component"], "exakit")
        statuses = {"current", "ahead", "unsupported", "unknown", "available", "blocked_on_kit", "missing", "update_available"}
        self.assertTrue(all(r["status"] in statuses for r in doc["components"]))

    def test_whats_new_json(self):
        doc = _one_object(self.box.run("whats-new", "0.3.0", "--json").stdout)
        self.assertEqual(doc["version"], "0.3.0")
        self.assertTrue(doc["notes"])


class RefusalsAndCodesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.box = Sandbox(manifest=MANIFEST)
        cls.empty = Sandbox(manifest=None)

    @classmethod
    def tearDownClass(cls):
        cls.box.close()
        cls.empty.close()

    def test_unknown_persona_is_a_refusal_naming_the_known_ones(self):
        done = self.box.run("persona", "show", "nope", "--json")
        self.assertEqual(done.returncode, 2)
        doc = _one_object(done.stdout)
        self.assertEqual((doc["ok"], doc["rejected"], doc["remedy"]), (False, True, None))
        self.assertIn("analyst", doc["error"])

    def test_bad_option_and_bad_subcommand(self):
        self.assertEqual(self.box.run("version", "--nope").returncode, 2)
        self.assertEqual(self.box.run("persona", "bogus").returncode, 2)
        self.assertEqual(self.box.run("persona", "list", "--yes").returncode, 2)
        self.assertEqual(self.box.run("persona", "show").returncode, 2)

    def test_not_installed_exits_4_with_the_state_shape(self):
        done = self.empty.run("version", "--json")
        self.assertEqual(done.returncode, 4)
        doc = _one_object(done.stdout)
        self.assertEqual((doc["ok"], doc["rejected"]), (False, False))
        self.assertIn("remedy", doc)

    def test_human_refusal_goes_to_stderr_with_nothing_on_stdout(self):
        done = self.box.run("persona", "show", "nope")
        self.assertEqual(done.returncode, 2)
        self.assertEqual(done.stdout, "")
        self.assertIn("Unknown persona", done.stderr)

    def test_help_topic_and_component_pages(self):
        self.assertEqual(self.box.run("mcp").returncode, 0)
        self.assertIn("MCP server", self.box.run("mcp").stdout)
        self.assertIn("persona", self.box.run("persona", "--help").stdout)
        self.assertEqual(self.box.run("help", "--json").returncode, 0)


class PhaseBShapeTest(unittest.TestCase):
    """marketplace --list, uninstall <addon>, persona apply: the shapes and exit codes agents branch on."""

    @classmethod
    def setUpClass(cls):
        doc = {**MANIFEST, "components": {**MANIFEST["components"], "dash_server": {"version": "0.1.1", "port": 5100}}}
        cls.box = Sandbox(manifest=doc)
        bin_dir = Path(cls.box.env["EXAKIT_BIN_DIR"])
        bin_dir.mkdir(exist_ok=True)
        (bin_dir / "dash-server").write_text("#!/bin/sh\n")
        cls.box.env["EXAKIT_MCP_CLIENTS"] = "skip"

    @classmethod
    def tearDownClass(cls):
        cls.box.close()

    def test_marketplace_list_json_is_the_legacy_document(self):
        done = self.box.run("marketplace", "--list", "--json")
        self.assertEqual(done.returncode, 0, done.stderr)
        doc = _one_object(done.stdout)
        self.assertEqual(list(doc), ["addons"])
        rows = {r["id"]: r for r in doc["addons"]}
        self.assertEqual(set(rows), {"dash-server", "dbt-exasol", "exasol-scheduler", "exasol-vscode", "json-tables"})
        self.assertEqual(rows["dash-server"], {"id": "dash-server", "status": "installed", "installed": True, "version": "0.1.1"})
        for row in rows.values():
            self.assertIn(row["status"], ("installed", "available", "managed outside the kit", "not in this kit copy", "not available on this machine"))
            self.assertEqual(row["installed"], row["status"] == "installed")
        self.assertEqual(_one_object(self.box.run("marketplace", "--json").stdout), doc)

    def test_marketplace_without_a_terminal_installs_nothing(self):
        done = self.box.run("marketplace")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("nothing was installed", done.stdout)
        self.assertIn("marketplace --list", done.stdout)

    def test_marketplace_refusals(self):
        self.assertEqual(self.box.run("marketplace", "nope").returncode, 2)
        self.assertEqual(self.box.run("marketplace", "--list", "dash-server").returncode, 2)
        self.assertEqual(self.box.run("marketplace", "--frob").returncode, 2)

    def test_uninstall_one_addon_codes(self):
        self.assertEqual(self.box.run("uninstall", "nope").returncode, 2)
        self.assertEqual(self.box.run("uninstall", "dash-server", "json-tables").returncode, 2)
        not_installed = self.box.run("uninstall", "dbt-exasol")
        self.assertEqual(not_installed.returncode, 0, not_installed.stderr)
        self.assertIn("not installed", not_installed.stdout)
        declined = self.box.run("uninstall", "dash-server", "--json")
        self.assertEqual(declined.returncode, 5)
        doc = _one_object(declined.stdout)
        self.assertEqual((doc["ok"], doc["remedy"]), (False, "exakit uninstall dash-server --yes"))
        dry = self.box.run("uninstall", "dash-server", "--dry-run")
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertIn("will remove", dry.stdout)
        self.assertTrue((Path(self.box.env["EXAKIT_BIN_DIR"]) / "dash-server").exists())

    def test_persona_apply_refuses_without_yes_and_records_nothing(self):
        box = Sandbox(manifest={**MANIFEST, "components": {**MANIFEST["components"], "skills": {"version": "0.0.1"}}})
        box.env["EXAKIT_MCP_CLIENTS"] = "skip"
        box.env["EXAKIT_MARKETPLACE_ADDONS"] = "none"
        try:
            done = box.run("persona", "apply", "minimal", "--json")
            self.assertEqual(done.returncode, 5, done.stdout)
            doc = _one_object(done.stdout)
            self.assertEqual((doc["ok"], doc["remedy"]), (False, "exakit persona apply minimal --yes"))
            self.assertEqual(doc["skills"], [{"id": "skills", "state": "pending"}])
            self.assertNotIn("persona", json.loads((box.home / "manifest.json").read_text()))
        finally:
            box.close()

    def test_persona_apply_complete_records_the_persona(self):
        box = Sandbox(manifest=MANIFEST)
        box.env["EXAKIT_MCP_CLIENTS"] = "skip"
        box.env["EXAKIT_MARKETPLACE_ADDONS"] = "none"
        try:
            done = box.run("persona", "apply", "minimal", "--yes", "--json")
            self.assertEqual(done.returncode, 0, done.stdout)
            doc = _one_object(done.stdout)
            self.assertEqual((doc["installed"], doc["status"], doc["remedy"], doc["pending"]), (True, "complete", None, 0))
            recorded = json.loads((box.home / "manifest.json").read_text())["persona"]
            self.assertEqual((recorded["id"], recorded["source"]), ("minimal", "apply"))
            self.assertEqual(_one_object(box.run("persona", "list", "--json").stdout)["recorded"], "minimal")
        finally:
            box.close()


class StateQueryPhaseCTest(unittest.TestCase):
    """status and info: the tri-state exit code and the keys AGENTS.md promises, against the real CLI."""

    @classmethod
    def setUpClass(cls):
        cls.box = Sandbox(manifest=MANIFEST)
        cls.box.env["EXAKIT_PERSONAL_DEPLOY_DIR"] = str(Path(cls.box.dir) / "no-deployment")
        cls.box.env["PATH"] = str(Path(cls.box.dir) / "empty-path")
        cls.empty = Sandbox(manifest=None)

    @classmethod
    def tearDownClass(cls):
        cls.box.close()
        cls.empty.close()

    def test_status_json_keys_and_exit_3_without_a_database(self):
        done = self.box.run("status", "--json")
        self.assertEqual(done.returncode, 3, done.stderr)
        doc = _one_object(done.stdout)
        self.assertEqual(list(doc)[:3], ["installed", "status", "remedy"])
        self.assertTrue(doc["installed"])
        self.assertIn(doc["status"], ("not deployed", "no database", "stopped"))
        for key in ("installing", "install_step", "runtime", "platform", "wsl_version", "running", "services", "urls", "autostart",
                    "datasets_loaded", "datasets_source", "steps_completed", "steps_missing", "remedies", "remedy_hints",
                    "last_failure", "last_failure_at", "manifest", "persona", "schema_version"):
            self.assertIn(key, doc, key)
        self.assertFalse(doc["running"])
        self.assertEqual(doc["remedy"], doc["remedies"]["database"])
        self.assertEqual(doc["datasets_loaded"], ["tpch"])

    def test_status_human_screen_exit_3(self):
        done = self.box.run("status")
        self.assertEqual(done.returncode, 3, done.stderr)
        self.assertIn("Kit", done.stdout)
        self.assertIn("Data", done.stdout)

    def test_info_json_is_the_record_with_the_state_keys(self):
        done = self.box.run("info", "--json")
        self.assertEqual(done.returncode, 3, done.stderr)
        doc = _one_object(done.stdout)
        self.assertEqual(list(doc)[:3], ["installed", "status", "remedy"])
        self.assertEqual(doc["runtime"]["type"], "personal")
        self.assertEqual(set(doc["skills"]), {"installed_version", "advertised_version", "status", "next"})

    def test_not_installed_state_queries_exit_4_with_installed_false(self):
        for command in (("status", "--json"), ("info", "--json"), ("version", "--json")):
            done = self.empty.run(*command)
            self.assertEqual(done.returncode, 4, command)
            doc = _one_object(done.stdout)
            self.assertEqual((doc["installed"], doc["status"]), (False, "not installed"), command)
            self.assertTrue(doc["remedy"])
        self.assertEqual(self.empty.run("status").returncode, 4)
        self.assertEqual(self.empty.run("status").stdout, "")

    def test_bad_options(self):
        self.assertEqual(self.box.run("status", "--nope").returncode, 2)
        self.assertEqual(self.box.run("autostart", "on").returncode, 2)
        self.assertEqual(self.box.run("start", "--nope").returncode, 2)


class PhaseCCommandsTest(unittest.TestCase):
    """install, uninstall, repair-runtime, migrate, preflight: refusals and read-only answers against the real CLI."""

    @classmethod
    def setUpClass(cls):
        cls.box = Sandbox(manifest=MANIFEST)
        cls.box.env["EXAKIT_PERSONAL_DEPLOY_DIR"] = str(Path(cls.box.dir) / "no-deployment")
        cls.empty = Sandbox(manifest=None)

    @classmethod
    def tearDownClass(cls):
        cls.box.close()
        cls.empty.close()

    def test_install_dry_run_prints_the_plan_and_changes_nothing(self):
        done = self.empty.run("install", "--dry-run")
        self.assertEqual(done.returncode, 0, done.stderr)
        for title in ("Exasol launcher", "Local database deployment", "exapump", "AI bridge", "pyexasol", "exakit helper command"):
            self.assertIn(title, done.stdout)          # the screen names the steps; the ids are the --json contract below
        self.assertFalse((self.empty.home / "manifest.json").exists())

    def test_install_refuses_arguments(self):
        self.assertEqual(self.box.run("install", "--frob").returncode, 2)
        self.assertEqual(self.box.run("install", "now").returncode, 2)

    def test_preflight_is_read_only_and_answers_a_document(self):
        done = self.empty.run("preflight", "--json")
        self.assertIn(done.returncode, (0, 1), done.stderr)
        doc = _one_object(done.stdout)
        self.assertEqual(list(doc)[:3], ["installed", "status", "remedy"])
        self.assertIn(doc["status"], ("ready", "blocked"))
        self.assertIn("failures", doc)
        self.assertFalse((self.empty.home / "manifest.json").exists())

    def test_repair_runtime_declines_with_exit_5_and_the_legacy_keys(self):
        done = self.box.run("repair-runtime", "--json")
        self.assertEqual(done.returncode, 5, done.stdout)
        doc = _one_object(done.stdout)
        self.assertEqual((doc["ok"], doc["status"], doc["changed"], doc["remedy"]), (False, "declined", False, "exakit repair-runtime --yes"))
        self.assertEqual(self.box.run("repair-runtime", "--frob").returncode, 2)
        self.assertEqual(self.empty.run("repair-runtime", "--json").returncode, 4)

    def test_migrate_refusals(self):
        self.assertEqual(self.box.run("migrate").returncode, 2)
        self.assertEqual(self.box.run("migrate", "lxc").returncode, 2)
        self.assertEqual(self.box.run("migrate", "docker-nano", "--password", "x").returncode, 2)
        done = self.box.run("migrate", "docker-nano", "--json")
        self.assertEqual(done.returncode, 3, done.stdout)
        doc = _one_object(done.stdout)
        self.assertEqual((doc["installed"], doc["ok"]), (True, False))
        self.assertIn(doc["status"], ("no container", "no password"))

    def test_uninstall_dry_run_and_refusals(self):
        done = self.box.run("uninstall", "--dry-run")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("Dry run only", done.stdout)
        self.assertTrue((self.box.home / "manifest.json").exists())
        self.assertEqual(self.box.run("uninstall", "--frob").returncode, 2)
        self.assertEqual(self.box.run("uninstall").returncode, 1)
        bare = Sandbox(manifest=None)
        try:
            bare.home.rmdir()
            done = bare.run("uninstall")
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertIn("Nothing to uninstall", done.stdout)
        finally:
            bare.close()


class MigrationSplitTest(unittest.TestCase):
    def test_every_documented_command_has_a_handler(self):
        from exakit.cli.main import HANDLERS
        docs = json.loads((REPO / "help" / "exakit.json").read_text())
        documented = {c["command"].split()[0] for c in docs["commands"]}
        self.assertEqual(documented - set(HANDLERS), set())

    def test_launcher_copies_are_byte_identical(self):
        self.assertEqual((REPO / "setup" / "exakit").read_bytes(), (REPO / "bootstrap" / "exakit").read_bytes())
        self.assertEqual((REPO / "setup" / "exakit.ps1").read_bytes(), (REPO / "bootstrap" / "exakit.ps1").read_bytes())
        self.assertEqual((REPO / "setup" / "exakit.cmd").read_bytes(), (REPO / "bootstrap" / "exakit.cmd").read_bytes())
