# Test plan and acceptance criteria

Status: living document. Every row maps to a requirement in
[requirements.md](requirements.md) and to a check in the suites below unless
marked *manual*. Update the result column in the same commit as the change.
The release gates that wrap these suites are in
[release-checklist.md](release-checklist.md).

## 1. How the suites run

```bash
python3 tools/run_tests.py                   # every suite; reports/ gets JUnit XML, tests.json, test-report.md
python3 tools/run_tests.py --coverage        # the same with coverage.py (pip install coverage): coverage.xml for SonarQube
python3 tools/run_tests.py unit contract     # a subset
python3 tools/check_standard.py              # the coding standard, mechanically (reports/standard.json)
python3 tools/release_check.py               # the release gate (reports/release.json, release-check.md); --strict when tagging
python3 tools/qa_report.py                   # the QA report from everything above (reports/qa-report.md)
```

The suites, each provable on its own with `python3 -m unittest discover -s <dir> -t .`:

| Suite | Directory | Proves | Machine state |
|---|---|---|---|
| unit | `tests/unit` | every rule and adapter over fakes; the four upstream fallback orders (the versions manifest, About, release digests, the add-on release sites of D36); the Textual screens headless through Textual's pilot (`tests/unit/ui/test_tui.py`, skipped where Textual is not installed; the CI test job installs the pin) | none |
| contract | `tests/contract` | the frozen `--json` shapes and exit codes against the real CLI | a hermetic sandbox (`tests/support.py`: throwaway kit home and user home, bare PATH, no `EXAKIT_*` inherited) |
| scenarios | `tests/scenarios` | every command x every machine state x both output modes; the refusal paths of the mutating commands; the password never printed; a read never changes the record; the edge cases | the same sandbox, seven states (`harness.STATES`) |
| e2e | `tests/e2e` | the installer dry run, the launcher answers; the real uv + CPython bootstrap with `EXAKIT_E2E_NETWORK=1` | none (network opt-in) |
| mcp | `mcp/tests` | the MCP subsystem | none |
| sample-data | `tests/test_sample_data_schema.py` | the sample dataset's schema, CSVs and verification SQL agree | none |
| real install | `.github/workflows/real-install.yml` | M-3 on a fresh runner: install with a persona, status, the agent commands, a second run, stop/start/update/data-load, uninstall | a scratch machine |

A CLI-level test runs only read-only commands and refusal paths. The
sandbox isolates the kit home and the user home, but `start`, `data-load
--force`, `skills-install` and their kind reach the launcher, the database
and the skill folders of the machine they run on (D31).

## 2. Acceptance criteria (personas)

| Id | Given | When | Then | Req | Check |
|---|---|---|---|---|---|
| A1 | a fresh sandbox | `exakit_persona_ids` | prints `analyst data-engineer data-scientist minimal`, sorted | R15 | persona.sh: registry |
| A2 | every shipped file | validated | schema 1, id equals filename, ASCII, canonical json.tool layout, LF, title at most 40 chars, summary at most 120 | R14, R17 | persona.sh: files |
| A3 | every shipped file | ids cross-checked | every dataset is bundled, every add-on registered, every client accepted by `exakit_parse_mcp_client_selection`, `skills` is `all` | R17 | persona.sh: files |
| A4 | a user file `$EXAKIT_HOME/personas/team-x.json` | `exakit_persona_ids` | includes `team-x`, source `user` | R16 | persona.sh: user dir |
| A5 | a user file named `analyst.json` with a different title | `exakit_persona_field analyst title` | the user title wins | R16 | persona.sh: shadowing |
| A6 | a user file that is not JSON, and one with schema_version 99 | `exakit_persona_ids` | both are skipped with one warning each, the rest still listed, exit 0 | R16 | persona.sh: broken files |
| A7 | `EXAKIT_PERSONA=data-scientist`, no other env | `exakit_persona_apply_env` | exports `EXAKIT_DATASETS=tpch,energy,weather`, `EXAKIT_MCP_CLIENTS=all`, `EXAKIT_PERSONA_ACTIVE=1`; manifest has `persona.id`, `persona.source=install`, `persona.requested_at` | R1, R4 | persona.sh: expansion |
| A8 | `EXAKIT_PERSONA=data-scientist EXAKIT_DATASETS=tpch EXAKIT_MCP_CLIENTS=codex` | `exakit_persona_apply_env` | the explicit values are untouched | R2 | persona.sh: precedence |
| A9 | `EXAKIT_PERSONA=minimal` | `exakit_persona_apply_env` | `EXAKIT_LOAD_SAMPLE=0`, `EXAKIT_MCP_CLIENTS=skip`, `EXAKIT_DATASETS` unset | design 4 | persona.sh: minimal |
| A10 | `EXAKIT_PERSONA=nope` | `exakit_persona_apply_env` | dies before any step, message names the known ids, nothing recorded | R3 | persona.sh: unknown |
| A11 | `data-engineer`, no `code` CLI on PATH, json-tables engine stubbed absent | `exakit_persona_addons_answer` | prints `dbt-exasol,exasol-scheduler`; `EXAKIT_PERSONA_SKIPPED` names exasol-vscode and json-tables with their reasons; no `die` | design 3, D4 | persona.sh: add-on filter |
| A12 | `analyst`, dash-server already installed (stub `dash_server_installed_version`) | `exakit_persona_addons_answer` | prints `none` | design 3 | persona.sh: add-on filter |
| A13 | `EXAKIT_PERSONA_ACTIVE=1`, `EXAKIT_MARKETPLACE_ADDONS` unset | `exakit_marketplace_offer` (menu stubbed) | the menu sees `EXAKIT_MARKETPLACE_ADDONS` equal to the persona answer | design 3 | persona.sh: offer hook |
| A14 | `EXAKIT_PERSONA_ACTIVE` unset, `persona.id` recorded from an earlier run | `exakit_marketplace_offer` | the persona does not answer; existing behaviour | design 3 | persona.sh: offer hook |
| A15 | no manifest | `exakit persona list --json` | exit 4, one JSON object with `installed:false`, `status`, `remedy` | R12 | persona.sh: CLI |
| A16 | a sandbox manifest | `exakit persona list --json` | exit 0, `installed:true`, `status:"none"`, `recorded:null`, 4 personas each with `id`, `title`, `summary`, `source`, `recorded` | R7 | persona.sh: CLI |
| A17 | manifest with `persona.id=analyst` | `exakit persona list` | the analyst row is marked; `--json` `recorded:"analyst"` and `status:"recorded"` | R7 | persona.sh: CLI |
| A18 | `exakit persona show data-scientist --json` | | the file's fields, exit 0; `show nope` exits 2 with the refusal object under `--json` | R10, R12 | persona.sh: CLI |
| A19 | sandbox with tpch loaded, no clients connected, no add-ons, skills current | `exakit persona plan data-scientist --json` | `datasets`: tpch done, energy pending, weather pending; `mcp_clients` from the stubbed discovery; `addons` states; `skills.state:"done"`; `pending` equals the count; `remedy` is the `apply --yes` command | R9 | persona.sh: plan |
| A20 | same, everything already there | `exakit persona plan analyst --json` | `status:"complete"`, `pending:0`, `remedy:null` | R9 | persona.sh: plan |
| A21 | no terminal, no `--yes` | `exakit persona apply analyst` | prints the plan, exits 5, remedy is `exakit persona apply analyst --yes`; nothing recorded | R8, D6 | test_persona_apply: refuses_without_yes; contract PhaseBShapeTest |
| A22 | `--yes`, every downstream use case stubbed to succeed | `exakit persona apply analyst --yes --json` | `data.load` per pending dataset, `mcp.setup` per pending client with `EXAKIT_MCP_CLIENTS=<id>`, `marketplace.install_one` per available add-on (an installed one is `done`), `skills.install`; records `persona.source=apply`, `persona.applied_at`; `status:"applied"`, exit 0 | R8 | test_persona_apply: yes_runs_each_section |
| A23 | `--yes`, the add-on install fails | `exakit persona apply minimal --yes --json` | the other sections still run; `status:"partial"`, `failed[]` names the add-on, `remedy` is `exakit update <id>` (the step's own retry); exit 1 | R8 | test_persona_apply: failed_step_partial |
| A24 | `--yes`, `minimal`, everything present | `exakit persona apply minimal --yes` | no loader, no MCP setup, no marketplace call; `status:"complete"`, persona recorded; exit 0 | design 4 | test_persona_apply: complete_plan; contract PhaseBShapeTest |
| A25 | `exakit persona apply` (no id), `exakit persona bogus`, `exakit persona list --nope` | | exit 2 each; JSON refusal object when `--json` present | R12 | persona.sh: CLI |
| A26 | manifest with `persona.id` | `exakit status --json` | carries `"persona":"<id>"`; without the block, `"persona":null` | R13 | persona.sh: status |
| A27 | `help/exakit.json` | `exakit help persona`, `exakit catalog`, `exakit help --json` | all know the command; the Personas group exists | R13 | persona.sh: help |
| A28 | docs | grep | `AGENTS.md` env table has `EXAKIT_PERSONA` and names every shipped persona id; `README.md` has `exakit persona`; each `quickstarts/*.md` shows the one-line persona install; `install.sh` and `install.ps1` headers list the variable | R20 | persona.sh: docs |
| A29 | `help/whats-new.json` | tests/e2e whats-new card test | a `0.3.0` card that passes the line rules; `versions.json` `kit.version` is `0.3.0` | R18 | persona.sh + whats-new.sh |
| A30 | PowerShell files | static | every name in design 6 is defined; `persona.ps1` is ASCII; `setup-windows.ps1` calls `Set-ExakitPersonaEnvironment`; `Request-ExakitMarketplaceOffer` calls `Get-ExakitPersonaAddonsAnswer`; `Invoke-CmdStatus` emits `persona` | C6, design 6 | persona.sh: parity |
| A31 | pwsh present | live pwsh | `Get-ExakitPersonaIds` lists the same four; `Set-ExakitPersonaEnvironment data-scientist` sets the same env values as A7; unknown id throws | design 6 | persona.sh: pwsh block; persona.ps1 |
| A32 | the existing suites | run | `marketplace.sh`, `skills.sh`, `agent-operability.sh`, `agents-rosters.sh`, `whats-new.sh`, `ps-encoding-guard.sh`, `ps-undefined-functions.sh`, `ps-table-twin.sh`, `bash32-guard.sh`, `dry-run-matrix.sh`, `noninteractive-answers.sh`, `versions-manifest.sh`, `help` checks in `agent-audit.sh` still pass | C6 | section 5 |

## 3. Combination matrix

Personas x answers x platform x mode. Each cell is covered by the check named.

| Dimension | Values | Covered by |
|---|---|---|
| persona | analyst, data-scientist, data-engineer, minimal, user-defined, shadowing, unknown, broken | A1 to A10 |
| explicit env per variable | unset / set for each of DATASETS, LOAD_SAMPLE, MCP_CLIENTS, SKIP_MCP, MARKETPLACE_ADDONS | A7, A8, A13 (SKIP_MCP=1 and LOAD_SAMPLE set are asserted untouched in A8's block) |
| add-on availability | applicable+absent, applicable+installed, applicable+system-present, inapplicable, module missing | A11, A12, A19 |
| datasets state | none loaded, some loaded, all loaded | A19, A20 |
| MCP clients state | none detected, some pending, all connected, persona says skip | A19, A20, A24 |
| terminal | tty (interactive confirm), no tty with --yes, no tty without --yes | A21, A22 (manual: interactive path, section 4) |
| output | human, --json | every CLI row runs both |
| install entry | fresh install with EXAKIT_PERSONA, re-run over existing, apply on existing | A7, A13, A22 |
| platform | bash 3.2 (macOS), bash (Ubuntu), pwsh 7 (macOS/Ubuntu), Windows PowerShell 5.1 (windows-latest) | CI matrix; A30, A31 |
| kit copy age | new copy (module present), old copy without `persona.sh` (loader is a no-op, installer unchanged) | A14 plus the loader guard |

## 4. Manual acceptance (before merge, record the outcome here)

| Id | Steps | Expected | Result |
|---|---|---|---|
| M-1 | On this Mac: `EXAKIT_LOCAL_KIT=$PWD EXAKIT_DRY_RUN=1 EXAKIT_PERSONA=data-scientist sh install.sh` | plan shown, nothing installed, no error | pending |
| M-2 | `EXAKIT_LOCAL_KIT=$PWD EXAKIT_PERSONA=nope sh install.sh` | stops before step 1 naming the four ids | pending |
| M-3 | Full install on a scratch machine or VM with `EXAKIT_PERSONA=analyst` | tpch loaded, detected clients connected, dash-server installed, `exakit info --json` shows the persona block | **pass on ubuntu-latest** (real-install run 36718941027, 2026-09-30): install 69 s, status running, tpch loaded (8 tables, 173,745 rows), MCP configured for 7 clients, 9 skills, dash-server up on 5100, re-run 11 s skipping all 6 steps, stop/start/update/data-load --force, uninstall clean. The persona block was missing: the installer never recorded it; fixed the same day (`install.record_persona`). macOS Apple-silicon runner: everything but the database, asserted as such (no virtualisation in the hosted VM); Intel Mac: the refusal, asserted |
| M-4 | On a 0.2.0 install: `exakit update`, then `exakit persona list`, `exakit persona plan data-scientist`, `exakit persona apply data-scientist` interactively | update pulls 0.3.0 and shows the card; commands work; the confirm question appears once | pending |
| M-5 | Windows 11 (PowerShell 5.1): `$env:EXAKIT_PERSONA='data-engineer'; irm .../install.ps1 \| iex` | exasol-vscode skipped with the reason when VS Code is absent, the rest installed | the `install-windows` job of `real-install.yml` proves the PowerShell 5.1 path on windows-latest (installer, bootstrap, Python, persona recorded, skills, status, uninstall); the database needs WSL2, which hosted runners lack: still pending on a real Windows 11 machine |

## 5. Latest local run

Recorded on 2026-10-01 on this Mac (macOS, Python 3.12) by `tools/run_tests.py`; the full listing is `reports/test-report.md` (a snapshot is committed under `docs/reports/`).

| Suite | Result |
|---|---|
| unit (397; 7 skipped without Textual, which pass under the pinned Textual: 14 screen tests) | pass |
| contract (30) | pass |
| scenarios (284: 7 states x 43 commands, each in both modes, plus 8 edge cases) | pass |
| e2e (11, 1 network test skipped) | pass |
| mcp (118) | pass |
| sample-data (7) | pass |
| coverage of `exakit/` and `mcp/` | 72% (gate 70%, last measured 2026-09-30) |
| coding standard (`tools/check_standard.py`) | pass; 0 public functions without a docstring |
| lint (`ruff.toml`, ruff 0.14.0) | clean |
| release gate (`tools/release_check.py`) | pass with warnings: CHANGELOG still Unreleased; one pushed commit carries an attribution trailer |
| real install (`real-install.yml`: ubuntu full, macOS Apple silicon everything but the database, Windows full, Intel Mac refused) | pass |
| the Textual screens in a real terminal (`exakit marketplace` on a sandbox home, 2026-10-01) | the venv built by uv on the first run, the app drawn, the refusal carried out of it, Ctrl-C restored the terminal, exit 4 |

The legacy suites were deleted with the shell tree in Phase D (ADR 0007).
What they proved is carried by: dry-run-matrix and install-resume-safety ->
`tests/unit/app/test_install.py` and the e2e dry run; uninstall ->
`test_uninstall_repair.py`; marketplace -> `test_marketplace.py` and
`tests/unit/lifecycles/test_addons.py`; skills -> `test_skills.py`; the MCP
suites -> `test_mcp.py`; legacy-crossing -> `test_deploy_requirements_migrate.py`;
versions-manifest -> `tests/unit/domain/test_versions.py`; the JSON shapes ->
`tests/contract` and `tests/scenarios`. The PowerShell-only guards (parsing
under 5.1, encoding, undefined functions, the table twin) have no Python
counterpart to guard; `quality.yml` parses the bootstrap under 5.1 instead.
