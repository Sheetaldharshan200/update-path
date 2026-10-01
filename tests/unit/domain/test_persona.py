import unittest

from exakit.domain.catalog import Persona
from exakit.domain.persona import (
    ADDON_AVAILABLE, ADDON_INSTALLED, ADDON_SYSTEM, ADDON_UNAVAILABLE, MachineState, answers_for, plan_for,
)
from exakit.domain.plan import StepState

ALL_DS = ["tpch", "energy", "weather"]


def _persona(pid="data-scientist", datasets="all", clients="all", addons=("dash-server", "json-tables")) -> Persona:
    return Persona(id=pid, title=pid.title(), summary="s", datasets=datasets, mcp_clients=clients,
                   addons=addons, skills="all", source="kit")


def _machine(**over) -> MachineState:
    base = {
        "all_datasets": tuple(ALL_DS), "loaded_datasets": frozenset({"tpch"}),
        "client_states": {"claude_code": "pending", "cursor": "connected", "codex": "missing"},
        "addon_states": {"dash-server": (ADDON_AVAILABLE, ""), "json-tables": (ADDON_UNAVAILABLE, "no engine for macos-x86_64"),
                      "exasol-vscode": (ADDON_SYSTEM, ""), "dbt-exasol": (ADDON_INSTALLED, "")},
        "all_addons": ("dash-server", "dbt-exasol", "exasol-vscode", "json-tables"), "skills_current": True,
    }
    base.update(over)
    return MachineState(**base)


class AnswersTest(unittest.TestCase):
    def test_persona_alone_expands_all_and_words(self):
        a = answers_for(_persona(), {}, all_datasets=ALL_DS)
        self.assertEqual(a.datasets, ("tpch", "energy", "weather"))
        self.assertEqual(a.mcp_clients, "all")
        self.assertEqual(a.addons, ("dash-server", "json-tables"))
        self.assertEqual(a.explicit, frozenset())
        self.assertEqual(a.env(), {"EXAKIT_DATASETS": "tpch,energy,weather", "EXAKIT_MCP_CLIENTS": "all",
                                   "EXAKIT_MARKETPLACE_ADDONS": "dash-server,json-tables"})

    def test_minimal_persona_answers_no_to_everything(self):
        a = answers_for(_persona("minimal", datasets="none", clients="skip", addons="none"), {}, all_datasets=ALL_DS)
        self.assertIsNone(a.datasets)
        self.assertEqual(a.env(), {"EXAKIT_LOAD_SAMPLE": "0", "EXAKIT_MCP_CLIENTS": "skip", "EXAKIT_MARKETPLACE_ADDONS": "none"})

    def test_explicit_env_wins_per_variable(self):
        env = {"EXAKIT_DATASETS": "tpch", "EXAKIT_MCP_CLIENTS": "codex"}
        a = answers_for(_persona(), env, all_datasets=ALL_DS)
        self.assertEqual(a.datasets, ("tpch",))
        self.assertEqual(a.mcp_clients, "codex")
        self.assertEqual(a.addons, ("dash-server", "json-tables"))
        self.assertEqual(a.explicit, frozenset({"datasets", "mcp_clients"}))

    def test_load_sample_and_skip_mcp_are_explicit_answers_too(self):
        a = answers_for(_persona(), {"EXAKIT_LOAD_SAMPLE": "0", "EXAKIT_SKIP_MCP": "1"}, all_datasets=ALL_DS)
        self.assertIsNone(a.datasets)
        self.assertEqual(a.mcp_clients, "skip")
        a = answers_for(_persona(datasets="none"), {"EXAKIT_LOAD_SAMPLE": "1"}, all_datasets=ALL_DS)
        self.assertEqual(a.datasets, ("tpch",))

    def test_explicit_marketplace_answer_words_and_lists(self):
        self.assertEqual(answers_for(_persona(), {"EXAKIT_MARKETPLACE_ADDONS": "None"}, all_datasets=ALL_DS).addons, "none")
        self.assertEqual(answers_for(_persona(), {"EXAKIT_MARKETPLACE_ADDONS": "a, b"}, all_datasets=ALL_DS).addons, ("a", "b"))

    def test_explicit_client_skip_words(self):
        self.assertEqual(answers_for(_persona(), {"EXAKIT_MCP_CLIENTS": "none"}, all_datasets=ALL_DS).mcp_clients, "skip")

    def test_dataset_list_from_persona_and_empty_all_falls_back_to_tpch(self):
        self.assertEqual(answers_for(_persona(datasets=("energy",)), {}, all_datasets=ALL_DS).datasets, ("energy",))
        self.assertEqual(answers_for(_persona(), {}, all_datasets=[]).datasets, ("tpch",))


class PlanTest(unittest.TestCase):
    def test_plan_states_per_section(self):
        plan = plan_for(_persona(), _machine())
        doc = plan.to_dict()
        self.assertEqual(doc["datasets"], [{"id": "tpch", "state": "done"}, {"id": "energy", "state": "pending"}, {"id": "weather", "state": "pending"}])
        self.assertEqual(doc["mcp_clients"], [{"id": "claude_code", "state": "pending"}, {"id": "cursor", "state": "done"}])
        self.assertEqual(doc["addons"][0], {"id": "dash-server", "state": "pending"})
        self.assertEqual(doc["addons"][1]["state"], "skipped")
        self.assertIn("no engine", doc["addons"][1]["reason"])
        self.assertEqual(doc["skills"], [{"id": "skills", "state": "done"}])
        self.assertEqual(doc["pending"], 4)
        self.assertEqual(plan.remedy_command, "exakit persona apply data-scientist")
        self.assertEqual(plan.pending("addons")[0].remedy, "exakit marketplace dash-server")

    def test_complete_when_everything_is_there(self):
        machine = _machine(loaded_datasets=frozenset(ALL_DS), client_states={"cursor": "connected"},
                           addon_states={"dash-server": (ADDON_INSTALLED, "")})
        plan = plan_for(_persona(addons=("dash-server",)), machine)
        self.assertTrue(plan.complete)
        self.assertEqual(plan.to_dict()["pending"], 0)

    def test_named_clients_and_missing_detection(self):
        plan = plan_for(_persona(clients=("claude", "codex")), _machine())
        rows = {s.id: s for s in plan.steps if s.section == "mcp_clients"}
        self.assertEqual(set(rows), {"claude_desktop", "claude_code", "codex"})
        self.assertEqual(rows["codex"].state, StepState.PENDING)
        self.assertIn("not detected", rows["codex"].reason)
        plan = plan_for(_persona(clients="all"), _machine(client_states=None))
        self.assertEqual(plan.steps[3].id, "all")
        self.assertIn("detection is unavailable", plan.steps[3].reason)

    def test_skip_and_none_sections_are_empty(self):
        plan = plan_for(_persona("minimal", datasets="none", clients="skip", addons="none"), _machine())
        self.assertEqual([s.section for s in plan.steps], ["skills"])

    def test_all_addons_and_unknown_addon(self):
        plan = plan_for(_persona(addons="all"), _machine())
        self.assertEqual([s.id for s in plan.steps if s.section == "addons"], ["dash-server", "dbt-exasol", "exasol-vscode", "json-tables"])
        self.assertEqual({s.id: s.state for s in plan.steps if s.section == "addons"}["exasol-vscode"], StepState.SKIPPED)
        plan = plan_for(_persona(addons=("ghost",)), _machine())
        ghost = next(s for s in plan.steps if s.id == "ghost")
        self.assertEqual(ghost.state, StepState.SKIPPED)

    def test_explicit_answers_shape_the_plan(self):
        answers = answers_for(_persona(), {"EXAKIT_DATASETS": "energy"}, all_datasets=ALL_DS)
        plan = plan_for(_persona(), _machine(), answers)
        self.assertEqual([s.id for s in plan.steps if s.section == "datasets"], ["energy"])


if __name__ == "__main__":
    unittest.main()
