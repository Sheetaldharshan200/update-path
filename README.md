<div align="center">

<picture>
  <source srcset="static/Exasol_Logo_2025_Bright.svg" media="(prefers-color-scheme: dark)">
  <img src="static/Exasol_Logo_2025_Dark.svg" alt="Exasol Logo" width="300">
</picture>

# Exasol Personal Local Starter Kit

### The Analytics Database for Agentic AI. Free for Personal Use.

**One command. No cloud account. No license key to enter.**

[![Documentation](https://img.shields.io/badge/docs-exasol.com-blue)](https://docs.exasol.com/db/latest/home.htm)
[![Community](https://img.shields.io/badge/community-exasol-green)](https://community.exasol.com)
[![Quickstart](https://img.shields.io/badge/database%20ready-~2%20min-orange)](QUICKSTART.md)

**macOS / Linux / WSL**

```bash
curl -fsSL https://raw.githubusercontent.com/krishna-exasol/update-path/main/install.sh | sh
```

**Windows (PowerShell)**

```powershell
irm https://raw.githubusercontent.com/krishna-exasol/update-path/main/install.ps1 | iex
```

**Prefer to let your AI do it?** Paste this into Claude Code, Codex, or any coding agent:

<div align="left">

```text
Install the Exasol starter kit from https://github.com/krishna-exasol/update-path
```

</div>

</div>

---

## What is this?

You already use AI. The hard part is trusting it with your data. This kit gives you a complete, private AI-ready analytics setup that runs **entirely on your machine**. See every SQL statement before it runs, verify every answer yourself, and rerun the whole thing tomorrow.

**One command installs four things and connects them:**

| | Component | What it does for you |
|---|---|---|
| 🤖 | **[MCP server](https://github.com/exasol/mcp-server)** | Lets Claude, Cursor, or other supported MCP clients query your database with a dedicated read-only login |
| 🗄️ | **[Exasol&nbsp;Personal&nbsp;Local](https://github.com/exasol/exasol-personal)** | A full in-memory analytics database, running locally |
| ⚡ | **[exapump](https://github.com/exasol-labs/exapump)** | Load CSV/Parquet files and run SQL from your terminal |
| 🐍 | **[pyexasol](https://github.com/exasol/pyexasol)** | The official Exasol Python driver, ready in its own environment |

**Four add-ons — add them any time with `exakit marketplace`:**

| | Add-on | What it does for you |
|---|---|---|
| 📊 | **[dash-server](https://github.com/exasol-labs/dash-server)** | Your AI builds live, query-backed dashboards on the local database; you open them in the browser |
| 🧩 | **[Exasol&nbsp;for&nbsp;VS&nbsp;Code](https://github.com/exasol-labs/exasol-vscode)** | SQL editing and schema browsing against the local database, inside your editor |
| 🧬 | **[JSON&nbsp;Tables](https://github.com/exasol-labs/exasol-json-tables)** | Load JSON files into Exasol as regular tables, nested documents included |
| ⏱️ | **[Exasol&nbsp;Scheduler](https://github.com/exasol-labs/exasol-scheduler)** | Lightweight, table-driven SQL job scheduling: run SQL on a timetable inside the local database |



## Key features

- 🪶 **Almost no prerequisites.** No Homebrew, Rust or Python install needed. The kit uses a suitable Python if it finds one, otherwise it installs a managed one for itself.
- ⚡ **Database ready in about 2 minutes.** The full install — sample data and AI client setup included — takes longer, notably so on Windows. Let it finish; re-running is always safe.
- 🔒 **Read-only AI.** Your assistant can read everything and change nothing. The database enforces it.
- 🤖 **Support for multiple AI clients.** Claude, Codex, Cursor, GitHub Copilot, Gemini CLI, OpenCode, Continue.
- 📊 **Sample data included.** Three sample datasets, loaded and verified for you.
- ♻️ **Safe to re-run.** Re-runs skip what is already done.

## 🚀 Local Agent-Ready Starter

*Install, connect an AI client, ask your first question.*

### Will it run on my machine?

| Your machine | Minimum Requirements | That's all |
|---|---|---|
| **macOS** | 8 GB+ RAM, 20 GB free disk | Runs in a lightweight managed VM — no Docker to install |
| **Linux / WSL** | Docker or Podman (running), 4 GB+ RAM, ~10 GB free disk where the engine keeps its data (plus ~3 GB at your home) | Container runtime required |
| **Windows** | Docker Desktop (running), 4 GB+ RAM, ~10 GB free disk where Docker keeps its data (plus ~3 GB on the system drive) | Native Windows uses the PowerShell installer |

**No Python install needed** on any platform: the kit uses a system Python 3.11+ when it finds one, and otherwise installs a managed Python for its own use.

Step-by-step guides: [QUICKSTART](QUICKSTART.md) · [macOS](quickstarts/macos.md) · [Linux](quickstarts/linux.md) · [WSL](quickstarts/windows-wsl.md) · [Windows + Docker](quickstarts/windows-docker.md)

### Installing: what to expect

One command does the whole install. It checks your machine, shows what it will do, and then installs the database, exapump, the MCP server, pyexasol and your AI client connections. The database is ready in about 2 minutes. The rest takes a few minutes more, especially on Windows. Let it finish. It is the same on macOS, Linux, WSL and Windows PowerShell.

At the end you get a connection panel with everything you need, and a first prompt for your AI client is on your clipboard.

Installing from a script or an AI agent? See [AGENTS.md](AGENTS.md).

## Connect your AI client

```bash
exakit mcp-setup
```

A checkbox multi-select (↑/↓ to move, **Space** to toggle, **Enter** to confirm). A **Select All** row sits at the top, then **Claude**, **Codex**, **Cursor**, **GitHub Copilot**, **Gemini CLI**, **OpenCode**, **Continue**, and **Skip**. The list is **dynamic**: every supported client is shown, and the ones already connected or not installed on this machine appear greyed out, with the reason, and cannot be selected. If everything found is already connected, the command says so and exits.

The command checks the MCP connection, prints where each config lives, and gives you a first prompt to try. It writes the exact path of the local MCP launcher into the client configs, so setup does not depend on what is on each app's PATH.

The installer runs this step for you automatically. `exakit mcp-setup` re-runs it any time.

Health check any time: `exakit mcp-doctor`.

## Let an AI client drive the kit (the skills)

The installer gives your AI agent eight skills, one per thing it may need to drive: setup, the database, exapump, MCP, Python, operating the kit itself, the Exasol tool ecosystem and the marketplace, plus one per installed add-on. They work in Claude Code, Codex, Cursor and any tool that reads the open skill standard, and load only when relevant. `exakit skills` lists them, `exakit update` refreshes them. Index: [skills/README.md](skills/README.md).

## The workflow this kit teaches

```
ASK -> INSPECT -> RUN -> VALIDATE -> RERUN
```

Ask your assistant: *"Which product category generated the most revenue? Show me the SQL before you run it."*

## Sample data included

The kit ships **three bundled datasets**, each in its own schema, so your AI client sees them instantly:

| Dataset | What it is | Schema |
|---|---|---|
| **TPC-H retail** | The standard wholesale/retail model: customers, orders, line items, parts, suppliers (~175k rows, ~21 MB) ([data/datasets/tpch](data/datasets/tpch)) | `TPCH` |
| **Smart&#8209;meter&nbsp;energy&nbsp;readings** | A ~108k-row time series ([data/datasets/energy](data/datasets/energy)) | `ENERGY` |
| **Daily&nbsp;city&nbsp;weather&nbsp;history** | ~11k rows ([data/datasets/weather](data/datasets/weather)) | `WEATHER` |

```bash
exakit data-load             # bundled datasets not yet loaded, or your own data
exakit data-load --force     # reload TPC-H
EXAKIT_DATASETS=tpch,energy,weather exakit data-load --force   # reload all three
```

Your own data can be CSV, Parquet or JSON files, or a folder of them, one table each (JSON through the JSON Tables add-on, offered when needed). Uploads land in the `STARTER_KIT` schema. Details: [what's included](data/README.md) · [data dictionary](data/data-dictionary.md) · [14 example questions with reference SQL](data/example-questions.md)

## More ways to connect

- **GUI**: [DBeaver](https://dbeaver.io/download/) or [DbVisualizer](https://www.dbvis.com/download/). New Connection, Exasol, host `127.0.0.1`, port `8563`, user `sys`.
  - `exakit info` shows where the password lives.
- **Python**: pyexasol comes preinstalled in its own environment.
- **Terminal**: `exapump interactive -p starter-kit` opens a SQL shell.

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
exakit help            # the commands it offers
```

Something failed mid-install? Re-run the install command. It picks up where it left off.

## Add-ons: the marketplace

The install stays minimal on purpose; extras live in the marketplace. At the
end of a successful install the kit asks once whether to add any — or browse
later with:

```bash
exakit marketplace
```

Space selects, Enter installs. Installed add-ons update through `exakit update`
like everything else, and a tool you already have — even one installed outside
the kit — is never offered twice. Flowcharts of every scenario, and how to
build your own add-on: [MARKETPLACE.md](MARKETPLACE.md).

## Staying up to date

The maintainers publish one recommended set of versions in `versions.json` on the kit's `main` branch. Your machine reads it (at most once a day, cached for offline use) and compares it with what is installed.

```bash
exakit version    # installed, recommended and status, one row per component
exakit update     # apply what is pending (asks before it stops the database)
```

`exakit update` refreshes the kit scripts, exapump, the MCP server, pyexasol, the agent skills and installed add-ons in seconds, with no downtime. When any update is pending, one dim line appears after other commands. Silence it for good with `EXAKIT_NO_UPDATE_NOTICE=1`, or throttle it with `EXAKIT_NOTICE_INTERVAL=86400` for at most one notice a day. A database runtime update stops the database for a minute or two, so it asks first and never runs unattended (opt in with `exakit update --yes`). Data, credentials and MCP configs are never touched, the previous kit copy is kept, and the kit never moves a component backwards.

## Safety and operations

- **Dedicated read-only MCP login.** The kit provisions and validates a least-privilege database user before any MCP flow proceeds.
- **Local TLS handled for MCP clients.** Generated MCP client configs set `EXA_SSL_CERT_VALIDATION=no` only for the local self-signed `127.0.0.1` runtime. Use trusted CA validation for real remote databases.
- **No preinstalled Python required.** Uses `python3` when present, otherwise bootstraps a managed runtime through `uv`.
- **Repo stays pure source.** Runtime state, logs, credentials, backups, and generated configs live under `~/.exasol-starter-kit/`, never in this repo.
- **Everything is inspectable.** Install scripts, MCP configs, backups, and logs remain available on disk.
- **Local only.** The database listens on `127.0.0.1` only, passwords live in local files and are never shown on screen, and AI client configs are backed up before every change.
- **One edit outside its own home.** The installer appends a PATH line to your shell profile, marked with a kit comment so you can find it, and says so when it does. Set `EXAKIT_NO_PROFILE_EDIT=1` to keep it out and put `~/.local/bin` on PATH yourself.
- **Reversible lifecycle.** `exakit` manages the kit end to end: `status`, `start`/`stop`, `data-load`, MCP setup and maintenance (`mcp-setup`, `mcp-doctor`), `logs`, and a guarded `uninstall`. Run `exakit help` (or `exakit catalog`) to see the commands it offers. A few maintenance commands are deliberately left off both lists; `exakit help <name>` still answers for them.

## See it in action

Install, connect an AI client, and run the first query, end to end:

https://github.com/user-attachments/assets/77916db0-d273-4720-8d59-1aedac95d5e8

## Quick answers

| Question | Answer |
|---|---|
| Do&nbsp;I&nbsp;need&nbsp;Rust&nbsp;/&nbsp;Python&nbsp;/&nbsp;Homebrew? | **None of them.** The kit uses a system Python 3.11+ if you have one, and otherwise installs a managed Python for its own use. |
| Does&nbsp;it&nbsp;cost&nbsp;anything? | No. Exasol Personal Local is free to use. It is free of charge, not open source: the database ships under [Exasol's own licence terms](https://www.exasol.com/legal/), while this kit's scripts are [MIT](LICENSE). |
| What&nbsp;makes&nbsp;this&nbsp;"for&nbsp;Agentic&nbsp;AI"? | An MCP server ships in the box with a dedicated read-only login, so Claude, Cursor, and other MCP clients can query your data directly, with every SQL statement inspectable before it runs. |
| What&nbsp;sample&nbsp;data&nbsp;is&nbsp;included? | Three bundled datasets: TPC-H retail, smart-meter energy, daily weather, each in its own schema. See the [data dictionary](data/data-dictionary.md). |
| Can&nbsp;I&nbsp;load&nbsp;my&nbsp;own&nbsp;data? | Yes. `exakit data-load` has a local CSV or Parquet option, and `exapump upload` works from the terminal. |
| Docker&nbsp;installed&nbsp;but&nbsp;not&nbsp;running? | Start Docker Desktop, run the install command again. |
| Docker Desktop runs on Windows<br>but WSL can't see it? | Docker Desktop → Settings → Resources → **WSL integration** → enable your distro → Apply & restart (the installer detects and flags this too). |
| `exakit` not recognized after<br>a Windows install? | Re-run the install command. It adds `~\.local\bin` to your user PATH and repairs the command automatically. |
| Port&nbsp;8563&nbsp;already&nbsp;taken? | Linux, WSL and Windows: `EXAKIT_DB_PORT=8564` before the install command. macOS deploys on 8563 itself — an existing Exasol there is adopted, anything else must be stopped first. |
| Behind&nbsp;a&nbsp;corporate&nbsp;proxy? | `export HTTPS_PROXY=...` and re-run. |
| Where's&nbsp;the&nbsp;deep-dive&nbsp;for&nbsp;my&nbsp;OS? | [macOS](quickstarts/macos.md) · [Linux](quickstarts/linux.md) · [WSL](quickstarts/windows-wsl.md) · [Windows + Docker](quickstarts/windows-docker.md) |
| Installing&nbsp;over&nbsp;a&nbsp;database<br>I&nbsp;already&nbsp;have? | An existing database is adopted, never replaced. Running or stopped, it is reused with its data intact. Only a database that cannot start at all is replaced, and the installer warns you first. |
| How&nbsp;do&nbsp;updates&nbsp;work? | The maintainers publish one recommended set of versions. `exakit version` shows what is pending, `exakit update` applies it. See [Staying up to date](#staying-up-to-date). |
| How&nbsp;do&nbsp;I&nbsp;remove&nbsp;everything? | `exakit uninstall` |

---

<div align="center">

*Questions or issues: open an issue in this repository.*

Community-supported. This kit is licensed under [MIT](LICENSE). That covers the kit's own scripts only: the Exasol database it installs is a separate product under Exasol's own licence terms. Part of [Exasol Labs 🧪](https://github.com/exasol-labs/).

Continue exploring [Exasol](https://github.com/exasol).

</div>
