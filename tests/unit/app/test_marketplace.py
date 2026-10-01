"""Marketplace: classification, the read-only list, the scripted and menu answers, install loop, add-on uninstall."""

from __future__ import annotations

import unittest
from unittest import mock

from exakit.app import marketplace
from exakit.domain.errors import BadInput, Failed, NotConfirmed
from exakit.lifecycles.base import ServiceHooks
from exakit.ui.console import ConsoleRenderer
from tests.unit.app.harness import MANIFEST, Sandbox

ALL = ("dash-server", "dbt-exasol", "exasol-scheduler", "exasol-vscode", "json-tables")


class FakeLifecycle:
    """A lifecycle whose answers are set by the test; records what was asked of it."""

    def __init__(self, ctx, addon, *, installed=None, system=False, ok=(True, ""), fail_install=False, service=False):
        self.ctx, self.addon = ctx, addon
        self._installed, self._system, self._ok, self._fail, self._service = installed, system, ok, fail_install, service
        self.calls: list[str] = []
        self.started = 0

    def applicable(self):
        return self._ok

    def system_present(self):
        return self._system

    def installed_version(self):
        return self._installed

    def target_version(self):
        return "9.9.9"

    def install(self, version):
        self.calls.append(f"install {version}")
        if self._fail:
            raise Failed("boom", remedy="exakit update x")
        self.ctx.manifest_store.update(lambda m: m.set(f"components.{self.addon.manifest_key}.version", version))
        self._installed = version

    def validate(self):
        self.calls.append("validate")

    def note_failure(self, reason):
        self.calls.append(f"note {reason}")

    def summary(self):
        return "the one fact"

    def service(self):
        if not self._service:
            return None
        def start():
            self.started += 1
        return ServiceHooks(status=lambda: "running", start=start, stop=lambda: None, url=lambda: None,
                            log_path=lambda: None, autostart=lambda: None)

    def uninstall(self, *, dry_run):
        self.calls.append(f"uninstall dry={dry_run}")
        if not dry_run:
            self.ctx.manifest_store.update(lambda m: m.delete(f"components.{self.addon.manifest_key}"))
        return ["/x/venv"]


class Fixture:
    """Installs a table of fake lifecycles keyed by add-on id into both places that pick one."""

    def __init__(self, box: Sandbox, **spec):
        self.box, self.spec = box, spec
        self.made: dict[str, FakeLifecycle] = {}

    def factory(self, ctx, addon):
        if addon.id not in self.made:
            self.made[addon.id] = FakeLifecycle(ctx, addon, **self.spec.get(addon.id, {}))
        return self.made[addon.id]

    def __enter__(self):
        self.patches = [mock.patch("exakit.lifecycles.for_addon", self.factory), mock.patch("exakit.app.marketplace.for_addon", self.factory)]
        for p in self.patches:
            p.start()
        return self

    def __exit__(self, *exc):
        for p in self.patches:
            p.stop()


def installed_manifest(*ids: str) -> dict:
    doc = {**MANIFEST, "components": dict(MANIFEST["components"])}
    for aid in ids:
        doc["components"][aid.replace("-", "_")] = {"version": "1.0.0"}
    return doc


class ListingTest(unittest.TestCase):
    def test_every_state_has_its_word_and_the_json_shape_is_frozen(self):
        box = Sandbox(manifest=installed_manifest("dash-server"), json_mode=True)
        try:
            with Fixture(box, **{"dash-server": {"installed": "1.0.0"}, "dbt-exasol": {"system": True},
                                 "json-tables": {"ok": (False, "no engine here")}}):
                result = marketplace.listing(box.ctx)
            rows = {r["id"]: r for r in result.data["addons"]}
            self.assertEqual(set(rows), set(ALL))
            self.assertEqual(rows["dash-server"], {"id": "dash-server", "status": "installed", "installed": True, "version": "1.0.0"})
            self.assertEqual(rows["dbt-exasol"], {"id": "dbt-exasol", "status": "managed outside the kit", "installed": False})
            self.assertEqual(rows["json-tables"]["status"], "not available on this machine")
            self.assertEqual(rows["json-tables"]["reason"], "no engine here")
            self.assertEqual(rows["exasol-scheduler"], {"id": "exasol-scheduler", "status": "available", "installed": False, "version": "9.9.9"})
            self.assertTrue(result.raw)
        finally:
            box.close()

    def test_text_listing_prints_one_row_per_addon_with_reasons(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            with Fixture(box, **{"json-tables": {"ok": (False, "no engine here")}}):
                marketplace.listing(box.ctx)
            screen = box.screen()
            self.assertIn("json-tables      not available on this machine", screen)
            self.assertIn("(no engine here)", screen)
            self.assertIn("dash-server      available 9.9.9", screen)
        finally:
            box.close()

    def test_list_refuses_ids_and_unknown_options(self):
        box = Sandbox(manifest=MANIFEST, json_mode=True)
        try:
            with Fixture(box):
                with self.assertRaises(BadInput):
                    marketplace.run(box.ctx, ["--list", "dash-server"])
                with self.assertRaises(BadInput):
                    marketplace.run(box.ctx, ["--frob"])
                with self.assertRaises(BadInput) as caught:
                    marketplace.run(box.ctx, ["nope"])
            self.assertIn("known: dash-server", caught.exception.message)
        finally:
            box.close()


class ScriptedAnswerTest(unittest.TestCase):
    def test_none_installs_nothing(self):
        box = Sandbox(manifest=MANIFEST, env={"EXAKIT_MARKETPLACE_ADDONS": "none"})
        try:
            with Fixture(box) as fx:
                result = marketplace.run(box.ctx, [])
            self.assertEqual(result.status, "skipped")
            self.assertFalse(any(f.calls for f in fx.made.values()))
            self.assertIn("installing nothing", box.screen())
        finally:
            box.close()

    def test_all_installs_every_available_addon_only(self):
        box = Sandbox(manifest=installed_manifest("dash-server"), env={"EXAKIT_MARKETPLACE_ADDONS": "ALL"})
        try:
            with Fixture(box, **{"dash-server": {"installed": "1.0.0"}, "dbt-exasol": {"system": True},
                                 "json-tables": {"ok": (False, "x")}}) as fx:
                result = marketplace.run(box.ctx, [])
            self.assertEqual(result.status, "applied")
            self.assertEqual(sorted(result.data["installed"]), ["exasol-scheduler", "exasol-vscode"])
            self.assertEqual(fx.made["dash-server"].calls, [])
        finally:
            box.close()

    def test_named_ids_explain_installed_and_system_and_refuse_the_rest(self):
        box = Sandbox(manifest=installed_manifest("dash-server"))
        try:
            spec = {"dash-server": {"installed": "1.0.0"}, "dbt-exasol": {"system": True}, "json-tables": {"ok": (False, "no engine")}}
            with Fixture(box, **spec):
                result = marketplace.run(box.ctx, ["dash-server", "dbt-exasol"])
                self.assertEqual(result.status, "skipped")
                self.assertIn("dash-server is already installed - update it with: exakit update", box.screen())
                self.assertIn("dbt-exasol is already on this system - the kit leaves it alone", box.screen())
                self.assertIn("Nothing to install - every requested add-on is already present.", box.screen())
                with self.assertRaises(Failed) as caught:
                    marketplace.run(box.ctx, ["json-tables"])
                self.assertIn("not available on this machine: no engine", caught.exception.message)
            box.env["EXAKIT_MARKETPLACE_ADDONS"] = "dash-server,zzz"
            with Fixture(box, **spec), self.assertRaises(BadInput) as caught:
                marketplace.run(box.ctx, [])
            self.assertIn("'zzz'", caught.exception.message)
        finally:
            box.close()

    def test_a_missing_module_names_the_update(self):
        box = Sandbox(manifest=MANIFEST, env={"EXAKIT_MARKETPLACE_ADDONS": "dash-server"})
        try:
            addon = box.ctx.catalog.addon("dash-server")
            with Fixture(box), mock.patch.object(type(addon), "directory", new_callable=mock.PropertyMock, return_value=None), \
                 self.assertRaises(Failed) as caught:
                marketplace.run(box.ctx, [])
            self.assertIn("not part of this kit copy", caught.exception.message)
        finally:
            box.close()


class MenuTest(unittest.TestCase):
    def test_without_a_terminal_nothing_is_installed_and_the_list_is_named(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            with Fixture(box) as fx:
                result = marketplace.run(box.ctx, [])
            self.assertEqual(result.status, "skipped")
            self.assertIn("No terminal to ask on - nothing was installed.", box.screen())
            self.assertIn("exakit marketplace --list", box.screen())
            self.assertFalse(any(f.calls for f in fx.made.values()))
        finally:
            box.close()

    def test_everything_covered_names_each_addon(self):
        box = Sandbox(manifest=installed_manifest("dash-server"), interactive=True)
        try:
            spec = {a: {"system": True} for a in ALL}
            spec["dash-server"] = {"installed": "1.0.0"}
            spec["json-tables"] = {"ok": (False, "no engine")}
            with Fixture(box, **spec):
                result = marketplace.run(box.ctx, [])
            self.assertEqual(result.status, "skipped")
            self.assertIn("Everything available is already covered.", box.screen())
            self.assertIn("dash-server    Installed 1.0.0", box.screen())
            self.assertIn("dbt-exasol     managed outside the kit", box.screen())
            self.assertNotIn("json-tables", box.screen())
        finally:
            box.close()

    def test_the_menu_answer_installs_what_was_ticked(self):
        box = Sandbox(manifest=MANIFEST, interactive=True)
        try:
            box.ctx.ui.checkboxes = lambda title, options, defaults: ["dbt-exasol"]
            with Fixture(box) as fx:
                result = marketplace.run(box.ctx, [])
            self.assertEqual(result.data["installed"], ["dbt-exasol"])
            self.assertEqual(fx.made["dbt-exasol"].calls, ["install 9.9.9", "validate"])
            self.assertIn("dbt-exasol installed - the one fact", box.screen())
        finally:
            box.close()

    def test_an_empty_selection_installs_nothing(self):
        box = Sandbox(manifest=MANIFEST, interactive=True)
        try:
            box.ctx.ui.checkboxes = lambda title, options, defaults: []
            with Fixture(box):
                result = marketplace.run(box.ctx, [])
            self.assertEqual(result.status, "skipped")
            self.assertIn("Nothing selected - nothing was installed.", box.screen())
        finally:
            box.close()


class InstallLoopTest(unittest.TestCase):
    def test_a_failed_install_is_partial_with_exit_1_and_the_others_still_run(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            with Fixture(box, **{"dash-server": {"fail_install": True}}) as fx:
                result = marketplace.run(box.ctx, ["dash-server", "dbt-exasol"])
            self.assertEqual((result.status, result.exit_code), ("partial", 1))
            self.assertEqual(result.data, {"installed": ["dbt-exasol"], "failed": ["dash-server"]})
            self.assertEqual(result.remedy, "exakit update dash-server")
            self.assertEqual(fx.made["dash-server"].calls, ["install 9.9.9", "note boom"])
        finally:
            box.close()

    def test_a_service_addon_is_started_and_joins_autostart_when_it_is_on(self):
        doc = {**MANIFEST, "autostart": {"enabled": True}}
        box = Sandbox(manifest=doc)
        try:
            registered = []
            with Fixture(box, **{"dash-server": {"service": True}}) as fx, \
                 mock.patch("exakit.app.services.register_autostart", lambda ctx, s: registered.append(s.id) or True):
                marketplace.run(box.ctx, ["dash-server"])
            self.assertEqual(fx.made["dash-server"].started, 1)
            self.assertEqual(registered, ["dash-server"])
        finally:
            box.close()

    def test_quiet_install_keeps_the_screen_empty(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            with Fixture(box) as fx:
                self.assertTrue(marketplace.install_addon_quietly(box.ctx, "json-tables"))
            self.assertEqual(box.screen(), "")
            self.assertEqual(fx.made["json-tables"].calls, ["install 9.9.9", "validate"])
            self.assertIsInstance(box.ctx.ui, ConsoleRenderer)
        finally:
            box.close()


class UninstallAddonTest(unittest.TestCase):
    def test_not_installed_says_so(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            with Fixture(box):
                result = marketplace.uninstall_addon(box.ctx, "dash-server")
            self.assertEqual(result.status, "not-installed")
            self.assertIn("dash-server is not installed - nothing to remove.", box.screen())
        finally:
            box.close()

    def test_dry_run_narrates_through_the_hook(self):
        box = Sandbox(manifest=installed_manifest("dash-server"))
        try:
            box.ctx.dry_run = True
            with Fixture(box, **{"dash-server": {"installed": "1.0.0"}}) as fx:
                result = marketplace.uninstall_addon(box.ctx, "dash-server")
            self.assertEqual(result.status, "dry-run")
            self.assertEqual(fx.made["dash-server"].calls, ["uninstall dry=True"])
            self.assertEqual(box.manifest().get("components.dash_server.version"), "1.0.0")
        finally:
            box.close()

    def test_declining_is_exit_5_and_removes_nothing(self):
        box = Sandbox(manifest=installed_manifest("dash-server"))
        try:
            with Fixture(box, **{"dash-server": {"installed": "1.0.0"}}) as fx, self.assertRaises(NotConfirmed) as caught:
                marketplace.uninstall_addon(box.ctx, "dash-server")
            self.assertEqual(caught.exception.remedy, "exakit uninstall dash-server --yes")
            self.assertEqual(fx.made["dash-server"].calls, [])
        finally:
            box.close()

    def test_yes_removes_and_forgets(self):
        box = Sandbox(manifest=installed_manifest("dash-server"))
        try:
            box.ctx.yes = True
            with Fixture(box, **{"dash-server": {"installed": "1.0.0"}}) as fx:
                result = marketplace.uninstall_addon(box.ctx, "dash-server")
            self.assertEqual(result.status, "removed")
            self.assertEqual(fx.made["dash-server"].calls, ["uninstall dry=False"])
            self.assertIsNone(box.manifest().get("components.dash_server"))
            self.assertIn("dash-server removed. Reinstall any time with: exakit marketplace dash-server", box.screen())
        finally:
            box.close()
