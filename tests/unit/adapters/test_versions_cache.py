import hashlib
import json
import tempfile
import time
import unittest
from pathlib import Path

from exakit.adapters.net.digest import sha256_of, verify_sha256
from exakit.adapters.net.upstream import github_latest_release, pypi_latest_version
from exakit.adapters.net.versions_cache import CachedVersionsSource
from exakit.domain.errors import Failed
from tests.support import kit_settings
from tests.unit.fakes import FakeDownloader, ListLog

URL = "https://example.test/versions.json"


def _text(updated: str, kit: str = "0.2.0", schema: int = 1) -> str:
    return json.dumps({
        "schema_version": schema, "updated": updated, "kit": {"version": kit},
        "components": {"exapump": {"version": "0.13.0"}},
    })


ENDPOINTS = kit_settings().endpoints


class _Clock:
    def __init__(self, now: float | None = None) -> None:
        # Real time by default: freshness compares the clock with file mtimes.
        self.now = time.time() if now is None else now

    def __call__(self) -> float:
        return self.now


class VersionsChainTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.cache = root / "cache" / "versions.json"
        self.baked = root / "kit" / "versions.json"
        self.baked.parent.mkdir()
        self.log = ListLog()
        self.clock = _Clock()

    def tearDown(self):
        self.tmp.cleanup()

    def _source(self, pages=None, ttl=86400) -> CachedVersionsSource:
        return CachedVersionsSource(cache_path=self.cache, baked_path=self.baked, url=URL, ttl_seconds=ttl, retry_seconds=3600,
                                    downloader=FakeDownloader(pages), log=self.log, clock=self.clock)

    def test_fetch_writes_the_cache_and_becomes_the_answer(self):
        self.baked.write_text(_text("2026-09-01"))
        src = self._source({URL: _text("2026-09-29", kit="0.3.0")})
        self.assertEqual(src.refresh(), "fetched")
        self.assertEqual(src.current().kit_version(), "0.3.0")
        self.assertEqual(src.source_label(), "fetched")
        self.assertTrue(self.cache.is_file())

    def test_fresh_cache_is_not_refetched_until_ttl(self):
        self.cache.parent.mkdir()
        self.cache.write_text(_text("2026-09-29"))
        src = self._source({URL: _text("2026-09-30")})
        self.assertEqual(src.refresh(), "fresh")
        self.assertEqual(src.downloader.calls, [])
        self.clock.now += 86401
        self.assertEqual(src.refresh(), "fetched")

    def test_force_refetches(self):
        self.cache.parent.mkdir()
        self.cache.write_text(_text("2026-09-29"))
        src = self._source({URL: _text("2026-09-30")})
        self.assertEqual(src.refresh(force=True), "fetched")

    def test_failed_fetch_keeps_the_cached_copy_and_is_not_retried_within_ttl(self):
        self.cache.parent.mkdir()
        self.cache.write_text(_text("2026-09-29"))
        src = self._source({})
        self.clock.now += 86401
        self.assertEqual(src.refresh(), "failed")
        self.assertEqual(src.current().updated(), "2026-09-29")
        self.assertEqual(src.source_label(), "cache")
        self.assertEqual(self._source({}).refresh(), "fresh")   # the attempt stamp answers within the retry window
        self.clock.now += 3601
        self.assertEqual(self._source({}).refresh(), "failed")  # and is retried after it, not after the day-long TTL

    def test_invalid_fetched_document_is_rejected_and_cache_kept(self):
        self.cache.parent.mkdir()
        self.cache.write_text(_text("2026-09-29"))
        src = self._source({URL: "{broken"})
        self.assertEqual(src.refresh(force=True), "failed")
        self.assertEqual(src.current().updated(), "2026-09-29")

    def test_schema_ahead_is_remembered(self):
        src = self._source({URL: _text("2026-09-29", schema=2)})
        self.assertEqual(src.refresh(force=True), "failed")
        self.assertTrue(src.schema_ahead())

    def test_cache_older_than_the_kit_copy_is_refused(self):
        self.cache.parent.mkdir()
        self.cache.write_text(_text("2026-01-01", kit="0.1.0"))
        self.baked.write_text(_text("2026-09-29"))
        src = self._source({})
        self.assertEqual(src.current().kit_version(), "0.2.0")
        self.assertEqual(src.source_label(), "baked")

    def test_no_document_anywhere_is_fallback(self):
        src = self._source({})
        self.assertIsNone(src.current())
        self.assertEqual(src.source_label(), "fallback")

    def test_non_https_url_is_never_fetched(self):
        src = CachedVersionsSource(cache_path=self.cache, baked_path=None, url="http://x/v.json", ttl_seconds=1, retry_seconds=3600,
                                   downloader=FakeDownloader({}), log=self.log, clock=self.clock)
        self.assertEqual(src.refresh(force=True), "failed")

    def test_from_env_reads_url_and_ttl(self):
        src = CachedVersionsSource.from_env({"EXAKIT_VERSIONS_TTL": "10"}, kit_repo="o/r", cache_path=self.cache,
                                            baked_path=None, downloader=FakeDownloader({}), log=self.log,
                                            url_template="https://raw.githubusercontent.com/{repo}/main/versions.json",
                                            ttl_default=86400, retry_default=3600)
        self.assertEqual(src.url, "https://raw.githubusercontent.com/o/r/main/versions.json")
        self.assertEqual(src.ttl_seconds, 10)


class DigestTest(unittest.TestCase):
    def test_sha256_and_verify(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "f"
            path.write_bytes(b"hello")
            expected = hashlib.sha256(b"hello").hexdigest()
            self.assertEqual(sha256_of(path), expected)
            verify_sha256(path, expected.upper(), what="thing")
            with self.assertRaises(Failed) as ctx:
                verify_sha256(path, "0" * 64, what="thing")
            self.assertIn("thing", str(ctx.exception))


class UpstreamTest(unittest.TestCase):
    def test_github_latest_strips_v_and_is_silent_on_error(self):
        dl = FakeDownloader({"https://api.github.com/repos/o/r/releases/latest": '{"tag_name": "v1.4.0"}'})
        self.assertEqual(github_latest_release("o/r", dl, endpoints=ENDPOINTS), "1.4.0")
        self.assertIsNone(github_latest_release("o/missing", dl, endpoints=ENDPOINTS))
        bad = FakeDownloader({"https://api.github.com/repos/o/r/releases/latest": '{"tag_name": "1.0;x"}'})
        self.assertIsNone(github_latest_release("o/r", bad, endpoints=ENDPOINTS))

    def test_pypi_latest(self):
        dl = FakeDownloader({"https://pypi.org/pypi/pyexasol/json": '{"info": {"version": "2.4.1"}}'})
        self.assertEqual(pypi_latest_version("pyexasol", dl, endpoints=ENDPOINTS), "2.4.1")
        self.assertIsNone(pypi_latest_version("nothing", dl, endpoints=ENDPOINTS))


if __name__ == "__main__":
    unittest.main()
