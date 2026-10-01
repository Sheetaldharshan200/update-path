"""The add-on lifecycles: which one answers for each add-on, and the machine-free parts of their behaviour."""

from __future__ import annotations

import os
import unittest
from unittest import mock

from exakit.addons import dash_server, dbt_exasol, exasol_scheduler, json_tables
from exakit.domain.errors import Failed
from exakit.domain.platform import Platform
from exakit.lifecycles import for_addon
from exakit.lifecycles.host_extension import HostExtensionLifecycle
from tests.unit.app.harness import MANIFEST, Sandbox
from tests.unit.fakes import FakeRunner, mode_of

CREDS = {**MANIFEST, "runtime": {**MANIFEST["runtime"], "password_file": "/creds/sys_password", "user": "sys"},
         "components": {**MANIFEST["components"], "mcp_server": {"version": "2.2.0", "connection": {"user": "mcp_readonly", "password_file": "/creds/ro"}}}}


class SelectionTest(unittest.TestCase):
    def test_each_addon_gets_its_own_module_or_the_generic_kind(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            expect = {"dash-server": dash_server.Lifecycle, "dbt-exasol": dbt_exasol.Lifecycle, "json-tables": json_tables.Lifecycle,
                      "exasol-scheduler": exasol_scheduler.Lifecycle, "exasol-vscode": HostExtensionLifecycle}
            for aid, cls in expect.items():
                self.assertIsInstance(for_addon(box.ctx, box.ctx.catalog.addon(aid)), cls, aid)
        finally:
            box.close()


class DashServerTest(unittest.TestCase):
    def test_port_comes_from_env_then_record_then_default(self):
        box = Sandbox(manifest={**MANIFEST, "components": {**MANIFEST["components"], "dash_server": {"port": 5107}}})
        try:
            lc = for_addon(box.ctx, box.ctx.catalog.addon("dash-server"))
            self.assertEqual(lc.port(), 5107)
            box.env["EXAKIT_DASH_SERVER_PORT"] = "6000"
            self.assertEqual(lc.port(), 6000)
        finally:
            box.close()
        box = Sandbox(manifest=MANIFEST)
        try:
            self.assertEqual(for_addon(box.ctx, box.ctx.catalog.addon("dash-server")).port(), box.ctx.catalog.addon("dash-server").service["port"])
        finally:
            box.close()

    def test_settle_port_walks_past_a_foreign_holder_and_refuses_an_explicit_one(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            lc = for_addon(box.ctx, box.ctx.catalog.addon("dash-server"))
            with mock.patch.object(lc, "foreign_holder", lambda port: "python (pid 7)" if port == 5100 else None), \
                 mock.patch("exakit.addons.dash_server.port_in_use", lambda port: port == 5100):
                self.assertEqual(lc.settle_port(), 5101)
                self.assertIn("dash-server will use port 5101 instead", box.screen())
                box.env["EXAKIT_DASH_SERVER_PORT"] = "5100"
                with self.assertRaises(Failed) as caught:
                    lc.settle_port()
            self.assertIn("EXAKIT_DASH_SERVER_PORT=<port>", caught.exception.message)
        finally:
            box.close()

    def test_launcher_prefers_the_read_only_user_and_never_holds_a_password(self):
        box = Sandbox(manifest=CREDS)
        try:
            lc = for_addon(box.ctx, box.ctx.catalog.addon("dash-server"))
            with mock.patch.object(type(lc), "uv", lambda self: mock.Mock(bin_of=lambda venv, name: f"{venv}/bin/{name}")):
                text = lc.launcher_content()
            self.assertIn('DASH_SERVER_EXASOL_USER="mcp_readonly"', text)
            self.assertIn('[ -r "/creds/ro" ]', text)
            self.assertIn('DASH_SERVER_EXASOL_DSN="127.0.0.1:8563"', text)
            self.assertIn("_ds_default_port=5100", text)
            self.assertNotIn("sys_password", text)
        finally:
            box.close()

    def test_status_reads_the_launcher_and_the_port(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            lc = for_addon(box.ctx, box.ctx.catalog.addon("dash-server"))
            self.assertEqual(lc.status(), "not installed")
            lc.launcher.parent.mkdir(parents=True, exist_ok=True)
            lc.launcher.write_text("#!/bin/sh\n")
            with mock.patch.object(lc, "http_answers", lambda port, path="/mcp": True), mock.patch.object(lc, "foreign_holder", lambda port: None):
                self.assertEqual(lc.status(), "running")
            with mock.patch.object(lc, "http_answers", lambda port, path="/mcp": False), mock.patch.object(lc, "foreign_holder", lambda port: "node (pid 9)"):
                self.assertEqual(lc.status(), "stopped (port 5100 is held by another process: node (pid 9))")
        finally:
            box.close()


class DbtTest(unittest.TestCase):
    def test_profile_and_launcher_carry_the_address_but_not_the_password(self):
        box = Sandbox(manifest=CREDS)
        try:
            lc = for_addon(box.ctx, box.ctx.catalog.addon("dbt-exasol"))
            with mock.patch.object(type(lc), "uv", lambda self: mock.Mock(bin_of=lambda venv, name: f"{venv}/bin/{name}")):
                lc.write_launchers()
            profile = (lc.home / "profiles.yml").read_text()
            self.assertIn("dsn: 127.0.0.1:8563", profile)
            self.assertIn("user: sys", profile)
            self.assertIn("env_var('DBT_ENV_SECRET_EXASOL_PASSWORD')", profile)
            self.assertIn("schema: DBT", profile)
            self.assertIn(mode_of(lc.home / "profiles.yml"), (0o600, None))
            launcher = (box.ctx.paths.bin_dir / "dbt-exasol").read_text()
            self.assertIn('[ -r "/creds/sys_password" ]', launcher)
            self.assertIn(f'DBT_PROFILES_DIR:={lc.home}', launcher)
        finally:
            box.close()

    def test_system_presence_needs_a_foreign_dbt_with_the_exasol_adapter(self):
        runner = FakeRunner(which={"dbt": "/opt/homebrew/bin/dbt"})
        from exakit.adapters.process.runner import Completed
        runner.responses[("/opt/homebrew/bin/dbt", "--version")] = Completed(0, "Plugins:\n  - exasol: 1.8.0\n", "")
        box = Sandbox(manifest=MANIFEST, runner=runner)
        try:
            self.assertTrue(for_addon(box.ctx, box.ctx.catalog.addon("dbt-exasol")).system_present())
            runner.responses[("/opt/homebrew/bin/dbt", "--version")] = Completed(0, "Plugins:\n  - postgres\n", "")
            self.assertFalse(for_addon(box.ctx, box.ctx.catalog.addon("dbt-exasol")).system_present())
        finally:
            box.close()


class JsonTablesTest(unittest.TestCase):
    def test_applicable_follows_the_published_engines(self):
        for platform, ok in ((Platform("macos", "aarch64"), True), (Platform("linux", "x86_64"), True), (Platform("macos", "x86_64"), False)):
            box = Sandbox(manifest=MANIFEST, platform=platform)
            try:
                lc = for_addon(box.ctx, box.ctx.catalog.addon("json-tables"))
                self.assertEqual(lc.applicable()[0], ok, platform.platform_key)
                if not ok:
                    self.assertIn("no prebuilt ingest engine", lc.applicable()[1])
            finally:
                box.close()

    def test_the_source_release_comes_first_and_the_kit_mirror_follows_it(self):
        from exakit.lifecycles import releases
        box = Sandbox(manifest={**MANIFEST, "kit": {"source": "acme/kit@main"}})
        try:
            lc = for_addon(box.ctx, box.ctx.catalog.addon("json-tables"))
            sites = releases.sites(lc, "v0.9.0")
            self.assertEqual([s.repo for s in sites], ["exasol-labs/exasol-json-tables", "acme/kit"])
            self.assertEqual([s.tag for s in sites], ["v0.9.0", "json-tables-v0.9.0"])
            self.assertEqual(sites[0].asset("wheel", "v0.9.0"), "exasol_json_tables-0.9.0-py3-none-any.whl")
            self.assertEqual(sites[0].asset("macos-aarch64", "v0.9.0"), "json_to_parquet-v0.9.0-macos-arm64.tar.gz")
            self.assertEqual(lc.engine_asset("v0.9.0"), "json_to_parquet-v0.9.0-macos-arm64.tar.gz")
            box.env["EXAKIT_JSON_TABLES_MIRROR_REPO"] = "me/mirror"
            box.env["EXAKIT_JSON_TABLES_MIRROR_TAG"] = "custom"
            mirror = releases.sites(lc, "v0.9.0")[1]
            self.assertEqual((mirror.repo, mirror.tag, mirror.mirror), ("me/mirror", "custom", True))
        finally:
            box.close()

    def test_the_shim_answers_only_the_ingest_call(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            lc = for_addon(box.ctx, box.ctx.catalog.addon("json-tables"))
            with mock.patch.object(type(lc), "uv", lambda self: mock.Mock(bin_of=lambda venv, name: f"{venv}/bin/{name}")):
                lc.write_launchers()
            shim = (lc.shim_dir / "cargo").read_text()
            self.assertIn("*json_tables_ingest*", shim)
            self.assertIn(f'exec "{lc.engine}"', shim)
            self.assertTrue(os.access(lc.shim_dir / "cargo", os.X_OK))
            self.assertIn(f'PATH="{lc.shim_dir}:$PATH"', (box.ctx.paths.bin_dir / "exasol-json-tables").read_text())
        finally:
            box.close()


class SchedulerTest(unittest.TestCase):
    def test_asset_names_follow_the_platform(self):
        for platform, asset in ((Platform("macos", "aarch64"), "exasol_scheduler-v1.0.0-macos-arm64.tar.gz"),
                                (Platform("linux", "x86_64"), "exasol_scheduler-v1.0.0-linux-x86_64.tar.gz")):
            box = Sandbox(manifest=MANIFEST, platform=platform)
            try:
                lc = for_addon(box.ctx, box.ctx.catalog.addon("exasol-scheduler"))
                self.assertEqual(lc.asset_name("v1.0.0"), asset)
                self.assertTrue(lc.applicable()[0])
            finally:
                box.close()
        box = Sandbox(manifest=MANIFEST, platform=Platform("windows", "x86_64"))
        try:
            self.assertFalse(for_addon(box.ctx, box.ctx.catalog.addon("exasol-scheduler")).applicable()[0])
        finally:
            box.close()

    def test_the_service_user_gets_the_three_create_grants_and_a_failure_names_the_statement_not_the_password(self):
        from exakit.adapters.process.runner import Completed
        statements: list[str] = []

        class Pump:
            def sql(self, profile, text, **kw):
                statements.append(text)
                if text.startswith("GRANT CREATE TABLE"):
                    return Completed(1, "", "insufficient privileges\n")
                return Completed(0, "EXAKIT_SCHED_USER_MISSING", "")

        box = Sandbox(manifest=CREDS)
        try:
            lc = for_addon(box.ctx, box.ctx.catalog.addon("exasol-scheduler"))
            with mock.patch("exakit.app.runtime_ops.exapump", lambda ctx: Pump()), \
                 mock.patch("exakit.app.runtime_ops.profile_name", lambda ctx: "starter-kit"), \
                 self.assertRaises(Failed) as caught:
                lc.ensure_db_user()
            self.assertIn("granting CREATE TABLE failed: insufficient privileges", caught.exception.message)
            self.assertEqual(caught.exception.remedy, "exakit status")
            self.assertEqual([s for s in statements if s.startswith("GRANT")],
                             ["GRANT CREATE SESSION TO SCHEDULER_SVC", "GRANT CREATE SCHEMA TO SCHEDULER_SVC", "GRANT CREATE TABLE TO SCHEDULER_SVC"])
            self.assertTrue(any(s.startswith("CREATE USER SCHEDULER_SVC IDENTIFIED BY") for s in statements))
            self.assertFalse(any("self.schema" in s for s in statements))
            password = statements[1].split('"')[1]
            self.assertNotIn(password, caught.exception.message)
        finally:
            box.close()

    def test_launcher_supervises_the_engine_with_the_service_user(self):
        box = Sandbox(manifest=CREDS)
        try:
            lc = for_addon(box.ctx, box.ctx.catalog.addon("exasol-scheduler"))
            text = lc.launcher_content()
            self.assertIn('EXA_USER="scheduler_svc"', text)
            self.assertIn('EXA_HOST="127.0.0.1"', text)
            self.assertIn('EXA_PORT="8563"', text)
            self.assertIn("exasol_scheduler_password", text)
            self.assertIn('[ "$_fails" -ge 5 ]', text)
            self.assertNotIn("sys_password", text)
        finally:
            box.close()

    def test_status_reports_a_give_up_marker(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            lc = for_addon(box.ctx, box.ctx.catalog.addon("exasol-scheduler"))
            self.assertEqual(lc.status(), "not installed")
            lc.launcher.parent.mkdir(parents=True, exist_ok=True)
            lc.launcher.write_text("#!/bin/sh\n")
            lc.home.mkdir(parents=True, exist_ok=True)
            lc.giveup.write_text("gave up after 5 rapid failures (last exit 1) at now\n")
            with mock.patch.object(lc, "pids", list):
                self.assertTrue(lc.status().startswith("stopped (gave up after 5 rapid failures"))
            with mock.patch.object(lc, "pids", lambda: [42]):
                self.assertEqual(lc.status(), "running")
        finally:
            box.close()
