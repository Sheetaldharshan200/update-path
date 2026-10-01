import json
import tempfile
import unittest
from pathlib import Path

from exakit.domain.catalog import (
    Catalog, Persona, validate_addon, validate_component, validate_persona,
)
from exakit.domain.errors import BadInput

REPO = Path(__file__).resolve().parents[3]
KIT_CATALOG = REPO / "catalog"


def _canonical(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    return text == json.dumps(json.loads(text), indent=2) + "\n" and text.isascii() and "\r" not in text


class ShippedFilesTest(unittest.TestCase):
    """Every file the kit ships is valid, canonical and cross-referenced."""

    def test_components_validate_and_are_canonical(self):
        files = sorted((KIT_CATALOG / "components").glob("*.json"))
        self.assertEqual([f.stem for f in files], ["exakit", "exapump", "mcp", "personal", "pyexasol", "skills"])
        for path in files:
            self.assertEqual(validate_component(json.loads(path.read_text()), expected_id=path.stem), [], path.name)
            self.assertTrue(_canonical(path), path.name)

    def test_addons_validate_and_are_canonical(self):
        files = sorted((KIT_CATALOG / "addons").glob("*/addon.json"))
        self.assertEqual([f.parent.name for f in files], ["dash-server", "dbt-exasol", "exasol-scheduler", "exasol-vscode", "json-tables"])
        for path in files:
            self.assertEqual(validate_addon(json.loads(path.read_text()), expected_id=path.parent.name), [], path.parent.name)
            self.assertTrue(_canonical(path), path.parent.name)

    def test_every_addon_names_a_help_document_and_a_skill_that_exist(self):
        for path in (KIT_CATALOG / "addons").glob("*/addon.json"):
            doc = json.loads(path.read_text())
            self.assertTrue((REPO / "help" / f"{doc['help']}.json").is_file(), doc["id"])
            skill = REPO / "skills" / doc["skill"] / "SKILL.md"
            self.assertTrue(skill.is_file(), doc["id"])
            self.assertIn(f"addon: {doc['id']}", skill.read_text())

    def test_personas_validate_against_the_shipped_addons(self):
        addon_ids = {p.parent.name for p in (KIT_CATALOG / "addons").glob("*/addon.json")}
        files = sorted((KIT_CATALOG / "personas").glob("*.json"))
        self.assertEqual([f.stem for f in files], ["analyst", "data-engineer", "data-scientist", "minimal"])
        for path in files:
            problems = validate_persona(json.loads(path.read_text()), expected_id=path.stem,
                                        known_datasets={"tpch", "energy", "weather"}, known_addons=addon_ids)
            self.assertEqual(problems, [], path.name)
            self.assertTrue(_canonical(path), path.name)

    def test_the_catalog_loads_from_the_repo(self):
        warnings: list[str] = []
        catalog = Catalog.load(REPO, None, warn=warnings.append)
        self.assertEqual(warnings, [])
        self.assertEqual(catalog.component_ids(), ["personal", "exapump", "mcp", "skills", "pyexasol", "exakit"])
        self.assertEqual(catalog.addon_ids(), ["dash-server", "dbt-exasol", "exasol-scheduler", "exasol-vscode", "json-tables"])
        self.assertEqual(catalog.persona_ids(), ["analyst", "data-engineer", "data-scientist", "minimal"])
        self.assertEqual(catalog.component("mcp").manifest_key, "mcp_server")
        self.assertEqual(catalog.addon("dash-server").service["port"], 5100)
        self.assertFalse(catalog.addon("json-tables").supports("macos-x86_64"))
        self.assertTrue(catalog.addon("dash-server").supports("macos-x86_64"))


class ValidatorTest(unittest.TestCase):
    def _persona(self, **changes) -> dict:
        doc = {"schema_version": 1, "id": "x", "title": "X", "summary": "s", "datasets": ["tpch"],
               "mcp_clients": "all", "addons": ["dash-server"], "skills": "all"}
        doc.update(changes)
        return doc

    def test_persona_accepts_the_schema(self):
        self.assertEqual(validate_persona(self._persona(), expected_id="x"), [])

    def test_persona_rejects_each_bad_field_with_a_reason(self):
        cases = {
            "id": self._persona(id="Bad Id"),
            "file name": self._persona(id="y"),
            "title": self._persona(title="t" * 41),
            "summary": self._persona(summary="café"),
            "datasets": self._persona(datasets="some"),
            "datasets:": self._persona(datasets=[]),
            "mcp_clients": self._persona(mcp_clients=["7"]),
            "addons": self._persona(addons=["nope"]),
            "skills": self._persona(skills="none"),
        }
        for needle, doc in cases.items():
            problems = validate_persona(doc, expected_id="x", known_addons={"dash-server"})
            self.assertTrue(problems, needle)
            self.assertTrue(any(needle.rstrip(":") in p for p in problems), (needle, problems))

    def test_persona_newer_schema_says_update_the_kit(self):
        problems = validate_persona(self._persona(schema_version=2))
        self.assertIn("newer kit", problems[0])

    def test_persona_cross_checks_only_when_known_ids_are_given(self):
        doc = self._persona(datasets=["made-up"], addons=["made-up"])
        self.assertEqual(validate_persona(doc, expected_id="x"), [])
        self.assertTrue(validate_persona(doc, expected_id="x", known_datasets={"tpch"}))

    def test_component_and_addon_rejections(self):
        self.assertIn("kind", validate_component({"schema_version": 1, "id": "a", "title": "A", "kind": "weird"})[0])
        self.assertTrue(any("source" in p for p in validate_addon({"schema_version": 1, "id": "a", "title": "A", "kind": "binary"})))
        bad = {"schema_version": 1, "id": "a", "title": "A", "kind": "binary",
               "source": {"type": "github_release", "repo": "o/r"}, "platforms": ["amiga-68k"]}
        self.assertTrue(any("platforms" in p for p in validate_addon(bad)))


class CatalogLoadTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.kit = Path(self.tmp.name) / "kit"
        self.user = Path(self.tmp.name) / "personas"
        (self.kit / "catalog" / "personas").mkdir(parents=True)
        (self.kit / "catalog" / "addons" / "dash-server").mkdir(parents=True)
        (self.kit / "catalog" / "addons" / "dash-server" / "addon.json").write_text(json.dumps({
            "schema_version": 1, "id": "dash-server", "title": "D", "kind": "python-venv",
            "source": {"type": "pypi", "package": "dash-server"}}))
        self._write_persona(self.kit / "catalog" / "personas", "analyst", title="Analyst")
        (self.kit / "catalog" / "kit.json").write_bytes((REPO / "catalog" / "kit.json").read_bytes())

    def tearDown(self):
        self.tmp.cleanup()

    def _write_persona(self, directory: Path, pid: str, **fields) -> None:
        directory.mkdir(parents=True, exist_ok=True)
        doc = {"schema_version": 1, "id": pid, "title": "T", "summary": "s", "datasets": "all",
               "mcp_clients": "all", "addons": ["dash-server"], "skills": "all"}
        doc.update(fields)
        (directory / f"{pid}.json").write_text(json.dumps(doc))

    def test_user_personas_are_listed_and_shadow_shipped_ones(self):
        self._write_persona(self.user, "team-x")
        self._write_persona(self.user, "analyst", title="Our Analyst")
        catalog = Catalog.load(self.kit, self.user, warn=lambda m: None)
        self.assertEqual(catalog.persona_ids(), ["analyst", "team-x"])
        self.assertEqual(catalog.persona("analyst").title, "Our Analyst")
        self.assertEqual(catalog.persona("analyst").source, "user")
        self.assertEqual(catalog.persona("team-x").source, "user")

    def test_broken_user_files_are_skipped_with_one_warning_each(self):
        self.user.mkdir()
        (self.user / "broken.json").write_text("{not json")
        self._write_persona(self.user, "future", schema_version=99)
        warnings: list[str] = []
        catalog = Catalog.load(self.kit, self.user, warn=warnings.append)
        self.assertEqual(catalog.persona_ids(), ["analyst"])
        self.assertEqual(len(warnings), 2)
        self.assertTrue(any("newer kit" in w for w in warnings))

    def test_unknown_ids_are_bad_input_naming_the_known_ones(self):
        catalog = Catalog.load(self.kit, None, warn=lambda m: None)
        with self.assertRaises(BadInput) as ctx:
            catalog.persona("nope")
        self.assertIn("analyst", str(ctx.exception))
        with self.assertRaises(BadInput):
            catalog.addon("nope")
        self.assertTrue(catalog.has_addon("dash-server"))

    def test_persona_to_dict_round_trips_the_file(self):
        catalog = Catalog.load(self.kit, None, warn=lambda m: None)
        persona = catalog.persona("analyst")
        self.assertIsInstance(persona, Persona)
        self.assertEqual(persona.to_dict()["addons"], ["dash-server"])
        self.assertEqual(persona.to_dict()["datasets"], "all")


if __name__ == "__main__":
    unittest.main()
