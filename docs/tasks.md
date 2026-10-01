# Tasks

Status legend: `[ ]` not started, `[~]` in progress, `[x]` done, `[-]` dropped (say why).
Update this file in the same commit as the work. Design sections are in
[design.md](design.md); phases in [architecture.md](architecture.md) section 7.

## Phase A: bootstrap, launcher, read-only commands, persona list/plan

### Domain
- [x] A1 `exakit/domain/{errors,result,plan,platform,ids}.py` + unit tests (design 2.1)
- [x] A2 `exakit/domain/manifest.py` schema 2 + migrate, `adapters/fs/{paths,atomic,lock,manifest_store,log}.py` + tests (design 3.4)
- [x] A3 `exakit/domain/versions.py` + `adapters/net/{http,digest,versions_cache,github,pypi}.py` + tests mirroring the four promises of `tests/versions-manifest.sh`
- [x] A4 `exakit/domain/catalog.py` + validators; `catalog/components/*.json`; `catalog/addons/*/addon.json` (metadata only); `catalog/personas/*.json` (moved from setup/personas); tests validate every shipped file (design 3.1 to 3.3)
- [x] A5 `exakit/domain/persona.py` answers_for + plan_for + tests (the 32-row acceptance matrix rows A1 to A12, A19, A20)

### UI and app
- [x] A6 `exakit/ui/{__init__,plain,silent,widgets}.py`
- [x] A7 `exakit/ui/console.py` with the legacy palettes: banner, panel, rule, spinner, numbered select, checkbox by numbers, confirm/prompt. The live progress table and the arrow-key checkbox arrive with the flows that need them (B2, B5)
- [x] A8 `exakit/app/{__init__,machine,notice}.py` with Context and run_plan (design 4.1)
- [x] A9 `exakit/app/{version,help,whats_new}.py` + `cli/` modules + contract tests against the real CLI. `status` and `info` stay on the legacy CLI until the runtime adapter (C1): their answers need the database probe (design 11, D8)
- [x] A10 `exakit/app/persona.py` list/show/plan + `cli/persona.py` + goldens (acceptance A15 to A20, A25, A26)
- [x] A11 `cli/__init__.py` main/dispatch/MIGRATED_COMMANDS + `cli/legacy.py` passthrough + contract test that every command is in exactly one world

### Bootstrap and update path
- [x] A12 `bootstrap/ensure-python.sh` + `.ps1`; `versions.json` `tools.uv` block with digests; unit test for the digest table
- [x] A13 `bootstrap/exakit`, `exakit.cmd`, `exakit.ps1` launchers; `setup/exakit` becomes the launcher and the legacy CLI moves to `setup/legacy-exakit` (same for `.ps1`) (design 10)
- [x] A14 `install.sh` / `install.ps1` steps 3 and 4; `EXAKIT_DRY_RUN` and `EXAKIT_PREFLIGHT` routed to Python
- [x] A15 `versions.json` kit 0.3.0; `setup/whats-new.json` 0.3.0 card

### Tests and CI
- [x] A16 `tests/unit`, `tests/contract`, `tests/e2e` runners. The legacy suites stay at `tests/*.sh` and `*.ps1` (their `ROOT` is `dirname/..`; moving them would touch 40 files for nothing) and now run against `setup/legacy-exakit*` (design 11, D9)
- [x] A17 `versions.yml` and `windows-ps51.yml` run the three Python suites and the legacy suites
- [x] A18 Full local run on this Mac (bash 3.2, pwsh 7, python 3.12) recorded in test-and-acceptance.md section 5 (2026-09-30, by tools/run_tests.py)

### Docs
- [x] A19 `AGENTS.md` (EXAKIT_PERSONA, `exakit persona`), `README.md`, quickstarts, `CHANGELOG.md`, `CLAUDE.md` recipes (persona, add-on, component), `MARKETPLACE.md` pointer
- [x] A20 `docs/adr/0001-0006.md` for decisions A1 to A6
- [x] A21 Work lives in `Sheetaldharshan200/exakit-v0.3.0` (private) on `main`; no AI attribution

## Phase B: marketplace, skills, mcp, data, persona apply, logs, sql

- [x] B1 `lifecycles/{__init__,base,python_venv,binary,host_extension}.py`; per-add-on modules `exakit/addons/{dash_server,dbt_exasol,json_tables,exasol_scheduler}.py` (exasol-vscode is the generic host extension); `tests/unit/lifecycles/test_addons.py` (D16)
- [x] B2 `app/marketplace.py` (list, scripted and menu answers, install loop, `install_addon_quietly`, `uninstall <addon>`), `app/services.py`; `marketplace` and add-on `uninstall` migrated (the full uninstall stays legacy, D18); `tests/unit/app/test_marketplace.py` + contract shapes. The legacy `.sh`/`.ps1` add-on modules stay until C4 retires the legacy start/stop/autostart (D17)
- [x] B3 `app/skills.py` (place, retire, allowlist, per-add-on) + `tests/unit/app/test_skills.py`
- [x] B4 `app/mcp.py` (setup, status, doctor, remove, read-only user, add-on endpoints) over `adapters/clients` calling `mcp/` in process (D15; the package move is Phase C); `app/runtime_ops.py` self-heal; `tests/unit/app/test_mcp.py`
- [x] B5 `adapters/exapump.py` + `app/{data,data_files,sql,logs}.py` (bundled datasets, files with cut-short recovery, folders with receipts, JSON through json-tables) + CLI wiring; `tests/unit/app/{test_data,test_sql_logs}.py`
- [x] B6 `app/persona.py` apply through `run_plan` (datasets via data, clients via mcp, add-ons via marketplace, skills via skills; records `persona.*`); `tests/unit/app/test_persona_apply.py` + contract; acceptance A21 to A24
- [x] B8 Every function in `exakit/` is under 40 lines and every module under 400 (`data_folder.py` and `mcp_readonly.py` split out of `data_files.py` and `mcp.py`); an ast check in the test run record proves it
- [x] B7 The legacy suites went with the shell tree in Phase D (ADR 0007); `quality.yml` runs the Python suites on every platform

## Phase C: install, update, runtime, uninstall

- [x] C1 `adapters/runtime/personal.py` (status decision tree, start/stop/wait/reap/deploy/record) + `adapters/process/services.py` (launchd, systemd user, Windows Startup) + `adapters/fs/notes.py` (failure note, install-lock holder) + fakes. `podman.py` is not needed: the container runtime is legacy-only and reaches Python solely through `migrate docker-nano` (C4)
- [x] C2 `app/install.py` + `app/install_steps.py` (six ticked steps with resume, artifact and version-drift reruns, soft failures reported once, the persona's answers folded into the environment, the closing sequence), `app/deploy.py` (the deployment decision tree: reuse, start, replace with consent, deploy fresh), `app/requirements.py` (the compatibility gate, Podman on Linux, `exakit preflight`), `adapters/platform/machine.py`; `tests/unit/app/{test_install,test_deploy_requirements_migrate}.py` + contract PhaseCCommandsTest (D23, D24)
- [x] C3 `exakit/components/{base,exapump,mcp_server,pyexasol,personal,kit,skill_set}.py` (one lifecycle per kit part: install, validate, update, uninstall) + `adapters/clients/handshake.py` + `app/update.py` (targets, ahead/current/unsupported/min-kit rules, the runtime offer with `--yes`/`EXAKIT_CONFIRM_RUNTIME_UPDATE`, kit self-update stage/swap/backup/marker, skills re-placed, what's-new card); `tests/unit/components/test_components.py`, `tests/unit/app/test_update.py` (D22). Left for C2: the exapump glibc container shim (Linux with glibc < 2.38) still comes from the legacy installer
- [x] C4a `app/status.py`, `app/info.py` (the tri-state queries, every AGENTS.md key, `datasets_source`), `app/runtime.py` (`start` with orphan reaping, `stop`, `autostart`); `tests/unit/app/test_status_info_runtime.py` + contract StateQueryPhaseCTest (D21)
- [x] C4b `app/repair.py` (consent, exit 5 when declined, the installer re-run in process with a forced fresh deployment) and `app/legacy_db.py` + `app/legacy_crossing.py` + `app/migrate.py` (the docker-nano crossing: asked once during the install, `exakit migrate docker-nano` afterwards) over `adapters/process/containers.py`
- [x] C5 `app/uninstall.py` (the safe-target rule, the legacy removal order, the menu with the typed UNINSTALL gate, `--yes`, `--dry-run`, snapshots kept); `tests/unit/app/test_uninstall_repair.py`
- [x] C6 `install.sh` / `install.ps1` hand over to `python -m exakit install`; `cli/legacy.py` deleted, the dispatcher refuses an unknown command with exit 2 and no shell CLI is ever run by `exakit` (`app/guide.py` carries `guide`). `setup/` itself stays on disk until D1, because the legacy suites under `tests/*.sh` still exercise it and a real install through the Python path (manual M-3, M-5) is the last gate before deleting it (D26)

## Phase D: delete the legacy tree

- [x] D1 `setup/lib`, the legacy CLIs, the setup scripts, `upgrade/`, `setup/load-data.sh` and every legacy `tests/*.sh` / `*.ps1` suite deleted; `setup/` holds only the two launcher copies; help documents in `help/`, the what's-new file in `help/whats-new.json`, the cargo shim source in `shim/`; Kit 2 (`upgrade-kit2`, `rollback-kit2`, `upgrade/`) removed outright - it was never going to ship; `MIGRATED_COMMANDS` removed; CI runs the Python suites on ubuntu, macOS and Windows; the bump workflows retune `fallback_version` in the catalog (D27)
- [x] D2 `CLAUDE.md`, `MARKETPLACE.md` (the add-on walkthrough is the catalog file plus a `Lifecycle` subclass), `AGENTS.md` describe only the Python kit
- [x] D3 `ui/tui/` on Textual (decision A3, revised 2026-10-01): Phase G; an `exakit ui` dashboard command stays unplanned
- [x] D4 Manual acceptance M-3 on a scratch Linux machine: `.github/workflows/real-install.yml` (run 36718941027, 2026-09-30) installed with the analyst persona, status running, tpch loaded, the agent commands, a second run skipping every step, stop/start/update/data-load, uninstall. macOS runners cannot virtualise: everything but the database proven there. M-5 (Windows 11) still manual
- [ ] D4b Manual acceptance M-5 on Windows 11 (PowerShell 5.1) and M-4 on a 0.2.0 install: real machines, not runners (the Windows runner proves everything but the database)
- [x] D5 The exapump glibc container shim is ported (`exakit/components/exapump_shim.py`, image in `catalog/kit.json`, `EXAKIT_EXAPUMP_SHIM_IMAGE` overrides); the Windows uninstall removes `$EXAKIT_HOME/python` through a detached shell a few seconds after it exits

## Phase E: quality gates (2026-09-30)

- [x] E1 `tools/check_standard.py`: the coding standard mechanically (size, complexity, layers, boundary, stdlib, shell ASCII, docstrings noted); the deviations it found were fixed (the Log protocol moved to `domain/`, daemons and HTTP probes through the adapters, `install.sh` ASCII)
- [x] E2 `ruff.toml`: the SonarQube-aligned lint; 485 findings fixed or decided (every ignore carries its reason); `sonar-project.properties`
- [x] E3 `tests/scenarios`: every command in every machine state, both output modes, the refusal paths of the mutating commands, the password never printed, the record never changed by a read; the edge cases (unknown persona, flag placement, colour, spaces in paths, corrupt record, concurrency, help in both modes)
- [x] E4 `tools/run_tests.py` (JUnit XML, tests.json, test-report.md, coverage), `tools/release_check.py` (the release gate), `tools/qa_report.py` (the QA report); `docs/release-checklist.md`
- [x] E5 `.github/workflows/quality.yml`: standard + lint + shellcheck, the suites on Linux 3.11/3.12, macOS and Windows with coverage, the release gate, the QA report as the run summary, SonarQube when the token is set (`windows-ps51.yml` and the `kit-tests` job folded in)
- [x] E6 Bugs the gates found and fixed: the installer never recorded the persona; a corrupt install record was a traceback; `update --dry-run` acted; `<command> --help --json` printed no JSON; the dry run did not validate `EXAKIT_PERSONA`; a 3.12-only f-string in `domain/catalog.py`; the two package workflows did not parse
- [x] E7 The coverage gate is 70% (72% measured): the CLI entry point and every help page are exercised in process, the glibc shim and the Windows uninstall have tests
- [ ] E8 Five commits in the pushed history carry an attribution trailer (before the rule); the release gate warns until the history is rewritten, which is the owner's call
- [x] E9 Every public function and method in `exakit/` carries a docstring (the rule counts module-level functions and methods, not closures); `tools/check_standard.py` reports 0

## Phase G: the Textual screens (2026-10-01)

- [x] G1 `catalog/kit.json` `ui` block, `versions.json` `tools.textual`, `adapters/tui_env.py` (the venv under the kit home: created once by uv, reinstalled on a pin change, absent uv or network means no screens), `cli/_context.tui_site()`
- [x] G2 `ui/tui/`: `KitApp` (header with the wordmark, the plan panel, the log pane, the status bar), the modal screens (select, checkboxes, confirm, prompt), `TuiRenderer` (every Renderer call handed to the app from the worker thread; the plain transcript mirrored for the scrollback), `app.tcss`; `cli/main` runs the interactive flows inside the app and prints the transcript when it closes
- [x] G3 `tests/unit/ui/test_tui.py` (headless, Textual's pilot; skipped without Textual), `tests/unit/adapters/test_tui_env.py`; the CI test job installs the pinned Textual; the checker allows `textual` and `rich` in `exakit/ui/tui/` only
- [x] G4 `exakit uninstall` removes the screens' venv with the kit home (it lives there); `exakit update` picks up a new pin on the next interactive run (the marker file); proven in a real terminal on 2026-10-01: the venv built by uv on the first run, the app drawn, a refusal carried out of it, Ctrl-C closing it with the terminal restored; the wordmark steps aside under 70 columns

## Phase F: every default is data (2026-09-30)

- [x] F1 `catalog/kit.json` + `exakit/domain/settings.py`: the repository, installer URLs, versions and About fetch URLs with their cache and retry budgets, endpoint templates, the managed Python, the machine requirements, the runtime port and budgets, the MCP read-only defaults, the data schema, the notice interval; validated on load, read through `ctx.catalog.kit`, environment overrides on top (D34, design 3.3a)
- [x] F2 The catalog `source` blocks carry every tag template, asset name per platform, digest key, pin, mirror and checksum file (exapump, Exasol Personal, exasol-scheduler, json-tables); `config` blocks carry dbt's profile and schema and the scheduler's service user and schema; dash-server's port is `service.port`
- [x] F3 The adapters take what they need as parameters (endpoints, timeouts, the managed Python, the runtime budgets): no adapter carries a default of its own
- [x] F4 `tests/unit/domain/test_settings.py` validates the file, every field's type, the endpoint templates, the installer command per platform, the failure on a missing file, and holds the moved literals out of `exakit/`; `tools/release_check.py` holds the shell layer's own defaults (it runs before Python) equal to the file
- [x] F5 What the Windows jobs found: install.ps1 still demanded the deleted `setup\lib\exakit-common.ps1` (every Windows install from a checkout failed); no Windows install produced an `exakit` command at all (the helper step copied the sh launcher) - now `exakit.cmd` (a shim in `bootstrap/`, byte-identical copy in `setup/`) plus `exakit.ps1` in the bin dir, on install and on self-update, removed by uninstall; the MCP ACL reader depended on how icacls echoed the path. An e2e guard holds every kit path the installers name to a file that exists
- [x] F6 Intel Macs: the local database does not run there (the launcher refuses); the kit now refuses before anything is downloaded or written, in both installers and the Python gate, from `platforms` on the Personal component (D35); the real-install workflow proves the refusal on GitHub's Intel macOS runner
- [x] F8 The add-ons download from their source repositories' releases first (D36): `source.releases` in the catalog, `exakit/lifecycles/releases.py`, the upstream digests (`.sha256` sidecars, `SHA256SUMS`, the release API), the binary extracted from the archive; the kit's mirror is the fallback and `versions.json` pins the mirror release that actually exists in this repository; `tests/unit/lifecycles/test_releases.py`
- [x] F9 Downloads report their bytes: `Downloader.fetch(progress=)`, `Renderer.progress()` (a live bar on the spinner, quarter lines in plain mode, the log under `--json`); the spinner shows the time a step has taken; a line written under a spinner clears it first; the marketplace probes run under a busy indicator
- [x] F10 The scheduler's service user: `GRANT CREATE SCHEMA` (the statement carried the literal text `self.schema`, so every scheduler install failed at the grant) and a failure names the statement that failed, never a secret one's text
- [x] F7 The MCP subsystem reads the mcp component's package and `fallback_version` from the catalog (`catalog_mcp_defaults`); `versions.yml` holds that file to the manifest, the bump and update-test workflows no longer rewrite a constant
