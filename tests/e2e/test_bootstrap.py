"""End to end: the installer's dry run, the launcher's three answers, and the update path's file layout.

No network: the kit comes from this checkout (EXAKIT_LOCAL_KIT) and a dry run
stops before the Python bootstrap. The real bootstrap (uv download, CPython
install) is exercised by ``tests/e2e/test_bootstrap_network.py`` when
EXAKIT_E2E_NETWORK=1.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def _run(cmd: list[str], env: dict[str, str], cwd: Path = REPO) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=False, cwd=cwd, env=env, capture_output=True, text=True, timeout=300)


@unittest.skipUnless(shutil.which("sh") and os.name != "nt", "POSIX shell installer")
class InstallerDryRunTest(unittest.TestCase):
    def test_dry_run_unpacks_the_kit_and_installs_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = {**os.environ, "HOME": tmp, "EXAKIT_HOME": f"{tmp}/home", "EXAKIT_LOCAL_KIT": str(REPO),
                   "EXAKIT_DRY_RUN": "1", "NO_COLOR": "1"}
            done = _run(["sh", str(REPO / "install.sh")], env)
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            self.assertIn("Dry run", done.stdout)
            if shutil.which("python3"):          # the plan is drawn by the kit when a Python 3.11+ is on PATH
                self.assertIn("Step 1/6  Exasol launcher", done.stdout)
                self.assertIn("Step 6/6  exakit helper command", done.stdout)
            self.assertFalse((Path(tmp) / "home" / "manifest.json").exists())
            self.assertFalse((Path(tmp) / "home" / "python").exists())

    def test_installer_names_the_python_hand_over(self):
        text = (REPO / "install.sh").read_text()
        self.assertIn("bootstrap/ensure-python.sh", text)
        self.assertIn("-m exakit install", text)
        self.assertIn("EXAKIT_PERSONA", text)


@unittest.skipUnless(shutil.which("sh") and os.name != "nt", "POSIX launcher")
class LauncherTest(unittest.TestCase):
    def _env(self, tmp: str, **extra: str) -> dict[str, str]:
        return {**os.environ, "HOME": tmp, "EXAKIT_HOME": f"{tmp}/home", "NO_COLOR": "1", **extra}

    def test_no_kit_answers_not_installed_and_exits_4(self):
        with tempfile.TemporaryDirectory() as tmp:
            launcher = Path(tmp) / "exakit"
            shutil.copy(REPO / "bootstrap" / "exakit", launcher)
            done = _run([str(launcher), "status", "--json"], self._env(tmp), cwd=Path(tmp))
            self.assertEqual(done.returncode, 4)
            doc = json.loads(done.stdout)
            self.assertEqual((doc["installed"], doc["status"]), (False, "not installed"))
            self.assertIn("remedy", doc)

    def test_read_only_query_without_python_answers_unknown_and_exits_3(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = self._env(tmp)
            env.pop("EXAKIT_PYTHON", None)
            done = _run([str(REPO / "bootstrap" / "exakit"), "status", "--json"], env)
            self.assertEqual(done.returncode, 3, done.stderr)
            doc = json.loads(done.stdout)
            self.assertEqual((doc["installed"], doc["status"], doc["remedy"]), (True, "unknown", "exakit update"))

    def test_launcher_runs_the_kit_with_a_given_python(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = self._env(tmp, EXAKIT_PYTHON=sys.executable, EXAKIT_VERSIONS_TTL="999999")
            done = _run([str(REPO / "setup" / "exakit"), "persona", "list", "--json"], env)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(json.loads(done.stdout)["status"], "none")

    def test_recorded_interpreter_is_reused(self):
        with tempfile.TemporaryDirectory() as tmp:
            record = Path(tmp) / "home" / "python" / "interpreter"
            record.parent.mkdir(parents=True)
            record.write_text(sys.executable + "\n")
            env = self._env(tmp, EXAKIT_VERSIONS_TTL="999999")
            env.pop("EXAKIT_PYTHON", None)
            done = _run([str(REPO / "bootstrap" / "exakit"), "persona", "list", "--json"], env)
            self.assertEqual(done.returncode, 0, done.stderr)


class UpdatePathLayoutTest(unittest.TestCase):
    """What the 0.2.0 self-update copies from the new tree must be the launcher."""

    def test_setup_exakit_is_the_launcher_and_nothing_else_lives_in_setup(self):
        self.assertEqual((REPO / "setup" / "exakit").read_bytes(), (REPO / "bootstrap" / "exakit").read_bytes())
        self.assertIn("python -m exakit", (REPO / "setup" / "exakit").read_text())
        self.assertEqual(sorted(p.name for p in (REPO / "setup").iterdir()), ["exakit", "exakit.cmd", "exakit.ps1"])
        self.assertEqual((REPO / "setup" / "exakit.cmd").read_bytes(), (REPO / "bootstrap" / "exakit.cmd").read_bytes())

    def test_versions_json_pins_uv_with_a_digest_per_platform(self):
        doc = json.loads((REPO / "versions.json").read_text())
        self.assertEqual(doc["kit"]["version"], "0.3.0")
        uv = doc["tools"]["uv"]
        self.assertEqual(set(uv["sha256"]), {"linux-aarch64", "linux-x86_64", "macos-aarch64", "macos-x86_64", "windows-x86_64"})
        self.assertTrue(all(len(v) == 64 for v in uv["sha256"].values()))

    def test_whats_new_has_the_0_3_0_card(self):
        doc = json.loads((REPO / "help" / "whats-new.json").read_text())
        self.assertIn("0.3.0", doc)
        self.assertTrue(all(len(line) <= 68 for line in doc["0.3.0"]))


class InstallerSentinelsTest(unittest.TestCase):
    """Every file the two installers name as part of the kit exists in the tree: a deleted file must not linger in a check."""

    KNOWN_ABSENT = {"setup\\lib\\ui.ps1"}     # the visual layer left with the shell tree; the installer falls back to plain text

    def test_every_kit_path_the_installers_name_exists(self):
        import re
        repo = Path(__file__).resolve().parents[2]
        missing = []
        for name in ("install.sh", "install.ps1"):
            text = (repo / name).read_text(encoding="utf-8")
            for match in re.finditer(r'"((?:setup|bootstrap|exakit|help)[\\/][A-Za-z0-9_.\\/-]+)"', text):
                rel = match.group(1)
                if rel in self.KNOWN_ABSENT:
                    continue
                if not (repo / rel.replace("\\", "/")).exists():
                    missing.append(f"{name}: {rel}")
        self.assertEqual(missing, [])


if __name__ == "__main__":
    unittest.main()
