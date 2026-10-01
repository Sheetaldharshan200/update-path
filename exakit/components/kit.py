"""The kit copy itself: staged beside it, swapped by rename, the launcher reinstalled, the skills re-placed."""

from __future__ import annotations

import json
import shutil
import tarfile
import time
from pathlib import Path

from exakit.domain.errors import Failed
from exakit.domain.versions import is_newer

from .base import ComponentBase

REQUIRED = ("setup/exakit", "setup/exakit.ps1", "setup/exakit.cmd", "versions.json", "exakit/__main__.py", "bootstrap/exakit", "help/exakit.json", "catalog/kit.json")


def kit_version_at(root: Path, path: str = "kit.version") -> str | None:
    """The kit version a kit copy's versions.json names, or None."""
    try:
        node = json.loads((root / "versions.json").read_text(encoding="utf-8"))
        for part in path.split("."):
            node = node[part]
        return str(node)
    except (OSError, ValueError, KeyError, TypeError):
        return None


class Lifecycle(ComponentBase):
    id = "exakit"
    key = "kit"
    step = "exakit_helper"

    def installed_version(self) -> str | None:
        """The installed kit version, or None."""
        from exakit.app.machine import installed_version
        return installed_version(self.ctx, "exakit", self.ctx.manifest_or_none())[0]

    def target_version(self) -> str:
        """The advertised kit version."""
        doc = self.ctx.versions.current()
        latest = doc.kit_version() if doc else None
        if not latest:
            raise Failed("Could not resolve the advertised starter kit version.")
        return latest

    def install(self, version: str) -> None:
        """A first install is an update."""
        self.update()

    # --- the self-update -----------------------------------------------------------------------

    def _download(self, latest: str, stage: Path) -> str:
        """The kit tarball: main first (kit script changes live there), then the release tags. Returns the ref."""
        archive = stage.parent / f".kit-download-{int(time.time())}.tar.gz"
        for ref in ("main", f"v{latest}", latest):
            url = self.ctx.catalog.kit.endpoints.url("archive_branch" if ref == "main" else "archive_tag", repo=self.ctx.kit_repo, ref=ref)
            try:
                with self.ctx.ui.progress(f"Downloading the starter kit ({ref})") as report:
                    self.ctx.net.fetch(url, archive, what=f"starter kit ({ref})", progress=report)
            except Failed:
                continue
            try:
                with tarfile.open(archive) as tar:
                    members = [m for m in tar.getmembers() if "/" in m.name]
                    for member in members:
                        member.name = member.name.split("/", 1)[1]
                    tar.extractall(stage, members=members, filter="data")
            except (tarfile.TarError, OSError):
                raise Failed("Could not unpack the starter kit update; existing kit copy was left untouched.") from None
            finally:
                archive.unlink(missing_ok=True)
            return ref
        raise Failed(f"Could not download the starter kit from {self.ctx.kit_repo} (tried main and the {latest} tags).")

    def _restore(self, backup: Path, kit_dir: Path, marker: Path) -> None:
        if not backup.is_dir():
            return
        shutil.rmtree(kit_dir, ignore_errors=True)
        backup.rename(kit_dir)
        marker.unlink(missing_ok=True)

    def _swap(self, stage: Path, latest: str) -> tuple[str, Path | None]:
        kit_dir = self.ctx.paths.kit
        marker = self.ctx.paths.update_in_progress
        backup = kit_dir.with_name(f"kit.backup-{time.strftime('%Y%m%d-%H%M%S')}")
        staged = kit_version_at(stage) or latest
        if staged != latest and is_newer(latest, staged):
            self.ctx.ui.warn(f"The downloaded kit is {staged}, not the advertised {latest} - the published manifest is a few minutes ahead. Recording {staged}.")
        had_kit = kit_dir.is_dir()
        if had_kit:
            marker.write_text(f"{backup}\n", encoding="utf-8")
            try:
                kit_dir.rename(backup)
            except OSError:
                marker.unlink(missing_ok=True)
                shutil.rmtree(stage, ignore_errors=True)
                raise Failed("Could not back up existing kit copy; update was not applied.") from None
            self.ctx.ui.info(f"Previous kit copy kept at {backup}")
        kit_dir.parent.mkdir(parents=True, exist_ok=True)
        try:
            stage.rename(kit_dir)
        except OSError:
            self._restore(backup, kit_dir, marker)
            shutil.rmtree(stage, ignore_errors=True)
            raise Failed("Could not install the staged starter kit update; previous kit copy was restored.") from None
        try:
            from exakit.app.install_steps import helper_files
            for source, target in helper_files(self.ctx, kit_dir):
                self.install_binary(source, target)
        except OSError:
            self._restore(backup, kit_dir, marker)
            raise Failed(f"Could not install the exakit command to {self.ctx.paths.bin_dir} (is it writable? is the disk full?).") from None
        marker.unlink(missing_ok=True)
        return staged, backup if had_kit else None

    def update(self, options: list[str] | None = None) -> None:
        """Download, stage and swap the kit copy, reinstall the launcher, re-place the skills."""
        from exakit.app import skills, whats_new
        from exakit.app.machine import kit_root
        latest = self.target_version()
        current = self.installed_version()
        if latest == current:
            self.ctx.ui.ok(f"exakit is already current ({current})")
            return
        if kit_root(self.ctx) != self.ctx.paths.kit:
            self.ctx.ui.info("This kit runs from a source checkout; update it with git, not exakit update.")
            return
        self.ctx.ui.info(f"Updating starter kit {current or 'unknown'} -> {latest}")
        self.ctx.paths.home.mkdir(parents=True, exist_ok=True)
        stage = self.ctx.paths.home / f".kit-stage.{int(time.time())}"
        stage.mkdir()
        ref = self._download(latest, stage)
        for required in REQUIRED:
            if not (stage / required).is_file():
                shutil.rmtree(stage, ignore_errors=True)
                raise Failed(f"Downloaded starter kit is incomplete (missing {required}); existing kit copy was left untouched.")
        staged, _ = self._swap(stage, latest)
        self.ctx.manifest_store.update(lambda m: (m.set("kit.source", f"{self.ctx.kit_repo}@{ref}"), m.set("kit.version", staged)))
        self.ctx.ui.ok(f"exakit updated to {staged}. Database data, credentials, and MCP state were not changed.")
        if any((self.ctx.paths.kit / "skills").glob("*/SKILL.md")):
            try:
                skills.install(self.ctx)
                self.ctx.ui.ok("AI skills refreshed from the new kit copy.")
            except Failed:
                self.ctx.ui.warn("The AI skills could not be refreshed - run: exakit skills-install")
        points = whats_new.points(self.ctx.paths.kit, staged)
        if points:
            self.ctx.ui.panel(f"What's new in {staged}", [f"- {p}" for p in points])
