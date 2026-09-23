# Quickstart: Linux

Gets you from a Linux machine to a local Exasol database with an AI assistant connected. The database is an **Exasol Personal** local deployment, run by the Exasol launcher through Podman. **This is also the WSL path**: a WSL2 distro is Linux to the launcher, so everything below applies inside it. Three things differ there and are called out where they matter — install Podman inside the distro rather than on Windows, keep the kit off `/mnt/c`, and turn systemd on if you want the database back after a reboot.

## What you need

- **Podman** (rootless is fine) — the database runs through it. You do not have to install it first: if it is missing, the installer says so and installs it between the launcher step and the database step. It asks before it does, because that one command needs `sudo`; answer no, or pre-answer with `EXAKIT_INSTALL_PODMAN=0`, and it prints the command for you to run instead.
- 8 GB+ RAM, 20 GB free disk
- **No Python install needed.** The kit uses a system Python 3.11+ if it finds one, and otherwise installs a managed Python for its own use.

Check first (installs nothing):

```bash
curl -fsSL https://raw.githubusercontent.com/krishna-exasol/update-path/main/install.sh | EXAKIT_PREFLIGHT=1 sh
```

Every ✗ line tells you what to fix — a missing Podman is named with the exact package-manager command.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/krishna-exasol/update-path/main/install.sh | sh
```

What happens, in order:

1. Your machine is checked (Podman, RAM, disk) and the plan is shown — a machine that cannot run Exasol Personal is refused before anything is downloaded, with the reason named
2. The Exasol launcher is downloaded and checksum-verified, then deploys the database locally, reachable only from your machine
3. The database is ready, usually in a few minutes
4. exapump (the data tool) is installed, the sample data is loaded and verified
5. The AI bridge is set up with a read-only database login, and your AI clients are connected
6. You get a connection panel with everything you need

The launcher selects and remembers the database's port itself (8563 unless something else held it); `exakit info` shows the one in use, and every later command reads it back from the deployment.

**Inside WSL**, one thing to know: Windows and the WSL distros share one network stack, so an Exasol Personal deployed on the Windows side holds port 8563 inside the distro as well. The kit never adopts a database it cannot authenticate to — it names it ("answers like an Exasol database this kit did not deploy") and asks you to stop it on the other side first (`exakit stop` in PowerShell), then re-run.

## Headless, over SSH

The database and every add-on listen on `127.0.0.1` only, by design — that bind address is not configurable, and opening it is not the answer. To reach them from your laptop, forward the port over SSH (substitute the port `exakit info` shows):

```bash
ssh -N -L 8563:127.0.0.1:8563 you@server     # the database, for a local SQL client
ssh -N -L 5100:127.0.0.1:5100 you@server     # dash-server, then open http://127.0.0.1:5100
```

Clipboard and browser conveniences degrade silently on a headless box (the kit prints what it would have copied); everything else works unchanged.

## Connect your AI assistant

The installer already offered to connect every AI client it detected. To run
that step again — after installing a new client, or if you skipped it — use
`exakit mcp-setup`; it writes the read-only database connection into each
client's own config. Then ask your first question: the
[example questions](../data/example-questions.md) are written against the
bundled sample data, and the full ask → inspect → run → validate loop is in the
[QUICKSTART](../QUICKSTART.md).

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
| No Podman | The installer offers to install it for you at the database step (apt, dnf, yum, zypper, pacman or apk). If you said no, or your package manager is not one it knows, install it yourself (`sudo apt-get install -y podman uidmap`, `sudo dnf install -y podman`) and re-run. Podman specifically: no other container engine substitutes, because the launcher only drives Podman. |
| Rootless Podman | Fully supported and the usual case. Your user needs subordinate id ranges (`/etc/subuid`, `/etc/subgid` — most distros set these up when the user is created) and cgroups v2 (the default on every current distro). |
| Autostart on a headless server | `exakit autostart` registers a systemd **user** unit that runs the launcher's start. A user unit only runs while you have a session, so the kit enables lingering for your user when it can (`loginctl enable-linger`); where that is refused, it says so and names the command an admin has to run. |
| Upgrading the launcher | `exakit update` explains what a launcher update does before asking — including the one-time longer first start after it (the deployment rebuilds part of its runtime once; your data is kept). |
| Where did everything go? | The kit lives in `~/.exasol-starter-kit` (credentials under `credentials/`, logs under `logs/`); the database deployment lives under `~/.exasol/personal/` — **the deployment holds the database software and your data together**. |
| Which database is this? | Exasol Personal, deployed locally by the Exasol launcher through Podman. It is the only runtime the kit installs. |
| I already had the kit, with the database in a container | Re-run the install command. It spots the old installation and asks whether to bring your data across — **Migrate my data** or **Skip and continue**. Neither deletes the old container or its data volume; both stop it, because it holds the port the new database needs. The kit's own sample data is left out of the copy (the install loads it itself). Skipped, or never asked? `exakit migrate docker-nano` does the copy later, into the running database. |
| Removing it | `exakit uninstall` — interactive, and it names what goes, including the deployment and its data. |
