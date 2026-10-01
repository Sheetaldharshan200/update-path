"""uninstall (full, dry run, menu gate, safe target) and repair-runtime (consent, then the installer)."""

from __future__ import annotations

import unittest
from pathlib import Path
from unittest import mock

from exakit.app import repair, uninstall
from exakit.domain.errors import BadInput, Failed, NotConfirmed, NotRunning
from exakit.domain.result import Result
from tests.unit.app.harness import MANIFEST, Sandbox
from tests.unit.fakes import FakeRuntime


class SafeTargetTest(unittest.TestCase):
    def test_only_a_kit_home_is_removable(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            user = box.user_home
            self.assertTrue(uninstall.safe_target(box.home, user))
            self.assertFalse(uninstall.safe_target(user, user))
            self.assertFalse(uninstall.safe_target(Path("/"), user))
            other = Path(box.tmp.name) / "other"
            other.mkdir()
            (other / "photo.jpg").write_text("")
            self.assertFalse(uninstall.safe_target(other, user))
            empty = Path(box.tmp.name) / "empty"
            empty.mkdir()
            self.assertTrue(uninstall.safe_target(empty, user))
        finally:
            box.close()


def installed_box(**kw) -> Sandbox:
    box = Sandbox(manifest=MANIFEST, **kw)
    box.ctx.runtime = FakeRuntime("running", exists=True)
    box.ctx.services = mock.Mock(registered=lambda sid: False, unregister=lambda sid: True)
    (box.ctx.paths.bin_dir).mkdir(exist_ok=True)
    for name in ("exasol", "exakit", "exapump"):
        (box.ctx.paths.bin_dir / name).write_text("")
    (box.home / "credentials").mkdir()
    return box


class FullUninstallTest(unittest.TestCase):
    def test_nothing_installed_says_so(self):
        box = Sandbox()
        try:
            box.home.rmdir()
            self.assertEqual(uninstall.run(box.ctx, []).status, "nothing")
            self.assertIn("Nothing to uninstall", box.screen())
        finally:
            box.close()

    def test_dry_run_names_everything_and_removes_nothing(self):
        box = installed_box()
        try:
            result = uninstall.run(box.ctx, ["--dry-run"])
            self.assertEqual(result.status, "dry-run")
            self.assertIn("database", result.data["would_remove"])
            self.assertTrue(box.ctx.manifest_store.exists())
            self.assertTrue((box.ctx.paths.bin_dir / "exakit").exists())
            self.assertEqual(box.ctx.runtime.destroyed if hasattr(box.ctx.runtime, "destroyed") else 0, 0)
            self.assertIn("will remove: local Exasol personal deployment and ALL its data", box.screen())
            self.assertIn("Dry run only - nothing was removed.", box.screen())
        finally:
            box.close()

    def test_on_windows_the_python_folder_is_removed_by_a_detached_shell_after_exit(self):
        from exakit.domain.platform import Platform
        from tests.unit.fakes import FakeRunner
        runner = FakeRunner()
        box = installed_box(platform=Platform("windows", "x86_64"), runner=runner)
        try:
            (box.home / "python").mkdir()
            (box.home / "python" / "python.exe").write_text("")
            with mock.patch("exakit.app.uninstall.for_component") as comp:
                comp.return_value.uninstall = lambda dry_run: []
                result = uninstall.run(box.ctx, ["--yes"])
            self.assertEqual(result.status, "removed")
            self.assertTrue((box.home / "python" / "python.exe").exists(), "the running Python is left for the detached shell")
            self.assertFalse((box.home / "credentials").exists())
            spawned = [c for c in runner.calls if c and c[0] == "spawn"]
            self.assertEqual(len(spawned), 1)
            self.assertIn("rmdir", spawned[0][-1])
            self.assertIn(str(box.home / "python"), spawned[0][-1])
            self.assertIn("removed a few seconds after this command exits", box.screen())
        finally:
            box.close()

    def test_yes_removes_the_kit_in_order(self):
        box = installed_box()
        try:
            with mock.patch("exakit.app.uninstall.for_component") as comp:
                comp.return_value.uninstall = lambda dry_run: []
                result = uninstall.run(box.ctx, ["--yes"])
            self.assertEqual(result.status, "removed")
            self.assertFalse(box.home.exists())
            self.assertFalse((box.ctx.paths.bin_dir / "exakit").exists())
            self.assertFalse((box.ctx.paths.bin_dir / "exasol").exists())
            self.assertIn("Uninstall complete", box.screen())
            self.assertIn("There is no export step", box.screen())
        finally:
            box.close()

    def test_an_unsafe_home_is_refused(self):
        box = installed_box()
        try:
            box.ctx.paths = box.ctx.paths.__class__(home=box.user_home, bin_dir=box.ctx.paths.bin_dir)
            with self.assertRaises(Failed) as caught:
                uninstall.run(box.ctx, ["--yes"])
            self.assertIn("Unsafe EXAKIT_HOME", caught.exception.message)
            self.assertTrue(box.user_home.exists())
        finally:
            box.close()

    def test_the_menu_needs_a_terminal_and_the_typed_word(self):
        box = installed_box()
        try:
            with self.assertRaises(Failed) as caught:
                uninstall.run(box.ctx, [])
            self.assertIn("needs an interactive terminal", caught.exception.message)
        finally:
            box.close()
        box = installed_box(interactive=True)
        try:
            box.ctx.ui.checkboxes = lambda title, options, defaults: ["pyexasol"]
            box.ctx.ui.prompt = lambda question, default="": "nope"
            result = uninstall.run(box.ctx, [])
            self.assertEqual(result.status, "cancelled")
            self.assertTrue(box.ctx.manifest_store.exists())
            box.ctx.ui.prompt = lambda question, default="": "UNINSTALL"
            with mock.patch("exakit.app.uninstall.for_component") as comp:
                comp.return_value.uninstall = lambda dry_run: []
                result = uninstall.run(box.ctx, [])
                self.assertEqual((result.status, result.data["removed"]), ("removed", ["pyexasol"]))
                comp.assert_called_with(box.ctx, "pyexasol")
        finally:
            box.close()

    def test_option_and_target_refusals(self):
        box = installed_box()
        try:
            with self.assertRaises(BadInput):
                uninstall.run(box.ctx, ["--frob"])
            with self.assertRaises(BadInput):
                uninstall.run(box.ctx, ["nope"])
            with self.assertRaises(BadInput):
                uninstall.run(box.ctx, ["dash-server", "json-tables"])
        finally:
            box.close()


class RepairRuntimeTest(unittest.TestCase):
    def test_declining_is_exit_5_with_the_legacy_shape_and_changes_nothing(self):
        box = Sandbox(manifest=MANIFEST, json_mode=True)
        try:
            with self.assertRaises(NotConfirmed) as caught:
                repair.run(box.ctx, [])
            doc = caught.exception.refusal()
            self.assertEqual((doc["ok"], doc["status"], doc["reason"], doc["changed"], doc["remedy"]),
                             (False, "declined", "not confirmed", False, "exakit repair-runtime --yes"))
            self.assertIn("runtime", box.manifest().steps_completed())
        finally:
            box.close()

    def test_yes_resets_the_record_and_reruns_the_installer_with_a_forced_fresh_deployment(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            seen = {}
            def fake_install(ctx):
                seen["env"] = dict(ctx.env)
                seen["steps"] = ctx.manifest().steps_completed()
                seen["flag"] = ctx.manifest().get("data.datasets.tpch.loaded")
                return Result(True, "installed", data={"soft_failures": {}})
            with mock.patch("exakit.app.repair.install.run", fake_install):
                result = repair.run(box.ctx, ["--yes"])
            self.assertEqual(result.status, "repaired")
            self.assertEqual((seen["env"]["EXAKIT_REUSE_DB"], seen["env"]["EXAKIT_REPLACE_DB"]), ("0", "1"))
            self.assertNotIn("runtime", seen["steps"])
            self.assertIs(seen["flag"], False)
        finally:
            box.close()

    def test_a_rebuild_that_does_not_finish_is_exit_3(self):
        box = Sandbox(manifest=MANIFEST, env={"EXAKIT_CONFIRM_RUNTIME_REPAIR": "1"})
        try:
            with mock.patch("exakit.app.repair.install.run", lambda ctx: Result(True, "partial", data={"soft_failures": {"runtime": {}}})), \
                 self.assertRaises(NotRunning) as caught:
                repair.run(box.ctx, [])
            self.assertEqual(caught.exception.data["status"], "failed")
        finally:
            box.close()

    def test_bad_option(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            with self.assertRaises(BadInput):
                repair.run(box.ctx, ["--frob"])
        finally:
            box.close()
