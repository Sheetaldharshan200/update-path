"""``exakit persona apply``: the plan drives the use cases through run_plan and records the persona."""

from __future__ import annotations

import unittest
from unittest import mock

from exakit.app import persona as persona_app
from exakit.domain.errors import NotConfirmed, NotInstalled
from exakit.domain.persona import ADDON_AVAILABLE, ADDON_INSTALLED
from tests.unit.app.harness import MANIFEST, Sandbox


def _states(states: dict[str, str]):
    def fake(ctx, manifest):
        return {a: (states.get(a, ADDON_AVAILABLE), "") for a in ctx.catalog.addon_ids()}
    return fake


class ApplyTest(unittest.TestCase):
    def test_no_install_record_is_exit_4(self):
        box = Sandbox(json_mode=True)
        try:
            with self.assertRaises(NotInstalled):
                persona_app.apply(box.ctx, "minimal")
        finally:
            box.close()

    def test_a_complete_plan_records_the_persona_and_runs_nothing(self):
        box = Sandbox(manifest=MANIFEST, json_mode=True, env={"EXAKIT_MCP_CLIENTS": "skip"})
        try:
            with mock.patch("exakit.app.machine.addon_states", _states({})), \
                 mock.patch("exakit.app.machine.skills_current", lambda ctx, m: True):
                result = persona_app.apply(box.ctx, "minimal")
            self.assertEqual(result.status, "complete")
            self.assertEqual(box.manifest().get("persona.id"), "minimal")
            self.assertEqual(box.manifest().get("persona.source"), "apply")
            self.assertTrue(box.manifest().get("persona.applied_at"))
        finally:
            box.close()

    def test_every_section_is_in_the_document_even_when_it_has_no_steps(self):
        """A machine with no AI clients still answers with an mcp_clients array: the JSON shape is frozen."""
        box = Sandbox(manifest=MANIFEST, json_mode=True, env={"EXAKIT_MCP_CLIENTS": "skip"})
        try:
            with mock.patch("exakit.app.machine.addon_states", _states({})), \
                 mock.patch("exakit.app.machine.skills_current", lambda ctx, m: True):
                planned = persona_app.plan(box.ctx, "minimal").to_dict()
                applied = persona_app.apply(box.ctx, "minimal").to_dict()
            for doc in (planned, applied):
                self.assertEqual(doc["mcp_clients"], [])
                self.assertTrue({"datasets", "mcp_clients", "addons", "skills", "pending", "failed"} <= set(doc), sorted(doc))
        finally:
            box.close()

    def test_without_yes_and_without_a_terminal_it_refuses_with_5_and_records_nothing(self):
        box = Sandbox(manifest=MANIFEST, json_mode=True, env={"EXAKIT_MCP_CLIENTS": "skip"})
        try:
            with mock.patch("exakit.app.machine.addon_states", _states({})), \
                 mock.patch("exakit.app.machine.skills_current", lambda ctx, m: False), \
                 self.assertRaises(NotConfirmed) as caught:
                persona_app.apply(box.ctx, "minimal")
            self.assertEqual(caught.exception.remedy, "exakit persona apply minimal --yes")
            self.assertIsNone(box.manifest().get("persona.id"))
        finally:
            box.close()

    def test_yes_runs_each_section_through_its_use_case(self):
        env = {"EXAKIT_MCP_CLIENTS": "claude", "EXAKIT_DATASETS": "tpch", "EXAKIT_MARKETPLACE_ADDONS": "dash-server,dbt-exasol"}
        doc = {**MANIFEST, "data": {"loaded": False, "datasets": {}}}
        box = Sandbox(manifest=doc, json_mode=True, env=env)
        box.ctx.yes = True
        try:
            ran: list[str] = []
            from exakit.domain.result import Result
            with mock.patch("exakit.app.machine.addon_states", _states({"dbt-exasol": ADDON_INSTALLED})), \
                 mock.patch("exakit.app.machine.skills_current", lambda ctx, m: False), \
                 mock.patch("exakit.app.machine.client_states", lambda ctx: {"claude": "pending"}), \
                 mock.patch("exakit.app.data.load", lambda ctx, ds, **kw: ran.append(f"data {ds.id}") or Result(True, "loaded")), \
                 mock.patch("exakit.app.mcp.setup", lambda ctx: ran.append(f"mcp {ctx.env['EXAKIT_MCP_CLIENTS']}") or Result(True, "ok")), \
                 mock.patch("exakit.app.marketplace.install_one", lambda ctx, addon: ran.append(f"addon {addon.id}") or True), \
                 mock.patch("exakit.app.skills.install", lambda ctx: ran.append("skills") or 3):
                result = persona_app.apply(box.ctx, "analyst")
            self.assertEqual(result.status, "applied")
            self.assertEqual(ran, ["data tpch", "mcp claude_desktop", "mcp claude_code", "addon dash-server", "skills"])
            self.assertEqual(box.manifest().get("persona.id"), "analyst")
            addons = {s["id"]: s["state"] for s in result.data["addons"]}
            self.assertEqual(addons, {"dbt-exasol": "done", "dash-server": "done"})
        finally:
            box.close()

    def test_a_failed_step_makes_the_answer_partial_with_its_remedy(self):
        box = Sandbox(manifest=MANIFEST, json_mode=True, env={"EXAKIT_MCP_CLIENTS": "skip", "EXAKIT_MARKETPLACE_ADDONS": "dash-server"})
        box.ctx.yes = True
        try:
            with mock.patch("exakit.app.machine.addon_states", _states({})), \
                 mock.patch("exakit.app.machine.skills_current", lambda ctx, m: True), \
                 mock.patch("exakit.app.marketplace.install_one", lambda ctx, addon: False):
                result = persona_app.apply(box.ctx, "minimal")
            self.assertEqual((result.status, result.exit_code), ("partial", 1))
            self.assertEqual(result.remedy, "exakit update dash-server")
            self.assertEqual([(f["section"], f["id"]) for f in result.data["failed"]], [("addons", "dash-server")])
        finally:
            box.close()
