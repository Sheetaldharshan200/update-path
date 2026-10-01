"""The real Python bootstrap: downloads the pinned uv, verifies it, installs CPython. Network required.

Runs only with EXAKIT_E2E_NETWORK=1 (CI's e2e job sets it; local runs opt in).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


@unittest.skipUnless(os.environ.get("EXAKIT_E2E_NETWORK") == "1" and os.name != "nt", "network e2e opt-in")
class EnsurePythonTest(unittest.TestCase):
    def test_bootstrap_installs_a_managed_python_and_records_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = {k: v for k, v in os.environ.items() if k != "EXAKIT_PYTHON"}
            env.update({"HOME": tmp, "EXAKIT_HOME": f"{tmp}/home", "EXAKIT_KIT_DIR": str(REPO),
                        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})
            script = f'. "{REPO}/bootstrap/ensure-python.sh" && ensure_python && "$EXAKIT_PYTHON" --version'
            done = subprocess.run(["sh", "-c", script], check=False, env=env, capture_output=True, text=True, timeout=600)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertIn("Python 3.12", done.stdout)
            self.assertTrue((Path(tmp) / "home" / "tools" / "uv" / "uv").exists())
            self.assertTrue((Path(tmp) / "home" / "python" / "interpreter").exists())
            self.assertTrue(shutil.which("sh"))


if __name__ == "__main__":
    unittest.main()
