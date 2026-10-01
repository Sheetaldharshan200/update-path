import io
import unittest

from exakit.domain.plan import Plan, Step, StepState
from exakit.ui import make_renderer, wants_fancy
from exakit.ui.console import ConsoleRenderer
from exakit.ui.silent import SilentRenderer
from exakit.ui.widgets import FANCY, PLAIN, Option, visible_len, wrap


def _plain(interactive=False, answers=()):
    out = io.StringIO()
    it = iter(answers)
    r = ConsoleRenderer(palette=PLAIN, out=out, interactive=interactive, reader=lambda: next(it, ""))
    return r, out


class WidgetsTest(unittest.TestCase):
    def test_visible_len_ignores_escapes(self):
        self.assertEqual(visible_len("\x1b[1mabc\x1b[0m"), 3)
        self.assertEqual(visible_len("\x1b]8;;https://x\x1b\\link\x1b]8;;\x1b\\"), 4)

    def test_wrap_breaks_on_words_and_splits_long_words(self):
        self.assertEqual(wrap("one two three", 8), ["one two", "three"])
        self.assertEqual(wrap("abcdefghij", 4), ["abcd", "efgh", "ij"])
        self.assertEqual(wrap("short", 10), ["short"])

    def test_palettes_are_the_legacy_glyphs(self):
        self.assertEqual((PLAIN.tick, PLAIN.cross, PLAIN.bullet, PLAIN.arrow), ("[ok]", "[x]", "-", ">"))
        self.assertEqual((FANCY.tick, FANCY.cross, FANCY.bullet, FANCY.arrow), ("✓", "✗", "•", "▸"))
        self.assertEqual(FANCY.accent, "\x1b[38;5;35m")


class ConsoleTest(unittest.TestCase):
    def test_message_levels_use_the_three_indent_levels(self):
        r, out = _plain()
        r.heading("Step")
        r.info("action")
        r.ok("done")
        self.assertEqual(out.getvalue(), "  > Step\n    - action\n      [ok] done\n")

    def test_panel_boxes_its_lines(self):
        r, out = _plain()
        r.panel("Title", ["alpha", "a longer line"])
        lines = out.getvalue().splitlines()
        self.assertTrue(lines[0].startswith("  +- Title "))
        self.assertTrue(lines[0].endswith("+"))
        width = len("a longer line") + 2                      # widest line plus breathing room
        self.assertEqual(lines[1], "  | alpha" + " " * (width - 5 - 2) + " |")
        self.assertEqual(lines[2], "  | a longer line" + " " * (width - 13 - 2) + " |")
        self.assertEqual(lines[3], "  +" + "-" * width + "+")
        self.assertTrue(all(len(line) == len(lines[3]) for line in lines[1:3]))

    def test_plan_renders_every_state(self):
        r, out = _plain()
        plan = Plan("Persona: Analyst (analyst)", [
            Step("datasets", "tpch", StepState.DONE),
            Step("addons", "dash-server", StepState.PENDING),
            Step("addons", "exasol-vscode", StepState.SKIPPED, "VS Code was not found"),
            Step("skills", "skills", StepState.FAILED, "copy failed"),
        ])
        r.plan(plan)
        text = out.getvalue()
        for needle in ("Sample data:", "[ok]  tpch (already there)", "+  dash-server", "-  exasol-vscode (skipped)",
                       "VS Code was not found", "[x]  skills (failed)"):
            self.assertIn(needle, text)

    def test_steps_print_begin_and_end_in_plain_mode(self):
        r, out = _plain()
        step = Step("addons", "dash-server", StepState.PENDING)
        r.step_begin(step)
        step.state = StepState.DONE
        r.step_end(step)
        self.assertEqual(out.getvalue(), "  > Add-ons: dash-server...\n  [ok] Add-ons: dash-server\n")

    def test_questions_take_defaults_without_a_terminal(self):
        r, _ = _plain(interactive=False)
        self.assertTrue(r.confirm("Go?", True))
        self.assertFalse(r.confirm("Go?", False))
        self.assertEqual(r.prompt("Name", "x"), "x")
        self.assertEqual(r.select("Pick", [Option("a", "A"), Option("b", "B")], default=2), "b")
        self.assertEqual(r.checkboxes("Pick", [Option("a", "A"), Option("b", "B", disabled=True)], ["a", "b"]), ["a"])

    def test_questions_read_answers_with_a_terminal(self):
        r, _ = _plain(interactive=True, answers=["n", "", "2", "0", "1,2", "a"])
        self.assertFalse(r.confirm("Go?", True))
        self.assertEqual(r.prompt("Name", "dflt"), "dflt")
        opts = [Option("a", "A"), Option("b", "B")]
        self.assertEqual(r.select("Pick", opts), "b")
        self.assertIsNone(r.select("Pick", opts))
        self.assertEqual(r.checkboxes("Pick", opts, []), ["a", "b"])
        self.assertEqual(r.checkboxes("Pick", opts, []), ["a", "b"])


class ArrowMenuTest(unittest.TestCase):
    """The menus a terminal gets: arrows move, Space toggles, Enter continues, a/n all/none, Esc backs out, digits pick."""

    def _renderer(self, keys: list[str]) -> tuple[ConsoleRenderer, io.StringIO]:
        out = io.StringIO()
        it = iter(keys)
        return ConsoleRenderer(palette=PLAIN, out=out, interactive=True, reader=lambda: "", keys=lambda: next(it)), out

    def test_checkboxes_toggle_with_space_and_continue_with_enter(self):
        opts = [Option("a", "A"), Option("b", "B"), Option("c", "C", disabled=True)]
        r, out = self._renderer(["down", "space", "up", "space", "enter"])
        self.assertEqual(r.checkboxes("Pick", opts, ["a"]), ["b"])
        self.assertIn("[x] B", out.getvalue())
        self.assertIn("Space toggles", out.getvalue())

    def test_checkboxes_all_none_digits_and_escape(self):
        opts = [Option("a", "A"), Option("b", "B")]
        r, _ = self._renderer(["n", "a", "enter"])
        self.assertEqual(r.checkboxes("Pick", opts, []), ["a", "b"])
        r, _ = self._renderer(["a", "2", "enter"])
        self.assertEqual(r.checkboxes("Pick", opts, []), ["a"])
        r, _ = self._renderer(["space", "esc"])
        self.assertEqual(r.checkboxes("Pick", opts, ["b"]), ["b"], "escape keeps the defaults")

    def test_select_moves_and_chooses(self):
        opts = [Option("a", "A"), Option("b", "B"), Option("c", "C")]
        r, out = self._renderer(["down", "down", "enter"])
        self.assertEqual(r.select("Pick", opts), "c")
        self.assertIn("(*) C", out.getvalue())
        r, _ = self._renderer(["2"])
        self.assertEqual(r.select("Pick", opts), "b")
        r, _ = self._renderer(["up", "esc"])
        self.assertIsNone(r.select("Pick", opts))

    def test_without_a_key_reader_the_numbered_prompts_remain(self):
        it = iter(["2"])
        r = ConsoleRenderer(palette=PLAIN, out=io.StringIO(), interactive=True, reader=lambda: next(it))
        self.assertEqual(r.select("Pick", [Option("a", "A"), Option("b", "B")]), "b")


class BannerTest(unittest.TestCase):
    def test_the_fancy_banner_draws_the_wordmark_with_the_green_x(self):
        out = io.StringIO()
        ConsoleRenderer(palette=FANCY, out=out, interactive=False).banner("Exasol Personal Local Starter Kit", "sub")
        text = out.getvalue()
        self.assertIn("███████╗", text)
        self.assertIn(FANCY.green, text)
        self.assertIn("Exasol Personal Local Starter Kit", text)
        self.assertIn("sub", text)

    def test_the_plain_banner_is_the_title_alone(self):
        out = io.StringIO()
        ConsoleRenderer(palette=PLAIN, out=out, interactive=False).banner("Title")
        self.assertNotIn("█", out.getvalue())
        self.assertIn("Title", out.getvalue())


class FactoryTest(unittest.TestCase):
    def test_json_gives_the_silent_renderer(self):
        r = make_renderer(json=True, env={})
        self.assertIsInstance(r, SilentRenderer)
        self.assertFalse(r.interactive)
        self.assertTrue(r.confirm("q", True))

    def test_a_pipe_is_plain_and_non_interactive(self):
        out = io.StringIO()
        r = make_renderer(json=False, env={"LANG": "en_US.UTF-8"}, out=out)
        self.assertFalse(r.fancy)
        self.assertFalse(r.interactive)

    def test_fancy_rule(self):
        class Tty(io.StringIO):
            def isatty(self):
                return True
        self.assertTrue(wants_fancy({"LANG": "en_US.UTF-8"}, Tty()))
        self.assertFalse(wants_fancy({"LANG": "C"}, Tty()))
        self.assertFalse(wants_fancy({"LANG": "en_US.UTF-8", "NO_COLOR": "1"}, Tty()))
        self.assertFalse(wants_fancy({"LANG": "en_US.UTF-8", "TERM": "dumb"}, Tty()))
        self.assertFalse(wants_fancy({"LANG": "en_US.UTF-8", "EXAKIT_NO_FANCY": "1"}, Tty()))
        self.assertFalse(wants_fancy({"LANG": "en_US.UTF-8"}, io.StringIO()))


if __name__ == "__main__":
    unittest.main()
