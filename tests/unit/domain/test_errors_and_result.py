import json
import unittest

from exakit.domain.errors import (
    EXIT_OK, BadInput, ExakitError, Failed, NotConfirmed, NotInstalled, NotRunning,
)
from exakit.domain.result import Result


class ExitCodesTest(unittest.TestCase):
    def test_every_code_matches_the_documented_contract(self):
        self.assertEqual(EXIT_OK, 0)
        self.assertEqual(Failed.code, 1)
        self.assertEqual(BadInput.code, 2)
        self.assertEqual(NotRunning.code, 3)
        self.assertEqual(NotInstalled.code, 4)
        self.assertEqual(NotConfirmed.code, 5)

    def test_base_error_is_a_failure(self):
        self.assertEqual(ExakitError("x").code, 1)

    def test_refusal_object_has_the_contract_keys(self):
        err = BadInput("Unknown command 'x'.", remedy="exakit catalog --json")
        doc = err.refusal()
        self.assertEqual(doc, {
            "ok": False, "error": "Unknown command 'x'.",
            "remedy": "exakit catalog --json", "rejected": True,
        })

    def test_refusal_marks_rejected_only_for_bad_input(self):
        self.assertFalse(NotConfirmed("declined").refusal()["rejected"])

    def test_refusal_carries_hint_and_extra_data(self):
        err = NotConfirmed("nothing changed", remedy="exakit persona apply x --yes",
                           hint="run it with --yes", data={"pending": 3})
        doc = err.refusal()
        self.assertEqual(doc["remedy_hint"], "run it with --yes")
        self.assertEqual(doc["pending"], 3)


class ResultTest(unittest.TestCase):
    def test_contract_keys_come_first_and_data_is_flat(self):
        result = Result(True, "running", data={"kit_level": 1, "persona": None})
        doc = result.to_dict()
        self.assertEqual(list(doc)[:3], ["installed", "status", "remedy"])
        self.assertEqual(doc["kit_level"], 1)
        self.assertIsNone(doc["persona"])

    def test_data_cannot_override_the_contract_keys(self):
        result = Result(False, "not installed", remedy="install", data={"status": "hacked"})
        self.assertEqual(result.to_dict()["status"], "not installed")

    def test_hint_is_present_only_when_set(self):
        self.assertNotIn("remedy_hint", Result(True, "ok").to_dict())
        self.assertIn("remedy_hint", Result(True, "ok", remedy_hint="why").to_dict())

    def test_json_is_one_line_ascii(self):
        text = Result(True, "ok", data={"name": "café"}).to_json()
        self.assertNotIn("\n", text)
        self.assertTrue(text.isascii())
        self.assertEqual(json.loads(text)["name"], "café")

    def test_default_exit_code_is_ok(self):
        self.assertEqual(Result(True, "ok").exit_code, 0)


if __name__ == "__main__":
    unittest.main()
