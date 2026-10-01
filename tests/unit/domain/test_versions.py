import json
import unittest

from exakit.domain.versions import (
    VersionPolicy, VersionsDoc, VersionsInvalid, VersionsSchemaAhead, cache_outranks_baked,
    compare, is_newer, metadata_applies, parse_version, resolve, validate,
)

GOOD = {
    "schema_version": 1, "updated": "2026-09-29", "kit": {"version": "0.2.0"},
    "components": {
        "exapump": {"version": "0.13.0", "repo": "exasol-labs/exapump", "severity": "normal",
                    "sha256": {"macos-aarch64": "a" * 64}},
        "mcp": {"version": "2.2.0", "package": "exasol-mcp-server", "severity": "critical",
                "note": "read the changelog", "min_kit_version": "0.2.0"},
    },
    "tools": {"uv": {"version": "0.8.4", "sha256": {"macos-aarch64": "b" * 64}}},
}


def _doc(**changes) -> dict:
    doc = json.loads(json.dumps(GOOD))
    doc.update(changes)
    return doc


class ValidationTest(unittest.TestCase):
    def test_the_shipped_shape_is_accepted(self):
        validate(GOOD)
        self.assertEqual(VersionsDoc.parse(json.dumps(GOOD)).kit_version(), "0.2.0")

    def test_newer_schema_is_reported_as_ahead_not_corrupt(self):
        with self.assertRaises(VersionsSchemaAhead):
            validate(_doc(schema_version=2))

    def test_missing_or_older_schema_is_invalid(self):
        with self.assertRaises(VersionsInvalid):
            validate(_doc(schema_version="1"))
        doc = _doc()
        del doc["schema_version"]
        with self.assertRaises(VersionsInvalid):
            validate(doc)

    def test_unsafe_version_and_bad_digest_are_refused(self):
        doc = _doc()
        doc["components"]["exapump"]["version"] = "0.13.0; rm -rf /"
        with self.assertRaises(VersionsInvalid):
            validate(doc)
        doc = _doc()
        doc["components"]["exapump"]["sha256"]["macos-aarch64"] = "xyz"
        with self.assertRaises(VersionsInvalid):
            validate(doc)

    def test_empty_components_and_non_object_are_refused(self):
        with self.assertRaises(VersionsInvalid):
            validate(_doc(components={}))
        with self.assertRaises(VersionsInvalid):
            validate([])
        with self.assertRaises(VersionsInvalid):
            VersionsDoc.parse("{not json")

    def test_tools_block_is_validated_like_a_component(self):
        doc = _doc(tools={"uv": {"version": "0.8.4", "sha256": {}}})
        with self.assertRaises(VersionsInvalid):
            validate(doc)


class DocReadsTest(unittest.TestCase):
    def setUp(self):
        self.doc = VersionsDoc(GOOD)

    def test_component_reads(self):
        self.assertEqual(self.doc.component_version("exapump"), "0.13.0")
        self.assertIsNone(self.doc.component_version("nope"))
        self.assertEqual(self.doc.sha256("exapump", "macos-aarch64"), "a" * 64)
        self.assertIsNone(self.doc.sha256("exapump", "windows-x86_64"))
        self.assertEqual(self.doc.tool("uv")["version"], "0.8.4")

    def test_metadata_reads_default_to_normal_and_none(self):
        self.assertEqual(self.doc.severity("mcp"), "critical")
        self.assertEqual(self.doc.severity("exapump"), "normal")
        self.assertEqual(self.doc.note("mcp"), "read the changelog")
        self.assertIsNone(self.doc.note("exapump"))
        self.assertEqual(self.doc.min_kit_version("mcp"), "0.2.0")


class CompareTest(unittest.TestCase):
    def test_prerelease_sorts_below_its_release(self):
        self.assertTrue(is_newer("2.3.0", "2.3.0-rc1"))
        self.assertFalse(is_newer("2.3.0-rc1", "2.3.0"))
        self.assertTrue(is_newer("2.3.0-rc2", "2.3.0-rc1"))

    def test_post_release_sorts_above(self):
        self.assertTrue(is_newer("0.13.0.post1", "0.13.0"))

    def test_build_metadata_and_v_prefix_are_ignored(self):
        self.assertEqual(compare("v1.2.3+build9", "1.2.3"), 0)

    def test_never_raises_on_odd_shapes(self):
        for a, b in (("abc", "1"), ("", "1"), ("1.a.2", "1.b"), ("2026.09", "2026.9.1")):
            compare(a, b)
        self.assertFalse(is_newer("", "1.0"))
        self.assertFalse(is_newer("1.0", "1.0"))

    def test_parse_version_is_all_ints(self):
        for part in parse_version("2.3.0-rc1"):
            self.assertTrue(all(isinstance(x, int) for x in (part if isinstance(part, tuple) else (part,))))


class PolicyTest(unittest.TestCase):
    def test_policy_words(self):
        self.assertIs(VersionPolicy.from_env(None), VersionPolicy.MANIFEST)
        self.assertIs(VersionPolicy.from_env("LATEST"), VersionPolicy.LATEST)
        self.assertIs(VersionPolicy.from_env("pinned"), VersionPolicy.PINNED)
        self.assertIs(VersionPolicy.from_env("whatever"), VersionPolicy.PINNED)

    def test_metadata_applies_only_under_manifest_without_a_pin(self):
        self.assertTrue(metadata_applies(VersionPolicy.MANIFEST, None))
        self.assertFalse(metadata_applies(VersionPolicy.MANIFEST, "0.1"))
        self.assertFalse(metadata_applies(VersionPolicy.LATEST, None))


class ResolveTest(unittest.TestCase):
    doc = VersionsDoc(GOOD)

    def test_env_pin_wins_over_everything(self):
        r = resolve("exapump", policy=VersionPolicy.LATEST, env_pin="0.11.2", doc=self.doc, fallback="0.1", latest=lambda: "9.9")
        self.assertEqual((r.version, r.source), ("0.11.2", "env"))

    def test_manifest_policy_reads_the_document_then_falls_back(self):
        r = resolve("exapump", policy=VersionPolicy.MANIFEST, env_pin=None, doc=self.doc, fallback="0.1")
        self.assertEqual((r.version, r.source), ("0.13.0", "manifest"))
        r = resolve("dash-server", policy=VersionPolicy.MANIFEST, env_pin=None, doc=self.doc, fallback="0.1.1")
        self.assertEqual((r.version, r.source), ("0.1.1", "fallback"))
        self.assertIsNone(resolve("dash-server", policy=VersionPolicy.MANIFEST, env_pin=None, doc=None, fallback=None))

    def test_latest_asks_upstream_then_falls_back(self):
        r = resolve("mcp", policy=VersionPolicy.LATEST, env_pin=None, doc=self.doc, fallback="2.0", latest=lambda: "2.5.0")
        self.assertEqual((r.version, r.source), ("2.5.0", "latest"))
        r = resolve("mcp", policy=VersionPolicy.LATEST, env_pin=None, doc=self.doc, fallback="2.0", latest=lambda: None)
        self.assertEqual((r.version, r.source), ("2.0", "fallback"))

    def test_pinned_never_reads_the_document(self):
        r = resolve("mcp", policy=VersionPolicy.PINNED, env_pin=None, doc=self.doc, fallback="2.0")
        self.assertEqual((r.version, r.source), ("2.0", "fallback"))


class CacheOutranksTest(unittest.TestCase):
    def test_cache_loses_only_when_provably_older(self):
        older = VersionsDoc(_doc(updated="2026-01-01"))
        newer = VersionsDoc(_doc(updated="2026-09-29"))
        undated = VersionsDoc(_doc(updated=None))
        self.assertFalse(cache_outranks_baked(older, newer))
        self.assertTrue(cache_outranks_baked(newer, older))
        self.assertTrue(cache_outranks_baked(newer, newer))
        self.assertTrue(cache_outranks_baked(undated, newer))
        self.assertTrue(cache_outranks_baked(older, undated))
        self.assertTrue(cache_outranks_baked(older, None))


if __name__ == "__main__":
    unittest.main()
