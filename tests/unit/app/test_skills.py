import json
import unittest
from pathlib import Path

from exakit.app import skills
from exakit.domain.errors import Failed
from tests.unit.app.harness import MANIFEST, Sandbox


class SkillDiscoveryTest(unittest.TestCase):
    def test_shipped_skills_are_valid_and_named_by_folder(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            found = skills.shipped(box.ctx)
            self.assertGreater(len(found), 5)
            for skill in found:
                self.assertEqual(skill.id, skill.name)
                self.assertIn("Triggers", skill.description)
            owners = {s.id: s.addon for s in found if s.addon}
            self.assertEqual(owners, {k: k for k in ("dash-server", "dbt-exasol", "exasol-scheduler", "exasol-vscode", "json-tables")})
        finally:
            box.close()

    def test_frontmatter_rules(self):
        box = Sandbox()
        try:
            path = Path(box.tmp.name) / "SKILL.md"
            path.write_text("---\nname: x\ndescription: Does things. Triggers — a, b\naddon: dash-server\n---\nbody\n", encoding="utf-8")
            self.assertEqual(skills.frontmatter(path), {"name": "x", "description": "Does things. Triggers — a, b", "addon": "dash-server"})
            path.write_text("no frontmatter\n", encoding="utf-8")
            self.assertEqual(skills.frontmatter(path), {})
        finally:
            box.close()

    def test_summary_cuts_at_triggers_and_truncates(self):
        self.assertEqual(skills.summary_of("Load data fast. Triggers — x"), "Load data fast.")
        long = "word " * 30 + "Triggers — x"
        self.assertTrue(skills.summary_of(long).endswith("..."))
        self.assertLessEqual(len(skills.summary_of(long)), 64)


class InstallTest(unittest.TestCase):
    def _box(self, **kw) -> Sandbox:
        box = Sandbox(manifest=MANIFEST, **kw)
        roots = [Path(box.tmp.name) / "r1", Path(box.tmp.name) / "r2"]
        box.env["EXAKIT_SKILL_ROOTS"] = " ".join(str(r) for r in roots)
        box.roots = roots
        return box

    def test_install_places_core_skills_only_and_records(self):
        box = self._box()
        try:
            placed = skills.install(box.ctx)
            self.assertGreater(placed, 0)
            for root in box.roots:
                self.assertTrue((root / "exasol-marketplace" / "SKILL.md").is_file())
                self.assertFalse((root / "dash-server").exists())   # add-on not installed
            m = box.manifest()
            self.assertEqual(m.get("components.skills.version"), "1.12.2")
            self.assertIn("exasol-marketplace", m.get("components.skills.installed"))
            self.assertNotIn("dash-server", m.get("components.skills.installed"))
            self.assertIn("Installed", box.screen())
            self.assertEqual(skills.state_of(box.ctx, "exasol-marketplace"), "installed")
        finally:
            box.close()

    def test_addon_skill_follows_its_addon(self):
        box = self._box()
        try:
            box.ctx.manifest_store.update(lambda m: m.set("components.dash_server.version", "0.1.1"))
            (Path(box.env["EXAKIT_BIN_DIR"])).mkdir(exist_ok=True)
            (Path(box.env["EXAKIT_BIN_DIR"]) / "dash-server").write_text("#!/bin/sh\n")
            skills.install(box.ctx)
            self.assertTrue((box.roots[0] / "dash-server" / "SKILL.md").is_file())
            skills.remove_for_addon(box.ctx, "dash-server")
            self.assertFalse((box.roots[0] / "dash-server").exists())
            self.assertNotIn("dash-server", box.manifest().get("components.skills.installed"))
            self.assertEqual(skills.install_for_addon(box.ctx, "dash-server"), 1)
            self.assertTrue((box.roots[1] / "dash-server" / "SKILL.md").is_file())
        finally:
            box.close()

    def test_retire_removes_only_recorded_names_that_left_the_kit(self):
        box = self._box()
        try:
            for root in box.roots:
                (root / "zz-old").mkdir(parents=True)
                (root / "zz-old" / "SKILL.md").write_text("---\nname: zz-old\n---\n")
                (root / "mine").mkdir(parents=True)
                (root / "mine" / "SKILL.md").write_text("---\nname: mine\n---\n")
            box.ctx.manifest_store.update(lambda m: m.set("components.skills.installed", ["zz-old", "exasol-marketplace"]))
            skills.install(box.ctx)
            self.assertFalse((box.roots[0] / "zz-old").exists())
            self.assertTrue((box.roots[0] / "mine").exists())
            self.assertIn("Retired 1 skill", box.screen())
        finally:
            box.close()

    def test_missing_skills_dir_is_a_failure(self):
        box = self._box()
        try:
            box.ctx.paths = box.ctx.paths.__class__(home=Path(box.tmp.name) / "empty-home", bin_dir=box.ctx.paths.bin_dir)
            (Path(box.tmp.name) / "empty-home" / "kit" / "exakit").mkdir(parents=True)
            with self.assertRaises(Failed):
                skills.install(box.ctx)
        finally:
            box.close()


class AllowlistTest(unittest.TestCase):
    def test_merge_is_additive_and_idempotent_and_undoable(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            settings = box.user_home / ".claude" / "settings.json"
            settings.parent.mkdir()
            settings.write_text(json.dumps({"permissions": {"allow": ["Bash(ls:*)"], "deny": []}, "other": 1}))
            self.assertEqual(skills.apply_allowlist(box.ctx), "ADDED 40")
            doc = json.loads(settings.read_text())
            self.assertEqual(doc["permissions"]["allow"][0], "Bash(ls:*)")
            self.assertIn("mcp__exasol", doc["permissions"]["allow"])
            self.assertEqual(len(doc["permissions"]["deny"]), 3)
            self.assertEqual(doc["other"], 1)
            self.assertEqual(skills.apply_allowlist(box.ctx), "ADDED 0")
            self.assertEqual(skills.remove_allowlist(box.ctx), "REMOVED 40")
            doc = json.loads(settings.read_text())
            self.assertEqual(doc["permissions"]["allow"], ["Bash(ls:*)"])
        finally:
            box.close()

    def test_unsafe_files_are_skipped(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            settings = box.user_home / ".claude" / "settings.json"
            settings.parent.mkdir()
            settings.write_text("{broken")
            self.assertEqual(skills.apply_allowlist(box.ctx), "SKIP unreadable")
            settings.write_text("[]")
            self.assertEqual(skills.apply_allowlist(box.ctx), "SKIP not-an-object")
            settings.write_text('{"permissions": "x"}')
            self.assertEqual(skills.apply_allowlist(box.ctx), "SKIP permissions-not-an-object")
        finally:
            box.close()


class ListTest(unittest.TestCase):
    def test_json_shape_and_gating(self):
        box = Sandbox(manifest=MANIFEST, json_mode=True)
        try:
            box.env["EXAKIT_SKILL_ROOTS"] = str(Path(box.tmp.name) / "roots")
            result = skills.list_skills(box.ctx)
            doc = json.loads(result.to_json())
            self.assertEqual(set(doc), {"skills", "installed_version", "advertised_version", "status", "next"})
            self.assertEqual(doc["status"], "missing")
            self.assertEqual(doc["next"], "exakit skills-install")
            gated = next(r for r in doc["skills"] if r["name"] == "dash-server")
            self.assertEqual((gated["state"], gated["addon"], gated["remedy"]), ("needs-addon", "dash-server", "exakit marketplace dash-server"))
            core = next(r for r in doc["skills"] if r["name"] == "exasol-marketplace")
            self.assertEqual(set(core), {"name", "state", "summary"})
        finally:
            box.close()

    def test_update_pending_wins_over_missing(self):
        box = Sandbox(manifest={**MANIFEST, "components": {"skills": {"version": "1.0.0"}}}, json_mode=True)
        try:
            doc = json.loads(skills.list_skills(box.ctx).to_json())
            self.assertEqual((doc["status"], doc["next"]), ("update_pending", "exakit update"))
        finally:
            box.close()

    def test_human_panel_names_the_owner(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            box.env["EXAKIT_SKILL_ROOTS"] = str(Path(box.tmp.name) / "roots")
            skills.list_skills(box.ctx)
            self.assertIn("with dash-server", box.screen())
            self.assertIn("exakit skills-install", box.screen())
        finally:
            box.close()


if __name__ == "__main__":
    unittest.main()
