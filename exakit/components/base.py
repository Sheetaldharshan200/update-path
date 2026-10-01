"""What the component lifecycles share: the record, the advertised version, verified downloads, the runtime facts."""

from __future__ import annotations

import time
from pathlib import Path

from exakit.adapters.net.github import asset_digest
from exakit.domain.errors import Failed
from exakit.domain.ids import env_var
from exakit.domain.manifest import Manifest
from exakit.domain.versions import resolve


class ComponentBase:
    id = ""
    key = ""            # the manifest block under components.<key>
    step = ""           # the installer step this component ticks

    def __init__(self, ctx) -> None:
        self.ctx = ctx

    # --- the record -----------------------------------------------------------------

    def recorded(self, field: str, default=None):
        """The component's recorded field from the install record, or ``default`` when there is no record or no such field."""
        manifest = self.ctx.manifest_or_none()
        return manifest.get(f"components.{self.key}.{field}", default) if manifest else default

    def record(self, **fields) -> None:
        """Write the given fields into the component's block of the install record."""
        def change(m: Manifest) -> None:
            for name, value in fields.items():
                m.set(f"components.{self.key}.{name}", value)
        self.ctx.manifest_store.update(change)

    def forget(self) -> None:
        """Drop the component's block, its desired version and its step tick from the install record."""
        def change(m: Manifest) -> None:
            m.delete(f"components.{self.key}")
            m.delete(f"desired.{self.id}")
            if self.step:
                m.unmark_step(self.step)
        self.ctx.manifest_store.update(change)

    def record_desired(self, version: str) -> None:
        """Record the version the install aimed for."""
        self.ctx.manifest_store.update(lambda m: m.set(f"desired.{self.id}", version))

    # --- versions -----------------------------------------------------------------------

    @property
    def source(self) -> dict:
        """The catalog's source block: repository, tag and asset templates, pins."""
        return self.ctx.catalog.component(self.id).source

    def repo(self) -> str:
        """The GitHub repository the component's releases come from, per the catalog."""
        return str(self.source["repo"])

    def tag(self, version: str) -> str:
        """The release tag for a version, from the catalog's template (``v{version}`` by default)."""
        return str(self.source.get("tag", "v{version}")).format(version=version)

    def fallback_version(self) -> str | None:
        """The catalog's last-resort version for this component, or None when it has none."""
        return self.ctx.catalog.component(self.id).fallback_version if self.id in self.ctx.catalog.component_ids() else None

    def target_version(self) -> str:
        """The version to install: EXAKIT_<ID>_VERSION, else the policy's answer from versions.json, else the catalog fallback."""
        pin = self.ctx.env.get(env_var(self.id, "VERSION"))
        resolved = resolve(self.id, policy=self.ctx.policy, env_pin=pin, doc=self.ctx.versions.current(), fallback=self.fallback_version())
        if resolved is None:
            raise Failed(f"Could not resolve the advertised {self.id} version.")
        return resolved.version

    def pin_applies(self, version: str) -> bool:
        """True when versions.json advertises exactly this version, so its pins (digests, release tags) apply."""
        doc = self.ctx.versions.current()
        return bool(doc) and doc.component_version(self.id) == version

    def published_digest(self, version: str, key: str) -> str | None:
        """The sha256 versions.json publishes for this version under ``key``, or None when it names another version."""
        doc = self.ctx.versions.current()
        return doc.sha256(self.id, key) if doc and self.pin_applies(version) else None

    def force(self) -> bool:
        """True when EXAKIT_FORCE_COMPONENT_INSTALL=1 asks for an install even over a working copy."""
        return self.ctx.env.get("EXAKIT_FORCE_COMPONENT_INSTALL") == "1"

    # --- downloads ---------------------------------------------------------------------

    def fetch_verified(self, url: str, dest: Path, *, digest: str | None, what: str, repo: str | None = None,
                       tag: str | None = None, asset: str | None = None) -> Path:
        """Download to ``dest`` and verify: the given digest, else the release API's, else refuse (or the unverified hatch)."""
        if digest is None and repo and tag and asset:
            digest = asset_digest(repo, tag, asset, self.ctx.net, endpoints=self.ctx.catalog.kit.endpoints, token=self.ctx.env.get("GITHUB_TOKEN"),
                                  cache_dir=self.ctx.paths.releases_cache)
        hatch = f"EXAKIT_ALLOW_UNVERIFIED_{self.id.upper()}"
        if digest is None and self.ctx.env.get(hatch) != "1":
            raise Failed(f"No checksum available for {what}; refusing to install an unverified {self.id} binary. Add its digest to "
                         f"versions.json (components.{self.id}.sha256) or check network access to the release API.",
                         hint=f"Override at your own risk with {hatch}=1")
        if digest is None:
            self.ctx.ui.warn(f"No digest available for {what} - proceeding WITHOUT checksum verification ({hatch}=1).")
        with self.ctx.ui.progress(f"Downloading {what}") as report:
            self.ctx.net.fetch(url, dest, sha256=digest, token=self.ctx.env.get("GITHUB_TOKEN"), what=what, progress=report)
        return dest

    def install_binary(self, staged: Path, dest: Path) -> None:
        """Place a staged binary at ``dest``, executable, through a temp file and an atomic rename."""
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_name(f".{dest.name}.tmp")
        tmp.write_bytes(staged.read_bytes())
        tmp.chmod(0o755)
        tmp.replace(dest)

    # --- the runtime facts ---------------------------------------------------------------

    def runtime_connection(self) -> tuple[str, int, str, str | None]:
        """(host, port, user, password file) from the install record; port 0 when no DSN is recorded."""
        manifest = self.ctx.manifest_or_none()
        dsn = (manifest.get("runtime.dsn") if manifest else "") or ""
        host, _, port = dsn.rpartition(":")
        return host, int(port) if port.isdigit() else 0, (manifest.get("runtime.user") if manifest else None) or "sys", \
            manifest.get("runtime.password_file") if manifest else None

    def password(self, path: str | None) -> str | None:
        """The password in the file at ``path``, stripped, or None when there is no file or it is empty."""
        if not path:
            return None
        try:
            return Path(path).read_text(encoding="utf-8").strip() or None
        except OSError:
            return None

    def elapsed(self, started: float) -> str:
        """The seconds since ``started`` (a monotonic clock value), as text for a closing line."""
        return f"{int(time.monotonic() - started)}s"

    # --- defaults ----------------------------------------------------------------------------

    def validate(self) -> None:
        """Check that the installed component works; the default checks nothing."""
        return

    def uninstall(self, *, dry_run: bool) -> list[str]:
        """Remove the component (a dry run only lists); the default removes nothing."""
        return []
