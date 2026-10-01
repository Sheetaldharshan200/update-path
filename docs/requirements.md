# Requirements: personas, and the road to one implementation

Status: living document. Edit it in the same PR as any change it describes.
Companions: [design.md](design.md), [tasks.md](tasks.md),
[test-and-acceptance.md](test-and-acceptance.md).

## 1. Why this work exists

The kit has four problems the team faces every week. All four are in scope;
they are solved in milestones, not all at once.

| # | Pain | What it costs today |
|---|------|---------------------|
| P1 | **Two implementations of everything.** Bash (`setup/exakit`, `setup/lib/*.sh`) and PowerShell (`setup/exakit.ps1`, `setup/lib/*.ps1`) each carry the full lifecycle: install, update, marketplace, manifest, uninstall, status. About 53,000 lines in total. | Every fix is written twice and parity-tested (`tests/ps-table-twin.sh`, `tests/marketplace.sh`, `tests/dry-run-matrix.sh`). Drift already exists: the Windows self-update does not refresh skills, a missing library exits 1 on Windows and 4 on bash, `exakit update <addon>` is a repair on bash and a no-op on Windows. |
| P2 | **Slow add-on onboarding.** A marketplace add-on is a `.sh` + `.ps1` module pair, a `versions.json` block, two registry lines, a help document, two CI guard entries. | Even a metadata-only add-on (download a release, verify, put on PATH) needs two full lifecycle modules. |
| P3 | **Interactive experience is hand-rolled.** `ui.sh` / `ui.ps1` are ANSI twins (banner, spinner, live table, checkbox menu) with their own parity guard. | Any new interactive flow doubles the UI code and the guard surface. |
| P4 | **No role-based install.** Leadership wants one keyword that installs the right datasets, AI clients, add-ons and skills for a kind of user, on every platform, in one command. | Today a user answers four menus or sets four env vars, and there is no record of what they intended. |

## 2. Non-negotiable constraints

These come from the repo's published promises and from the team. A change
that breaks one is wrong even if it is otherwise good.

- **C1. No new compiled binaries of our own.** Unsigned executables get held
  by Defender and corporate EDR (`Test-ExakitBinaryNotRunnableYet`), refused
  by WDAC (`Test-JsonTablesAppControl`) and blocked by firewalls. The core
  stays script and data. Downloading upstream tools the kit already trusts
  (uv, exapump, Exasol Personal) is unchanged.
- **C2. Ships as an update, not as a new product.** An installed 0.2.0 kit
  runs `exakit update`, gets the new kit copy from `main`, and everything it
  had keeps working: the manifest is read as is, every command keeps its
  output, exit codes, `--json` shapes and env-var answers. New features are
  additive.
- **C3. One-command install stays.** `curl ... | sh` on macOS, Linux and WSL,
  `irm ... | iex` on Windows. No preinstalled Python or other runtime is
  assumed before the installer runs.
- **C4. Portability floors.** Bash 3.2 (macOS default) and Windows PowerShell
  5.1 (`CLAUDE.md`). Linux, macOS, WSL and Windows, on x86_64 and arm64; the
  local database itself on Apple silicon Macs, Linux x86_64/arm64 and Windows
  x86_64 (`catalog/components/personal.json`, `platforms`), refused in words
  before anything is installed elsewhere.
- **C5. The agent contract is frozen.** `AGENTS.md`: every state query has
  `installed`, `status` and `remedy`; `remedy` is a runnable command or
  `null`; exit codes 0/1/2/3/4/5 keep their meanings; `--json` prints one
  object on stdout and nothing else; env vars use names, never menu numbers;
  browsing is never an install without a terminal.
- **C6. Existing guards keep passing.** No hand-wired add-on case arms
  (`tests/marketplace.sh`), the registry is the filesystem for skills
  (`tests/skills.sh`) and help documents, ASCII-only `.ps1` files
  (`tests/ps-encoding-guard.sh`), every PowerShell call resolves
  (`tests/ps-undefined-functions.sh`), `whats-new.json` line rules.
- **C7. No AI attribution** in commits, PRs, code or docs (`CLAUDE.md`).

## 3. Delivery: four phases of one migration

The architecture ([architecture.md](architecture.md)) is one Python
implementation bootstrapped by a tiny shell layer. It is delivered as a
strangler migration in four phases, each shipped through `exakit update`:

| Phase | Python takes over | Solves |
|---|---|---|
| **A** | bootstrap, launcher, read-only commands (`status info version help catalog whats-new`), `persona list/show/plan` | P4 (persona keyword and plan), the foundation for P1 |
| **B** | `marketplace`, `skills`, `mcp-*`, `data-load`, `sql`, `logs`, `persona apply`; add-ons become `catalog/addons/<id>/addon.json` | P2, P4 complete |
| **C** | `install`, `update`, runtime commands, `uninstall`; setup scripts deleted | P1 |
| **D** | `setup/` deleted; optional TUI | P3 |

Sections 4 (personas) and 5 below are the functional requirements; the
persona requirements are met across phases A (list, show, plan, the install
keyword through the legacy install) and B (apply).

## 4. Functional requirements: personas

### 4.1 Definitions

- A **persona** is a named bundle of the install's optional choices:
  which bundled datasets to load, which AI clients to connect, which
  marketplace add-ons to install, and (reserved) which skills to place.
- A persona is **data**, never a script. It lives in
  `setup/personas/<id>.json`. The directory is the registry, the same rule
  skills (`skills/<id>/SKILL.md`) and help documents (`setup/help/<id>.json`)
  follow. No shell code names a persona.
- A persona is **exactly a named set of the existing env-var answers**
  (`EXAKIT_DATASETS`, `EXAKIT_LOAD_SAMPLE`, `EXAKIT_MCP_CLIENTS`,
  `EXAKIT_SKIP_MCP`, `EXAKIT_MARKETPLACE_ADDONS`). It adds one behaviour those
  answers do not have: an add-on the persona names that is not available on
  this machine is **skipped with a reason**, not fatal, because a persona is
  written once for every platform.

### 4.2 Install-time keyword (leadership's ask)

- **R1.** `EXAKIT_PERSONA=<id>` on the install command applies the persona
  during the install, on every platform:
  - macOS/Linux/WSL: `curl -fsSL .../install.sh | EXAKIT_PERSONA=data-scientist sh`
  - Windows: `$env:EXAKIT_PERSONA = 'data-scientist'; irm .../install.ps1 | iex`
- **R2.** An explicit env answer always wins over the persona, per variable.
  `EXAKIT_PERSONA=data-scientist EXAKIT_DATASETS=tpch` loads only tpch and
  takes everything else from the persona.
- **R3.** An unknown persona id stops the install before anything is
  installed, names the known ids, and exits 2 (bad input). It never silently
  falls back to the defaults.
- **R4.** The persona is recorded in the manifest (`persona.id`,
  `persona.source=install`, `persona.requested_at`) so `exakit info --json`
  and `exakit persona list` can say what was intended, even if a step failed.
- **R5.** Skills are installed for every persona (core skills always, add-on
  skills with their add-on), exactly as today. `skills` in the persona file
  is reserved and must be `"all"` in schema 1.
- **R6.** Re-running the installer with `EXAKIT_PERSONA` over an existing
  install is safe: steps already done are skipped exactly as a re-run is
  today. Adding clients or add-ons to an existing install is done with
  `exakit persona apply <id>` (R8), which does not depend on the installer's
  once-only gates.

### 4.3 Post-install command

- **R7.** `exakit persona list [--json]` lists every persona this kit copy
  ships plus user-defined ones, with title and summary, and marks the
  recorded one. Works whether or not one was recorded. `--json` shape in
  [design.md 5.3](design.md#53-json-shapes).
- **R8.** `exakit persona apply <id> [--yes] [--json]` brings this machine to
  the persona: loads its pending datasets, connects its AI clients, installs
  its add-ons (skipping unavailable ones with a reason), places skills, and
  records `persona.id`, `persona.source=apply`, `persona.applied_at`.
  Interactive: shows the plan and asks once. Headless without `--yes`: prints
  the plan, exits 5 (not confirmed), remedy `exakit persona apply <id> --yes`.
- **R9.** `exakit persona plan <id> [--json]` shows what `apply` would do on
  this machine and changes nothing. Every item carries a state
  (`pending`, `done`, `skipped` + reason, `unavailable` + reason).
- **R10.** `exakit persona show <id> [--json]` prints the persona definition.
- **R11.** Bare `exakit persona` with a terminal opens a cursor menu of
  personas, then the plan, then the confirmation. Without a terminal it
  lists and installs nothing (the marketplace rule).
- **R12.** Errors follow the contract: unknown persona or option exits 2
  (JSON refusal object under `--json`), no install exits 4, database not
  running for a step that needs it is self-healed via
  `exakit_ensure_runtime_running` or exits 3, declined exits 5.
- **R13.** `exakit status --json` gains `"persona": "<id>"|null`.
  `exakit info --json` carries the `persona` block by virtue of dumping the
  manifest. `exakit help persona`, `exakit catalog` and `exakit help --json`
  know the command.

### 4.4 Persona files

- **R14.** Schema 1, canonical JSON formatting (`json.tool`, indent 2, one
  key per line, LF, ASCII), fields: `schema_version`, `id`, `title`,
  `summary`, `datasets`, `mcp_clients`, `addons`, `skills`. Exact types in
  [design.md 4](design.md#4-persona-file-format).
- **R15.** The kit ships four personas: `analyst`, `data-scientist`,
  `data-engineer`, `minimal`. Their content is in
  [design.md 4.3](design.md#43-shipped-personas).
- **R16.** A user or a team can drop `<id>.json` into
  `$EXAKIT_HOME/personas/` (default `~/.exasol-starter-kit/personas/`). A
  user file with the same id as a shipped one shadows it. A file that does
  not parse or fails validation is ignored with a warning, never fatal.
- **R17.** Every dataset id must be a bundled dataset, every add-on id must
  be registered, every client name must be one `EXAKIT_MCP_CLIENTS` accepts.
  A shipped persona that violates this fails CI (`tests/persona.sh`).

### 4.5 Update path

- **R18.** `versions.json` `kit.version` moves to 0.3.0 and
  `setup/whats-new.json` gets a 0.3.0 card. `exakit update` on any installed
  kit then pulls the new copy and the `persona` command exists from that
  moment, on both platforms. No manifest migration is needed: a kit with no
  `persona` block simply has none recorded.
- **R19.** `exakit uninstall` removes the persona record with everything
  else (it removes the manifest). `exakit uninstall <addon>` leaves the
  persona record alone; `exakit persona plan` then shows that add-on as
  pending again, which is the truthful state.

### 4.6 Documentation

- **R20.** `AGENTS.md` env table gets `EXAKIT_PERSONA` and the Discovery
  section names `exakit persona list --json`. `README.md` gets a "Pick a
  persona" paragraph and the everyday-commands block gets `exakit persona`.
  The three `quickstarts/*.md` show the one-line persona install.
  `install.sh` / `install.ps1` headers list the variable. `CHANGELOG.md`
  Unreleased describes it. `setup/help/exakit.json` documents the command.

## 5. Functional requirements: the shared implementation

- **R21.** Every command keeps its `--json` shape, exit code and env answers; `tests/contract` holds golden outputs captured from the 0.2.0 CLI.
- **R22.** A new add-on is one `catalog/addons/<id>/addon.json` plus, only when a generic lifecycle cannot express it, a `hooks.py`. Never a module pair.
- **R23.** A new component is one `catalog/components/<id>.json` plus its `versions.json` entry.
- **R24.** A new interactive screen is a `Plan` rendered by the shared renderer; no screen code is duplicated per OS.
- **R25.** Only `bootstrap/` and `adapters/platform/`, `adapters/process/services.py` contain OS-specific code.
- **R26.** The managed Python (uv, CPython 3.12) is installed by the bootstrap before anything else on every OS, verified by digests in `versions.json`; the system Python is never used.
- **R27.** An install made by 0.2.0 that runs `exakit update` gets the launcher, the Python, and the migrated manifest without user action; every command it had keeps working during phases A to C.

## 6. Out of scope

- A compiled `exakit` core (C1).
- A TUI that the installer depends on (C3). A post-install TUI is optional, phase D.
- Changing what the core steps install (Personal, exapump, MCP server,
  pyexasol, skills, helper). Personas select the optional layer only.
- Keeping any lifecycle logic in shell after phase D.
