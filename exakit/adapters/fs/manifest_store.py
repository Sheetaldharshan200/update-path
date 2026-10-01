"""Loading and saving the manifest: locked, atomic, and honest about corruption."""

from __future__ import annotations

import json
import time
from collections.abc import Callable
from pathlib import Path
from typing import Protocol

from exakit.domain.errors import Failed, NotInstalled
from exakit.domain.manifest import Manifest

from .atomic import atomic_write_text
from .lock import FileLock


class ManifestStore(Protocol):
    def exists(self) -> bool: ...
    def load(self) -> Manifest: ...
    def save(self, manifest: Manifest) -> None: ...
    def update(self, change: Callable[[Manifest], None]) -> Manifest: ...


class CorruptManifest(Failed):
    """The file exists but is not JSON. The installer quarantines and rebuilds it; every other command reports it (exit 1)."""

    def __init__(self, path: Path) -> None:
        super().__init__(f"The install record {path} does not parse as JSON (an interrupted run?).", remedy="exakit install",
                         hint="the installer keeps the broken file aside, rebuilds the record and recovers the completed steps")
        self.path = path


class FileManifestStore:
    """The real store. ``update`` is the only safe way to read-modify-write."""

    def __init__(self, path: Path, lock_path: Path) -> None:
        self.path = path
        self.lock_path = lock_path

    def exists(self) -> bool:
        """True when a record exists."""
        return self.path.is_file()

    def load(self) -> Manifest:
        """Raises NotInstalled when there is no record, CorruptManifest when it is not JSON."""
        if not self.exists():
            raise NotInstalled("No installation found.", hint=f"no install record at {self.path}")
        try:
            doc = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as err:
            raise CorruptManifest(self.path) from err
        if not isinstance(doc, dict):
            raise CorruptManifest(self.path)
        return Manifest(doc)

    def save(self, manifest: Manifest) -> None:
        """Write the record atomically."""
        atomic_write_text(self.path, json.dumps(manifest.doc, indent=2) + "\n", mode=0o600)

    def update(self, change: Callable[[Manifest], None]) -> Manifest:
        """Read, change, write under one lock, so a concurrent writer cannot be lost."""
        with FileLock(self.lock_path):
            manifest = self.load()
            change(manifest)
            self.save(manifest)
            return manifest

    def quarantine(self) -> Path:
        """Move a corrupt file aside and return where it went."""
        aside = self.path.with_name(f"{self.path.name}.corrupt-{int(time.time())}")
        self.path.replace(aside)
        return aside
