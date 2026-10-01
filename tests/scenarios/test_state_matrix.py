"""Every command in every machine state, both output modes: the matrix behind the contract.

One test per (state, command), generated from ``harness.STATES`` x
``harness.COMMANDS``. Each runs the command twice, human and ``--json``, and holds:

  * the exit code the contract fixes for that state (``EXPECTED`` below; a pair
    when the two modes legitimately differ)
  * ``--json`` prints exactly one JSON object and nothing else on stdout
  * exit 4 answers ``installed: false``; exit 2 answers the refusal object with
    ``rejected: true``; exits 1, 3 and 5 answer a refusal or a state document
  * a remedy, when present, is a runnable command or null, never a sentence
  * human mode prints no JSON object on stdout, and an exit-2 refusal leaves stdout empty
  * the content of the password file never appears on either stream
  * a read-only command leaves the install record byte-identical

``EdgeCaseTest`` adds the environment and argument edge cases that are not a
(state, command) cell.
"""

from __future__ import annotations

import json
import subprocess
import sys
import unittest

from tests.scenarios.harness import COMMANDS, FRESH_ONLY, SECRET, STATES, sandbox_for
from tests.support import REPO, Sandbox, one_object

Code = int | tuple[int, int] | frozenset[int]
MACHINE_DEPENDENT = frozenset({0, 1})   # preflight answers for the machine that runs the suite: ready, or blocked (a small CI disk)

FRESH: dict[str, Code] = {
    "status": 4, "info": 4, "version": 4, "guide": 4, "preflight": MACHINE_DEPENDENT, "catalog": 0, "help": 0, "help-topic": 0,
    "help-unknown-topic": (1, 0), "whats-new": 0, "persona-list": 0, "persona-plan": 0, "persona-show": 0,
    "persona-show-unknown": 2, "persona-bad-subcommand": 2, "persona-apply-no-yes": 4, "marketplace-list": 4,
    "marketplace-list-with-id": 4, "skills": 0, "logs": 0, "logs-bad-target": (1, 2), "mcp-status": 4, "mcp-doctor": 4,
    "mcp-remove-no-client": 2, "sql-no-statement": 4, "sql-select": 4, "sql-write-rejected": 4, "data-load-bad-option": 2,
    "update-dry-run": 4, "update-unknown-target": 4, "install-dry-run": 0, "install-with-argument": 2, "uninstall-dry-run": 0,
    "uninstall-addon-dry-run": 4, "repair-runtime-no-yes": 4, "migrate-no-args": 2, "autostart-with-argument": 2,
    "status-bad-option": 2, "unknown-command": 2, "start-fresh-only": 4, "stop-fresh-only": 4, "mcp-setup-fresh-only": 4,
}
INSTALLED: dict[str, Code] = {
    **FRESH, "status": 3, "info": 3, "version": 0, "guide": 0, "persona-apply-no-yes": 0, "marketplace-list": 0,
    "marketplace-list-with-id": 2, "mcp-status": 0, "mcp-doctor": 3, "sql-no-statement": 2, "sql-select": 3,
    "sql-write-rejected": 2, "update-dry-run": 0, "update-unknown-target": 2, "uninstall-addon-dry-run": 0,
    "repair-runtime-no-yes": 5,
}
CORRUPT: dict[str, Code] = {
    **INSTALLED, "status": 1, "info": 1, "version": 1, "guide": 1, "persona-list": 1, "persona-plan": 1,
    "persona-apply-no-yes": 1, "marketplace-list": 1, "marketplace-list-with-id": 1, "skills": 1, "logs": 1,
    "logs-bad-target": 1, "mcp-status": 1, "mcp-doctor": 1, "sql-no-statement": 1, "sql-select": 1, "sql-write-rejected": 1,
    "update-dry-run": 1, "update-unknown-target": 1, "install-dry-run": 1, "uninstall-dry-run": 1, "uninstall-addon-dry-run": 1,
    "repair-runtime-no-yes": 1,
}
EXPECTED: dict[str, dict[str, Code]] = {
    "fresh": FRESH, "recorded_running": INSTALLED, "stopped": INSTALLED, "no_database": INSTALLED,
    "interrupted_install": INSTALLED, "persona_recorded": INSTALLED, "corrupt_record": CORRUPT,
}
# The commands that may write the install record even without --yes: a complete persona plan is recorded as applied.
WRITES_RECORD = {"persona-apply-no-yes"}
RUNNABLE_PREFIXES = ("exakit ", "curl ", "sh ", "irm ", "powershell", "wsl ", "sudo ")


class MatrixTest(unittest.TestCase):
    boxes: dict[str, Sandbox] = {}

    @classmethod
    def setUpClass(cls) -> None:
        cls.boxes = {state: sandbox_for(state) for state in STATES}

    @classmethod
    def tearDownClass(cls) -> None:
        for box in cls.boxes.values():
            box.close()

    def _record(self, box: Sandbox) -> bytes | None:
        path = box.home / "manifest.json"
        return path.read_bytes() if path.exists() else None

    def _assert_code(self, done: subprocess.CompletedProcess, expected: int | frozenset[int]) -> None:
        detail = f"stdout={done.stdout[-300:]!r} stderr={done.stderr[-300:]!r}"
        if isinstance(expected, frozenset):
            self.assertIn(done.returncode, expected, detail)
        else:
            self.assertEqual(done.returncode, expected, detail)

    def _json_shape(self, code: int, doc: dict) -> None:
        if code == 4:
            self.assertIs(doc.get("installed"), False, doc)
        elif code == 2:
            self.assertEqual((doc.get("ok"), doc.get("rejected")), (False, True), doc)
            self.assertIn("error", doc)
        elif code in (1, 3, 5):
            self.assertTrue(doc.get("ok") is False or "status" in doc, doc)
        else:
            self.assertIsNot(doc.get("ok"), False, doc)
        if "remedy" in doc and doc["remedy"] is not None:
            self.assertIsInstance(doc["remedy"], str)
            self.assertTrue(doc["remedy"].startswith(RUNNABLE_PREFIXES), f"a remedy is a command, not a sentence: {doc['remedy']!r}")

    def check(self, state: str, cid: str) -> None:
        box = self.boxes[state]
        argv = COMMANDS[cid]
        expected = EXPECTED[state][cid]
        human_code, json_code = expected if isinstance(expected, tuple) else (expected, expected)
        before = self._record(box)
        human = box.run(*argv)
        with self.subTest(mode="human"):
            self._assert_code(human, human_code)
            self.assertFalse(any(line.startswith("{") for line in human.stdout.splitlines()), "no JSON in human mode")
            if human_code == 2:
                self.assertEqual(human.stdout.strip(), "", "a refusal goes to stderr, nothing on stdout")
            self.assertNotIn(SECRET, human.stdout + human.stderr)
        as_json = box.run(*argv, "--json")
        with self.subTest(mode="json"):
            self._assert_code(as_json, json_code)
            doc = one_object(as_json.stdout)
            self._json_shape(as_json.returncode, doc)
            if isinstance(json_code, frozenset) and as_json.returncode == 1:
                self.assertEqual(doc.get("status"), "blocked", doc)
                self.assertTrue(doc.get("failures"), doc)
            self.assertNotIn(SECRET, as_json.stdout + as_json.stderr)
        if cid not in WRITES_RECORD:
            self.assertEqual(self._record(box), before, f"{cid} must not change the install record")


def _make(state: str, cid: str):
    def test(self: MatrixTest) -> None:
        self.check(state, cid)
    test.__doc__ = f"{state}: exakit {' '.join(COMMANDS[cid])}"
    return test


for _state in STATES:
    for _cid in COMMANDS:
        if _cid in FRESH_ONLY and _state != "fresh":
            continue
        setattr(MatrixTest, f"test_{_state}__{_cid.replace('-', '_')}", _make(_state, _cid))


class EdgeCaseTest(unittest.TestCase):
    """The cells that are not a (state, command): environment answers, flag placement, paths, concurrency."""

    def test_an_unknown_persona_stops_the_install_before_anything_and_names_the_known_ones(self):
        box = Sandbox(manifest=None, env={"EXAKIT_PERSONA": "nope"})
        try:
            done = box.run("install", "--dry-run", "--json")
            self.assertEqual(done.returncode, 2, done.stderr)
            doc = one_object(done.stdout)
            for pid in ("analyst", "data-engineer", "data-scientist", "minimal"):
                self.assertIn(pid, doc["error"])
            self.assertFalse((box.home / "manifest.json").exists())
        finally:
            box.close()

    def test_a_known_persona_shapes_the_install_plan_without_installing(self):
        box = Sandbox(manifest=None, env={"EXAKIT_PERSONA": "analyst"})
        try:
            doc = one_object(box.run("install", "--dry-run", "--json").stdout)
            self.assertEqual(doc["status"], "dry-run")
            self.assertTrue(doc["pending"] > 0)
            self.assertFalse((box.home / "manifest.json").exists())
        finally:
            box.close()

    def test_global_flags_may_sit_anywhere_and_repeat(self):
        box = sandbox_for("stopped")
        try:
            first = one_object(box.run("--json", "status").stdout)
            second = one_object(box.run("status", "--json", "--json").stdout)
            third = one_object(box.run("status", "-j").stdout)
            self.assertEqual(list(first), list(second))
            self.assertEqual(list(first), list(third))
        finally:
            box.close()

    def test_json_output_carries_no_colour_even_when_no_color_is_unset(self):
        box = sandbox_for("stopped")
        env = {k: v for k, v in box.env.items() if k != "NO_COLOR"}
        try:
            done = subprocess.run([sys.executable, "-m", "exakit", "status", "--json"], cwd=REPO, env=env, capture_output=True, text=True, check=False)
            self.assertNotIn("\x1b", done.stdout)
            one_object(done.stdout)
        finally:
            box.close()

    def test_a_kit_home_with_spaces_in_its_path_works(self):
        box = Sandbox(manifest=None)
        try:
            spaced = box.user_home / "kit home"
            spaced.mkdir()
            done = box.run("status", "--json", env={"EXAKIT_HOME": str(spaced)})
            self.assertEqual(done.returncode, 4, done.stderr)
            self.assertIs(one_object(done.stdout)["installed"], False)
            self.assertEqual(box.run("install", "--dry-run", env={"EXAKIT_HOME": str(spaced)}).returncode, 0)
        finally:
            box.close()

    def test_a_corrupt_record_is_one_refusal_naming_the_installer_never_a_traceback(self):
        box = sandbox_for("corrupt_record")
        try:
            human = box.run("status")
            self.assertEqual(human.returncode, 1)
            self.assertIn("exakit install", human.stderr)
            self.assertNotIn("Traceback", human.stderr + human.stdout)
            doc = one_object(box.run("status", "--json").stdout)
            self.assertEqual((doc["ok"], doc["remedy"]), (False, "exakit install"))
        finally:
            box.close()

    def test_two_state_queries_at_once_each_answer_one_object(self):
        box = sandbox_for("stopped")
        try:
            procs = [subprocess.Popen([sys.executable, "-m", "exakit", "status", "--json"], cwd=REPO, env=box.env,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(3)]
            for proc in procs:
                out, _err = proc.communicate(timeout=120)
                self.assertEqual(proc.returncode, 3)
                self.assertIn("status", one_object(out))
        finally:
            box.close()

    def test_every_documented_command_answers_help_with_the_same_exit_code_in_both_modes(self):
        box = sandbox_for("stopped")
        try:
            commands = json.loads((REPO / "help" / "exakit.json").read_text(encoding="utf-8"))["commands"]
            for entry in commands:
                with self.subTest(command=entry["command"]):
                    human = box.run(entry["command"], "--help")
                    as_json = box.run(entry["command"], "--help", "--json")
                    self.assertEqual(human.returncode, 0, human.stderr)
                    self.assertEqual(as_json.returncode, 0, as_json.stderr)
                    doc = one_object(as_json.stdout)
                    if "search" in doc:              # a command page is the search that finds it; a document answers itself
                        self.assertIn(entry["command"], [c["command"] for c in doc["commands"]], doc)
        finally:
            box.close()
