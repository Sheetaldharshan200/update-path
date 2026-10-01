import unittest

from exakit.domain.manifest import SCHEMA_VERSION, Manifest, utc_now
from exakit.domain.platform import Platform


def _legacy_doc() -> dict:
    """A manifest exactly as a 0.2.0 install leaves it (schema 1, no schema_version key)."""
    return {
        "manifest_version": 1, "kit_level": 1, "installed_at": "2026-09-01T10:00:00Z",
        "os": "macos", "arch": "arm64",
        "runtime": {"type": "personal", "status": "running"},
        "components": {"mcp_server": {"version": "2.2.0"}},
        "data": {"loaded": True, "datasets": {"tpch": {"loaded": True}}},
        "steps_completed": ["launcher", "runtime"], "log_dir": "/x/logs",
    }


class ManifestAccessTest(unittest.TestCase):
    def test_get_walks_dot_paths_and_defaults_when_missing(self):
        m = Manifest(_legacy_doc())
        self.assertEqual(m.get("components.mcp_server.version"), "2.2.0")
        self.assertIsNone(m.get("components.nothing.version"))
        self.assertEqual(m.get("runtime.port", 8563), 8563)

    def test_get_does_not_walk_into_scalars(self):
        self.assertIsNone(Manifest(_legacy_doc()).get("os.name"))

    def test_set_creates_intermediate_objects(self):
        m = Manifest(_legacy_doc())
        m.set("persona.id", "analyst")
        m.set("persona.source", "install")
        self.assertEqual(m.doc["persona"], {"id": "analyst", "source": "install"})

    def test_set_replaces_a_scalar_that_is_in_the_way(self):
        m = Manifest({"kit": "old"})
        m.set("kit.version", "0.3.0")
        self.assertEqual(m.doc["kit"], {"version": "0.3.0"})

    def test_delete_removes_subtrees_and_is_silent_when_absent(self):
        m = Manifest(_legacy_doc())
        self.assertTrue(m.delete("data.datasets"))
        self.assertNotIn("datasets", m.doc["data"])
        self.assertFalse(m.delete("data.datasets"))
        self.assertFalse(m.delete("no.such.path"))

    def test_steps_are_recorded_once(self):
        m = Manifest(_legacy_doc())
        m.mark_step("exapump")
        m.mark_step("exapump")
        self.assertEqual(m.steps_completed(), ["launcher", "runtime", "exapump"])

    def test_runtime_type_and_persona_id_are_none_when_absent(self):
        m = Manifest({"runtime": {}})
        self.assertIsNone(m.runtime_type())
        self.assertIsNone(m.persona_id())
        m.set("runtime.type", "personal")
        m.set("persona.id", "minimal")
        self.assertEqual(m.runtime_type(), "personal")
        self.assertEqual(m.persona_id(), "minimal")

    def test_copy_is_independent(self):
        m = Manifest(_legacy_doc())
        c = m.copy()
        c.set("os", "linux")
        self.assertEqual(m.get("os"), "macos")


class ManifestSchemaTest(unittest.TestCase):
    def test_new_has_the_legacy_initial_shape_plus_schema_two(self):
        m = Manifest.new(platform=Platform("linux", "x86_64"), log_dir="/h/logs")
        self.assertEqual(m.doc["manifest_version"], 1)
        self.assertEqual(m.doc["schema_version"], SCHEMA_VERSION)
        self.assertEqual(m.doc["kit_level"], 1)
        self.assertEqual(m.doc["os"], "linux")
        self.assertEqual(m.doc["data"], {"loaded": False})
        self.assertEqual(m.doc["steps_completed"], [])
        self.assertEqual(m.doc["log_dir"], "/h/logs")
        self.assertRegex(m.doc["installed_at"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

    def test_new_can_salvage_completed_steps(self):
        m = Manifest.new(platform=Platform("macos", "aarch64"), log_dir="/l", steps_completed=["launcher"])
        self.assertEqual(m.steps_completed(), ["launcher"])

    def test_legacy_document_is_schema_one(self):
        self.assertEqual(Manifest(_legacy_doc()).schema_version, 1)

    def test_migrate_moves_one_to_two_and_keeps_every_key(self):
        before = _legacy_doc()
        m = Manifest(dict(before))
        notes = m.migrate()
        self.assertEqual(len(notes), 1)
        self.assertEqual(m.schema_version, 2)
        for key, value in before.items():
            self.assertEqual(m.doc[key], value)

    def test_migrate_is_idempotent(self):
        m = Manifest(_legacy_doc())
        m.migrate()
        self.assertEqual(m.migrate(), [])

    def test_utc_now_format(self):
        self.assertRegex(utc_now(), r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


if __name__ == "__main__":
    unittest.main()
