"""The AI skill set: a light component that can move without a kit release, from the same tarball the kit uses."""

from __future__ import annotations

import shutil
import tarfile
import time
from pathlib import Path

from exakit.domain.errors import Failed
from exakit.domain.versions import is_newer

from .base import ComponentBase
from .kit import kit_version_at


class Lifecycle(ComponentBase):
    id = "skills"
    key = "skills"
    step = ""

    def installed_version(self) -> str | None:
        """The recorded skill set version, or None."""
        return self.recorded("version") or None

    def fallback_version(self) -> str | None:
        """The version the kit copy's skills carry."""
        from exakit.app.machine import skills_local_version
        return skills_local_version(self.ctx)

    def install(self, version: str) -> None:
        """Place the skills."""
        from exakit.app import skills
        skills.install(self.ctx)

    def _stage(self, latest: str, current: str | None) -> Path | None:
        """The kit tarball's skills/, staged with its own .version marker; None (after a warning) when it cannot be had."""
        stage = Path(self.ctx.paths.cache / f"skills-stage-{int(time.time())}")
        stage.mkdir(parents=True, exist_ok=True)
        archive = stage / "kit.tar.gz"
        try:
            self.ctx.net.fetch(self.ctx.catalog.kit.endpoints.url("archive_branch", repo=self.ctx.kit_repo, ref="main"), archive, what="skill set")
            with tarfile.open(archive) as tar:
                members = [m for m in tar.getmembers() if "/" in m.name]
                for member in members:
                    member.name = member.name.split("/", 1)[1]
                tar.extractall(stage, members=members, filter="data")
        except (Failed, tarfile.TarError, OSError):
            shutil.rmtree(stage, ignore_errors=True)
            self.ctx.ui.warn(f"Could not download the skill set from {self.ctx.kit_repo}; the skills were left as they are. Retry: exakit update")
            return None
        archive.unlink(missing_ok=True)
        if not any((stage / "skills").glob("*/SKILL.md")):
            shutil.rmtree(stage, ignore_errors=True)
            self.ctx.ui.warn("The downloaded kit carries no skills; the skills were left as they are.")
            return None
        staged = kit_version_at(stage, "components.skills.version") or latest
        if staged != latest and is_newer(latest, staged):
            self.ctx.ui.warn(f"The downloaded skill set is {staged}, not the advertised {latest} - the published manifest is a few minutes "
                             f"ahead of main. Recording {staged}; the next update picks up the rest.")
        (stage / "skills" / ".version").write_text(f"{staged}\n", encoding="utf-8")
        return stage

    def update(self, options: list[str] | None = None) -> None:
        """Re-place the skills from the kit copy."""
        from exakit.app import skills
        from exakit.app.machine import kit_root
        try:
            latest = self.target_version()
        except Failed:
            self.ctx.ui.warn("Could not resolve the advertised skill set; the skills were left as they are.")
            return
        current = self.installed_version()
        if latest == current:
            self.ctx.ui.ok(f"skills are already current ({current})")
            return
        root = kit_root(self.ctx)
        if root != self.ctx.paths.kit:
            self.ctx.ui.info("This kit runs from a source checkout; placing the skills it carries.")
            skills.install(self.ctx)
            return
        self.ctx.ui.info(f"Updating AI skills {current or 'not installed'} -> {latest}")
        stage = self._stage(latest, current)
        if stage is None:
            return
        backup = self._swap(root / "skills", stage)
        if backup is None:
            return
        try:
            skills.install(self.ctx)
        except Failed:
            self.ctx.ui.warn("The new skills are in the kit copy but could not be placed - run: exakit skills-install")
            return
        shutil.rmtree(backup, ignore_errors=True)
        self.ctx.ui.ok(f"AI skills updated to {self.installed_version()}. Restart or reload your AI client to pick them up.")

    def _swap(self, target: Path, stage: Path) -> Path | None:
        """The staged skills/ in place of the current one; returns the set-aside copy (an empty path when there was none)."""
        backup = target.with_name(f"skills.backup-{time.strftime('%Y%m%d-%H%M%S')}")
        if target.is_dir():
            target.rename(backup)
        try:
            (stage / "skills").rename(target)
        except OSError:
            if backup.is_dir():
                backup.rename(target)
            shutil.rmtree(stage, ignore_errors=True)
            self.ctx.ui.warn("Could not install the downloaded skills; the previous set was put back.")
            return None
        shutil.rmtree(stage, ignore_errors=True)
        return backup

    def uninstall(self, *, dry_run: bool) -> list[str]:
        """Remove the skills from the agents' folders."""
        from exakit.app import skills
        removed: list[str] = []
        names = [s.id for s in skills.shipped(self.ctx)] or list(self.recorded("installed") or [])
        for root in skills.roots(self.ctx):
            found = [root / name for name in names if (root / name).exists()]
            if not found:
                continue
            word = "skill" if len(found) == 1 else "skills"
            self.ctx.ui.info(f"{'  will remove: ' if dry_run else ''}{len(found)} AI {word} from {root}")
            for path in found:
                removed.append(str(path))
                if not dry_run:
                    shutil.rmtree(path, ignore_errors=True)
        if not dry_run:
            skills.remove_allowlist(self.ctx)
            self.forget()
        return removed
