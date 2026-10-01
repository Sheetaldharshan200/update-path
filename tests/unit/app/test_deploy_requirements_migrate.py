"""The deployment decision tree, the compatibility gate and the preflight report, and the migrate command's parsing."""

from __future__ import annotations

import unittest
from pathlib import Path
from unittest import mock

from exakit.adapters.process.containers import Engine
from exakit.app import deploy, legacy_db, migrate, requirements
from exakit.domain.errors import BadInput, Failed, NotRunning
from exakit.domain.platform import Platform
from tests.unit.app.harness import MANIFEST, Sandbox
from tests.unit.fakes import FakeRunner, FakeRuntime


def box_with(state: str, exists: bool, **kw) -> Sandbox:
    box = Sandbox(manifest=MANIFEST, **kw)
    box.ctx.runtime = FakeRuntime(state, exists=exists)
    box.ctx.credentials = mock.Mock(store=lambda name, value: Path("/creds") / name)
    return box


class DeployTest(unittest.TestCase):
    def test_a_running_database_is_reused_by_default_and_declined_with_the_env(self):
        box = box_with("running", True)
        try:
            self.assertTrue(deploy.deploy_local(box.ctx))
            self.assertIn("Reusing the existing Exasol deployment", box.screen())
            self.assertEqual(box.manifest().get("runtime.status"), "healthy")
        finally:
            box.close()
        box = box_with("running", True, env={"EXAKIT_REUSE_DB": "0"})
        try:
            self.assertFalse(deploy.deploy_local(box.ctx))
            self.assertTrue(box.ctx.paths.failure_note.exists())
        finally:
            box.close()

    def test_a_stopped_deployment_is_started_and_kept(self):
        box = box_with("stopped", True)
        try:
            self.assertTrue(deploy.deploy_local(box.ctx))
            self.assertEqual(box.ctx.runtime.started, 1)
            self.assertIn("(started)", box.screen())
        finally:
            box.close()

    def test_replacing_needs_consent_then_deploys_fresh(self):
        box = box_with("stopped", True, env={"EXAKIT_REUSE_DB": "0"})
        try:
            self.assertFalse(deploy.deploy_local(box.ctx))
            self.assertIn("Nothing was deleted.", box.screen())
        finally:
            box.close()
        box = box_with("stopped", True, env={"EXAKIT_REUSE_DB": "0", "EXAKIT_REPLACE_DB": "1"})
        try:
            with mock.patch("exakit.app.deploy.port_in_use", lambda port: False):
                self.assertTrue(deploy.deploy_local(box.ctx))
            self.assertEqual((box.ctx.runtime.destroyed, box.ctx.runtime.installed_local), (1, 1))
            self.assertIn("Exasol Personal deployed and answering", box.screen())
        finally:
            box.close()

    def test_a_fresh_deploy_that_fails_notes_the_reason(self):
        box = box_with("stopped", False)
        box.ctx.runtime.install_ok = False
        try:
            with mock.patch("exakit.app.deploy.port_in_use", lambda port: False):
                self.assertFalse(deploy.deploy_local(box.ctx))
            self.assertIn("The launcher could not deploy the database locally", box.ctx.paths.failure_note.read_text())
        finally:
            box.close()


class RequirementsTest(unittest.TestCase):
    def test_the_gate_refuses_low_memory_and_passes_with_force(self):
        box = Sandbox(manifest=MANIFEST)
        box.ctx.runtime = FakeRuntime("stopped")
        try:
            with mock.patch("exakit.app.requirements.machine.ram_gb", lambda p, r: 4), \
                 mock.patch("exakit.app.requirements.machine.free_disk_gb", lambda p, r, path: 100):
                with self.assertRaises(Failed) as caught:
                    requirements.check(box.ctx)
                self.assertEqual(caught.exception.message, "Insufficient memory: 4 GB.")
                box.env["EXAKIT_FORCE"] = "1"
                requirements.check(box.ctx)
            self.assertIn("Compatibility check passed (macos aarch64, 4 GB RAM, 100 GB free)", box.screen())
        finally:
            box.close()

    def test_an_intel_mac_is_refused_before_anything_with_the_supported_platforms_named(self):
        box = Sandbox(manifest=MANIFEST, platform=Platform("macos", "x86_64"))
        box.ctx.runtime = FakeRuntime("stopped")
        try:
            with mock.patch("exakit.app.requirements.machine.ram_gb", lambda p, r: 16), \
                 mock.patch("exakit.app.requirements.machine.free_disk_gb", lambda p, r, path: 100), \
                 self.assertRaises(Failed) as caught:
                requirements.check(box.ctx)
            self.assertIn("macOS on Intel", caught.exception.message)
            self.assertIn("Apple silicon", box.screen())
            self.assertIn("Nothing was installed", box.screen())
        finally:
            box.close()
        box = Sandbox(manifest=MANIFEST, platform=Platform("macos", "x86_64"), json_mode=True)
        try:
            with mock.patch("exakit.app.requirements.machine.ram_gb", lambda p, r: 16), \
                 mock.patch("exakit.app.requirements.machine.free_disk_gb", lambda p, r, path: 100), \
                 mock.patch("exakit.app.requirements.machine.macos_translated", lambda p, r: False):
                result = requirements.preflight(box.ctx)
            self.assertEqual(result.status, "blocked")
            self.assertTrue(any("macOS on Intel" in f for f in result.data["failures"]), result.data)
        finally:
            box.close()

    def test_wsl1_and_windows_are_refused(self):
        box = Sandbox(manifest=MANIFEST, platform=Platform("linux", "x86_64", wsl_version=1))
        try:
            with self.assertRaises(Failed) as caught:
                requirements.check(box.ctx)
            self.assertIn("WSL 1", caught.exception.message)
        finally:
            box.close()
        box = Sandbox(manifest=MANIFEST, platform=Platform("windows", "x86_64"))
        try:
            with self.assertRaises(Failed):
                requirements.check(box.ctx)
        finally:
            box.close()

    def test_preflight_reports_and_exits_1_on_a_blocker(self):
        runner = FakeRunner(which={"curl": "/usr/bin/curl", "tar": "/usr/bin/tar", "bash": "/bin/bash"})
        box = Sandbox(manifest=MANIFEST, runner=runner)
        try:
            with mock.patch("exakit.app.requirements.machine.ram_gb", lambda p, r: 16), \
                 mock.patch("exakit.app.requirements.machine.free_disk_gb", lambda p, r, path: 10), \
                 mock.patch("exakit.app.requirements.machine.macos_translated", lambda p, r: False):
                result = requirements.preflight(box.ctx)
            self.assertEqual((result.status, result.exit_code), ("blocked", 1))
            self.assertEqual(len(result.data["failures"]), 1)
            self.assertIn("Free disk", result.data["failures"][0])
            self.assertIn("[ok] Memory: 16 GB", box.screen())
        finally:
            box.close()


class MigrateArgsTest(unittest.TestCase):
    def test_parse(self):
        overrides, yes = migrate.parse_args(["docker-nano", "--container", "old", "--engine=podman", "--yes"])
        self.assertEqual((overrides, yes), ({"container": "old", "engine": "podman"}, True))
        for bad in ([], ["nope"], ["docker-nano", "--password", "x"], ["docker-nano", "--engine", "lxc"], ["docker-nano", "--dsn", "host"],
                    ["docker-nano", "--frob"], ["docker-nano", "--container"]):
            with self.assertRaises(BadInput, msg=bad):
                migrate.parse_args(bad)

    def test_no_container_and_no_password_are_exit_3_with_the_state_keys(self):
        box = Sandbox(manifest=MANIFEST, json_mode=True)
        try:
            with mock.patch("exakit.app.legacy_db.containers.find_engine", lambda runner, container, timeout=0, prefer=None: None), \
                 self.assertRaises(NotRunning) as caught:
                migrate.migrate(box.ctx, ["docker-nano"])
            self.assertEqual(caught.exception.refusal()["status"], "no container")
            engine = Engine("docker", "/usr/bin/docker")
            with mock.patch("exakit.app.legacy_db.containers.find_engine", lambda runner, container, timeout=0, prefer=None: engine), \
                 mock.patch("exakit.app.legacy_db.containers.published_port", lambda runner, e, c, timeout=0: 8563), \
                 self.assertRaises(NotRunning) as caught:
                migrate.migrate(box.ctx, ["docker-nano"])
            self.assertEqual(caught.exception.refusal()["status"], "no password")
        finally:
            box.close()

    def test_classification_keeps_the_kits_unchanged_sample_out(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            catalog = {"TPCH.NATION": ("tpch", 25), "TPCH.REGION": ("tpch", 5)}
            with mock.patch("exakit.app.legacy_db.sample_catalog", lambda ctx: catalog), \
                 mock.patch("exakit.app.legacy_db.table_rows", lambda ctx, schemas: {"TPCH.NATION": 25, "TPCH.REGION": 7}):
                found = legacy_db.classify(box.ctx, ["TPCH.NATION", "TPCH.REGION", "MINE.T1"])
            self.assertEqual((found.own, found.sample, found.sample_ids), (["TPCH.REGION", "MINE.T1"], ["TPCH.NATION"], ["tpch"]))
        finally:
            box.close()
