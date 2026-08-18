# Quickstart: Windows with Docker Desktop

Gets you from Windows to a local Exasol database, staying entirely in **PowerShell**. No WSL terminal needed. (More comfortable in a Linux shell? Use the [WSL quickstart](windows-wsl.md).)

## What you need

- Windows 10/11
- **Docker Desktop, installed and running** ([get it here](https://docs.docker.com/desktop/setup/install/windows-install/))
- 4 GB+ RAM, ~10 GB free disk

## Install (regular PowerShell, no admin needed)

```powershell
irm https://raw.githubusercontent.com/exasol-labs/exasol-personal-local-starterkit/main/install.ps1 | iex
```

What happens, in order:

1. Your machine is checked and the plan is shown
2. Docker is verified. If Docker Desktop is not running, you are told exactly that
3. The database container is pulled and started, reachable only from your machine
4. exapump (the data tool) is installed, the sample data is loaded and verified
5. The AI bridge is set up with a read-only database login, and your AI clients are connected
6. You get a connection panel with everything you need

Want to look before it runs? `$env:EXAKIT_DRY_RUN = "1"` first. It downloads and plans, installs nothing.

## Verify

```powershell
exakit status                                       # Status: running
```

Any SQL client (DBeaver etc.) connects with host `127.0.0.1`, port `8563`, user `sys`. The password location is shown by `exakit info`.

## Load data

The installer loads the sample data for you. Open the menu again any time, for more datasets or your own files:

```powershell
exakit data-load
```

## Connect your AI assistant

The installer does this too. To run it again: `exakit mcp-setup`. Details in the [QUICKSTART](../QUICKSTART.md).

Restart your AI client, then continue with the [first workflow](../demo/first-revenue-analysis.md).

## Keeping it current

```powershell
exakit version         # installed vs the versions the maintainers advertise
exakit update          # the quick ones in seconds, then it asks before touching the database
exakit update runtime  # recreates the Nano container, on its own; the data volume is kept
```

A waiting database update is offered inline — `Stop the database and update the
runtime now? [y/N]` — and `y` recreates the container and brings the database back
up for you. Unattended runs are never asked and never stopped: opt in with
`exakit update -Yes` or `EXAKIT_CONFIRM_RUNTIME_UPDATE=1`.

Kit 2 (the Trusted AI Workflow add-on) is not available on the Windows path yet.

Full detail: [Staying up to date](../README.md#staying-up-to-date).

## Windows notes

| Issue | Fix |
|---|---|
| "Docker is installed but not running" | Start Docker Desktop, wait for the whale icon to settle, re-run |
| `docker` works in WSL but PowerShell says it is not found | Your shell's PATH predates the Docker Desktop install. The installer finds `docker.exe` anyway and tells you; to fix the shell itself, close the terminal and open a new one |
| "needs at least 10 GB free on D:\" when C: has plenty | Docker Desktop's disk image was moved (Settings, Resources, Advanced). The check follows Docker's real storage location, so free space *there* |
| Disk full during the image pull | `docker system df` shows what Docker is holding; `docker system prune -a` reclaims it |
| A step failed but the install continued | By design. The summary at the end names each missing piece and the one command that installs it |
| "Port 8563 is already in use" | Stop the other application, or set `$env:EXAKIT_DB_PORT = "8564"` and re-run |
| Script execution policy complaints | The installer affects only its own script. Nothing system-wide is changed |
| Corporate proxy | Set `$env:HTTPS_PROXY` before running |
| After a reboot | `exakit start` brings the database back with all data intact |
| Windows on ARM | The database and Python driver install. exapump needs an x86_64 Windows machine |

Remove everything: `exakit uninstall`.
