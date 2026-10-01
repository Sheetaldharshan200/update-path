"""Where an add-on's release assets come from: the source repository's own release first, the kit's mirror after it.

Each entry of the catalog's ``source.releases`` names one site: a repository (or ``mirror: kit``),
a tag template, the asset per platform key (``wheel`` for a Python wheel), how the site publishes
its digests (``sidecar`` for ``<asset>.sha256`` beside the asset, else the name of its checksums
file, else the release API alone), the archive ``member`` that is the binary, and ``pins``, the
``versions.json`` map that pins this site's digests. The sites are tried in order: the next one
answers only when a download could not complete. A checksum that does not match stops the install
at once; it is never a reason to try elsewhere.
"""

from __future__ import annotations

import shutil
import tarfile
import zipfile
from dataclasses import dataclass
from fnmatch import fnmatch
from pathlib import Path
from typing import Any

from exakit.adapters.net.digest import ChecksumMismatch, digest_from_checksums
from exakit.adapters.net.github import download_url
from exakit.domain.errors import Failed
from exakit.domain.ids import env_var


@dataclass(frozen=True, slots=True)
class Site:
    repo: str
    tag: str                        # already filled for the version
    assets: dict[str, str]          # platform key (or "wheel") -> asset name template
    checksums: str | None           # "sidecar", a checksums file on the release, or None (the release API only)
    member: str | None              # the archive member that is the binary (a glob over the path inside the archive)
    pins: str | None                # the versions.json map that pins this site's digests (components.<id>.<pins>.<key>)
    mirror: bool                    # the kit's own copy: EXAKIT_<ID>_MIRROR_REPO and kit.source override its repository

    def asset(self, key: str, version: str) -> str | None:
        """The asset's name for this version, or None when the site does not publish one under ``key``."""
        template = self.assets.get(key)
        return _fill(template, version) if template else None

    @property
    def label(self) -> str:
        """``owner/repo@tag`` for messages and the log."""
        return f"{self.repo}@{self.tag}"


@dataclass(frozen=True, slots=True)
class Fetched:
    path: Path
    site: Site
    asset: str


def _fill(template: str, version: str) -> str:
    return template.format(version=version, bare=version.lstrip("v"))


def _mirror_repo(lifecycle) -> str:
    """EXAKIT_<ID>_MIRROR_REPO, else the repository this kit copy came from (kit.source), else the kit repository."""
    explicit = lifecycle.ctx.env.get(env_var(lifecycle.addon.id, "MIRROR_REPO"))
    if explicit:
        return explicit
    manifest = lifecycle.ctx.manifest_or_none()
    source = manifest.get("kit.source") if manifest else None
    if isinstance(source, str) and "@" in source and "/" in source.split("@")[0]:
        return source.split("@")[0]
    return lifecycle.ctx.kit_repo


def _mirror_tag(lifecycle, version: str) -> str | None:
    """EXAKIT_<ID>_MIRROR_TAG or _RELEASE_TAG, else the ``release`` pin in versions.json, else None (the template)."""
    for suffix in ("MIRROR_TAG", "RELEASE_TAG"):
        explicit = lifecycle.ctx.env.get(env_var(lifecycle.addon.id, suffix))
        if explicit:
            return explicit
    doc = lifecycle.ctx.versions.current()
    pinned = doc.value(f"components.{lifecycle.addon.id}.release") if doc and lifecycle.pin_applies(version) else None
    return str(pinned) if pinned else None


def _site(lifecycle, entry: dict[str, Any], version: str) -> Site:
    mirror = entry.get("mirror") == "kit"
    tag = (_mirror_tag(lifecycle, version) if mirror else None) or _fill(str(entry.get("tag", "{version}")), version)
    assets = {str(k): str(v) for k, v in (entry.get("assets") or {}).items()}
    doc = lifecycle.ctx.versions.current()
    wheel = doc.value(f"components.{lifecycle.addon.id}.wheel") if doc and lifecycle.pin_applies(version) else None
    if "wheel" in assets and isinstance(wheel, str) and wheel:
        assets["wheel"] = wheel
    return Site(repo=_mirror_repo(lifecycle) if mirror else str(entry["repo"]), tag=tag, assets=assets,
                checksums=entry.get("checksums"), member=entry.get("member"), pins=entry.get("pins"), mirror=mirror)


def sites(lifecycle, version: str) -> list[Site]:
    """The release sites the catalog names for the add-on, in the order they are tried."""
    return [_site(lifecycle, dict(entry), version) for entry in lifecycle.addon.source.get("releases") or []]


def has_asset(lifecycle, key: str) -> bool:
    """True when some site publishes an asset under ``key`` (a platform key or ``wheel``)."""
    return any(key in (entry.get("assets") or {}) for entry in lifecycle.addon.source.get("releases") or [])


def asset_for(lifecycle, version: str, key: str) -> str | None:
    """The asset name the first site that has one gives for ``key``; None when no site does."""
    for site in sites(lifecycle, version):
        name = site.asset(key, version)
        if name:
            return name
    return None


def _pinned(lifecycle, site: Site, version: str, pin_key: str | None) -> str | None:
    if not site.pins or not pin_key or not lifecycle.pin_applies(version):
        return None
    doc = lifecycle.ctx.versions.current()
    value = doc.value(f"components.{lifecycle.addon.id}.{site.pins}.{pin_key}") if doc else None
    return value if isinstance(value, str) and value else None


def _published(lifecycle, site: Site, asset: str) -> str | None:
    """The digest the site's checksums publish for the asset: the sidecar or the checksums file; None when neither answers."""
    if not site.checksums:
        return None
    name = f"{asset}.sha256" if site.checksums == "sidecar" else site.checksums
    url = download_url(site.repo, site.tag, name, endpoints=lifecycle.ctx.catalog.kit.endpoints)
    try:
        text = lifecycle.ctx.net.text(url, token=lifecycle.ctx.env.get("GITHUB_TOKEN"))
    except Failed as err:
        lifecycle.ctx.log.line("WARN", f"{name} on {site.label} did not answer: {err.message}")
        return None
    return digest_from_checksums(text, asset)


def fetch_asset(lifecycle, version: str, key: str, dest_dir: Path, *, what: str, pin_key: str | None = None) -> Fetched:
    """Download the asset under ``key`` into ``dest_dir`` from the first site that answers, verified.

    The digest: the versions.json pin for the site, else what the site's checksums publish, else the
    release API's (``fetch_verified``), else the refusal or the unverified hatch. A mismatch raises at once.
    """
    attempts: list[str] = []
    for site in sites(lifecycle, version):
        asset = site.asset(key, version)
        if not asset:
            continue
        url = download_url(site.repo, site.tag, asset, endpoints=lifecycle.ctx.catalog.kit.endpoints)
        digest = _pinned(lifecycle, site, version, pin_key) or _published(lifecycle, site, asset)
        try:
            path = lifecycle.fetch_verified(url, dest_dir / asset, digest=digest, what=what, repo=site.repo, tag=site.tag, asset=asset)
        except ChecksumMismatch:
            raise
        except Failed as err:
            attempts.append(f"{site.label}: {err.message}")
            lifecycle.ctx.log.line("WARN", f"{what}: {site.label} did not answer - {err.message}")
            continue
        lifecycle.ctx.log.line("INFO", f"{what}: {asset} from {site.label}")
        return Fetched(path, site, asset)
    if not attempts:
        raise Failed(f"no release publishes {what} for this platform ({lifecycle.ctx.platform.platform_key})")
    raise Failed(f"Could not download {what} from any release ({'; '.join(attempts)})",
                 hint="check the network; GITHUB_TOKEN raises the API limit")


def fetch_binary(lifecycle, version: str, key: str, dest: Path, *, what: str, pin_key: str | None = None) -> Site:
    """Download the binary under ``key`` to ``dest``: the archive member the site names, or the bare file."""
    got = fetch_asset(lifecycle, version, key, dest.parent, what=what, pin_key=pin_key)
    if got.site.member:
        extract_member(got.path, got.site.member, dest)
        got.path.unlink(missing_ok=True)
    elif got.path != dest:
        got.path.replace(dest)
    return got.site


def extract_member(archive: Path, member: str, dest: Path) -> None:
    """Copy the one archive member matching ``member`` (a glob over its path in a tar or zip) to ``dest``."""
    name = archive.name.lower()
    if name.endswith((".tar.gz", ".tgz", ".tar", ".tar.xz", ".tar.bz2")):
        with tarfile.open(archive) as tar:
            hits = [m for m in tar.getmembers() if m.isfile() and fnmatch(m.name, member)]
            if not hits:
                raise Failed(f"{archive.name} holds no file matching {member}")
            with tar.extractfile(hits[0]) as src, dest.open("wb") as out:     # type: ignore[union-attr]
                shutil.copyfileobj(src, out)
        return
    if name.endswith(".zip"):
        with zipfile.ZipFile(archive) as bundle:
            hits = [n for n in bundle.namelist() if not n.endswith("/") and fnmatch(n, member)]
            if not hits:
                raise Failed(f"{archive.name} holds no file matching {member}")
            with bundle.open(hits[0]) as src, dest.open("wb") as out:
                shutil.copyfileobj(src, out)
        return
    archive.replace(dest)
