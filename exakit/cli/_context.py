"""Build the Context for this machine: the real adapters, wired once per command."""

from __future__ import annotations

import os
from pathlib import Path

from exakit.adapters.fs.log import FileLog, NullLog
from exakit.adapters.fs.manifest_store import FileManifestStore
from exakit.adapters.fs.paths import Paths
from exakit.adapters.net.http import UrllibDownloader
from exakit.adapters.net.versions_cache import CachedVersionsSource
from exakit.adapters.platform.detect import detect
from exakit.adapters.process.runner import SubprocessRunner
from exakit.app import Context
from exakit.domain.catalog import Catalog
from exakit.ui import make_renderer

def kit_root_for(paths: Paths) -> Path:
    """The kit copy: the installed one, else this checkout."""
    if (paths.kit / "exakit").is_dir():
        return paths.kit
    return Path(__file__).resolve().parents[2]


def build(*, json: bool, yes: bool, dry_run: bool, readonly: bool, mutating: bool) -> Context:
    """The Context for this machine: the real adapters, wired once per command."""
    env = dict(os.environ)
    paths = Paths.from_env(env, Path.home())
    root = kit_root_for(paths)
    log = FileLog(paths.logs) if mutating and paths.home.exists() else NullLog()
    warnings: list[str] = []
    catalog = Catalog.load(root, paths.personas_user, warn=warnings.append)
    ui = make_renderer(json=json, env=env, log=log, home=str(Path.home()))
    for warning in warnings:
        ui.warn(warning)
    kit_repo = env.get("EXAKIT_KIT_REPO") or env.get("EXAKIT_REPO") or catalog.kit.repository
    downloader = UrllibDownloader(user_agent=f"exakit/{_kit_version(root)}")
    versions = CachedVersionsSource.from_env(env, kit_repo=kit_repo, cache_path=paths.versions_cache, baked_path=root / "versions.json",
                                             downloader=downloader, log=log, url_template=catalog.kit.versions_url_template,
                                             ttl_default=catalog.kit.versions_ttl, retry_default=catalog.kit.versions_retry)
    return Context(
        paths=paths, platform=detect(), env=env, catalog=catalog,
        manifest_store=FileManifestStore(paths.manifest, paths.manifest_lock), versions=versions,
        runner=SubprocessRunner(), net=downloader, ui=ui, log=log,
        json=json, yes=yes, dry_run=dry_run, readonly=readonly, kit_repo_override=env.get("EXAKIT_KIT_REPO") or env.get("EXAKIT_REPO") or None,
    )


def tui_site(ctx: Context) -> Path | None:
    """The screens' site-packages (architecture A3): ready, or prepared now by uv from the pin; None keeps the console."""
    from exakit.adapters import tui_env
    from exakit.adapters.uv import UvTool, find_uv
    try:
        doc = ctx.versions.current()
        tool = doc.tool("textual") if doc else None
        if not tool:
            return None
        spec = f"{ctx.catalog.kit.ui_package}=={tool['version']}"
        venv = ctx.paths.home / ctx.catalog.kit.ui_venv_dir
        windows = ctx.platform.os == "windows"
        site = tui_env.ready(venv, spec, windows=windows)
        if site is not None:
            return site
        bin_path = find_uv(ctx.env, ctx.paths.home, ctx.runner, windows=windows)
        if not bin_path:
            ctx.log.line("INFO", "screens: uv is not available here, keeping the console")
            return None
        uv = UvTool(bin_path, ctx.runner, python_version=ctx.catalog.kit.managed_python, windows=windows)
        with ctx.ui.busy("Preparing the screens (first run only)"):
            return tui_env.ensure(venv, uv, spec, windows=windows)
    except Exception as err:    # the screens are optional; whatever stops them is one log line
        ctx.log.line("WARN", f"screens: not available ({err}); keeping the console")
        return None


def _kit_version(root: Path) -> str:
    import json as _json
    try:
        return _json.loads((root / "versions.json").read_text(encoding="utf-8"))["kit"]["version"]
    except (OSError, ValueError, KeyError, TypeError):
        return "unknown"
