#!/usr/bin/env bash
# runtime-personal.sh — Exasol Personal local runtime module (macOS).
#
# Sourced by setup scripts after common.sh and detect.sh. Installs the Exasol
# launcher from the resolved GitHub release (checksum-verified) and deploys a
# local database with `exasol install local`.
#
# Launcher facts:
#   - release assets: exasol-personal_macOS_{arm64,x86_64}.tar.gz + checksums
#   - local deployment needs macOS with at least 8 GB RAM
#   - deployment state: ~/.exasol/personal/deployments/default
#   - `exasol info` prints connection details for the current deployment
#   - rerunning `exasol install local` with the same preset is safe

EXAKIT_PERSONAL_PORT=8563
EXAKIT_PERSONAL_MIN_RAM_GB="${EXAKIT_PERSONAL_MIN_RAM_GB:-8}"
EXAKIT_PERSONAL_MIN_DISK_GB="${EXAKIT_PERSONAL_MIN_DISK_GB:-20}"
EXAKIT_PERSONAL_BIN="$EXAKIT_BIN_DIR/exasol"
EXAKIT_PERSONAL_DEPLOY_DIR="${EXAKIT_PERSONAL_DEPLOY_DIR:-$HOME/.exasol/personal/deployments/default}"

# personal_check_requirements — the compatibility gate. Incompatible machines
# get a clear explanation and a graceful exit; machines at the bare minimum
# proceed with an explicit warning; comfortable machines get one quiet OK line.
# (Replaces the old "Detected environment" panel: users don't act on a table of
# facts — they act on "this will/won't work and why".)
EXAKIT_PERSONAL_COMFORT_RAM_GB="${EXAKIT_PERSONAL_COMFORT_RAM_GB:-12}"
EXAKIT_PERSONAL_COMFORT_DISK_GB="${EXAKIT_PERSONAL_COMFORT_DISK_GB:-40}"
personal_check_requirements() {
    if [ "$(detect_os)" != "macos" ]; then
        error "This machine is not compatible: the Exasol Personal local deployment is macOS-only in this kit."
        info "On Linux/WSL use the Linux installer (Exasol Nano via Docker/Podman); on Windows use install.ps1."
        die "Incompatible platform: $(detect_os)."
    fi

    _arch="$(detect_arch)"
    if [ "$_arch" = "unsupported" ]; then
        error "This machine is not compatible: no Exasol Personal build exists for the '$(uname -m)' CPU architecture."
        info "Supported architectures: Apple Silicon (arm64) and Intel (x86_64)."
        die "Incompatible CPU architecture: $(uname -m)."
    fi

    _ram="$(detect_ram_gb)"
    _disk="$(detect_free_disk_gb "$HOME")"
    if [ "${EXAKIT_FORCE:-0}" != "1" ]; then
        if [ "$_ram" -eq 0 ]; then
            die "Could not determine this machine's memory. Fix the environment or set EXAKIT_FORCE=1 to install anyway."
        fi
        if [ "$_ram" -lt "$EXAKIT_PERSONAL_MIN_RAM_GB" ]; then
            error "This machine is not compatible: Exasol Personal needs at least ${EXAKIT_PERSONAL_MIN_RAM_GB} GB RAM and this machine has ${_ram} GB."
            info "Nothing was installed. Re-run on a machine with ${EXAKIT_PERSONAL_MIN_RAM_GB}+ GB RAM (or force at your own risk with EXAKIT_FORCE=1)."
            die "Insufficient memory: ${_ram} GB."
        fi
        if [ "$_disk" -eq 0 ]; then
            die "Could not determine free disk space at $HOME. Free up space or set EXAKIT_FORCE=1 to install anyway."
        fi
        if [ "$_disk" -lt "$EXAKIT_PERSONAL_MIN_DISK_GB" ]; then
            error "This machine is not compatible right now: the deployment needs at least ${EXAKIT_PERSONAL_MIN_DISK_GB} GB free disk and $HOME has ${_disk} GB."
            info "Nothing was installed. Free up disk space and re-run (or force at your own risk with EXAKIT_FORCE=1)."
            die "Insufficient free disk space: ${_disk} GB."
        fi
    fi

    # Bare minimum: run, but say what to expect.
    if [ "$_ram" -lt "$EXAKIT_PERSONAL_COMFORT_RAM_GB" ]; then
        warn "Memory is at the bare minimum (${_ram} GB; comfortable: ${EXAKIT_PERSONAL_COMFORT_RAM_GB}+ GB) — the database will run, but expect slower queries and keep other heavy apps closed."
    fi
    if [ "$_disk" -lt "$EXAKIT_PERSONAL_COMFORT_DISK_GB" ]; then
        warn "Free disk is tight (${_disk} GB; comfortable: ${EXAKIT_PERSONAL_COMFORT_DISK_GB}+ GB) — fine for the bundled datasets, but watch space before loading large files."
    fi
    ok "Compatibility check passed (macOS $_arch, ${_ram} GB RAM, ${_disk} GB free)"
}

personal_asset_name() {
    case "$(detect_arch)" in
        arm64)  echo "exasol-personal_macOS_arm64.tar.gz" ;;
        x86_64) echo "exasol-personal_macOS_x86_64.tar.gz" ;;
    esac
}

personal_release_url() {
    echo "https://github.com/${EXAKIT_PERSONAL_REPO}/releases/download/v${EXAKIT_PERSONAL_VERSION}"
}

# personal_deployed_version — the launcher version that created the deployment
# currently on disk; empty (non-zero) when there is no deployment, or its
# version cannot be read.
#
# Read from deployment STATE, never by executing a launcher. The decision this
# feeds has to be made BEFORE any binary is downloaded or installed, and the
# only launcher that could answer `exasol info` may be the very one about to be
# overwritten — so asking it is both too late and unreliable. Two state files
# carry the version, both written into the deployment directory by the launcher:
#   .exasolLauncher.version    the bare version ("2.1.0"), no trailing newline
#   .exasolLauncherState.json  "deploymentVersion": "2.1.0"
# The bare file is preferred (nothing to parse); the JSON is the fallback for a
# deployment that only carries it there. Neither needs python3, so this works on
# a machine where the installer has not reached its Python step yet.
personal_deployed_version() {
    [ -d "$EXAKIT_PERSONAL_DEPLOY_DIR" ] || return 1

    _pdv_raw=""
    _pdv_file="$EXAKIT_PERSONAL_DEPLOY_DIR/.exasolLauncher.version"
    if [ -f "$_pdv_file" ]; then
        _pdv_raw="$(tr -d '[:space:]' < "$_pdv_file" 2>/dev/null || true)"
    fi
    if [ -z "$_pdv_raw" ]; then
        _pdv_state="$EXAKIT_PERSONAL_DEPLOY_DIR/.exasolLauncherState.json"
        if [ -f "$_pdv_state" ]; then
            # Plain BRE, no alternation and no -E: the state file is written as
            # one line, and tr keeps it one line even if that ever changes.
            _pdv_raw="$(tr -d '\012\015' < "$_pdv_state" 2>/dev/null | \
                sed -n 's/.*"deploymentVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        fi
    fi

    _pdv_raw="${_pdv_raw#v}"
    # Only answer with something that actually looks like a version. A truncated,
    # empty or garbage state file must read as "unknown" and let the install
    # proceed — never as a version that could wrongly block it.
    case "$_pdv_raw" in
        ""|*[!0-9A-Za-z.+_-]*) return 1 ;;
    esac
    case "$_pdv_raw" in
        [0-9]*) printf '%s\n' "$_pdv_raw" ;;
        *) return 1 ;;
    esac
}

# personal_deployment_outranks <deployed> <advertised> — true ONLY when the
# deployed version is demonstrably higher, comparing dotted numeric components
# left to right and treating a missing component as 0 (so 2.1 > 2). Anything it
# cannot decide is false: this answer blocks an install, and a refusal must never
# be a guess.
#
# Deliberately not exakit_version_newer: without Python that helper falls back to
# "same major, different tag -> worth inspecting" and answers true in BOTH
# directions, which is the right bias for offering an update and exactly the
# wrong one here — it would refuse a legitimate 2.0.0 -> 2.1.0 upgrade on any
# machine that has no Python runtime yet. This comparison needs no Python at all.
personal_deployment_outranks() {
    # Only the numeric release matters for "can this launcher drive this
    # deployment"; drop any pre-release/build suffix.
    _pdo_a="${1#v}"
    _pdo_b="${2#v}"
    _pdo_a="${_pdo_a%%[!0-9.]*}"
    _pdo_b="${_pdo_b%%[!0-9.]*}"
    [ -n "$_pdo_a" ] && [ -n "$_pdo_b" ] || return 1
    while [ -n "$_pdo_a" ] || [ -n "$_pdo_b" ]; do
        _pdo_ha="${_pdo_a%%.*}"
        _pdo_hb="${_pdo_b%%.*}"
        [ -n "$_pdo_ha" ] || _pdo_ha=0
        [ -n "$_pdo_hb" ] || _pdo_hb=0
        case "$_pdo_ha$_pdo_hb" in *[!0-9]*) return 1 ;; esac
        [ "$_pdo_ha" -gt "$_pdo_hb" ] && return 0
        [ "$_pdo_ha" -lt "$_pdo_hb" ] && return 1
        case "$_pdo_a" in *.*) _pdo_a="${_pdo_a#*.}" ;; *) _pdo_a="" ;; esac
        case "$_pdo_b" in *.*) _pdo_b="${_pdo_b#*.}" ;; *) _pdo_b="" ;; esac
    done
    return 1
}

# personal_refuse_launcher_downgrade — never install a launcher older than the
# deployment already on disk.
#
# A launcher refuses to drive a deployment newer than itself, and says so in a
# wall of its own text ending in usage output:
#   deployment directory is incompatible with this launcher: Deployment version
#   2.1.0 is newer than launcher version 2.0.0 (command install)
# Installing the older launcher therefore does not merely fail — it leaves the
# database undriveable, and every re-run fails identically. The trigger is real:
# maintainers lower the advertised set to withdraw a faulty release, and the
# next installer re-run on a machine already carrying the newer deployment
# breaks it.
#
# `exakit update` already refuses a downgrade (and exakit_update_component
# refuses again at the choke point), but both compare the advertised version
# against the INSTALL RECORD, and neither is on this path: the installer calls
# personal_install_launcher directly and held no version opinion at all. This
# guard is not a copy of that one — it asks a different, more authoritative
# question (what is actually deployed on disk), and it answers it before the
# first byte is downloaded.
personal_refuse_launcher_downgrade() {
    [ -n "${EXAKIT_PERSONAL_VERSION:-}" ] || return 0
    _prd_deployed="$(personal_deployed_version 2>/dev/null || true)"
    [ -n "$_prd_deployed" ] || return 0
    personal_deployment_outranks "$_prd_deployed" "$EXAKIT_PERSONAL_VERSION" || return 0

    error "The Exasol Personal deployment on this machine is version ${_prd_deployed}, which is newer than the launcher version this kit advertises (${EXAKIT_PERSONAL_VERSION})."
    info "A ${EXAKIT_PERSONAL_VERSION} launcher refuses to drive a ${_prd_deployed} deployment, so installing it would leave your database unusable. Nothing was installed or changed."
    info "Deployment: $(ui_tilde "$EXAKIT_PERSONAL_DEPLOY_DIR")"
    info "To install the launcher that matches your deployment, re-run with: EXAKIT_PERSONAL_VERSION=${_prd_deployed}"
    info "To start over on ${EXAKIT_PERSONAL_VERSION} instead, remove the newer deployment first with 'exakit uninstall' — that deletes its data."
    die "Refusing to install launcher ${EXAKIT_PERSONAL_VERSION} over a newer ${_prd_deployed} deployment."
}

# personal_install_launcher — download, verify, and install the `exasol` CLI.
# An already-installed launcher is only accepted if it supports the 'local'
# preset (older releases do not); otherwise the resolved version is installed
# alongside it and preferred.
personal_install_launcher() {
    if [ "${EXAKIT_FORCE_COMPONENT_INSTALL:-0}" != "1" ] && command -v exasol >/dev/null 2>&1; then
        _existing="$(command -v exasol)"
        if "$_existing" install --help 2>/dev/null | grep -w "local" >/dev/null; then
            ok "Exasol launcher already installed: $_existing"
            return 0
        fi
        warn "The installed Exasol launcher ($_existing) does not support the 'local' preset (too old)."
        info "Installing launcher v${EXAKIT_PERSONAL_VERSION} to $EXAKIT_PERSONAL_BIN — your existing launcher is left untouched"
    fi

    # Refuse before acting: from here on the advertised version WILL be written
    # over whatever launcher this kit manages, so the deployment on disk gets its
    # veto now, while nothing has been downloaded or overwritten yet. Deliberately
    # after the early return above: a launcher already on PATH that is new enough
    # for the deployment is kept as it always was, and that case installs nothing
    # to object to.
    personal_refuse_launcher_downgrade

    _asset="$(personal_asset_name)"
    _base="$(personal_release_url)"
    _tmp="$(mktemp -d "${TMPDIR:-/tmp}/exakit-personal.XXXXXX")"

    # The whole step on ONE line. begin_step already set a spinner label, and
    # fetch/run_logged animate it, so every stage here was narrated twice: once
    # live by the spinner, then permanently by an info/ok pair repeating it --
    # four lines carrying two facts, each ✓ restating the bullet above it.
    # EXAKIT_QUIET_DETAIL routes that pair to the LOGFILE and leaves the spinner
    # as the narration. Same save-and-restore bracket as exakit_marketplace_install
    # in common.sh, and for the same reason; warn/error stay ungated there, so a
    # step that says nothing while it works still speaks when it goes wrong.
    #
    # Gated on a terminal: without one ui_spin_begin draws nothing, and quieting
    # the detail as well would leave a CI log silent for the length of a
    # download. Piped or redirected, the info lines stay and nothing changes.
    _pil_prev_label="${EXAKIT_ACTIVE_LABEL:-}"
    _pil_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    [ -t 1 ] && EXAKIT_QUIET_DETAIL=1
    _pil_t0="$(date +%s 2>/dev/null || echo 0)"

    # Re-assigned per phase rather than printed: fetch and run_logged read this
    # at their next ui_spin_begin, so the words change on the operation boundary
    # without a second animator and without restarting the one already running.
    EXAKIT_ACTIVE_LABEL="Downloading Exasol launcher v${EXAKIT_PERSONAL_VERSION}"
    info "Downloading Exasol launcher v${EXAKIT_PERSONAL_VERSION} ($_asset)"
    fetch "$_base/$_asset" "$_tmp/$_asset"
    fetch "$_base/exasol-personal_${EXAKIT_PERSONAL_VERSION}_checksums.txt" "$_tmp/checksums.txt"
    verify_sha256_from_file "$_tmp/$_asset" "$_tmp/checksums.txt"

    EXAKIT_ACTIVE_LABEL="Installing launcher to $(ui_tilde "$EXAKIT_PERSONAL_BIN")"
    info "Installing launcher to $(ui_tilde "$EXAKIT_PERSONAL_BIN")"
    mkdir -p "$EXAKIT_BIN_DIR"
    run_logged tar -xzf "$_tmp/$_asset" -C "$_tmp" || die "Could not extract $_asset"
    _binary="$(find "$_tmp" -name exasol -type f | head -1)"
    [ -n "$_binary" ] || die "The release archive did not contain an 'exasol' binary"
    install -m 755 "$_binary" "$EXAKIT_PERSONAL_BIN" \
        || die "Could not install the Exasol launcher to $EXAKIT_PERSONAL_BIN (is it writable? is the disk full?)."
    push_rollback "rm -f \"$EXAKIT_PERSONAL_BIN\""
    rm -rf "$_tmp"

    EXAKIT_QUIET_DETAIL="$_pil_prev_quiet"
    EXAKIT_ACTIVE_LABEL="$_pil_prev_label"
    # After the restore, never inside it: this one can end in an `ok` reporting
    # that the kit edited the user's shell profile, which is not a line to send
    # to the logfile.
    ensure_path_hint "$EXAKIT_BIN_DIR"
    ok "Exasol launcher v${EXAKIT_PERSONAL_VERSION} installed to $(ui_tilde "$EXAKIT_PERSONAL_BIN") ($(( $(date +%s 2>/dev/null || echo 0) - _pil_t0 ))s)"
}

personal_cli() {
    # Prefer the kit-installed managed launcher; fall back to one on PATH.
    if [ -x "$EXAKIT_PERSONAL_BIN" ]; then
        echo "$EXAKIT_PERSONAL_BIN"
    elif command -v exasol >/dev/null 2>&1; then
        command -v exasol
    else
        echo "$EXAKIT_PERSONAL_BIN"
    fi
}

personal_deployment_exists() {
    [ -d "$EXAKIT_PERSONAL_DEPLOY_DIR" ] && "$(personal_cli)" info >/dev/null 2>&1
}

# personal_deployment_running — is a local Exasol deployment actually up and
# reachable right now? Some launcher versions can answer `exasol info` even
# before the SQL listener exists, so require both signals before reusing an
# existing database.
personal_deployment_running() {
    port_in_use "$EXAKIT_PERSONAL_PORT" && "$(personal_cli)" info >/dev/null 2>&1
}

# personal_db_port_pids — PIDs currently LISTENing on the deployment port.
personal_db_port_pids() {
    command -v lsof >/dev/null 2>&1 || return 0
    lsof -nP -iTCP:"$EXAKIT_PERSONAL_PORT" -sTCP:LISTEN -t 2>/dev/null | sort -u
}

# personal_is_orphan_daemon PID — true only if PID is an Exasol Personal runner
# daemon (the "mac-runner ... __daemon__" forwarder). Scopes cleanup so we never
# kill an unrelated application that happens to hold the port.
personal_is_orphan_daemon() {
    case "$(ps -p "$1" -o command= 2>/dev/null || true)" in
        *mac-runner*__daemon__*) return 0 ;;
        *) return 1 ;;
    esac
}

# personal_reap_orphan_daemon — the Exasol Personal launcher can leave an
# orphaned "mac-runner ... __daemon__" process bound to the database port after
# a failed deploy, or after a destroy that could not find its PID file (it logs
# "VM is not running (no PID file found)"). The orphan then makes the next
# deploy fail with "bind: operation not permitted" on vm.sock and makes MCP
# clients see "Connection reset by peer". Reap only that specific daemon; a
# genuinely foreign process on the port is reported and left untouched.
# Returns 0 if the port ends up free (or was never held), 1 otherwise.
personal_reap_orphan_daemon() {
    # Judge the port by whether a process is actually LISTENing on it, not by a
    # bare TCP connect: after a teardown, client sockets linger in
    # CLOSE_WAIT/TIME_WAIT and would make a connect test wrongly report "in use".
    if ! command -v lsof >/dev/null 2>&1; then
        if port_in_use "$EXAKIT_PERSONAL_PORT"; then
            warn "Port $EXAKIT_PERSONAL_PORT is in use but 'lsof' is unavailable to identify the process; cannot auto-clean a leftover Exasol daemon."
            return 1
        fi
        return 0
    fi

    _listeners="$(personal_db_port_pids)"
    [ -n "$_listeners" ] || return 0   # nothing listening → port is free

    _reaped=""
    for _pid in $_listeners; do
        if personal_is_orphan_daemon "$_pid"; then
            info "Reaping orphaned Exasol runner daemon (pid $_pid) still holding port $EXAKIT_PERSONAL_PORT"
            pkill -P "$_pid" 2>/dev/null || true
            kill "$_pid" 2>/dev/null || true
            _reaped="$_reaped $_pid"
        else
            warn "Port $EXAKIT_PERSONAL_PORT is held by a non-Exasol process (pid $_pid: $(ps -p "$_pid" -o command= 2>/dev/null | cut -c1-80)); leaving it untouched."
        fi
    done

    # Only a foreign listener remains (nothing of ours to reap) → not our port.
    [ -n "$_reaped" ] || return 1

    # Wait for the listener to release the port (SIGTERM path, up to ~5s), then
    # force-kill any survivor and its children and give it a moment to settle.
    _waited=0
    while [ "$_waited" -lt 5 ] && [ -n "$(personal_db_port_pids)" ]; do
        sleep 1
        _waited=$((_waited + 1))
    done
    for _pid in $_reaped; do
        if kill -0 "$_pid" 2>/dev/null; then
            pkill -9 -P "$_pid" 2>/dev/null || true
            kill -9 "$_pid" 2>/dev/null || true
        fi
    done
    _waited=0
    while [ "$_waited" -lt 3 ] && [ -n "$(personal_db_port_pids)" ]; do
        sleep 1
        _waited=$((_waited + 1))
    done

    if [ -n "$(personal_db_port_pids)" ]; then
        warn "Port $EXAKIT_PERSONAL_PORT still has a listening process after reaping the Exasol daemon."
        return 1
    fi
    ok "Freed port $EXAKIT_PERSONAL_PORT (removed a leftover Exasol runner daemon)"
    return 0
}

# --- deployment progress ----------------------------------------------------
# `exasol install local` narrates itself in structured JSON and then prints a
# forty-line connection overview -- none of which the person waiting for a
# database can act on, and all of whose useful parts the kit restates in its own
# closing panel. So the stream is consumed rather than shown: each line is
# matched against the launcher's own milestone messages, and one line is redrawn
# in place with a bar, a percentage and the phase in plain English.
#
# Nothing is lost by hiding it. Every raw line still goes to the logfile exactly
# as before; a copy is kept so a FAILED deploy can print the launcher's own last
# words instead of only a log path; and the launcher's EULA notice -- the one
# part of that output the user genuinely must see -- is replayed afterwards, in
# the launcher's own words rather than a copy of them that could go stale.

# _personal_deploy_milestone <line> — "<pct>|<phase>" for a line that marks
# progress, nothing for any other line.
#
# The strings are the launcher's own log messages, matched as plain substrings
# rather than as JSON so that a switch to text logging keeps working. An
# unrecognised line simply does not move the bar, which is what makes a launcher
# release that renames a message degrade to a slower-looking bar instead of to a
# wrong one. The percentages are milestone positions, not a measured fraction of
# the work: the bar moves only when the launcher has actually reached the next
# stage, and the elapsed counter -- which ticks every second whatever the
# launcher is doing -- is what says "still alive" in between.
_personal_deploy_milestone() {
    case "$1" in
        *"validating presets"*)                    printf '5|10|2|Preparing the deployment' ;;
        *"extracting preset files"*)               printf '10|20|2|Preparing the deployment' ;;
        *"successfully initialized deployment"*)   printf '20|35|5|Preparing the deployment' ;;
        # The long one. On a warm cache the launcher says nothing at all between
        # here and "waiting for database to start" -- about twenty-five seconds
        # of VM boot -- so the ceiling is that next milestone rather than the
        # "starting deployment" one, which a warm run never emits. If it DOES
        # emit it, the line below picks the segment up mid-flight.
        *"fetching resource"*|*"found resource in cache"*)
                                                   printf '35|65|25|Fetching the Exasol runtime' ;;
        *"starting deployment"*)                   printf '45|65|15|Starting the database' ;;
        *"waiting for database to start"*)         printf '65|90|10|Waiting for the database' ;;
        *"installing script language container"*)  printf '80|90|15|Installing script languages' ;;
        *"no installation steps defined"*)         printf '90|100|4|Finishing up' ;;
        *"Completed deploying"*)                   printf '100|100|0|Deployed' ;;
    esac
}

# Eighths of a block. A twenty-cell bar advancing in whole cells steps 5% at a
# time, which at five frames a second reads as a bar that is stuck and then
# jumps. The partial-block glyphs give the same bar eight times the resolution,
# so it creeps. Index 0 is a space: the frontier cell is EMPTY when there is no
# fraction to draw, which is what keeps the dim remainder unbroken.
# _personal_deploy_collect <state-file> <tail-file> <notice-file> — consume the
# launcher's output: log every line, keep the tail, keep the EULA notice, and
# turn the lines that mean something into progress. It runs on the right-hand
# side of the pipe, so everything it learns has to be handed back through files.
_personal_deploy_collect() {
    _pdc_pct=0
    _pdc_phase=""
    _pdc_shown=""
    while IFS= read -r _pdc_line || [ -n "$_pdc_line" ]; do
        [ -n "${EXAKIT_LOG_FILE:-}" ] && printf '%s\n' "$_pdc_line" >> "$EXAKIT_LOG_FILE"
        printf '%s\n' "$_pdc_line" >> "$2"
        case "$_pdc_line" in
            *"End User License Agreement"*|*"terms-and-conditions"*)
                printf '%s\n' "$_pdc_line" >> "$3" ;;
        esac
        _pdc_hit="$(_personal_deploy_milestone "$_pdc_line")"
        [ -n "$_pdc_hit" ] || continue
        # Monotonic: a message arriving out of the expected order never rewinds
        # the bar, and a repeated one never redraws it.
        [ "${_pdc_hit%%|*}" -gt "$_pdc_pct" ] 2>/dev/null || continue
        _pdc_pct="${_pdc_hit%%|*}"
        _pdc_rest="${_pdc_hit#*|}"
        _pdc_ceil="${_pdc_rest%%|*}"; _pdc_rest="${_pdc_rest#*|}"
        _pdc_secs="${_pdc_rest%%|*}"
        _pdc_phase="${_pdc_rest#*|}"
        ui_progress_state "$1" "$_pdc_pct" "$_pdc_ceil" "$_pdc_secs" "$_pdc_phase"
        # Nothing is animating (piped, CI, NO_COLOR, a dumb terminal): one plain
        # logged line per phase, rather than a line that redraws nothing.
        if [ "${EXAKIT_DEPLOY_LIVE:-0}" != 1 ] && [ "$_pdc_phase" != "$_pdc_shown" ]; then
            info "$_pdc_phase"
            _pdc_shown="$_pdc_phase"
        fi
    done
}

# _personal_deploy_print_tail <file> — the launcher's own last words, in the dim
# gutter foreign output has always used here. A failed deploy used to leave the
# whole stream on screen; now that the stream is consumed, the end of it is what
# has to survive, or a failure would be left with nothing but a log path.
_personal_deploy_print_tail() {
    [ -s "$1" ] || return 0
    foreign_note "last lines from the exasol launcher"
    tail -n 12 "$1" | while IFS= read -r _pdt_line; do
        printf '      %s%s %s%s\n' "${UI_DIM:-}" "${UI_VB:-|}" "$_pdt_line" "${UI_RESET:-}"
    done
}

# _personal_deploy_print_notice <file> — replay the launcher's EULA notice. It is
# the one part of the hidden output the user must still see, and it is replayed
# verbatim so this kit never states licence terms in words of its own.
_personal_deploy_print_notice() {
    [ -s "$1" ] || return 0
    _pdn_first=1
    while IFS= read -r _pdn_line; do
        [ -n "$_pdn_line" ] || continue
        if [ "$_pdn_first" = 1 ]; then
            info "$_pdn_line"
            _pdn_first=0
        else
            printf '      %s%s%s\n' "${UI_DIM:-}" "$_pdn_line" "${UI_RESET:-}"
            _exakit_log_file "INFO  $_pdn_line"
        fi
    done < "$1"
}

# personal_deploy_local — run the local deployment. This is the long step
# (usually under 2 minutes); output stays visible and is logged.
personal_deploy_local() {
    # A reachable Exasol is already up (this run, a previous run, or the user
    # started it by hand). `exasol info` is the launcher's own health signal.
    # Checked BEFORE the port test below so a healthy database that legitimately
    # owns port 8563 is offered for reuse rather than reported as a conflict.
    # Ask before adopting it — a piped/non-interactive install defaults to yes
    # (reuse), which is the safe, idempotent choice for automation. Set
    # EXAKIT_REUSE_DB=0 to force a fresh deployment, =1 to reuse without asking.
    if personal_deployment_running; then
        info "An Exasol database is already running and reachable on port $EXAKIT_PERSONAL_PORT."
        if confirm_env EXAKIT_REUSE_DB "Use the running database instead of deploying a new one?" y; then
            ok "Reusing the existing Exasol deployment"
            personal_record_manifest
            return 0
        fi
        die "Declined to reuse the running database. Stop it first ('exakit stop', or 'exasol stop'), then re-run to deploy a fresh one — port $EXAKIT_PERSONAL_PORT stays in use while it is running."
    fi

    # A deployment exists but is not running — cleanly stopped, or a crashed
    # VM. The launcher refuses `install local` over a stopped deployment
    # ("run `start` to restart or `destroy` to delete resources"), so
    # deploying here would dead-end. Adopt it the way a running one is
    # adopted: start it and reuse. A piped/non-interactive install defaults
    # to yes (reuse); EXAKIT_REUSE_DB=0 rebuilds fresh instead, destroying
    # the old deployment's data. A deployment that will not start (a crashed
    # VM) is replaced — announced, never silently.
    if personal_deployment_exists; then
        info "An existing Exasol deployment was found (not running)."
        if confirm_env EXAKIT_REUSE_DB "Start and reuse the existing database instead of deploying a new one?" y; then
            if personal_launcher_supports start && run_logged "$(personal_cli)" start; then
                ok "Reusing the existing Exasol deployment (started)"
                personal_wait_ready
                personal_record_manifest
                return 0
            fi
            warn "The existing deployment could not be started."
        fi
        info "Replacing the existing deployment — its previous data is not recoverable."
        # --auto-approve: destroy has its own [y/N] prompt, which a piped or
        # scripted install cannot answer; the consent came from the reuse
        # question (or EXAKIT_REUSE_DB=0) just above.
        run_logged "$(personal_cli)" destroy --remove --auto-approve || \
            warn "Could not fully remove the old deployment; the launcher will deploy over it."
    fi

    # Port busy but the launcher sees no reachable deployment on it. This is
    # usually our own orphaned runner daemon from a failed deploy or destroy —
    # reap it and continue. Only a genuinely foreign process (another database,
    # a stale container), which the reaper leaves untouched, is a hard stop.
    # EXAKIT_DB_PORT does not apply to the macOS path, so name the real port.
    if port_in_use "$EXAKIT_PERSONAL_PORT"; then
        personal_reap_orphan_daemon || \
            die "Port $EXAKIT_PERSONAL_PORT is in use by a process that is not a reachable Exasol Personal deployment. Stop that application and re-run (EXAKIT_DB_PORT does not apply to the macOS deployment)."
    fi

    # Two points, not three. Deploying and then checking health are one fact to
    # the reader -- the database is up and answering -- so they close on a single
    # line, and the launcher's EULA notice follows as the step's own second
    # point instead of being wedged between them.
    #
    # Safe to leave the notice until last: personal_wait_ready dies if the
    # database never answers, die runs the EXIT trap, and the rollback pushed
    # below destroys this deployment -- so the path that skips the notice is the
    # path where no deployment survives to have accepted anything.
    #
    # Same bracket and the same terminal gate as personal_install_launcher: the
    # progress bar narrates the deploy and the spinner narrates the health
    # probe, so the info/ok pairs underneath are the second telling.
    _pdl_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    [ -t 1 ] && EXAKIT_QUIET_DETAIL=1

    info "Deploying Exasol Personal locally — super quick !"
    push_rollback "$(personal_cli) destroy --remove --auto-approve || true"

    # The launcher's output is consumed, not shown -- see the progress helpers
    # above. Three files carry what the pipeline learns back out of it: the live
    # phase, the tail to print if it fails, and the EULA notice to replay if it
    # succeeds.
    _deploy_tmp="$(mktemp -d "${TMPDIR:-/tmp}/exakit-deploy.XXXXXX")" || \
        die "Could not create a temporary directory for the deployment."
    _deploy_state="$_deploy_tmp/state"
    _deploy_tail="$_deploy_tmp/tail"
    _deploy_notice="$_deploy_tmp/notice"
    _deploy_t0="$(date +%s 2>/dev/null || echo 0)"
    ui_progress_state "$_deploy_state" 0 5 3 "Preparing the deployment"
    : > "$_deploy_tail"
    : > "$_deploy_notice"

    EXAKIT_DEPLOY_LIVE=0
    ui_progress_begin "$_deploy_state" "$_deploy_t0" && EXAKIT_DEPLOY_LIVE=1
    "$(personal_cli)" install local 2>&1 | \
        _personal_deploy_collect "$_deploy_state" "$_deploy_tail" "$_deploy_notice"
    _deploy_rc=${PIPESTATUS[0]}
    ui_progress_end
    EXAKIT_DEPLOY_LIVE=0

    if [ "$_deploy_rc" -ne 0 ]; then
        # Restored before anything explains the failure: the tail below prints
        # through foreign_note, and a step that says nothing while it works must
        # still say everything when it goes wrong.
        EXAKIT_QUIET_DETAIL="$_pdl_prev_quiet"
        _personal_deploy_print_tail "$_deploy_tail"
        rm -rf "$_deploy_tmp"
        die "Local deployment failed. Re-running the installer retries it safely."
    fi

    personal_wait_ready

    EXAKIT_QUIET_DETAIL="$_pdl_prev_quiet"
    # One line for both, and the elapsed covers both -- it is the step's time,
    # not the deploy's alone. The endpoint is the literal fallback
    # personal_record_manifest uses when deployment.json cannot be read; the
    # real DSN is not parsed out of it until a few lines later, and this is the
    # same address either way on the macOS deployment.
    ok "Exasol Personal deployed and answering on 127.0.0.1:${EXAKIT_PERSONAL_PORT} ($(( $(date +%s 2>/dev/null || echo 0) - _deploy_t0 ))s)"
    _personal_deploy_print_notice "$_deploy_notice"
    rm -rf "$_deploy_tmp"

    personal_record_manifest
}

personal_wait_ready() {
    info "Checking deployment health"
    # This probe is silent for five seconds a try, up to thirty tries. Animate
    # it: the step that just stopped showing the launcher's chatter must not
    # then end on a still screen.
    ui_spin_begin "Waiting for the database to answer"
    _tries=0
    while [ "$_tries" -lt 30 ]; do
        if port_in_use "$EXAKIT_PERSONAL_PORT" && "$(personal_cli)" info >/dev/null 2>&1; then
            ui_spin_end
            ok "Deployment is reachable"
            return 0
        fi
        sleep 5
        _tries=$((_tries + 1))
    done
    ui_spin_end
    die "Deployment does not respond to 'exasol info'. Check: $(personal_cli) info"
}

personal_record_manifest() {
    manifest_set runtime.type "personal"
    manifest_set runtime.version "$EXAKIT_PERSONAL_VERSION"
    manifest_set runtime.launcher "$(personal_cli)"
    manifest_set runtime.deployment_dir "$EXAKIT_PERSONAL_DEPLOY_DIR"

    # The deployment directory has everything a client needs:
    #   deployment.json -> host, dbPort, username, cert-validation flag
    #   secrets.json    -> dbPassword
    _dep="$EXAKIT_PERSONAL_DEPLOY_DIR/deployment.json"
    _sec="$EXAKIT_PERSONAL_DEPLOY_DIR/secrets.json"
    if [ -f "$_dep" ]; then
        require_python3
        _conn="$(run_python -c '
import json, sys
doc = json.load(open(sys.argv[1]))
c = doc.get("connection", {})
print("%s:%s\t%s" % (c.get("host", "127.0.0.1"), c.get("dbPort", 8563), c.get("username", "sys")))
' "$_dep" 2>/dev/null)"
        _dsn="$(printf '%s' "$_conn" | cut -f1)"
        _user="$(printf '%s' "$_conn" | cut -f2)"
        # A corrupt/unreadable deployment.json must not record an empty DSN.
        manifest_set runtime.dsn "${_dsn:-127.0.0.1:${EXAKIT_PERSONAL_PORT}}"
        manifest_set runtime.user "${_user:-sys}"
    else
        manifest_set runtime.dsn "127.0.0.1:${EXAKIT_PERSONAL_PORT}"
        manifest_set runtime.user "sys"
    fi
    _password=""
    if [ -f "$_sec" ]; then
        _password="$(run_python -c 'import json,sys; print(json.load(open(sys.argv[1])).get("dbPassword",""))' "$_sec" 2>/dev/null)"
    fi
    if [ -n "$_password" ]; then
        store_credential personal_sys_password "$_password"
        manifest_set runtime.password_file "$EXAKIT_CREDS_DIR/personal_sys_password"
    else
        warn "Could not read the database password from the deployment secrets — the exapump profile and MCP configs will ask for it or need manual completion."
    fi
    manifest_set runtime.tls "self-signed"
    manifest_set runtime.status "healthy"
}

# --- lifecycle (used by exakit) ---------------------------------------------
personal_launcher_supports() {
    # No `grep -q` here: it exits at the first match and closes the pipe, the
    # launcher takes a SIGPIPE (141) writing the rest of its help, and the
    # dispatcher's `set -o pipefail` then fails the whole pipeline — making a
    # supported command look unsupported. Plain grep reads the full help.
    "$(personal_cli)" --help 2>&1 | grep -w "$1" >/dev/null
}

# personal_deployment_wedged — has the launcher marked this deployment as
# INTERRUPTED? That is a third state, and collapsing it into "stopped" is what
# made a crashed database look like a merely idle one.
#
# Reproduced: SIGKILL the runner, and the launcher records
# currentWorkflowState.interrupted and thereafter refuses to start with "local VM
# state contains invalid database port: 0" — forever, because every start attempt
# rewrites the VM state file without ever putting the database port back. `exakit
# start` cannot fix it, and neither can the launcher's own advice to run stop and
# start. Only a redeploy clears it, which personal_deploy_local already knows how
# to do; it just was never reached (see step_artifact_state).
#
# Read from the launcher's own state file rather than by running `exasol status`:
# this is called from `exakit status`, which agents poll, and a file read is free
# where a launcher subprocess is not.
personal_deployment_wedged() {
    [ -n "${EXAKIT_PERSONAL_DEPLOY_DIR:-}" ] || return 1
    _pdw_state="$EXAKIT_PERSONAL_DEPLOY_DIR/.exasolLauncherState.json"
    [ -f "$_pdw_state" ] || return 1
    exakit_can_run_python || return 1
    run_python - "$_pdw_state" <<'EXAKIT_WEDGE_PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as handle:
        doc = json.load(handle)
except (OSError, ValueError):
    sys.exit(1)
state = doc.get("currentWorkflowState")
if not isinstance(state, dict) or "interrupted" not in state:
    sys.exit(1)
detail = state.get("interrupted") or {}
if isinstance(detail, dict) and detail.get("error"):
    print(detail["error"])
sys.exit(0)
EXAKIT_WEDGE_PY
}

# personal_repair_command — the one command that actually clears a wedged
# deployment. Named in every place the wedge is reported, because the state is
# unrecoverable by any gentler route and an agent that is told "stopped" will
# loop on `exakit start` instead.
personal_repair_command() {
    printf 'exakit repair-runtime\n'
}

personal_status() {
    if ! command -v exasol >/dev/null 2>&1 && [ ! -x "$EXAKIT_PERSONAL_BIN" ]; then
        echo "not installed"
    elif personal_deployment_exists; then
        # `exasol info` answers even when the cluster is stopped — the SQL
        # port tells the truth about whether the database is actually up.
        if port_in_use "$EXAKIT_PERSONAL_PORT"; then
            echo "running"
        elif personal_deployment_wedged >/dev/null 2>&1; then
            # Not "stopped": start will fail, and saying stopped sends the
            # reader (and every agent) to a command that cannot work.
            echo "interrupted"
        else
            echo "stopped"
        fi
    else
        echo "not deployed"
    fi
}

personal_start() {
    if personal_launcher_supports start; then
        if ! run_logged "$(personal_cli)" start; then
            # Say what to do, not just that it failed. A start that fails on a
            # wedged deployment fails identically every time it is retried, and
            # "Failed to start the deployment" plus a log path sent readers back
            # to `exakit start` in a loop.
            if personal_deployment_wedged >/dev/null 2>&1; then
                die "The deployment is interrupted and cannot be started — the launcher has to rebuild it. Repair it with: $(personal_repair_command) (this replaces the deployment; its data is not recoverable)."
            fi
            die "Failed to start the deployment. Check the log above, then retry with 'exakit start'; if it fails the same way, repair with: $(personal_repair_command)"
        fi
        ok "Deployment started"
    else
        info "This launcher version has no explicit start command."
        info "Check the deployment with: $(personal_cli) info"
    fi
}

personal_stop() {
    if personal_launcher_supports stop; then
        run_logged "$(personal_cli)" stop || die "Failed to stop the deployment"
        manifest_set runtime.status "stopped"
        # exapump.sh caches a reachable database for the run; this run just
        # ended that. Guarded: the runtime modules load without exapump.sh.
        command -v exakit_forget_db_reachable >/dev/null 2>&1 && exakit_forget_db_reachable
        ok "Deployment stopped"
    else
        info "This launcher version has no explicit stop command."
        info "To remove the deployment entirely use: exakit uninstall"
    fi
}

# personal_teardown [--data] — destroy the local deployment. An Exasol
# Personal deployment keeps runtime and data together, so removing it always
# deletes the database content; without --data we refuse instead of silently
# destroying data the documented contract says would be kept.
personal_teardown() {
    if [ "${1:-}" != "--data" ]; then
        warn "Exasol Personal keeps the runtime and the database content in one deployment — removing it deletes all data."
        info "Use 'exakit stop' to stop it without deleting, or 'exakit uninstall' to remove everything."
        return 1
    fi
    if personal_deployment_exists; then
        info "Destroying the local Exasol Personal deployment"
        # --auto-approve: the launcher's 'destroy' prompts for confirmation by
        # default. run_logged sends its output to the log, so that prompt is
        # invisible and the install just hangs forever waiting for input. The
        # user has already confirmed at the exakit uninstall level.
        run_logged "$(personal_cli)" destroy --remove --auto-approve || warn "Destroy reported errors (see log)"
    else
        info "No active deployment found"
    fi
    # The launcher's destroy can leave an orphaned runner daemon bound to the
    # port when it cannot locate the daemon PID. Reap it unconditionally (even
    # when no deployment was found above, the orphan can outlive the deployment
    # dir) so a future deploy and MCP clients get a clean port.
    personal_reap_orphan_daemon || \
        warn "Could not fully free port $EXAKIT_PERSONAL_PORT; if a later deploy fails to bind it, stop the leftover process holding that port and retry."
    manifest_set runtime.status "removed"
}

personal_upgrade_plan() {
    _current="$1"
    _latest="$2"
    warn "Exasol Personal major upgrade detected: ${_current:-unknown} -> $_latest."
    warn "Personal keeps runtime and database content together in the local deployment."
    info "No destructive action was taken."
    info "Deployment: $EXAKIT_PERSONAL_DEPLOY_DIR"
    info "Step 1: exakit update personal --backup"
    info "Step 2: follow the Exasol Personal $_latest migration/redeployment guidance for your data."
    info "Step 3: exakit update personal --apply"
}

personal_upgrade_backup() {
    _current="$1"
    _latest="$2"
    require_cmd tar "tar"
    [ -d "$EXAKIT_PERSONAL_DEPLOY_DIR" ] || \
        die "No Exasol Personal deployment directory found at $EXAKIT_PERSONAL_DEPLOY_DIR; nothing was backed up."
    if [ "$(personal_status 2>/dev/null || true)" = "running" ] && [ "${EXAKIT_FORCE:-0}" != "1" ]; then
        die "Stop Exasol Personal before backing up for a major upgrade: exakit stop"
    fi

    _backup_dir="$EXAKIT_HOME/backups"
    mkdir -p "$_backup_dir"
    chmod 700 "$_backup_dir" 2>/dev/null || true
    _stamp="$(date +%Y%m%d-%H%M%S)"
    _safe_current="$(printf '%s' "${_current:-unknown}" | tr '/ :' '---')"
    _safe_latest="$(printf '%s' "${_latest:-unknown}" | tr '/ :' '---')"
    _backup="$_backup_dir/personal-upgrade-${_safe_current}-to-${_safe_latest}-${_stamp}.tar.gz"
    _parent="$(dirname "$EXAKIT_PERSONAL_DEPLOY_DIR")"
    _base="$(basename "$EXAKIT_PERSONAL_DEPLOY_DIR")"

    info "Creating Exasol Personal deployment backup"
    if ! tar -czf "$_backup" -C "$_parent" "$_base" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
        rm -f "$_backup"
        die "Could not create the Personal backup; no update was applied."
    fi
    chmod 600 "$_backup" 2>/dev/null || true
    if exakit_can_run_python; then
        manifest_set backups.personal_upgrade.latest "$_backup"
        manifest_set backups.personal_upgrade.created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        manifest_set backups.personal_upgrade.from "${_current:-unknown}"
        manifest_set backups.personal_upgrade.to "$_latest"
    else
        warn "Backup was created, but the manifest could not be updated because no Python runtime is available."
    fi
    ok "Personal deployment backup created: $_backup"
}

personal_update() {
    _mode="default"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --plan) _mode="plan" ;;
            --backup) _mode="backup" ;;
            --apply) _mode="apply" ;;
            *) die "Unknown option '$1' for 'exakit update personal'." ;;
        esac
        shift
    done

    _latest="$(exakit_component_available personal)"
    [ -n "$_latest" ] || die "Could not resolve the advertised Exasol Personal version."
    _current="$(manifest_get runtime.version 2>/dev/null || true)"
    if [ "$_latest" = "$_current" ]; then
        ok "Exasol Personal launcher is already current ($_current)"
        return 0
    fi

    _current_major="$(exakit_major_version "$_current")"
    _latest_major="$(exakit_major_version "$_latest")"
    if [ -n "$_current_major" ] && [ -n "$_latest_major" ] && [ "$_current_major" != "$_latest_major" ]; then
        case "$_mode" in
            plan|default)
                personal_upgrade_plan "$_current" "$_latest"
                [ "$_mode" = "plan" ] && return 0
                return 1
                ;;
            backup)
                personal_upgrade_plan "$_current" "$_latest"
                personal_upgrade_backup "$_current" "$_latest"
                return 0
                ;;
            apply)
                _last_backup="$(manifest_get backups.personal_upgrade.latest 2>/dev/null || true)"
                _backup_from="$(manifest_get backups.personal_upgrade.from 2>/dev/null || true)"
                _backup_to="$(manifest_get backups.personal_upgrade.to 2>/dev/null || true)"
                if [ -z "$_last_backup" ] || [ ! -f "$_last_backup" ]; then
                    die "Create a backup first: exakit update personal --backup"
                fi
                if [ "$_backup_from" != "${_current:-unknown}" ] || [ "$_backup_to" != "$_latest" ]; then
                    die "The latest recorded Personal backup does not match this upgrade (${_current:-unknown} -> $_latest). Run: exakit update personal --backup"
                fi
                info "Updating Exasol Personal launcher ${_current:-unknown} -> $_latest"
                EXAKIT_PERSONAL_VERSION="$_latest"
                EXAKIT_FORCE_COMPONENT_INSTALL=1
                export EXAKIT_PERSONAL_VERSION EXAKIT_FORCE_COMPONENT_INSTALL
                rm -f "$EXAKIT_PERSONAL_BIN"
                personal_install_launcher
                manifest_set runtime.launcher "$(personal_cli)"
                manifest_set runtime.launcher_version "$EXAKIT_PERSONAL_VERSION"
                manifest_set desired.runtime.personal "$EXAKIT_PERSONAL_VERSION"
                warn "Launcher updated. Existing database content was not deleted or migrated."
                info "Complete the Exasol Personal $_latest data migration before recording runtime.version as $_latest."
                ok "Exasol Personal launcher update applied with backup available at $_last_backup"
                return 0
                ;;
        esac
    fi

    info "Updating Exasol Personal launcher ${_current:-unknown} -> $_latest"
    EXAKIT_PERSONAL_VERSION="$_latest"
    EXAKIT_FORCE_COMPONENT_INSTALL=1
    export EXAKIT_PERSONAL_VERSION EXAKIT_FORCE_COMPONENT_INSTALL
    rm -f "$EXAKIT_PERSONAL_BIN"
    personal_install_launcher
    personal_record_manifest
    manifest_set desired.runtime.personal "$EXAKIT_PERSONAL_VERSION"
    ok "Exasol Personal launcher updated; deployment data was not changed"
}
