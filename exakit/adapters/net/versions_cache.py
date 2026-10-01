"""Where the advertised versions come from: fetch -> cache -> the kit's own copy -> nothing.

The chain never fails a command. A failed fetch keeps a good cached copy; a
cached copy that is provably older than the running kit is refused (it once
downgraded a Windows install); the TTL keeps commands offline between
refreshes; a recent failed attempt counts as answered so a machine without
network is not asked on every command.
"""

from __future__ import annotations

import os
import time
from collections.abc import Mapping
from pathlib import Path
from typing import Protocol

from exakit.domain.versions import VersionsDoc, VersionsInvalid, VersionsSchemaAhead, cache_outranks_baked

from ..fs.atomic import atomic_write_text
from ..fs.log import Log
from .http import Downloader



class VersionsSource(Protocol):
    def current(self) -> VersionsDoc | None: ...
    def refresh(self, *, force: bool = False) -> str: ...
    def source_label(self) -> str: ...
    def schema_ahead(self) -> bool: ...


class CachedVersionsSource:
    """The real chain. ``current()`` memoises the chosen document for the life of the command."""

    def __init__(
        self,
        *,
        cache_path: Path,
        baked_path: Path | None,
        url: str,
        ttl_seconds: int,
        downloader: Downloader,
        log: Log,
        clock=time.time,
        retry_seconds: int,
    ) -> None:
        self.cache_path = cache_path
        self.baked_path = baked_path
        self.url = url
        self.ttl_seconds = ttl_seconds
        self.retry_seconds = retry_seconds
        self.downloader = downloader
        self.log = log
        self.clock = clock
        self._doc: VersionsDoc | None = None
        self._label: str | None = None
        self._schema_ahead = False

    @classmethod
    def from_env(cls, env: Mapping[str, str], *, kit_repo: str, cache_path: Path, baked_path: Path | None,
                 downloader: Downloader, log: Log, url_template: str, ttl_default: int, retry_default: int) -> CachedVersionsSource:
        """EXAKIT_VERSIONS_URL, EXAKIT_VERSIONS_TTL and EXAKIT_VERSIONS_RETRY win; the kit's settings are the defaults."""
        url = env.get("EXAKIT_VERSIONS_URL") or url_template.format(repo=kit_repo)
        ttl_text = env.get("EXAKIT_VERSIONS_TTL", "")
        ttl = int(ttl_text) if ttl_text.isdigit() else ttl_default
        retry_text = env.get("EXAKIT_VERSIONS_RETRY", "")
        retry = int(retry_text) if retry_text.isdigit() else retry_default
        return cls(cache_path=cache_path, baked_path=baked_path, url=url, ttl_seconds=ttl,
                   downloader=downloader, log=log, retry_seconds=retry)

    # --- reading ----------------------------------------------------------------

    def _read(self, path: Path | None, label: str) -> VersionsDoc | None:
        if path is None or not path.is_file():
            return None
        try:
            return VersionsDoc.parse(path.read_text(encoding="utf-8"))
        except VersionsSchemaAhead as err:
            self._schema_ahead = True
            self.log.line("WARN", f"versions manifest {label} rejected: {err}")
        except (VersionsInvalid, OSError) as err:
            self.log.line("WARN", f"versions manifest {label} rejected: {err}")
        return None

    def current(self) -> VersionsDoc | None:
        """The manifest in use, after a refresh."""
        if self._label is not None:
            return self._doc
        baked = self._read(self.baked_path, "baked")
        cached = self._read(self.cache_path, "cache")
        if cached is not None and cache_outranks_baked(cached, baked):
            self._doc, self._label = cached, "cache"
        elif baked is not None:
            self._doc, self._label = baked, "baked"
        else:
            self._doc, self._label = None, "fallback"
        return self._doc

    def source_label(self) -> str:
        """fetched | cache | baked | fallback: where the answers came from."""
        if self._label is None:
            self.current()
        return self._label or "fallback"

    def schema_ahead(self) -> bool:
        """True when the fetched manifest needs a newer kit."""
        return self._schema_ahead

    # --- refreshing ---------------------------------------------------------------

    @property
    def _attempt_stamp(self) -> Path:
        return self.cache_path.with_name(self.cache_path.name + ".attempt")

    def _stamp(self, path: Path) -> None:
        """Mark a file as written NOW by the kit's clock, so freshness and the clock agree."""
        path.touch()
        now = self.clock()
        os.utime(path, (now, now))

    def _fresh(self, path: Path, window: int | None = None) -> bool:
        try:
            return self.clock() - path.stat().st_mtime < (self.ttl_seconds if window is None else window)
        except OSError:
            return False

    def refresh(self, *, force: bool = False) -> str:
        """fetched | fresh | failed. GitHub first; a failure keeps the cache (then the baked copy) and is retried after retry_seconds."""
        if not self.url.startswith("https://"):
            self.log.line("WARN", "refusing to fetch the versions manifest over a non-HTTPS URL")
            return "failed"
        if not force and (self._fresh(self.cache_path) or self._fresh(self._attempt_stamp, self.retry_seconds)):
            return "fresh"
        try:
            self.cache_path.parent.mkdir(parents=True, exist_ok=True)
            self._stamp(self._attempt_stamp)
        except OSError:
            return "failed"
        try:
            text = self.downloader.text(self.url)
            doc = VersionsDoc.parse(text)
        except VersionsSchemaAhead as err:
            self._schema_ahead = True
            self.log.line("WARN", f"fetched versions manifest did not validate ({err}) - keeping the cached copy")
            return "failed"
        except (VersionsInvalid, Exception) as err:  # a download error is a Failed; keep the cache
            self.log.line("INFO", f"versions manifest fetch failed ({err}) - keeping the cached copy")
            return "failed"
        atomic_write_text(self.cache_path, text if text.endswith("\n") else text + "\n", mode=0o644)
        self._stamp(self.cache_path)
        self._doc, self._label = doc, "fetched"
        self.log.line("INFO", f"versions manifest refreshed from {self.url}")
        return "fetched"
