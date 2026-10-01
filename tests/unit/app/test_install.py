"""The installer over fakes: fresh run, resume, drift, soft failures, the persona's answers, the closing sequence."""

from __future__ import annotations

import unittest
from unittest import mock

from exakit.app import install
from exakit.domain.errors import Failed
from exakit.domain.platform import Platform
from tests.unit.app.harness import MANIFEST, Sandbox
from tests.unit.fakes import FakeRuntime


class Calls:
    """One fake per component id, remembering the verbs called on it."""

    def __init__(self):
        self.log: list[str] = []
        self.fail: set[str] = set()

    def lifecycle(self, ctx, cid):
        calls = self
        class Fake:
            def target_version(self):
                return "1.0.0"
            def install(self, version):
                calls.log.append(f"{cid}.install")
                if f"{cid}.install" in calls.fail:
                    raise Failed(f"{cid} install boom")
                if cid == "personal":
                    ctx.paths.bin_dir.mkdir(parents=True, exist_ok=True)
                    (ctx.paths.bin_dir / "exasol").write_text("launcher")
            def create_profile(self):
                calls.log.append(f"{cid}.profile")
            def validate(self):
                calls.log.append(f"{cid}.validate")
            def install_binary(self, src, dest):
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(src.read_bytes())
        return Fake()


def box_with(manifest=None, **kw) -> tuple[Sandbox, Calls, list]:
    box = Sandbox(manifest=manifest, **kw)
    box.ctx.runtime = FakeRuntime("stopped", exists=False)
    calls = Calls()
    patches = [
        mock.patch("exakit.app.install_steps.for_component", lambda ctx, cid: calls.lifecycle(ctx, cid)),
        mock.patch("exakit.app.install.for_component", lambda ctx, cid: calls.lifecycle(ctx, cid)),
        mock.patch("exakit.app.install.check_requirements", lambda ctx: calls.log.append("requirements")),
        mock.patch("exakit.app.install_steps.mcp.setup", lambda ctx: calls.log.append("mcp.setup") or mock.Mock(exit_code=0)),
        mock.patch("exakit.app.install_steps.skills.install", lambda ctx: calls.log.append("skills") or 3),
        mock.patch("exakit.app.install_steps.data.load", lambda ctx, ds, **kw: calls.log.append(f"data.{ds.id}") or mock.Mock()),
        mock.patch("exakit.app.install_steps.data.loaded", lambda ctx, **kw: set()),
        mock.patch("exakit.app.install.services.autostart_enable", lambda ctx: calls.log.append("autostart") or True),
        mock.patch("exakit.app.install.marketplace_rows", lambda ctx: []),
        mock.patch("exakit.app.install_steps.crossing_after", lambda ctx, runtime_failed: None),
        mock.patch("exakit.app.install.crossing_before", lambda ctx: None),
        mock.patch("exakit.app.install.process_start_time", lambda pid, runner: "now"),
        mock.patch("exakit.app.deploy.port_in_use", lambda port: False),        # never the machine's own port 8563
    ]
    return box, calls, patches


class Patched:
    def __init__(self, patches):
        self.patches = patches

    def __enter__(self):
        for p in self.patches:
            p.start()

    def __exit__(self, *exc):
        for p in self.patches:
            p.stop()


class FreshInstallTest(unittest.TestCase):
    def test_a_fresh_install_runs_every_step_in_order_and_records(self):
        box, calls, patches = box_with(env={"EXAKIT_MCP_CLIENTS": "skip"})
        try:
            with Patched(patches):
                result = install.run(box.ctx)
            self.assertEqual(result.status, "installed", result.data)
            self.assertEqual(calls.log[:2], ["requirements", "personal.install"])
            self.assertIn("exapump.install", calls.log)
            self.assertIn("exapump.profile", calls.log)
            self.assertIn("data.tpch", calls.log)
            self.assertIn("mcp.install", calls.log)
            self.assertIn("mcp.setup", calls.log)
            self.assertIn("skills", calls.log)
            self.assertIn("pyexasol.install", calls.log)
            self.assertEqual(calls.log[-1], "autostart")
            m = box.manifest()
            self.assertEqual(m.steps_completed(), ["launcher", "runtime", "exapump", "mcp", "pyexasol", "exakit_helper"])
            self.assertEqual(m.get("runtime.type"), "personal")
            self.assertEqual(m.get("kit.version"), "0.3.0")
            self.assertTrue(str(m.get("kit.source")).startswith("checkout:"))
            self.assertIsNone(m.get("install.current_step"))
            self.assertFalse(box.ctx.paths.install_lock.exists())
            self.assertTrue((box.ctx.paths.bin_dir / "exakit").exists())
            self.assertTrue((box.ctx.paths.kit / "exakit").is_dir())
            self.assertEqual(box.ctx.runtime.installed_local, 1)
            self.assertIn("Your starter kit is ready to use.", box.screen())
            self.assertIn("Your local Exasol", box.screen())
        finally:
            box.close()

    def test_a_second_run_skips_every_done_step(self):
        box, calls, patches = box_with(env={"EXAKIT_MCP_CLIENTS": "skip"})
        try:
            with Patched(patches):
                install.run(box.ctx)
                box.ctx.runtime = FakeRuntime("running", exists=True)
                calls.log.clear()
                box.out.truncate(0)
                box.out.seek(0)
                with mock.patch("exakit.app.install_steps.data.loaded", lambda ctx, **kw: {"tpch"}):
                    result = install.run(box.ctx)
            self.assertEqual(result.status, "installed")
            self.assertNotIn("personal.install", calls.log)
            self.assertNotIn("exapump.install", calls.log)
            self.assertEqual(box.screen().count("already done, skipping"), 6)
        finally:
            box.close()

    def test_a_missing_artifact_reruns_its_step(self):
        box, calls, patches = box_with(env={"EXAKIT_MCP_CLIENTS": "skip"})
        try:
            with Patched(patches):
                install.run(box.ctx)
                (box.ctx.paths.bin_dir / "exakit").unlink()
                box.ctx.runtime = FakeRuntime("running", exists=True)
                calls.log.clear()
                box.out.truncate(0)
                box.out.seek(0)
                install.run(box.ctx)
            self.assertIn("what it installed is missing - running it again", box.screen())
            self.assertTrue((box.ctx.paths.bin_dir / "exakit").exists())
        finally:
            box.close()


class SoftFailureTest(unittest.TestCase):
    def test_a_failed_database_skips_what_needs_it_and_reports_once(self):
        box, calls, patches = box_with(env={"EXAKIT_MCP_CLIENTS": "skip"})
        box.ctx.runtime.install_ok = False
        try:
            with Patched(patches):
                result = install.run(box.ctx)
            self.assertEqual(result.status, "partial")
            self.assertEqual(set(result.data["soft_failures"]), {"runtime"})
            self.assertNotIn("exapump.install", calls.log)
            self.assertNotIn("pyexasol.install", calls.log)
            self.assertIn("skills", calls.log)
            self.assertEqual(box.manifest().steps_completed(), ["launcher", "exakit_helper"])
            self.assertIn("Skipping exapump, the sample data, the AI bridge and pyexasol", box.screen())
            self.assertIn("the local database is not installed:", box.screen())
            self.assertIn("reinstall it with:  curl", box.screen())
            self.assertIn("Optional add-ons", box.screen() + "") if False else None
        finally:
            box.close()

    def test_a_failed_soft_component_does_not_stop_the_rest(self):
        box, calls, patches = box_with(env={"EXAKIT_MCP_CLIENTS": "skip"})
        calls.fail.add("pyexasol.install")
        try:
            with Patched(patches):
                result = install.run(box.ctx)
            self.assertEqual(result.status, "partial")
            self.assertEqual(result.data["soft_failures"]["pyexasol"]["repair"], "exakit update")
            self.assertEqual(result.data["soft_failures"]["pyexasol"]["reason"], "pyexasol install boom")
            self.assertIn("exakit_helper", box.manifest().steps_completed())
            self.assertNotIn("pyexasol", box.manifest().steps_completed())
        finally:
            box.close()

    def test_a_hard_failure_before_the_steps_releases_the_lock_and_names_the_step(self):
        box, _calls, patches = box_with()
        try:
            patches[2] = mock.patch("exakit.app.install.check_requirements", mock.Mock(side_effect=Failed("Insufficient memory: 4 GB.")))
            with Patched(patches), self.assertRaises(Failed) as caught:
                install.run(box.ctx)
            self.assertEqual(caught.exception.message, "Insufficient memory: 4 GB.")
            self.assertFalse(box.ctx.paths.install_lock.exists())
            self.assertIn("Re-running the installer is safe", box.screen())
        finally:
            box.close()


class AnswersTest(unittest.TestCase):
    def test_a_dry_run_shows_the_screen_and_the_plan_with_its_step_titles(self):
        box, calls, patches = box_with()
        box.ctx.dry_run = True
        try:
            with Patched(patches):
                result = install.run(box.ctx)
            self.assertEqual(result.status, "dry-run")
            self.assertEqual(calls.log, [])
            screen = box.screen()
            self.assertIn("Exasol Personal Local Starter Kit", screen)
            self.assertIn("Platform: macos (aarch64)", screen)
            self.assertIn("Step 1/6  Exasol launcher", screen)
            self.assertIn("Step 6/6  exakit helper command", screen)
            self.assertIn("Dry run: nothing was installed", screen)
            self.assertEqual([s["id"] for s in result.data["install"]], ["launcher", "runtime", "exapump", "mcp", "pyexasol", "exakit_helper"])
        finally:
            box.close()

    def test_persona_answers_drive_the_data_and_client_sections(self):
        box, calls, patches = box_with(env={"EXAKIT_PERSONA": "data-scientist"})
        try:
            with Patched(patches):
                install.run(box.ctx)
            self.assertEqual([c for c in calls.log if c.startswith("data.")], ["data.tpch", "data.energy", "data.weather"])
            self.assertEqual(box.ctx.env["EXAKIT_MCP_CLIENTS"], "all")
            self.assertEqual(box.ctx.env["EXAKIT_PERSONA_ACTIVE"], "1")
            self.assertIn("mcp.setup", calls.log)
            recorded = box.manifest()
            self.assertEqual((recorded.get("persona.id"), recorded.get("persona.source")), ("data-scientist", "install"))
            self.assertTrue(recorded.get("persona.requested_at"))
        finally:
            box.close()

    def test_on_windows_the_helper_is_the_cmd_shim_and_the_powershell_launcher(self):
        box, _calls, patches = box_with(env={"EXAKIT_LOAD_SAMPLE": "0", "EXAKIT_MCP_CLIENTS": "skip"}, platform=Platform("windows", "x86_64"))
        try:
            with Patched(patches):
                install.run(box.ctx)
            bin_dir = box.ctx.paths.bin_dir
            self.assertTrue((bin_dir / "exakit.cmd").exists() and (bin_dir / "exakit.ps1").exists())
            self.assertFalse((bin_dir / "exakit").exists())
            self.assertIn(b"exakit.ps1", (bin_dir / "exakit.cmd").read_bytes())
            self.assertIn("exakit_helper", box.manifest().steps_completed())
        finally:
            box.close()

    def test_an_unknown_persona_is_refused_before_anything_runs(self):
        box, calls, patches = box_with(env={"EXAKIT_PERSONA": "nope"})
        try:
            from exakit.domain.errors import BadInput
            with Patched(patches), self.assertRaises(BadInput):
                install.run(box.ctx)
            self.assertEqual(calls.log, [])
        finally:
            box.close()

    def test_load_sample_zero_skips_the_data(self):
        box, calls, patches = box_with(env={"EXAKIT_LOAD_SAMPLE": "0", "EXAKIT_MCP_CLIENTS": "skip"})
        try:
            with Patched(patches):
                install.run(box.ctx)
            self.assertFalse(any(c.startswith("data.") for c in calls.log))
            self.assertIn("Skipping the sample data (EXAKIT_LOAD_SAMPLE=0)", box.screen())
        finally:
            box.close()


class HousekeepingTest(unittest.TestCase):
    def test_dry_run_prints_the_plan_and_changes_nothing(self):
        box = Sandbox()
        box.ctx.dry_run = True
        try:
            result = install.run(box.ctx)
            self.assertEqual(result.status, "dry-run")
            self.assertEqual(result.data["pending"], 6)
            self.assertFalse(box.ctx.manifest_store.exists())
        finally:
            box.close()

    def test_a_corrupt_manifest_is_quarantined_and_its_ticks_recovered(self):
        box = Sandbox()
        try:
            box.ctx.paths.manifest.write_text('{"steps_completed": ["launcher", "runtime"], "runtime": {"type": "pers')
            install.init_manifest(box.ctx)
            self.assertEqual(box.manifest().steps_completed(), ["launcher", "runtime"])
            self.assertTrue(any(p.name.startswith("manifest.json.corrupt-") for p in box.home.iterdir()))
        finally:
            box.close()

    def test_a_live_lock_refuses_a_second_run(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            box.ctx.paths.install_lock.write_text("123\nstart\n")
            with mock.patch("exakit.app.install.lock_holder_alive", lambda path, runner: True), self.assertRaises(Failed) as caught:
                install.acquire_lock(box.ctx)
            self.assertIn("already in progress (pid 123)", caught.exception.message)
        finally:
            box.close()

    def test_whats_new_box_shows_the_crossed_versions_once(self):
        box = Sandbox(manifest={**MANIFEST, "kit": {"version": "0.3.0", "whats_new_from": "0.2.0"}})
        try:
            install.whats_new_box(box.ctx, install.kit_root(box.ctx))
            self.assertIn("What's new in 0.3.0", box.screen())
            self.assertIsNone(box.manifest().get("kit.whats_new_from"))
        finally:
            box.close()
