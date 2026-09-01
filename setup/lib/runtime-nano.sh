#!/usr/bin/env bash
# runtime-nano.sh — Exasol Nano container runtime module (Linux, WSL, Windows).
#
# Sourced by setup scripts after common.sh and detect.sh. Runs the resolved
# exasol/nano image tag under Docker (preferred) or Podman (fallback), with:
#   - a persistent named volume for /exa (database state survives restarts)
#   - the SQL port bound to localhost only
#   - a generated SYS password injected on first deployment via secret mount
#
# Container contract (from the image documentation):
#   - readiness: logs print "Database is now up and running!"
#   - connection: 127.0.0.1:8563, user sys, TLS (self-signed certificate)
#   - recommended limits: --shm-size=512mb --pids-limit=-1

EXAKIT_NANO_CONTAINER="${EXAKIT_NANO_CONTAINER:-exasol-nano}"
EXAKIT_NANO_VOLUME="${EXAKIT_NANO_VOLUME:-exasol-nano-data}"
EXAKIT_NANO_MIN_RAM_GB="${EXAKIT_NANO_MIN_RAM_GB:-4}"
# Hard floor and comfortable floor for free disk, applied to every filesystem
# this install writes to (see nano_check_disk): the Nano image alone unpacks to
# several GB, and the container's /exa volume grows with the data loaded in.
EXAKIT_NANO_MIN_DISK_GB="${EXAKIT_NANO_MIN_DISK_GB:-10}"
EXAKIT_NANO_ROOMY_DISK_GB="${EXAKIT_NANO_ROOMY_DISK_GB:-20}"
# What $HOME needs when the engine keeps its data on a different filesystem:
# only the kit's own files (credentials, logs, the pyexasol virtual environment).
EXAKIT_NANO_MIN_KIT_DISK_GB="${EXAKIT_NANO_MIN_KIT_DISK_GB:-3}"
EXAKIT_NANO_READY_TIMEOUT="${EXAKIT_NANO_READY_TIMEOUT:-600}"
# Minimal image used only for the self-repair of root-owned state leftovers
# (see nano_repair_creds); pulled on demand, never on the happy path.
EXAKIT_NANO_REPAIR_IMAGE="${EXAKIT_NANO_REPAIR_IMAGE:-docker.io/library/busybox:stable}"

# nano_engine — the usable container engine, cached after first call.
nano_engine() {
    if [ -z "${EXAKIT_NANO_ENGINE:-}" ]; then
        EXAKIT_NANO_ENGINE="$(detect_container_runtime)"
    fi
    echo "$EXAKIT_NANO_ENGINE"
}

# nano_resolve_names — lifecycle commands must act on the names the install
# actually used (recorded in the manifest), not on this shell's defaults.
# An explicit environment override still wins.
nano_resolve_names() {
    if [ "$EXAKIT_NANO_CONTAINER" = "exasol-nano" ]; then
        _mc="$(manifest_get runtime.container 2>/dev/null)"
        [ -n "$_mc" ] && EXAKIT_NANO_CONTAINER="$_mc"
    fi
    if [ "$EXAKIT_NANO_VOLUME" = "exasol-nano-data" ]; then
        _mv="$(manifest_get runtime.volume 2>/dev/null)"
        [ -n "$_mv" ] && EXAKIT_NANO_VOLUME="$_mv"
    fi
}

nano_check_requirements() {
    [ "$(detect_arch)" != "unsupported" ] || \
        die "Unsupported CPU architecture: $(uname -m). Exasol Nano images exist for x86_64 and arm64 only."

    _engine="$(detect_container_runtime_detail)"
    case "$_engine" in
        docker|podman)
            ok "Container runtime: $_engine"
            ;;
        docker-permission)
            # The daemon is up — the USER cannot reach the socket (classic
            # fresh-Linux state: not in the docker group). Say exactly that;
            # "unreachable, start Docker" would send them in circles, and
            # sudo'ing the installer is not the fix (it must run as the user).
            error "Docker is running, but this user is not allowed to use it (permission denied on the Docker socket)."
            printf '    Your user is not in the docker group. Fix it and re-run this installer:\n' >&2
            printf '      1. sudo usermod -aG docker $USER\n' >&2
            printf '      2. log out and back in (or run: newgrp docker)\n' >&2
            printf '      3. confirm it works without sudo: docker ps\n' >&2
            printf '    Do not run this installer with sudo — it must run as your normal user.\n' >&2
            die "No usable container runtime — fix the Docker socket permission, then re-run."
            ;;
        docker-stopped)
            # Docker's CLI is present but its daemon did not respond. Podman was
            # already tried as the fallback (detect_container_runtime checks it
            # second), so tell the user the whole picture: what failed, what was
            # tried, and how to fix either one.
            if command -v podman >/dev/null 2>&1; then
                _podman_hint="Podman was tried as a fallback, but its machine/service is not running either."
                _podman_fix="start it: podman machine start (or: sudo systemctl start podman)"
            else
                _podman_hint="Podman was tried as a fallback, but it is not installed."
                _podman_fix="install it (https://podman.io/docs/installation), then re-run"
            fi
            if wsl_docker_desktop_on_windows; then
                error "Docker is installed but unreachable: Docker Desktop is running on Windows, but it is not connected to this WSL distro."
                printf '    %s\n' "$_podman_hint" >&2
                printf '    Fix either runtime and re-run this installer:\n' >&2
                printf '      Docker:  Docker Desktop > Settings > Resources > WSL integration >\n' >&2
                printf '               turn on this distro, then click Apply & restart\n' >&2
                printf '      Podman:  %s\n' "$_podman_fix" >&2
                die "No usable container runtime — connect Docker Desktop to this distro or provide Podman, then re-run."
            fi
            error "Docker is installed but unreachable (its daemon did not respond)."
            printf '    %s\n' "$_podman_hint" >&2
            printf '    Fix either runtime and re-run this installer:\n' >&2
            printf '      Docker:  start it (e.g. open Docker Desktop, or: sudo systemctl start docker)\n' >&2
            printf '      Podman:  %s\n' "$_podman_fix" >&2
            die "No usable container runtime — start Docker or provide Podman, then re-run."
            ;;
        podman-stopped)
            error "Podman is installed but its machine/service is not running (Docker was not found)."
            printf '    Fix either runtime and re-run this installer:\n' >&2
            printf '      Podman:  podman machine start (or: sudo systemctl start podman)\n' >&2
            printf '      Docker:  install it (https://docs.docker.com/get-docker/)\n' >&2
            die "No usable container runtime — start Podman or install Docker, then re-run."
            ;;
        none)
            error "No container runtime found. Exasol Nano needs Docker or Podman."
            printf '    Install one of:\n' >&2
            printf '      Docker:  https://docs.docker.com/get-docker/\n' >&2
            printf '      Podman:  https://podman.io/docs/installation\n' >&2
            die "Install a container runtime and re-run this script."
            ;;
    esac

    _ram="$(detect_ram_gb)"
    if [ "${EXAKIT_FORCE:-0}" != "1" ]; then
        if [ "$_ram" -eq 0 ]; then
            die "Could not determine this machine's memory. Fix the environment or set EXAKIT_FORCE=1 to install anyway."
        elif [ "$_ram" -lt "$EXAKIT_NANO_MIN_RAM_GB" ]; then
            error "This machine is not compatible: Exasol Nano needs at least ${EXAKIT_NANO_MIN_RAM_GB} GB RAM and this machine has ${_ram} GB."
            info "Nothing was installed. Re-run on a machine with ${EXAKIT_NANO_MIN_RAM_GB}+ GB RAM (or force at your own risk with EXAKIT_FORCE=1)."
            die "Insufficient memory: ${_ram} GB."
        fi
    fi

    nano_check_disk

    # Bare minimum: run, but say what to expect.
    if [ "$_ram" -lt $((EXAKIT_NANO_MIN_RAM_GB + 2)) ]; then
        warn "Memory is at the bare minimum (${_ram} GB) — the database will run, but expect slower queries and keep other heavy apps closed."
    fi
    ok "Compatibility check passed (${_ram} GB RAM, ${EXAKIT_NANO_DISK_SUMMARY:-disk ok})"
}

# nano_check_disk — the disk guard, run against every filesystem this install
# writes to, not just $HOME.
#
# The kit needs room in three places that are not always the same volume:
#   - $HOME              the kit home, the pyexasol venv, downloads, logs
#   - the engine's data root   the image and the container's /exa volume, which
#                              is where nearly all of the space actually goes
#   - the Windows drive under WSL   because `df` inside WSL reports the virtual
#                              disk's nominal size, not the space Windows has
#                              left for it to grow into
# Checking only the first passed installs that then failed mid-pull with "no
# space left on device" and no indication of which disk was full.
#
# Sets EXAKIT_NANO_DISK_SUMMARY for the caller's closing line.
nano_check_disk() {
    _nd_summary=""
    _nd_tight=0

    # <free-gb> <required-gb> <what-for> <where>
    _nd_check() {
        _ndc_free="$1"
        _ndc_need="$2"
        _ndc_what="$3"
        _ndc_where="$4"
        if [ "${EXAKIT_FORCE:-0}" != "1" ]; then
            if [ "$_ndc_free" -eq 0 ]; then
                die "Could not determine free disk space for ${_ndc_what} (${_ndc_where}). Free up space or set EXAKIT_FORCE=1 to install anyway."
            elif [ "$_ndc_free" -lt "$_ndc_need" ]; then
                error "This machine is not compatible right now: ${_ndc_what} needs at least ${_ndc_need} GB free and ${_ndc_where} has ${_ndc_free} GB."
                info "Nothing was installed. Free up disk space at ${_ndc_where} and re-run (or force at your own risk with EXAKIT_FORCE=1)."
                nano_print_reclaimable
                die "Insufficient free disk space: ${_ndc_free} GB at ${_ndc_where}."
            fi
        fi
        [ "$_ndc_free" -lt "$EXAKIT_NANO_ROOMY_DISK_GB" ] && _nd_tight=1
        _nd_summary="${_nd_summary}${_nd_summary:+, }${_ndc_free} GB free at ${_ndc_where}"
        return 0
    }

    # Where the engine really writes: the image and the container's /exa volume,
    # which is where nearly all of the space goes. Frequently NOT $HOME's
    # filesystem — /var/lib/docker often lives on its own volume.
    _nd_home="$(detect_free_disk_gb "$HOME")"
    _nd_docker="$(detect_docker_data_gb)"
    if [ "$_nd_docker" -gt 0 ] && [ "$_nd_docker" -ne "$_nd_home" ]; then
        _nd_check "$_nd_docker" "$EXAKIT_NANO_MIN_DISK_GB" \
            "the database image and container data" "the container engine's data directory"
        # A separate data volume leaves $HOME holding only the kit's own files,
        # so it is judged on that smaller need rather than the database's.
        _nd_check "$_nd_home" "$EXAKIT_NANO_MIN_KIT_DISK_GB" "the kit's own files" "$HOME"
    else
        # One filesystem for both: the full requirement applies to it.
        _nd_check "$_nd_home" "$EXAKIT_NANO_MIN_DISK_GB" \
            "the database image, container data and the kit's own files" "$HOME"
    fi

    # WSL: every number above came from inside the distro, where `df` reports the
    # virtual disk's NOMINAL size (typically 1 TB) and not the space Windows has
    # left for that file to grow into. The Windows system drive is the real
    # constraint, and it is the one a user is most likely to have filled.
    if [ "$(detect_os)" = "wsl" ]; then
        _nd_windows="$(detect_wsl_windows_free_gb)"
        if [ "$_nd_windows" -gt 0 ]; then
            _nd_check "$_nd_windows" "$EXAKIT_NANO_MIN_DISK_GB" \
                "the WSL virtual disk this distro grows into" "the Windows system drive"
        else
            # Not fatal — Windows interop can be switched off — but the checks
            # above provably do not cover this, and silence would imply they did.
            warn "Could not read free space on the Windows system drive from this distro. The numbers above are the WSL virtual disk's, which reports its maximum size, not what Windows has left for it. Check free space on C: in Windows before loading large data."
        fi
    fi

    if [ "$_nd_tight" -eq 1 ]; then
        warn "Free disk is tight (${_nd_summary}) — fine for the bundled datasets, but watch space before loading large files."
        nano_print_reclaimable
    fi
    EXAKIT_NANO_DISK_SUMMARY="$_nd_summary"
    return 0
}

# nano_print_reclaimable — how much of the missing space the engine is already
# sitting on, shown only when space is the problem. Never fails: no answer just
# means no hint.
nano_print_reclaimable() {
    _npr_engine="$(nano_engine)"
    [ -n "$_npr_engine" ] && [ "$_npr_engine" != "none" ] || return 0
    _npr_out="$(exakit_run_bounded 15 "$_npr_engine" system df 2>/dev/null)" || return 0
    [ -n "$_npr_out" ] || return 0
    info "The container engine's current disk usage (reclaim with: $_npr_engine system prune -a):"
    printf '%s\n' "$_npr_out" | while IFS= read -r _npr_line; do
        printf '        %s\n' "$_npr_line"
    done
    return 0
}

nano_image_ref() {
    echo "docker.io/${EXAKIT_NANO_IMAGE}:${EXAKIT_NANO_TAG}"
}

nano_container_exists() {
    "$(nano_engine)" container inspect "$EXAKIT_NANO_CONTAINER" >/dev/null 2>&1
}

nano_container_running() {
    [ "$("$(nano_engine)" container inspect -f '{{.State.Running}}' "$EXAKIT_NANO_CONTAINER" 2>/dev/null)" = "true" ]
}

# nano_ready_in_logs — ready marker from the CURRENT boot only. Container
# logs survive stop/start, so scanning the full history would match a stale
# line from a previous boot; scoping to StartedAt also keeps each poll cheap.
nano_ready_in_logs() {
    _engine="$(nano_engine)"
    _started="$("$_engine" container inspect -f '{{.State.StartedAt}}' "$EXAKIT_NANO_CONTAINER" 2>/dev/null)"
    # Normalize StartedAt to an epoch that `logs --since` accepts on both
    # engines. docker emits RFC3339 ("2026-07-06T05:46:47.33Z"); podman emits
    # Go's default String() form ("2026-07-06 05:46:47.33 +0000 UTC"), which
    # podman's own --since cannot parse — left as-is it silently returns no
    # logs, the marker never matches, and readiness polling loops until timeout.
    _since=""
    if [ -n "$_started" ]; then
        _norm="$(printf '%s' "$_started" | sed -E 's/\.[0-9]+//; s/ UTC$//; s/T/ /')"
        _since="$(date -d "$_norm" +%s 2>/dev/null || true)"
    fi
    # Capture then match, rather than `logs | grep -q`. Under `set -o pipefail`
    # (which exakit and the setup scripts enable), `grep -q` closing the pipe on
    # first match makes `logs` exit with SIGPIPE, and pipefail reports the whole
    # pipeline as failed — so a genuinely-ready DB is misread as "starting".
    if [ -n "$_since" ]; then
        _out="$("$_engine" logs --since "$_since" "$EXAKIT_NANO_CONTAINER" 2>&1)"
    else
        # Fallback: if the timestamp could not be parsed, scan full history
        # rather than loop forever. Risks matching a stale marker from a prior
        # boot, but a false-ready beats a guaranteed timeout.
        _out="$("$_engine" logs "$EXAKIT_NANO_CONTAINER" 2>&1)"
    fi
    case "$_out" in
        *"Database is now up and running!"*) return 0 ;;
        *) return 1 ;;
    esac
}

# nano_has_first_deploy_args — the container was created with the
# first-deploy-only 'init sys_password_file=...' arguments. Nano refuses to
# boot with them once /exa is initialized, so such a container cannot simply
# be restarted — it must be recreated without them (the data volume carries
# the database and its password forward).
nano_has_first_deploy_args() {
    "$(nano_engine)" container inspect -f '{{join .Config.Cmd " "}}' "$EXAKIT_NANO_CONTAINER" 2>/dev/null | \
        grep -q "sys_password_file"
}

# nano_start_existing — bring a stopped container back up, recreating it
# first when it still carries the single-use first-deploy arguments.
nano_start_existing() {
    _engine="$(nano_engine)"
    if nano_has_first_deploy_args; then
        _image="$("$_engine" container inspect -f '{{.Config.Image}}' "$EXAKIT_NANO_CONTAINER" 2>/dev/null)"
        [ -n "$_image" ] || _image="$(nano_image_ref)"
        info "Recreating the Nano container (first-deploy options are single-use; the data volume is kept)"
        run_logged "$_engine" rm -f "$EXAKIT_NANO_CONTAINER" || die "Could not replace the old container (see log)"
        run_logged "$_engine" run -d \
            --name "$EXAKIT_NANO_CONTAINER" \
            --shm-size=512mb \
            --pids-limit=-1 \
            -p "127.0.0.1:${EXAKIT_DB_PORT}:8563" \
            -v "${EXAKIT_NANO_VOLUME}:/exa" \
            "$_image" || nano_die_container_start
    else
        run_logged "$_engine" start "$EXAKIT_NANO_CONTAINER" || \
            die "Could not start existing container $EXAKIT_NANO_CONTAINER (see log)"
    fi
    nano_wait_ready
}

# nano_die_container_start — the engine refused to start the container; say what
# it said.
#
# `docker run` failures are single-line and self-explanatory - "port is already
# allocated", "no space left on device", "invalid mount config for type bind",
# "invalid reference format" - and they have four different fixes. Sending the
# reader to a logfile for one line is the kit refusing to pass on an answer it
# already has (the principle exapump.sh:503 states outright).
nano_die_container_start() {
    if [ -n "${EXAKIT_LOG_FILE:-}" ] && [ -r "${EXAKIT_LOG_FILE}" ]; then
        error "The container engine refused to start the database container:"
        tail -n 5 "$EXAKIT_LOG_FILE" 2>/dev/null | grep -v '^[[:space:]]*$' | while IFS= read -r _ndcs_line; do
            printf '      %s%s %s%s\n' "${UI_ERR:-}" "${UI_VB:-|}" "$_ndcs_line" "${UI_RESET:-}" >&2
        done
    fi
    die "Container failed to start."
}

# nano_creds_poisoned — detect the debris a root Docker daemon leaves behind
# when a container was ever started while the secret file was missing: Docker
# creates the whole missing mount path as root-owned DIRECTORIES on the host.
# The result is a credentials dir this user cannot write into and a
# nano_sys_password that is a directory — every later install then dies with
# a bare "Permission denied" (seen in the wild on WSL).
nano_creds_poisoned() {
    [ -d "${EXAKIT_CREDS_DIR}/nano_sys_password" ] && return 0
    [ -d "$EXAKIT_CREDS_DIR" ] && [ ! -w "$EXAKIT_CREDS_DIR" ] && return 0
    return 1
}

# nano_repair_creds — fix that state WITHOUT sudo: the user cannot delete
# root-owned files, but the container engine's daemon (already a hard
# requirement, already verified usable) runs as root — so let it remove the
# bogus mount-path directory and hand the credentials dir back to this user.
# Falls back to a precise manual remedy if the engine repair does not stick.
nano_repair_creds() {
    nano_creds_poisoned || return 0
    _engine="$(nano_engine)"
    warn "Found root-owned leftovers from an interrupted install in $(ui_tilde "$EXAKIT_CREDS_DIR")"
    info "Repairing them via $_engine (no sudo needed)"
    run_logged "$_engine" run --rm \
        -v "${EXAKIT_CREDS_DIR}:/repair" \
        "$EXAKIT_NANO_REPAIR_IMAGE" \
        sh -c "[ -d /repair/nano_sys_password ] && rm -rf /repair/nano_sys_password; chown -R $(id -u):$(id -g) /repair" || true
    if nano_creds_poisoned; then
        error "Could not repair the credentials directory automatically."
        printf '    An earlier interrupted install left root-owned files in it, and this\n' >&2
        printf '    user (%s) cannot remove them. Remove them once, then re-run:\n' "$(id -un)" >&2
        printf '      sudo rm -rf %s\n' "$EXAKIT_CREDS_DIR" >&2
        die "Credentials directory $EXAKIT_CREDS_DIR is not writable."
    fi
    ok "Credentials directory repaired"
}

# nano_install — pull the resolved image and start the container (first run
# deploys the database with a generated SYS password). Idempotent.
nano_install() {
    _engine="$(nano_engine)"
    _image="$(nano_image_ref)"

    # EXAKIT_REUSE_DB=0 means REPLACE, not adopt.
    #
    # `exakit repair-runtime` sets it, having just told the user the data is not
    # recoverable and taken a yes for it. Without this the two early returns
    # below adopt the very container that repair promised to rebuild, report
    # "already running and healthy", and the command repairs nothing -- and
    # unlike the macOS path there is not even a question to notice it by.
    #
    # The volume goes with the container: it holds /exa, so leaving it would
    # rebuild the container around the same database the repair was called to
    # replace. Order matters -- the engine refuses to remove a volume that a
    # container still uses. ⇄ twin: Install-Nano in nano.ps1.
    if [ "${EXAKIT_REUSE_DB:-1}" = "0" ] && nano_container_exists; then
        info "Replacing the existing Nano container and its data"
        run_logged "$_engine" rm -f "$EXAKIT_NANO_CONTAINER" || \
            warn "Could not remove the existing Nano container; the rebuild may adopt it."
        run_logged "$_engine" volume rm "$EXAKIT_NANO_VOLUME" || \
            warn "Could not remove the existing Nano data volume; the rebuild may reuse its data."
    fi

    if nano_container_running && nano_ready_in_logs; then
        ok "Nano container already running and healthy"
        nano_record_manifest
        return 0
    fi

    if nano_container_exists && ! nano_container_running; then
        info "Found existing Nano container — starting it"
        nano_start_existing
        nano_record_manifest
        return 0
    fi

    # The whole step on ONE line. begin_step set a spinner label and run_logged
    # animates it, so a fresh install narrated itself twice over nine lines: an
    # info/ok pair for the pull, another for the container, and one
    # "Still starting..." every 30 seconds of a wait that can run for ten
    # minutes. EXAKIT_QUIET_DETAIL routes all of that to the LOGFILE and leaves
    # the animation as the narration -- the same save-and-restore bracket
    # exakit_marketplace_install uses in common.sh, with warn/error ungated so a
    # quiet step still speaks when it goes wrong.
    #
    # Gated on a terminal: without one the spinner draws nothing, and quieting
    # the detail as well would leave a CI log silent for the length of a pull.
    # The two early returns above are already one line each and are left alone.
    _ni_prev_label="${EXAKIT_ACTIVE_LABEL:-}"
    _ni_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    [ -t 1 ] && EXAKIT_QUIET_DETAIL=1
    _ni_t0="$(date +%s 2>/dev/null || echo 0)"

    if ! nano_container_exists; then
        if port_in_use "$EXAKIT_DB_PORT"; then
            # Name the holder. "Stop it" is unactionable when "it" is never
            # named, and the holder is often not what the user expects: on a
            # machine with WSL, a failed WSL install leaves wslrelay holding
            # this port long after its container is gone.
            _nip_who="$(port_holder_desc "$EXAKIT_DB_PORT" 2>/dev/null || true)"
            error "Port $EXAKIT_DB_PORT is already taken${_nip_who:+ by $_nip_who}."
            printf '    Free it, or run the database on another port:
' >&2
            printf '      EXAKIT_DB_PORT=8564 %s
' "$(exakit_install_command 2>/dev/null || echo 'bash setup/setup-wsl.sh')" >&2
            die "Port $EXAKIT_DB_PORT is not available."
        fi
        # Re-assigned per phase rather than printed: run_logged reads this at its
        # next ui_spin_begin, so the words change on the operation boundary
        # without starting a second animator.
        EXAKIT_ACTIVE_LABEL="Pulling image $_image"
        info "Pulling image $_image"
        _pulled=0
        for _attempt in 1 2 3; do
            if run_logged "$_engine" pull "$_image"; then
                _pulled=1
                break
            fi
            [ "$_attempt" -lt 3 ] && { warn "Pull attempt $_attempt failed — retrying in $((_attempt * 10))s"; sleep $((_attempt * 10)); }
        done
        [ "$_pulled" -eq 1 ] || die "Image pull failed after 3 attempts: $_image (network/Docker Hub issue — see log)"
        ok "Image pulled"

        # DOES THE DATA VOLUME ALREADY EXIST? This branch only knows that the
        # CONTAINER is absent, which is a different question - a removed
        # container, a partial uninstall or a rolled-back run all leave the
        # volume behind, and that volume IS the database.
        #
        # Deploying over it does two wrong things at once: a freshly generated
        # password is mounted as the first-deploy secret (the real password
        # stays inside the volume, so the new one is a fiction the kit then
        # records), and the single-use `init` arguments are passed over an
        # already-initialised /exa, which the image refuses to boot with.
        #
        # So: adopt it, or replace it on an explicit instruction. Never
        # silently re-initialise it.
        _nano_volume_existed=0
        if "$_engine" volume inspect "$EXAKIT_NANO_VOLUME" >/dev/null 2>&1; then
            _nano_volume_existed=1
        fi
        if [ "$_nano_volume_existed" -eq 1 ] && [ "${EXAKIT_REUSE_DB:-1}" = "0" ]; then
            warn "Replacing the existing database volume $EXAKIT_NANO_VOLUME (EXAKIT_REUSE_DB=0) - its data is being deleted."
            run_logged "$_engine" volume rm "$EXAKIT_NANO_VOLUME" || \
                die "Could not remove the existing data volume $EXAKIT_NANO_VOLUME (see log). Remove it by hand, then re-run."
            _nano_volume_existed=0
        fi

        # First deployment: generate the SYS password up front and hand it to
        # the container as a read-only secret file. It is only applied when
        # /exa is empty; on an existing volume the previous password stays.
        nano_repair_creds
        _password="$(read_credential nano_sys_password)"
        if [ -z "$_password" ]; then
            # An ADOPTED volume already has a password, and it is inside the
            # volume - not here. Minting one now would record a password the
            # database has never heard of, and every later connection would
            # fail against a credential the kit itself reported as correct. Say
            # so instead. (Reachable when the kit home was removed but the
            # volume was not, which a partial uninstall leaves behind.)
            if [ "$_nano_volume_existed" -eq 1 ]; then
                warn "The data volume $EXAKIT_NANO_VOLUME is being adopted, but this machine has no stored password for it."
                info "Its SYS password lives inside the volume, from the install that created it."
                info "If you no longer have it, replace the volume and lose its data with: EXAKIT_REUSE_DB=0"
            fi
            _password="$(generate_password)"
            store_credential nano_sys_password "$_password"
        fi

        # SELinux systems (Fedora, RHEL) need the :z label on bind mounts;
        # harmless elsewhere, so apply it for podman across the board.
        _secret_mount="${EXAKIT_CREDS_DIR}/nano_sys_password:/run/secrets/sys_password:ro"
        [ "$_engine" = "podman" ] && _secret_mount="${_secret_mount},z"

        # The secret must exist as a regular NON-EMPTY file before the engine
        # sees the bind mount. Two distinct hazards, one guard:
        #
        # If the path were missing, a root Docker daemon would create it as a
        # root-owned DIRECTORY on the host - the exact debris nano_repair_creds
        # exists to clean up. Never hand it that chance.
        #
        # And -s, not -f: a ZERO-BYTE secret passes an existence test, and the
        # image then refuses to deploy with
        #     sys_password_file '/run/secrets/sys_password' is empty
        # which surfaces minutes later as a container that started and exited,
        # reported as a startup timeout. One character here turns that whole
        # mystery into a sentence printed before the container is ever created.
        [ -s "${EXAKIT_CREDS_DIR}/nano_sys_password" ] || \
            die "The database password file ${EXAKIT_CREDS_DIR}/nano_sys_password is missing or empty. Delete it and re-run the installer to generate a new one."

        EXAKIT_ACTIVE_LABEL="Starting the Nano container"
        info "Starting Nano container ($EXAKIT_NANO_CONTAINER)"
        # The `init` arguments and the secret mount are FIRST-DEPLOY ONLY. On an
        # adopted volume the database and its password already exist inside it,
        # and the image refuses to boot when handed init options over an
        # initialised /exa - so an adopted volume gets neither.
        if [ "$_nano_volume_existed" -eq 1 ]; then
            info "Adopting the existing database volume $EXAKIT_NANO_VOLUME (its data and password are kept)"
            run_logged "$_engine" run -d \
                --name "$EXAKIT_NANO_CONTAINER" \
                --shm-size=512mb \
                --pids-limit=-1 \
                -p "127.0.0.1:${EXAKIT_DB_PORT}:8563" \
                -v "${EXAKIT_NANO_VOLUME}:/exa" \
                "$_image" || nano_die_container_start
            # No volume rollback: this run did not create it, so undoing this
            # step must never delete it. Only the container is ours to remove.
            push_rollback "$_engine rm -f $EXAKIT_NANO_CONTAINER"
        else
            run_logged "$_engine" run -d \
                --name "$EXAKIT_NANO_CONTAINER" \
                --shm-size=512mb \
                --pids-limit=-1 \
                -p "127.0.0.1:${EXAKIT_DB_PORT}:8563" \
                -v "${EXAKIT_NANO_VOLUME}:/exa" \
                -v "$_secret_mount" \
                "$_image" init sys_password_file=/run/secrets/sys_password || \
                nano_die_container_start
            # run_rollback executes in reverse order: the container must be
            # removed BEFORE its volume, or the engine refuses ("volume in use")
            # and a half-initialized volume is orphaned for the next install.
            #
            # Registered ONLY here, because only here did this run create the
            # volume. Registering it unconditionally meant that answering "yes"
            # to "undo the failed step?" deleted a database the run had merely
            # adopted.
            push_rollback "$_engine volume rm $EXAKIT_NANO_VOLUME"
            push_rollback "$_engine rm -f $EXAKIT_NANO_CONTAINER"
            # Read by nano_wait_ready: only a first deploy may be told to
            # delete the data volume, because only it has nothing to lose.
            EXAKIT_NANO_FIRST_DEPLOY=1
        fi
    fi

    nano_wait_ready
    nano_record_manifest

    EXAKIT_QUIET_DETAIL="$_ni_prev_quiet"
    EXAKIT_ACTIVE_LABEL="$_ni_prev_label"
    ok "Exasol Nano ${EXAKIT_NANO_TAG} running on 127.0.0.1:${EXAKIT_DB_PORT} ($(( $(date +%s 2>/dev/null || echo 0) - _ni_t0 ))s)"
}

# nano_wait_ready — poll container logs until the database reports ready.
#
# Two ways this ends badly, and they are not the same thing: the container can
# EXIT, or it can keep running without ever reporting ready. Both used to die
# with "Nano startup timed out", which is simply false for the first - and it is
# the common one. EXAKIT_NANO_EXITED tells them apart.
nano_wait_ready() {
    EXAKIT_NANO_EXITED=0
    nano_wait_ready_soft && return 0
    if [ "${EXAKIT_NANO_EXITED:-0}" = "1" ]; then
        die "The database container exited before the database came up - the lines above are its own reason."
    fi
    die "The database did not become ready in time."
}

# nano_explain_container_exit <tail> — say which known fatal cause this is.
#
# The container states its own problem plainly and then exits; matching the few
# markers we have seen in the field turns a wall of engine log into one sentence
# with a remedy. Anything unmatched simply gets no extra line: the tail is
# already printed, which is more than the old "(see log)" ever gave.
nano_explain_container_exit() {
    case "$1" in
        *"sys_password_file"*|*"is empty"*)
            printf '    The container was handed an empty password secret.\n' >&2
            printf '    Delete %s/nano_sys_password and re-run the installer.\n' "$EXAKIT_CREDS_DIR" >&2
            ;;
        *"already initialized"*|*"already initialised"*)
            printf '    The data volume %s is already initialised, so the first-deploy\n' "$EXAKIT_NANO_VOLUME" >&2
            printf '    options it was started with cannot apply. Reuse it, or replace it\n' >&2
            printf '    and lose its data, with: EXAKIT_REUSE_DB=0\n' >&2
            ;;
        *"no space left"*)
            printf '    The container ran out of disk. Free space where the engine stores\n' >&2
            printf '    its data, then re-run.\n' >&2
            ;;
    esac
    return 0
}

nano_wait_ready_soft() {
    info "Waiting for the database to come up (timeout: ${EXAKIT_NANO_READY_TIMEOUT}s)"
    # The longest stretch of the install, and the only one with nothing to
    # animate it: the poll below is a plain sleep loop, so under a one-line step
    # the screen would sit still for minutes. The spinner's own elapsed counter
    # is exactly what the "Still starting..." lines were standing in for, in one
    # line that updates in place instead of one more every 30 seconds. Every
    # exit below stops it first -- an abandoned animator paints over whatever
    # the caller prints next.
    ui_spin_begin "Waiting for the database to come up"
    _waited=0
    while [ "$_waited" -lt "$EXAKIT_NANO_READY_TIMEOUT" ]; do
        if ! nano_container_running; then
            ui_spin_end
            # The container had already said why it was dying. Reading the
            # tail STRAIGHT INTO THE LOG FILE and printing "(see log)" threw
            # away an answer the process was holding - and the caller then
            # called it a timeout, which it was not. Keep the tail, log it,
            # and put its last lines on screen where the reader is.
            _nwr_tail="$("$(nano_engine)" logs --tail 30 "$EXAKIT_NANO_CONTAINER" 2>&1)"
            printf '%s
' "$_nwr_tail" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1
            EXAKIT_NANO_EXITED=1
            error "The database container started and then exited. Its last words:"
            printf '%s
' "$_nwr_tail" | grep -v '^[[:space:]]*$' | tail -8 | while IFS= read -r _nwr_line; do
                printf '      %s%s %s%s
' "${UI_ERR:-}" "${UI_VB:-|}" "$_nwr_line" "${UI_RESET:-}" >&2
            done
            nano_explain_container_exit "$_nwr_tail"
            return 1
        fi
        if nano_ready_in_logs; then
            ui_spin_end
            ok "Database is up (took ~${_waited}s)"
            return 0
        fi
        sleep 5
        _waited=$((_waited + 5))
        if [ $((_waited % 30)) -eq 0 ]; then
            # Only where the spinner is NOT already counting. On a terminal it
            # is, and a line printed under a live animator is erased by its next
            # frame within 0.2s -- the defect the table work spent weeks on. The
            # logfile gets the tick either way.
            if [ -t 1 ]; then
                _exakit_log_file "INFO  Still starting... (${_waited}s)"
            else
                info "Still starting... (${_waited}s)"
            fi
        fi
    done
    ui_spin_end
    error "The database did not report ready within ${EXAKIT_NANO_READY_TIMEOUT}s."
    printf '    It may still be coming up. Watch it:  %s logs -f %s\n' \
        "$(nano_engine)" "$EXAKIT_NANO_CONTAINER" >&2
    printf '    Then check again:                     exakit status\n' >&2
    # The reset command below DELETES THE DATABASE, and this function is reached
    # from three places: a first deploy, `exakit start` on an established
    # database, and an update. Printing it unconditionally handed the user whose
    # database was merely slow to come back the one command that destroys every
    # table they ever loaded - framed as a routine remedy, with nothing saying
    # that the volume IS the database. Only the first deploy has nothing to lose.
    if [ "${EXAKIT_NANO_FIRST_DEPLOY:-0}" = "1" ]; then
        printf '    This was a first deployment, so there is no data to lose yet.\n' >&2
        printf '    If the volume was left half-initialized, start over:\n' >&2
        printf '      %s rm -f %s && %s volume rm %s\n' \
            "$(nano_engine)" "$EXAKIT_NANO_CONTAINER" "$(nano_engine)" "$EXAKIT_NANO_VOLUME" >&2
    else
        printf '    Do NOT remove the volume %s - it IS your database.\n' "$EXAKIT_NANO_VOLUME" >&2
        printf '    If the container is genuinely wedged:  exakit repair-runtime\n' >&2
    fi
    return 1
}

nano_record_manifest() {
    manifest_set runtime.type "nano"
    manifest_set runtime.engine "$(nano_engine)"
    manifest_set runtime.image "$(nano_image_ref)"
    manifest_set runtime.container "$EXAKIT_NANO_CONTAINER"
    manifest_set runtime.volume "$EXAKIT_NANO_VOLUME"
    manifest_set runtime.dsn "127.0.0.1:${EXAKIT_DB_PORT}"
    manifest_set runtime.user "sys"
    manifest_set runtime.password_file "$EXAKIT_CREDS_DIR/nano_sys_password"
    manifest_set runtime.tls "self-signed"
    manifest_set runtime.status "healthy"
}

# --- lifecycle (used by exakit) ---------------------------------------------
nano_status() {
    nano_resolve_names
    if ! nano_container_exists; then
        echo "not installed"
    elif ! nano_container_running; then
        echo "stopped"
    elif nano_ready_in_logs; then
        echo "running"
    else
        echo "starting"
    fi
}

nano_start() {
    nano_resolve_names
    nano_container_exists || die "No Nano container found. Run the installer first."
    if nano_container_running; then
        ok "Nano container is already running"
        return 0
    fi
    nano_start_existing
    ok "Nano started"
}

nano_stop() {
    nano_resolve_names
    nano_container_running || { ok "Nano container is not running"; return 0; }
    info "Stopping Nano container (waiting up to 60s for a clean shutdown)"
    run_logged "$(nano_engine)" stop -t 60 "$EXAKIT_NANO_CONTAINER" || die "Failed to stop container"
    manifest_set runtime.status "stopped"
    # exapump.sh caches a reachable database for the run; this run just ended
    # that. Guarded: the runtime modules load without exapump.sh.
    command -v exakit_forget_db_reachable >/dev/null 2>&1 && exakit_forget_db_reachable
    ok "Nano stopped"
}

# nano_teardown [--data] — remove the container; --data also removes the
# persistent volume (all database content).
nano_teardown() {
    nano_resolve_names
    _engine="$(nano_engine)"
    if nano_container_exists; then
        info "Removing Nano container"
        run_logged "$_engine" rm -f "$EXAKIT_NANO_CONTAINER" || warn "Container removal failed"
    else
        warn "No container named '$EXAKIT_NANO_CONTAINER' found — nothing to remove (was it created under a different name?)"
    fi
    if [ "${1:-}" = "--data" ]; then
        if "$_engine" volume inspect "$EXAKIT_NANO_VOLUME" >/dev/null 2>&1; then
            info "Removing data volume $EXAKIT_NANO_VOLUME"
            run_logged "$_engine" volume rm "$EXAKIT_NANO_VOLUME" || warn "Volume removal failed"
        fi
    else
        info "Data volume $EXAKIT_NANO_VOLUME kept (pass --data to remove it)"
    fi
    manifest_set runtime.status "removed"
}

nano_update() {
    nano_resolve_names
    _latest="$(exakit_component_available nano)"
    [ -n "$_latest" ] || die "Could not resolve the advertised Exasol Nano image tag."
    _current="$(exakit_component_current nano 2>/dev/null || true)"
    if [ "$_latest" = "$_current" ]; then
        ok "Exasol Nano is already current ($_current)"
        return 0
    fi

    # The container is recreated, so the database goes down for the duration.
    # Even an explicit `exakit update runtime` asks first; a script pre-answers
    # with EXAKIT_CONFIRM_RUNTIME_UPDATE=1 (an unattended run takes the default,
    # which is yes — the command was asked for explicitly).
    confirm_env EXAKIT_CONFIRM_RUNTIME_UPDATE \
        "Update Exasol Nano ${_current:-unknown} -> ${_latest}? The database stops while the container is recreated; the data volume is kept." y || {
        info "Runtime update cancelled — nothing was changed."
        return 0
    }

    _engine="$(nano_engine)"
    _image="docker.io/${EXAKIT_NANO_IMAGE}:${_latest}"
    _old_image="docker.io/${EXAKIT_NANO_IMAGE}:${_current}"
    _snapshot="$(nano_update_snapshot "$_current" "$_latest")"
    info "Updating Exasol Nano ${_current:-unknown} -> $_latest"
    info "The container will be recreated; the data volume '$EXAKIT_NANO_VOLUME' is kept."
    info "Pre-update runtime snapshot: $_snapshot"
    run_logged "$_engine" pull "$_image" || die "Could not pull $_image"

    if nano_container_exists; then
        if nano_container_running; then
            info "Stopping Nano before recreating the container"
            run_logged "$_engine" stop -t 60 "$EXAKIT_NANO_CONTAINER" || die "Could not stop $EXAKIT_NANO_CONTAINER"
        fi
        run_logged "$_engine" rm -f "$EXAKIT_NANO_CONTAINER" || die "Could not remove old Nano container"
    fi

    info "Starting Nano with the existing data volume"
    run_logged "$_engine" run -d \
        --name "$EXAKIT_NANO_CONTAINER" \
        --shm-size=512mb \
        --pids-limit=-1 \
        -p "127.0.0.1:${EXAKIT_DB_PORT}:8563" \
        -v "${EXAKIT_NANO_VOLUME}:/exa" \
        "$_image" || {
            nano_restore_previous_container "$_old_image"
            die "Could not start updated Nano container; attempted to restore the previous image."
        }
    EXAKIT_NANO_TAG="$_latest"
    export EXAKIT_NANO_TAG
    if ! nano_wait_ready_soft; then
        nano_restore_previous_container "$_old_image"
        die "Updated Nano container did not become ready; attempted to restore the previous image."
    fi
    nano_record_manifest
    manifest_set desired.runtime.nano "$EXAKIT_NANO_TAG"
    manifest_set backups.nano_update.latest "$_snapshot"
    ok "Nano updated; data volume kept: $EXAKIT_NANO_VOLUME"
}

nano_update_snapshot() {
    _current="$1"
    _latest="$2"
    _backup_dir="$EXAKIT_HOME/backups/nano-update"
    _stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    _snapshot="$_backup_dir/${_stamp}-${_current:-unknown}-to-${_latest}.json"
    mkdir -p "$_backup_dir"
    chmod 700 "$EXAKIT_HOME/backups" "$_backup_dir" 2>/dev/null || true
    {
        printf '{\n'
        printf '  "created_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  "operation": "nano_update",\n'
        printf '  "from": "%s",\n' "${_current:-unknown}"
        printf '  "to": "%s",\n' "$_latest"
        printf '  "container": "%s",\n' "$EXAKIT_NANO_CONTAINER"
        printf '  "volume": "%s",\n' "$EXAKIT_NANO_VOLUME"
        printf '  "image": "%s"\n' "$(manifest_get runtime.image 2>/dev/null || true)"
        printf '}\n'
    } > "$_snapshot"
    chmod 600 "$_snapshot" 2>/dev/null || true
    printf '%s\n' "$_snapshot"
}

nano_restore_previous_container() {
    _old_image="$1"
    [ -n "$_old_image" ] && [ "$_old_image" != "docker.io/${EXAKIT_NANO_IMAGE}:" ] || return 0
    warn "Restoring the previous Nano container image ($_old_image)"
    run_logged "$(nano_engine)" rm -f "$EXAKIT_NANO_CONTAINER" || true
    run_logged "$(nano_engine)" run -d \
        --name "$EXAKIT_NANO_CONTAINER" \
        --shm-size=512mb \
        --pids-limit=-1 \
        -p "127.0.0.1:${EXAKIT_DB_PORT}:8563" \
        -v "${EXAKIT_NANO_VOLUME}:/exa" \
        "$_old_image" || warn "Could not restore the previous Nano container automatically."
}
