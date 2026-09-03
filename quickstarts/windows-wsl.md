# Quickstart: WSL

Gets you from Windows to a local Exasol database with an AI assistant connected, using **WSL (Windows Subsystem for Linux)**. Prefer staying in PowerShell? Use the [Windows Docker quickstart](windows-docker.md) instead.

## What you need

- Windows 10/11 with **WSL 2** and a Linux distro (Ubuntu is fine):
  ```powershell
  wsl --install        # from an admin PowerShell, if you do not have WSL yet
  ```
- **Docker available inside WSL**. Easiest via Docker Desktop with WSL integration turned on (Docker Desktop, Settings, Resources, WSL integration, enable your distro). Podman works too.
- 4 GB+ RAM, ~10 GB free disk
- **No Python install needed.** The kit uses a system Python 3.11+ if it finds one, and otherwise installs a managed Python for its own use

Check from a WSL terminal (installs nothing):

```bash
curl -fsSL https://raw.githubusercontent.com/krishna-exasol/update-path/main/install.sh | EXAKIT_PREFLIGHT=1 sh
```

Every ✗ line tells you what to fix. The usual one is Docker Desktop not running or WSL integration not enabled.

## Install (inside the WSL terminal)

```bash
curl -fsSL https://raw.githubusercontent.com/krishna-exasol/update-path/main/install.sh | sh
```

What happens, in order:

1. WSL is detected and the plan is shown
2. The database container is pulled and started, reachable only from your machine
3. The database is ready, usually in under 2 minutes
4. exapump (the data tool) is installed, the sample data is loaded and verified
5. The AI bridge is set up with a read-only database login, and your AI clients are connected
6. You get a connection panel with everything you need

## Windows and WSL share one Docker engine

Docker Desktop with WSL integration is **one engine**, reachable from both this distro and PowerShell. Both installs default to the same container, `exasol-nano`, on the same data volume, `exasol-nano-data` — so the two paths are not two databases, they are one:

- Installing here **takes over the container a [Windows PowerShell install](windows-docker.md) created**, and that kit is left reporting on a database it no longer controls. A run that then fails can leave the shared container stopped, which looks from the Windows side like a database that lost its data.
- `exakit uninstall` on either side removes that shared container — and with it the database the other side was using.

So pick one path per machine and stay on it. If you really need both, give one of them its own names **before** you install it:

```bash
curl -fsSL https://raw.githubusercontent.com/krishna-exasol/update-path/main/install.sh | \
  EXAKIT_NANO_CONTAINER=exasol-nano-wsl EXAKIT_NANO_VOLUME=exasol-nano-wsl-data sh
```

Each install records the names it used, so `exakit start`, `stop`, `status` and `uninstall` keep acting on its own container from then on. There is no way to separate two installs that have already shared one.

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

Windows apps can reach the database directly at `127.0.0.1:8563`. If you configure a Windows desktop app from inside WSL, make sure its config uses a launcher command Windows can run. Two options:

- Install `uv` on Windows and use the path from `(Get-Command uvx).Source` as the command
- Or keep the same settings and wrap the launch as `wsl uvx exasol-mcp-server@<version>`

Then continue with the [first workflow](../demo/first-revenue-analysis.md).

## Keeping it current

```bash
exakit version         # installed vs the versions the maintainers advertise
exakit update          # the quick ones in seconds, then it asks before touching the database
exakit update --yes    # unattended: also recreates the Nano container on the same data volume, no question asked
```

A waiting database update is offered inline — `Stop the database and update the
runtime now? [y/N]` — and `y` recreates the container and brings the database back
up for you. Unattended runs are never asked and never stopped: opt in with
`exakit update --yes` or `EXAKIT_CONFIRM_RUNTIME_UPDATE=1`.

Full detail: [Staying up to date](../README.md#staying-up-to-date).

## WSL notes

| Issue | Fix |
|---|---|
| "No container runtime found" inside WSL | Start Docker Desktop on Windows and enable WSL integration for your distro, then re-run |
| Docker works in PowerShell but not in WSL | Same fix: WSL integration is per distro (Settings, Resources, WSL integration) |
| Port 8563 busy on the Windows side | Something on Windows holds it. Stop it, or re-run with `EXAKIT_DB_PORT=8564` |
| Database state after `wsl --shutdown` | Safe. Your data is kept. `exakit start` brings it back |
| WSL clock drift after laptop sleep | If TLS or downloads act strange: `sudo hwclock -s` |
| This install took over a Windows one (or the other way round) | They share Docker Desktop's engine, and both default to the same container. See [Windows and WSL share one Docker engine](#windows-and-wsl-share-one-docker-engine) — the separation has to be set with `EXAKIT_NANO_CONTAINER` and `EXAKIT_NANO_VOLUME` before installing |
| `$HOME` is on `/mnt/c`, redirected or cloud-synced | `EXAKIT_HOME=/opt/exakit` (any writable Linux path) before the install moves state, credentials, logs and the kit copy there. Keep it exported for later `exakit` commands too — put it in `~/.bashrc`, not just the one shell |

Remove everything: `exakit uninstall` inside WSL.
