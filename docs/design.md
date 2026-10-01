# Low-level design

Status: DRAFT for review. Implements [architecture.md](architecture.md), which
is approved. Requirements: [requirements.md](requirements.md). Work
breakdown: [tasks.md](tasks.md). Proof: [test-and-acceptance.md](test-and-acceptance.md).

Reading guide: section 1 is the shell that remains, 2 to 8 are the Python
package, 9 the frozen contracts, 10 the update path, 11 testing, 12 the
first work package, 13 the coding standard every file follows.

---

## 1. Bootstrap: the shell that remains

Three shell files per OS family, none of them with lifecycle logic.

### 1.1 `install.sh` (macOS, Linux, WSL) and `install.ps1` (Windows)

```
main()
  1. preflight        not root; curl + tar (or PowerShell 5.1+); supported os/arch
  2. fetch kit        tarball of main (or EXAKIT_REF / EXAKIT_LOCAL_KIT) -> $EXAKIT_HOME/kit
                      staged next to the old copy, swapped by rename, backup kept
  3. ensure python    . bootstrap/ensure-python.sh   (section 1.2)
  4. hand over        exec "$EXAKIT_PYTHON" -m exakit install  (stdin reattached to /dev/tty when possible)
```

Environment it honours: `EXAKIT_HOME`, `EXAKIT_REPO`, `EXAKIT_REF`,
`EXAKIT_LOCAL_KIT`, `EXAKIT_DRY_RUN`, `EXAKIT_PREFLIGHT`, `GITHUB_TOKEN`.
Every other `EXAKIT_*` variable passes through untouched to Python.
`EXAKIT_DRY_RUN=1` stops after step 3 with the plan printed by
`python -m exakit install --dry-run`; `EXAKIT_PREFLIGHT=1` runs
`python -m exakit preflight` after step 3.

Exit codes: 1 preflight failure, 2 bad env value, 0 otherwise (the Python
exit code is propagated by `exec`).

### 1.2 `bootstrap/ensure-python.sh` and `ensure-python.ps1`

The only place that knows how a Python gets onto the machine.

```
ensure_python()
  if EXAKIT_PYTHON set and runs `-c "import sys; sys.exit(sys.version_info < (3,11))"` -> done
  read $EXAKIT_HOME/python/interpreter   (path written by a previous run) -> verify -> done
  if EXAKIT_READONLY_QUERY=1            -> exit 3 (never download from a read-only query)
  uv := $EXAKIT_UV_BIN | `uv` on PATH | $EXAKIT_HOME/tools/uv/uv
  if no uv:
      version, sha256 := versions.json  tools.uv.version, tools.uv.sha256.<platform-key>
      download https://github.com/astral-sh/uv/releases/download/<version>/uv-<triple>.(tar.gz|zip)
      verify sha256 (refuse on mismatch unless EXAKIT_ALLOW_UNVERIFIED_UV=1)
      unpack into $EXAKIT_HOME/tools/uv/
  UV_PYTHON_INSTALL_DIR=$EXAKIT_HOME/python  uv python install 3.12   (idempotent, uv verifies its own downloads)
  interpreter := uv python find 3.12
  write $EXAKIT_HOME/python/interpreter
  export EXAKIT_PYTHON=<interpreter>
```

Why a pinned uv release archive and not `curl astral.sh/uv/install.sh | sh`:
the archive has a digest we control in `versions.json`; the installer script
does not. Why never the system Python: the macOS Xcode stub and the Windows
Store stub both exist, are executable, and fail (documented in today's
`common.sh`).

`versions.json` gains one additive block, validated like every component:

```json
"tools": {
  "uv": {
    "version": "0.8.4",
    "sha256": {
      "linux-aarch64": "...", "linux-x86_64": "...",
      "macos-aarch64": "...", "macos-x86_64": "...",
      "windows-x86_64": "..."
    }
  }
}
```

### 1.3 `bootstrap/exakit` (the launcher on PATH) and `bootstrap/exakit.cmd` + `exakit.ps1`

```sh
#!/bin/sh
# exakit - launcher. Finds the kit's Python and runs the kit. Nothing else.
EXAKIT_HOME="${EXAKIT_HOME:-$HOME/.exasol-starter-kit}"
KIT="$EXAKIT_HOME/kit"
[ -d "$KIT/exakit" ] || { echo "exakit: no kit at $KIT (run the installer)" >&2; exit 4; }
case " $* " in *" --json "*|*" -j "*) EXAKIT_REFUSAL_JSON=1; export EXAKIT_REFUSAL_JSON ;; esac
. "$KIT/bootstrap/ensure-python.sh"      # defines ensure_python; honours EXAKIT_READONLY_QUERY
ensure_python || exit $?
PYTHONPATH="$KIT${PYTHONPATH:+:$PYTHONPATH}" exec "$EXAKIT_PYTHON" -m exakit "$@"
```

Windows: `exakit.cmd` is today's shim (`powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\...\kit\bootstrap\exakit.ps1" %*`) and `exakit.ps1` is the launcher above in PowerShell. Both launchers are under 40 lines and have no branches other than "is Python here".

Read-only commands (`status info version help catalog whats-new skills marketplace --list persona list|show|plan`) set `EXAKIT_READONLY_QUERY=1` inside Python before touching adapters; the launcher only refuses to *download* a Python for them when none exists, answering the documented `{"installed": true, "status": "unknown", "remedy": "exakit update"}` shape with exit 3.

---

## 2. Package `exakit/`: module map and public API

Python 3.11+, standard library only, `from __future__ import annotations`,
dataclasses, `typing.Protocol` for every adapter. Style is the existing
`mcp/` package's. No module over 400 lines; no function over 40.

```
exakit/
  __init__.py            __version__ read from kit versions.json at import
  __main__.py            sys.exit(cli.main())
  cli/
    main.py              main(argv) -> int; HANDLERS (every command); exit codes
    _common.py           add_json_flag(), add_yes_flag(), render_or_json(result, ctx)
    status.py info.py version.py help.py catalog.py whats_new.py
    persona.py marketplace.py skills.py mcp.py data.py sql.py logs.py
    install.py update.py runtime.py (start/stop/repair/autostart/migrate) uninstall.py
  ui/
    __init__.py          Renderer Protocol; make_renderer(mode) -> Renderer
    console.py           one renderer, two palettes: plain (no tty, NO_COLOR, EXAKIT_NO_FANCY) and fancy (colour, glyphs, the spinner, arrow-key menus)
    spinner.py           the live line: a spinner with a detail and the time so far; plain-mode milestones
    keys.py              the key reader behind the arrow-key menus (termios on POSIX, msvcrt on Windows)
    silent.py            used under --json: everything goes to the log, nothing to stdout
    widgets.py           shared: wrap(), visible_len(), the wordmark, Option, the progress bar
    tui/                 the Textual screens (6.1): __init__ (wanted/load/run), app.py, renderer.py, screens.py, app.tcss
  app/
    __init__.py          Context dataclass; UseCase Protocol (plan/apply)
    status.py info.py version.py help.py
    persona.py marketplace.py skills.py mcp.py mcp_readonly.py data.py data_files.py data_folder.py sql.py logs.py
    install.py install_steps.py deploy.py requirements.py update.py uninstall.py repair.py
    legacy_db.py legacy_crossing.py migrate.py                 the old-kit container database crossing (D24)
    status.py info.py runtime.py                                status, info, start, stop, autostart
    services.py          the database plus each installed service add-on: status/start/stop/autostart
    runtime_ops.py       credentials, exapump and the personal runtime as the use cases reach them; ensure_running()
    notice.py            the once-a-day pending-update notice
    machine.py           MachineState probe: what is on THIS machine (datasets, clients, add-ons, skills)
  components/
    __init__.py          for_component(ctx, id): the kit's own parts, one lifecycle each (D22)
    base.py              ComponentBase: record, advertised version, verified downloads, runtime facts
    exapump.py mcp_server.py pyexasol.py personal.py kit.py skill_set.py
  lifecycles/
    __init__.py          Lifecycle Protocol; for_addon(ctx, addon) picks exakit.addons.<id_> or the generic kind
    base.py              LifecycleBase: manifest block, versions, verified downloads, launchers, ServiceHooks
    python_venv.py binary.py host_extension.py             the three generic kinds
  addons/
    dash_server.py dbt_exasol.py json_tables.py exasol_scheduler.py   one Lifecycle subclass per add-on with bespoke steps (D16)
  domain/
    errors.py            ExakitError hierarchy with exit codes (the only place codes are defined)
    result.py            Result, Refusal
    plan.py              Step, StepState, Plan
    manifest.py          Manifest (pure dict ops + schema + migrations)
    versions.py          VersionsDoc, VersionPolicy, resolve(), compare()
    catalog.py           Component, Addon, Persona dataclasses + validate_*() + Catalog
    persona.py           answers_for(persona, env) -> Answers; plan_for(persona, machine) -> Plan
    platform.py          Platform(os, arch, wsl) + platform_key()
    ids.py               canonical client ids, dataset ids helpers, is_token()
  adapters/
    fs/       paths.py (Paths), atomic.py (atomic_write), lock.py (FileLock), manifest_store.py, log.py
    process/  runner.py (Runner Protocol + SubprocessRunner), services.py (Services Protocol + launchd/systemd/taskscheduler)
    platform/ base.py (PlatformAdapter Protocol), macos.py, linux.py, wsl.py, windows.py, detect.py
    net/      http.py (Downloader), digest.py (sha256), github.py, pypi.py, versions_cache.py
    runtime/  personal.py (PersonalRuntime Protocol + impl over the `exasol` launcher), podman.py
    clients/  (today's mcp/adapters, moved: base.py, registry.py, one file per client)
    exapump.py           the exapump CLI wrapper (profiles, sql, upload)
  lifecycles/
    __init__.py          Lifecycle Protocol; for_addon(addon) -> Lifecycle
    python_venv.py       uv venv + uv pip install <package>==<version>; console script launcher
    binary.py            release asset -> verify digest -> place under $EXAKIT_HOME/tools/<id>/ -> launcher in bin dir
    host_extension.py    e.g. VS Code: `code --install-extension` from a verified .vsix
```

### 2.1 Public signatures (the ones other modules call)

```python
# domain/errors.py
class ExakitError(Exception):
    code: int = 1                      # Failed
    def __init__(self, message: str, *, remedy: str | None = None, hint: str | None = None): ...
class BadInput(ExakitError):      code = 2
class NotRunning(ExakitError):    code = 3
class NotInstalled(ExakitError):  code = 4
class NotConfirmed(ExakitError):  code = 5
EXIT_OK = 0

# domain/result.py
@dataclass(slots=True)
class Result:
    installed: bool
    status: str
    remedy: str | None = None
    remedy_hint: str | None = None
    data: dict[str, Any] = field(default_factory=dict)   # command-specific keys, merged flat into JSON
    exit_code: int = 0
    def to_json(self) -> str: ...                        # one line, keys: installed, status, remedy, [remedy_hint], **data

# domain/plan.py
class StepState(str, Enum): DONE = "done"; PENDING = "pending"; SKIPPED = "skipped"; FAILED = "failed"
@dataclass(slots=True)
class Step:
    section: str          # datasets | mcp_clients | addons | skills | components | files | services ...
    id: str
    state: StepState
    reason: str = ""      # why skipped/failed
    run: Callable[[], None] | None = None   # set by app for pending steps; None in plan-only mode
    remedy: str | None = None               # the one command that retries this step
@dataclass(slots=True)
class Plan:
    title: str
    steps: list[Step]
    def pending(self, section: str | None = None) -> list[Step]: ...
    def by_section(self) -> dict[str, list[Step]]: ...
    @property
    def complete(self) -> bool: ...

# domain/manifest.py
SCHEMA_VERSION = 2
class Manifest:
    def __init__(self, doc: dict[str, Any]): ...
    @classmethod
    def new(cls, *, platform: Platform, kit_version: str, kit_source: str) -> "Manifest": ...
    def get(self, path: str, default: Any = None) -> Any: ...      # "components.mcp_server.version"
    def set(self, path: str, value: Any) -> None: ...
    def delete(self, path: str) -> None: ...
    def migrate(self) -> list[str]: ...                            # 1 -> 2: adds schema_version, persona:{}, kit.python; returns notes
    @property
    def doc(self) -> dict[str, Any]: ...

# domain/versions.py
class VersionPolicy(str, Enum): MANIFEST = "manifest"; LATEST = "latest"; PINNED = "pinned"
@dataclass(frozen=True)
class VersionsDoc:
    raw: dict[str, Any]
    @classmethod
    def parse(cls, text: str) -> "VersionsDoc": ...               # raises BadInput on schema/charset violations
    def kit_version(self) -> str: ...
    def component(self, id: str) -> dict[str, Any] | None: ...
    def sha256(self, id: str, platform_key: str) -> str | None: ...
    def tool(self, id: str) -> dict[str, Any] | None: ...
def resolve(component_id: str, *, policy: VersionPolicy, env_pin: str | None,
            doc: VersionsDoc | None, fallback: str, latest: Callable[[], str | None]) -> tuple[str, str]:
    """-> (version, source) where source in {env, manifest, latest, fallback}"""
def compare(a: str, b: str) -> int: ...                             # PEP-440-ish loose compare, never raises

# domain/catalog.py
@dataclass(frozen=True) class Component: id; title; kind; package|repo; severity; min_kit_version; ...
@dataclass(frozen=True) class Addon:     id; title; kind; source; platforms; requires; provides; service; skill; help; ...
@dataclass(frozen=True) class Persona:   id; title; summary; datasets; mcp_clients; addons; skills; source
def validate_component(doc) -> list[str]; validate_addon(doc) -> list[str]; validate_persona(doc, *, known_datasets, known_addons, known_clients) -> list[str]
class Catalog:
    def __init__(self, components: dict[str, Component], addons: dict[str, Addon], personas: dict[str, Persona]): ...
    @classmethod
    def load(cls, kit_root: Path, user_root: Path | None, *, warn: Callable[[str], None]) -> "Catalog": ...
    def component(self, id) -> Component; def addon(self, id) -> Addon; def persona(self, id) -> Persona   # raise BadInput with known ids
    def persona_ids(self) -> list[str]; def addon_ids(self) -> list[str]

# domain/persona.py
@dataclass(frozen=True)
class Answers:
    datasets: list[str] | None          # None = "no sample data" (EXAKIT_LOAD_SAMPLE=0)
    mcp_clients: str                    # "all" | "skip" | csv of ids
    addons: list[str]                   # already filtered by the caller against MachineState
def answers_for(persona: Persona, env: Mapping[str, str], *, all_datasets: list[str]) -> Answers: ...   # explicit env wins per variable
def plan_for(persona: Persona, machine: "MachineState") -> Plan: ...   # pure: done/pending/skipped+reason

# app/__init__.py
@dataclass
class Context:
    paths: Paths; platform: Platform; env: Mapping[str, str]
    catalog: Catalog; manifest: ManifestStore; versions: VersionsSource
    runner: Runner; net: Downloader; runtime: PersonalRuntime; services: Services; clients: ClientRegistry
    ui: Renderer; log: Log
    json: bool; yes: bool; dry_run: bool; readonly: bool
class UseCase(Protocol):
    def plan(self, ctx: Context, **args) -> Plan: ...
    def apply(self, ctx: Context, plan: Plan) -> Result: ...
def run_plan(ctx: Context, plan: Plan, *, confirm_question: str) -> Result:
    """The one apply loop: show plan -> confirm (or --yes / NotConfirmed) -> run steps in order,
    each in try/except, mark FAILED with reason+remedy, continue -> verify -> Result(applied|partial)."""

# app/machine.py
@dataclass(frozen=True)
class MachineState:
    loaded_datasets: set[str]; all_datasets: list[str]
    client_states: dict[str, str]        # id -> connected | pending | missing
    addon_states: dict[str, tuple[str, str]]  # id -> (installed|available|system|unavailable|missing-module, reason)
    skills_current: bool
def probe(ctx: Context, *, need: set[str]) -> MachineState: ...   # only probes the sections asked for

# lifecycles/__init__.py
class Lifecycle(Protocol):
    def applicable(self, ctx: Context, addon: Addon) -> tuple[bool, str]: ...
    def system_present(self, ctx, addon) -> bool: ...
    def installed_version(self, ctx, addon) -> str | None: ...
    def install(self, ctx, addon, version: str) -> None: ...
    def validate(self, ctx, addon) -> None: ...
    def update(self, ctx, addon, version: str) -> None: ...
    def uninstall(self, ctx, addon, *, dry_run: bool) -> list[str]: ...   # paths it would/did remove
    def service(self, ctx, addon) -> ServiceHooks | None: ...             # status/start/stop/urls/log_path, or None
def for_addon(addon: Addon, kit_root: Path) -> Lifecycle:
    """kind -> built-in lifecycle; catalog/addons/<id>/lifecycle.py (class Lifecycle) overrides when present."""
```

---

## 3. Data schemas

All JSON is canonical (`json.tool`, indent 2, one key per line, LF, ASCII).
Each schema has a `schema_version`. Validators return a list of problems;
an empty list is valid. Shipped files that fail validation fail CI.

### 3.1 `catalog/components/<id>.json`

```json
{
  "schema_version": 1,
  "id": "exapump",
  "title": "exapump",
  "kind": "binary",                          // binary | python-tool | runtime | skills | helper
  "source": {"type": "github_release", "repo": "exasol-labs/exapump", "asset": "exapump-{os}-{arch}{ext}"},
  "install_order": 30,
  "step_id": "exapump",                      // the steps_completed key (unchanged)
  "fallback_version": "0.13.0",              // today's *_FALLBACK constants move here
  "requires": ["runtime"],
  "help": "exapump"                          // help/<id>.json
}
```

The five core components today (personal, exapump, mcp, pyexasol, skills)
plus `exakit` (the helper) become six files. `versions.json` keeps
carrying the advertised version, severity, note, min_kit_version and
digests; the catalog carries what does not change per release.

### 3.2 `catalog/addons/<id>/addon.json`

```json
{
  "schema_version": 1,
  "id": "dash-server",
  "title": "dash-server (AI dashboard host)",
  "kind": "python-venv",                     // python-venv | binary | host-extension | custom
  "source": {"type": "github_tag", "repo": "exasol-labs/dash-server"},
  "platforms": ["macos-aarch64", "macos-x86_64", "linux-aarch64", "linux-x86_64", "windows-x86_64"],
  "requires": ["runtime", "mcp"],            // component/add-on ids that must be present
  "provides": ["dashboarding"],              // capabilities (persona schema 2 will select on these)
  "service": {"port": 8050, "autostart": true, "url": "http://127.0.0.1:{port}"},
  "launcher": "dash-server",                 // name placed in the bin dir
  "skill": "skill/",                         // optional, SKILL.md inside, addon: <id>
  "help": "dash-server",                     // help/<id>.json (repo + tagline live there today; they stay)
  "fallback_version": "0.1.1"
}
```

`kind: custom` means `lifecycle.py` next to it exports `class Lifecycle`
implementing the Protocol. The generic lifecycles cover everything the five
add-ons do today except: exasol-scheduler's DB user bootstrap (custom hook
`post_install`), json-tables' Windows cargo shim (a second `binary` asset
under `source.extra`). Both are expressed as optional hooks, not full
modules: `exakit/addons/<id_>.py` may define a `Lifecycle` subclass (D16) overriding `install`, `validate`, `service`, `uninstall`,
`validate`.

### 3.3 `catalog/personas/<id>.json` (schema 1, unchanged from the approved draft)

```json
{
  "schema_version": 1,
  "id": "data-scientist",
  "title": "Data Scientist",
  "summary": "Every sample dataset, every AI client on this machine, dashboards and JSON ingestion.",
  "datasets": "all",                         // "all" | "none" | [ids]
  "mcp_clients": "all",                      // "all" | "skip" | [client ids]
  "addons": ["dash-server", "json-tables"],  // "all" | "none" | [ids]
  "skills": "all"                            // reserved
}
```

User personas: `$EXAKIT_HOME/personas/<id>.json`, same schema, shadow by id.

### 3.3a `catalog/kit.json` (schema 1): the kit's own settings

The one place a default lives. Nothing in `exakit/` carries a repository
name, a URL, a port, a threshold, a budget or a package name as a literal;
the code reads `ctx.catalog.kit` (a frozen `KitSettings`, `domain/settings.py`)
and an environment variable may override a value where the reading code
says so. `tests/unit/domain/test_settings.py` holds the file valid and holds
the literals out of the package.

```jsonc
{
  "schema_version": 1, "id": "kit", "title": "...",
  "repository": "owner/name",                       // the kit updates from here; EXAKIT_KIT_REPO overrides
  "install":  { "sh_url": "https://...", "ps1_url": "https://..." },        // the remedies quote these; EXAKIT_INSTALL_URL overrides
  "versions": { "url_template": "https://.../{repo}/main/versions.json", "ttl_seconds": 86400, "retry_seconds": 3600 },
  "about":    { "url": "https://api.github.com/repos", "ttl_seconds": 86400, "retry_seconds": 3600, "max_len": 200 },
  "endpoints": { "github_api": "...", "github_web": "...", "release_asset": "{github_web}/{repo}/releases/download/{tag}/{name}",
                 "release_by_tag": "...", "latest_release": "...", "archive_tag": "...", "archive_branch": "...", "archive_ref": "...",
                 "pypi_json": "https://pypi.org/pypi/{package}/json" },
  "python":   { "managed_version": "3.12" },        // what the bootstrap installs; release_check holds bootstrap/ to it
  "requirements": { "min_ram_gb": 8, "min_disk_gb": 20, "comfort_ram_gb": 12, "comfort_disk_gb": 40 },
  "runtime":  { "db_port": 8563, "probe_timeout_seconds": 10, "ready_timeout_seconds": 150, "rebuild_timeout_seconds": 900,
                "reap_min_age_seconds": 180, "container_probe_timeout_seconds": 20, "container_action_timeout_seconds": 120 },
  "mcp":      { "readonly_user": "mcp_readonly", "readonly_schemas": "STARTER_KIT" },
  "data":     { "schema": "STARTER_KIT" },
  "exapump":  { "glibc_shim_image": "ubuntu:24.04" },   // where the binary runs when the host glibc is older than 2.38
  "notice":   { "interval_seconds": 86400 }
}
```

The component and add-on `source` blocks (3.1, 3.2) carry what each
download needs: `tag` (a template over `{version}`), `asset` (a template
over `{version}`, `{platform}`, `{exe}`) or `assets` (one name per platform
key), `digest_keys` (the platform's key in `versions.json`), `sha256` (pins
for versions the manifest no longer lists), `checksums` (the release's
checksum file), `sources` (the archive ref of the upstream sources). An
add-on's `config` block holds its own knobs (dbt's profile and schema, the
scheduler's service user and schema); the service port is `service.port`.

An add-on installed from GitHub releases names its **release sites** in
`source.releases`, in the order they are tried (D36): the add-on's own
repository first, the kit's mirror after it. Each site is an object:

```json
{"repo": "exasol-labs/exasol-scheduler",          // or "mirror": "kit" (the kit repository, kit.source, EXAKIT_<ID>_MIRROR_REPO)
 "tag": "{version}",                               // a template over {version} and {bare} (the version without its v)
 "assets": {"macos-aarch64": "exasol_scheduler-{version}-macos-arm64.tar.gz", "...": "..."},   // per platform key; "wheel" for a wheel
 "checksums": "sidecar",                           // "<asset>.sha256" beside the asset, or a checksums file name, or absent (the release API)
 "member": "*/exasol_scheduler",                   // the archive member that is the binary; absent for a bare file
 "pins": "sha256"}                                 // the versions.json map that pins this site's digests
```

`exakit/lifecycles/releases.py` reads them: `sites()`, `has_asset()`,
`asset_for()`, `fetch_asset()` (the first site that answers, verified),
`fetch_binary()` (plus the member extraction). The digest for a site: its
`pins` in `versions.json` when the manifest names this version, else what
its `checksums` publish, else the release API's (cached), else the refusal
or the `EXAKIT_ALLOW_UNVERIFIED_<ID>=1` hatch. A download that cannot
complete hands over to the next site; a checksum mismatch never does.

The `ui` block names the screens' toolkit: `{"package": "textual", "venv_dir": "ui-venv"}`
(the package uv installs, pinned by `tools.textual.version` in `versions.json`, and
the folder under the kit home it lives in). Section 6.1.

### 3.4 `manifest.json` schema 2 (additive)

```
schema_version: 2                      NEW (absent = 1; migrate() adds it and the two blocks below)
kit.python: <interpreter path>         NEW
persona: {id, source: install|apply, requested_at, applied_at, skipped}   NEW, absent when none
everything else                        exactly today's keys (section 2 map in the codebase audit)
```

Migration 1 to 2 runs on first write by the Python kit, never on a read-only
query, and is logged as one line.

### 3.5 `versions.json`

Schema stays 1. Additive: `tools.uv` (section 1.2), `tools.textual`
(`{"version": "8.2.8"}`, the screens' toolkit of 6.1) and, per component,
nothing new. The `expected` component set in `versions.yml` stays.

---

## 4. Use cases

Every mutating use case is `plan -> confirm -> apply -> verify -> record`.
`run_plan()` in `app/__init__.py` is the only apply loop in the codebase.

| Use case | plan() builds | apply() steps (each a `Step.run`) | verify | records |
|---|---|---|---|---|
| install | components in `install_order`, filtered by `steps_completed`; then data, clients, skills, marketplace offer as sections; persona answers folded in | one step per component via its lifecycle; data via `data.load`; clients via `mcp.setup`; skills via `skills.place`; add-ons via `marketplace.install` | each lifecycle `validate()`; `runtime.status()` | `steps_completed`, `install.current_step`, soft failures, `persona.*` |
| update | `exakit`, `runtime`, core components, `skills`, installed add-ons; `version_available > current` and not ahead; heavy (runtime) gated by `--yes`/env/confirm | self-update (stage main tarball, swap, reinstall launcher, re-place skills); per-component `update()` | `validate()` | `kit.version`, `kit.source`, `components.<id>.version` |
| marketplace | selected add-ons: state from `MachineState.addon_states`; refuse unknown; skip unavailable with reason (explicit `exakit marketplace <id>` of an unavailable one is still `BadInput`, as today) | `install -> validate -> place skill -> autostart -> start` | service status | `components.<id>.*` |
| persona | `domain.persona.plan_for()` | datasets via data, clients via mcp, add-ons via marketplace, skills via skills | re-probe | `persona.*` |
| mcp | client selection (env or menu) x adapter detection | read-only user, per-client render + write with snapshot | validator | `components.mcp_server.*` |
| data | datasets/files pending | exapump loads with progress table | marker tables | `data.*` |
| skills | diff of shipped vs placed | copy, retire, allowlist | re-list | `components.skills.*` |
| runtime | start/stop/repair/autostart/migrate | `PersonalRuntime` calls, Services | `status()` | `runtime.*`, `autostart.enabled` |
| uninstall | selection (menu/env) -> files, services, configs, database | typed confirmation for everything; snapshots kept | re-probe | manifest removed or trimmed |

Read-only use cases (`status`, `info`, `version`, `help`, `catalog`,
`whats-new`, `persona list/show/plan`, `marketplace --list`, `skills`,
`logs`, `mcp-status`, `mcp-doctor` without repair) build a `Result` directly
and never write (except the versions cache refresh, which today's code also
allows).

### 4.1 `run_plan()` in full

```python
def run_plan(ctx, plan, *, confirm_question) -> Result:
    if plan.complete:
        return Result(True, "complete", data=plan_json(plan))
    if not ctx.yes:
        ctx.ui.plan(plan)
        if ctx.json or not ctx.ui.interactive:
            raise NotConfirmed("nothing changed", remedy=f"{plan.remedy_command} --yes", data=plan_json(plan))
        if not ctx.ui.confirm(confirm_question, default=True):
            raise NotConfirmed("nothing changed", remedy=f"{plan.remedy_command} --yes")
    failed: list[Step] = []
    for step in plan.pending():
        ctx.ui.step_begin(step)
        try:
            step.run(); step.state = StepState.DONE
        except ExakitError as err:
            step.state, step.reason, step.remedy = StepState.FAILED, str(err), err.remedy or step.remedy
            failed.append(step)
        ctx.ui.step_end(step)
    status = "applied" if not failed else "partial"
    remedy = failed[0].remedy if failed else None
    return Result(True, status, remedy=remedy, data=plan_json(plan), exit_code=0 if not failed else 1)
```

Under `--json`, `ctx.ui` is the `silent` renderer, so stdout carries the
one `Result` line and everything else is in the log.

---

## 5. CLI

### 5.1 Parser

```
exakit [--json|-j] [--yes|-y] [--dry-run] <command> [args]
```

Global flags are accepted before or after the command (argparse
`parents=` on every subparser), matching today's `exakit status --json`.
Each `cli/<command>.py` exposes `register(subparsers) -> None` and
`run(args, ctx) -> Result`. `cli/__init__.py`:

```python
MIGRATED_COMMANDS: frozenset[str]   # grows per phase; anything else -> cli.legacy.run()
def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    ctx = build_context(args)                       # adapters for this OS, renderer for this tty/--json
    try:
        result = COMMANDS[args.command].run(args, ctx)
        emit(result, ctx)                           # JSON line or rendered
        notice.maybe_show(ctx, args.command)        # the pending-update notice, never under --json
        return result.exit_code
    except ExakitError as err:
        emit_refusal(err, ctx)                      # {"ok": false, "error", "remedy", "rejected"} under --json; card otherwise
        return err.code
    except KeyboardInterrupt:
        return 130
```

Unknown command: `BadInput` with remedy `exakit catalog --json` (exit 2). A
bare component id (`exakit mcp`) renders that help page, as today.

### 5.2 Legacy passthrough (phases A to C only)

`cli/legacy.py` runs `bash setup/legacy-exakit <argv>` (or
`powershell -File setup/legacy-exakit.ps1`) with stdin/stdout/stderr
inherited and returns its exit code. The migrated set is the single source
of truth; `tests/contract` asserts every command is in exactly one of the two
worlds.

---

## 6. UI renderer contract

```python
class Renderer(Protocol):
    interactive: bool
    def banner(self, title: str) -> None
    def heading(self, text) / info / ok / warn / error(self, text) -> None
    def panel(self, title: str, lines: list[str]) -> None
    def rule(self) -> None
    def plan(self, plan: Plan) -> None                     # the persona/marketplace/update panel
    def step_begin(self, step: Step) / step_end(self, step: Step) -> None   # spinner or table row
    def table(self, table: Table) -> LiveTable             # begin/update/end, one live table at a time
    def select(self, title: str, options: list[Option], default: int) -> int | None
    def checkboxes(self, title: str, options: list[Option], defaults: set[int]) -> set[int]
    def confirm(self, question: str, default: bool) -> bool
    def prompt(self, question: str, default: str) -> str
```

`ansi.py` is a port of `ui.sh` (same glyphs, palette, box drawing, live
table behaviour, terminal-width capping) so screens look identical.
`plain.py` prints one line per call. `silent.py` writes to the log. Menus in
non-interactive mode return their defaults, exactly as today.

### 6.1 The Textual screens (`ui/tui/`)

The interactive flows (install, marketplace, update, uninstall, mcp-setup,
data-load, migrate, skills-install, `persona apply`) draw a full-screen
Textual app when the output is a terminal, `--json` is not set, the run is
not a dry run and `EXAKIT_TUI` is not `0`; every other run keeps the console
renderer. Textual is a third-party package, so it never enters the core
interpreter: `cli/_context.tui_site()` asks `adapters/tui_env.ensure()` for a
venv under the kit home (`ui.venv_dir` in kit.json, created by uv from the
managed Python, `textual==<tools.textual.version>` installed into it, a
marker file holding the spec so a pin change reinstalls once), and
`ui/tui.load()` adds that venv's site-packages to `sys.path` and imports
Textual. Any failure on that path (no uv, offline, an import error) is one
log line and the console renderer: the installer never depends on the
screens. The platform gate runs before the venv is created, so an
unsupported machine still writes nothing.

Threading: Textual owns the main thread (`KitApp.run()`); the command runs
in a worker thread with `ctx.ui` set to `TuiRenderer`, whose every method
hands its call to the app with `call_from_thread` (a menu awaits a modal
screen's answer on a future, so the worker blocks exactly as it does on a
console prompt). The renderer also mirrors every line into a plain
`ConsoleRenderer` over a buffer; when the app closes, `cli/main` writes that
transcript to stdout so the scrollback holds what the console mode would
have printed, and then emits the Result as always. A `Result` or an
`ExakitError` raised by the worker is carried out of the app and handled
by the same code path as the console. Ctrl-C and `q` close the app: the
process exits with 130 as it did before.

Screens: a header with the wordmark and the platform/target line; a plan
panel (one row per step with its state glyph, label and time taken); the
log pane (info, ok, warn, error, panels, the summary); a status bar with the
spinner, the current download's bar and elapsed time; modal screens for
`select` (radio list), `checkboxes` (selection list with `a`/`n`), `confirm`
and `prompt`. Keys match the console menus: Up/Down, Space, Enter, digits,
Esc. Styling lives in `app.tcss`; nothing is drawn by hand.

Tests: `tests/unit/ui/test_tui.py` runs the app headless through Textual's
`run_test` pilot (skipped where Textual is not installed; the CI test job
installs the pinned version); `tests/unit/adapters/test_tui_env.py` proves
the venv is created once, reinstalled on a pin change and skipped when uv is
absent. The checker allows `textual` and `rich` imports in `exakit/ui/tui/`
only.

---

## 7. Adapter protocols (each in its own file, each with a fake in `tests/unit/fakes/`)

| Protocol | Methods | Implementations |
|---|---|---|
| `Paths` | `home, kit, manifest, logs, credentials, cache, tools, python, bin_dir, personas_user, workflows` | one, computed from `EXAKIT_HOME`, `EXAKIT_BIN_DIR` |
| `ManifestStore` | `load() -> Manifest`, `save(m)`, `exists()`, `locked()` context | file store with `FileLock` + atomic replace |
| `Runner` | `run(cmd, *, env, cwd, timeout, capture, stdin) -> Completed(code, out, err)`, `which(name)` | `SubprocessRunner` |
| `Services` | `install(ServiceSpec)`, `remove(name)`, `status(name) -> running|stopped|absent`, `start`, `stop` | `launchd.py`, `systemd.py` (user units), `taskscheduler.py` |
| `PlatformAdapter` | `detect() -> Platform`, `bin_dir()`, `add_to_profile(path) -> str|None`, `unsigned_binary_hint(path)`, `container_engine()` | macos, linux, wsl, windows |
| `Downloader` | `fetch(url, dest, *, sha256=None, token=None) -> Path`, `text(url, *, ttl_cache=None) -> str` | urllib-based, retries, refuses http:// |
| `VersionsSource` | `current() -> VersionsDoc`, `refresh(force=False)`, `source_label()` | fetch -> cache -> kit copy -> none (today's chain) |
| `PersonalRuntime` | `launcher_version()`, `install_launcher(version)`, `deploy(opts)`, `start()`, `stop()`, `status() -> RuntimeStatus`, `credentials() -> Credentials`, `destroy()` | over the `exasol` launcher CLI |
| `ClientRegistry` | today's `AdapterRegistry` | moved as is |
| `Exapump` | `ensure_profile()`, `sql(text, *, write, json)`, `upload(...)`, `bucketfs(...)` | wrapper over the binary |
| `Log` | `line(level, msg)`, `path` | one file per run under `logs/` |

---

## 8. Lifecycles (generic add-on behaviour)

```
python_venv     uv venv $HOME_KIT/<id>-venv --python 3.12 ; uv pip install <spec>==<version>
                launcher: bin_dir/<launcher> -> venv/bin/<console_script>
binary          asset URL from source + version + platform_key ; download ; sha256 from versions.json
                (else fallback digest in addon.json, else GitHub asset digest) ; place tools/<id>/ ; launcher
host_extension  verified .vsix (or equivalent) ; `code --install-extension` ; applicable = host CLI found
```

Each records `components.<id_>.{version, path|venv, launcher, validated}`
and, when `service` is set, registers autostart through `Services` when
`autostart.enabled`.

---

## 9. Frozen contracts (golden in `tests/contract/golden/`)

Unchanged from today: every `--json` shape of `status info version
mcp-status mcp-doctor sql skills marketplace --list logs catalog help`,
the refusal object, exit codes, and every `EXAKIT_*` variable in
`AGENTS.md`. Additions, all additive:

- `status --json`: `"persona": "<id>" | null`, `"schema_version": 2`.
- `info --json`: the manifest dump gains the `persona` and `kit.python` keys.
- `exakit persona list|show|plan|apply --json`: the shapes in the approved
  persona design (list: `recorded`, `personas[]`; plan/apply: `persona`,
  `datasets[]`, `mcp_clients[]`, `addons[]`, `skills`, `pending`, `failed[]`),
  each with `installed`, `status`, `remedy`. The four section arrays are
  always present, empty when the persona or the machine gives them no step
  (a machine with no AI client still answers `"mcp_clients": []`).
- `EXAKIT_PERSONA=<id>` on the install.

---

## 10. Update path from 0.2.0

1. `versions.json` `kit.version` = `0.3.0`; `help/whats-new.json` 0.3.0 card.
2. The 0.2.0 kit's `exakit_update_self` stages the new tarball, swaps `kit/`,
   and installs `setup/exakit` to `~/.local/bin/exakit`. In the new tree,
   `setup/exakit` **is the launcher** (a copy of `bootstrap/exakit`); same on
   Windows with `setup/exakit.ps1`. So the very update that brings the tree
   also installs the launcher, with no change to the 0.2.0 code. `setup/`
   holds those two files and nothing else.
3. First `exakit` run after the update: the launcher finds no managed Python,
   runs `ensure-python`, then `python -m exakit`. `Manifest.migrate()` runs on
   the first write.
4. Read-only commands that day answer from Python once it exists; before that,
   from the documented "unknown" shape.

---

## 11. Testing

| Suite | What | How it runs |
|---|---|---|
| `tests/unit/` | domain and app with fakes; every lifecycle against a fake runner; the installer, the update loop, uninstall, repair, the crossing; persona answers/plan; manifest migration; versions resolve/compare; catalog validation of every shipped file | `python -m unittest discover -s tests/unit -t .` |
| `tests/contract/` | the `--json` shape and exit code of every command and state against the real CLI in a sandbox; the refusal object; every documented command has a handler | same runner |
| `tests/e2e/` | `install.sh` dry run; the launcher with and without a Python; the kit layout the 0.2.0 self-update relies on | same runner |
| `tests/test_sample_data_schema.py` | the sample dataset's schema, CSVs and verification SQL agree | `python tests/test_sample_data_schema.py` |
| `mcp/tests/` | the MCP subsystem's own tests | `python -m unittest discover -s mcp/tests -t .` |

CI (`versions.yml`) runs all of the above on ubuntu and macOS plus the
coding-standard sweep (no function over 40 lines, no module over 400);
`windows.yml` runs the three kit suites on a Windows runner and parses the
bootstrap under Windows PowerShell 5.1. The legacy shell suites went with
the shell tree (D27).

---

## 12. Phase A work package (the first implementation slice)

Files, in build order. Each item is a PR-sized commit with its tests.

1. `exakit/domain/{errors,result,plan,platform,ids}.py` + unit tests.
2. `exakit/domain/manifest.py` (schema 2, migrate) + `adapters/fs/*` + tests.
3. `exakit/domain/versions.py` + `adapters/net/{http,digest,versions_cache}.py` + tests (parity with `tests/versions-manifest.sh` promises 1 to 4).
4. `exakit/domain/catalog.py` + `catalog/components/*.json`, `catalog/addons/*/addon.json` (metadata only, no lifecycle yet), `catalog/personas/*.json` + validation tests.
5. `exakit/ui/{plain,silent,widgets}.py`; `ansi.py` port of ui.sh (banner, panel, table, menus).
6. `exakit/app/{status,info,version,help,machine,notice}.py`, `exakit/app/persona.py` (list/show/plan) + `cli/` for those + `cli/legacy.py` + contract goldens.
7. `bootstrap/ensure-python.{sh,ps1}`, `bootstrap/exakit{,.cmd,.ps1}`; `setup/exakit` -> launcher, `setup/legacy-exakit`; `install.sh`/`install.ps1` steps 3 and 4; `versions.json` `tools.uv`.
8. `tests/e2e` dry runs; move `tests/*.sh` to `tests/legacy/`; CI wiring.
9. Docs: `AGENTS.md`, `README.md`, quickstarts, `CHANGELOG.md`, `whats-new.json`, `CLAUDE.md` (new "adding a persona / add-on" recipes), `MARKETPLACE.md` pointer to the catalog.

Phase B follows the same shape for marketplace, skills, mcp, data,
persona apply; Phase C for install, update, runtime, uninstall; Phase D
deletes `setup/`.

---

## 13. Coding standard (checked in review; enforced by `tools/check_standard.py` and `ruff.toml` where mechanical)

- Python 3.11+, stdlib only in `exakit/`. `from __future__ import annotations`, full type hints, `@dataclass(slots=True)` for data, `Protocol` for boundaries, `Enum` for closed sets.
- One concept per module; a module is at most 400 lines; a function at most 40 lines and one level of responsibility. If a function needs a comment to separate phases, split it.
- No `subprocess`, `open`, `urllib`, `os.environ` writes outside `adapters/`. `domain/` imports nothing from `app/`, `adapters/`, `ui/`, `cli/`.
- Every user-visible string is a plain sentence, ASCII, and names the one command that fixes the problem. Remedies are runnable commands or `None`, never prose.
- Errors are raised, not returned; only `run_plan()` and `cli.main()` catch them.
- Every public function has a one-paragraph docstring saying what it guarantees, not how it works. Comments explain a decision, not a line.
- Tests: one behaviour per test, named `test_<condition>_<expectation>`; fakes over mocks; no network, no real machine state, no sleeps.
- Naming: ids are kebab-case in data and CLI (`dash-server`), snake_case in manifest keys (`dash_server`), `PascalCase` classes, `snake_case` functions. The mapping lives in `domain/ids.py` and nowhere else.
- Nothing platform-specific outside `adapters/platform/`, `adapters/process/services.py`, `bootstrap/`.

---

## 14. Decisions taken while building Phases A and B

| # | Decision | Why |
|---|---|---|
| D8 | `status` and `info` stay on the legacy CLI in Phase A; Python owns `help`, `catalog`, `whats-new`, `version`, `persona`. | Their answers need the database probe (launcher state, port, a SELECT) that belongs to the runtime adapter (C1). Porting half of it would have produced a second, different answer. |
| D9 | The legacy suites stay at `tests/*.sh` and run against `setup/legacy-exakit*`; new suites live in `tests/unit`, `tests/contract`, `tests/e2e`. | Every legacy suite computes its root as `dirname/..`; moving forty files one level deeper changes nothing about what they prove. |
| D10 | `setup/exakit` and `setup/exakit.ps1` are byte-identical copies of the launchers in `bootstrap/`; the old CLIs are `setup/legacy-exakit*`. A contract test pins the identity. | The 0.2.0 self-update copies `setup/exakit` to the bin dir; that is how the launcher reaches an installed machine with no change to 0.2.0 code. |
| D11 | `MachineState` (the persona planner's input) is a domain dataclass; `app/machine.py` builds it. | `plan_for` must stay pure and testable with fakes; the probes are IO. |
| D12 | Help documents stay under `setup/help/` for now. | Every legacy screen and test reads them there; the move to `help/` is a Phase D rename. |
| D13 | The installed-version probes in Phase A are the manifest plus a disk check for exapump and pyexasol. | The full per-component probes are the lifecycles' `installed_version` hooks (B1) and the runtime adapter (C1). The table's shape and vocabulary are already final. |
| D14 | uv is pinned to 0.12.21 with one digest per platform in `versions.json` `tools.uv`. | Verified on this Mac: the archive digest matched and CPython 3.12.14 installed in five seconds. Bumping uv is a `versions.json` change with new digests. |
| D15 | The `mcp/` package stays where it is in Phase B; `adapters/clients` calls `mcp.cli.main` in process. | Its own tests and the legacy CLI both import it from there; moving it is a rename with no behaviour change, scheduled for Phase C. |
| D16 | Bespoke add-on steps live in `exakit/addons/<id_>.py` as a `Lifecycle` subclass of the generic kind; `lifecycles.for_addon` picks the module when it exists. | A class that overrides the steps it needs is easier to read than a hook table (`hooks.py` with named callbacks): dash-server's port settling, the scheduler's database user and json-tables' cargo shim each override two or three methods and inherit the rest. |
| D17 | The legacy add-on `.sh`/`.ps1` modules are not deleted in Phase B. | The legacy `start`, `stop`, `autostart`, `update` and `status` still dispatch to them; they go with those commands in C4. Both worlds read the same `components.<id>` manifest block, so a Python install and a legacy start agree. |
| D18 | `status`, `info`, `start`, `stop`, `autostart`, `update`, the installer and the full `uninstall` stay legacy through Phase B; `uninstall <addon>` is Python. | The single-add-on removal is the marketplace's own hook (dash-server's dry run names the dashboards it keeps); the full uninstall needs the runtime adapter (C1). `cli.commands.uninstall_command` splits on whether an id was given. |
| D19 | An add-on is "installed" when the manifest records a version AND its lifecycle still finds it on disk (venv interpreter or launcher for Python tools, engine for binaries, the editor's own listing for extensions). | The legacy rule (manifest + launcher) missed a deleted venv and, for VS Code, an extension removed inside the editor. The probe needs no uv and no network, so `marketplace --list` stays a read. |
| D20 | `install_addon_quietly` swaps the renderer for `SilentRenderer` around one install. | Loading a `.json` file needs json-tables; the file load is the story, the add-on install is a footnote that belongs in the log. |
| D21 | `status`, `info`, `start`, `stop` and `autostart` are Python from Phase C on (supersedes D8). `status --json` keeps every legacy key and adds `datasets_source`, `persona` and `schema_version`; `NotInstalled.refusal()` leads with `installed`, `status`, `remedy` so every state query keeps its exit-4 shape. | The runtime adapter (C1) now answers the probe the legacy screen ran; the read-only query never writes (no failure note, no manifest heal), which the legacy `EXAKIT_READONLY_QUERY` flag only approximated. |
| D22 | The kit's own parts (launcher, exapump, MCP server, pyexasol, the kit copy, the skill set) are `exakit/components/<id>.py` lifecycles with the same verbs as the add-on lifecycles, chosen by `components.for_component`. `app/update.py` drives them; `app/install.py` (C2) will drive the same `install` + `validate`. | The legacy tree had one `<id>_install` / `<id>_update` pair per shell module; one class per part keeps install and update from drifting (update is "force install, then validate, then record desired"). Components are not add-ons: they have no `service`, no marketplace state and their manifest keys are fixed by the 0.2.0 record. |
| D23 | The installer keeps no rollback stack. A failed step says so, keeps partial progress and names the re-run; every lifecycle's `install` is idempotent, and `begin()` re-runs a step whose artifact is gone or whose version drifted. | The legacy `push_rollback` commands undid one step's files on request; in practice the answer was always "keep partial progress, re-run", which is the only path the new installer offers. Less code, one recovery story. |
| D24 | The old-kit crossing (an Exasol container from a 0.1.x kit) is ported in full (`legacy_db`, `legacy_crossing`, `migrate`) instead of being dropped with the container runtime. | Machines that installed the first kits still exist; `status --json` documents `legacy_database`, and AGENTS.md documents `EXAKIT_LEGACY_DATA` and `exakit migrate docker-nano`. The port talks to docker/podman through one small adapter and never deletes the container. |
| D25 | `exakit install --dry-run` prints the six-step plan; `EXAKIT_DRY_RUN=1` on `install.sh` still stops before the Python hand-over (nothing is installed, not even the kit's Python). | The shell dry run is the promise agents rely on ("nothing under EXAKIT_HOME changes"); the Python dry run is for an installed kit asking what a re-run would do. |
| D26 | After Phase C the `exakit` command never runs the legacy shell CLI: `cli/legacy.py` is gone and an unknown command is a refusal. `setup/` stays on disk for one more step so the legacy suites keep proving the shell twins until the Python path has been run end to end on a real machine (M-3, M-5); D1 deletes it. | The user's rule is "existing behaviour intact through `exakit update`": the safest order is Python first, the shell tree deleted only after a real install has gone through the Python path, not before. |
| D27 | Phase D deleted `setup/lib`, the legacy CLIs, the setup scripts, `upgrade/` and every `tests/*.sh` / `*.ps1` suite in one commit, without a real install having been run through the Python path first (the user's call). The help documents moved to `help/`, the what's-new file to `help/whats-new.json`, the cargo shim source to `shim/`; Kit 2 (`upgrade-kit2`, `rollback-kit2`) was dropped rather than ported, on the user's word that it will not ship. What the legacy suites proved is now proved by `tests/unit`, `tests/contract` and `tests/e2e`, or was specific to the shell twins and has no Python counterpart to prove. | The user chose to close the migration rather than wait for the manual acceptance; the trade is recorded here and in test-and-acceptance.md (M-3 and M-5 remain the first thing to run on a scratch machine). |
| D28 | The marketplace description is the add-on's own GitHub About (`app/about.py`): fetched from `https://api.github.com/repos/<repo>` at most once per `EXAKIT_ABOUT_TTL` (a day), sanitised and capped at `EXAKIT_ABOUT_MAX_LEN` (200), cached under `cache/about/`, with the help document's `tagline` behind it and `EXAKIT_ABOUT_OFFLINE=1` to never fetch. The order is GitHub first, the cache when GitHub fails or rate-limits (a failed fetch is retried after `EXAKIT_ABOUT_RETRY`, an hour, not after the day-long TTL), the kit's own tagline when there is no cache. | The old kit did exactly this so an add-on's wording is maintained in one place, its own repository; the Python port had regressed to the tagline. |
| D29 | Every upstream lookup follows one order, proved by `tests/unit/test_fallback_order.py`: GitHub first; the cached answer when GitHub fails or rate-limits; the kit's own copy last. The versions manifest: fetched from the kit repository, then `cache/versions.json`, then the copy baked into the kit, then the catalog `fallback_version`; a failed fetch is retried after `EXAKIT_VERSIONS_RETRY` (an hour), not after the day-long TTL. A release asset's digest: the pin in `versions.json` needs no network at all; an unpinned version asks the release API, whose answer is cached under `cache/releases/` so a rate-limited re-run still verifies; with nothing to verify against the download is refused unless the `EXAKIT_ALLOW_UNVERIFIED_<ID>=1` hatch is set. | The 60-per-hour unauthenticated GitHub limit is the failure a shared or scripted machine actually hits; every path must survive it without changing what gets installed. |

| D30 | Quality gates are code in `tools/` and run on every push: the coding standard (`check_standard.py`), the lint (`ruff.toml`, SonarQube-aligned), every suite with JUnit and coverage (`run_tests.py`), the release gate (`release_check.py`), the QA report (`qa_report.py`). | A rule that is not checked mechanically drifts; the first run of the checker found six deviations from section 9 and the lint 485 findings. |
| D31 | The sandbox every CLI-level suite runs in is hermetic: a throwaway user home, a bare PATH, every `EXAKIT_*` of the caller dropped. The scenario matrix runs only read-only commands and the refusal paths of the mutating ones. | A probe that ran `start`, `data-load --force` and `skills-install` in a kit-home-only sandbox reached the launcher, the database and the skills of the machine it ran on. |
| D32 | `--json` is answered by every path, including `<command> --help` and a corrupt install record (one refusal object, exit 1, never a traceback; `EXAKIT_DEBUG=1` re-raises). | The contract is "one object on stdout"; two paths broke it. |
| D33 | The Log protocol lives in `domain/log.py`; the UI imports nothing from `adapters/`. Daemons start through `Runner.spawn`, HTTP probes through `adapters.net.http.http_status`. | The layer rule of section 9, held by the checker. The one exception, the terminal device in `ui/__init__.py`, is named in the checker. |
| D34 | Every default is data: `catalog/kit.json` for the kit (repository, installer URLs, fetch URLs and cache budgets, endpoint templates, the managed Python, the machine requirements, the runtime's port and budgets, the MCP and data defaults), the `source` and `config` blocks of the catalog for each component and add-on (tags, asset names per platform, pins, mirrors, service users). The code reads them through `ctx.catalog`; an environment variable overrides where documented. A test holds the literals out of `exakit/`. | The fallback order (GitHub, cache, ours) is only as good as the "ours" it ends in; a value that lives in a module cannot be changed by a kit update without a code change, and the same value lived in three places. |
| D36 | The kit is a bundler, not the maintainer of the add-ons: an add-on's binaries come from the add-on's own GitHub release first (`exasol-labs/exasol-scheduler`, `exasol-labs/exasol-json-tables`: the upstream archives, verified by the digests upstream publishes, the binary extracted), and the kit's mirror release answers only when that download cannot complete, or for a platform upstream does not publish (the JSON Tables linux-aarch64 engine). The sites are catalog data (`source.releases`); `versions.json` pins the mirror's digests and names the mirror release. | The mirror pinned a release tag that did not exist in this repository and digests of another build; the installs failed on a download the source repository was answering all along. The upstream release is the authority on what the add-on is; the mirror is a fallback and must never be the only path. |
| D37 | The interactive screens are Textual, in a venv of their own (architecture A3, revised): the core stays standard-library, the console renderer stays the fallback, the Textual app owns the main thread and the command runs in a worker whose renderer hands every call to the app; the transcript is printed when the app closes. | A hand-rolled full-screen UI (arrow menus, spinners, bars drawn with escape codes) is the second UI toolkit to maintain; Textual gives layout, widgets, modals and a test pilot for the price of one pinned package that the installer can live without. |
| D35 | The platforms the local database runs on are data: `platforms` on the Personal component (`catalog/components/personal.json`: Apple silicon Macs, Linux x86_64/arm64, Windows x86_64). The Python gate and `exakit preflight` read it and refuse in words before step 1; `install.sh` holds the same rule for Intel Macs because it runs before Python exists. An unsupported machine installs nothing: no download, no record, no command. | The launcher itself refuses Intel Macs (`local deployments are only supported on macOS Apple Silicon, Linux amd64/arm64, and Windows amd64`); the kit must say so first, not after installing half of itself. |

## 15. Variables the code reads that the user guide does not list

Read by `ctx.env.get`, set by tests, the CI, the installers or the kit's own
children. Documented here so the release gate (tools/release_check.py) can
hold the rule that every variable the code reads is written down somewhere.

| Variable | Meaning |
|---|---|
| `EXAKIT_ABOUT_URL` | the GitHub API base the About fetch uses (tests point it at a fake) |
| `EXAKIT_BANNER_SHOWN` | set by the installer for its children so the banner prints once |
| `EXAKIT_DEBUG` | 1 re-raises an unexpected error with its traceback instead of the one-line refusal |
| `EXAKIT_EXAPUMP_CONFIG_DIR` | where exapump's config.toml lives (default ~/.exapump); tests relocate it |
| `EXAKIT_EXAPUMP_PROFILE` | the exapump profile the kit writes and reads (default starter-kit) |
| `EXAKIT_TUI` | 0 keeps the console renderer in a terminal (no Textual screens, no venv for them); unset or 1 draws the Textual screens for the interactive flows when the output is a terminal |
| `EXAKIT_VERBOSE_BOOTSTRAP` | 1 prints the bootstrap's progress lines (uv download, the managed Python); silent otherwise, failures always shown |
| `EXAKIT_EXAPUMP_SHIM_IMAGE` | the container image the exapump glibc shim runs the binary in (default `exapump.glibc_shim_image` in kit.json, ubuntu:24.04) |
| `EXAKIT_EXASOL_SCHEDULER_MIRROR_REPO` | the repository of the scheduler's mirror site, the fallback behind the upstream release (default: the kit repository) |
| `EXAKIT_EXASOL_SCHEDULER_RELEASE_TAG` | that mirror release's tag (default: the pinned one); `EXAKIT_EXASOL_SCHEDULER_MIRROR_TAG` is the same |
| `EXAKIT_FORCE_COMPONENT_INSTALL` | 1 installs a component even when a system copy is present |
| `EXAKIT_INSTALL_URL` | the installer URL the remedies quote (default https://www.exasol.com/install/starter-kit.sh) |
| `EXAKIT_JSON_TABLES_BIN` | the exasol-json-tables launcher to use for JSON loads (default: the kit's) |
| `EXAKIT_JSON_TABLES_MIRROR_REPO` | the repository of the JSON Tables mirror site, the fallback behind the upstream release (default: the kit repository) |
| `EXAKIT_JSON_TABLES_MIRROR_TAG` | that mirror release's tag (default: the pinned one); `EXAKIT_JSON_TABLES_RELEASE_TAG` is the same |
| `EXAKIT_KIT_REPO` | the repository versions.json and the kit's own updates come from (EXAKIT_REPO is the older name) |
| `EXAKIT_KIT_SOURCE` | what kit.source records (default checkout:<path>); the installers set it to <repo>@<ref> |
| `EXAKIT_LAUNCHAGENT_DIR` | macOS: where the autostart LaunchAgent is written (default ~/Library/LaunchAgents) |
| `EXAKIT_LEGACY_EXPORT_DIR` | where a migration exports the docker-nano tables (default $EXAKIT_HOME/migration) |
| `EXAKIT_MCP_PACKAGE` | the MCP server package uvx runs (default exasol-mcp-server) |
| `EXAKIT_MCP_READONLY_USER` | the dedicated read-only database user for MCP (default MCP_READONLY) |
| `EXAKIT_ON_EXISTING` | data-load on a table that already holds foreign rows: skip, append or replace |
| `EXAKIT_PERSONAL_DEPLOY_DIR` | the Exasol Personal deployment directory (default ~/.exasol/personal/deployments/default) |
| `EXAKIT_PYEXASOL_PACKAGE` | the pyexasol package spec the venv installs (default pyexasol) |
| `EXAKIT_PYEXASOL_VENV` | the pyexasol venv (default $EXAKIT_HOME/pyexasol-venv) |
| `EXAKIT_SCHEMA` | the schema data-load targets for files (default STARTER_KIT) |
| `EXAKIT_SKILL_ROOTS` | where skills are installed, separated by the path separator (default ~/.claude/skills and ~/.agents/skills) |
| `EXAKIT_STARTUP_DIR` | Windows: the Startup folder the autostart shortcut goes to |
| `EXAKIT_SYSTEMD_USER_DIR` | Linux: where the autostart user unit is written (default ~/.config/systemd/user) |
| `EXAKIT_UNINSTALL_DB_SKIPPED` | set by uninstall for its children when the database was kept |
| `EXAKIT_UNINSTALL_FULL` | set by uninstall for its children during the EVERYTHING row |
| `EXAKIT_UPLOAD_PIECE_KB` | the piece size a large file upload is cut into, in KB |
