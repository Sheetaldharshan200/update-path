"""The release sites (D36): the source repository's release first, the kit's mirror after it, digests from the site that answers."""

from __future__ import annotations

import hashlib
import io
import json
import tarfile
import unittest
import zipfile

from exakit.adapters.net.digest import ChecksumMismatch, digest_from_checksums
from exakit.domain.errors import Failed
from exakit.domain.platform import Platform
from exakit.lifecycles import for_addon, releases
from tests.unit.app.harness import MANIFEST, Sandbox

UP = "https://github.com/exasol-labs/exasol-scheduler/releases/download/v1.0.0"
API = "https://api.github.com/repos"
BODY = b"binary bytes"
DIGEST = hashlib.sha256(BODY).hexdigest()


def _tgz(member: str, body: bytes = BODY) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        info = tarfile.TarInfo(member)
        info.size = len(body)
        tar.addfile(info, io.BytesIO(body))
    return buf.getvalue()


class SchedulerSitesTest(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox(manifest=MANIFEST, platform=Platform("macos", "aarch64"))
        self.lc = for_addon(self.box.ctx, self.box.ctx.catalog.addon("exasol-scheduler"))
        self.mirror = f"https://github.com/{self.box.ctx.kit_repo}/releases/download/exasol-scheduler-v1.0.0"
        self.archive = _tgz("target/aarch64-apple-darwin/release/exasol_scheduler")
        self.archive_digest = hashlib.sha256(self.archive).hexdigest()
        self.dest = self.box.home / "staged" / "engine"
        self.dest.parent.mkdir(parents=True)

    def tearDown(self):
        self.box.close()

    def test_the_source_release_answers_first_verified_by_its_sidecar_and_the_binary_is_extracted(self):
        asset = "exasol_scheduler-v1.0.0-macos-arm64.tar.gz"
        self.box.downloader.pages[f"{UP}/{asset}"] = self.archive
        self.box.downloader.pages[f"{UP}/{asset}.sha256"] = f"{self.archive_digest}  dist/{asset}\n"
        site = releases.fetch_binary(self.lc, "v1.0.0", "macos-aarch64", self.dest, what="exasol-scheduler v1.0.0", pin_key="macos-arm64")
        self.assertEqual(site.repo, "exasol-labs/exasol-scheduler")
        self.assertEqual(self.dest.read_bytes(), BODY)
        self.assertFalse((self.dest.parent / asset).exists())
        self.assertFalse(any(self.box.ctx.kit_repo in url for url in self.box.downloader.calls))

    def test_the_kit_mirror_answers_when_the_source_release_cannot_be_downloaded(self):
        self.box.downloader.pages[f"{self.mirror}/exasol-scheduler-macos-arm64"] = BODY
        self.box.downloader.pages[f"{API}/{self.box.ctx.kit_repo}/releases/tags/exasol-scheduler-v1.0.0"] = json.dumps(
            {"assets": [{"name": "exasol-scheduler-macos-arm64", "browser_download_url": "x", "digest": f"sha256:{DIGEST}"}]})
        site = releases.fetch_binary(self.lc, "v1.0.0", "macos-aarch64", self.dest, what="exasol-scheduler v1.0.0", pin_key="macos-arm64")
        self.assertTrue(site.mirror)
        self.assertEqual(self.dest.read_bytes(), BODY)
        self.assertTrue(any(url.startswith(UP) for url in self.box.downloader.calls), "the source release was asked first")

    def test_a_checksum_mismatch_stops_at_once_and_never_tries_the_mirror(self):
        asset = "exasol_scheduler-v1.0.0-macos-arm64.tar.gz"
        self.box.downloader.pages[f"{UP}/{asset}"] = self.archive
        self.box.downloader.pages[f"{UP}/{asset}.sha256"] = f"{'0' * 64}  {asset}\n"
        self.box.downloader.pages[f"{self.mirror}/exasol-scheduler-macos-arm64"] = BODY
        with self.assertRaises(ChecksumMismatch):
            releases.fetch_binary(self.lc, "v1.0.0", "macos-aarch64", self.dest, what="exasol-scheduler v1.0.0")
        self.assertFalse(any(url.startswith(self.mirror) for url in self.box.downloader.calls))

    def test_when_no_site_answers_the_failure_names_every_attempt(self):
        with self.assertRaises(Failed) as caught:
            releases.fetch_binary(self.lc, "v1.0.0", "macos-aarch64", self.dest, what="exasol-scheduler v1.0.0")
        self.assertIn("exasol-labs/exasol-scheduler@v1.0.0", caught.exception.message)
        self.assertIn(f"{self.box.ctx.kit_repo}@exasol-scheduler-v1.0.0", caught.exception.message)

    def test_the_pins_in_versions_json_apply_to_the_mirror_and_need_no_network_for_the_digest(self):
        box = Sandbox(manifest=MANIFEST, platform=Platform("macos", "aarch64"))
        try:
            lc = for_addon(box.ctx, box.ctx.catalog.addon("exasol-scheduler"))
            doc = box.ctx.versions.current()
            version = doc.component_version("exasol-scheduler")
            pinned = doc.sha256("exasol-scheduler", "macos-arm64")
            site = releases.sites(lc, version)[1]
            self.assertEqual(site.tag, doc.value("components.exasol-scheduler.release"))
            self.assertEqual(releases._pinned(lc, site, version, "macos-arm64"), pinned)
            self.assertIsNone(releases._pinned(lc, releases.sites(lc, version)[0], version, "macos-arm64"))
        finally:
            box.close()

    def test_a_platform_no_site_publishes_is_refused_in_words(self):
        box = Sandbox(manifest=MANIFEST, platform=Platform("windows", "x86_64"))
        try:
            lc = for_addon(box.ctx, box.ctx.catalog.addon("exasol-scheduler"))
            with self.assertRaises(Failed) as caught:
                releases.fetch_asset(lc, "v1.0.0", "windows-x86_64", box.home, what="exasol-scheduler")
            self.assertIn("no release publishes", caught.exception.message)
        finally:
            box.close()


class JsonTablesSitesTest(unittest.TestCase):
    def test_the_checksums_file_vouches_for_the_wheel_and_the_engine(self):
        box = Sandbox(manifest=MANIFEST, platform=Platform("linux", "x86_64"))
        try:
            lc = for_addon(box.ctx, box.ctx.catalog.addon("json-tables"))
            up = "https://github.com/exasol-labs/exasol-json-tables/releases/download/v0.9.0"
            wheel, engine = "exasol_json_tables-0.9.0-py3-none-any.whl", "json_to_parquet-v0.9.0-linux-x86_64.tar.gz"
            archive = _tgz("json_to_parquet-v0.9.0-linux-x86_64/json_to_parquet")
            box.downloader.pages[f"{up}/{wheel}"] = BODY
            box.downloader.pages[f"{up}/{engine}"] = archive
            box.downloader.pages[f"{up}/SHA256SUMS"] = f"{DIGEST}  {wheel}\n{hashlib.sha256(archive).hexdigest()}  {engine}\n"
            got = releases.fetch_asset(lc, "v0.9.0", "wheel", box.home / "w", what="wheel", pin_key="wheel")
            self.assertEqual(got.asset, wheel)
            dest = box.home / "engine"
            releases.fetch_binary(lc, "v0.9.0", "linux-x86_64", dest, what="engine")
            self.assertEqual(dest.read_bytes(), BODY)
        finally:
            box.close()

    def test_linux_arm_has_only_the_mirror_and_is_still_applicable(self):
        box = Sandbox(manifest=MANIFEST, platform=Platform("linux", "aarch64"))
        try:
            lc = for_addon(box.ctx, box.ctx.catalog.addon("json-tables"))
            self.assertTrue(lc.applicable()[0])
            self.assertEqual(lc.engine_asset("v0.9.0"), "exasol-json-tables-ingest-linux-aarch64")
        finally:
            box.close()


class ExtractionTest(unittest.TestCase):
    def test_tar_zip_and_bare_files(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            home = box.home
            (home / "a.tar.gz").write_bytes(_tgz("x/y/tool"))
            releases.extract_member(home / "a.tar.gz", "*/tool", home / "t1")
            self.assertEqual((home / "t1").read_bytes(), BODY)
            buf = io.BytesIO()
            with zipfile.ZipFile(buf, "w") as z:
                z.writestr("dir/", "")
                z.writestr("dir/tool.exe", BODY)
            (home / "a.zip").write_bytes(buf.getvalue())
            releases.extract_member(home / "a.zip", "*/tool.exe", home / "t2")
            self.assertEqual((home / "t2").read_bytes(), BODY)
            (home / "bare").write_bytes(BODY)
            releases.extract_member(home / "bare", "*", home / "t3")
            self.assertEqual((home / "t3").read_bytes(), BODY)
            (home / "b.tar.gz").write_bytes(_tgz("x/other"))
            with self.assertRaises(Failed):
                releases.extract_member(home / "b.tar.gz", "*/tool", home / "t4")
        finally:
            box.close()


class ChecksumFileTest(unittest.TestCase):
    def test_a_path_prefix_or_a_star_before_the_name_is_ignored(self):
        text = f"{DIGEST}  dist/a.tar.gz\n{'1' * 64} *b.tar.gz\nnot a line\n"
        self.assertEqual(digest_from_checksums(text, "a.tar.gz"), DIGEST)
        self.assertEqual(digest_from_checksums(text, "b.tar.gz"), "1" * 64)
        self.assertIsNone(digest_from_checksums(text, "c.tar.gz"))
