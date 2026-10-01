"""The add-on description: the GitHub About once a day, sanitised and capped, the tagline behind it, never the network when offline."""

from __future__ import annotations

import json
import os
import time
import unittest

from exakit.app import about
from tests.unit.app.harness import MANIFEST, Sandbox


class AboutTest(unittest.TestCase):
    def _addon(self, box):
        return box.ctx.catalog.addon("dash-server")

    def test_fetches_sanitises_caps_and_caches(self):
        box = Sandbox(manifest=MANIFEST, env={"EXAKIT_ABOUT_MAX_LEN": "40"})
        try:
            addon = self._addon(box)
            repo = about.repo_of(box.ctx, addon)
            self.assertEqual(repo, "exasol-labs/dash-server")
            box.downloader.pages[f"https://api.github.com/repos/{repo}"] = json.dumps(
                {"description": "Agent-operated\x1b[31m Dash\x1b[0m hosting\n for live dashboards on your database, and more words"})
            text = about.description(box.ctx, addon)
            self.assertEqual(text, "Agent-operated Dash hosting for live")
            self.assertEqual((box.ctx.paths.about_cache / "dash-server.txt").read_text().strip(), text)
            calls = len(box.downloader.calls)
            self.assertEqual(about.description(box.ctx, addon), text)
            self.assertEqual(len(box.downloader.calls), calls, "a fresh cache is not refetched")
        finally:
            box.close()

    def test_offline_and_a_failed_fetch_fall_back_to_the_tagline(self):
        box = Sandbox(manifest=MANIFEST, env={"EXAKIT_ABOUT_OFFLINE": "1"})
        try:
            self.assertEqual(about.description(box.ctx, self._addon(box)), "Agent-operated Dash hosting for live dashboards on your database")
            self.assertEqual(box.downloader.calls, [])
        finally:
            box.close()
        box = Sandbox(manifest=MANIFEST)
        try:
            text = about.description(box.ctx, self._addon(box))
            self.assertEqual(text, "Agent-operated Dash hosting for live dashboards on your database")
            self.assertTrue((box.ctx.paths.about_cache / ".attempt-dash-server").exists())
            calls = len(box.downloader.calls)
            about.description(box.ctx, self._addon(box))
            self.assertEqual(len(box.downloader.calls), calls, "a failed attempt is not retried within the TTL")
        finally:
            box.close()

    def test_a_stale_cache_is_refreshed_and_kept_when_the_refresh_fails(self):
        box = Sandbox(manifest=MANIFEST, env={"EXAKIT_ABOUT_TTL": "10"})
        try:
            cache = box.ctx.paths.about_cache / "dash-server.txt"
            cache.parent.mkdir(parents=True)
            cache.write_text("old words\n")
            old = time.time() - 100
            os.utime(cache, (old, old))
            self.assertEqual(about.description(box.ctx, self._addon(box)), "old words")
            self.assertEqual(len(box.downloader.calls), 1)
        finally:
            box.close()

    def test_sanitise_and_cap(self):
        self.assertEqual(about.sanitise("a\x1b]8;;http://x\x07link\x1b]8;;\x07  b\tc\r\n"), "alink b c")
        self.assertEqual(about.cap("one two three", 8), "one two")
        self.assertEqual(about.cap("onetwothree", 5), "onetw")
        self.assertEqual(about.cap("short", 0), "short")

    def test_a_failed_fetch_is_retried_after_the_rate_limit_window_not_the_ttl(self):
        box = Sandbox(manifest=MANIFEST, env={"EXAKIT_ABOUT_RETRY": "10"})
        try:
            addon = self._addon(box)
            about.description(box.ctx, addon)                       # fails: no page -> tagline, attempt marker written
            attempt = box.ctx.paths.about_cache / ".attempt-dash-server"
            old = time.time() - 100
            os.utime(attempt, (old, old))                           # the retry window has passed
            repo = about.repo_of(box.ctx, addon)
            box.downloader.pages[f"https://api.github.com/repos/{repo}"] = json.dumps({"description": "fresh words"})
            self.assertEqual(about.description(box.ctx, addon), "fresh words")
        finally:
            box.close()
