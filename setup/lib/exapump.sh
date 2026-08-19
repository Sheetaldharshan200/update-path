#!/usr/bin/env bash
# exapump.sh — exapump installation and connection module.
#
# Sourced by setup scripts after common.sh, detect.sh, and a runtime module.
# Installs the resolved exapump release binary (checksum-verified against the
# digests published by the release API), writes a dedicated connection
# profile, and validates the connection with SELECT 1.
#
# exapump facts:
#   - release assets: exapump-<ver>-{macos,linux}-{aarch64,x86_64}[, .exe]
#   - profiles: ~/.exapump/config.toml (TOML, one section per profile)
#   - SQL from a file: exapump sql -p <profile> < file.sql
#   - CSV/Parquet load: exapump upload <file> --table <schema.table>

EXAKIT_EXAPUMP_PROFILE="${EXAKIT_EXAPUMP_PROFILE:-starter-kit}"
EXAKIT_EXAPUMP_BIN="$EXAKIT_BIN_DIR/exapump"
# ONE definition of where exapump keeps its profiles, and it is overridable.
# The uninstall path used to spell it `rm -rf "$HOME/.exapump"` inline: a test
# that sandboxes EXAKIT_HOME and EXAKIT_BIN_DIR (as every suite here does) but
# not HOME therefore deleted the DEVELOPER'S OWN profile, and the machine only
# said so later, as `Profile 'starter-kit' not found in config` from a command
# that had worked ten minutes earlier. Every reader and the remover now share
# this variable, so sandboxing it once is enough.
EXAKIT_EXAPUMP_CONFIG_DIR="${EXAKIT_EXAPUMP_CONFIG_DIR:-$HOME/.exapump}"
EXAPUMP_CONFIG="$EXAKIT_EXAPUMP_CONFIG_DIR/config.toml"

exapump_asset_name() {
    _ver="$EXAKIT_EXAPUMP_VERSION"
    case "$(detect_os)" in
        macos) _osname="macos" ;;
        *)     _osname="linux" ;;
    esac
    case "$(detect_arch)" in
        arm64)  _archname="aarch64" ;;
        x86_64) _archname="x86_64" ;;
    esac
    echo "exapump-${_ver}-${_osname}-${_archname}"
}

# exapump_expected_sha256 <asset> — the digest the download is verified against:
#
#   1. versions.json, but ONLY when the version being installed is the advertised
#      one. An env override must never borrow another release's digest — that
#      would either fail confusingly or, worse, match the wrong artifact.
#   2. the digests of the release shipped with this kit (below).
#   3. the release API for the version in question.
#
# Empty output means "no digest available"; the caller decides what to do with
# that (it refuses to install unless explicitly overridden).
# ⇄ twin: Get-ExapumpExpectedSha256 in exapump.ps1.
exapump_expected_sha256() {
    _ex_asset="$1"
    _ex_advertised="$(exakit_versions_value components.exapump.version 2>/dev/null || true)"
    if [ -n "$_ex_advertised" ] && [ "$_ex_advertised" = "$EXAKIT_EXAPUMP_VERSION" ]; then
        # The asset name is exapump-<version>-<os>-<arch>, and versions.json keys
        # its digests by that same <os>-<arch> token.
        _ex_platform="${_ex_asset#exapump-${EXAKIT_EXAPUMP_VERSION}-}"
        _ex_digest="$(exakit_versions_value "components.exapump.sha256.${_ex_platform}" 2>/dev/null || true)"
        case "$_ex_digest" in
            *[!0-9a-f]*) _ex_digest="" ;;
        esac
        if [ -n "$_ex_digest" ] && [ "${#_ex_digest}" -eq 64 ]; then
            printf '%s\n' "$_ex_digest"
            return 0
        fi
    fi
    _ex_digest="$(exapump_pinned_sha256 "$_ex_asset")"
    if [ -n "$_ex_digest" ]; then
        printf '%s\n' "$_ex_digest"
        return 0
    fi
    exapump_release_digest_from_api "$_ex_asset"
}

# Digests of the bundled fallback release (published by the release API). When the
# version is overridden the digest is fetched from the API instead.
exapump_pinned_sha256() {
    case "$1" in
        exapump-0.11.2-linux-aarch64)  echo "106c3c5ea168a1381549807b82639137c8b3f94bd64c1b6d02fa380a025d5085" ;;
        exapump-0.11.2-linux-x86_64)   echo "669af4d488e5b1ae2e9c9e030c1be4b1cdb7442dedf3175a361928613f4b3e80" ;;
        exapump-0.11.2-macos-aarch64)  echo "e1438c69f26cdcca69ad1b7211aa9495524c53ff1badebee91d5a631c503616b" ;;
        exapump-0.11.2-macos-x86_64)   echo "1dd68d2dbc2d556e1613975eeffb25813f1ec60e06e93d514d5dd86df8144648" ;;
        *) echo "" ;;
    esac
}

exapump_release_digest_from_api() {
    _json="$(curl -fsSL --retry 3 --connect-timeout 15 \
        "https://api.github.com/repos/${EXAKIT_EXAPUMP_REPO}/releases/tags/v${EXAKIT_EXAPUMP_VERSION}" \
        2>/dev/null || true)"
    [ -n "$_json" ] || return 1
    if exakit_can_run_python; then
        printf '%s' "$_json" | run_python -c '
import json, sys
name = sys.argv[1]
doc = json.load(sys.stdin)
for asset in doc.get("assets", []):
    if asset["name"] == name and asset.get("digest", "").startswith("sha256:"):
        print(asset["digest"].split(":", 1)[1])
        break
' "$1"
        return $?
    fi
    # Best-effort shell fallback for GitHub's asset object. If this misses, the
    # caller already warns and continues rather than pretending verification ran.
    printf '%s' "$_json" | tr '{' '\n' | awk -v name="$1" '
        index($0, "\"name\":\"" name "\"") || index($0, "\"name\": \"" name "\"") {
            if (match($0, /"digest"[[:space:]]*:[[:space:]]*"sha256:[^"]+"/)) {
                digest = substr($0, RSTART, RLENGTH)
                sub(/^.*sha256:/, "", digest)
                sub(/"$/, "", digest)
                print digest
                exit
            }
        }'
}

exapump_cli() {
    if [ -x "$EXAKIT_EXAPUMP_BIN" ]; then
        echo "$EXAKIT_EXAPUMP_BIN"
    elif command -v exapump >/dev/null 2>&1; then
        command -v exapump
    else
        echo "$EXAKIT_EXAPUMP_BIN"
    fi
}

exapump_install() {
    [ "$(detect_arch)" != "unsupported" ] || \
        die "Unsupported CPU architecture: $(uname -m). exapump binaries exist for x86_64 and arm64 only."

    if [ "${EXAKIT_FORCE_COMPONENT_INSTALL:-0}" != "1" ] && { command -v exapump >/dev/null 2>&1 || [ -x "$EXAKIT_EXAPUMP_BIN" ]; }; then
        # Trust the existing binary only if it actually runs — an interrupted
        # earlier download can leave a broken file at the same path.
        if "$(exapump_cli)" --version >/dev/null 2>&1; then
            ok "exapump already installed: $(exapump_cli)"
            exapump_record_manifest
            return 0
        fi
        # A binary that fails on the dynamic linker is not a broken download —
        # it is intact but needs a newer glibc than this system has. Shim it
        # in place instead of re-downloading the same incompatible bytes.
        # (Only for the kit-managed path: a foreign exapump elsewhere on PATH
        # falls through to a fresh, kit-managed install below.)
        if [ -x "$EXAKIT_EXAPUMP_BIN" ]; then
            _existing_err="$("$EXAKIT_EXAPUMP_BIN" --version 2>&1 || true)"
            case "$_existing_err" in
                *GLIBC_*)
                    exapump_install_glibc_shim
                    exapump_record_manifest
                    return 0
                    ;;
            esac
        fi
        warn "Existing exapump binary does not run (interrupted download?) — reinstalling"
        rm -f "$EXAKIT_EXAPUMP_BIN"
    fi

    _asset="$(exapump_asset_name)"
    _url="https://github.com/${EXAKIT_EXAPUMP_REPO}/releases/download/v${EXAKIT_EXAPUMP_VERSION}/${_asset}"
    _tmp="$(mktemp "${TMPDIR:-/tmp}/exakit-exapump.XXXXXX")"

    info "Downloading exapump v${EXAKIT_EXAPUMP_VERSION} ($_asset)"
    fetch "$_url" "$_tmp"

    _expected="$(exapump_expected_sha256 "$_asset" 2>/dev/null || true)"
    if [ -n "$_expected" ]; then
        verify_sha256 "$_tmp" "$_expected"
    elif [ "${EXAKIT_ALLOW_UNVERIFIED_EXAPUMP:-0}" = "1" ]; then
        warn "No digest available for $_asset — proceeding WITHOUT checksum verification (EXAKIT_ALLOW_UNVERIFIED_EXAPUMP=1)."
    else
        # Match the launcher's bar: never install a downloaded-and-executed
        # binary we could not verify. For an advertised version the digest comes
        # from versions.json, and for the shipped one from the pinned table, so
        # this only fires on a version this kit knows nothing about plus an
        # unreachable release API — which should fail loudly rather than run
        # unverified code.
        rm -f "$_tmp"
        die "No checksum available for $_asset; refusing to install an unverified exapump binary. Add its digest to versions.json (components.exapump.sha256) or check network access to the release API. Override at your own risk with EXAKIT_ALLOW_UNVERIFIED_EXAPUMP=1."
    fi

    mkdir -p "$EXAKIT_BIN_DIR"
    install -m 755 "$_tmp" "$EXAKIT_EXAPUMP_BIN" \
        || die "Could not install exapump to $EXAKIT_EXAPUMP_BIN (is it writable? is the disk full?)."
    push_rollback "rm -f \"$EXAKIT_EXAPUMP_BIN\""
    rm -f "$_tmp"
    ensure_path_hint "$EXAKIT_BIN_DIR"
    # Smoke-test the freshly installed binary BEFORE reporting success. A
    # checksum only proves the download is intact, not that it can launch:
    # release binaries link against a glibc newer than several supported
    # distros ship (e.g. Ubuntu 22.04's 2.35 vs the required 2.38+), and an
    # un-launchable binary would otherwise surface 30s later as an opaque
    # "SELECT 1 failed" after the connection retries.
    exapump_verify_runs
    ok "exapump installed: $EXAKIT_EXAPUMP_BIN"
    exapump_record_manifest
}

# exapump_verify_runs — prove the installed binary launches. On the known
# failure (dynamic-linker GLIBC version mismatch) self-repair with the
# container shim; anything else is a hard, explained failure.
exapump_verify_runs() {
    _evr_err="$("$EXAKIT_EXAPUMP_BIN" --version 2>&1)" && return 0
    _exakit_log_file "ERR   exapump --version failed: $_evr_err"
    case "$_evr_err" in
        *GLIBC_*)
            exapump_install_glibc_shim
            ;;
        *)
            die "exapump was installed but does not run: ${_evr_err:-unknown error}. See ${EXAKIT_LOG_FILE:-the log} and https://github.com/${EXAKIT_EXAPUMP_REPO}/issues"
            ;;
    esac
}

# exapump_install_glibc_shim — the exapump release binary needs a newer glibc
# than this system provides (all published Linux builds currently require
# 2.38+, while e.g. Ubuntu 22.04 LTS and every other Jammy-era distro ship
# 2.35). The Linux install path already requires a container runtime for the
# database, so run the real binary inside a small newer-glibc container with
# host networking instead of failing the install. The wrapper is transparent
# to every caller: same path, same CLI, profiles and data files under $HOME
# and /tmp remain visible.
EXAKIT_EXAPUMP_SHIM_IMAGE="${EXAKIT_EXAPUMP_SHIM_IMAGE:-docker.io/library/ubuntu:24.04}"
exapump_install_glibc_shim() {
    _shim_runtime="$(detect_container_runtime)"
    # Rootless podman remaps ownership inside the container: without
    # keep-id the user's own files (profile at ~/.exapump, mode 600) appear
    # root-owned and unreadable to the -u uid. Docker has no such remap and
    # no such flag.
    _shim_userns=""
    [ "$_shim_runtime" = "podman" ] && _shim_userns="--userns=keep-id"
    _sys_glibc="$(ldd --version 2>/dev/null | head -1)"
    warn "The exapump release binary needs a newer glibc than this system provides (${_sys_glibc:-unknown glibc})."
    if [ "$_shim_runtime" = "none" ]; then
        die "exapump cannot run on this system's glibc and no container runtime is available to shim it. Install Docker or Podman and re-run, or use a distro with glibc 2.38+ (e.g. Ubuntu 24.04)."
    fi
    info "Self-repair: running exapump inside a $EXAKIT_EXAPUMP_SHIM_IMAGE container via $_shim_runtime"

    _shim_real_dir="$EXAKIT_HOME/libexec"
    _shim_real="$_shim_real_dir/exapump-real"
    mkdir -p "$_shim_real_dir" || die "Could not create $_shim_real_dir (is the disk full?)."
    mv "$EXAKIT_EXAPUMP_BIN" "$_shim_real" \
        || die "Could not move the exapump binary to $_shim_real."
    chmod 755 "$_shim_real"

    run_logged "$_shim_runtime" pull "$EXAKIT_EXAPUMP_SHIM_IMAGE" \
        || die "Could not pull $EXAKIT_EXAPUMP_SHIM_IMAGE with $_shim_runtime (see log). Check network access and re-run."

    # $HOME/$PWD/id expand at RUN time (quoted heredoc); the runtime, image,
    # and real-binary path are baked in below with a safe substitution.
    cat > "$EXAKIT_EXAPUMP_BIN" <<'EXAKIT_SHIM_EOF'
#!/bin/sh
# exapump glibc shim — generated by the Exasol Personal Local Starter Kit.
# The exapump release binary requires a newer glibc than this system has, so
# it runs inside a container with host networking. The real binary lives at
# the path baked in below; re-running the installer regenerates this wrapper.
# Files are visible to exapump only under $HOME and /tmp.
if [ -t 0 ] && [ -t 1 ]; then _exakit_tty="-it"; else _exakit_tty="-i"; fi
case "$PWD" in
    "$HOME"*|/tmp*) _exakit_wd="$PWD" ;;
    *)              _exakit_wd="$HOME" ;;
esac
exec @RUNTIME@ run --rm $_exakit_tty --network host @USERNS@ \
    -u "$(id -u):$(id -g)" \
    -e HOME="$HOME" \
    -v "$HOME:$HOME" -v /tmp:/tmp \
    -w "$_exakit_wd" \
    @IMAGE@ \
    "@REAL@" "$@"
EXAKIT_SHIM_EOF
    # sed with | as the delimiter: the substituted values are paths/images
    # that can contain / but never |.
    sed -i.exakit-bak \
        -e "s|@RUNTIME@|$_shim_runtime|" \
        -e "s|@USERNS@|$_shim_userns|" \
        -e "s|@IMAGE@|$EXAKIT_EXAPUMP_SHIM_IMAGE|" \
        -e "s|@REAL@|$_shim_real|" \
        "$EXAKIT_EXAPUMP_BIN" && rm -f "$EXAKIT_EXAPUMP_BIN.exakit-bak"
    chmod 755 "$EXAKIT_EXAPUMP_BIN"

    _shim_check="$("$EXAKIT_EXAPUMP_BIN" --version 2>&1)" \
        || die "The exapump container shim did not run: ${_shim_check:-unknown error}. See ${EXAKIT_LOG_FILE:-the log}."
    manifest_set components.exapump.glibc_shim true
    manifest_set components.exapump.shim_image "$EXAKIT_EXAPUMP_SHIM_IMAGE"
    ok "exapump runs via the $_shim_runtime shim ($_shim_check)"
}

# exapump_create_profile — write the kit's connection profile from the
# manifest. Managed section, safe to re-run; other profiles are untouched.
exapump_create_profile() {
    _dsn="$(manifest_get runtime.dsn 2>/dev/null)"
    [ -n "$_dsn" ] || die "No runtime DSN in the manifest — install the database first."
    _host="${_dsn%%:*}"
    _port="${_dsn##*:}"
    _user="$(manifest_get runtime.user 2>/dev/null)"
    _user="${_user:-sys}"

    _pwfile="$(manifest_get runtime.password_file 2>/dev/null)"
    _password=""
    if [ -n "$_pwfile" ] && [ -f "$_pwfile" ]; then
        _password="$(cat "$_pwfile")"
    fi
    if [ -z "$_password" ] && (: < /dev/tty) 2>/dev/null; then
        printf '    %s?%s Database password for user %s (input hidden): ' "${UI_ASK:-}" "${UI_RESET:-}" "$_user"
        stty -echo < /dev/tty 2>/dev/null
        read -r _password < /dev/tty
        stty echo < /dev/tty 2>/dev/null
        printf '\n'
    fi
    if [ -z "$_password" ]; then
        warn "No database password available — create the profile manually with: exapump profile init $EXAKIT_EXAPUMP_PROFILE"
        return 0
    fi

    # If the runtime password wasn't already on file (e.g. we adopted a running
    # deployment whose secrets we couldn't read, so the password came from the
    # prompt above), remember it so exapump_validate_connection can persist it
    # AFTER confirming it works. The MCP step reads runtime.password_file to
    # provision the read-only user, so it must be recorded — but only once the
    # password is validated, otherwise a mistyped password would be saved and
    # the next run would reuse it instead of re-prompting.
    if [ -z "$_pwfile" ] || [ ! -f "$_pwfile" ]; then
        _EXAKIT_PENDING_RUNTIME_PASSWORD="$_password"
    fi

    require_python3
    mkdir -p "$(dirname "$EXAPUMP_CONFIG")"
    run_python - "$EXAPUMP_CONFIG" "$EXAKIT_EXAPUMP_PROFILE" "$_host" "$_port" "$_user" "$_password" <<'PY' || die "Could not write the exapump profile"
import os, re, sys
path, profile, host, port, user, password = sys.argv[1:7]
try:
    with open(path) as f:
        content = f.read()
except FileNotFoundError:
    content = ""

section = (
    f"[{profile}]\n"
    f'host = "{host}"\n'
    f"port = {port}\n"
    f'user = "{user}"\n'
    f'password = "{password}"\n'
    f"tls = true\n"
    f"validate_certificate = false\n"
)
pattern = re.compile(rf"\[{re.escape(profile)}\][^\[]*", re.S)
if pattern.search(content):
    content = pattern.sub(section + "\n", content).rstrip("\n") + "\n"
else:
    if content and not content.endswith("\n\n"):
        content = content.rstrip("\n") + "\n\n"
    content += section
# Atomic replace: an interrupted run must never truncate a config that may
# hold the user's other profiles.
tmp = path + ".tmp"
with open(tmp, "w") as f:
    f.write(content)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
    chmod 600 "$EXAPUMP_CONFIG"
    manifest_set components.exapump.profile "$EXAKIT_EXAPUMP_PROFILE"
    ok "Connection profile written: [$EXAKIT_EXAPUMP_PROFILE] in $EXAPUMP_CONFIG"
}

# exapump_ddl_roundtrip — one DDL write-readback round through the profile.
# Returns 0 ONLY if a freshly created schema+table is durably persisted and
# visible from SUBSEQUENT connections (each exapump invocation reconnects).
#
# This is the real readiness signal. Right after first boot the Nano database
# accepts a connection and answers SELECT 1 while still stabilizing, and in that
# window it can ACKNOWLEDGE a DDL batch ("N statements executed, 0 failed")
# without durably persisting it — so the schema-creation step "succeeds" but the
# very next `exapump upload` fails with "schema STARTER_KIT not found". The probe
# reproduces exactly that sequence (create schema in one connection, reference it
# from the next) so we only proceed once the database really is ready.
exapump_ddl_roundtrip() {
    _probe="EXAKIT_READY_PROBE"
    _cli="$(exapump_cli)"
    # Best-effort clean slate — a probe schema left by an interrupted earlier
    # attempt must not make this one look like a success. Result ignored.
    "$_cli" sql -p "$EXAKIT_EXAPUMP_PROFILE" "DROP SCHEMA IF EXISTS $_probe CASCADE" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1
    "$_cli" sql -p "$EXAKIT_EXAPUMP_PROFILE" "CREATE SCHEMA $_probe" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || return 1
    # A NEW connection must see the just-created schema (this is the exact
    # cross-connection visibility that failed during install) and persist a table.
    if ! "$_cli" sql -p "$EXAKIT_EXAPUMP_PROFILE" "CREATE TABLE $_probe.READY_PROBE (n DECIMAL(9,0))" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 \
        || ! "$_cli" sql -p "$EXAKIT_EXAPUMP_PROFILE" "INSERT INTO $_probe.READY_PROBE VALUES (42)" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
        "$_cli" sql -p "$EXAKIT_EXAPUMP_PROFILE" "DROP SCHEMA IF EXISTS $_probe CASCADE" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1
        return 1
    fi
    _out="$("$_cli" sql -p "$EXAKIT_EXAPUMP_PROFILE" "SELECT 'EXAKIT_DDL[' || CAST(n AS VARCHAR(10)) || ']' AS R FROM $_probe.READY_PROBE" 2>/dev/null)"
    "$_cli" sql -p "$EXAKIT_EXAPUMP_PROFILE" "DROP SCHEMA IF EXISTS $_probe CASCADE" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1
    case "$_out" in
        *"EXAKIT_DDL[42]"*) return 0 ;;
        *) return 1 ;;
    esac
}

# exapump_confirm_database_ready — block until the database can durably persist
# a schema, not merely answer SELECT 1. Polls exapump_ddl_roundtrip with a
# bounded budget (EXAKIT_DDL_READY_TIMEOUT, default 180s) so the sample-data and
# MCP steps that follow can trust that CREATE SCHEMA/TABLE will stick.
exapump_confirm_database_ready() {
    _timeout="${EXAKIT_DDL_READY_TIMEOUT:-180}"
    info "Confirming the database can persist schema changes"
    _waited=0
    while :; do
        if exapump_ddl_roundtrip; then
            if [ "$_waited" -eq 0 ]; then
                ok "Database is ready for schema changes"
            else
                ok "Database is ready for schema changes (after ~${_waited}s)"
            fi
            return 0
        fi
        [ "$_waited" -ge "$_timeout" ] && break
        sleep 5
        _waited=$((_waited + 5))
        if [ $((_waited % 30)) -eq 0 ]; then
            info "Database still stabilizing... (${_waited}s)"
        fi
    done
    die "The database accepts connections but could not durably persist a schema within ${_timeout}s (first-boot stabilization window). Wait a moment, then retry: exakit data-load"
}

# exapump_validate_connection — SELECT 1 through the new profile, then confirm
# the database can durably persist DDL before any caller relies on CREATE SCHEMA
# sticking.
exapump_validate_connection() {
    if [ -z "$(manifest_get components.exapump.profile 2>/dev/null)" ]; then
        die "No connection profile exists (no database password was available to write one). Create it manually with 'exapump profile init $EXAKIT_EXAPUMP_PROFILE', then re-run this script."
    fi
    info "Validating the database connection (SELECT 1)"
    _connected=0
    _tries=0
    while [ "$_tries" -lt 6 ]; do
        if run_logged "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" 'SELECT 1'; then
            _connected=1
            break
        fi
        _tries=$((_tries + 1))
        sleep 5
    done
    [ "$_connected" -eq 1 ] || \
        die "SELECT 1 failed via profile '$EXAKIT_EXAPUMP_PROFILE'. Try: exapump sql -p $EXAKIT_EXAPUMP_PROFILE 'SELECT 1'"
    ok "Connection works"

    # A working connection is NOT proof the database can persist schema changes
    # yet — see exapump_ddl_roundtrip. Gate here so both the data-load and MCP
    # steps that follow run against a database that is genuinely ready.
    exapump_confirm_database_ready

    manifest_set components.exapump.validated true
    # Now that the password is proven to work, persist it as the runtime
    # password if the runtime step could not (adopted deployment with
    # unreadable secrets) — the MCP step needs runtime.password_file.
    if [ -n "${_EXAKIT_PENDING_RUNTIME_PASSWORD:-}" ]; then
        store_credential runtime_sys_password "$_EXAKIT_PENDING_RUNTIME_PASSWORD"
        manifest_set runtime.password_file "$EXAKIT_CREDS_DIR/runtime_sys_password"
        unset _EXAKIT_PENDING_RUNTIME_PASSWORD
    fi
}

# exapump_run_sql_file <file> [description] — execute a SQL file, logged.
exapump_run_sql_file() {
    [ -s "$1" ] || { warn "SQL file missing or empty: $1"; return 1; }
    info "Running ${2:-$(basename "$1")}"
    if ! run_logged "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" < "$1"; then
        [ -n "${EXAKIT_LOG_FILE:-}" ] && exakit_explain_db_error "$(tail -8 "$EXAKIT_LOG_FILE" 2>/dev/null)"
        die "SQL file failed: $1 (see log)"
    fi
    ok "${2:-$(basename "$1")} done"
}

# exapump_upload <file> <schema.table> — load a CSV/Parquet file, logged.
exapump_upload() {
    [ -s "$1" ] || { warn "Data file missing or empty: $1"; return 1; }
    # EXAKIT_UPLOAD_QUIET: `exakit data-load` narrates the whole job with a
    # single "Loading your data" spinner, so per-file chatter is noise there.
    # The installer leaves it unset and keeps its step-by-step narration.
    [ "${EXAKIT_UPLOAD_QUIET:-0}" = 1 ] || info "Loading $(basename "$1") into $2"
    if ! run_logged "$(exapump_cli)" upload "$1" --table "$2" -p "$EXAKIT_EXAPUMP_PROFILE"; then
        # The engine's message is in the log; translate the common faults into
        # their remedy before dying, so "Connection refused" arrives WITH
        # "exakit start" instead of leaving the user to map one to the other.
        [ -n "${EXAKIT_LOG_FILE:-}" ] && exakit_explain_db_error "$(tail -8 "$EXAKIT_LOG_FILE" 2>/dev/null)"
        die "Upload failed: $1 -> $2 (see log)"
    fi
    [ "${EXAKIT_UPLOAD_QUIET:-0}" = 1 ] || ok "$(basename "$1") loaded"
}

# exapump_count <schema.table> — row count (prints the number, empty on failure).
# Wrap the count in a unique delimited token (EXAKIT_RC[<n>]) and recover it with
# a regex instead of scraping the last line for digits. The old "tail -1 |
# tr -dc 0-9" collapsed exapump's "[1/1] ... 1 rows" status line to "111" for
# every table in non-TTY installs (where exapump prints no separate value line).
# The echoed query literal never forms "EXAKIT_RC[<digits>]", so only the real
# result matches.
exapump_count() {
    _sql="SELECT 'EXAKIT_RC[' || CAST(COUNT(*) AS VARCHAR(40)) || ']' AS EXAKIT_RC FROM $1"
    "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" "$_sql" 2>/dev/null | \
        grep -oE 'EXAKIT_RC\[[0-9]+\]' | head -1 | tr -dc '0-9'
}

exapump_record_manifest() {
    manifest_set components.exapump.version "$EXAKIT_EXAPUMP_VERSION"
    manifest_set components.exapump.path "$(exapump_cli)"
}

# exapump_confirm_installed_version — ask the binary what it is, now that this run
# has installed one, and make the record agree with the answer.
# exapump_record_manifest writes the version the run INTENDED to install; only the
# binary can say what is actually there (the recorded path can be gone by the time
# anyone looks, leaving an exapump the user manages themselves on PATH as the answer,
# and the glibc shim runs whatever the container image holds). Returns non-zero when
# they disagree, so the caller does not announce a move that did not happen.
#
# Silence is left alone deliberately: exakit_component_current answers nothing only
# when there is no runnable binary at all, exapump_install already fails loudly for
# that, and a correction invented from silence would be worse than the record.
# ⇄ twin: Confirm-ExapumpInstalledVersion in exapump.ps1.
exapump_confirm_installed_version() {
    command -v exakit_component_current >/dev/null 2>&1 || return 0
    _ecv_live="$(exakit_component_current exapump 2>/dev/null || true)"
    [ -n "$_ecv_live" ] || return 0
    [ "$_ecv_live" != "$EXAKIT_EXAPUMP_VERSION" ] || return 0
    warn "The exapump on disk reports $_ecv_live, not the $EXAKIT_EXAPUMP_VERSION this update installed — recording what is there"
    manifest_set components.exapump.version "$_ecv_live"
    return 1
}

exapump_update() {
    _latest="$(exakit_component_available exapump)"
    [ -n "$_latest" ] || die "Could not resolve the advertised exapump version."
    # The already-current guard reads the same thing `exakit version` prints in
    # its Installed column: the version the binary on disk reports when asked. The
    # manifest record is only what a previous run WROTE DOWN — exapump_record_manifest
    # writes it from EXAKIT_EXAPUMP_VERSION, before the download it describes is
    # proven — so it can name a version that was never installed, and it says nothing
    # at all about a binary someone replaced by hand. Comparing against the record
    # made this function decline the work the dispatcher had just announced from the
    # live probe ("exapump 0.11.0 -> 0.11.2", then "already current (0.11.2)"), and
    # call an install current at a version nobody is running.
    _exapump_recorded="$(manifest_get components.exapump.version 2>/dev/null || true)"
    if command -v exakit_component_current >/dev/null 2>&1; then
        # An empty answer is NOT "cannot tell", so it must not fall back to the
        # record: for exapump the reader answers nothing only when there is no
        # executable binary at the recorded path or on PATH, and it already falls
        # back to the record itself when a binary IS there but will not run (a
        # release built against a newer glibc). Provably absent means install —
        # the record must not vouch for a binary that is gone.
        _current="$(exakit_component_current exapump 2>/dev/null || true)"
    else
        # The reader lives in common.sh, which every entry point sources before this
        # module. This is the sourced-alone case, where the record is all there is.
        _current="$_exapump_recorded"
    fi
    if [ "$_latest" = "$_current" ]; then
        # Genuinely already current, so this stays a clean skip — but a record that
        # disagrees with the binary is still reconciled, because that record is what
        # `exakit version` credits the kit with having installed, and what a
        # subsequent exapump_install would leave untouched on its already-installed
        # path.
        if [ "$_exapump_recorded" != "$_current" ]; then
            info "Reconciling the recorded exapump version (${_exapump_recorded:-unrecorded}) with the binary on disk"
            manifest_set components.exapump.version "$_current"
        fi
        ok "exapump is already current ($_current)"
        return 0
    fi
    # Not the place to ask whether $_latest is a step BACKWARDS from $_current. That
    # is settled once, for every component, at the choke point in
    # exakit_update_component (exakit_component_is_ahead), which reads the same live
    # probe this guard now reads and returns before exapump_update is called at all.
    # A second copy of the rule here would be one more thing to keep in step with it.
    info "Updating exapump ${_current:-not installed} -> $_latest"
    EXAKIT_EXAPUMP_VERSION="$_latest"
    EXAKIT_FORCE_COMPONENT_INSTALL=1
    export EXAKIT_EXAPUMP_VERSION EXAKIT_FORCE_COMPONENT_INSTALL
    exapump_install
    exapump_create_profile
    manifest_set desired.exapump "$EXAKIT_EXAPUMP_VERSION"
    # Confirm from the binary, not from the record exapump_install just wrote.
    if exapump_confirm_installed_version; then
        ok "exapump updated without changing database data"
    fi
}

exakit_table_name_from_path() {
    _base="$(basename "$1")"
    _base="${_base%%\?*}"
    _base="${_base%.*}"
    _table="$(printf '%s' "$_base" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9_' '_')"
    _table="$(printf '%s' "$_table" | sed 's/^_*//; s/_*$//; s/__*/_/g')"
    printf '%s\n' "${_table:-MY_TABLE}"
}

exakit_normalize_path() {
    case "$1" in
        "~") printf '%s\n' "$HOME" ;;
        "~/"*) printf '%s/%s\n' "$HOME" "${1#~/}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

exakit_validate_table_target() {
    case "$1" in
        *.*) ;;
        *) return 1 ;;
    esac
    _schema="${1%%.*}"
    _table="${1#*.}"
    case "$_schema" in ""|*[!A-Za-z0-9_]*) return 1 ;; esac
    case "$_table" in ""|*[!A-Za-z0-9_]*) return 1 ;; esac
    return 0
}

exakit_target_schema() {
    printf '%s\n' "${1%%.*}" | tr '[:lower:]' '[:upper:]'
}

exakit_upper_table_target() {
    _schema="${1%%.*}"
    _table="${1#*.}"
    printf '%s.%s\n' \
        "$(printf '%s' "$_schema" | tr '[:lower:]' '[:upper:]')" \
        "$(printf '%s' "$_table" | tr '[:lower:]' '[:upper:]')"
}

# exakit_schema_present <schema> — read-only check that a schema exists, from a
# fresh connection. Distinct from exakit_ensure_schema, which also creates it.
exakit_schema_present() {
    _schema="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
    [ -n "$_schema" ] || return 1
    "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" \
        "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_ALL_SCHEMAS WHERE SCHEMA_NAME = '$_schema') THEN 'EXAKIT_SCHEMA_PRESENT' ELSE 'EXAKIT_SCHEMA_MISSING' END AS STATUS" \
        2>> "${EXAKIT_LOG_FILE:-/dev/null}" | grep -q "EXAKIT_SCHEMA_PRESENT"
}

exakit_ensure_schema() {
    _schema="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
    [ -n "$_schema" ] || return 1
    if exakit_schema_present "$_schema"; then
        return 0
    fi
    [ "${EXAKIT_UPLOAD_QUIET:-0}" = 1 ] || info "Creating schema $_schema"
    run_logged "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" "CREATE SCHEMA $_schema" || \
        die "Could not create schema $_schema"
}

exakit_verify_loaded_table() {
    _target="$1"
    _rows="$(exapump_count "$_target")"
    [ -n "$_rows" ] || die "Could not verify row count for $_target."
    if [ "$_rows" = "0" ]; then
        warn "Verified $_target, but it currently has 0 rows."
    else
        [ "${EXAKIT_UPLOAD_QUIET:-0}" = 1 ] || ok "Verified $_target ($_rows rows)"
    fi
    manifest_set data.last_load.verified_table "$_target"
    manifest_set data.last_load.verified_rows "$_rows"
}

exakit_prompt_optional_verification() {
    _default="${1:-}"
    _target="$(prompt_text "Verify table after script/import (SCHEMA.TABLE, blank to skip)" "$_default")"
    [ -n "$_target" ] || {
        info "Skipping table verification for this script/import."
        return 0
    }
    exakit_validate_table_target "$_target" || die "Verification table must look like SCHEMA.TABLE and use letters, numbers, or underscores."
    exakit_verify_loaded_table "$(exakit_upper_table_target "$_target")"
}

# --- JSON input: routed through the JSON Tables add-on -----------------------
#
# exapump loads CSV and Parquet. JSON is a different shape of problem -- one
# document can be an arbitrarily nested tree, and turning that into relational
# tables is what the JSON Tables add-on exists for. So `exakit data-load` reads
# the file's kind first and, for JSON, offers the add-on (prebuilt, no Rust
# toolchain) and then finishes the load itself: ingest the JSON to Parquet,
# then push the Parquet in through the same verified exapump path CSV uses.
# The user hands over one JSON file and ends up with queryable tables.

# exakit_data_file_kind <path> — csv | parquet | json | unknown, from the name.
# Compressed variants resolve to their payload kind: exapump handles .csv.gz,
# and the ingest engine reads .json.gz / .ndjson.gz.
exakit_data_file_kind() {
    _dfk_name="$(printf '%s' "${1##*/}" | tr '[:upper:]' '[:lower:]')"
    case "$_dfk_name" in
        *.gz|*.bz2|*.zst|*.xz) _dfk_name="${_dfk_name%.*}" ;;
    esac
    case "$_dfk_name" in
        *.json|*.ndjson|*.jsonl) printf 'json\n' ;;
        *.parquet|*.pq)          printf 'parquet\n' ;;
        *.csv|*.tsv|*.txt)       printf 'csv\n' ;;
        *)                       printf 'unknown\n' ;;
    esac
}

# _exakit_json_tables_ready — is the add-on installed AND usable right now?
_exakit_json_tables_ready() {
    command -v json_tables_installed_version >/dev/null 2>&1 || return 1
    [ -n "$(json_tables_installed_version 2>/dev/null || true)" ] || return 1
    [ -x "${EXAKIT_JSON_TABLES_BIN:-}" ] || return 1
    return 0
}

# _exakit_json_tables_load_module — the module is sourced by the exakit CLI but
# not by the installer, and the JSON path can be reached from either.
_exakit_json_tables_load_module() {
    command -v json_tables_install >/dev/null 2>&1 && return 0
    command -v _exakit_marketplace_load_modules >/dev/null 2>&1 || return 1
    _exakit_marketplace_load_modules >/dev/null 2>&1 || true
    command -v json_tables_install >/dev/null 2>&1
}

# _exakit_json_tables_ensure - make the JSON engine usable, saying nothing.
# A JSON file is just data the user asked to load, so the engine it needs is an
# implementation detail: it installs with its output in the log, under the same
# "Loading your data" spinner as the load itself. No question is asked, and no
# download or install step is announced.
#
# Returns 0 when the engine is ready, 1 when this machine cannot have it - that
# case still speaks up, because a silent failure is worse than a loud one.
_exakit_json_tables_ensure() {
    _exakit_json_tables_ready && return 0

    _exakit_json_tables_load_module || {
        warn "This kit copy does not carry the JSON engine - update the kit first: exakit update exakit"
        return 1
    }
    if command -v _exakit_addon_applicable >/dev/null 2>&1 && \
       ! _exakit_addon_applicable json-tables; then
        _jte_why="$(_exakit_addon_applicable_reason json-tables 2>/dev/null || true)"
        warn "JSON files need an engine that is not available on this machine${_jte_why:+: $_jte_why}"
        info "CSV and Parquet load without it. Convert the file, or load it from a supported machine."
        return 1
    fi
    command -v _exakit_marketplace_install_one >/dev/null 2>&1 || {
        warn "The marketplace installer is not available in this kit build."
        return 1
    }
    if ! _exakit_marketplace_install_one json-tables >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
        warn "The JSON engine could not be installed, so this file was not loaded."
        info "Everything already in the database is untouched. Details: exakit logs"
        return 1
    fi
    _exakit_json_tables_ready || {
        warn "The JSON engine installed but is not usable yet - retry with: exakit data-load"
        return 1
    }
    return 0
}

# exakit_load_local_json <path> <target> - ingest a JSON file and load what
# comes out of it. The target is decided by the CALLER, before anything runs,
# so JSON asks exactly what CSV and Parquet ask: one SCHEMA.TABLE, then it
# loads. Nothing here prompts.
#
# Nested JSON legitimately yields SEVERAL tables. One table lands on <target>
# exactly; several keep <target> as their shared prefix, so the name the user
# typed still describes every table the document produced. The full list is
# left in EXAKIT_LAST_LOAD_TARGET for the caller's closing line.
exakit_load_local_json() {
    _jl_path="$1"
    _jl_target="$2"
    _jl_schema="$(exakit_target_schema "$_jl_target")"
    _jl_base="${_jl_target#*.}"

    _exakit_json_tables_ensure || return 1

    _jl_tmp="$(mktemp -d "${TMPDIR:-/tmp}/exakit-json-load.XXXXXX")" || {
        warn "Could not create a temporary directory for the JSON ingest."
        return 1
    }
    # THE INGEST ENGINE IS LINE-ORIENTED: it reads one complete JSON document
    # per line. A pretty-printed file - which is what almost every API, export
    # and hand-written fixture actually looks like - fails on its first line
    # with "Line 1: EOF while parsing an object", because line 1 is just "{".
    #
    # Re-flowing that onto one line changes whitespace, not data, so the kit
    # does it rather than telling someone to reformat a file it can read
    # perfectly well. A file that is ALREADY line-delimited is passed through
    # untouched; one that is not JSON at all is reported as that, instead of
    # as a parse error pointing at a line number nobody wrote.
    _jl_input="$_jl_path"
    _jl_norm="$_jl_tmp/normalised.json"
    run_python - "$_jl_path" "$_jl_norm" <<'EXAKIT_JSON_NORMALISE_PY'
import json, sys

source, target = sys.argv[1], sys.argv[2]
with open(source, encoding="utf-8-sig") as handle:
    raw = handle.read()

try:
    document = json.loads(raw)
except ValueError:
    # Not one whole document. It may already be NDJSON - every non-empty line
    # a document of its own - which is exactly what the engine wants.
    for line in raw.splitlines():
        if not line.strip():
            continue
        try:
            json.loads(line)
        except ValueError:
            sys.exit(4)          # neither shape: genuinely malformed
    sys.exit(3)                  # already line-delimited, use it as it is

with open(target, "w", encoding="utf-8") as out:
    if isinstance(document, list):
        # A top-level array is a list of records: one per line.
        for item in document:
            out.write(json.dumps(item) + "\n")
    else:
        out.write(json.dumps(document) + "\n")
EXAKIT_JSON_NORMALISE_PY
    case $? in
        0) _jl_input="$_jl_norm" ;;
        3) ;;   # already NDJSON
        4) rm -rf "$_jl_tmp"
           warn "$(ui_tilde "$_jl_path") is not valid JSON."
           info "It must be one JSON document, or NDJSON with one document per line."
           info "Nothing was loaded; the database is unchanged."
           return 1 ;;
        *) ;;   # no python, or an unreadable file: let the engine have its say
    esac

    if ! run_logged "$EXAKIT_JSON_TABLES_BIN" ingest \
            --input "$_jl_input" --output-dir "$_jl_tmp/out"; then
        rm -rf "$_jl_tmp"
        warn "This JSON file could not be read - see: exakit logs json-tables"
        info "It must be one JSON document, or NDJSON with one document per line."
        info "Nothing was loaded; the database is unchanged."
        return 1
    fi

    _jl_files="$(find "$_jl_tmp/out" -name '*.parquet' 2>/dev/null | sort)"
    if [ -z "$_jl_files" ]; then
        rm -rf "$_jl_tmp"
        warn "No tables came out of $(ui_tilde "$_jl_path")."
        info "Check the file is JSON or NDJSON, then retry: exakit data-load"
        return 1
    fi
    _jl_count="$(printf '%s\n' "$_jl_files" | grep -c .)"

    exakit_ensure_schema "$_jl_schema"
    if [ "$_jl_count" -eq 1 ]; then
        exapump_upload "$_jl_files" "$_jl_target"
        exakit_verify_loaded_table "$_jl_target"
        _jl_loaded="$_jl_target"
    else
        _jl_loaded=""
        while IFS= read -r _jl_file; do
            [ -n "$_jl_file" ] || continue
            _jl_table="$_jl_schema.${_jl_base}_$(exakit_table_name_from_path "$_jl_file")"
            _jl_table="$(exakit_upper_table_target "$_jl_table")"
            exapump_upload "$_jl_file" "$_jl_table"
            exakit_verify_loaded_table "$_jl_table"
            _jl_loaded="${_jl_loaded:+$_jl_loaded, }$_jl_table"
        done <<EXAKIT_JL_EOF
$_jl_files
EXAKIT_JL_EOF
    fi
    rm -rf "$_jl_tmp"

    manifest_set data.last_load.type "local_json"
    manifest_set data.last_load.target "$_jl_loaded"
    manifest_set data.last_load.source "$_jl_path"
    EXAKIT_LAST_LOAD_TARGET="$_jl_loaded"
    return 0
}

exakit_load_local_file() {
    while :; do
        _raw_path="$(prompt_text "Local CSV / Parquet / JSON file path (type back to return)")"
        case "$_raw_path" in
            b|B|back|Back|BACK)
                info "Returning to data loading options."
                return 2
                ;;
        esac
        if [ -z "$_raw_path" ]; then
            warn "Please enter a local CSV, Parquet or JSON file path, or type back to return."
            continue
        fi
        _path="$(exakit_normalize_path "$_raw_path")"
        [ -s "$_path" ] && break
        warn "File not found or empty: $_path"
    done
    # Every file kind is asked the same two things, in the same order, before
    # any work starts: the file, then SCHEMA.TABLE. What has to happen after
    # that - an engine to install, a conversion to run - is this command's
    # problem, not the user's, so none of it reaches the screen.
    _default_table="${EXAKIT_SCHEMA:-STARTER_KIT}.$(exakit_table_name_from_path "$_path")"
    while :; do
        _target="$(prompt_text "Target table (SCHEMA.TABLE, back to return)" "$_default_table")"
        case "$_target" in
            b|B|back|Back|BACK)
                info "Returning to data loading options."
                return 2
                ;;
        esac
        exakit_validate_table_target "$_target" && break
        warn "Target table must look like SCHEMA.TABLE and use letters, numbers, or underscores."
    done
    _target="$(exakit_upper_table_target "$_target")"

    # One label, one spinner, whatever the file turns out to need.
    EXAKIT_UPLOAD_QUIET=1
    EXAKIT_ACTIVE_LABEL="Loading your data"
    export EXAKIT_UPLOAD_QUIET EXAKIT_ACTIVE_LABEL

    if [ "$(exakit_data_file_kind "$_path")" = "json" ]; then
        EXAKIT_LAST_LOAD_TARGET=""
        exakit_load_local_json "$_path" "$_target"
        _lf_status=$?
        EXAKIT_UPLOAD_QUIET=0
        EXAKIT_ACTIVE_LABEL=""
        [ "$_lf_status" -eq 0 ] || return "$_lf_status"
        ok "Loaded $(ui_tilde "$_path") into ${EXAKIT_LAST_LOAD_TARGET:-$_target}"
        return 0
    fi
    exakit_ensure_schema "$(exakit_target_schema "$_target")"
    exapump_upload "$_path" "$_target"
    manifest_set data.last_load.type "local_file"
    manifest_set data.last_load.target "$_target"
    manifest_set data.last_load.source "$_path"
    exakit_verify_loaded_table "$_target"
    EXAKIT_UPLOAD_QUIET=0
    EXAKIT_ACTIVE_LABEL=""
    ok "Loaded $(ui_tilde "$_path") into $_target"
}

exakit_load_remote_file() {
    _url="$(prompt_text "Remote CSV / Parquet / JSON URL")"
    [ -n "$_url" ] || die "Remote URL is required."
    _name="$(basename "${_url%%\?*}")"
    [ -n "$_name" ] || _name="remote-data.csv"
    # Same two questions as a local file, asked before the download starts.
    _default_table="${EXAKIT_SCHEMA:-STARTER_KIT}.$(exakit_table_name_from_path "$_name")"
    _target="$(prompt_text "Target table (SCHEMA.TABLE)" "$_default_table")"
    exakit_validate_table_target "$_target" || die "Target table must look like SCHEMA.TABLE and use letters, numbers, or underscores."
    _target="$(exakit_upper_table_target "$_target")"

    _tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/exakit-remote-data.XXXXXX")" || die "Could not create a temporary download directory."
    _tmp_file="$_tmp_dir/$_name"

    # The download is part of "loading your data", not a step of its own: the
    # spinner carries it under the same label as everything after it.
    EXAKIT_UPLOAD_QUIET=1
    EXAKIT_ACTIVE_LABEL="Loading your data"
    export EXAKIT_UPLOAD_QUIET EXAKIT_ACTIVE_LABEL
    fetch "$_url" "$_tmp_file"

    if [ "$(exakit_data_file_kind "$_tmp_file")" = "json" ]; then
        EXAKIT_LAST_LOAD_TARGET=""
        exakit_load_local_json "$_tmp_file" "$_target"
        _rf_status=$?
        rm -rf "$_tmp_dir"
        EXAKIT_UPLOAD_QUIET=0
        EXAKIT_ACTIVE_LABEL=""
        [ "$_rf_status" -eq 0 ] || return "$_rf_status"
        manifest_set data.last_load.type "remote_file"
        manifest_set data.last_load.source "$_url"
        ok "Loaded $_url into ${EXAKIT_LAST_LOAD_TARGET:-$_target}"
        return 0
    fi
    exakit_ensure_schema "$(exakit_target_schema "$_target")"
    exapump_upload "$_tmp_file" "$_target"
    rm -rf "$_tmp_dir"
    manifest_set data.last_load.type "remote_file"
    manifest_set data.last_load.target "$_target"
    manifest_set data.last_load.source "$_url"
    exakit_verify_loaded_table "$_target"
    EXAKIT_UPLOAD_QUIET=0
    EXAKIT_ACTIVE_LABEL=""
    ok "Loaded $_url into $_target"
}

exakit_run_sql_script() {
    _raw_path="$(prompt_text "SQL script path")"
    _path="$(exakit_normalize_path "$_raw_path")"
    [ -s "$_path" ] || die "SQL script not found or empty: $_path"
    exapump_run_sql_file "$_path" "SQL script ($(basename "$_path"))"
    manifest_set data.last_load.type "sql_script"
    manifest_set data.last_load.source "$_path"
    exakit_prompt_optional_verification ""
    ok "SQL script completed"
}

# --- bundled dataset registry ------------------------------------------------
# The kit can ship any number of bundled datasets. TPC-H is the original one
# (flat layout: data/*.csv + sql/0*.sql, loaded by exakit_load_sample_data);
# every additional dataset is a self-contained directory:
#
#   data/datasets/<id>/dataset.conf      id=, label=, markers= (see below)
#   data/datasets/<id>/01_create_schema.sql
#   data/datasets/<id>/data/*.csv        optional bulk files (table = filename)
#   data/datasets/<id>/02_load_data.sql  optional transform/generation step
#   data/datasets/<id>/03_verify_setup.sql  optional checks (a FAIL row blocks)
#
# Each bundled dataset loads into its own schema (schema= in dataset.conf,
# default the id uppercased — e.g. TPCH, ENERGY, WEATHER) so its tables stay
# grouped in the AI client; the MCP read-only user has database-wide read
# (USE ANY SCHEMA + SELECT ANY TABLE — see exakit_configure_mcp_readonly_access)
# so it sees every dataset schema with no per-schema grant. "markers" names the
# dataset's tables used to answer "is this loaded?" against the DATABASE (in
# that schema), not just the manifest.

# exakit_bundled_datasets — one line per dataset: "id|label|flag|markers|schema".
# Every dataset (TPC-H included) lives under data/datasets/<id>/ and is
# discovered from its dataset.conf; nothing is hardcoded here. A conf may set
# flag= to override the default manifest key (TPC-H keeps the historical
# data.loaded so existing installs stay recognized) and schema= to name the
# schema it loads into (default: the id, uppercased).
# Read one key from a dataset.conf. The trailing-CR strip matters: a kit
# copied from a Windows checkout can carry CRLF confs, and a CR-suffixed id
# makes every dataset "Unknown" (gitattributes now pins these to LF, but a
# pre-existing checkout keeps its old line endings).
_exakit_dataset_conf_get() {
    sed -n "s/^$1=//p" "$2" | head -1 | tr -d '\r'
}


exakit_bundled_datasets() {
    _bdr_root="$(exakit_repo_root 2>/dev/null)" || return 0
    for _bdr_conf in "$_bdr_root"/data/datasets/*/dataset.conf; do
        [ -f "$_bdr_conf" ] || continue
        _bdr_id="$(_exakit_dataset_conf_get id "$_bdr_conf")"
        _bdr_label="$(_exakit_dataset_conf_get label "$_bdr_conf")"
        _bdr_markers="$(_exakit_dataset_conf_get markers "$_bdr_conf")"
        _bdr_flag="$(_exakit_dataset_conf_get flag "$_bdr_conf")"
        _bdr_order="$(_exakit_dataset_conf_get order "$_bdr_conf")"
        _bdr_schema="$(_exakit_dataset_conf_get schema "$_bdr_conf")"
        [ -n "$_bdr_id" ] && [ -n "$_bdr_label" ] || continue
        [ -n "$_bdr_flag" ] || _bdr_flag="data.datasets.${_bdr_id}.loaded"
        [ -n "$_bdr_schema" ] || _bdr_schema="$(printf '%s' "$_bdr_id" | tr '[:lower:]' '[:upper:]')"
        case "$_bdr_order" in ''|*[!0-9]*) _bdr_order=50 ;; esac
        printf '%s|%s|%s|%s|%s|%s\n' "$_bdr_order" "$_bdr_id" "$_bdr_label" "$_bdr_flag" "$_bdr_markers" "$_bdr_schema"
    done | sort -t'|' -n -k1,1 | cut -d'|' -f2-
}

# exakit_db_reachable — can we run SQL right now?
#
# ONLY A "YES" IS CACHED. Caching the "no" too is what let one installer run
# report a full database while looking at an empty one: the probe ran before
# the runtime step, the deployment was down (or being replaced), and the 0 that
# answer left behind was still there when the data step asked afterwards. Every
# dataset then fell through to the manifest flag and printed "already loaded"
# against a database with no schemas in it — and the run exited 0.
#
# A "yes" cannot go stale the same way: nothing in a kit run takes the database
# down without going through personal_stop/nano_stop, and those call
# exakit_forget_db_reachable. A "no" can go stale on any run that starts or
# deploys one, so it is re-probed. The cost is one refused local connection per
# ask, and exakit_dataset_loaded is the only caller.
_EXAKIT_DB_REACHABLE=""
exakit_db_reachable() {
    if [ "$_EXAKIT_DB_REACHABLE" != 1 ]; then
        if [ -n "$(manifest_get components.exapump.profile 2>/dev/null)" ] && \
           "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" "SELECT 1" >/dev/null 2>&1; then
            _EXAKIT_DB_REACHABLE=1
        else
            _EXAKIT_DB_REACHABLE=0
        fi
    fi
    [ "$_EXAKIT_DB_REACHABLE" = 1 ]
}

# exakit_forget_db_reachable — drop the cached "yes" after the kit itself takes
# the database down, so a later check re-probes instead of trusting a state that
# this run has just ended.
exakit_forget_db_reachable() {
    _EXAKIT_DB_REACHABLE=""
    return 0
}

# exakit_table_present <table> [schema] — does the table exist in the given
# schema (default STARTER_KIT / $EXAKIT_SCHEMA)?
exakit_table_present() {
    _tp_schema="$(printf '%s' "${2:-${EXAKIT_SCHEMA:-STARTER_KIT}}" | tr '[:lower:]' '[:upper:]')"
    _tp_table="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
    [ -n "$_tp_table" ] || return 1
    "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" \
        "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_ALL_TABLES WHERE TABLE_SCHEMA = '$_tp_schema' AND TABLE_NAME = '$_tp_table') THEN 'EXAKIT_TABLE_PRESENT' ELSE 'EXAKIT_TABLE_MISSING' END AS STATUS" \
        2>> "${EXAKIT_LOG_FILE:-/dev/null}" | grep -q "EXAKIT_TABLE_PRESENT"
}

# _exakit_sync_dataset_flag <key> <true|false> — write one manifest flag only
# when it disagrees with what was observed. Split out because a dataset has TWO
# keys to keep honest, not one (see exakit_dataset_loaded).
_exakit_sync_dataset_flag() {
    [ -n "$1" ] || return 0
    [ "$(manifest_get "$1" 2>/dev/null)" = "$2" ] || manifest_set "$1" "$2"
    return 0
}

# exakit_dataset_loaded <flag> <markers_csv> [schema] [id] — is the dataset
# actually loaded? The DATABASE is the source of truth: when it is reachable,
# every marker table must exist in the dataset's schema, and BOTH manifest keys
# are synced to what was observed, so a destroy+redeploy that left a stale
# "loaded" flag self-heals. Only when the database is unreachable do we fall
# back to the manifest.
#
# TWO KEYS, on purpose. A dataset.conf may set flag= to override the manifest
# key (TPC-H keeps the historical data.loaded so older installs stay
# recognized), while `exakit status` reads the canonical
# data.datasets.<id>.loaded for every dataset alike. Syncing only the override
# is what let `exakit status --json` keep listing tpch as loaded against a
# database with no schemas in it, long after this function had observed the
# tables were gone and healed the other key. Whichever key the caller names,
# the canonical one is written too.
exakit_dataset_loaded() {
    _dl_flag="$1"
    _dl_markers="$(printf '%s' "$2" | tr ',' ' ')"
    _dl_schema="$3"
    _dl_id="${4:-}"
    _dl_canonical=""
    [ -n "$_dl_id" ] && _dl_canonical="data.datasets.${_dl_id}.loaded"
    [ "$_dl_canonical" = "$_dl_flag" ] && _dl_canonical=""
    if exakit_db_reachable && [ -n "$_dl_markers" ]; then
        for _dl_table in $_dl_markers; do
            if ! exakit_table_present "$_dl_table" "$_dl_schema"; then
                _exakit_sync_dataset_flag "$_dl_flag" false
                _exakit_sync_dataset_flag "$_dl_canonical" false
                return 1
            fi
        done
        _exakit_sync_dataset_flag "$_dl_flag" true
        _exakit_sync_dataset_flag "$_dl_canonical" true
        return 0
    fi
    [ "$(manifest_get "$_dl_flag" 2>/dev/null)" = "true" ]
}

# exakit_pending_datasets — "id|label" lines for bundled datasets that are NOT
# loaded yet. Drives the dynamic data menus: loaded datasets are not offered.
exakit_pending_datasets() {
    exakit_bundled_datasets | while IFS='|' read -r _bd_id _bd_label _bd_flag _bd_markers _bd_schema; do
        [ -n "$_bd_id" ] || continue
        exakit_dataset_loaded "$_bd_flag" "$_bd_markers" "$_bd_schema" "$_bd_id" \
            || printf '%s|%s\n' "$_bd_id" "$_bd_label"
    done
}

# exakit_verified_datasets — the ids of bundled datasets whose marker tables are
# ACTUALLY in the database right now, one per line, and the manifest flags healed
# to match. The verifying counterpart to the manifest read in
# exakit_loaded_datasets. Returns non-zero (and prints nothing) when the database
# cannot be asked, so the caller keeps the manifest's answer instead of reporting
# an empty database.
#
# ONE query for every marker table, not one per table: this runs inside
# `exakit status`, which agents call constantly and which used to cost nothing.
# Eight round trips to answer "what data is in there?" would be a tax on the
# command's whole reason to exist.
exakit_verified_datasets() {
    exakit_db_reachable || return 1
    _vd_present="$("$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" \
        "SELECT TABLE_SCHEMA || '.' || TABLE_NAME AS QUALIFIED FROM SYS.EXA_ALL_TABLES" \
        2>/dev/null)" || return 1
    _vd_ids=""
    _vd_heal=""
    # A pipeline would put this loop in a subshell and lose both accumulators,
    # so feed the list in through a here-doc instead. bash 3.2: no process
    # substitution, no lastpipe.
    while IFS='|' read -r _vd_id _vd_label _vd_flag _vd_markers _vd_schema; do
        [ -n "$_vd_id" ] || continue
        # No markers declared means nothing to verify — keep the manifest's word
        # rather than silently demoting the dataset to "not loaded".
        if [ -z "$_vd_markers" ]; then
            [ "$(manifest_get "$_vd_flag" 2>/dev/null)" = "true" ] && \
                _vd_ids="${_vd_ids}${_vd_id}
"
            continue
        fi
        _vd_ok=1
        for _vd_table in $(printf '%s' "$_vd_markers" | tr ',' ' '); do
            printf '%s\n' "$_vd_present" \
                | grep -Fqx "$_vd_schema.$_vd_table" || { _vd_ok=0; break; }
        done
        if [ "$_vd_ok" = 1 ]; then
            _vd_ids="${_vd_ids}${_vd_id}
"
            _vd_heal="${_vd_heal}${_vd_flag}=true
data.datasets.${_vd_id}.loaded=true
"
        else
            _vd_heal="${_vd_heal}${_vd_flag}=false
data.datasets.${_vd_id}.loaded=false
"
        fi
    done <<EOF
$(exakit_bundled_datasets)
EOF
    [ -n "$_vd_heal" ] && printf '%s' "$_vd_heal" | manifest_set_many
    [ -n "$_vd_ids" ] && printf '%s' "$_vd_ids"
    return 0
}

# exakit_load_dataset <kit_root> <id> [--force] — load one bundled dataset.
exakit_load_dataset() {
    case "$2" in
        tpch) exakit_load_sample_data "$1" "${3:-}" ;;
        *) exakit_load_dataset_dir "$1" "$2" "${3:-}" ;;
    esac
}

# exakit_load_dataset_dir <kit_root> <id> [--force] — generic pipeline for a
# directory-based bundled dataset (see the layout above): schema script, bulk
# files, optional transform, optional verify, then record the manifest flag.
# Mirrors exakit_load_sample_data step-for-step so datasets behave alike.
exakit_load_dataset_dir() {
    _ld_kit_root="$1"
    _ld_id="$2"
    _ld_force="${3:-}"
    _ld_dir="$_ld_kit_root/data/datasets/$_ld_id"
    [ -d "$_ld_dir" ] || die "Unknown bundled dataset: $_ld_id (no $_ld_dir)"
    # Each dataset loads into its own schema (schema= in dataset.conf, default
    # the id uppercased) so the tables stay grouped per dataset in the AI
    # client. The dataset's SQL scripts create and OPEN that same schema.
    _ld_schema="$(_exakit_dataset_conf_get schema "$_ld_dir/dataset.conf" 2>/dev/null)"
    [ -n "$_ld_schema" ] || _ld_schema="$(printf '%s' "$_ld_id" | tr '[:lower:]' '[:upper:]')"
    # Honor a flag= override in dataset.conf (TPC-H keeps the historical
    # data.loaded key); default to the per-dataset key.
    _ld_flag="$(_exakit_dataset_conf_get flag "$_ld_dir/dataset.conf" 2>/dev/null)"
    [ -n "$_ld_flag" ] || _ld_flag="data.datasets.${_ld_id}.loaded"

    [ -n "$(manifest_get components.exapump.profile 2>/dev/null)" ] || \
        die "No exapump connection profile is recorded — the exapump setup step has not completed. Re-run the installer, then retry."

    # Ask the DATABASE, not the manifest. Reading the flag directly here is what
    # let an install that had just replaced the deployment print "already
    # loaded" three times into a database with no schemas in it, and exit 0.
    # exakit_dataset_loaded re-checks the marker tables whenever the database is
    # reachable and heals both flags, so a destroy+redeploy reloads by itself.
    _ld_markers="$(_exakit_dataset_conf_get markers "$_ld_dir/dataset.conf" 2>/dev/null)"
    if [ "$_ld_force" != "--force" ] && \
       exakit_dataset_loaded "$_ld_flag" "$_ld_markers" "$_ld_schema" "$_ld_id"; then
        ok "Dataset '$_ld_id' already loaded (pass --force to re-run)"
        return 0
    fi

    info "Loading the '$_ld_id' dataset into schema $_ld_schema"

    # Schema script is OPTIONAL: exapump infers column types and creates the
    # table itself when none exists, so a dataset can ship as bare CSVs. The
    # script exists to pin exact types/precision and primary keys. When one is
    # present, verify the DDL really landed from a fresh connection and re-run
    # the idempotent script once if not (the database can report a DDL batch
    # as applied while still stabilizing after first boot).
    if [ -s "$_ld_dir/01_create_schema.sql" ]; then
        exapump_run_sql_file "$_ld_dir/01_create_schema.sql" "$_ld_id schema (01_create_schema.sql)"
        if ! exakit_schema_present "$_ld_schema"; then
            warn "Schema $_ld_schema is not present after creation — re-running the schema script"
            exapump_run_sql_file "$_ld_dir/01_create_schema.sql" "$_ld_id schema (re-run)"
            exakit_schema_present "$_ld_schema" || \
                die "Schema $_ld_schema was reported created but does not exist. The database may still be stabilizing after first boot; wait a moment and retry: exakit data-load"
        fi
    else
        exakit_ensure_schema "$_ld_schema" || die "Could not create schema $_ld_schema."
    fi

    _ld_tables=""
    for _ld_csv in "$_ld_dir"/data/*.csv; do
        [ -s "$_ld_csv" ] || continue
        _ld_table="$(basename "$_ld_csv" .csv | tr '[:lower:]' '[:upper:]')"
        exapump_upload "$_ld_csv" "$_ld_schema.$_ld_table"
        _ld_tables="$_ld_tables $_ld_table"
    done

    if [ -s "$_ld_dir/02_load_data.sql" ]; then
        exapump_run_sql_file "$_ld_dir/02_load_data.sql" "$_ld_id load statements (02_load_data.sql)"
    fi

    if [ -s "$_ld_dir/03_verify_setup.sql" ]; then
        info "Verification ($_ld_id 03_verify_setup.sql):"
        _ld_verify="$(mktemp "${TMPDIR:-/tmp}/exakit-verify.XXXXXX")" || \
            die "Could not create a temporary file for verification output."
        "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" < "$_ld_dir/03_verify_setup.sql" \
            > "$_ld_verify" 2>> "${EXAKIT_LOG_FILE:-/dev/null}"
        _ld_verify_status=$?
        exakit_stream_foreign < "$_ld_verify"
        # Grade on the STATUS column value ",FAIL," — not the bare word. The
        # verify SQL is full of the literal string (its header comment and every
        # "CASE … ELSE 'FAIL' END" clause), so matching bare FAIL would fail a
        # dataset even when every row reads OK. A real failing check emits an
        # unquoted STATUS column (check_name,FAIL,detail). Mirrors exapump.ps1.
        if [ "$_ld_verify_status" -ne 0 ] || grep -q ',FAIL,' "$_ld_verify"; then
            rm -f "$_ld_verify"
            die "Verification failed for dataset '$_ld_id' — see ${EXAKIT_LOG_FILE:-the log}. Data is loaded but not marked ready; fix the underlying issue and re-run with --force."
        fi
        rm -f "$_ld_verify"
    fi

    # Row-count summary over the dataset's tables: every uploaded CSV table
    # plus the conf's marker tables (covers SQL-generated tables too).
    _ld_markers="$(_exakit_dataset_conf_get markers "$_ld_dir/dataset.conf" 2>/dev/null | tr ',' ' ')"
    for _ld_marker in $_ld_markers; do
        case " $_ld_tables " in *" $_ld_marker "*) ;; *) _ld_tables="$_ld_tables $_ld_marker" ;; esac
    done
    if [ -n "$_ld_tables" ]; then
        ui_panel_begin "Row counts"
        for _ld_table in $_ld_tables; do
            _ld_rows="$(exapump_count "$_ld_schema.$_ld_table")"
            _ld_row_line="$(printf '%-30s %s rows' "$_ld_schema.$_ld_table" "${_ld_rows:-?}")"
            ui_panel_line "$_ld_row_line"
            _exakit_log_file "DATA  $_ld_row_line"
        done
        ui_panel_end
    fi

    manifest_set "$_ld_flag" true
    # Also record the canonical per-dataset key so data.datasets is a complete
    # map even for datasets that keep a legacy flag (TPC-H uses data.loaded for
    # backward compatibility). data.loaded is left untouched for existing installs.
    _ld_canonical="data.datasets.${_ld_id}.loaded"
    [ "$_ld_flag" = "$_ld_canonical" ] || manifest_set "$_ld_canonical" true
    manifest_set data.last_load.source "dataset:$_ld_id"
    ok "Dataset '$_ld_id' loaded and verified"
}

# exakit_data_load_select <final_label> — dynamic checkbox over the data
# sources, shown as a small tree with exactly three top-level choices:
#
#   Sample datasets                 <- group header (only when any is pending)
#     [x] <each dataset not loaded yet, visible upfront and individually
#          selectable — no extra keypress needed to see what is available>
#   [ ] A local CSV / Parquet / JSON file
#   [ ] <final_label>               <- mutually exclusive opt-out (Cancel/Skip)
#
# Already-loaded datasets are not offered; when every bundled dataset is
# loaded the group disappears and only the local-file and opt-out choices
# remain. Pending datasets are pre-selected; with none pending the opt-out is
# the (safe) default, which is also what a non-interactive run keeps. The
# result lands in EXAKIT_DATA_LOAD_SELECTION as a csv of ids ("tpch",
# "local") or "none".
EXAKIT_DATA_LOAD_SELECTION=""
exakit_data_load_select() {
    _dls_final_label="$1"
    _dls_labels=()
    _dls_ids=()
    _dls_pending_n=0
    # Collect the pending datasets first so we know which one is last and can
    # give it the tree's corner connector.
    _dls_pend_ids=()
    _dls_pend_labels=()
    while IFS='|' read -r _dls_id _dls_label; do
        [ -n "$_dls_id" ] || continue
        _dls_pend_ids+=("$_dls_id")
        _dls_pend_labels+=("$_dls_label")
        _dls_pending_n=$((_dls_pending_n + 1))
    done <<EXAKIT_DLS_EOF
$(exakit_pending_datasets)
EXAKIT_DLS_EOF
    if [ "$_dls_pending_n" -gt 0 ]; then
        # The group row is itself a checkbox: pre-selected with every dataset;
        # unchecking it clears all datasets, after which the user can pick
        # them individually. Each dataset hangs off it with a tree connector
        # (UI_TEE/UI_CORNER from the ui palette; ASCII in plain mode) so the
        # parent-child relationship is visible, not just implied by indent.
        # Mirrors exapump.ps1, where the palette is mandatory: glyph literals
        # in the BOM-less .ps1 twin break Windows PowerShell 5.1 parsing.
        _dls_tee="${UI_TEE:-|-}"; _dls_corner="${UI_CORNER:-\`-}"
        _dls_labels+=("Sample datasets")
        _dls_ids+=("__group__")
        _dls_i=0
        while [ "$_dls_i" -lt "$_dls_pending_n" ]; do
            if [ "$_dls_i" -eq $((_dls_pending_n - 1)) ]; then _dls_conn="$_dls_corner"; else _dls_conn="$_dls_tee"; fi
            _dls_labels+=("$_dls_conn ${_dls_pend_labels[$_dls_i]}")
            _dls_ids+=("${_dls_pend_ids[$_dls_i]}")
            _dls_i=$((_dls_i + 1))
        done
    fi
    _dls_labels+=("A local CSV / Parquet / JSON file"); _dls_ids+=("local")
    _dls_labels+=("$_dls_final_label");        _dls_ids+=("none")
    _dls_final_idx="${#_dls_labels[@]}"
    if [ "$_dls_pending_n" -gt 0 ]; then
        # Default: the group AND every pending dataset (rows 1..pending+1).
        _dls_defaults=""
        _dls_i=1
        while [ "$_dls_i" -le $((_dls_pending_n + 1)) ]; do
            _dls_defaults="${_dls_defaults:+$_dls_defaults,}$_dls_i"
            _dls_i=$((_dls_i + 1))
        done
        # "all": master toggle, checked only while EVERY dataset is. See the
        # same spec in exakit_marketplace_menu — one child ticked must not
        # render as a checked parent, or the row lies about what will load.
        EXAKIT_CHECKBOX_GROUP="1:2:$((_dls_pending_n + 1)):all"
    else
        info "Every bundled dataset is already loaded (reload with: exakit data-load --force)."
        _dls_defaults="$_dls_final_idx"
    fi
    EXAKIT_CHECKBOX_EXCLUSIVE="$_dls_final_idx"
    ui_checkbox_menu "Select data to load" "$_dls_defaults" "${_dls_labels[@]}"
    case ",$EXAKIT_CHECKBOX_SELECTION," in
        *",$_dls_final_idx,"*)
            EXAKIT_DATA_LOAD_SELECTION="none"
            return 0
            ;;
    esac
    EXAKIT_DATA_LOAD_SELECTION=""
    for _dls_idx in $(printf '%s' "$EXAKIT_CHECKBOX_SELECTION" | tr ',' ' '); do
        [ "$_dls_idx" -ge 1 ] && [ "$_dls_idx" -lt "$_dls_final_idx" ] || continue
        _dls_id="${_dls_ids[$((_dls_idx - 1))]}"
        [ "$_dls_id" = "__group__" ] && continue
        EXAKIT_DATA_LOAD_SELECTION="${EXAKIT_DATA_LOAD_SELECTION:+$EXAKIT_DATA_LOAD_SELECTION,}$_dls_id"
    done
    [ -n "$EXAKIT_DATA_LOAD_SELECTION" ] || EXAKIT_DATA_LOAD_SELECTION="none"
    return 0
}

# Standalone `exakit data-load` menu: the dynamic dataset checkbox with a
# plain Cancel as the opt-out.
exakit_data_load_menu() {
    [ -n "$(manifest_get components.exapump.profile 2>/dev/null)" ] || \
        die "No exapump connection profile is recorded — re-run the installer, then retry."

    exakit_data_load_select "Cancel (load nothing)"
    if [ "$EXAKIT_DATA_LOAD_SELECTION" = "none" ]; then
        info "Data loading cancelled."
        return 0
    fi
    _menu_status=0
    for _menu_id in $(printf '%s' "$EXAKIT_DATA_LOAD_SELECTION" | tr ',' ' '); do
        case "$_menu_id" in
            local)
                exakit_load_local_file
                _local_status=$?
                if [ "$_local_status" -eq 2 ]; then
                    info "Local file load skipped. Run it any time with: exakit data-load"
                elif [ "$_local_status" -ne 0 ]; then
                    _menu_status="$_local_status"
                fi
                ;;
            *)
                _kit_root="$(exakit_repo_root)" || die "Could not find the kit's sql/ and data/ files to load."
                exakit_load_dataset "$_kit_root" "$_menu_id"
                ;;
        esac
    done
    return "$_menu_status"
}

# exakit_load_sample_data <kit_root> [--force] — the TPC-H sample-data entry
# point, kept for its long-standing callers (setup/load-data.sh, the installer
# EXAKIT_LOAD_SAMPLE path, and `exakit data-load --force`). TPC-H now lives in
# data/datasets/tpch/ like every other bundled dataset, so this simply
# delegates to the generic directory pipeline.
exakit_load_sample_data() {
    exakit_load_dataset_dir "$1" tpch "${2:-}"
}
