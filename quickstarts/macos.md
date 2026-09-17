# Quickstart: macOS

Gets you from a bare Mac to a local Exasol database with an AI assistant connected. On macOS the database runs in a lightweight VM that Exasol Personal manages for you — no Docker, and nothing for you to configure.

## What you need

- macOS on Apple Silicon or Intel (one optional add-on, JSON Tables, is Apple
  Silicon only — everything else runs on both)
- 8 GB+ RAM, ~20 GB free disk

The install runs unattended, and the database is usually up in **under 2 minutes**. The steps after it — sample data, the AI bridge, the Python driver — add to that.

Check before you start (installs nothing):

```bash
curl -fsSL https://raw.githubusercontent.com/krishna-exasol/update-path/main/install.sh | EXAKIT_PREFLIGHT=1 sh
```

No Python on your Mac? That is fine. The installer brings its own.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/krishna-exasol/update-path/main/install.sh | sh
```

What happens, in order:

1. Your Mac is checked (chip, memory, disk) and the plan is shown
2. The database is deployed and started
3. exapump (the data tool) is installed and tested
4. The sample data is loaded and verified
5. The AI bridge is set up with a read-only database login, and your AI clients are connected
6. You get a connection panel with everything you need

Safe to interrupt and re-run at any point. Completed steps are skipped.

## Verify

```bash
exakit status
```

## Load data

The installer loads the sample data for you. Open the menu again any time, for more datasets or your own files:

```bash
exakit data-load
```

## Connect your AI assistant

The installer does this too. To run it again: `exakit mcp-setup`. Details in the [QUICKSTART](../QUICKSTART.md).

After setup, restart the AI client and look for an MCP server named `exasol`.

Then continue with the [example questions to ask](../data/example-questions.md).

## Keeping it current

```bash
exakit version         # installed vs the versions the maintainers advertise
exakit update          # the quick ones in seconds, then it asks before touching the database
exakit update --yes    # unattended: applies a waiting database update without asking
```

A waiting database update is offered inline — `Stop the database and update the
runtime now? [y/N]` — and `y` runs the whole sequence for you. A **major** Exasol
Personal version is never started that way: it is a data migration, so it keeps
the backup-gated route, run one step at a time:

```bash
exakit update runtime --plan     # what the migration involves, changes nothing
exakit update runtime --backup   # take the backup the migration is gated on
exakit update runtime --apply    # perform the migration
```

Full detail: [Staying up to date](../README.md#staying-up-to-date).

## macOS notes

| Issue | Fix |
|---|---|
| "This machine is not compatible: Exasol Personal needs at least 8 GB RAM" | Exasol Personal needs 8 GB RAM and 20 GB free disk. The installer stops rather than half-installing. To try anyway on a marginal machine: `EXAKIT_FORCE=1` |
| `python3` triggers a developer-tools popup | Dismiss it. `/usr/bin/python3` is only a stub until Xcode's command line tools are installed; the installer brings its own Python and carries on. Nothing to re-run |
| `~/.local/bin` not on PATH warning | Add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` — or to `~/.bash_profile` if you switched your login shell to bash, because macOS terminals never read `~/.bashrc` |
| Company-managed Mac blocks virtualization | Use a machine you control |
| `exakit start` keeps failing after a crash or hard power-off | `exakit status` says `interrupted`. The launcher cannot restart that deployment; rebuild it with `exakit repair-runtime`. **This deletes the database content** — the bundled sample data is reloaded, anything you loaded yourself is not |
| On an Intel Mac, `exakit data-load` will not take a `.json` file | The JSON Tables add-on is published for Apple silicon only. Everything else in the kit runs on both; convert the file to CSV or Parquet, or load it from an Apple silicon Mac |
| Where did everything go? | Commands: `~/.local/bin` · kit state and credentials: `~/.exasol-starter-kit` · the database itself (deployment, data, `secrets.json`): `~/.exasol/personal/deployments/default` |

Stop and start any time with `exakit stop` and `exakit start`. Your data is kept.

Remove everything: `exakit uninstall`.
