"""The screens' venv: built once by uv, rebuilt when the pin changes, found again without work otherwise."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from exakit.adapters import tui_env


class FakeUv:
    """Records what uv was asked and lays down the folders a real venv would have."""

    def __init__(self, root: Path, *, windows: bool = False) -> None:
        self.calls: list[tuple] = []
        self.windows = windows
        self.root = root

    def venv(self, path: Path, *, seed: bool) -> None:
        self.calls.append(("venv", path, seed))
        site = path / ("Lib" if self.windows else "lib/python3.12") / "site-packages"
        site.mkdir(parents=True)
        self.python_of(path).parent.mkdir(parents=True, exist_ok=True)
        self.python_of(path).write_text("")

    def pip_install(self, python: Path, spec: str) -> None:
        self.calls.append(("pip", python, spec))

    def python_of(self, venv: Path) -> Path:
        return venv / ("Scripts/python.exe" if self.windows else "bin/python")

    def bin_of(self, venv: Path, name: str) -> Path:
        return venv / "bin" / name


class EnsureTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.venv = Path(self.tmp.name) / "ui-venv"
        self.uv = FakeUv(Path(self.tmp.name))

    def tearDown(self):
        self.tmp.cleanup()

    def test_the_first_call_creates_the_venv_installs_the_pin_and_writes_the_marker(self):
        site = tui_env.ensure(self.venv, self.uv, "textual==8.2.8", windows=False)
        self.assertEqual(site, self.venv / "lib/python3.12/site-packages")
        self.assertEqual([c[0] for c in self.uv.calls], ["venv", "pip"])
        self.assertEqual(self.uv.calls[1][2], "textual==8.2.8")
        self.assertEqual((self.venv / tui_env.MARKER).read_text().strip(), "textual==8.2.8")

    def test_the_second_call_does_no_work(self):
        tui_env.ensure(self.venv, self.uv, "textual==8.2.8", windows=False)
        self.uv.calls.clear()
        self.assertEqual(tui_env.ready(self.venv, "textual==8.2.8", windows=False), self.venv / "lib/python3.12/site-packages")
        tui_env.ensure(self.venv, self.uv, "textual==8.2.8", windows=False)
        self.assertEqual(self.uv.calls, [])

    def test_a_new_pin_reinstalls_into_the_same_venv(self):
        tui_env.ensure(self.venv, self.uv, "textual==8.2.8", windows=False)
        self.uv.calls.clear()
        self.assertIsNone(tui_env.ready(self.venv, "textual==8.3.0", windows=False))
        tui_env.ensure(self.venv, self.uv, "textual==8.3.0", windows=False)
        self.assertEqual([c[0] for c in self.uv.calls], ["pip"])
        self.assertEqual((self.venv / tui_env.MARKER).read_text().strip(), "textual==8.3.0")

    def test_windows_keeps_its_site_packages_under_lib(self):
        uv = FakeUv(Path(self.tmp.name), windows=True)
        site = tui_env.ensure(self.venv, uv, "textual==8.2.8", windows=True)
        self.assertEqual(site, self.venv / "Lib" / "site-packages")

    def test_nothing_is_ready_before_the_venv_exists(self):
        self.assertIsNone(tui_env.ready(self.venv, "textual==8.2.8", windows=False))
        self.assertIsNone(tui_env.site_packages(self.venv, windows=False))
