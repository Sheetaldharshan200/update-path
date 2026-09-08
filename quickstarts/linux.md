# Quickstart: Linux

Gets you from a Linux machine to a local Exasol database with an AI assistant connected. The database runs as the **Exasol Nano** container under Docker or Podman — on WSL, use the [WSL quickstart](windows-wsl.md) instead, which also covers the shared-engine realities of that setup.

## What you need

- A container engine — **Docker** (the daemon running, and your user allowed to use it) or **Podman** (rootless is fine):
  ```bash
  docker ps        # permission denied? -> sudo usermod -aG docker $USER, then log out and back in (or: newgrp docker)
  ```
- 4 GB+ RAM, and free disk on **every filesystem the install writes to**: ~10 GB where the engine stores its data (Docker's data root, or `~/.local/share/containers` for rootless Podman), plus ~3 GB at your home for the kit itself. On a machine whose engine data root sits on a separate volume, both are checked separately.
- **No Python install needed.** The kit uses a system Python 3.11+ if it finds one, and otherwise installs a managed Python for its own use.

Check first (installs nothing):

```bash
curl -fsSL https://raw.githubusercontent.com/krishna-exasol/update-path/main/install.sh | EXAKIT_PREFLIGHT=1 sh
```

Every ✗ line tells you what to fix. The usual ones: the Docker socket permission above, or a stopped daemon (`sudo systemctl start docker`, or `podman machine start` where Podman runs in a VM).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/krishna-exasol/update-path/main/install.sh | sh
```

What happens, in order:

1. Your engine is detected (Docker preferred, Podman as the fallback) and the plan is shown
2. The database container is pulled and started, reachable only from your machine (127.0.0.1:8563)
3. The database is ready, usually in under 2 minutes
4. exapump (the data tool) is installed, the sample data is loaded and verified
5. The AI bridge is set up with a read-only database login, and your AI clients are connected
6. You get a connection panel with everything you need

Port 8563 taken? `EXAKIT_DB_PORT=8564` before the install command — the kit records it and every later command reuses it.

## SELinux (Fedora, RHEL, and friends)

When SELinux is **enforcing**, the kit labels its one bind mount (the database password secret) with `:z` automatically — detected with `getenforce`, whichever engine you run. Nothing to configure; this note exists so a denial in your audit log has a name. Everything else the database touches lives in a named volume, which SELinux handles by itself.

## Rootless Podman: what is different

Rootless Podman is fully supported, with three realities worth knowing:

- **Autostart works through systemd, not the engine.** There is no daemon at boot to honour a container restart policy, so `exakit autostart` registers a systemd **user unit** that starts the container instead — and `exakit status` reports autostart honestly either way.
- **Lingering.** A user unit only runs while you have a session. The kit enables lingering for your user when it can (`loginctl enable-linger`); on a box where that is refused, it says so and names the command an admin has to run. Without lingering, a headless machine will not bring the database back at boot.
- **Preconditions Podman itself needs**: your user must have subordinate id ranges (`/etc/subuid`, `/etc/subgid` — most distros set these up when the user is created) and cgroups v2 (the default on every current distro). The kit binds the database to 127.0.0.1:8563, which is above the unprivileged-port floor, so no sysctl change is needed.

## Headless, over SSH

The database and every add-on listen on `127.0.0.1` only, by design — that bind address is not configurable, and opening it is not the answer. To reach them from your laptop, forward the port over SSH:

```bash
ssh -N -L 8563:127.0.0.1:8563 you@server     # the database, for a local SQL client
ssh -N -L 5100:127.0.0.1:5100 you@server     # dash-server, then open http://127.0.0.1:5100
```

Clipboard and browser conveniences degrade silently on a headless box (the kit prints what it would have copied); everything else works unchanged.

## Everyday commands

```bash
exakit status      # is everything running? (exit 0 = yes)
exakit start       # start the database and services
exakit stop        # stop them
exakit sql 'SELECT 1'
exakit autostart   # asks, then flips start-at-boot; EXAKIT_AUTOSTART_CHANGE=1 pre-answers
exakit update      # bring the kit and its components up to date
```

## Notes

| Situation | What to know |
|---|---|
| Docker vs Podman | Docker is preferred when both are usable; the choice is recorded and reused. `docker ps` failing with *permission denied* means the group fix above, not a reinstall. |
| Headless server | Autostart needs lingering (see above). Everything binds to loopback — forward the port over SSH rather than changing the bind address (see [Headless, over SSH](#headless-over-ssh)). |
| Where did everything go? | The kit lives in `~/.exasol-starter-kit` (credentials under `credentials/`, logs under `logs/`); the database data lives in the `exasol-nano-data` volume inside your engine — **the volume IS the database**. |
| Removing it | `exakit uninstall` — interactive, and it names what goes, including the data volume. |
