"""The Textual screens, headless: the renderer's calls reach the app from a worker thread, the keys answer the modal questions.

Skipped where Textual is not installed; the CI test job installs the pinned version.
"""

from __future__ import annotations

import importlib.util
import io
import unittest
from unittest import mock

from exakit.domain.errors import Failed
from exakit.domain.plan import Plan, Step, StepState
from exakit.domain.result import Result
from exakit.ui.console import ConsoleRenderer
from exakit.ui.widgets import PLAIN, Option

HAVE_TEXTUAL = importlib.util.find_spec("textual") is not None


def _mirror():
    buffer = io.StringIO()
    return ConsoleRenderer(palette=PLAIN, out=buffer, err=buffer, interactive=False), buffer


@unittest.skipUnless(HAVE_TEXTUAL, "textual is not installed here")
class ScreensTest(unittest.IsolatedAsyncioTestCase):
    async def _run(self, job, keys=(), size=(120, 40)):
        """Run ``job`` inside the app from its worker thread; press ``keys`` once a question is up; return (app, transcript)."""
        from exakit.ui.tui.app import KitApp
        from exakit.ui.tui.renderer import TuiRenderer
        from exakit.ui.tui.panels import PlanPanel, StatusBar
        mirror, buffer = _mirror()
        app = KitApp(title="Exasol Personal Local Starter Kit", subtitle="test")
        renderer = TuiRenderer(app, mirror)
        app.job = lambda: job(renderer)
        async with app.run_test(size=size) as pilot:
            for _ in range(100):
                await pilot.pause(0.02)
                if keys and len(app.screen_stack) > 1:
                    break
                if app.done:
                    break
            for key in keys:
                await pilot.press(key)
                await pilot.pause(0.02)
            for _ in range(200):
                if app.done:
                    break
                await pilot.pause(0.02)
            self.assertTrue(app.done, "the command never finished")
            final = app.query_one(StatusBar).final
            rows = {key: text.plain for key, text in app.query_one(PlanPanel).texts.items()}
            await pilot.press("enter")
        return app, buffer.getvalue(), final, rows

    async def test_lines_and_steps_reach_the_app_and_the_transcript(self):
        def job(ui):
            ui.banner("Exasol Personal Local Starter Kit", "Platform: macos (arm64)")
            ui.info("hello")
            ui.ok("done")
            plan = Plan("Install", [Step("components", "exapump", StepState.PENDING, label="exapump"), Step("datasets", "tpch", StepState.DONE)])
            ui.plan(plan)
            ui.step_begin(plan.steps[0])
            with ui.busy("Downloading"):
                pass
            with ui.progress("Downloading exapump") as report:
                report(50, 100)
            ui.step_end(plan.steps[0], ok=True)
            return Result(True, "ok")

        app, transcript, final, rows = await self._run(job)
        self.assertEqual(app.outcome().status, "ok")
        self.assertIn("- hello", transcript)
        self.assertIn("[ok] done", transcript)
        self.assertIn("exapump", transcript)
        self.assertEqual(final, "Finished - press Enter to close")
        self.assertEqual(set(rows), {"components/exapump", "datasets/tpch"})
        self.assertIn("✓ exapump", rows["components/exapump"])

    async def test_select_answers_with_the_arrow_keys(self):
        answers = []

        def job(ui):
            answers.append(ui.select("Pick one", [Option("a", "A"), Option("b", "B"), Option("c", "C")], default=1))
            return Result(True, "ok")

        _app, transcript, _final, _rows = await self._run(job, keys=("down", "enter"))
        self.assertEqual(answers, ["b"])
        self.assertIn("? Pick one b", transcript)

    async def test_select_takes_a_digit_and_escape_backs_out(self):
        answers = []

        def job(ui):
            answers.append(ui.select("Pick one", [Option("a", "A"), Option("b", "B"), Option("c", "C")], default=1))
            answers.append(ui.select("Again", [Option("a", "A"), Option("b", "B")], default=1))
            return Result(True, "ok")

        await self._run(job, keys=("3", "escape"))
        self.assertEqual(answers, ["c", None])

    async def test_checkboxes_tick_with_space_and_continue_with_enter(self):
        answers = []

        def job(ui):
            answers.append(ui.checkboxes("Datasets", [Option("tpch", "TPC-H"), Option("energy", "Energy"), Option("weather", "Weather")], defaults=["tpch"]))
            return Result(True, "ok")

        await self._run(job, keys=("down", "space", "enter"))
        self.assertEqual(answers, [["tpch", "energy"]])

    async def test_checkboxes_a_and_n_take_all_and_none(self):
        answers = []

        def job(ui):
            answers.append(ui.checkboxes("Datasets", [Option("tpch", "TPC-H"), Option("energy", "Energy")], defaults=[]))
            answers.append(ui.checkboxes("Datasets", [Option("tpch", "TPC-H"), Option("energy", "Energy")], defaults=["tpch"]))
            return Result(True, "ok")

        await self._run(job, keys=("a", "enter", "n", "enter"))
        self.assertEqual(answers, [["tpch", "energy"], []])

    async def test_confirm_and_prompt(self):
        answers = []

        def job(ui):
            answers.append(ui.confirm("Install the kit?", default=True))
            answers.append(ui.confirm("Really?", default=True))
            answers.append(ui.prompt("Schema", default="STARTER_KIT"))
            return Result(True, "ok")

        await self._run(job, keys=("enter", "n", "enter"))
        self.assertEqual(answers, [True, False, "STARTER_KIT"])

    async def test_a_failure_in_the_command_is_carried_out_of_the_app(self):
        def job(ui):
            ui.error("Setup failed")
            raise Failed("the step did not finish", remedy="exakit install")

        app, transcript, final, _rows = await self._run(job)
        self.assertIn("[x] Setup failed", transcript)
        self.assertTrue(final.startswith("Stopped"))
        with self.assertRaises(Failed) as caught:
            app.outcome()
        self.assertEqual(caught.exception.remedy, "exakit install")


class WantedTest(unittest.TestCase):
    def test_only_interactive_flows_in_a_utf8_terminal_want_the_screens(self):
        from exakit.ui import tui

        class Tty(io.StringIO):
            def isatty(self):
                return True

        env = {"LANG": "en_US.UTF-8", "TERM": "xterm-256color"}
        with mock.patch("exakit.ui.tui.has_terminal", lambda out: True):
            self.assertTrue(tui.wanted(env, Tty(), command="install", args=[], json=False, dry_run=False))
            self.assertTrue(tui.wanted(env, Tty(), command="persona", args=["apply", "analyst"], json=False, dry_run=False))
            self.assertFalse(tui.wanted(env, Tty(), command="persona", args=[], json=False, dry_run=False))
            self.assertFalse(tui.wanted(env, Tty(), command="status", args=[], json=False, dry_run=False))
            self.assertFalse(tui.wanted(env, Tty(), command="install", args=[], json=True, dry_run=False))
            self.assertFalse(tui.wanted(env, Tty(), command="install", args=[], json=False, dry_run=True))
            self.assertFalse(tui.wanted({**env, "EXAKIT_TUI": "0"}, Tty(), command="install", args=[], json=False, dry_run=False))
            self.assertFalse(tui.wanted({**env, "EXAKIT_DRY_RUN": "1"}, Tty(), command="install", args=[], json=False, dry_run=False))
            self.assertFalse(tui.wanted({"LANG": "C"}, Tty(), command="install", args=[], json=False, dry_run=False))
        self.assertFalse(tui.wanted(env, io.StringIO(), command="install", args=[], json=False, dry_run=False))

    def test_load_fails_softly_on_a_folder_without_the_toolkit(self):
        import tempfile
        from pathlib import Path
        from exakit.ui import tui
        if HAVE_TEXTUAL:
            self.skipTest("textual is importable here, so load() cannot fail")
        with tempfile.TemporaryDirectory() as tmp:
            self.assertFalse(tui.load(Path(tmp)))

