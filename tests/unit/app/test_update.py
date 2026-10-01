"""The update loop: targets, the skip rules, the runtime offer, and what each answer does."""

from __future__ import annotations

import unittest
from unittest import mock

from exakit.app import update
from exakit.domain.errors import BadInput, Failed
from tests.unit.app.harness import MANIFEST, FakeVersions, Sandbox
from tests.unit.components.test_components import versions_doc
from tests.unit.fakes import FakeRuntime


class Recorder:
    """Stands in for every component lifecycle: answers versions from a table, records what was updated."""

    def __init__(self, current: dict[str, str | None]):
        self.current = current
        self.updated: list[str] = []

    def lifecycle(self, cid):
        recorder = self
        class Fake:
            def installed_version(self):
                return recorder.current.get(cid)
            def update(self, options=None):
                recorder.updated.append(cid)
        return Fake()


def box_for(doc: dict, current: dict[str, str | None], manifest: dict | None = None, **kw) -> tuple[Sandbox, Recorder, list]:
    box = Sandbox(manifest=manifest or MANIFEST, **kw)
    box.ctx.versions = FakeVersions(doc)
    box.ctx.runtime = FakeRuntime("running")
    recorder = Recorder(current)
    patches = [
        mock.patch("exakit.app.update.for_component", lambda ctx, cid: recorder.lifecycle(cid)),
        mock.patch("exakit.app.update.installed_version", lambda ctx, cid, manifest: (recorder.current.get(cid), recorder.current.get(cid) is not None)),
        mock.patch("exakit.app.update.for_addon", lambda ctx, addon: recorder.lifecycle(addon.id)),
    ]
    return box, recorder, patches


DOC = versions_doc(personal=("2.3.0", {}), exapump=("0.13.0", {}), mcp=("2.2.0", {}), pyexasol=("2.4.1", {}), skills=("1.12.2", {}))


class ArgsAndTargetsTest(unittest.TestCase):
    def test_parse_args(self):
        self.assertEqual(update.parse_args([]), ("all", [], False))
        self.assertEqual(update.parse_args(["--yes", "runtime", "--plan"]), ("runtime", ["--plan"], True))
        with self.assertRaises(BadInput):
            update.parse_args(["--frob"])
        with self.assertRaises(Failed):
            update.parse_args(["exapump", "--plan"])

    def test_targets(self):
        box = Sandbox(manifest={**MANIFEST, "components": {**MANIFEST["components"], "dash_server": {"version": "0.1.1"}}})
        try:
            (box.ctx.paths.bin_dir).mkdir(exist_ok=True)
            (box.ctx.paths.bin_dir / "dash-server").write_text("")
            self.assertEqual(update.targets(box.ctx, "all"), ["exakit", "runtime", "exapump", "mcp", "pyexasol", "skills", "dash-server"])
            self.assertEqual(update.targets(box.ctx, "db"), ["runtime"])
            self.assertEqual(update.targets(box.ctx, "json-tables"), ["json-tables"])
            with self.assertRaises(BadInput):
                update.targets(box.ctx, "nope")
        finally:
            box.close()


class LoopTest(unittest.TestCase):
    def test_everything_current_updates_nothing(self):
        box, rec, patches = box_for(DOC, {"exakit": "0.3.0", "personal": "2.3.0", "exapump": "0.13.0", "mcp": "2.2.0", "pyexasol": "2.4.1", "skills": "1.12.2"})
        try:
            with patches[0], patches[1], patches[2]:
                result = update.run(box.ctx, [])
            self.assertEqual((result.status, rec.updated), ("current", []))
            self.assertIn("Everything is already current.", box.screen())
        finally:
            box.close()

    def test_behind_components_are_updated_and_ahead_ones_kept(self):
        box, rec, patches = box_for(DOC, {"exakit": "0.3.0", "personal": "2.3.0", "exapump": "0.12.0", "mcp": "2.3.0", "pyexasol": None, "skills": "1.12.2"})
        try:
            with patches[0], patches[1], patches[2]:
                result = update.run(box.ctx, [])
            self.assertEqual(result.status, "updated")
            self.assertEqual(rec.updated, ["exapump", "pyexasol"])
            self.assertIn("mcp 2.3.0 is newer than the tested 2.2.0 - keeping yours", box.screen())
            self.assertIn("exapump 0.12.0 -> 0.13.0", box.screen())
        finally:
            box.close()

    def test_runtime_is_deferred_without_an_answer_and_applied_with_yes(self):
        box, rec, patches = box_for(DOC, {"exakit": "0.3.0", "personal": "2.2.0", "exapump": "0.13.0", "mcp": "2.2.0", "pyexasol": "2.4.1", "skills": "1.12.2"})
        try:
            with patches[0], patches[1], patches[2]:
                result = update.run(box.ctx, [])
                self.assertEqual((result.status, rec.updated), ("deferred", []))
                self.assertIn("Unattended runs can opt in", box.screen())
                result = update.run(box.ctx, ["--yes"])
            self.assertEqual((result.status, rec.updated), ("updated", ["runtime"]))
            self.assertIn("Runtime updated and the database is running again.", box.screen())
        finally:
            box.close()

    def test_env_no_and_major_upgrade_are_left_alone(self):
        box, rec, patches = box_for(DOC, {"exakit": "0.3.0", "personal": "2.2.0", "exapump": "0.13.0", "mcp": "2.2.0", "pyexasol": "2.4.1", "skills": "1.12.2"},
                                    env={"EXAKIT_CONFIRM_RUNTIME_UPDATE": "no"})
        try:
            with patches[0], patches[1], patches[2]:
                self.assertEqual(update.run(box.ctx, []).status, "deferred")
            self.assertIn("Apply it when convenient", box.screen())
        finally:
            box.close()
        box, rec, patches = box_for(versions_doc(personal=("3.0.0", {}), exapump=("0.13.0", {}), mcp=("2.2.0", {}), pyexasol=("2.4.1", {}), skills=("1.12.2", {})),
                                    {"exakit": "0.3.0", "personal": "2.3.0", "exapump": "0.13.0", "mcp": "2.2.0", "pyexasol": "2.4.1", "skills": "1.12.2"},
                                    env={"EXAKIT_CONFIRM_RUNTIME_UPDATE": "yes"})
        try:
            with patches[0], patches[1], patches[2]:
                self.assertEqual(update.run(box.ctx, ["--yes"]).status, "deferred")
            self.assertEqual(rec.updated, [])
            self.assertIn("deferred runtime change", box.screen())
        finally:
            box.close()

    def test_an_explicit_target_runs_even_when_current_for_addons_and_refuses_unsupported(self):
        doc = versions_doc(exapump=("0.13.0", {"sha256": {"linux-x86_64": "aa" * 32}}))
        doc["components"]["dash-server"] = {"version": "0.1.1", "severity": "normal"}
        box, rec, patches = box_for(doc, {"exapump": "0.13.0", "dash-server": "0.1.1"})
        try:
            with patches[0], patches[1], patches[2]:
                self.assertEqual(update.run(box.ctx, ["dash-server"]).status, "updated")
                self.assertEqual(rec.updated, ["dash-server"])
                with self.assertRaises(Failed) as caught:
                    update.run(box.ctx, ["exapump"])
            self.assertIn("no build for this platform", caught.exception.message)
        finally:
            box.close()

    def test_min_kit_blocks_a_component_on_a_routine_update(self):
        doc = versions_doc(exapump=("0.13.0", {"min_kit_version": "9.9.9"}), personal=("2.3.0", {}), mcp=("2.2.0", {}), pyexasol=("2.4.1", {}), skills=("1.12.2", {}))
        box, rec, patches = box_for(doc, {"exakit": "0.3.0", "exapump": "0.12.0", "personal": "2.3.0", "mcp": "2.2.0", "pyexasol": "2.4.1", "skills": "1.12.2"})
        try:
            with patches[0], patches[1], patches[2]:
                self.assertEqual(update.run(box.ctx, []).status, "current")
                self.assertEqual(rec.updated, [])
                with self.assertRaises(Failed):
                    update.run(box.ctx, ["exapump"])
        finally:
            box.close()
