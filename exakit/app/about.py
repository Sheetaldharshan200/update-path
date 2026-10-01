"""An add-on's one-line description: its GitHub About, fetched at most once a day, else the help document's tagline.

The order is fixed: GitHub first (the add-on's own repository owns the
wording), the cached copy when GitHub cannot be reached or answers with the
rate limit (60 requests an hour without a token), and the kit's own
``help/<id>.json`` tagline when there is no cache either. A cached copy is
reused for ``EXAKIT_ABOUT_TTL`` seconds (a day); a failed fetch is retried
after ``EXAKIT_ABOUT_RETRY`` seconds (an hour, the rate-limit window). It is
prose the kit does not control: escape sequences and control bytes are
stripped, it is folded to one line and capped, before it is cached.
"""

from __future__ import annotations

import json
import re
import time
from pathlib import Path

from exakit.domain.catalog import Addon
from exakit.domain.errors import ExakitError

from . import Context, help as help_app
from .machine import kit_root

ESCAPES = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\]8;;[^\x07\x1b]*(?:\x07|\x1b\\)")
CONTROL = re.compile(r"[\x00-\x1f\x7f]")


def _int(ctx: Context, name: str, default: int) -> int:
    value = ctx.env.get(name, "")
    return int(value) if value.isdigit() else default


def sanitise(text: str) -> str:
    """The text without escapes, control characters and extra whitespace."""
    text = ESCAPES.sub("", text)
    text = CONTROL.sub(" ", text)
    return re.sub(r" +", " ", text).strip()


def cap(text: str, max_len: int) -> str:
    """The text cut at a word boundary within ``max_len``."""
    if max_len <= 0 or len(text) <= max_len:
        return text
    cut = text[:max_len]
    return cut.rsplit(" ", 1)[0] if " " in cut else cut


def _fresh(path: Path, ttl: int) -> bool:
    if ttl <= 0 or not path.is_file():
        return False
    return time.time() - path.stat().st_mtime < ttl


def repo_of(ctx: Context, addon: Addon) -> str | None:
    """The GitHub repository of an add-on, or None."""
    doc = help_app.load_docs(kit_root(ctx) / "help").get(addon.help or addon.id) or {}
    repo = doc.get("repo") or addon.source.get("repo")
    return str(repo) if repo else None


def fetch(ctx: Context, addon: Addon) -> str | None:
    """GitHub first, once per TTL; a failed fetch (network, rate limit) is retried after EXAKIT_ABOUT_RETRY. Returns what is on disk."""
    cache_dir = ctx.paths.about_cache
    cache, attempt = cache_dir / f"{addon.id}.txt", cache_dir / f".attempt-{addon.id}"
    ttl = _int(ctx, "EXAKIT_ABOUT_TTL", ctx.catalog.kit.about_ttl)
    url = ctx.env.get("EXAKIT_ABOUT_URL") or ctx.catalog.kit.about_url
    repo = repo_of(ctx, addon)
    if ctx.env.get("EXAKIT_ABOUT_OFFLINE") == "1" or not repo or not url.startswith("https://") or _fresh(cache, ttl) \
            or _fresh(attempt, _int(ctx, "EXAKIT_ABOUT_RETRY", ctx.catalog.kit.about_retry)):
        return _read(cache)
    cache_dir.mkdir(parents=True, exist_ok=True)
    attempt.write_text("", encoding="utf-8")
    try:
        body = ctx.net.text(f"{url}/{repo}", token=ctx.env.get("GITHUB_TOKEN"))
        text = cap(sanitise(str(json.loads(body).get("description") or "")), _int(ctx, "EXAKIT_ABOUT_MAX_LEN", ctx.catalog.kit.about_max_len))
    except ExakitError as err:
        why = "GitHub's rate limit (60 requests an hour without GITHUB_TOKEN)" if "403" in (err.hint or "") or "429" in (err.hint or "") else err.hint or "no answer"
        ctx.log.line("INFO", f"About fetch failed for {addon.id}: {why} - using the cached copy, else the kit's own tagline")
        return _read(cache)
    except (ValueError, AttributeError, OSError):
        ctx.log.line("INFO", f"About fetch for {addon.id} did not parse - keeping whatever is on disk")
        return _read(cache)
    if not text:
        ctx.log.line("INFO", f"{repo} has no About text to show for {addon.id}")
        return _read(cache)
    tmp = cache.with_suffix(".tmp")
    tmp.write_text(text + "\n", encoding="utf-8")
    tmp.replace(cache)
    ctx.log.line("INFO", f"About refreshed for {addon.id} from {repo}")
    return text


def _read(cache: Path) -> str | None:
    try:
        return cache.read_text(encoding="utf-8").splitlines()[0].strip() or None
    except (OSError, IndexError):
        return None


def description(ctx: Context, addon: Addon) -> str:
    """The live About when it can be had, the cached one, the help tagline, or the help pointer."""
    text = fetch(ctx, addon)
    if text:
        return text
    doc = help_app.load_docs(kit_root(ctx) / "help").get(addon.help or addon.id) or {}
    tagline = str(doc.get("tagline") or "").strip()
    return tagline.rstrip(".") if tagline else f"Details: exakit help {addon.id}"
