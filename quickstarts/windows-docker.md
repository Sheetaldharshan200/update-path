# Quickstart: Windows with Docker Desktop

Gets you from Windows to a local Exasol database, staying entirely in **PowerShell**. No WSL terminal needed. (More comfortable in a Linux shell? Use the [WSL quickstart](windows-wsl.md).)

## What you need

- Windows 10/11
- **Docker Desktop, installed and running** ([get it here](https://docs.docker.com/desktop/setup/install/windows-install/))
- 4 GB+ RAM
- Free disk on up to **three** volumes, each judged on what actually lands there: **10 GB** where Docker Desktop keeps its data (the disk image, so the database container and its volume), **5 GB** on the system drive when Docker's data root has been moved elsewhere (Windows headroom, Docker's own state, and `%TEMP%`, through which the image download is unpacked), and **3 GB** at the kit's home, `~\.exasol-starter-kit`. On an ordinary single-drive machine these collapse into the one 10 GB check
- **No Python install needed.** The kit uses a system Python 3.11+ if it finds one, and otherwise installs a managed Python for its own use

Want to check before installing anything? The requirements check installs **nothing**:

```powershell
$env:EXAKIT_PREFLIGHT = '1'
irm https://raw.githubusercontent.com/krishna-exasol/update-path/main/install.ps1 | iex
```

## Install (regular PowerShell, no admin needed)

```powershell
irm https://raw.githubusercontent.com/krishna-exasol/update-path/main/install.ps1 | iex
```

What happens, in order:

1. A quick machine check runs first, before anything is downloaded or written
2. The kit is downloaded to `~\.exasol-starter-kit\kit` — every script is readable, before or after the run — and the plan is shown
3. Your machine and Docker are verified in full: RAM, free disk on each volume that matters, and the container engine. If Docker Desktop is not running, you are told exactly that
4. The database container is pulled and started, reachable only from your machine
5. exapump (the data tool) is installed, the sample data is loaded and verified
6. The AI bridge is set up with a read-only database login, and your AI clients are connected
7. You get a connection panel with everything you need

Want to look before it runs? `$env:EXAKIT_DRY_RUN = "1"` first. It downloads and plans, installs nothing.

## Windows and WSL share one Docker engine

Docker Desktop with WSL integration is **one engine**, reachable from both PowerShell and your Linux distro. Both installs default to the same container, `exasol-nano`, on the same data volume, `exasol-nano-data` — so the two paths are not two databases, they are one:

- Running the [WSL install](windows-wsl.md) afterwards **takes over this install's container**, and your Windows kit is left reporting on a database it no longer controls. A run that then fails can leave the shared container stopped, which looks to the other side like a database that lost its data.
- `exakit uninstall` on either side removes that shared container — and with it the database the other side was using.

So pick one path per machine and stay on it. If you really need both, give one of them its own names **before** you install it:

```powershell
$env:EXAKIT_NANO_CONTAINER = "exasol-nano-win"
$env:EXAKIT_NANO_VOLUME    = "exasol-nano-win-data"
```

Each install records the names it used, so `exakit start`, `stop`, `status` and `uninstall` keep acting on its own container from then on. There is no way to separate two installs that have already shared one.

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

Restart your AI client, then continue with the [example questions to ask](../data/example-questions.md).

## Keeping it current

```powershell
exakit version         # installed vs the versions the maintainers advertise
exakit update          # the quick ones in seconds, then it asks before touching the database
exakit update --yes    # unattended: also recreates the Nano container on the same data volume, no question asked
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
| Script execution policy complaints | On a normal machine the installer bypasses policy for its own scripts only — nothing system-wide changes. On a **company-managed machine** where Group Policy pins the policy, `-ExecutionPolicy Bypass` is ignored by design: the installer detects that up front and stops with the fix (`Get-ExecutionPolicy -List` shows the MachinePolicy/UserPolicy rows; ask IT for RemoteSigned, or use the [WSL quickstart](windows-wsl.md), which never touches Windows PowerShell) |
| Corporate proxy | Set `$env:HTTPS_PROXY` before running — the installer passes it to every download, with your signed-in Windows credentials for proxies that ask (HTTP 407) |
| After a reboot | Normally nothing to do: a fresh install turns automatic start on, so the container comes back by itself once Docker Desktop is running. If you turned it off (`exakit autostart off`) or Docker Desktop is not up yet, `exakit start` brings the database back with all data intact |
| Does the installer change my `PATH`? | Yes — it puts `~\.local\bin` at the front of your **user** `PATH` (a per-user registry value: no admin rights, nothing machine-wide), so `exakit` works in every new terminal. Set `$env:EXAKIT_NO_PATH_EDIT = "1"` beforehand to skip that write; the kit then still works in the window you installed from, and afterwards you call it by its full path, `~\.local\bin\exakit.cmd` |
| Windows on ARM (Snapdragon / Copilot+ PC) | Only the database container and pyexasol are available. exapump publishes a Windows build for x86_64 only, and everything downstream of it goes with it: **no sample data, no `exakit data-load`, no `exakit sql`, and no AI bridge** (the read-only MCP user is provisioned through exapump). The `json-tables` and `exasol-scheduler` add-ons are not offered in the marketplace either. You get a working, empty database on `127.0.0.1:8563` that you drive from a SQL client or from Python via pyexasol. For the full kit on this machine, use the [WSL quickstart](windows-wsl.md) — the Linux arm64 builds do exist. Check first with `$env:EXAKIT_PREFLIGHT = '1'`; it names the architecture and what will be skipped before anything is downloaded |
| "The specified path, file name, or both are too long" during an update | Windows' 260-character path limit, hit while unpacking into a deep profile (a OneDrive-redirected home is most of the budget before the kit adds anything). Either turn long paths on (`LongPathsEnabled` under `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem`, needs IT) or move the kit somewhere short with `$env:EXAKIT_HOME = "D:\exakit"` and re-run |
| Your security team asks what this is | The kit downloads from `github.com`, `objects.githubusercontent.com`, `pypi.org`, `files.pythonhosted.org`, `astral.sh` and `registry-1.docker.io`, and installs unsigned prebuilt binaries (`exapump.exe` and any add-on you choose) into `~\.local\bin`, each checked against a SHA-256 digest published in `versions.json`. `exakit update` also starts one short-lived hidden `powershell.exe -EncodedCommand` child process — it exists only to replace the kit folder the running script is executing from, once that script has exited — which some EDR products flag on sight |
| A WSL install took over this database | They share Docker Desktop's engine, and both default to the same container. See [Windows and WSL share one Docker engine](#windows-and-wsl-share-one-docker-engine) — the separation has to be set with `$env:EXAKIT_NANO_CONTAINER` and `$env:EXAKIT_NANO_VOLUME` before installing |
| Home directory is redirected, OneDrive-synced or on a UNC path | `$env:EXAKIT_HOME = "D:\exakit"` before the install moves state, credentials, logs and the kit copy there. Keep it set for later `exakit` commands too — set it as a user environment variable, not just in one shell window |

Remove everything: `exakit uninstall`.
