#!/usr/bin/env bash
# detect.sh — environment detection for the Exasol Personal Local Starter Kit.
#
# Sourced by install.sh and setup-*.sh. Pure read-only checks, no side effects.
# Compatible with bash 3.2 and POSIX sh — every function here must also run
# under dash/ash. The one bash-only feature this file uses, the /dev/tcp probe
# in port_in_use, is now guarded by $BASH_VERSION and has a POSIX fallback, so
# the claim on this line is true rather than aspirational: read it before
# reaching for a bashism.

# detect_os — prints: macos | linux | wsl | unsupported
detect_os() {
    case "$(uname -s)" in
        Darwin)
            echo "macos"
            ;;
        Linux)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        *)
            echo "unsupported"
            ;;
    esac
}

# detect_wsl_version — 1 or 2 for a WSL distro; empty (and non-zero) elsewhere.
#
# /proc/version says "Microsoft" on BOTH WSL versions, so detect_os classifies
# them both as `wsl` — and the install then walks a WSL 1 user into the
# container-runtime remedy, telling them to install Docker on a system that has
# no Linux kernel to run it (Docker Desktop dropped WSL 1 support). The kernel
# RELEASE is what tells them apart: WSL 2 ships a Microsoft kernel whose release
# carries "microsoft-standard" / "WSL2", while WSL 1's emulated release is the
# 4.4.x "-Microsoft" string. Anything unrecognised answers 2: this gates a hard
# refusal, and a guess must never be the thing that blocks a working install.
detect_wsl_version() {
    [ "$(detect_os)" = "wsl" ] || return 1
    _dwv="$(cat /proc/sys/kernel/osrelease 2>/dev/null)"
    case "$_dwv" in
        *WSL2*|*wsl2*|*microsoft-standard*) echo 2 ;;
        4.4.*Microsoft*|4.4.*microsoft*)    echo 1 ;;
        *)                                  echo 2 ;;
    esac
}

# detect_wsl_drvfs_path <path> — true when the path lives on a Windows drive
# mounted into the distro (DrvFs), rather than on the Linux filesystem.
#
# This matters for SECRETS. DrvFs is mounted without the `metadata` option by
# default, so `chmod 600` on it returns success and stores nothing: every file
# keeps mode 0777. The kit's database passwords are plaintext files protected by
# exactly that chmod, so a kit home under /mnt/c leaves them readable by every
# Windows user on the machine — and uploaded, when the profile is OneDrive-backed.
detect_wsl_drvfs_path() {
    [ "$(detect_os)" = "wsl" ] || return 1
    _ddp="${1:-$HOME}"
    case "$_ddp" in
        /mnt/[a-zA-Z]|/mnt/[a-zA-Z]/*) return 0 ;;
    esac
    # A drive mounted somewhere else (or a bind): ask the mount table. DrvFs
    # reports the Windows device itself ("C:\") as its source.
    _ddp_src="$(df -P "$_ddp" 2>/dev/null | awk 'NR == 2 { print $1 }')"
    case "$_ddp_src" in
        [A-Za-z]:*|*drvfs*|*DrvFs*) return 0 ;;
    esac
    return 1
}

# detect_arch — prints: arm64 | x86_64 | unsupported
detect_arch() {
    case "$(uname -m)" in
        arm64|aarch64) echo "arm64" ;;
        x86_64|amd64)  echo "x86_64" ;;
        *)             echo "unsupported" ;;
    esac
}

# detect_cpu_advertises_sve — true when a Linux aarch64 kernel advertises any
# SVE capability. Some hypervisors (seen: VirtualBox on Apple Silicon) expose
# SVE feature bits the host CPU cannot actually execute, so OpenSSL's runtime
# CPU detection picks an SVE code path and dies with SIGILL. Used by the
# pyexasol and MCP validation steps to recognize that crash and self-repair
# (pin OPENSSL_armcap=0 for the affected component).
detect_cpu_advertises_sve() {
    [ "$(uname -s)" = "Linux" ] || return 1
    [ "$(uname -m)" = "aarch64" ] || return 1
    grep -m1 '^Features' /proc/cpuinfo 2>/dev/null | grep -qE '(^| )sve'
}

# detect_sve_remedy_hint — the permanent, system-wide fix for the faked-SVE
# crash, printed wherever the per-component workaround is applied. Kernels
# before ~5.16 ignore arm64.nosve, hence the newer-kernel step.
#
# BRANCHED, because this used to print three Debian/Ubuntu commands to every
# aarch64 Linux: `apt-get`, `linux-generic-hwe-*`, `lsb_release` and
# `update-grub` do not exist on Fedora/RHEL, and NONE of them applies inside
# WSL, where the kernel comes from Windows and there is no GRUB at all. Three
# impossible instructions labelled "permanent fix" is worse than no hint.
detect_sve_remedy_hint() {
    info "This guest advertises SVE support its host CPU cannot execute (common with VirtualBox on Apple Silicon)."
    if [ "$(detect_os)" = "wsl" ]; then
        # WSL boots a kernel Windows supplies; the equivalent of a GRUB edit is
        # .wslconfig on the Windows side, and the equivalent of a reboot is
        # `wsl --shutdown`.
        info "Permanent fix (WSL): add the boot flags on the WINDOWS side, in %USERPROFILE%\\.wslconfig:"
        info "  [wsl2]"
        info "  kernelCommandLine = arm64.nosve arm64.nosme"
        info "Then apply it from PowerShell: wsl --shutdown  (reopen this distro afterwards)"
        return 0
    fi
    info "Permanent fix: run a kernel that honors arm64.nosve and disable SVE at boot:"
    if command -v apt-get >/dev/null 2>&1; then
        info "  sudo apt-get install -y linux-generic-hwe-\$(lsb_release -rs 2>/dev/null || echo 22.04)"
        info "  add 'arm64.nosve arm64.nosme' to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub"
        info "  sudo update-grub && sudo reboot"
    elif command -v grubby >/dev/null 2>&1; then
        info "  sudo grubby --update-kernel=ALL --args='arm64.nosve arm64.nosme'"
        info "  sudo reboot"
    else
        info "  add 'arm64.nosve arm64.nosme' to this machine's kernel command line, then reboot"
        info "  (Debian/Ubuntu: /etc/default/grub then 'sudo update-grub'; Fedora/RHEL: 'sudo grubby --update-kernel=ALL --args=...')"
    fi
    info "A kernel newer than 5.16 is required for the flag to be honored."
}

# detect_ram_gb — total physical memory in whole GB. ALWAYS prints a
# non-negative integer, and 0 when it cannot be determined. This matters:
# callers compare it with `-lt`/`-ge`, and an empty value there makes the test
# error out ("integer expression expected") AND evaluate false — silently
# skipping the requirement guard. Returning 0 instead fails closed.
detect_ram_gb() {
    if [ "$(uname -s)" = "Darwin" ]; then
        _dr_bytes="$(sysctl -n hw.memsize 2>/dev/null)"
        case "$_dr_bytes" in
            ''|*[!0-9]*) _dr_ram=0 ;;
            *)           _dr_ram=$(( _dr_bytes / 1073741824 )) ;;
        esac
    else
        _dr_ram="$(awk '/MemTotal/ { printf "%d", $2 / 1048576 }' /proc/meminfo 2>/dev/null)"
    fi
    case "$_dr_ram" in
        ''|*[!0-9]*) echo 0 ;;
        *)           echo "$_dr_ram" ;;
    esac
}

# detect_free_disk_gb <path> — free space in whole GB. Same fail-closed
# contract as detect_ram_gb: always a non-negative integer, 0 if unknown.
detect_free_disk_gb() {
    _dd="$(df -Pk "${1:-$HOME}" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1048576 }')"
    case "$_dd" in
        ''|*[!0-9]*) echo 0 ;;
        *)           echo "$_dd" ;;
    esac
}

# detect_docker_data_gb — free space in whole GB where the container engine
# actually stores images, containers and volumes. 0 when it cannot be told.
#
# `df $HOME` is not that place. On a Linux host Docker writes to
# /var/lib/docker, which is often a different filesystem from the user's home
# (a separate /var, an LVM volume, a mounted data disk); under Podman it is
# ~/.local/share/containers, which usually is. Guarding the wrong filesystem is
# how an install passes its disk check and then dies mid-pull with "no space
# left on device".
detect_docker_data_gb() {
    _ddd_engine="$(detect_container_runtime)"
    [ "$_ddd_engine" != "none" ] || { echo 0; return; }
    _ddd_root="$(_detect_engine_probe "$_ddd_engine" info --format '{{.DockerRootDir}}' 2>/dev/null | head -n 1)"
    # Podman reports its graph root under a different key; ask for that when the
    # Docker-shaped template comes back empty.
    if [ -z "$_ddd_root" ] && [ "$_ddd_engine" = "podman" ]; then
        _ddd_root="$(_detect_engine_probe podman info --format '{{.Store.GraphRoot}}' 2>/dev/null | head -n 1)"
    fi
    [ -n "$_ddd_root" ] && [ -d "$_ddd_root" ] || { echo 0; return; }
    detect_free_disk_gb "$_ddd_root"
}

# detect_wsl_windows_free_gb — free space in whole GB on the Windows drive
# backing this WSL distro. 0 when this is not WSL, or when it cannot be told.
#
# Inside WSL, `df /` reports the SIZE OF THE VIRTUAL DISK (typically 1 TB), not
# the space left on the Windows volume that file grows into. A WSL install on a
# Windows machine with 3 GB free on C: therefore sailed through the 10 GB disk
# check and failed later, during the image pull, with an error that named
# neither Windows nor C:. Ask Windows directly instead.
detect_wsl_windows_free_gb() {
    [ "$(detect_os)" = "wsl" ] || { echo 0; return; }
    command -v powershell.exe >/dev/null 2>&1 || { echo 0; return; }
    # SystemDrive rather than a hard-coded C:, and whole GB so the value matches
    # every other number in this file. Windows line endings are stripped.
    _dwf="$(powershell.exe -NoProfile -NonInteractive -Command \
        '[math]::Floor((Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID=" + [char]39 + $env:SystemDrive + [char]39)).FreeSpace / 1GB)' \
        2>/dev/null | tr -d '\r\n[:space:]')"
    case "$_dwf" in
        ''|*[!0-9]*) echo 0 ;;
        *)           echo "$_dwf" ;;
    esac
}

# detect_container_runtime — prints the first usable runtime:
#   docker | podman | none
# "Usable" means the CLI exists and the daemon/socket answers.
# `docker info` blocks for as long as Docker Desktop takes to start, so bound it:
# a version lookup must not sit there in silence. detect.sh is also sourced on its
# own by the installer's preflight, before common.sh and the bounded runner exist;
# there the plain call is correct, since preflight is allowed to wait for an engine
# it is specifically reporting on.
_detect_engine_probe() {
    if command -v exakit_run_bounded >/dev/null 2>&1; then
        exakit_run_bounded "${EXAKIT_ENGINE_PROBE_TIMEOUT:-8}" "$@"
    else
        "$@"
    fi
}

detect_container_runtime() {
    if command -v docker >/dev/null 2>&1 && _detect_engine_probe docker info >/dev/null 2>&1; then
        echo "docker"
        return
    fi
    if command -v podman >/dev/null 2>&1 && _detect_engine_probe podman info >/dev/null 2>&1; then
        echo "podman"
        return
    fi
    echo "none"
}

# detect_container_runtime_detail — richer status for error messages:
#   docker | podman | docker-permission | docker-stopped | podman-stopped | none
detect_container_runtime_detail() {
    _usable="$(detect_container_runtime)"
    if [ "$_usable" != "none" ]; then
        echo "$_usable"
        return
    fi
    if command -v docker >/dev/null 2>&1; then
        # Distinguish "the daemon is down" from "the daemon is UP but this
        # user may not talk to it" (typically: not in the docker group, so
        # /var/run/docker.sock refuses with permission denied). The remedies
        # are completely different — telling that user to start a daemon
        # that is already running sends them in circles.
        if docker info 2>&1 | grep -qi 'permission denied'; then
            echo "docker-permission"
            return
        fi
        echo "docker-stopped"
        return
    fi
    if command -v podman >/dev/null 2>&1; then
        echo "podman-stopped"
        return
    fi
    echo "none"
}

# port_listener_pids <port> — the pids of whatever is LISTENING on the port,
# newest tool first, empty when nothing can tell. The one place in the kit that
# answers "who has this port?", so a machine without lsof degrades the same way
# everywhere instead of once per caller.
#
# lsof is on every macOS and on no minimal Linux: a Fedora @core or Ubuntu
# Server image ships iproute2 (`ss`) and nothing else, so an lsof-only probe was
# silently unavailable on exactly the hosts most likely to be running something
# else on a port. ss first on Linux, then lsof, then net-tools' netstat, which is
# still what some older images carry.
port_listener_pids() {
    _plp_port="$1"
    _plp_out=""
    if command -v ss >/dev/null 2>&1; then
        # "LISTEN 0 4096 127.0.0.1:5100 0.0.0.0:* users:(("python3",pid=42,fd=6))"
        # -H is not in older iproute2, so match the address column instead of
        # trusting a header to be absent.
        _plp_out="$(ss -ltnp 2>/dev/null \
            | awk -v p=":$_plp_port" '$4 ~ p"$" { print }' \
            | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p')"
    fi
    if [ -z "$_plp_out" ] && command -v lsof >/dev/null 2>&1; then
        _plp_out="$(lsof -nP -iTCP:"$_plp_port" -sTCP:LISTEN -t 2>/dev/null)"
    fi
    if [ -z "$_plp_out" ] && command -v netstat >/dev/null 2>&1; then
        # net-tools prints "pid/name" in the last column of a LISTEN row.
        _plp_out="$(netstat -ltnp 2>/dev/null \
            | awk -v p=":$_plp_port" '$4 ~ p"$" { print $NF }' \
            | sed -n 's|^\([0-9][0-9]*\)/.*|\1|p')"
    fi
    [ -n "$_plp_out" ] || return 1
    printf '%s\n' "$_plp_out" | sort -u
    return 0
}

# port_holder_desc <port> — "pid N (name)" for whatever is listening, or empty.
#
# "Stop it or set EXAKIT_DB_PORT" is unactionable when "it" is never named, and
# the holder is often not what the user expects: on a Windows machine with WSL,
# a failed WSL install leaves wslrelay holding the port after its container is
# long gone. dash-server has named its port's holder this way for a while
# (_dash_server_port_foreign_desc); the database port deserves the same.
#
# Inside a WSL distro this can still come back empty while the port really is
# taken: Windows and WSL share localhost, and no tool in the distro can see a
# Windows process. The callers say so (runtime-nano.sh's port remedy) rather
# than leaving the reader with an unexplained blank.
port_holder_desc() {
    _phd_port="$1"
    _phd_pid="$(port_listener_pids "$_phd_port" 2>/dev/null | head -1)"
    [ -n "$_phd_pid" ] || return 1
    _phd_name="$(ps -o comm= -p "$_phd_pid" 2>/dev/null | sed 's|.*/||' | tr -d ' ')"
    [ -n "$_phd_name" ] || _phd_name="unknown"
    printf 'pid %s (%s)' "$_phd_pid" "$_phd_name"
    return 0
}

# port_in_use <port> — succeeds when something already listens on the port.
#
# /dev/tcp is a bash/ksh feature, not POSIX: under dash or BusyBox ash the
# redirection simply fails and the function answered "the port is free" — a
# fail-OPEN answer in a file whose every other probe fails closed. Guard it on
# $BASH_VERSION and give the POSIX shells a real probe instead.
port_in_use() {
    _piu_port="$1"
    if [ -n "${BASH_VERSION:-}" ]; then
        (exec 3<>"/dev/tcp/127.0.0.1/$_piu_port") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
        return 1
    fi
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk -v p=":$_piu_port" '$4 ~ p"$" { found = 1 } END { exit !found }' && return 0
        return 1
    fi
    if command -v nc >/dev/null 2>&1; then
        nc -z 127.0.0.1 "$_piu_port" >/dev/null 2>&1 && return 0
        return 1
    fi
    port_listener_pids "$_piu_port" >/dev/null 2>&1 && return 0
    return 1
}

# detect_rootless_podman_gap — one sentence naming a rootless-Podman
# precondition this machine does not meet, with its remedy; empty (and non-zero)
# when the machine looks fine. Cheap: two greps and a file test, no engine call.
#
# The README asks for "Docker or Podman (running)" and stops there, but rootless
# Podman needs two more things and says so only through an engine error the kit
# does not translate:
#   - subordinate id ranges for this user (/etc/subuid, /etc/subgid). Without
#     them `podman info` itself fails with "no subuid ranges found for user".
#   - cgroups v2. The container is started with --pids-limit and --shm-size,
#     and rootless Podman refuses resource limits on a cgroups-v1 host.
# Neither applies to root, to macOS (where Podman runs in a VM), or to Docker.
detect_rootless_podman_gap() {
    [ "$(detect_os)" != "macos" ] || return 1
    [ "$(id -u 2>/dev/null || echo 0)" != "0" ] || return 1
    _drp_user="$(id -un 2>/dev/null || printf '%s' "${USER:-}")"
    [ -n "$_drp_user" ] || return 1
    for _drp_file in /etc/subuid /etc/subgid; do
        # An unreadable or absent file is not evidence of a gap — some
        # distributions manage the ranges elsewhere. Only a readable file that
        # does not list this user is.
        [ -r "$_drp_file" ] || continue
        if ! grep -q "^${_drp_user}:" "$_drp_file" 2>/dev/null; then
            printf 'no user-namespace range for %s in %s — add one with: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 %s && podman system migrate' \
                "$_drp_user" "$_drp_file" "$_drp_user"
            return 0
        fi
    done
    if [ ! -f /sys/fs/cgroup/cgroup.controllers ]; then
        printf 'cgroups v2 is not active, so rootless Podman cannot apply the container resource limits the kit sets — boot with systemd.unified_cgroup_hierarchy=1, or run the database under Docker instead'
        return 0
    fi
    return 1
}

# wsl_docker_desktop_on_windows — inside WSL, use Windows interop to detect
# the classic half-configured state: Docker Desktop IS running on the
# Windows side (docker.exe answers) while this distro cannot reach it,
# i.e. WSL integration is not enabled for this distro.
wsl_docker_desktop_on_windows() {
    [ "$(detect_os)" = "wsl" ] || return 1
    command -v docker.exe >/dev/null 2>&1 || return 1
    docker.exe info >/dev/null 2>&1
}

# preflight_report — check every requirement for this machine and print a
# pass/fail line for each, with the remedy inline. Returns non-zero when a
# hard requirement is missing. Installs nothing; safe to run any time.
preflight_report() {
    _failures=0
    _pf_ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
    _pf_bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*"; _failures=$((_failures + 1)); }
    _pf_note() { printf '  \033[1;33m·\033[0m %s\n' "$*"; }

    _os="$(detect_os)"
    _arch="$(detect_arch)"

    printf 'Preflight check\n'

    # platform
    if [ "$_os" = "unsupported" ]; then
        _pf_bad "Operating system: $(uname -s) is not supported (macOS, Linux, WSL, or Windows via install.ps1)"
    else
        _pf_ok "Operating system: $_os"
    fi
    if [ "$_arch" = "unsupported" ]; then
        _pf_bad "CPU architecture: $(uname -m) is not supported (arm64 or x86_64 required)"
    else
        _pf_ok "CPU architecture: $_arch"
    fi
    # WSL 1 has no Linux kernel, so no container engine can run in it. Said
    # HERE, before the engine check, because the engine check's own remedy
    # ("install Docker") is a loop on this platform: nothing to install helps.
    if [ "$(detect_wsl_version 2>/dev/null)" = "1" ]; then
        _pf_bad "This distro runs on WSL 1, which cannot run a container engine — convert it from an admin PowerShell (files are kept): wsl --set-version <distro> 2 (list them with: wsl -l -v)"
    fi
    # A kit home on a Windows drive cannot hold a protected secret: DrvFs is
    # mounted without Linux permissions, so the chmod 600 on the database
    # passwords is accepted and discarded. Warned BEFORE the install writes one.
    _pf_home="${EXAKIT_HOME:-$HOME/.exasol-starter-kit}"
    if detect_wsl_drvfs_path "$_pf_home" 2>/dev/null; then
        _pf_bad "Kit home $_pf_home is on a Windows drive: WSL mounts those without Linux file permissions, so the database passwords stored there cannot be protected (any Windows user can read them, and OneDrive syncs them) — set EXAKIT_HOME to a path on the Linux filesystem, e.g. EXAKIT_HOME=\$HOME/.exasol-starter-kit"
    fi

    # memory and disk, against the target runtime for this OS
    _ram="$(detect_ram_gb)"
    _disk="$(detect_free_disk_gb "$HOME")"
    if [ "$_os" = "macos" ]; then
        if [ "$_ram" -ge 8 ]; then _pf_ok "Memory: ${_ram} GB (Exasol Personal needs 8+)"
        else _pf_bad "Memory: ${_ram} GB — Exasol Personal needs at least 8 GB; this machine cannot run the kit's macOS path"; fi
        if [ "$_disk" -ge 20 ]; then _pf_ok "Free disk: ${_disk} GB (20+ recommended)"
        else _pf_bad "Free disk: ${_disk} GB — free up space (20 GB recommended for the local database)"; fi
    else
        if [ "$_ram" -ge 4 ]; then _pf_ok "Memory: ${_ram} GB (Exasol Nano needs 4+)"
        else _pf_bad "Memory: ${_ram} GB — Exasol Nano needs at least 4 GB"; fi
        if [ "$_disk" -ge 10 ]; then _pf_ok "Free disk at $HOME: ${_disk} GB (10+ recommended)"
        else _pf_bad "Free disk at $HOME: ${_disk} GB — free up space (10 GB recommended for the database image and data)"; fi

        # The two filesystems $HOME does not speak for. Reported only when they
        # are knowable and different, so an ordinary Linux box still sees one
        # disk line: the container engine's data directory (where the image and
        # the /exa volume actually land) and, under WSL, the Windows drive the
        # virtual disk grows into — `df` inside WSL reports the vhdx's nominal
        # size and will happily claim 1 TB free on a Windows machine with 3 GB.
        _disk_engine="$(detect_docker_data_gb)"
        if [ "$_disk_engine" -gt 0 ] && [ "$_disk_engine" -ne "$_disk" ]; then
            if [ "$_disk_engine" -ge 10 ]; then _pf_ok "Free disk where the container engine stores images: ${_disk_engine} GB (10+ recommended)"
            else _pf_bad "Free disk where the container engine stores images: ${_disk_engine} GB — free up space there (try: docker system prune -a)"; fi
        fi
        _disk_windows="$(detect_wsl_windows_free_gb)"
        if [ "$_disk_windows" -gt 0 ]; then
            if [ "$_disk_windows" -ge 10 ]; then _pf_ok "Free disk on the Windows system drive: ${_disk_windows} GB (10+ recommended; the WSL disk grows into it)"
            else _pf_bad "Free disk on the Windows system drive: ${_disk_windows} GB — the WSL virtual disk grows into it, so free up space on Windows"; fi
        fi
    fi

    # base tools. bash is one of them: install.sh is POSIX sh, but every setup
    # script and library it hands off to is bash, so a bash-less distro fails at
    # the handoff with a bare "exec: bash: not found".
    for _tool in curl tar bash; do
        if command -v "$_tool" >/dev/null 2>&1; then _pf_ok "$_tool available"
        else _pf_bad "$_tool missing — install it with your package manager"; fi
    done
    if command -v python3 >/dev/null 2>&1; then
        # The kit's tooling needs 3.11+ (tomllib); an older system python is
        # fine — the installer switches to its managed runtime automatically.
        if python3 -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3, 11) else 1)' 2>/dev/null; then
            _pf_ok "python3 available"
        else
            _pf_note "python3 available but older than 3.11 — the installer will use its managed Python runtime automatically"
        fi
    elif command -v uv >/dev/null 2>&1 || [ -x "${HOME}/.local/bin/uv" ]; then
        _pf_ok "uv available — it can provide Python automatically"
    elif [ "$_os" = "macos" ]; then
        _pf_note "python3 missing — the installer can bootstrap a managed Python runtime automatically"
    else
        _pf_note "python3 missing — the installer can bootstrap a managed Python runtime automatically"
    fi

    # container runtime (only the Nano platforms need one)
    if [ "$_os" != "macos" ]; then
        case "$(detect_container_runtime_detail)" in
            docker)         _pf_ok "Container runtime: docker (running)" ;;
            podman)
                _pf_ok "Container runtime: podman (running)"
                # Rootless Podman answers `podman info` happily and then fails
                # at `run` when the machine is missing what rootless needs.
                _pf_podman_gap="$(detect_rootless_podman_gap 2>/dev/null || true)"
                [ -n "$_pf_podman_gap" ] && _pf_bad "Rootless Podman: $_pf_podman_gap"
                ;;
            docker-stopped)
                if command -v podman >/dev/null 2>&1; then
                    _pf_podman="Podman (the fallback) is installed but not running either"
                else
                    _pf_podman="Podman (the fallback) is not installed"
                fi
                if wsl_docker_desktop_on_windows; then
                    _pf_bad "Docker is unreachable: Docker Desktop runs on Windows but is not connected to this WSL distro (Docker Desktop > Settings > Resources > WSL integration > enable this distro, Apply & restart); $_pf_podman"
                else
                    _pf_bad "Docker is installed but unreachable (daemon not responding) — start Docker (e.g. Docker Desktop); $_pf_podman"
                fi ;;
            docker-permission)
                # Twin of the same remedy in nano_check_requirements
                # (runtime-nano.sh): both name newgrp, because "log out and back
                # in" is the one instruction that does NOT work in WSL — there is
                # no login session to leave, and the group only takes effect when
                # the distro's init restarts.
                _pf_bad "Docker is running but this user may not use it (permission denied on the Docker socket) — add yourself to the docker group: sudo usermod -aG docker \$USER, then start a session that has it: run 'newgrp docker' in this shell, or log out and back in"
                [ "$_os" = "wsl" ] && _pf_note "On WSL, closing the terminal is not enough: run 'wsl --terminate <distro>' from Windows, then reopen it"
                ;;
            podman-stopped)
                # `podman machine` is the macOS/Windows VM wrapper and does not
                # exist on Linux; `sudo systemctl start podman` starts the ROOT
                # socket, which does nothing for the rootless user the installer
                # insists on being. On Linux the real cause is almost always the
                # user-namespace ranges.
                if [ "$_os" = "macos" ]; then
                    _pf_bad "Podman is installed but its VM is not running (Docker not found) — start it: podman machine start, or install Docker"
                else
                    _pf_podman_gap="$(detect_rootless_podman_gap 2>/dev/null || true)"
                    if [ -n "$_pf_podman_gap" ]; then
                        _pf_bad "Podman is installed but 'podman info' failed (Docker not found): $_pf_podman_gap"
                    else
                        _pf_bad "Podman is installed but 'podman info' failed (Docker not found) — on Linux this is usually the user-namespace ranges: check 'grep \$(id -un) /etc/subuid /etc/subgid'. Using the Podman socket? Start it per user: systemctl --user start podman.socket"
                    fi
                fi ;;
            none)           _pf_bad "No container runtime — install Docker (docs.docker.com/get-docker) or Podman (podman.io)" ;;
        esac
    fi

    # leftover root-owned credentials (a root Docker daemon creates missing
    # bind-mount paths as root-owned directories; an interrupted install can
    # leave them behind — the installer repairs this automatically)
    _pf_creds="${EXAKIT_CREDS_DIR:-$HOME/.exasol-starter-kit/credentials}"
    if [ -d "$_pf_creds/nano_sys_password" ] || { [ -d "$_pf_creds" ] && [ ! -w "$_pf_creds" ]; }; then
        _pf_note "Root-owned leftovers from an interrupted install in $_pf_creds — the installer repairs this automatically via the container engine"
    fi

    # port
    #
    # PROBE THE PORT THE INSTALL WILL ACTUALLY BIND. EXAKIT_DB_PORT only moves
    # the CONTAINER deployments; the macOS deployment always binds 8563. The
    # preflight honoured the variable everywhere, so on a Mac with
    # EXAKIT_DB_PORT=8564 it reported "Port 8564 is free" — a green tick for a
    # port the deploy never touches — and never looked at 8563 at all. The
    # preflight's whole job is to answer "will this work here", so it asks
    # about the right port and drops the knob from the remedy where it does
    # nothing.
    if [ "$(detect_os)" = "macos" ]; then
        _pf_port=8563
    else
        _pf_port="${EXAKIT_DB_PORT:-8563}"
    fi
    if port_in_use "$_pf_port"; then
        if [ "$(detect_os)" = "macos" ]; then
            _pf_note "Port $_pf_port is in use — fine if that is an existing local Exasol (it is adopted); otherwise stop the other application (the macOS deployment cannot use a different port)"
        else
            _pf_note "Port $_pf_port is in use — fine if that is an existing local Exasol; otherwise stop the other application or set EXAKIT_DB_PORT"
        fi
    else
        _pf_ok "Port $_pf_port is free"
    fi

    # network reachability (downloads come from these). Any HTTP response
    # counts as reachable — only connection/DNS/TLS failures matter here.
    _pf_reachable() {
        curl -sI --connect-timeout 5 -o /dev/null "https://$1" 2>/dev/null
    }
    for _endpoint in github.com objects.githubusercontent.com; do
        if _pf_reachable "$_endpoint"; then
            _pf_ok "Network: $_endpoint reachable"
        else
            _pf_bad "Network: cannot reach $_endpoint — check connectivity/proxy (set HTTPS_PROXY if needed)"
        fi
    done
    if [ "$_os" != "macos" ]; then
        if _pf_reachable "registry-1.docker.io/v2/"; then
            _pf_ok "Network: Docker Hub reachable"
        else
            _pf_bad "Network: cannot reach Docker Hub — the Nano image cannot be pulled from this network"
        fi
    fi
    if _pf_reachable "pypi.org"; then
        _pf_ok "Network: pypi.org reachable (MCP server package)"
    else
        _pf_bad "Network: cannot reach pypi.org — the MCP server package cannot be downloaded"
    fi

    printf '\n'
    if [ "$_failures" -eq 0 ]; then
        printf 'All checks passed — this machine can run the starter kit.\n'
    else
        printf '%s requirement(s) missing — fix the items marked ✗ above and re-run.\n' "$_failures"
    fi
    return "$_failures"
}
