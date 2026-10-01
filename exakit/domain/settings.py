"""The kit's own settings: catalog/kit.json, the one place a default lives.

Every value the code used to carry as a constant is here: the repository the
kit updates from, the installer URLs, where the versions manifest and an
add-on's About are fetched and how long they are cached, the endpoint
templates, the managed Python, the machine requirements, the runtime's port
and budgets, the MCP defaults. An environment variable may override a value
where the reading code says so; the file is the fallback behind every one.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .errors import Failed

SCHEMA_VERSION = 1
Problems = list[str]

# (section, key, type) for every value; the loader and the validator share it.
FIELDS: tuple[tuple[str, str, type], ...] = (
    ("install", "sh_url", str), ("install", "ps1_url", str),
    ("versions", "url_template", str), ("versions", "ttl_seconds", int), ("versions", "retry_seconds", int),
    ("about", "url", str), ("about", "ttl_seconds", int), ("about", "retry_seconds", int), ("about", "max_len", int),
    ("endpoints", "github_api", str), ("endpoints", "github_web", str), ("endpoints", "release_asset", str),
    ("endpoints", "release_by_tag", str), ("endpoints", "latest_release", str), ("endpoints", "archive_tag", str),
    ("endpoints", "archive_branch", str), ("endpoints", "archive_ref", str), ("endpoints", "pypi_json", str),
    ("python", "managed_version", str),
    ("requirements", "min_ram_gb", int), ("requirements", "min_disk_gb", int),
    ("requirements", "comfort_ram_gb", int), ("requirements", "comfort_disk_gb", int),
    ("runtime", "db_port", int), ("runtime", "probe_timeout_seconds", int), ("runtime", "ready_timeout_seconds", int),
    ("runtime", "rebuild_timeout_seconds", int), ("runtime", "reap_min_age_seconds", int),
    ("runtime", "container_probe_timeout_seconds", int), ("runtime", "container_action_timeout_seconds", int),
    ("mcp", "readonly_user", str), ("mcp", "readonly_schemas", str),
    ("data", "schema", str),
    ("exapump", "glibc_shim_image", str),
    ("ui", "package", str), ("ui", "venv_dir", str),
    ("notice", "interval_seconds", int),
)


@dataclass(frozen=True, slots=True)
class Endpoints:
    """URL templates; ``format`` fills them with the kit's hosts and the caller's names."""

    github_api: str
    github_web: str
    release_asset: str
    release_by_tag: str
    latest_release: str
    archive_tag: str
    archive_branch: str
    archive_ref: str
    pypi_json: str

    def url(self, template: str, **names: str) -> str:
        """The template of that name, filled: ``url("release_asset", repo=..., tag=..., name=...)``."""
        pattern = getattr(self, template)
        return pattern.format(github_api=self.github_api, github_web=self.github_web, **names)


@dataclass(frozen=True, slots=True)
class KitSettings:
    repository: str
    install_sh_url: str
    install_ps1_url: str
    versions_url_template: str
    versions_ttl: int
    versions_retry: int
    about_url: str
    about_ttl: int
    about_retry: int
    about_max_len: int
    endpoints: Endpoints
    managed_python: str
    min_ram_gb: int
    min_disk_gb: int
    comfort_ram_gb: int
    comfort_disk_gb: int
    db_port: int
    probe_timeout: int
    ready_timeout: int
    rebuild_timeout: int
    reap_min_age: int
    container_probe_timeout: int
    container_action_timeout: int
    mcp_readonly_user: str
    mcp_readonly_schemas: str
    data_schema: str
    exapump_shim_image: str
    ui_package: str
    ui_venv_dir: str
    notice_interval: int

    @classmethod
    def from_doc(cls, doc: dict[str, Any]) -> KitSettings:
        """The settings of a validated document (``validate_settings`` first; this does not check)."""
        value = _reader(doc)
        return cls(
            repository=str(doc["repository"]),
            install_sh_url=value("install", "sh_url"), install_ps1_url=value("install", "ps1_url"),
            versions_url_template=value("versions", "url_template"), versions_ttl=value("versions", "ttl_seconds"),
            versions_retry=value("versions", "retry_seconds"),
            about_url=value("about", "url"), about_ttl=value("about", "ttl_seconds"), about_retry=value("about", "retry_seconds"),
            about_max_len=value("about", "max_len"),
            endpoints=Endpoints(**{k: value("endpoints", k) for _s, k, _t in FIELDS if _s == "endpoints"}),
            managed_python=value("python", "managed_version"),
            min_ram_gb=value("requirements", "min_ram_gb"), min_disk_gb=value("requirements", "min_disk_gb"),
            comfort_ram_gb=value("requirements", "comfort_ram_gb"), comfort_disk_gb=value("requirements", "comfort_disk_gb"),
            db_port=value("runtime", "db_port"), probe_timeout=value("runtime", "probe_timeout_seconds"),
            ready_timeout=value("runtime", "ready_timeout_seconds"), rebuild_timeout=value("runtime", "rebuild_timeout_seconds"),
            reap_min_age=value("runtime", "reap_min_age_seconds"), container_probe_timeout=value("runtime", "container_probe_timeout_seconds"),
            container_action_timeout=value("runtime", "container_action_timeout_seconds"),
            mcp_readonly_user=value("mcp", "readonly_user"), mcp_readonly_schemas=value("mcp", "readonly_schemas"),
            data_schema=value("data", "schema"),
            exapump_shim_image=value("exapump", "glibc_shim_image"),
            ui_package=value("ui", "package"), ui_venv_dir=value("ui", "venv_dir"),
            notice_interval=value("notice", "interval_seconds"),
        )

    def install_command(self, windows: bool = False) -> str:
        """The one command that (re)runs the installer on this platform, runnable as written."""
        if windows:
            return f"irm {self.install_ps1_url} | iex"
        return f"curl -fsSL {self.install_sh_url} | sh"


def _reader(doc: dict[str, Any]):
    def value(section: str, key: str):
        return doc[section][key]
    return value


def validate_settings(doc: Any) -> Problems:
    """Every field present with its type; every template names only placeholders the code fills."""
    problems: Problems = []
    if not isinstance(doc, dict):
        return ["not a JSON object"]
    if doc.get("schema_version") != SCHEMA_VERSION:
        return [f"schema_version must be {SCHEMA_VERSION}"]
    if doc.get("id") != "kit":
        problems.append("id must be 'kit'")
    repository = doc.get("repository")
    if not isinstance(repository, str) or repository.count("/") != 1 or not repository.isascii():
        problems.append("repository must be owner/name")
    for section, key, kind in FIELDS:
        block = doc.get(section)
        if not isinstance(block, dict) or key not in block:
            problems.append(f"{section}.{key} is missing")
        elif not isinstance(block[key], kind) or isinstance(block[key], bool) or (kind is str and not block[key].strip()):
            problems.append(f"{section}.{key} must be a non-empty {kind.__name__}")
        elif kind is int and block[key] < 0:
            problems.append(f"{section}.{key} must not be negative")
        elif kind is str and key.endswith("url") and not block[key].startswith("https://"):
            problems.append(f"{section}.{key} must be an https:// URL")
    return problems


def load_settings(path: Path) -> KitSettings:
    """catalog/kit.json, validated; a kit copy without it (or with a broken one) cannot run any command."""
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
        problems = validate_settings(doc)
    except (OSError, ValueError) as err:
        problems = [str(err)]
    if problems:
        raise Failed(f"The kit's settings file {path} is missing or invalid ({'; '.join(problems[:3])}): this kit copy is incomplete.",
                     remedy="exakit update", hint="a fresh copy of the kit carries catalog/kit.json")
    return KitSettings.from_doc(doc)
