import json
import os
import tempfile
import threading
import unittest
from pathlib import Path

from exakit.adapters.fs.atomic import atomic_write_text
from exakit.adapters.fs.lock import FileLock
from exakit.adapters.fs.log import FileLog, NullLog
from exakit.adapters.fs.manifest_store import CorruptManifest, FileManifestStore
from tests.unit.fakes import mode_of
from exakit.adapters.fs.paths import Paths
from exakit.domain.errors import Failed, NotInstalled
from exakit.domain.manifest import Manifest


class PathsTest(unittest.TestCase):
    def test_defaults_under_the_user_home(self):
        p = Paths.from_env({}, Path("/Users/me"))
        self.assertEqual(p.home, Path("/Users/me/.exasol-starter-kit"))
        self.assertEqual(p.bin_dir, Path("/Users/me/.local/bin"))
        self.assertEqual(p.kit, p.home / "kit")
        self.assertEqual(p.manifest, p.home / "manifest.json")
        self.assertEqual(p.logs, p.home / "logs")
        self.assertEqual(p.cache / "versions.json", p.versions_cache)
        self.assertEqual(p.personas_user, p.home / "personas")

    def test_env_overrides_win(self):
        p = Paths.from_env({"EXAKIT_HOME": "/tmp/kit", "EXAKIT_BIN_DIR": "/tmp/bin"}, Path("/Users/me"))
        self.assertEqual(p.home, Path("/tmp/kit"))
        self.assertEqual(p.bin_dir, Path("/tmp/bin"))


class AtomicWriteTest(unittest.TestCase):
    def test_writes_content_with_private_mode_and_no_temp_left(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "sub" / "file.json"
            atomic_write_text(target, '{"a": 1}\n')
            self.assertEqual(target.read_text(), '{"a": 1}\n')
            self.assertIn(mode_of(target), (0o600, None))
            self.assertEqual(os.listdir(target.parent), ["file.json"])

    def test_replaces_existing_content(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "f"
            atomic_write_text(target, "one")
            atomic_write_text(target, "two")
            self.assertEqual(target.read_text(), "two")


class FileLockTest(unittest.TestCase):
    def test_lock_is_exclusive_and_times_out_with_a_kit_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "x.lock"
            with FileLock(path), self.assertRaises(Failed), FileLock(path, timeout=0.2):
                pass

    def test_lock_is_released_on_exit(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "x.lock"
            with FileLock(path):
                pass
            with FileLock(path, timeout=0.2):
                pass


class ManifestStoreTest(unittest.TestCase):
    def _store(self, tmp: str) -> FileManifestStore:
        return FileManifestStore(Path(tmp) / "manifest.json", Path(tmp) / "manifest.json.lock")

    def test_missing_manifest_is_not_installed(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = self._store(tmp)
            self.assertFalse(store.exists())
            with self.assertRaises(NotInstalled):
                store.load()

    def test_save_and_load_round_trip_pretty_printed(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = self._store(tmp)
            store.save(Manifest({"kit_level": 1, "components": {}}))
            text = store.path.read_text()
            self.assertTrue(text.startswith("{\n  "))
            self.assertEqual(store.load().doc, {"kit_level": 1, "components": {}})

    def test_corrupt_file_is_reported_and_can_be_quarantined(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = self._store(tmp)
            store.path.write_text("{not json")
            with self.assertRaises(CorruptManifest):
                store.load()
            aside = store.quarantine()
            self.assertFalse(store.exists())
            self.assertTrue(aside.name.startswith("manifest.json.corrupt-"))

    def test_update_applies_the_change_under_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = self._store(tmp)
            store.save(Manifest({"steps_completed": []}))
            result = store.update(lambda m: m.mark_step("runtime"))
            self.assertEqual(result.steps_completed(), ["runtime"])
            self.assertEqual(json.loads(store.path.read_text())["steps_completed"], ["runtime"])

    def test_concurrent_updates_are_not_lost(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = self._store(tmp)
            store.save(Manifest({"n": 0}))

            def bump():
                for _ in range(20):
                    store.update(lambda m: m.set("n", m.get("n") + 1))

            threads = [threading.Thread(target=bump) for _ in range(4)]
            for t in threads:
                t.start()
            for t in threads:
                t.join()
            self.assertEqual(store.load().get("n"), 80)


class LogTest(unittest.TestCase):
    def test_file_log_writes_legacy_format(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = FileLog(Path(tmp) / "logs", prefix="install")
            log.line("INFO", "hello")
            log.line("WARN", "careful")
            lines = log.path.read_text().splitlines()
            self.assertRegex(lines[0], r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} INFO  hello$")
            self.assertRegex(lines[1], r" WARN  careful$")
            self.assertIn(mode_of(log.path), (0o600, None))

    def test_file_log_stops_quietly_when_the_directory_cannot_be_made(self):
        with tempfile.TemporaryDirectory() as tmp:
            blocker = Path(tmp) / "file"
            blocker.write_text("x")
            log = FileLog(blocker / "logs")
            log.line("INFO", "nope")
            self.assertIsNone(log.path)

    def test_null_log_has_no_path(self):
        log = NullLog()
        log.line("INFO", "x")
        self.assertIsNone(log.path)


if __name__ == "__main__":
    unittest.main()
