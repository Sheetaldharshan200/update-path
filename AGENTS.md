# Agent guide: Exasol Personal Local Starter Kit

This repo installs a complete local analytics stack with one command: an Exasol database on the user's machine, the `exapump` data/SQL CLI, an MCP server with a dedicated read-only database user, and the `pyexasol` Python driver. If a user asks you to "install this repo", this file is your runbook.

## Install (one command)

macOS / Linux / WSL:

```bash
curl -fsSL https://raw.githubusercontent.com/krishna-exasol/update-path/main/install.sh | sh
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/krishna-exasol/update-path/main/install.ps1 | iex
```

The installer is **fully unattended-safe**. With no TTY attached (the normal case for an agent shell) every question takes a safe default: all bundled datasets are loaded, and every AI client that is installed on the machine but not yet connected gets an MCP config. Nothing ever hangs waiting for input.

One caveat when driving a **WSL** install from the Windows side (`wsl.exe -- bash -c "curl ... | sh"`): wsl.exe can attach a console that looks interactive but never delivers keypresses, so menus render and block. Either run the command detached (`setsid sh -c '...' < /dev/null` on Linux/WSL; `setsid` does **not** exist on macOS, where `nohup sh -c '...' </dev/null &` is the equivalent) or pre-answer everything with the env vars below.

## Answer the install's choices via environment variables

Flags do not travel through a pipe, so choices are env vars. They work on all platforms; on Windows set them with `$env:` before `irm ... | iex`. **Always use client and dataset names, never menu numbers.** Numbers are display order and change between releases.

| Variable | Effect |
|---|---|
| `EXAKIT_MCP_CLIENTS=claude,cursor` | Which MCP clients to configure, by name: `claude` (= desktop app **and** Claude Code CLI), `claude_desktop`, `claude_code`, `codex`, `cursor`, `vscode_copilot` (also `copilot`), `gemini_cli` (also `gemini`), `opencode`, `continue`, `all`, `skip` |
| `EXAKIT_SKIP_MCP=1` | Skip MCP client setup entirely (run `exakit mcp-setup` later) |
| `EXAKIT_DATASETS=tpch,weather` | Which bundled datasets to load, by id: `tpch`, `energy`, `weather`. Takes precedence over `EXAKIT_LOAD_SAMPLE` |
| `EXAKIT_LOAD_SAMPLE=0\|1` | `0` skip data loading, `1` load the bundled sample (tpch) |
| `EXAKIT_DATA_FILE=/abs/path/data.json` | Load this local CSV / Parquet / JSON file (skips the data menu; also works standalone: `EXAKIT_DATA_FILE=... exakit data-load`) |
| `EXAKIT_DATA_TABLE=SCHEMA.TABLE` | Target table for `EXAKIT_DATA_FILE` (default `STARTER_KIT.<FILENAME>`; a nested JSON file fans out to `<TABLE>_*` tables) |
| `EXAKIT_MARKETPLACE_ADDONS=dash-server` | Answer the closing marketplace offer: ids csv, `all`, or `none`. Unset, a non-interactive install skips the offer with a hint |
| `EXAKIT_REUSE_DB=0\|1` | Adopt an existing database (`1`, the default) or destroy it and deploy fresh (`0`). Honoured on **both** runtimes: on macOS it pre-answers the adoption question; on the container path (Linux, WSL, Windows) `=0` removes the Nano container **and its data volume**, and that volume is the database — its data is deleted and cannot be recovered |
| `EXAKIT_PREFLIGHT=1` | Check machine requirements only, installs nothing. Both installers: `... \| EXAKIT_PREFLIGHT=1 sh`, or `$env:EXAKIT_PREFLIGHT = '1'` before `irm ... \| iex` |
| `EXAKIT_DRY_RUN=1` | Download the kit for inspection, installs nothing |
| `EXAKIT_DB_PORT=8564` | Alternate DB port (Linux and Windows container path only) |

Version and update behaviour (all optional, sensible defaults):

| Variable | Effect |
|---|---|
| `EXAKIT_VERSION_POLICY=manifest\|latest\|pinned` | Where versions come from. `manifest` (default) installs the tested set the maintainers publish in `versions.json`; `latest` resolves each component from its own upstream; anything else (`pinned`) uses the kit's built-in fallbacks and touches no network |
| `EXAKIT_VERSIONS_URL=...` | Where that document is fetched from (must be `https://`). Defaults to the kit repository's `versions.json` on `main` |
| `EXAKIT_VERSIONS_TTL=86400` | Seconds before the cached copy is refreshed. `0` fetches every time |
| `EXAKIT_<COMPONENT>_VERSION=...` | Pin one component by hand: `EXAKIT_EXAPUMP_VERSION`, `EXAKIT_MCP_VERSION`, `EXAKIT_PYEXASOL_VERSION`, `EXAKIT_PERSONAL_VERSION`, `EXAKIT_NANO_TAG`. Outranks the manifest, on install **and** on update |
| `EXAKIT_CONFIRM_RUNTIME_UPDATE=1` | Pre-answer "yes, you may stop the database and recreate the container". Covers both entry points: it skips the confirmation in `exakit update`, and it opts an unattended `exakit update` into the runtime change it would otherwise defer (`exakit update --yes` does the same for one run). `=0` is a deliberate "no" and outranks the prompt |
| `EXAKIT_NO_UPDATE_NOTICE=1` | Never print the once-a-day update notice after other commands |

Example:

```bash
curl -fsSL .../install.sh | EXAKIT_MCP_CLIENTS=claude EXAKIT_DATASETS=tpch sh
```

## Troubleshooting and advanced overrides

None of these are needed on a normal machine, and none are set by default. They exist because when one of them is the answer, nothing else is.

| Variable | Effect |
|---|---|
| `EXAKIT_HOME=/abs/path` | Where the kit keeps everything — state, credentials, logs, the kit copy (default `~/.exasol-starter-kit`). The only fix for a redirected, cloud-synced (OneDrive) or UNC home directory. Set it for the install **and** keep it set for later `exakit` commands (on Windows as a user environment variable, not just in one shell): the CLI reads it each time and otherwise looks in the default location |
| `EXAKIT_NANO_CONTAINER=exasol-nano-win` | Name of the Nano container (default `exasol-nano`). The install records the name it used, so that machine's later `exakit` commands keep acting on the right one |
| `EXAKIT_NANO_VOLUME=exasol-nano-win-data` | Name of the Nano data volume (default `exasol-nano-data`). That volume **is** the database. Set both of these to keep a Windows and a WSL install apart — see the adoption note under Timing |
| `EXAKIT_NANO_READY_TIMEOUT=1200` | Seconds to wait for the database to report ready (default `600`). Raise it on a slow or heavily loaded machine rather than treating the timeout as a failure |
| `EXAKIT_NANO_MIN_RAM_GB=4` | RAM floor for the container path (default `4`) |
| `EXAKIT_NANO_MIN_DISK_GB=10` | Free-disk floor where the container engine stores its data — the image and the database volume (default `10`) |
| `EXAKIT_NANO_MIN_SYSTEM_DISK_GB=5` | Free-disk floor on the Windows system drive when Docker's data root is on another volume (default `5`, Windows path only) |
| `EXAKIT_NANO_MIN_KIT_DISK_GB=3` | Free-disk floor at the kit's own home when the engine's data is on another volume (default `3`) |
| `EXAKIT_FORCE=1` | Install even though a RAM or free-disk check failed, or could not read the number at all. It lowers no requirement — the deploy can still fail on the real limit |
| `EXAKIT_AUTO_ROLLBACK=1` | On a failed install, undo the failed step's changes without asking. The question defaults to no, so an unattended run otherwise keeps partial progress and resumes on the next run (sh installer only) |

## Timing: read this before you run it

- The first install deploys a database, **usually in under 2 minutes** on every platform.
- Your shell tool may **time out before the deploy finishes**. That is not a failure. Run the install in the background (or with a raised timeout), then poll:

```bash
exakit status        # until it reports running
```

- **Re-running the installer is safe and resumes.** Completed steps are skipped, failed steps retry. When in doubt, re-run rather than diagnose.
- An existing database is **adopted**, running or stopped. Only a database that cannot start is replaced, and the installer announces it. To restart a stopped database, prefer `exakit start` over re-installing.
- **On Windows, adoption crosses runtimes, because Windows and WSL share one Docker engine.** Docker Desktop with WSL integration is a single engine reachable from both PowerShell and the distro, and both installs default to the container `exasol-nano` on the volume `exasol-nano-data` — so a WSL install adopts and takes over the container a Windows install created (and the other way round), and `exakit uninstall` in either one removes the container the other is using. If both have to exist on one machine, give one of them `EXAKIT_NANO_CONTAINER` and `EXAKIT_NANO_VOLUME` of its own **before** installing it; there is no way to separate them afterwards.
- **A database that cannot be started at all is a distinct state, and it has its own command.** After a crash (SIGKILL, a hard power loss) the launcher can mark the deployment `interrupted`, after which every `exakit start` fails the same way. `exakit status` reports `interrupted` rather than `stopped` and names `exakit repair-runtime` as the remedy; `status --json` puts that same command in `remedies.database`. **Do not loop on `exakit start`, and do not expect a plain installer re-run to fix it** — `repair-runtime` rebuilds the deployment, which **destroys its data** (bundled datasets are reloaded afterwards; anything the user loaded themselves is not). Ask the user before running it, and pass `--yes` only once they have agreed.

## Verify the install

```bash
exakit status                                     # Status: running
exakit info                                       # connection panel
exakit sql 'SELECT CURRENT_TIMESTAMP'             # end-to-end proof
```

A returned timestamp means the database works. MCP health: `exakit mcp-doctor` (reports `success` plus a per-client state map: connected, available, not installed — and it now starts the configured server and completes an MCP handshake, so `connected` means the client can actually reach it, not merely that the config entry parses).

**You cannot use the MCP tools in the session that installed them.** An MCP client reads its server list at startup, so the client running this install — including you — has no `exasol` tools until it restarts. That is expected and is not a fault to diagnose. For the rest of *this* session use `exakit sql` (below); verify the MCP path next session, or ask the user to restart their client.

### Running SQL

`exakit sql '<statement>'` is the path to prefer: it is the only one that turns a raw engine error into a remedy (connection refused → `exakit start`; `FETCH FIRST`/`TOP` → `LIMIT`; object not found → describe it first). It refuses anything that is not a single read statement unless you pass `--write`.

It is **not** a sandbox — it connects as the admin user, exactly like `exapump sql -p starter-kit`. The enforced read-only boundary is the MCP user and nothing else.

## Updates

The kit installs a **tested set** of versions published by the maintainers, not the newest of each component. Two commands cover everything:

```bash
exakit version           # installed vs advertised, one row per component
exakit update            # apply what is waiting: kit scripts, exapump, MCP server, pyexasol — and, after asking, the database
```

What an agent needs to know:

- `exakit update` takes **seconds** for the quick components. A pending **database** update stops the database, so it is applied only for an answer the run was actually given: on a terminal the user is asked (`Stop the database and update the runtime now? [y/N]`), and on yes the command does the whole sequence itself — stop, update, restart, report.
- **An agent-driven run has no terminal, so the database update is never started on its own.** It is deferred with the exact command (`exakit update`). Opt in deliberately with `exakit update --yes` or `EXAKIT_CONFIRM_RUNTIME_UPDATE=1`, and expect the database to be down for a minute or two. Ask the user first — the database is theirs, and other things may be connected to it.
- The runtime update keeps your data: the container is recreated over the same data volume and the previous image is put back if the new one does not come up. There is no data backup step because nothing deletes data. The one exception is an Exasol Personal **major** upgrade, which is a real data migration: `exakit update` reports it, never starts it, and points at the Exasol Personal migration guidance for that version.
- Nothing here can hang. Version resolution degrades to a cached copy, then to the copy that shipped with the kit; no command fails because an update check could not reach the network.
- `exakit version` is the one command that reports versions: one row per component and add-on, each with what is installed and whether something newer is advertised. There is no separate `update-check` — it was merged into `version`.
- If the advertised version is **older** than the installed one, nothing is offered and nothing is applied: `exakit version` shows a status of `none`, and asking for that component by name succeeds and does nothing. The kit has no downgrade path, by any route or override. To withdraw a faulty release, publish a higher version.
- A component that reports `not installed` (most often `pyexasol`, whose install step is deliberately non-fatal) is repaired by the same command: `exakit update`.

## Marketplace add-ons (optional)

Optional tools live behind `exakit marketplace`, never in the install flow. Interactively it is a checkbox menu (Space selects, Enter installs); an agent answers with the environment instead:

```bash
EXAKIT_MARKETPLACE_ADDONS=dash-server exakit marketplace   # ids csv, or all / none
```

- **dash-server** — agent-operated Dash hosting: build live dashboards on the local database through its MCP control plane (`http://127.0.0.1:5100/mcp`; start it with `dash-server`). Once it is installed, `exakit mcp-setup` registers that control plane as an MCP server named `dash-server` for Cursor, Claude Code, Codex, GitHub Copilot, Gemini CLI, OpenCode and Continue — Claude Desktop is the one client left out, as a note rather than a warning, because its config file has no shape for a remote server (the app takes those through its own Connectors settings) — so after the client restarts you drive it with tools rather than raw HTTP.
- **exasol-vscode** — the Exasol extension for VS Code (SQL editing and schema browsing); installed into VS Code itself, so a copy the user already has from the VS Code Marketplace is respected and never touched.
- **json-tables** — ingest, query and reshape JSON-shaped data (`exasol-json-tables ingest --input <file.json>`). `exapump` loads CSV and Parquet only, so `exakit data-load` installs this add-on silently when handed a `.json` file and finishes the load itself — it asks nothing beyond the schema and table every file kind is asked for. Supported on macOS (Apple silicon), Linux, WSL and Windows x86_64; Windows ARM64 and Intel Macs have no prebuilt engine and are not offered. The ingest engine ships **prebuilt**, from an immutable per-version release the kit's own CI publishes — never tell a user to install Rust.
- Once installed, an add-on updates through the normal flow — `exakit update` covers it along with everything else. Add-ons that were never picked are never touched, and one already on the system outside the kit is respected, not managed.
- An interactive install ends with the same offer once everything ran; `EXAKIT_MARKETPLACE_ADDONS` pre-answers it (see the install answers table above).
- Add-ons that run as services (dash-server) are managed like the database: `exakit status` shows `running` / `stopped`, `exakit start` and `exakit stop` cover the database and every service together, and `exakit autostart on|off` decides whether they come back after a reboot (on by default from a fresh install — launchd on macOS, systemd --user on Linux, the container restart policy for Nano, a Startup entry on Windows).
- dash-server serves on `http://127.0.0.1:5100` by default. If something else holds that port the install moves to the next free one and records it; change it deliberately with `EXAKIT_DASH_SERVER_PORT=<port> exakit update`. `exakit status` distinguishes "stopped" from "the port is held by another process".
- `exakit logs` lists every log the kit can show (installer run, database container, each add-on service, and what the boot entries wrote at login) with size and last-updated; `exakit logs <target>` tails one, `-f` follows it, `--path` prints just the path for piping.
- After a restart, nothing needs a human if autostart is on. If it is off, `exakit start` brings the database and every service back in one command.
- Building a NEW add-on for the marketplace is a development task, not an install step: the walkthrough with skeleton code is [MARKETPLACE.md](MARKETPLACE.md).

## Recipe: install → local JSON file → live dashboard, in one unattended run

The whole flow — fresh machine to a dashboard URL — needs no human and no client restart. Every step below is the non-interactive path; do not substitute interactive menus for any of them.

1. **Install with both add-ons pre-answered**, in the background (see Timing above), then poll `exakit status` until `running`:

```bash
curl -fsSL https://raw.githubusercontent.com/krishna-exasol/update-path/main/install.sh | \
  EXAKIT_MCP_CLIENTS=claude EXAKIT_LOAD_SAMPLE=0 EXAKIT_MARKETPLACE_ADDONS=dash-server,json-tables sh
```

2. **Load the JSON file directly.** `exakit data-load` loads a file unattended with `EXAKIT_DATA_FILE=<file> EXAKIT_DATA_TABLE=<SCHEMA.TABLE>` — but this recipe still calls the add-on's CLI, because `ingest-and-wrap` additionally installs the queryable wrapper views the dashboard uses: it shreds the file, imports it, and creates those views in one command (admin credentials, because it creates schemas):

```bash
exasol-json-tables ingest-and-wrap --input <file.json> --dsn 127.0.0.1:8563 \
  --user sys --password "$(cat ~/.exasol-starter-kit/credentials/personal_sys_password)" \
  --name <workflow_name> --no-tls --if-exists replace --json
```

The `--json` summary names the source schema it created (`EJT_<NAME>_SRC`). Explore it with read-only SQL; every ingested column is a string, so `CAST(... AS DOUBLE)` numerics before aggregating.

3. **Build the dashboard through dash-server's MCP control plane** — plain JSON-RPC over HTTP to `http://127.0.0.1:5100/mcp` (read the real port from `exakit info`). The install just registered this endpoint with your clients as an MCP server named `dash-server`, but a client only reads its server list at startup, so the session that ran the install does not have those tools yet. Inside this run, call the endpoint over HTTP; from the next session, use the registered tools instead:

```bash
curl -s -X POST http://127.0.0.1:5100/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"<tool>","arguments":{...}}}'
```

   Call four tools in order: `exasol_profile_create_local` (bind the **read-only** user — `user: mcp_readonly`, `secret_value` from `~/.exasol-starter-kit/credentials/mcp_readonly_password`, `tls_verify: false`; dashboards read, they never need `sys`), `exasol_profile_validate`, `app_scaffold_from_schema` (point it at the ingested schema/table; it introspects the columns and builds the app itself), then `app_run_healthcheck`.

   **Then make it presentable — the scaffold alone is a bare ops template.** One `app_put_files` + `app_deploy_draft` pass turns it into a dashboard a human would demo:

   - Push `assets/theme.css`, copied **verbatim** from the local kit copy at `~/.exasol-starter-kit/kit/templates/dash-theme.css` — KPI cards, chart cards, tab styling and a colorblind-validated chart palette (`#2a78d6` / `#eb6834` / `#1baf7a`), so no run invents its own CSS.
   - In `app.py`, pass `assets_folder=str(Path(__file__).parent / "assets")` to the `Dash(...)` constructor. The host imports the module dynamically, so Dash's default assets lookup resolves outside the artifact and the theme is **silently never linked** without this.
   - Replace the scaffold's placeholder business SQL with real aggregates of the ingested measures — a KPI summary row (totals, counts, a margin), a monthly trend, and one or two categorical breakdowns — and lay the page out business-first: KPI row on top, charts in `chart-card` divs inside a `chart-grid`, the scaffold's system tabs after. Format money and counts in the KPI values; keep chart series on the palette above and never a dual-axis chart.

4. **Report the browser URL** (`http://127.0.0.1:<port>/apps/<app-name>`) only after the healthcheck's `data_layer` and `sql_smoke` probes pass — a `200` from the page alone does not prove the dashboard can query.

## Where things live

- State, credentials, logs: `~/.exasol-starter-kit/` (logs under `logs/`). Installer and `exakit` messages name their remedy — check there before improvising. Raw database/driver errors (through MCP tools or `exapump` directly) do NOT; translate the common ones with the table below.
- Kit source copy (read any script): `~/.exasol-starter-kit/kit/`
- CLI binaries: `~/.local/bin/` (`exakit`, `exapump`, `exasol` on macOS, and `dash-server` once that add-on is installed). **That directory is not on a bare non-interactive `PATH`** (a clean `sh -c` sees roughly `/usr/local/bin:/bin:/usr/bin`), so `exakit: command not found` does **not** mean "not installed" — test `~/.local/bin/exakit` before concluding anything, and either call it by absolute path or `export PATH="$HOME/.local/bin:$PATH"` first.
- Saved queries: `~/.exasol-starter-kit/workflows/` — created by the install, and where the skill's "make it rerunnable" step puts approved SQL.
- **Never print, echo or paste a database password — and it is not only in `~/.exasol-starter-kit/credentials/`.** The MCP setup writes `EXA_PASSWORD` **in clear text** into each AI client's own config (`~/.claude.json`, `~/.codex/config.toml`, and the rest — `exakit mcp-status` lists them). Those are files agents read routinely while debugging MCP, so treat them the same as the credential files: read them if you must, never reproduce them in your output, a commit, an issue, or a support thread. Redact the `env` block before showing a client config to anyone.

## After the install

Install the agent skills so future sessions can drive the full ask, inspect SQL, run, validate loop:

```bash
exakit skills-install     # place them where CLI agents look
exakit skills             # what this kit carries, and what is installed (--json too)
```

The skill set is a versioned component: `exakit version` shows a `skills` row, and `exakit update` fetches a newer set the maintainers advertise and installs it, without a kit release. A stale set is therefore fixed by `exakit update`, not by `skills-install`, which only re-places the local copy.

There is one skill per thing you have to operate, so only the relevant one loads: `local-agent-ready-starter` (setup and the first query), `exasol-runtime`, `exasol-exapump`, `exasol-mcp`, `exasol-pyexasol`, and one per marketplace add-on (`exasol-marketplace`, `dash-server`, `json-tables`, `exasol-vscode`). Full index: [skills/README.md](skills/README.md).

Then see `skills/local-agent-ready-starter/SKILL.md` for the full query-loop discipline. **If your harness loads this file but not filesystem skills, these are the rules that must not drop out:**

### Guardrails (also in SKILL.md — inlined here so they survive a skill-less harness)

- **The loop is ASK → INSPECT → RUN → VALIDATE → RERUN.** Show the user the SQL *before* running it; validate results independently (a second query, a count, a spot check) before presenting conclusions.
- **Two connections, two trust levels.** The MCP tools run as a dedicated **read-only** database user — reads everywhere, writes rejected *by the database*. `exapump -p starter-kit` connects as the **admin** user and is **not sandboxed**: it can create, drop and delete. Never treat an exapump success as proof something is safe for the MCP path, and never reach for exapump to "work around" an MCP rejection.
- **Prove the boundary, don't assert it:** `SELECT PRIVILEGE FROM SYS.EXA_USER_SYS_PRIVS` as the MCP user returns exactly `CREATE SESSION`, `SELECT ANY TABLE`, `USE ANY SCHEMA`.
- **Never print or log** a database password. They are in `~/.exasol-starter-kit/credentials/` **and in clear text inside each AI client's MCP config** (`~/.claude.json` and friends) — redact the `env` block before showing one of those to anyone.

### Common database errors → remedy (raw engine messages carry none)

| You see | It means | Do |
|---|---|---|
| `Connection refused` (MCP: `[Errno 61/111]`; exapump: `Failed to connect to 127.0.0.1:8563`) | The database is not running | `exakit start`, then confirm with `exakit status` (exit 0 = running, 3 = stopped) |
| `syntax error, unexpected FETCH_` (or `TOP_`) | Exasol does not page with `FETCH FIRST` / `TOP` | Rewrite with `LIMIT <n>` (optionally `OFFSET`) |
| `object <NAME> not found` | Wrong name or missing schema qualifier | `describe_exasol_table_or_view` (MCP) or `DESCRIBE <schema>.<table>`, then fix the query |

For scripted state checks: `exakit status --json` (fields: `running`, `datasets_loaded` — **verified against the database, not just the manifest** — `services`, `steps_completed`, plus `remedies`, a map of component to the exact repair command, and `last_failure`, the most recent recorded reason still pending), `exakit info --json` (the install record), `exakit mcp-doctor --json` (per-client MCP state), `exakit catalog --json` (the whole command surface) and `exakit logs --json` (every log target and its path).

**Exit codes.** `status`, `info --json` and `mcp-doctor` answer `0` running / `3` database not running / `4` not installed — those three are the state queries, and the code IS the answer. `version` answers `0` ok / `4` not installed only: they report on versions, which a stopped database does not change, so do not read database health off them. Bad input — an unknown subcommand, an unknown option, a statement `exakit sql` refuses — exits `2` and records nothing: `last_failure` is for a step of your install that did not finish, not for something you typed.

**One shape for every `--json` answer.** `installed`, `status` and `remedy` are present in all of them, in every state — healthy, database down, and not installed — so a parser can branch without first working out which shape it received. Introspecting the data without MCP: table and column comments ship with every bundled dataset and are readable from `SYS.EXA_ALL_TABLES` (`TABLE_COMMENT`) and `SYS.EXA_ALL_COLUMNS` (`COLUMN_COMMENT`, filtered by `COLUMN_SCHEMA` / `COLUMN_TABLE`) — a sub-100ms query that returns units, value domains and FK targets, not just types. Discover every command with `exakit catalog` (searchable: `exakit catalog logs`, machine-readable: `exakit catalog --json`). For a component rather than a command, `exakit <component> --help` prints its full page - what it is, how to start it, its commands, its environment variables and its troubleshooting table. Components: `exapump`, `mcp`, `pyexasol`, `personal`, `nano`, `dash-server`, `json-tables`, `exasol-vscode`. Every command answers `--help` too. All of it is rendered from `setup/help/*.json`, so `exakit catalog --json` and `exakit help <id> --json` are the structured forms an agent should read rather than scraping the decorated screen.

## Uninstall

```bash
exakit uninstall --yes    # database + data, MCP configs, skills, binaries
```
