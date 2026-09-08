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

- **Install `uv` on Windows** (`winget install astral-sh.uv`, or see astral.sh/uv) and use the path from `(Get-Command uvx).Source` as the command. Nothing else changes: the DSN is `127.0.0.1:8563`, which Windows reaches directly, and the credentials are carried as environment values, not as Linux file paths. This is the simpler of the two options.
- Or launch through WSL. Two things do not cross the boundary by themselves. `wsl` runs your command **without sourcing `~/.bashrc`**, so a bare `uvx` is not on its PATH — give the absolute path, which `command -v uvx` inside WSL prints. And the config's `env` block sets variables for `wsl.exe` on the Windows side, not inside the distro — carry them in yourself with `env`. Take the values from `exakit info`:

  ```json
  "command": "wsl.exe",
  "args": ["-d", "Ubuntu", "--", "env",
           "EXA_DSN=127.0.0.1:8563", "EXA_USER=mcp_readonly",
           "EXA_PASSWORD=<from exakit info>", "EXA_SSL_CERT_VALIDATION=false",
           "/home/<you>/.local/bin/uvx", "exasol-mcp-server@<version>"]
  ```

  A single string (`"command": "wsl uvx ..."`) is not a program name Windows can spawn, and the kit's own `uvx` may live under `~/.exasol-starter-kit/bin` instead — `command -v uvx` inside the distro is the authority.

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
| Port 8563 is already taken | Find out what holds it before stopping anything. From PowerShell: `Get-NetTCPConnection -LocalPort 8563 -State Listen`. If it is another Exasol — a Windows install of this kit, or a container in another WSL distro — leave it running and take another port instead: re-run with `EXAKIT_DB_PORT=8564` (the kit records it and later commands reuse it). If it is `wslrelay` left over from an earlier failed run and nothing in WSL needs it, `wsl --shutdown` releases it |
| Database state after `wsl --shutdown` or a Windows reboot | Safe, and normally nothing to do: your data is kept, and a fresh install turns automatic start on, so the container comes back by itself once Docker Desktop is running. If you turned it off (`exakit autostart`) or Docker Desktop is not up yet, `exakit start` brings it back |
| After a reboot, what does *not* come back | Only the database rides Docker Desktop's restart policy. Service add-ons such as dash-server are `systemd --user` units, and a WSL distro runs no user session until something opens it — so they start when you first open a WSL terminal, not at Windows boot. And WSL2 ships with systemd **off**: without `systemd=true` under `[boot]` in `/etc/wsl.conf` (then `wsl --shutdown` from Windows) there is no `systemd --user` at all and nothing was registered. `exakit start` brings everything back in one command |
| This distro is on WSL 1 | Nothing container-based can run there — WSL 1 has no Linux kernel. Convert it from an admin PowerShell, keeping your files: `wsl --set-version <distro> 2` (`wsl -l -v` lists versions), then re-run the installer |
| Using Podman inside WSL instead of Docker Desktop | Supported, and the shared-engine section above does **not** apply: a rootless Podman container is not on Docker Desktop's engine and the Windows side cannot see it. WSL still relays its published port to Windows, so a Windows install will report 8563 as taken — give one of them `EXAKIT_DB_PORT`. Remember that `wsl --shutdown` stops a Podman-hosted database, and that autostart for it goes through `systemd --user` (see the reboot row above) |
| WSL clock drift after laptop sleep | If TLS or downloads act strange: `sudo hwclock -s` |
| This install took over a Windows one (or the other way round) | They share Docker Desktop's engine, and both default to the same container. See [Windows and WSL share one Docker engine](#windows-and-wsl-share-one-docker-engine) — the separation has to be set with `EXAKIT_NANO_CONTAINER` and `EXAKIT_NANO_VOLUME` before installing |
| `$HOME` is on `/mnt/c`, redirected or cloud-synced | **Move the kit off it.** Windows drives are mounted into WSL without Linux file permissions, so the `chmod 600` the kit puts on your database passwords is accepted and does nothing — they end up readable by every Windows user on the machine, and synced to OneDrive if the profile is. Set `EXAKIT_HOME=/home/$USER/exakit` — any path on the Linux filesystem that you already own — **before** the install; it moves state, credentials, logs and the kit copy there. Keep it exported for later `exakit` commands too: put it in `~/.bashrc`, not just the one shell. (For a shared location such as `/opt/exakit`, create it first: `sudo mkdir -p /opt/exakit && sudo chown "$USER" /opt/exakit`. Never run the installer itself with `sudo`.) |
| The repo is already cloned on the Windows side | Install from it instead of downloading: `EXAKIT_LOCAL_KIT=/mnt/c/Users/<you>/src/update-path` before the install command. The kit is copied into `$EXAKIT_HOME`, so `/mnt/c` slowness costs you the copy and nothing after it, and the repo's `.gitattributes` keeps a Windows checkout free of the CRLF endings that would otherwise break the scripts. Same variable serves an air-gapped or proxied machine |

Remove everything: `exakit uninstall` inside WSL. It names the container and the data volume before it asks you to confirm — read them: on a machine that also has a Windows install of the kit, they are the same container and the same volume.
