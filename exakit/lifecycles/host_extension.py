"""An extension installed into a host application through that application's own CLI (VS Code)."""

from __future__ import annotations

from pathlib import Path

from exakit.adapters.net.github import download_url
from exakit.domain.errors import Failed

from .base import LifecycleBase, temp_dir

VSCODE_CLIS = ("code", "code-insiders", "cursor", "windsurf", "codium")
VSCODE_APP_PATHS = (
    "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
    "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code-insiders",
    "/Applications/Cursor.app/Contents/Resources/app/bin/cursor",
    "/Applications/Windsurf.app/Contents/Resources/app/bin/windsurf",
    "/Applications/VSCodium.app/Contents/Resources/app/bin/codium",
    "/usr/share/code/bin/code",
)
NOT_FOUND = ("VS Code was not found, and neither was a fork the kit can drive (VS Code Insiders, Cursor, VSCodium or Windsurf). "
             "Install VS Code from https://code.visualstudio.com - or, on a fork, put its CLI on PATH - then run: exakit marketplace")


class HostExtensionLifecycle(LifecycleBase):
    extension_id = "exasol.exasol-vscode"

    def host_cli(self) -> str | None:
        """The VS Code (or fork) command line, recorded or found on PATH; None when absent."""
        recorded = self.recorded("code_cli")
        if recorded and Path(recorded).exists():
            return recorded
        for name in VSCODE_CLIS:
            found = self.ctx.runner.which(name)
            if found:
                return found
        home = self.ctx.env.get("HOME", "")
        for path in VSCODE_APP_PATHS + tuple(p.replace("/Applications", f"{home}/Applications", 1) for p in VSCODE_APP_PATHS if p.startswith("/Applications")):
            if Path(path).exists():
                return path
        return None

    def applicable(self) -> tuple[bool, str]:
        """(True, '') when a host editor is found, else the reason."""
        return (True, "") if self.host_cli() else (False, NOT_FOUND)

    def live_version(self) -> str | None:
        """The extension version the editor reports, or None."""
        cli = self.host_cli()
        if not cli:
            return None
        done = self.ctx.runner.run([cli, "--list-extensions", "--show-versions"], timeout=60)
        for line in done.out.splitlines():
            if line.lower().startswith(self.extension_id + "@"):
                return line.split("@", 1)[1].strip()
        return None

    def installed_version(self) -> str | None:
        """The live version when the kit installed the extension; else None."""
        return self.live_version() if self.recorded("version") else None

    def system_present(self) -> bool:
        """True when the extension is installed but not by the kit."""
        return not self.recorded("version") and self.live_version() is not None

    def asset_name(self, version: str) -> str:
        """The .vsix asset for a version."""
        return f"{self.addon.id}-{version}.vsix"

    def install(self, version: str) -> None:
        """Download the verified .vsix and install it into the editor."""
        cli = self.host_cli()
        if not cli:
            raise Failed("VS Code's 'code' command was not found - install VS Code (https://code.visualstudio.com), then retry")
        force = self.ctx.env.get("EXAKIT_FORCE_COMPONENT_INSTALL") == "1"
        if self.live_version() == version and not force:
            self.ctx.ui.ok(f"{self.addon.id} {version} already installed")
        else:
            asset = self.asset_name(version)
            self.ctx.ui.info(f"Downloading {self.addon.title} v{version} ({asset})")
            with temp_dir("exakit-vsix-") as tmp:
                vsix = Path(tmp) / asset
                self.fetch_verified(download_url(self.addon.source["repo"], f"v{version}", asset, endpoints=self.ctx.catalog.kit.endpoints), vsix,
                                    digest=self.published_digest(version, "vsix"), what=asset,
                                    repo=self.addon.source["repo"], tag=f"v{version}", asset=asset)
                done = self.ctx.runner.run([cli, "--install-extension", str(vsix), "--force"], timeout=600)
            if not done.ok:
                raise Failed("the extension could not be installed. Install it from VS Code's Extensions view instead: search for 'Exasol'")
            if not self.live_version():
                raise Failed("VS Code did not list the extension after installing it")
            self.ctx.ui.ok(f"{self.addon.title} installed ({self.live_version()})")
        self.record(version=version, extension_id=self.extension_id, code_cli=cli)

    def validate(self) -> None:
        """The editor still lists the extension; records validated."""
        live = self.live_version()
        if not live:
            self.ctx.ui.warn(f"{self.addon.title} is not listed by the editor - reinstall with: exakit update {self.addon.id}")
            self.record(validated=False)
            return
        self.record(validated=True)
        self.ctx.ui.ok(f"{self.addon.title} answers: {self.extension_id}@{live}")

    def summary(self) -> str | None:
        """The closing line."""
        return "Exasol view in VS Code's sidebar"

    def uninstall(self, *, dry_run: bool) -> list[str]:
        """Ask the editor to remove the extension and forget it."""
        if not self.recorded("version"):
            self.ctx.ui.info("The Exasol VS Code extension is not kit-managed - nothing to remove.")
            self.ctx.ui.info(f"A copy you installed yourself is removed inside VS Code, or with: code --uninstall-extension {self.extension_id}")
            return []
        if dry_run:
            self.ctx.ui.text(f"  will remove: the Exasol VS Code extension ({self.extension_id}) from VS Code")
            return [self.extension_id]
        cli = self.host_cli()
        if cli and self.live_version() and not self.ctx.runner.run([cli, "--uninstall-extension", self.extension_id], timeout=600).ok:
            self.ctx.ui.warn("VS Code could not remove the extension - remove it from the Extensions view.")
        self.forget()
        self.ctx.ui.ok(f"{self.addon.title} removed - reinstall any time with: exakit marketplace")
        return [self.extension_id]
