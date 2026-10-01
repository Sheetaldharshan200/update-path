"""The one order every upstream lookup follows: GitHub first, the cached copy when GitHub fails or rate-limits, ours last.

Three lookups, each proved with the network faked to fail the way a 403 rate
limit does (the downloader raises): the versions manifest, an add-on's About,
and a release asset's digest.
"""

from __future__ import annotations

import hashlib
import json
import tempfile
import time
import unittest
from pathlib import Path

from exakit.adapters.net.versions_cache import CachedVersionsSource
from exakit.app import about
from exakit.components import for_component
from exakit.domain.errors import Failed
from exakit.domain.versions import VersionPolicy, resolve
from tests.unit.app.harness import MANIFEST, FakeVersions, Sandbox
from tests.unit.fakes import FakeDownloader, ListLog

URL = "https://raw.githubusercontent.com/o/r/main/versions.json"
API = "https://api.github.com/repos/exasol-labs/exapump/releases/tags/v0.12.0"


def manifest_text(exapump: str) -> str:
    return json.dumps({"schema_version": 1, "updated": "2026-09-30", "kit": {"version": "0.3.0"},
                       "components": {"exapump": {"version": exapump, "severity": "normal"}}})


class VersionsManifestOrderTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.cache = root / "cache" / "versions.json"
        self.baked = root / "kit" / "versions.json"
        self.baked.parent.mkdir()
        self.now = time.time()

    def tearDown(self):
        self.tmp.cleanup()

    def _source(self, pages):
        return CachedVersionsSource(cache_path=self.cache, baked_path=self.baked, url=URL, ttl_seconds=86400, retry_seconds=3600,
                                    downloader=FakeDownloader(pages), log=ListLog(), clock=lambda: self.now)

    def _advertised(self, source) -> str | None:
        found = resolve("exapump", policy=VersionPolicy.MANIFEST, env_pin=None, doc=source.current(), fallback="0.9.9-catalog")
        return found.version if found else None

    def test_github_first(self):
        self.baked.write_text(manifest_text("0.12.0"))
        source = self._source({URL: manifest_text("0.13.0")})
        self.assertEqual(source.refresh(), "fetched")
        self.assertEqual((source.source_label(), self._advertised(source)), ("fetched", "0.13.0"))
        self.assertTrue(self.cache.is_file(), "the answer is cached for next time")

    def test_then_the_cache_when_github_fails(self):
        self.baked.write_text(manifest_text("0.12.0"))
        self._source({URL: manifest_text("0.13.0")}).refresh()
        self.now += 90000                                        # the cache is past its TTL: GitHub is asked again
        source = self._source({})                                # and answers with the rate limit (the fake raises)
        self.assertEqual(source.refresh(), "failed")
        self.assertEqual((source.source_label(), self._advertised(source)), ("cache", "0.13.0"))

    def test_then_the_copy_in_the_kit_when_there_is_no_cache(self):
        self.baked.write_text(manifest_text("0.12.0"))
        source = self._source({})
        self.assertEqual(source.refresh(), "failed")
        self.assertEqual((source.source_label(), self._advertised(source)), ("baked", "0.12.0"))

    def test_then_the_catalog_fallback_when_there_is_nothing_at_all(self):
        source = self._source({})
        self.assertEqual(source.refresh(), "failed")
        self.assertEqual((source.source_label(), self._advertised(source)), ("fallback", "0.9.9-catalog"))


class AboutOrderTest(unittest.TestCase):
    def test_github_then_cache_then_our_tagline(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            addon = box.ctx.catalog.addon("dash-server")
            page = f"https://api.github.com/repos/{about.repo_of(box.ctx, addon)}"
            box.downloader.pages[page] = json.dumps({"description": "from GitHub"})
            self.assertEqual(about.description(box.ctx, addon), "from GitHub")
            del box.downloader.pages[page]                       # GitHub now fails
            cache = box.ctx.paths.about_cache / "dash-server.txt"
            import os
            os.utime(cache, (time.time() - 90000,) * 2)          # and the cache is stale, so GitHub is asked
            self.assertEqual(about.description(box.ctx, addon), "from GitHub")
            cache.unlink()
            (box.ctx.paths.about_cache / ".attempt-dash-server").unlink()
            self.assertEqual(about.description(box.ctx, addon), "Agent-operated Dash hosting for live dashboards on your database")
        finally:
            box.close()


class ReleaseDigestOrderTest(unittest.TestCase):
    """A binary is verified against our pinned digest without any network; otherwise GitHub, then the cached answer.

    0.12.0 is a version the catalog does not pin, so these scenarios reach the API; 0.13.0 is the pinned fallback.
    """

    ASSET = "exapump-0.12.0-macos-aarch64"
    BODY = b"exapump binary"

    def _box(self, pinned: bool, pages: dict | None = None) -> Sandbox:
        box = Sandbox(manifest=MANIFEST)
        block = {"sha256": {"macos-aarch64": hashlib.sha256(self.BODY).hexdigest()}} if pinned else {}
        box.ctx.versions = FakeVersions({"schema_version": 1, "updated": "2026-09-30", "kit": {"version": "0.3.0"},
                                         "components": {"exapump": {"version": "0.12.0", "severity": "normal", **block}}})
        box.downloader.pages[f"https://github.com/exasol-labs/exapump/releases/download/v0.12.0/{self.ASSET}"] = self.BODY
        box.downloader.pages.update(pages or {})
        return box

    def _fetch(self, box: Sandbox) -> Path:
        lifecycle = for_component(box.ctx, "exapump")
        dest = Path(box.tmp.name) / "staged"
        return lifecycle.fetch_verified(f"https://github.com/exasol-labs/exapump/releases/download/v0.12.0/{self.ASSET}", dest,
                                        digest=lifecycle.digest_for("0.12.0", self.ASSET), what=self.ASSET,
                                        repo="exasol-labs/exapump", tag="v0.12.0", asset=self.ASSET)

    def test_our_pinned_digest_needs_no_network(self):
        box = self._box(pinned=True)
        try:
            self._fetch(box)
            self.assertNotIn(API, box.downloader.calls, "the release API is never asked when versions.json pins the digest")
        finally:
            box.close()

    def test_unpinned_asks_github_then_uses_the_cached_answer_when_github_fails(self):
        api_page = json.dumps({"assets": [{"name": self.ASSET, "browser_download_url": "x", "digest": "sha256:" + hashlib.sha256(self.BODY).hexdigest()}]})
        box = self._box(pinned=False, pages={API: api_page})
        try:
            self._fetch(box)
            self.assertIn(API, box.downloader.calls)
            self.assertTrue(any(box.ctx.paths.releases_cache.glob("*.json")), "the release answer is cached")
            del box.downloader.pages[API]                        # rate-limited on the next run
            self._fetch(box)                                     # still verified, from the cached answer
        finally:
            box.close()

    def test_unpinned_with_no_github_installs_the_pinned_fallback_release_and_says_so(self):
        """Upstream's contract: a version with no checksum anywhere, and no API answer, becomes the pinned fallback (verified)."""
        box = self._box(pinned=False)
        try:
            box.ctx.versions = FakeVersions({"schema_version": 1, "updated": "2026-09-30", "kit": {"version": "0.3.0"},
                                             "components": {"exapump": {"version": "0.14.0", "severity": "normal"}}})
            source = box.ctx.catalog.component("exapump").source
            source["sha256"]["exapump-0.13.0-macos-aarch64"] = hashlib.sha256(self.BODY).hexdigest()
            lifecycle = for_component(box.ctx, "exapump")
            version, asset, digest = lifecycle.pinned_fallback("0.14.0", "exapump-0.14.0-macos-aarch64")
            self.assertEqual((version, asset, digest), ("0.13.0", "exapump-0.13.0-macos-aarch64", hashlib.sha256(self.BODY).hexdigest()))
            self.assertIn("pinned fallback release 0.13.0", box.screen())
            box.env["EXAKIT_ALLOW_UNVERIFIED_EXAPUMP"] = "1"
            self.assertEqual(lifecycle.pinned_fallback("0.14.0", "exapump-0.14.0-macos-aarch64")[0], "0.14.0")
        finally:
            box.close()

    def test_unpinned_with_no_cache_and_no_github_is_refused_unless_the_hatch_is_set(self):
        box = self._box(pinned=False)
        try:
            with self.assertRaises(Failed) as caught:
                self._fetch(box)
            self.assertIn("No checksum available", caught.exception.message)
            box.env["EXAKIT_ALLOW_UNVERIFIED_EXAPUMP"] = "1"
            self._fetch(box)
        finally:
            box.close()
