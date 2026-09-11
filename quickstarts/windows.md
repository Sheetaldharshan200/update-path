# Quickstart: Windows

Gets you from Windows to a local Exasol database, staying entirely in **PowerShell**. The database is an **Exasol Personal** local deployment: the Exasol launcher runs it through host Podman, and installs Podman itself if it is missing.

Exasol Personal supports Windows **x86_64**. It does not support Windows arm64 or WSL — the installer says so and exits without changing anything (see the notes below for what an arm64 machine can still do).

## What you need

- Windows 10/11 on x86_64
- 8 GB+ RAM, 20 GB free disk
- **Nothing to install first.** The database runs through Podman's default machine; if Podman is missing, the Exasol launcher offers to install it with Windows Package Manager — that install may ask for administrator approval, and it is the only step that ever does
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
3. The Exasol launcher is downloaded and checksum-verified, then deploys the database locally. If Podman is missing, the launcher offers to install it (this is where the one possible administrator prompt appears); Podman's default machine is prepared and **left exactly as it is** if one already exists
4. The database comes up, reachable only from your machine
5. exapump (the data tool) is installed, the sample data is loaded and verified
6. The AI bridge is set up with a read-only database login, and your AI clients are connected
7. You get a connection panel with everything you need

Want to look before it runs? `$env:EXAKIT_DRY_RUN = "1"` first. It downloads and plans, installs nothing.

## The Podman machine is shared, and the kit does not manage it

Podman's default machine is one machine for the whole host. The Exasol launcher uses it, never reconfigures one that already exists, and leaves it running after `exakit stop` and even after an uninstall — the kit owns the **deployment** (the database and its data), and nothing else. If you use Podman for other work, nothing about that changes.

## Verify

```powershell
exakit status                                       # Status: running
```

Any SQL client (DBeaver etc.) connects with host `127.0.0.1` and the port shown by `exakit info` (the launcher selects and remembers it; 8563 unless something else held it), user `sys`. The password location is shown by `exakit info` too.

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
```

A waiting database update is offered inline and explained before the y/N — including the one-time longer first start after a launcher change (the deployment rebuilds part of its runtime once; your data is kept). Unattended runs are never asked and never stopped: opt in with `exakit update -Yes` or `EXAKIT_CONFIRM_RUNTIME_UPDATE=1`.

Full detail: [Staying up to date](../README.md#staying-up-to-date).

## Windows notes

| Issue | Fix |
|---|---|
| The Podman install asked for administrator approval | That is Windows Package Manager installing Podman, once. Approve it, or install Podman yourself first (`winget install RedHat.Podman`) and re-run — the kit itself never needs admin rights |
| "Port 8563 is already in use" | The launcher selects the deployment's port itself and the kit uses whatever it selected. An existing Exasol on the port is adopted; anything else is reported with the process named — stop that application and re-run |
| A step failed but the install continued | By design. The summary at the end names each missing piece and the one command that installs it |
| Script execution policy complaints | On a normal machine the installer bypasses policy for its own scripts only — nothing system-wide changes. On a **company-managed machine** where Group Policy pins the policy, `-ExecutionPolicy Bypass` is ignored by design: the installer detects that up front and stops with the fix (`Get-ExecutionPolicy -List` shows the MachinePolicy/UserPolicy rows; ask IT for RemoteSigned) |
| Corporate proxy | Set `$env:HTTPS_PROXY` before running — the installer passes it to every download, with your signed-in Windows credentials for proxies that ask (HTTP 407) |
| After a reboot | Normally nothing to do: a fresh install turns automatic start on (a Startup entry runs the launcher). If you turned it off (`exakit autostart off`), `exakit start` brings the database back with all data intact |
| Does the installer change my `PATH`? | Yes — it puts `~\.local\bin` at the front of your **user** `PATH` (a per-user registry value: no admin rights, nothing machine-wide), so `exakit` works in every new terminal. Set `$env:EXAKIT_NO_PATH_EDIT = "1"` beforehand to skip that write; the kit then still works in the window you installed from, and afterwards you call it by its full path, `~\.local\bin\exakit.cmd` |
| I already had the kit, with the database in a container | Re-run the install command. It spots the old installation and asks whether to bring your data across — **Migrate my data** or **Skip and continue**. Neither deletes the old container or its data volume; both stop it, because it holds the port the new database needs. |
| Windows on ARM (Snapdragon / Copilot+ PC) | Exasol Personal has no Windows arm64 deployment, and the installer exits saying exactly that — nothing is downloaded or changed. For the full kit on this machine, use a Linux VM: the Linux arm64 builds do exist |
| "The specified path, file name, or both are too long" during an update | Windows' 260-character path limit, hit while unpacking into a deep profile (a OneDrive-redirected home is most of the budget before the kit adds anything). Either turn long paths on (`LongPathsEnabled` under `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem`, needs IT) or move the kit somewhere short with `$env:EXAKIT_HOME = "D:\exakit"` and re-run |
| Your security team asks what this is | The kit downloads from `github.com`, `objects.githubusercontent.com`, `pypi.org`, `files.pythonhosted.org` and `astral.sh`, and installs unsigned prebuilt binaries (`exapump.exe` and any add-on you choose) into `~\.local\bin`, each checked against a SHA-256 digest published in `versions.json`. The Exasol launcher itself is checksum-verified against its release's checksums file. `exakit update` also starts one short-lived hidden `powershell.exe -EncodedCommand` child process — it exists only to replace the kit folder the running script is executing from, once that script has exited — which some EDR products flag on sight |
| Home directory is redirected, OneDrive-synced or on a UNC path | `$env:EXAKIT_HOME = "D:\exakit"` before the install moves state, credentials, logs and the kit copy there. Keep it set for later `exakit` commands too — set it as a user environment variable, not just in one shell window |
| I had the old container-based install | It keeps working: an installed kit's runtime is recorded, and every `exakit` command, update and repair follows that record. The Personal default only applies to fresh installs |

Remove everything: `exakit uninstall`. The database deployment and its data go; Podman and its machine stay.
