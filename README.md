<div align="center">

<picture>
  <source srcset="static/Exasol_Logo_2025_Bright.svg" media="(prefers-color-scheme: dark)">
  <img src="static/Exasol_Logo_2025_Dark.svg" alt="Exasol Logo" width="300">
</picture>

# Exasol Personal Local Starter Kit

### The Sovereign Agentic Database. Free for Personal Use.

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

## Overview

This kit sets up an analytics database on your own machine and connects your AI assistant to it. Everything runs locally, so your data stays with you. You see every SQL statement before it runs and can check each answer yourself.

The install command sets up four components and connects them:

| Component | What it does |
|---|---|
| [MCP server](https://github.com/exasol/mcp-server) | Let Claude, Cursor or other supported MCP clients query your database through a dedicated read-only login |
| [Exasol&nbsp;Personal&nbsp;Local](https://github.com/exasol/exasol-personal) | An in-memory analytics database that runs on your machine |
| [exapump](https://github.com/exasol-labs/exapump) | Loads CSV and Parquet files and runs SQL from your terminal |
| [pyexasol](https://github.com/exasol/pyexasol) | The official Exasol Python driver, installed in its own environment |

It also gives your AI agent eight skills, one for each part of the kit. They work in Claude Code, Codex, Cursor and any tool that reads the open skill standard, and an agent loads one only when the task needs it.

## What's new

### Add-ons through `exakit marketplace`

The base install stays small. When you want more, you pick an add-on by the outcome you want, and the kit installs it, checks that it works, and keeps it current with `exakit update`. The installer asks once at the end of a successful install, and `exakit marketplace` opens the same list at any time.

| Add-on | What you get |
|---|---|
| [dash-server](https://github.com/exasol-labs/dash-server) | A result shared as a live dashboard. Your AI builds it from a query on the local database, and you open it in the browser |
| [Exasol&nbsp;for&nbsp;VS&nbsp;Code](https://github.com/exasol-labs/exasol-vscode) | SQL editing and schema browsing next to the rest of your project, inside your editor |
| [JSON&nbsp;Tables](https://github.com/exasol-labs/exasol-json-tables) | JSON files, nested ones included, turned into tables you can query |
| [Exasol&nbsp;Scheduler](https://github.com/exasol-labs/exasol-scheduler) | SQL that runs on a timetable inside the database. The jobs are rows in a table |
| [dbt-exasol](https://github.com/exasol/dbt-exasol) | Repeatable SQL models built, tested and documented with dbt against the local database |


### JSON loading

`exakit data-load` now takes JSON files, including nested documents, and loads them as regular tables. The load goes through the JSON Tables add-on, which the kit offers the first time you need it. Its ingest engine ships prebuilt, so you never need a Rust toolchain.

### Folder bulk upload

Point `exakit data-load` at a folder and every CSV, Parquet or JSON file in it becomes one table, named after the file. The folder is read at its top level only. Uploads land in the `STARTER_KIT` schema by default.

## Minimum requirements

Every platform runs the same database, Exasol Personal, set up by the same launcher.

| Your machine | Minimum | Notes |
|---|---|---|
| **[macOS](quickstarts/macos.md)** | 8 GB+ RAM, 20 GB free disk | Runs in a lightweight managed VM. Nothing to install first |
| **[Linux](quickstarts/linux.md)** | Podman (rootless is fine), 8 GB+ RAM, 20 GB free disk | If Podman is missing, the installer installs it without stopping to ask. It uses `sudo`, so expect a password prompt |
| **[Windows](quickstarts/windows.md)** | 8 GB+ RAM, 20 GB free disk | Runs through Podman, which the launcher offers to install (this may need administrator approval). An existing Podman machine must be rootless (`podman machine set --rootful=false`), or the database port cannot reach Windows. Windows arm64 is not supported |

Python 3.11+ is needed everywhere, and the kit installs its own copy if you don't have it. **WSL** is supported and follows the Linux path: run the same command inside a WSL2 distro.

If you already run the kit's database in a container, re-run the install command and it offers to bring your data across, without deleting anything. `exakit migrate docker-nano` does the same later.

The install checks your machine, shows what it is going to do, then installs everything and connects your AI clients. The database is ready in about 5 minutes, and the rest takes a few minutes more, especially on Windows. When it finishes, it shows a connection panel and copies a first prompt for your AI client to your clipboard.

## Connect your AI client and ask

```bash
exakit mcp-setup
```

The installer runs this for you, and you can run it again any time to add a client. It lists Claude, Codex, Cursor, GitHub Copilot, Gemini CLI, OpenCode and Continue, greys out the ones already connected or not installed, writes the config for the ones you pick and checks the connection. `exakit mcp-doctor` checks it again later.

Three sample datasets are loaded for you: TPC-H retail in `TPCH`, smart-meter energy readings in `ENERGY` and daily city weather in `WEATHER`. The [data dictionary](data/data-dictionary.md) describes them, and [data/example-questions.md](data/example-questions.md) has 14 questions with reference SQL.

Try it: *"Which product category generated the most revenue? Show me the SQL before you run it."*

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

## More ways to connect

- GUI: [DBeaver](https://dbeaver.io/download/) or [DbVisualizer](https://www.dbvis.com/download/). Create a new Exasol connection with host `127.0.0.1`, port `8563` and user `sys`.
  - `exakit info` shows where the password is stored.
- Python: pyexasol is preinstalled in its own environment.
- Terminal: `exapump interactive -p starter-kit` opens a SQL shell.

Run `exakit guide` for the full walkthrough.

## Staying up to date

The maintainers publish one recommended set of versions. Compare your install against it:

```bash
exakit version
```

`exakit update` applies what is pending. Most updates take seconds and need no downtime. A database update stops the database for a minute or two, so the kit asks first unless you pass `--yes`.

## See it in action

The whole flow, from install to the first query:

https://github.com/user-attachments/assets/77916db0-d273-4720-8d59-1aedac95d5e8

## Quick answers

| Question | Answer |
|---|---|
| What&nbsp;do&nbsp;I&nbsp;need&nbsp;installed&nbsp;first? | Nothing on macOS or Windows. Linux needs Podman, and the preflight check prints the command to install it. Python 3.11+ is needed everywhere, and the kit installs its own copy if you don't have one. You don't need Rust or Homebrew. |
| Does&nbsp;it&nbsp;cost&nbsp;anything? | No. Exasol Personal Local is free of charge, but it is not open source: the database ships under [Exasol's own licence terms](https://www.exasol.com/legal/), and this kit's scripts are [MIT](LICENSE). |
| Can&nbsp;I&nbsp;load&nbsp;my&nbsp;own&nbsp;data? | Yes. `exakit data-load` takes CSV, Parquet or JSON files, or a folder of them, and `exapump upload` works from the terminal. |
| The&nbsp;install&nbsp;failed&nbsp;partway&nbsp;through? | Re-run the install command. It skips what is already done and picks up where it left off. |
| `exakit` not recognized after<br>a Windows install? | Re-run the install command. It adds `~\.local\bin` to your user PATH and fixes the command. |
| Port&nbsp;8563&nbsp;already&nbsp;taken? | The launcher picks the deployment's port and remembers it, and the kit reads back whichever port it picked. If an existing Exasol database is on the port, the kit adopts it. If something else is using it, the kit names that process. |
| Behind&nbsp;a&nbsp;corporate&nbsp;proxy? | Set `HTTPS_PROXY` to your proxy address before you run the install command, and every download goes through it: `export HTTPS_PROXY=http://proxy.example.com:8080` on macOS and Linux, `$env:HTTPS_PROXY = 'http://proxy.example.com:8080'` in PowerShell. If the proxy asks for a login, the Windows installer uses your signed-in Windows account. |
| Installing&nbsp;over&nbsp;a&nbsp;database<br>I&nbsp;already&nbsp;have? | The kit adopts your existing database, running or stopped, and reuses it with its data intact. The installer replaces a database only if it cannot start at all, and it warns you first. |
| How&nbsp;do&nbsp;I&nbsp;remove&nbsp;everything? | Run `exakit uninstall`. |

---

<div align="center">

*For questions or problems, open an issue in this repository.*

This kit is community supported. Its own scripts are licensed under [MIT](LICENSE). The Exasol database it installs is a separate product under Exasol's own licence terms. The kit is part of [Exasol Labs](https://github.com/exasol-labs/).

More Exasol projects are on [GitHub](https://github.com/exasol).

</div>
