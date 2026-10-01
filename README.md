<div align="center">

<picture>
  <source srcset="static/Exasol_Logo_2025_Bright.svg" media="(prefers-color-scheme: dark)">
  <img src="static/Exasol_Logo_2025_Dark.svg" alt="Exasol Logo" width="300">
</picture>

# Exasol Personal Local Starter Kit

### The Analytics Database for Agentic AI. Free for Personal Use.

**Install it with one command. You don't need a cloud account or a license key.**

[![Documentation](https://img.shields.io/badge/docs-exasol.com-blue)](https://docs.exasol.com/db/latest/home.htm)
[![Community](https://img.shields.io/badge/community-exasol-green)](https://community.exasol.com)
[![Quickstart](https://img.shields.io/badge/database%20ready-~5%20min-orange)](QUICKSTART.md)

**macOS / Linux / WSL**

```bash
curl https://www.exasol.com/install/starter-kit.sh | sh
```

**Windows (PowerShell)**

```powershell
irm https://www.exasol.com/install/starter-kit.ps1 | iex
```

To have an AI agent do the install, paste this into Claude Code, Codex or any other coding agent:

<div align="left">

```text
Install the Exasol starter kit from https://github.com/exasol-labs/exasol-personal-local-starterkit
```

</div>

</div>

---

## What is this?

This kit sets up an analytics database on your own machine and connects your AI assistant to it. Everything runs locally, so your data stays with you. You can see every SQL statement before it runs, check each answer yourself, and run the same analysis again tomorrow.

The install command sets up four components and connects them:

| Component | What it does |
|---|---|
| [MCP server](https://github.com/exasol/mcp-server) | Lets Claude, Cursor or other supported MCP clients query your database through a dedicated read-only login |
| [Exasol&nbsp;Personal&nbsp;Local](https://github.com/exasol/exasol-personal) | An in-memory analytics database that runs on your machine |
| [exapump](https://github.com/exasol-labs/exapump) | Loads CSV and Parquet files and runs SQL from your terminal |
| [pyexasol](https://github.com/exasol/pyexasol) | The official Exasol Python driver, installed in its own environment |

### What's new in 0.2.0: `exakit marketplace`

The marketplace has five optional add-ons, and you can install any of them at any time with `exakit marketplace`:

| Add-on | What it does |
|---|---|
| [dash-server](https://github.com/exasol-labs/dash-server) | Your AI builds live dashboards from queries on the local database, and you view them in the browser |
| [Exasol&nbsp;for&nbsp;VS&nbsp;Code](https://github.com/exasol-labs/exasol-vscode) | SQL editing and schema browsing against the local database, inside your editor |
| [JSON&nbsp;Tables](https://github.com/exasol-labs/exasol-json-tables) | Loads JSON files into Exasol as regular tables, including nested documents |
| [Exasol&nbsp;Scheduler](https://github.com/exasol-labs/exasol-scheduler) | Runs SQL on a timetable inside the local database, with the jobs defined in a table |
| [dbt-exasol](https://github.com/exasol/dbt-exasol) | Builds, tests and documents SQL models against the local database with dbt |

## Key features

- Few prerequisites. The kit needs Python 3.11 or newer and installs its own copy if you don't have one. You don't need Homebrew or Rust.
- The database is ready in a few minutes. The full install, with sample data and AI client setup, takes longer, especially on Windows, so let it finish.
- Re-running the install is always safe. It skips whatever is already done.
- Your AI assistant has read-only access. It can read everything and change nothing, and the database enforces this: the MCP connection uses a dedicated read-only login.
- It works with Claude, Codex, Cursor, GitHub Copilot, Gemini CLI, OpenCode and Continue.
- Three sample datasets are loaded and verified for you.

## Local Agent-Ready Starter

*Install the kit, connect an AI client and ask your first question.*

### System requirements

Every platform runs the same database, **Exasol Personal**, set up by the same launcher.

| Your machine | Minimum requirements | Notes |
|---|---|---|
| **macOS** | 8 GB+ RAM, 20 GB free disk | Runs in a lightweight managed VM. You don't need to install anything first |
| **Linux** | Podman (rootless is fine), 8 GB+ RAM, 20 GB free disk | If Podman is missing, the installer installs it without stopping to ask. It uses `sudo`, so expect a password prompt |
| **Windows** | 8 GB+ RAM, 20 GB free disk | Runs through Podman on the host, which the launcher offers to install (this may need administrator approval). An existing Podman Desktop machine must be **rootless** (`podman machine set --rootful=false`), or the database port cannot reach Windows |

If you already run the kit's database in a container, re-run the install command to migrate your data, or run `exakit migrate docker-nano` later. Nothing is deleted. The sample data is not copied, because the kit loads it itself.

**WSL** is supported and follows the Linux path: run the same command inside a WSL2 distro. Podman or Docker Desktop on the Windows side does not count. Windows and WSL share port 8563, so run the database on one side only; the kit asks you to stop the other side's database rather than adopt it. Windows arm64 and Intel Macs are not supported for local deployments (the database runs on Apple silicon Macs, Linux x86_64/arm64 and Windows x86_64); the installer says so before it downloads anything. Run the kit inside WSL2 or a Linux VM instead.

Python 3.11+ is needed on every platform. If you don't have it, the kit installs its own copy.

Step-by-step guides: [QUICKSTART](QUICKSTART.md) · [macOS](quickstarts/macos.md) · [Linux](quickstarts/linux.md) · [Windows](quickstarts/windows.md)

### What the install does

The install command checks your machine, shows what it is going to do, and then installs the database, exapump, the MCP server, pyexasol and your AI client connections. The steps are the same on macOS, Linux, WSL and Windows PowerShell. The database is ready in about 5 minutes, and the rest takes a few minutes more, especially on Windows. Let it finish.

When it is done, it shows a connection panel with the details you need and copies a first prompt for your AI client to your clipboard.

If you are installing from a script or an AI agent, see [AGENTS.md](AGENTS.md).

## Connect your AI client

```bash
exakit mcp-setup
```

This opens a checkbox list (↑/↓ to move, **Space** to toggle, **Enter** to confirm). The first row is **Select All**, followed by Claude, Codex, Cursor, GitHub Copilot, Gemini CLI, OpenCode, Continue and Skip. Every supported client is listed. Clients that are already connected, or not installed on this machine, are greyed out with the reason and cannot be selected. If every client it finds is already connected, the command says so and exits.

The command checks the MCP connection, prints where each config file is, and gives you a first prompt to try. It writes the exact path of the local MCP launcher into each client config, so the setup does not depend on what is on each app's PATH.

The installer runs this step for you, and you can run `exakit mcp-setup` again at any time. To check the connection later, run `exakit mcp-doctor`.

## Skills for your AI agent

The installer gives your AI agent eight skills, each covering one part of the kit: setup, the database, exapump, MCP, Python, running the kit itself, the Exasol tool ecosystem and the marketplace. Each installed add-on adds one more. The skills work in Claude Code, Codex, Cursor and any tool that reads the open skill standard, and an agent loads a skill only when the task needs it. `exakit skills` lists them and `exakit update` refreshes them. The full list is in [skills/README.md](skills/README.md).

## The workflow this kit teaches

```
ASK -> INSPECT -> RUN -> VALIDATE -> RERUN
```

For example, ask your assistant: *"Which product category generated the most revenue? Show me the SQL before you run it."*

## Sample data included

The kit includes three datasets, each in its own schema, so your AI client can query them as soon as the install finishes:

| Dataset | What it is | Schema |
|---|---|---|
| TPC-H retail | The standard wholesale and retail model: customers, orders, line items, parts and suppliers (~175k rows, ~21 MB) ([data/datasets/tpch](data/datasets/tpch)) | `TPCH` |
| Smart&#8209;meter&nbsp;energy&nbsp;readings | A time series of ~108k rows ([data/datasets/energy](data/datasets/energy)) | `ENERGY` |
| Daily&nbsp;city&nbsp;weather&nbsp;history | ~11k rows ([data/datasets/weather](data/datasets/weather)) | `WEATHER` |

```bash
exakit data-load             # bundled datasets not yet loaded, or your own data
exakit data-load --force     # REPLACE TPC-H: drops and rebuilds its tables
```

You can also load your own CSV, Parquet or JSON files, or a folder of them, with one table per file. JSON files go through the JSON Tables add-on, which the kit offers when you need it. Uploads land in the `STARTER_KIT` schema by default. More detail: [what's included](data/README.md) · [data dictionary](data/data-dictionary.md) · [14 example questions with reference SQL](data/example-questions.md)

## More ways to connect

- GUI: [DBeaver](https://dbeaver.io/download/) or [DbVisualizer](https://www.dbvis.com/download/). Create a new Exasol connection with host `127.0.0.1`, port `8563` and user `sys`.
  - `exakit info` shows where the password is stored.
- Python: pyexasol is preinstalled in its own environment.
- Terminal: `exapump interactive -p starter-kit` opens a SQL shell.

Run `exakit guide` for the full walkthrough.

## Everyday commands

```bash
exakit status          # is everything running?
exakit info            # connection details
exakit start           # start the database
exakit stop            # stop it (your data is kept)
exakit data-load       # load more data
exakit mcp-setup       # connect AI clients
exakit mcp-doctor      # AI connection health check
exakit version         # what is installed, and what is newer
exakit update          # apply what is pending (asks before it stops the database)
exakit marketplace     # optional add-ons (dashboards & more)
exakit persona         # install by role: datasets, AI clients, add-ons in one go
exakit help            # the commands it offers
```

If an install fails partway through, re-run the install command. It picks up where it left off.

## Add-ons: the marketplace

The base install is kept small on purpose, and optional tools are in the marketplace. At the end of a successful install, the kit asks once whether you want any. You can also browse them later:

```bash
exakit marketplace
```

Press Space to select and Enter to install. `exakit update` keeps installed add-ons up to date along with the rest of the kit. The marketplace does not offer a tool you already have, even one you installed outside the kit. [MARKETPLACE.md](MARKETPLACE.md) has flowcharts for each scenario and explains how to build your own add-on.

## Pick a persona

A persona is a named bundle of the optional choices: which sample datasets,
which AI clients, which add-ons. Four ship with the kit: `analyst`,
`data-scientist`, `data-engineer` and `minimal`. Name one on the install
command and every question is answered for you:

```bash
curl -fsSL https://raw.githubusercontent.com/krishna-exasol/update-path/main/install.sh | EXAKIT_PERSONA=data-scientist sh
```

On an installed kit, `exakit persona list` shows them and
`exakit persona plan data-scientist` shows what is still missing on this
machine. Your own persona is one JSON file in `~/.exasol-starter-kit/personas/`.

## Staying up to date

The maintainers publish one recommended set of versions in `versions.json` on the kit's `main` branch. Your machine reads it at most once a day, caches it for offline use, and compares it with what is installed.

```bash
exakit version    # installed, recommended and status, one row per component
exakit update     # apply what is pending (asks before it stops the database)
```

`exakit update` refreshes the kit scripts, exapump, the MCP server, pyexasol, the agent skills and installed add-ons in seconds, without downtime. While an update is pending, other commands print one dim line to say so. A database runtime update stops the database for a minute or two, so the kit asks first and does not run it unattended unless you pass `exakit update --yes`. Updates never touch your data, credentials or MCP configs. The kit keeps the previous copy of itself and never downgrades a component.

## Safety and operations

- The MCP server uses a dedicated read-only login. The kit creates and validates this least-privilege database user before any MCP setup continues.
- Generated MCP client configs set `EXA_SSL_CERT_VALIDATION=no` only for the local, self-signed `127.0.0.1` runtime. For a real remote database, validate against a trusted CA.
- The kit needs Python 3.11+. It uses `python3` if present, and otherwise installs its own copy through `uv`.
- This repo holds source only. Runtime state, logs, credentials, backups and generated configs live under `~/.exasol-starter-kit/`.
- Install scripts, MCP configs, backups and logs stay on disk, where you can inspect them.
- Everything stays local. The database listens only on `127.0.0.1`, passwords are kept in local files and never shown on screen, and AI client configs are backed up before every change.
- The installer makes one edit outside its own directory: it appends a PATH line to your shell profile, marked with a kit comment so you can find it, and tells you when it does.
- `exakit` manages the kit from start to finish: `status`, `start`/`stop`, `data-load`, MCP setup and maintenance (`mcp-setup`, `mcp-doctor`), `logs`, and a guarded `uninstall`. Run `exakit help` (or `exakit catalog`) to see the commands it offers.

## See it in action

This recording shows the whole flow: installing the kit, connecting an AI client and running the first query.

https://github.com/user-attachments/assets/77916db0-d273-4720-8d59-1aedac95d5e8

## Quick answers

| Question | Answer |
|---|---|
| Do&nbsp;I&nbsp;need&nbsp;Rust&nbsp;/&nbsp;Python&nbsp;/&nbsp;Homebrew? | Only Python 3.11+, and the kit installs its own copy if you don't have one. You don't need Rust or Homebrew. |
| Does&nbsp;it&nbsp;cost&nbsp;anything? | No. Exasol Personal Local is free of charge, but it is not open source: the database ships under [Exasol's own licence terms](https://www.exasol.com/legal/), and this kit's scripts are [MIT](LICENSE). |
| What&nbsp;makes&nbsp;this&nbsp;"for&nbsp;Agentic&nbsp;AI"? | The kit includes an MCP server with a dedicated read-only login, so Claude, Cursor and other MCP clients can query your data directly. You can inspect every SQL statement before it runs. |
| What&nbsp;sample&nbsp;data&nbsp;is&nbsp;included? | Three datasets: TPC-H retail, smart-meter energy and daily weather, each in its own schema. See the [data dictionary](data/data-dictionary.md). |
| Can&nbsp;I&nbsp;load&nbsp;my&nbsp;own&nbsp;data? | Yes. `exakit data-load` has an option for local CSV, Parquet or JSON files, and `exapump upload` works from the terminal. |
| What&nbsp;do&nbsp;I&nbsp;need&nbsp;installed&nbsp;first? | Nothing on macOS or Windows. The Exasol launcher brings what it needs, and on Windows it installs Podman if it is missing. Linux needs Podman, and the preflight check prints the exact command to install it. |
| `exakit` not recognized after<br>a Windows install? | Re-run the install command. It adds `~\.local\bin` to your user PATH and fixes the command. |
| Port&nbsp;8563&nbsp;already&nbsp;taken? | The launcher picks the deployment's port and remembers it, and the kit reads back whichever port it picked. If an existing Exasol database is on the port, the kit adopts it. If something else is using it, the kit names that process. |
| Behind&nbsp;a&nbsp;corporate&nbsp;proxy? | Run `export HTTPS_PROXY=...` and re-run the install. |
| Where&nbsp;is&nbsp;the&nbsp;guide&nbsp;for&nbsp;my&nbsp;OS? | [macOS](quickstarts/macos.md) · [Linux](quickstarts/linux.md) · [Windows](quickstarts/windows.md) |
| Installing&nbsp;over&nbsp;a&nbsp;database<br>I&nbsp;already&nbsp;have? | The kit adopts your existing database, running or stopped, and reuses it with its data intact. The installer replaces a database only if it cannot start at all, and it warns you first. |
| How&nbsp;do&nbsp;updates&nbsp;work? | The maintainers publish one recommended set of versions. `exakit version` shows what is pending, and `exakit update` applies it. See [Staying up to date](#staying-up-to-date). |
| How&nbsp;do&nbsp;I&nbsp;remove&nbsp;everything? | Run `exakit uninstall`. |

---

<div align="center">

*For questions or problems, open an issue in this repository.*

This kit is community supported. Its own scripts are licensed under [MIT](LICENSE). The Exasol database it installs is a separate product under Exasol's own licence terms. The kit is part of [Exasol Labs](https://github.com/exasol-labs/).

More Exasol projects are on [GitHub](https://github.com/exasol).

</div>
