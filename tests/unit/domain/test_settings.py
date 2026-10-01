"""catalog/kit.json: the one place a default lives, validated field by field, read by the catalog, overridden by the environment."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from exakit.domain.errors import Failed
from exakit.domain.settings import FIELDS, KitSettings, load_settings, validate_settings
from tests.support import REPO, kit_settings

SHIPPED = json.loads((REPO / "catalog" / "kit.json").read_text(encoding="utf-8"))


class SettingsFileTest(unittest.TestCase):
    def test_the_shipped_file_validates_and_names_every_field(self):
        self.assertEqual(validate_settings(SHIPPED), [])
        settings = KitSettings.from_doc(SHIPPED)
        self.assertEqual(settings.repository.count("/"), 1)
        for section, key, kind in FIELDS:
            self.assertIsInstance(SHIPPED[section][key], kind, f"{section}.{key}")

    def test_every_missing_or_mistyped_field_is_named(self):
        for section, key, _kind in FIELDS:
            broken = json.loads(json.dumps(SHIPPED))
            del broken[section][key]
            self.assertIn(f"{section}.{key} is missing", validate_settings(broken))
            broken = json.loads(json.dumps(SHIPPED))
            broken[section][key] = [] if _kind is str else "nine"
            self.assertTrue(any(f"{section}.{key}" in p for p in validate_settings(broken)), (section, key))

    def test_urls_must_be_https_and_the_repository_owner_slash_name(self):
        broken = json.loads(json.dumps(SHIPPED))
        broken["install"]["sh_url"] = "http://example.invalid/kit.sh"
        broken["repository"] = "not-a-repo"
        problems = validate_settings(broken)
        self.assertTrue(any("install.sh_url" in p for p in problems))
        self.assertTrue(any("repository" in p for p in problems))

    def test_endpoint_templates_fill_with_the_configured_hosts(self):
        endpoints = kit_settings().endpoints
        self.assertEqual(endpoints.url("release_asset", repo="o/r", tag="v1", name="f"), "https://github.com/o/r/releases/download/v1/f")
        self.assertEqual(endpoints.url("release_by_tag", repo="o/r", tag="v1"), "https://api.github.com/repos/o/r/releases/tags/v1")
        self.assertEqual(endpoints.url("archive_branch", repo="o/r", ref="main"), "https://github.com/o/r/archive/refs/heads/main.tar.gz")
        self.assertEqual(endpoints.url("pypi_json", package="pyexasol"), "https://pypi.org/pypi/pyexasol/json")

    def test_the_installer_command_follows_the_platform(self):
        settings = kit_settings()
        self.assertEqual(settings.install_command(), f"curl -fsSL {settings.install_sh_url} | sh")
        self.assertEqual(settings.install_command(windows=True), f"irm {settings.install_ps1_url} | iex")

    def test_a_missing_or_broken_file_is_one_failure_naming_the_remedy(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "kit.json"
            with self.assertRaises(Failed) as missing:
                load_settings(path)
            self.assertEqual(missing.exception.remedy, "exakit update")
            path.write_text('{"schema_version": 1, "id": "kit"}', encoding="utf-8")
            with self.assertRaises(Failed) as broken:
                load_settings(path)
            self.assertIn("repository", broken.exception.message)
            path.write_text(json.dumps(SHIPPED), encoding="utf-8")
            self.assertEqual(load_settings(path).db_port, SHIPPED["runtime"]["db_port"])


class SettingsReachTheCodeTest(unittest.TestCase):
    """The values the code used to hardcode now come from the file, with the environment on top."""

    def test_the_context_reads_the_repository_and_the_installer_from_the_settings(self):
        from tests.unit.app.harness import MANIFEST, Sandbox
        box = Sandbox(manifest=MANIFEST)
        try:
            self.assertEqual(box.ctx.kit_repo, SHIPPED["repository"])
            self.assertEqual(box.ctx.install_command(), f"curl -fsSL {SHIPPED['install']['sh_url']} | sh")
            box.ctx.kit_repo_override = "me/mine"
            self.assertEqual(box.ctx.kit_repo, "me/mine")
            box.env["EXAKIT_INSTALL_URL"] = "https://example.test/kit.sh"
            self.assertEqual(box.ctx.install_command(), "curl -fsSL https://example.test/kit.sh | sh")
        finally:
            box.close()

    def test_no_python_module_carries_a_repository_url_port_or_threshold_literal(self):
        """The literals that moved to catalog/kit.json and the catalog source blocks must not come back."""
        forbidden = ("krishna-exasol/update-path", "exasol-labs/exapump", "exasol/exasol-personal", "exasol-labs/exasol-json-tables",
                     "https://api.github.com", "https://raw.githubusercontent.com", "https://pypi.org", "www.exasol.com/install",
                     "= 8563", "scheduler_svc", "exasol_starter_kit")
        offenders = []
        for path in (REPO / "exakit").rglob("*.py"):
            text = path.read_text(encoding="utf-8")
            offenders += [f"{path.relative_to(REPO)}: {word}" for word in forbidden if word in text]
        self.assertEqual(offenders, [])
