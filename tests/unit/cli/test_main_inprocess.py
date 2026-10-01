"""The CLI entry point in process: every documented command's help page, the read-only answers on a fresh and a recorded kit, the refusals."""

from __future__ import annotations

import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from exakit.cli import main as cli
from tests.support import MANIFEST, REPO, bare_path


class _Run:
    """One in-process call: exit code, stdout, stderr."""

    def __init__(self, home: Path, user_home: Path, *argv: str, env: dict[str, str] | None = None) -> None:
        base = {k: v for k, v in os.environ.items() if not k.startswith("EXAKIT_")}
        base.update({"HOME": str(user_home), "USERPROFILE": str(user_home), "PATH": bare_path(), "EXAKIT_HOME": str(home),
                     "EXAKIT_BIN_DIR": str(home.parent / "bin"), "EXAKIT_VERSIONS_TTL": "999999", "EXAKIT_NO_UPDATE_NOTICE": "1",
                     "EXAKIT_ABOUT_OFFLINE": "1", "NO_COLOR": "1", **(env or {})})
        out, err = io.StringIO(), io.StringIO()
        # No terminal, whatever the developer's shell has: a menu must never read /dev/tty from a test.
        with mock.patch.dict(os.environ, base, clear=True), mock.patch("exakit.ui.has_terminal", return_value=False), \
                mock.patch("sys.stdin", io.StringIO()), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.code = cli.main(list(argv))     # an empty stdin: `exakit sql` reads it when no statement is given
        self.out, self.err = out.getvalue(), err.getvalue()

    def doc(self) -> dict:
        lines = [line for line in self.out.splitlines() if line.strip()]
        assert len(lines) == 1, self.out
        return json.loads(lines[0])


class MainInProcessTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.home = root / "home"
        self.home.mkdir()
        self.user = root / "user"
        self.user.mkdir()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_cli(self, *argv: str, recorded: bool = False, env: dict[str, str] | None = None) -> _Run:
        manifest = self.home / "manifest.json"
        if recorded:
            manifest.write_text(json.dumps(MANIFEST), encoding="utf-8")
        elif manifest.exists():
            manifest.unlink()
        return _Run(self.home, self.user, *argv, env=env)

    def test_every_documented_command_renders_its_help_page_in_both_modes(self):
        commands = json.loads((REPO / "help" / "exakit.json").read_text(encoding="utf-8"))["commands"]
        for entry in commands:
            with self.subTest(command=entry["command"]):
                human = self.run_cli(entry["command"], "--help")
                self.assertEqual(human.code, 0, human.err)
                self.assertIn(entry["command"], human.out)
                as_json = self.run_cli(entry["command"], "--help", "--json")
                self.assertEqual(as_json.code, 0)
                as_json.doc()

    def test_the_overview_the_catalog_and_the_search(self):
        self.assertEqual(self.run_cli().code, 0)
        self.assertEqual(self.run_cli("help", "--all").code, 0)
        self.assertEqual(self.run_cli("catalog").code, 0)
        self.assertGreater(self.run_cli("catalog", "--json").doc()["count"], 30)
        self.assertEqual(self.run_cli("catalog", "status", "--json").doc()["search"], "status")
        self.assertEqual(self.run_cli("whats-new", "--json").code, 0)
        self.assertEqual(self.run_cli("exapump").code, 0)                    # a bare component id is its page

    def test_a_fresh_kit_answers_not_installed_and_still_lists_personas_and_skills(self):
        for argv in (("status",), ("info",), ("version",), ("guide",), ("mcp-status",), ("start",), ("logs", "setup")):
            with self.subTest(argv=argv):
                done = self.run_cli(*argv, "--json")
                self.assertIn(done.code, (4, 2), done.out)
        self.assertEqual(self.run_cli("persona", "list", "--json").doc()["installed"], True)
        self.assertEqual(self.run_cli("skills", "--json").code, 0)
        self.assertEqual(self.run_cli("preflight", "--json").doc()["installed"], True)
        self.assertEqual(self.run_cli("install", "--dry-run", "--json").doc()["status"], "dry-run")

    def test_a_recorded_kit_answers_its_state(self):
        status = self.run_cli("status", "--json", recorded=True)
        self.assertEqual(status.code, 3)
        self.assertEqual(status.doc()["installed"], True)
        self.assertEqual(self.run_cli("status", recorded=True).code, 3)
        self.assertEqual(self.run_cli("version", "--json", recorded=True).code, 0)
        self.assertEqual(self.run_cli("version", recorded=True).code, 0)
        self.assertEqual(self.run_cli("info", recorded=True).code, 3)
        self.assertEqual(self.run_cli("logs", recorded=True).code, 0)
        self.assertEqual(self.run_cli("skills", recorded=True).code, 0)
        self.assertEqual(self.run_cli("marketplace", "--list", recorded=True).code, 0)
        self.assertEqual(self.run_cli("persona", "plan", "analyst", recorded=True).code, 0)
        self.assertEqual(self.run_cli("uninstall", "--dry-run", recorded=True).code, 0)

    def test_refusals_are_exit_2_in_both_modes_and_leave_stdout_empty_in_human_mode(self):
        for argv in (("bogus",), ("status", "--nope"), ("persona", "show", "nope"), ("sql",), ("migrate",), ("install", "extra")):
            with self.subTest(argv=argv):
                human = self.run_cli(*argv, recorded=True)
                self.assertEqual(human.code, 2, human.err)
                self.assertEqual(human.out.strip(), "")
                as_json = self.run_cli(*argv, "--json", recorded=True)
                self.assertEqual(as_json.code, 2)
                self.assertEqual(as_json.doc()["rejected"], True)

    def test_an_unexpected_error_is_one_refusal_and_debug_re_raises_it(self):
        with mock.patch.dict(cli.HANDLERS, {"status": mock.Mock(side_effect=RuntimeError("boom"))}):
            done = self.run_cli("status", "--json", recorded=True)
            self.assertEqual(done.code, 1)
            self.assertIn("Unexpected error: RuntimeError: boom", done.doc()["error"])
            human = self.run_cli("status", recorded=True)
            self.assertEqual(human.code, 1)
            self.assertNotIn("Traceback", human.err + human.out)
            with self.assertRaises(RuntimeError):
                self.run_cli("status", recorded=True, env={"EXAKIT_DEBUG": "1"})
