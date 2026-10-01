import unittest

from exakit.domain.errors import BadInput
from exakit.domain.ids import (
    CLIENT_IDS, catalog_id, env_var, is_skip_word, is_token, manifest_key, parse_client_selection,
)


class IdsTest(unittest.TestCase):
    def test_tokens_are_lowercase_ascii_only(self):
        for good in ("tpch", "dash-server", "json_tables", "kit2"):
            self.assertTrue(is_token(good), good)
        for bad in ("", "Dash", "a b", "../x", "x;y", "-lead"):
            self.assertFalse(is_token(bad), bad)

    def test_manifest_and_catalog_ids_round_trip(self):
        self.assertEqual(manifest_key("dash-server"), "dash_server")
        self.assertEqual(catalog_id("dash_server"), "dash-server")

    def test_env_var_names_follow_the_documented_pattern(self):
        self.assertEqual(env_var("dash-server", "VERSION"), "EXAKIT_DASH_SERVER_VERSION")
        self.assertEqual(env_var("exapump", "BIN"), "EXAKIT_EXAPUMP_BIN")


class ClientSelectionTest(unittest.TestCase):
    def test_all_means_every_client_in_kit_order(self):
        self.assertEqual(parse_client_selection("all"), list(CLIENT_IDS))
        self.assertEqual(parse_client_selection("ALL"), list(CLIENT_IDS))

    def test_claude_covers_both_surfaces(self):
        self.assertEqual(parse_client_selection("claude"), ["claude_desktop", "claude_code"])

    def test_names_dedupe_and_keep_kit_order(self):
        self.assertEqual(parse_client_selection("cursor,claude,cursor"), ["claude_desktop", "claude_code", "cursor"])

    def test_aliases_and_numbers_are_accepted(self):
        self.assertEqual(parse_client_selection("copilot/gemini 7"), ["vscode_copilot", "gemini_cli", "continue"])

    def test_unknown_name_is_bad_input_naming_the_words(self):
        with self.assertRaises(BadInput) as ctx:
            parse_client_selection("claude,notepad")
        self.assertIn("notepad", str(ctx.exception))
        self.assertIn("claude, codex", str(ctx.exception))

    def test_empty_is_bad_input(self):
        with self.assertRaises(BadInput):
            parse_client_selection(" , ")

    def test_skip_words(self):
        self.assertTrue(is_skip_word("skip"))
        self.assertTrue(is_skip_word(" NONE "))
        self.assertFalse(is_skip_word("all"))


if __name__ == "__main__":
    unittest.main()
