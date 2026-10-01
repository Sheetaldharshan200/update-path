import unittest

from exakit.domain.plan import Plan, Step, StepState


def _plan() -> Plan:
    return Plan("Persona: Analyst", [
        Step("datasets", "tpch", StepState.DONE),
        Step("datasets", "energy", StepState.PENDING),
        Step("addons", "dash-server", StepState.PENDING),
        Step("addons", "exasol-vscode", StepState.SKIPPED, reason="VS Code was not found"),
        Step("skills", "skills", StepState.DONE),
    ], remedy_command="exakit persona apply analyst")


class PlanTest(unittest.TestCase):
    def test_pending_lists_only_pending_steps_in_order(self):
        self.assertEqual([s.id for s in _plan().pending()], ["energy", "dash-server"])

    def test_pending_can_be_narrowed_to_a_section(self):
        self.assertEqual([s.id for s in _plan().pending("addons")], ["dash-server"])

    def test_complete_when_nothing_is_pending(self):
        self.assertFalse(_plan().complete)
        self.assertTrue(Plan("x", [Step("a", "b", StepState.DONE)]).complete)
        self.assertTrue(Plan("empty").complete)

    def test_sections_keep_first_seen_order(self):
        self.assertEqual(list(_plan().by_section()), ["datasets", "addons", "skills"])

    def test_to_dict_has_sections_pending_count_and_failed_list(self):
        doc = _plan().to_dict()
        self.assertEqual(doc["datasets"], [{"id": "tpch", "state": "done"}, {"id": "energy", "state": "pending"}])
        self.assertEqual(doc["addons"][1], {"id": "exasol-vscode", "state": "skipped", "reason": "VS Code was not found"})
        self.assertEqual(doc["pending"], 2)
        self.assertEqual(doc["failed"], [])

    def test_failed_steps_are_reported_with_section_and_reason(self):
        plan = _plan()
        plan.steps[2].state = StepState.FAILED
        plan.steps[2].reason = "download failed"
        self.assertEqual(plan.to_dict()["failed"], [{"section": "addons", "id": "dash-server", "reason": "download failed"}])
        self.assertEqual(plan.to_dict()["pending"], 1)

    def test_run_callable_does_not_take_part_in_equality(self):
        a = Step("s", "x", StepState.PENDING, run=lambda: None)
        b = Step("s", "x", StepState.PENDING, run=lambda: None)
        self.assertEqual(a, b)


if __name__ == "__main__":
    unittest.main()
