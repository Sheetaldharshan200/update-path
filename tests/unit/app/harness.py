"""A Context built from fakes and a sandbox home, for testing use cases without a machine."""

from __future__ import annotations

import io
import json
import tempfile
from pathlib import Path
from typing import Any

from exakit.adapters.fs.log import NullLog
from exakit.adapters.fs.manifest_store import FileManifestStore
from exakit.adapters.fs.paths import Paths
from exakit.app import Context
from exakit.domain.catalog import Catalog
from exakit.domain.manifest import Manifest
from exakit.domain.platform import Platform
from exakit.domain.versions import VersionsDoc
from exakit.ui.console import ConsoleRenderer
from exakit.ui.silent import SilentRenderer
from exakit.ui.widgets import PLAIN
from tests.unit.fakes import FakeDownloader, FakeRunner

REPO = Path(__file__).resolve().parents[3]


class FakeVersions:
    def __init__(self, doc: dict[str, Any] | None = None) -> None:
        self._doc = VersionsDoc(doc) if doc else VersionsDoc(json.loads((REPO / "versions.json").read_text()))
        self.refreshed = 0

    def current(self):
        return self._doc

    def refresh(self, *, force: bool = False) -> str:
        self.refreshed += 1
        return "fresh"

    def source_label(self) -> str:
        return "baked"

    def schema_ahead(self) -> bool:
        return False


class Sandbox:
    """A temporary EXAKIT_HOME, HOME and bin dir, with a Context over fakes."""

    def __init__(self, *, manifest: dict[str, Any] | None = None, json_mode: bool = False, interactive: bool = False,
                 env: dict[str, str] | None = None, runner: FakeRunner | None = None, platform: Platform | None = None) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.home = root / "home"
        self.user_home = root / "user"
        self.user_home.mkdir()
        self.home.mkdir()
        self.env: dict[str, str] = {"HOME": str(self.user_home), "EXAKIT_HOME": str(self.home),
                                    "EXAKIT_BIN_DIR": str(root / "bin"), **(env or {})}
        self.out = io.StringIO()
        self.runner = runner or FakeRunner()
        self.downloader = FakeDownloader()
        paths = Paths.from_env(self.env, self.user_home)
        store = FileManifestStore(paths.manifest, paths.manifest_lock)
        if manifest is not None:
            store.save(Manifest(manifest))
        ui = SilentRenderer() if json_mode else ConsoleRenderer(palette=PLAIN, out=self.out, err=self.out, interactive=interactive, reader=lambda: "")
        self.ctx = Context(
            paths=paths, platform=platform or Platform("macos", "aarch64"), env=self.env,
            catalog=Catalog.load(REPO, paths.personas_user, warn=lambda m: None),
            manifest_store=store, versions=FakeVersions(), runner=self.runner, net=self.downloader,
            ui=ui, log=NullLog(), json=json_mode,
        )

    def screen(self) -> str:
        return self.out.getvalue()

    def manifest(self) -> Manifest:
        return self.ctx.manifest_store.load()

    def close(self) -> None:
        self.tmp.cleanup()


MANIFEST = {
    "manifest_version": 1, "kit_level": 1, "installed_at": "2026-09-30T00:00:00Z", "os": "macos", "arch": "arm64",
    "runtime": {"type": "personal", "status": "running", "version": "2.3.0", "dsn": "127.0.0.1:8563", "user": "sys"},
    "components": {"skills": {"version": "1.12.2"}, "mcp_server": {"version": "2.2.0"}, "exapump": {"profile": "starter-kit"}},
    "data": {"loaded": True, "datasets": {"tpch": {"loaded": True}}},
    "steps_completed": ["launcher", "runtime", "exapump", "mcp", "pyexasol", "exakit_helper"], "log_dir": "/tmp/x",
}
