"""The Exasol Personal launcher: a verified release binary the runtime adapter drives; updates keep the deployment."""

from __future__ import annotations

import tarfile
import time
from pathlib import Path

from exakit.adapters.net.digest import digest_from_checksums, verify_sha256
from exakit.adapters.net.github import download_url
from exakit.domain.errors import Failed
from exakit.domain.versions import is_newer, parse_version
from exakit.lifecycles.base import temp_dir

from .base import ComponentBase

def major(version: str | None) -> str:
    """The major number of a version, or '' when it does not parse."""
    try:
        return str(parse_version(version or "")[0][0])
    except (ValueError, IndexError):
        return ""


class Lifecycle(ComponentBase):
    id = "personal"
    key = "runtime"
    step = "launcher"

    @property
    def bin(self) -> Path:
        """The launcher binary in the bin dir."""
        return self.ctx.paths.bin_dir / ("exasol.exe" if self.ctx.platform.os == "windows" else "exasol")

    def runtime(self):
        """The runtime adapter, wired once per command."""
        from exakit.app.runtime_ops import runtime
        return runtime(self.ctx)

    def installed_version(self) -> str | None:
        """The deployed runtime version the record names, or None."""
        manifest = self.ctx.manifest_or_none()
        return (manifest.get("runtime.version") if manifest else None) or None

    def asset_name(self, version: str) -> str:
        """The release archive for this platform, named by the catalog; absent means no launcher is published here."""
        assets = self.source.get("assets") or {}
        name = assets.get(self.ctx.platform.platform_key) or assets.get(f"linux-{self.ctx.platform.arch}")
        if not name:
            raise Failed(f"No Exasol launcher is published for this platform ({self.ctx.platform.platform_key}).")
        return str(name)

    def release_url(self, version: str, name: str) -> str:
        """The download URL of a release asset."""
        return download_url(self.repo(), self.tag(version), name, endpoints=self.ctx.catalog.kit.endpoints)

    # --- install ----------------------------------------------------------------------------

    def _existing_supports_local(self) -> str | None:
        found = self.ctx.runner.which("exasol")
        if not found:
            return None
        done = self.ctx.runner.run([found, "install", "--help"], timeout=10)
        return found if done.ok and "local" in done.out else None

    def refuse_downgrade(self, version: str) -> None:
        """Refuse to install a launcher older than the deployed runtime."""
        deployed = self.runtime().deployed_version() if hasattr(self.runtime(), "deployed_version") else None
        if deployed and is_newer(deployed, version):
            self.ctx.ui.error(f"The Exasol Personal deployment on this machine is version {deployed}, which is newer than the launcher "
                              f"version this kit advertises ({version}).")
            self.ctx.ui.info(f"A {version} launcher refuses to drive a {deployed} deployment, so installing it would leave your database unusable. Nothing was installed or changed.")
            self.ctx.ui.info(f"To install the launcher that matches your deployment, re-run with: EXAKIT_PERSONAL_VERSION={deployed}")
            self.ctx.ui.info(f"To start over on {version} instead, remove the newer deployment first with 'exakit uninstall' - that deletes its data.")
            raise Failed(f"Refusing to install launcher {version} over a newer {deployed} deployment.")

    def install(self, version: str) -> None:
        """Download the verified launcher archive and place the binary."""
        if not self.force():
            existing = self._existing_supports_local()
            if existing:
                self.ctx.ui.ok(f"Exasol launcher already installed: {existing}")
                return
            if self.ctx.runner.which("exasol"):
                self.ctx.ui.warn(f"The installed Exasol launcher ({self.ctx.runner.which('exasol')}) does not support the 'local' preset (too old).")
                self.ctx.ui.info(f"Installing launcher v{version} to {self.bin} - your existing launcher is left untouched")
        self.refuse_downgrade(version)
        asset = self.asset_name(version)
        started = time.monotonic()
        self.ctx.ui.info(f"Downloading Exasol launcher v{version} ({asset})")
        with temp_dir("exakit-personal-") as tmp:
            archive = Path(tmp) / asset
            with self.ctx.ui.progress(f"Downloading {asset}") as report:
                self.ctx.net.fetch(self.release_url(version, asset), archive, what=asset, progress=report)
            checksums = Path(tmp) / "checksums.txt"
            self.ctx.net.fetch(self.release_url(version, str(self.source["checksums"]).format(version=version)), checksums, what="checksums")
            digest = digest_from_checksums(checksums.read_text(encoding="utf-8", errors="replace"), asset)
            if not digest:
                raise Failed(f"The release's checksums file does not list {asset}; refusing an unverified launcher.")
            verify_sha256(archive, digest, what=asset)
            self.ctx.ui.info(f"Installing launcher to {self.bin}")
            with tarfile.open(archive) as tar:
                tar.extractall(tmp, filter="data")
            binaries = [p for p in Path(tmp).rglob("exasol") if p.is_file()]
            if not binaries:
                raise Failed("The release archive did not contain an 'exasol' binary")
            self.install_binary(binaries[0], self.bin)
        done = self.ctx.runner.run([str(self.bin), "--version"], timeout=10)
        if self.ctx.platform.os == "macos" and done.code in (137, 9, -9):
            self.ctx.ui.error(f"{self.bin} was installed but the kernel killed it on its first run (SIGKILL, no output).")
            self.ctx.ui.info("On Apple silicon that is a code-signature problem in the downloaded release, not a problem with this machine.")
            self.ctx.ui.info(f"Confirm it with: codesign -dv \"{self.bin}\"   An ad-hoc signature unblocks you locally: codesign -s - \"{self.bin}\"")
            raise Failed("The Exasol launcher was downloaded and verified but cannot be executed on this machine.")
        self.ctx.ui.ok(f"Exasol launcher v{version} installed to {self.bin} ({self.elapsed(started)})")

    # --- update -------------------------------------------------------------------------------------

    def _record_launcher(self, version: str) -> None:
        from exakit.app.runtime_ops import credentials
        rt = self.runtime()
        def change(m):
            warning = rt.record(m, credentials(self.ctx)) if hasattr(rt, "record") else None
            m.set("desired.runtime.personal", version)
            if warning:
                self.ctx.ui.warn(warning)
        self.ctx.manifest_store.update(change)

    def update(self, options: list[str] | None = None) -> None:
        """Update the launcher and, with consent, the deployment."""
        mode = "default"
        for option in options or []:
            if option not in ("--plan", "--backup", "--apply"):
                raise Failed(f"Unknown option '{option}' for 'exakit update'.")
            mode = option.lstrip("-")
        latest = self.target_version()
        current = self.installed_version()
        if latest == current:
            self.ctx.ui.ok(f"Exasol Personal launcher is already current ({current})")
            return
        if major(current) and major(latest) and major(current) != major(latest):
            self._major_upgrade(mode, current, latest)
            return
        if mode == "plan":
            self.ctx.ui.info(f"Exasol Personal launcher {current or 'unknown'} -> {latest}.")
            self.ctx.ui.info("The launcher binary is replaced; the deployment and its data are not touched.")
            self.ctx.ui.info("Apply it with: exakit update runtime")
            return
        if mode == "backup":
            self.ctx.ui.info(f"Exasol Personal {current or 'unknown'} -> {latest} replaces the launcher binary only - it neither deletes nor "
                             "migrates database content, so there is nothing to back up first.")
            self.ctx.ui.info("Apply it with: exakit update runtime")
            return
        self.ctx.ui.info(f"Updating Exasol Personal launcher {current or 'unknown'} -> {latest}")
        self.ctx.env = {**dict(self.ctx.env), "EXAKIT_FORCE_COMPONENT_INSTALL": "1", "EXAKIT_PERSONAL_VERSION": latest}
        self.bin.unlink(missing_ok=True)
        self.install(latest)
        self._record_launcher(latest)
        self.ctx.ui.ok("Exasol Personal launcher updated; deployment data was not changed")

    def _major_upgrade(self, mode: str, current: str | None, latest: str) -> None:
        deploy_dir = getattr(self.runtime(), "deploy_dir", None)
        if mode in ("plan", "default"):
            self.ctx.ui.warn(f"Exasol Personal major upgrade detected: {current or 'unknown'} -> {latest}.")
            self.ctx.ui.warn("Personal keeps runtime and database content together in the local deployment.")
            self.ctx.ui.info("No destructive action was taken.")
            self.ctx.ui.info(f"Deployment: {deploy_dir}")
            self.ctx.ui.info(f"Follow the Exasol Personal {latest} migration/redeployment guidance for your data.")
            if mode == "default":
                raise Failed("A major Exasol Personal upgrade needs a backup and a data migration first.", remedy="exakit update runtime --backup")
            return
        if mode == "backup":
            self._backup(current, latest, deploy_dir)
            return
        manifest = self.ctx.manifest()
        backup = manifest.get("backups.personal_upgrade.latest")
        if not backup or not Path(backup).is_file():
            raise Failed("Create a backup first.", remedy="exakit update runtime --backup")
        if manifest.get("backups.personal_upgrade.from") != (current or "unknown") or manifest.get("backups.personal_upgrade.to") != latest:
            raise Failed(f"The latest recorded Personal backup does not match this upgrade ({current or 'unknown'} -> {latest}).")
        self.ctx.ui.info(f"Updating Exasol Personal launcher {current or 'unknown'} -> {latest}")
        self.ctx.env = {**dict(self.ctx.env), "EXAKIT_FORCE_COMPONENT_INSTALL": "1", "EXAKIT_PERSONAL_VERSION": latest}
        self.bin.unlink(missing_ok=True)
        self.install(latest)
        rt = self.runtime()
        def change(m):
            m.set("runtime.launcher", rt.cli())
            m.set("runtime.launcher_version", latest)
            m.set("desired.runtime.personal", latest)
            m.set("runtime.version", latest)
            m.set("runtime.migration_pending", latest)
        self.ctx.manifest_store.update(change)
        self.ctx.ui.warn("Launcher updated. Existing database content was not deleted or migrated.")
        self.ctx.ui.info(f"Recorded runtime.version {latest} with runtime.migration_pending {latest} - clear that key once the Exasol Personal {latest} data migration is done.")
        self.ctx.ui.ok(f"Exasol Personal launcher update applied with backup available at {backup}")

    def _backup(self, current: str | None, latest: str, deploy_dir) -> None:
        if not deploy_dir or not Path(deploy_dir).is_dir():
            raise Failed(f"No Exasol Personal deployment directory found at {deploy_dir}; nothing was backed up.")
        backups = self.ctx.paths.home / "backups"
        backups.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        archive = backups / f"personal-upgrade-{current or 'unknown'}-to-{latest}-{stamp}.tar.gz"
        self.ctx.ui.info(f"Backing up the deployment at {deploy_dir} to {archive}")
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(str(deploy_dir), arcname=Path(deploy_dir).name)
        def change(m):
            m.set("backups.personal_upgrade.latest", str(archive))
            m.set("backups.personal_upgrade.from", current or "unknown")
            m.set("backups.personal_upgrade.to", latest)
        self.ctx.manifest_store.update(change)
        self.ctx.ui.ok(f"Backup written: {archive}. Apply the upgrade with: exakit update runtime --apply")

    def uninstall(self, *, dry_run: bool) -> list[str]:
        """The deployment and ALL its data; the launcher binary itself goes with the bin dir sweep."""
        rt = self.runtime()
        if dry_run:
            self.ctx.ui.info("  will remove: the local Exasol personal deployment and ALL its data")
            return ["deployment"]
        self.ctx.ui.info("Removing the local Exasol personal deployment and all data")
        if rt.deployment_exists():
            self.ctx.ui.info("Destroying the local Exasol Personal deployment")
            if hasattr(rt, "destroy") and not rt.destroy():
                self.ctx.ui.warn("The launcher reported errors while destroying the deployment. What it said: exakit logs setup")
        else:
            self.ctx.ui.info("No active deployment found")
        if hasattr(rt, "reap_orphan") and not rt.reap_orphan(rt.db_port(), self.ctx.ui.info):
            pass
        self.ctx.manifest_store.update(lambda m: (m.set("runtime.status", "removed"), m.unmark_step("runtime")))
        return ["deployment"]
