"""What every add-on lifecycle shares: versions, downloads with digests, launchers, the manifest block."""

from __future__ import annotations

import os
import shutil
import stat
import tempfile
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from exakit.adapters.net.github import asset_digest
from exakit.adapters.process.services import ServiceSpec
from exakit.adapters.uv import UvTool, find_uv
from exakit.domain.catalog import Addon
from exakit.domain.errors import Failed
from exakit.domain.ids import env_var
from exakit.domain.manifest import Manifest
from exakit.domain.versions import resolve


@dataclass(frozen=True, slots=True)
class ServiceHooks:
    status: Callable[[], str]
    start: Callable[[], None]
    stop: Callable[[], None]
    url: Callable[[], str | None]
    log_path: Callable[[], Path | None]
    autostart: Callable[[], ServiceSpec | None]


class LifecycleBase:
    """Shared machinery. Subclasses fill in the steps that differ."""

    def __init__(self, ctx, addon: Addon) -> None:
        self.ctx = ctx
        self.addon = addon
        self.key = addon.manifest_key

    # --- the record ---------------------------------------------------------------

    def recorded(self, field: str, default=None):
        """The add-on's recorded field from the install record, or ``default`` when there is no record or no such field."""
        manifest = self.ctx.manifest_or_none()
        return manifest.get(f"components.{self.key}.{field}", default) if manifest else default

    def record(self, **fields) -> None:
        """Write the given fields into the add-on's block of the install record."""
        def change(m: Manifest) -> None:
            for name, value in fields.items():
                m.set(f"components.{self.key}.{name}", value)
        self.ctx.manifest_store.update(change)

    def forget(self) -> None:
        """Drop the add-on's block, its desired version and its step tick from the install record."""
        def change(m: Manifest) -> None:
            m.delete(f"components.{self.key}")
            m.delete(f"desired.{self.key}")
        self.ctx.manifest_store.update(change)

    def note_failure(self, reason: str) -> None:
        """Record the add-on as not validated and keep the reason for status to show."""
        self.record(validated=False)
        self.ctx.ui.warn(f"{self.addon.id} was not installed: {reason}")
        self.ctx.ui.warn(f"Everything else in the kit is unaffected. Retry with: exakit update {self.addon.id}")

    # --- versions -----------------------------------------------------------------------

    def target_version(self) -> str:
        """The version to install: EXAKIT_<ID>_VERSION, else the policy's answer from versions.json, else the catalog fallback."""
        pin = self.ctx.env.get(env_var(self.addon.id, "VERSION"))
        resolved = resolve(self.addon.id, policy=self.ctx.policy, env_pin=pin, doc=self.ctx.versions.current(),
                           fallback=self.addon.fallback_version)
        if resolved is None:
            raise Failed(f"Could not resolve the advertised {self.addon.id} version.")
        return resolved.version

    def pin_applies(self, version: str) -> bool:
        """True when versions.json advertises exactly this version, so its pins (digests, release tags) apply."""
        doc = self.ctx.versions.current()
        return bool(doc) and doc.component_version(self.addon.id) == version

    def published_digest(self, version: str, key: str) -> str | None:
        """The sha256 versions.json publishes for this version under ``key``, or None when it names another version."""
        doc = self.ctx.versions.current()
        return doc.sha256(self.addon.id, key) if doc and self.pin_applies(version) else None

    # --- downloads -------------------------------------------------------------------------

    def fetch_verified(self, url: str, dest: Path, *, digest: str | None, what: str, repo: str | None = None,
                       tag: str | None = None, asset: str | None = None) -> Path:
        """Download and verify. Without a digest: the release API's, else refuse (or the unverified hatch)."""
        if digest is None and repo and tag and asset:
            digest = asset_digest(repo, tag, asset, self.ctx.net, endpoints=self.ctx.catalog.kit.endpoints, token=self.ctx.env.get("GITHUB_TOKEN"),
                                  cache_dir=self.ctx.paths.releases_cache)
        hatch = f"EXAKIT_ALLOW_UNVERIFIED_{self.addon.id.upper().replace('-', '_')}"
        if digest is None and self.ctx.env.get(hatch) != "1":
            raise Failed(f"No checksum is available for {what}; refusing an unverified download "
                         f"(components.{self.addon.id}.sha256 in versions.json, or the release's own digest).",
                         hint=f"{hatch}=1 overrides")
        with self.ctx.ui.progress(f"Downloading {what}") as report:
            self.ctx.net.fetch(url, dest, sha256=digest, token=self.ctx.env.get("GITHUB_TOKEN"), what=what, progress=report)
        return dest

    # --- tools ----------------------------------------------------------------------------------

    def uv(self) -> UvTool:
        """The uv tool for the kit's venvs, wired once per command and installed on first use."""
        if self.ctx.uv is not None:
            return self.ctx.uv
        bin_path = find_uv(self.ctx.env, self.ctx.paths.home, self.ctx.runner, windows=self.ctx.platform.os == "windows")
        if not bin_path:
            raise Failed("uv (the Python tool runner) is not available - install it from https://docs.astral.sh/uv/ and re-run",
                         remedy=f"exakit update {self.addon.id}")
        self.ctx.uv = UvTool(bin_path, self.ctx.runner, python_version=self.ctx.catalog.kit.managed_python, windows=self.ctx.platform.os == "windows")
        return self.ctx.uv

    def write_launcher(self, name: str, content: str) -> Path:
        """Write an executable launcher of that name into the bin dir and return its path."""
        path = self.ctx.paths.bin_dir / name
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(f".{name}.tmp{os.getpid()}")
        tmp.write_text(content, encoding="utf-8")
        tmp.chmod(0o755)
        tmp.replace(path)
        return path

    def remove_paths(self, paths: list[Path], *, dry_run: bool) -> list[str]:
        """Remove the given paths (a dry run only names them); the answer lists what went or would go."""
        removed = []
        for path in paths:
            if not path.exists() and not path.is_symlink():
                continue
            removed.append(str(path))
            if dry_run:
                self.ctx.ui.text(f"  will remove: {path}")
                continue
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path, ignore_errors=True)
            else:
                path.unlink(missing_ok=True)
        return removed

    def runtime_credentials(self) -> tuple[str, str, str | None]:
        """(dsn, user, password_file) of the database admin from the install record."""
        manifest = self.ctx.manifest_or_none()
        if manifest is None:
            return "", "sys", None
        return manifest.get("runtime.dsn") or "", manifest.get("runtime.user") or "sys", manifest.get("runtime.password_file")

    # --- defaults subclasses may keep ------------------------------------------------------------

    def applicable(self) -> tuple[bool, str]:
        """(True, '') when the add-on can run on this machine, else (False, the reason the marketplace shows)."""
        if not self.addon.supports(self.ctx.platform.platform_key):
            return False, f"no build is published for this platform ({self.ctx.platform.platform_key})"
        return True, ""

    def system_present(self) -> bool:
        """True when a copy the kit did not install is already on PATH; the marketplace then offers nothing."""
        for name in {self.addon.id, self.addon.launcher or self.addon.id}:
            found = self.ctx.runner.which(name)
            if found and Path(found).resolve() != (self.ctx.paths.bin_dir / name).resolve():
                return True
        return False

    def service(self) -> ServiceHooks | None:
        """The service hooks of an add-on that runs as a daemon; None for the others."""
        return None

    def summary(self) -> str | None:
        """One line for the install's closing summary, or None when there is nothing to say."""
        return None

    def validate(self) -> None:
        """Check that the installed add-on works; subclasses record validated=True or False and say what they found."""
        return

    def update(self) -> None:
        """Same version: rewrite the launchers (repair); otherwise force a reinstall, then validate."""
        target = self.target_version()
        current = self.installed_version()
        if current == target:
            self.repair()
            self.ctx.ui.ok(f"{self.addon.id} is already current ({target})")
            return
        self.ctx.ui.info(f"Updating {self.addon.id} {current or 'not installed'} -> {target}")
        self.install(target)
        self.validate()
        self.ctx.manifest_store.update(lambda m: m.set(f"desired.{self.key}", target))
        self.ctx.ui.ok(f"{self.addon.id} updated; database data was not changed")

    def repair(self) -> None:
        """Rewrite what the add-on keeps outside its venv (launchers, profiles); a no-op for most."""
        return

    def installed_version(self) -> str | None:
        """The installed version, or None; every lifecycle answers this."""
        raise NotImplementedError

    def install(self, version: str) -> None:
        """Install this version into the kit; every lifecycle defines its steps."""
        raise NotImplementedError

    def uninstall(self, *, dry_run: bool) -> list[str]:
        """Remove the add-on (a dry run only lists what would go) and return what went."""
        raise NotImplementedError


def wait_for(probe: Callable[[], bool], *, seconds: int, every: float = 2.0) -> bool:
    """Poll ``probe`` every ``every`` seconds until it answers True or ``seconds`` pass; the answer is whether it did."""
    started = time.monotonic()
    while time.monotonic() - started < seconds:
        if probe():
            return True
        time.sleep(every)
    return probe()


def make_executable(path: Path) -> None:
    """Add the execute bits."""
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def temp_dir(prefix: str) -> tempfile.TemporaryDirectory:
    """A temporary directory with that prefix, removed when the ``with`` block ends."""
    return tempfile.TemporaryDirectory(prefix=prefix)
