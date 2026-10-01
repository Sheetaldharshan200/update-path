"""Downloads report their bytes as they land, and the renderers draw that honestly."""

from __future__ import annotations

import io
import unittest

from exakit.adapters.net.http import _copy
from exakit.ui.console import ConsoleRenderer
from exakit.ui.spinner import elapsed_text
from exakit.ui.silent import SilentRenderer
from exakit.ui.widgets import FANCY, PLAIN, human_size, progress_bar


class _Response:
    def __init__(self, body: bytes, length: str | None) -> None:
        self._buf = io.BytesIO(body)
        self.headers = {"Content-Length": length} if length is not None else {}

    def read(self, n: int) -> bytes:
        return self._buf.read(n)


class CopyTest(unittest.TestCase):
    def test_every_chunk_and_the_final_size_reach_the_callback(self):
        seen = []
        out = io.BytesIO()
        _copy(_Response(b"x" * (600 * 1024), str(600 * 1024)), out, lambda done, total: seen.append((done, total)))
        self.assertEqual(out.getvalue(), b"x" * (600 * 1024))
        self.assertEqual(seen[-1], (600 * 1024, 600 * 1024))
        self.assertTrue(all(total == 600 * 1024 for _, total in seen))
        self.assertGreaterEqual(len(seen), 3)

    def test_without_a_content_length_the_total_is_unknown_until_the_end(self):
        seen = []
        _copy(_Response(b"abc", None), io.BytesIO(), lambda done, total: seen.append((done, total)))
        self.assertEqual(seen, [(3, None), (3, 3)])

    def test_no_callback_is_fine(self):
        out = io.BytesIO()
        _copy(_Response(b"abc", "3"), out, None)
        self.assertEqual(out.getvalue(), b"abc")


class BarTest(unittest.TestCase):
    def test_sizes_and_the_bar(self):
        self.assertEqual(human_size(500), "1 KB")
        self.assertEqual(human_size(118872), "116 KB")
        self.assertEqual(human_size(13001728), "12.4 MB")
        self.assertEqual(progress_bar(0, 100, width=4), "[....]   0%  1 KB/1 KB")
        self.assertEqual(progress_bar(50, 100, width=4), "[##..]  50%  1 KB/1 KB")
        self.assertEqual(progress_bar(100, 100, width=4), "[####] 100%  1 KB/1 KB")
        self.assertEqual(progress_bar(2048, None), "2 KB")

    def test_elapsed_text(self):
        self.assertEqual(elapsed_text(1.5), "")
        self.assertEqual(elapsed_text(12.9), "12s")
        self.assertEqual(elapsed_text(65), "1m 05s")


class RendererProgressTest(unittest.TestCase):
    def test_plain_mode_prints_a_line_at_each_quarter_only(self):
        out = io.StringIO()
        r = ConsoleRenderer(palette=PLAIN, out=out, interactive=False)
        with r.progress("Downloading exapump") as report:
            for done in (10, 20, 30, 50, 60, 80, 100):
                report(done, 100)
        lines = [line for line in out.getvalue().splitlines() if line.strip()]
        self.assertEqual(len(lines), 4)
        self.assertIn("Downloading exapump: [", lines[0])
        self.assertTrue(lines[-1].rstrip().endswith("100%  1 KB/1 KB"))

    def test_plain_mode_says_nothing_when_the_total_is_unknown(self):
        out = io.StringIO()
        r = ConsoleRenderer(palette=PLAIN, out=out, interactive=False)
        with r.progress("Downloading") as report:
            report(10, None)
        self.assertEqual(out.getvalue(), "")

    def test_fancy_mode_puts_the_bar_on_the_live_spinner(self):
        out = io.StringIO()
        r = ConsoleRenderer(palette=FANCY, out=out, interactive=True)
        with r.progress("Downloading exapump") as report:
            report(50, 100)
            self.assertIsNotNone(r._spin)
            self.assertIn("Downloading exapump [##########..........]  50%", r._spin.detail)
        self.assertIsNone(r._spin)
        self.assertIn("\x1b[?25h", out.getvalue())

    def test_a_line_written_under_a_spinner_clears_the_spinner_line_first(self):
        out = io.StringIO()
        r = ConsoleRenderer(palette=FANCY, out=out, interactive=True)
        with r.busy("Deploying"):
            r.info("the launcher said hello")
        text = out.getvalue()
        self.assertIn("the launcher said hello\n", text)
        self.assertTrue(text[text.index("the launcher said hello") - 40:].startswith(("\r\x1b[K", "Deploying")) or "\r\x1b[K    " in text)
        before = text[:text.index("the launcher said hello")]
        self.assertTrue(before.endswith(("\x1b[0m ", "• ")), before[-30:])
        self.assertIn("\r\x1b[K    ", before[-40:])

    def test_the_silent_renderer_logs_the_label_and_draws_nothing(self):
        from tests.unit.fakes import ListLog
        log = ListLog()
        with SilentRenderer(log).progress("Downloading exapump") as report:
            report(1, 2)
        self.assertTrue(any("Downloading exapump" in str(line) for line in log.lines))
