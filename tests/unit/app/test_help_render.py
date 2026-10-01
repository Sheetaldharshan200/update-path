"""The help renderer over the shipped documents: every command page, every component page, colour on and off, the JSON payloads."""

from __future__ import annotations

import json
import unittest

from exakit.app import help as help_app
from tests.support import REPO

DOCS = help_app.load_docs(REPO / "help")


class HelpRenderTest(unittest.TestCase):
    def test_every_command_page_renders_in_colour_and_plain_at_two_widths(self):
        rows = help_app.catalog_rows(DOCS, include_hidden=True)
        self.assertGreater(len(rows), 30)
        for row in rows:
            for color, width in ((False, 80), (True, 120), (False, 40)):
                with self.subTest(command=row["invocation"] if "invocation" in row else row["command"], color=color, width=width):
                    text, code = help_app.render(DOCS, "command", row["command"], color=color, width=width)
                    self.assertEqual(code, 0, text)
                    self.assertIn(row["command"].split()[0], text)

    def test_every_component_page_and_the_overview_render(self):
        for doc_id in DOCS:
            with self.subTest(component=doc_id):
                text, code = help_app.render(DOCS, "component", doc_id, color=False, width=100)
                self.assertEqual(code, 0, text)
        text, code = help_app.render(DOCS, "overview", "", color=True, width=100)
        self.assertEqual(code, 0)
        text, code = help_app.render(DOCS, "all", "", color=False, width=100)
        self.assertEqual(code, 0)

    def test_an_unknown_page_is_a_not_found_with_exit_1(self):
        text, code = help_app.render(DOCS, "command", "nope", color=False, width=80)
        self.assertEqual(code, 1)
        self.assertIn("nope", text)

    def test_the_json_payloads_are_serialisable_and_consistent(self):
        everything = help_app.json_payload(DOCS, "all")
        self.assertEqual(everything["count"], len(everything["commands"]))
        json.dumps(everything)
        found = help_app.json_payload(DOCS, "status")
        self.assertEqual(found["search"], "status")
        self.assertTrue(any(c["command"] == "status" for c in found["commands"]))
        self.assertEqual(help_app.json_payload(DOCS, "exakit")["id"], "exakit")
        self.assertEqual(help_app.json_payload(DOCS, "zzz")["count"], 0)
