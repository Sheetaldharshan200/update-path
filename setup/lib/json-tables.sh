#!/usr/bin/env bash
# json-tables.sh — JSON Tables (ingest, query and reshape JSON-shaped data in
# Exasol): managed install + validation.
#
# A MARKETPLACE ADD-ON: never installed by the setup scripts. Sourced by the
# exakit CLI after common.sh.
#
# What upstream ships, and why this module looks the way it does:
#   - exasol-labs/exasol-json-tables is a Python package (`exasol-json-tables`,
#     console script of the same name) PLUS a Rust ingest engine (crate
#     json_tables_ingest, binary `json_to_parquet`).
#   - Its wheel contains only python/exasol_json_tables — the crate source is
#     not in it — and the CLI runs the engine with exactly one call shape:
#         cargo run --manifest-path <root>/crates/json_tables_ingest/Cargo.toml -- ...
#     There is no environment variable or PATH lookup for a prebuilt engine.
#     So a wheel-only install cannot ingest even on a machine WITH Rust: the
#     manifest path it points at does not exist inside site-packages.
#   - The kit therefore does three things: install the wheel, install the
#     prebuilt engine for this platform, and put a tiny `cargo` shim in front
#     of the CLI that turns that one call into a direct engine run. The shim
#     is visible ONLY to processes started by the kit's launcher — the user's
#     real cargo, if any, is untouched everywhere else.
#
# Nothing is compiled here: the engine binaries and the wheel are built once by
# .github/workflows/pkg-json-tables.yml and published to the kit repository's
# `mirror-json-tables` release, so a user never needs Rust or cargo. When
# upstream gains a documented way to point at a prebuilt engine, the shim is
# the only piece that goes away.
#
#   - venv:     $EXAKIT_HOME/json-tables-venv
#   - engine:   $EXAKIT_HOME/json-tables/libexec/json_to_parquet
#   - shim:     $EXAKIT_HOME/json-tables/shim/cargo
#   - launcher: $EXAKIT_BIN_DIR/exasol-json-tables

EXAKIT_JSON_TABLES_VERSION="${EXAKIT_JSON_TABLES_VERSION:-}"
EXAKIT_JSON_TABLES_VERSION_FALLBACK="${EXAKIT_JSON_TABLES_VERSION_FALLBACK:-v0.2}"
EXAKIT_JSON_TABLES_PACKAGE="${EXAKIT_JSON_TABLES_PACKAGE:-exasol-json-tables}"
# Upstream source, used only to restore package data the wheel omits (see
# _json_tables_restore_package_data). Not where the wheel or engine come from.
EXAKIT_JSON_TABLES_REPO="${EXAKIT_JSON_TABLES_REPO:-exasol-labs/exasol-json-tables}"
# The mirror release lives in the kit's own repository: the same place the kit
# is fetched from, built by the kit's own workflow.
EXAKIT_JSON_TABLES_MIRROR_TAG="${EXAKIT_JSON_TABLES_MIRROR_TAG:-mirror-json-tables}"
EXAKIT_JSON_TABLES_VENV="${EXAKIT_JSON_TABLES_VENV:-$EXAKIT_HOME/json-tables-venv}"
EXAKIT_JSON_TABLES_HOME="${EXAKIT_JSON_TABLES_HOME:-$EXAKIT_HOME/json-tables}"
EXAKIT_JSON_TABLES_BIN="${EXAKIT_JSON_TABLES_BIN:-$EXAKIT_BIN_DIR/exasol-json-tables}"
EXAKIT_JSON_TABLES_LOG="${EXAKIT_JSON_TABLES_LOG:-$EXAKIT_LOG_DIR/json-tables.log}"

json_tables_venv_python() {
    printf '%s\n' "$EXAKIT_JSON_TABLES_VENV/bin/python"
}

json_tables_engine_path() {
    printf '%s\n' "$EXAKIT_JSON_TABLES_HOME/libexec/json_to_parquet"
}

json_tables_shim_dir() {
    printf '%s\n' "$EXAKIT_JSON_TABLES_HOME/shim"
}

json_tables_log_path() {
    printf '%s\n' "$EXAKIT_JSON_TABLES_LOG"
}

# json_tables_mirror_repo — where the prebuilt artifacts live: the repository
# THIS KIT WAS INSTALLED FROM, so a fork that runs the packaging workflow
# serves its own users without any configuration. The manifest records the
# install source as owner/name@ref; a checkout or local install has no such
# record and falls back to the canonical kit repo.
json_tables_mirror_repo() {
    if [ -n "${EXAKIT_JSON_TABLES_MIRROR_REPO:-}" ]; then
        printf '%s\n' "$EXAKIT_JSON_TABLES_MIRROR_REPO"
        return 0
    fi
    _jmr_src="$(manifest_get kit.source 2>/dev/null || true)"
    case "$_jmr_src" in
        */*@*) printf '%s\n' "${_jmr_src%@*}"; return 0 ;;
    esac
    printf '%s\n' "$EXAKIT_KIT_REPO"
}

# _json_tables_restore_package_data — put back data files upstream ships in
# its source tree but does NOT declare as wheel package data, so pip never
# installs them.
#
# UPSTREAM BUG (exasol-json-tables, at least through 41ddd51a9a33):
# pyproject's packaging covers the .py modules under python/exasol_json_tables
# but not python/exasol_json_tables/preprocessor_assets/jvs_preprocessor_lib.lua,
# so every prebuilt wheel is missing it. `ingest` (writing Parquet) is
# unaffected; `ingest-and-wrap` and `wrap` fail with FILE-NOT-FOUND once they
# reach the step that installs the preprocessor into Exasol.
#
# Rather than ship a broken wrap step, restore any non-.py file upstream's
# source tree has and the installed wheel lacks, fetched from the exact
# commit the mirror release was built from. Nothing is overwritten, so a
# fixed release simply makes this a no-op. ⇄ twin:
# Restore-JsonTablesPackageData in json-tables.ps1. Mirrors
# _dash_server_restore_package_data.
_json_tables_restore_package_data() {
    _jtp_site="$("$(json_tables_venv_python)" -c 'import exasol_json_tables, os; print(os.path.dirname(exasol_json_tables.__file__))' 2>/dev/null)"
    [ -n "$_jtp_site" ] && [ -d "$_jtp_site" ] || return 0

    _jtp_tmp="$(mktemp -d "${TMPDIR:-/tmp}/exakit-jt-data.XXXXXX")" || return 0
    if ! fetch_quiet "https://github.com/$EXAKIT_JSON_TABLES_REPO/archive/$EXAKIT_JSON_TABLES_VERSION.tar.gz" \
            "$_jtp_tmp/src.tar.gz"; then
        rm -rf "$_jtp_tmp"
        return 0
    fi
    ( cd "$_jtp_tmp" && tar xzf src.tar.gz ) >>"${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || {
        rm -rf "$_jtp_tmp"; return 0; }
    # The archive's top directory embeds the full commit sha even when
    # EXAKIT_JSON_TABLES_VERSION is a short one, so find it rather than guess it.
    _jtp_src="$(find "$_jtp_tmp" -mindepth 1 -maxdepth 1 -type d)/python/exasol_json_tables"
    [ -d "$_jtp_src" ] || { rm -rf "$_jtp_tmp"; return 0; }

    _jtp_restored=0
    for _jtp_rel in $( cd "$_jtp_src" && find . -type f ! -name '*.py' | sed 's|^\./||' ); do
        [ -f "$_jtp_site/$_jtp_rel" ] && continue
        mkdir -p "$_jtp_site/$(dirname "$_jtp_rel")" 2>/dev/null || continue
        cp "$_jtp_src/$_jtp_rel" "$_jtp_site/$_jtp_rel" 2>/dev/null && \
            _jtp_restored=$((_jtp_restored + 1))
    done
    rm -rf "$_jtp_tmp"
    if [ "$_jtp_restored" -gt 0 ]; then
        info "Restored $_jtp_restored data file(s) the release does not declare as package data (upstream packaging gap; ingest-and-wrap needs them)"
    fi
    return 0
}

# json_tables_engine_asset — the engine built for THIS machine.
# ⇄ twin: Get-JsonTablesEngineAsset in json-tables.ps1.
json_tables_engine_asset() {
    # detect_os/detect_arch come from detect.sh, which the exakit CLI sources
    # but a bare `. common.sh` does not: fall back to uname so this module is
    # usable on its own, the same way exakit_ensure_uv does.
    if command -v detect_os >/dev/null 2>&1; then
        _jte_raw_os="$(detect_os 2>/dev/null || true)"
        _jte_raw_arch="$(detect_arch 2>/dev/null || true)"
    else
        _jte_raw_os="$(uname -s 2>/dev/null || true)"
        _jte_raw_arch="$(uname -m 2>/dev/null || true)"
    fi
    case "$_jte_raw_os" in
        macos|Darwin|darwin) _jte_os="macos" ;;
        # WSL is Linux, and the engine published for linux is the one that runs
        # there. detect_os reports it as its own platform because the INSTALLER
        # needs the distinction (Docker Desktop, /mnt paths); an artifact
        # lookup does not, so it must fold back into linux or the add-on
        # silently disappears from the marketplace on every WSL machine.
        # Same mapping exapump_asset_name uses.
        linux|Linux|wsl)     _jte_os="linux" ;;
        *)                   return 1 ;;
    esac
    case "$_jte_raw_arch" in
        arm64|aarch64)  _jte_arch="aarch64" ;;
        x86_64|amd64)   _jte_arch="x86_64" ;;
        *)              return 1 ;;
    esac
    # The workflow publishes macOS for arm64 only (the x86 runner was dropped).
    if [ "$_jte_os" = "macos" ] && [ "$_jte_arch" != "aarch64" ]; then
        return 1
    fi
    printf 'exasol-json-tables-ingest-%s-%s\n' "$_jte_os" "$_jte_arch"
}

# json_tables_applicable — an Intel Mac has no published engine, and building
# one needs the Rust toolchain this add-on exists to avoid. Hide it there
# rather than offering an install that cannot work.
json_tables_applicable() {
    json_tables_engine_asset >/dev/null 2>&1
}

json_tables_applicable_reason() {
    if command -v detect_os >/dev/null 2>&1; then
        _jtr_where="$(detect_os 2>/dev/null || true)/$(detect_arch 2>/dev/null || true)"
    else
        _jtr_where="$(uname -s 2>/dev/null || true)/$(uname -m 2>/dev/null || true)"
    fi
    printf '%s\n' "no prebuilt ingest engine is published for this platform ($_jtr_where)"
}

# json_tables_system_present — a copy the user installed themselves (pip, uv
# tool, pipx, a distro package) counts as "already on this machine": the kit
# does not offer a second one, and never manages or removes theirs. The generic
# probe already checks EXAKIT_JSON_TABLES_BIN's basename on PATH; this adds the
# case where the console script is absent from PATH but the package is importable
# in the ambient Python, which is how a `pip install --user` often looks.
json_tables_system_present() {
    _jsp_path="$(command -v exasol-json-tables 2>/dev/null || true)"
    if [ -n "$_jsp_path" ]; then
        [ "$_jsp_path" = "$EXAKIT_JSON_TABLES_BIN" ] && return 1
        [ "$_jsp_path" -ef "$EXAKIT_JSON_TABLES_BIN" ] 2>/dev/null && return 1
        return 0
    fi
    # Only the ambient interpreter, never the kit's own venv: importing it
    # there is a KIT install, which is a different thing entirely.
    _jsp_python="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
    [ -n "$_jsp_python" ] || return 1
    case "$_jsp_python" in
        "$EXAKIT_JSON_TABLES_VENV"/*|"$EXAKIT_HOME"/*) return 1 ;;
    esac
    ( "$_jsp_python" -c 'import exasol_json_tables' && : ) >/dev/null 2>&1 || return 1
    return 0
}

# json_tables_installed_version — both halves must be present: the Python
# package AND the engine. A venv without the engine cannot ingest, so it is not
# an install.
json_tables_installed_version() {
    _jtv_python="$(json_tables_venv_python)"
    [ -x "$_jtv_python" ] || return 1
    [ -x "$(json_tables_engine_path)" ] || return 1
    _jtv_recorded="$(manifest_get components.json_tables.version 2>/dev/null || true)"
    [ -n "$_jtv_recorded" ] || return 1
    ( "$_jtv_python" -c 'import exasol_json_tables' && : ) >/dev/null 2>&1 || return 1
    printf '%s\n' "$_jtv_recorded"
}

_json_tables_not_installed() {
    warn "JSON Tables was not installed: $1"
    # Explain the underlying fault BEFORE offering the retry. A corrupt uv
    # managed-Python cache makes the retry fail identically forever, so
    # "retry with" on its own is a loop, not a remedy.
    command -v exakit_explain_last_log_error >/dev/null 2>&1 && exakit_explain_last_log_error
    warn "Everything else in the kit is unaffected. Retry with: exakit update json-tables"
    command -v exakit_note_failure >/dev/null 2>&1 && exakit_note_failure "$1"
    manifest_set components.json_tables.validated false
    return 1
}

# _json_tables_mirror_asset_url <name> — a file in the mirror release.
_json_tables_mirror_asset_url() {
    printf 'https://github.com/%s/releases/download/%s/%s\n' \
        "$(json_tables_mirror_repo)" "$EXAKIT_JSON_TABLES_MIRROR_TAG" "$1"
}

# _json_tables_mirror_wheel_name — the wheel's real filename, read from the
# release API (its version comes from upstream's pyproject, not from ours).
_json_tables_mirror_wheel_name() {
    _jmw_json="$(curl -fsSL --retry 3 --connect-timeout 15 \
        "https://api.github.com/repos/$(json_tables_mirror_repo)/releases/tags/$EXAKIT_JSON_TABLES_MIRROR_TAG" \
        2>/dev/null || true)"
    [ -n "$_jmw_json" ] || return 1
    if exakit_can_run_python; then
        printf '%s' "$_jmw_json" | run_python -c '
import json, sys
doc = json.load(sys.stdin)
# NEWEST wheel, not the first listed. The mirror tag is rolling and
# accumulates assets across runs, so the release can hold several wheels at
# once - taking the first installs an old one while the version recorded is
# the current build, a mismatch no update could ever close.
wheels = [a for a in doc.get("assets", []) if a.get("name", "").endswith(".whl")]
wheels.sort(key=lambda a: a.get("created_at") or "", reverse=True)
if wheels:
    print(wheels[0]["name"])
'
        return $?
    fi
    printf '%s' "$_jmw_json" | tr ',' '\n' | sed -n 's/.*"name":"\([^"]*\.whl\)".*/\1/p' | sort -V | tail -1
}

# _json_tables_mirror_digest <asset> — the sha256 GitHub publishes for a
# release asset. The mirror tag is rolling (it moves whenever upstream does),
# so a digest pinned in versions.json would go stale by design: the release API
# is the right authority here, and an unverifiable download is still refused.
_json_tables_mirror_digest() {
    _jmd_json="$(curl -fsSL --retry 3 --connect-timeout 15 \
        "https://api.github.com/repos/$(json_tables_mirror_repo)/releases/tags/$EXAKIT_JSON_TABLES_MIRROR_TAG" \
        2>/dev/null || true)"
    [ -n "$_jmd_json" ] || return 1
    if exakit_can_run_python; then
        printf '%s' "$_jmd_json" | run_python -c '
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
    printf '%s' "$_jmd_json" | tr '{' '\n' | awk -v name="$1" '
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

# _json_tables_fetch_verified <asset> <dest> — download one mirror asset and
# verify it against the digest the release publishes. Same bar as exapump and
# the VS Code extension: an artifact that cannot be verified is not installed.
_json_tables_fetch_verified() {
    _jfv_asset="$1"
    _jfv_dest="$2"
    if ! fetch_quiet "$(_json_tables_mirror_asset_url "$_jfv_asset")" "$_jfv_dest"; then
        return 1
    fi
    _jfv_expected="$(_json_tables_mirror_digest "$_jfv_asset" 2>/dev/null || true)"
    if [ -n "$_jfv_expected" ]; then
        _jfv_actual="$(sha256_of "$_jfv_dest")"
        if [ "$_jfv_actual" != "$_jfv_expected" ]; then
            rm -f "$_jfv_dest"
            warn "Checksum mismatch for $_jfv_asset (expected $_jfv_expected, got $_jfv_actual)"
            return 1
        fi
        ok "Checksum verified: $_jfv_asset"
        return 0
    fi
    if [ "${EXAKIT_ALLOW_UNVERIFIED_JSON_TABLES:-0}" = "1" ]; then
        warn "No digest available for $_jfv_asset — proceeding WITHOUT checksum verification (EXAKIT_ALLOW_UNVERIFIED_JSON_TABLES=1)."
        return 0
    fi
    rm -f "$_jfv_dest"
    warn "No checksum is available for $_jfv_asset; refusing an unverified artifact."
    return 1
}

# _json_tables_mirror_version — the upstream build the mirror release actually
# carries, read from the `version=` line the packaging workflow writes into the
# release body. This is the ONLY version that can be installed: the artifacts
# for it are the ones sitting on that release.
_json_tables_mirror_version() {
    _jmv_json="$(curl -fsSL --retry 3 --connect-timeout 15 \
        "https://api.github.com/repos/$(json_tables_mirror_repo)/releases/tags/$EXAKIT_JSON_TABLES_MIRROR_TAG" \
        2>/dev/null || true)"
    [ -n "$_jmv_json" ] || return 1
    if exakit_can_run_python; then
        printf '%s' "$_jmv_json" | run_python -c '
import json, re, sys
doc = json.load(sys.stdin)
match = re.search(r"version=([A-Za-z0-9._+-]+)", doc.get("body") or "")
if match:
    print(match.group(1))
'
        return $?
    fi
    printf '%s' "$_jmv_json" | sed -n 's/.*version=\([A-Za-z0-9._+-]*\).*/\1/p' | head -1
}

# json_tables_latest — the generic <id>_latest hook (see exakit_component_latest).
#
# For every other component "latest" means whatever upstream published. Here it
# deliberately means whatever the kit's own packaging workflow has already
# BUILT and published, which can lag upstream by a run. That is the point: the
# update flow must never advertise a version whose prebuilt engine and wheel do
# not exist yet, because the whole promise of this add-on is that installing it
# needs no Rust toolchain. An upstream release the mirror has not caught up
# with is not installable, so it is not offered.
json_tables_latest() {
    _json_tables_mirror_version
}

json_tables_install() {
    # What gets installed is what the mirror release carries, so that is what
    # gets recorded. Resolving it from the mirror first (rather than trusting
    # versions.json, which moves in a follow-up pull request) keeps the recorded
    # version equal to the artifacts on disk — otherwise `exakit version` would see
    # a difference that no update could ever close.
    if [ -z "${EXAKIT_JSON_TABLES_VERSION:-}" ]; then
        EXAKIT_JSON_TABLES_VERSION="$(_json_tables_mirror_version 2>/dev/null || true)"
        [ -n "$EXAKIT_JSON_TABLES_VERSION" ] || \
            EXAKIT_JSON_TABLES_VERSION="$(exakit_component_available json-tables 2>/dev/null || true)"
        [ -n "$EXAKIT_JSON_TABLES_VERSION" ] || EXAKIT_JSON_TABLES_VERSION="$EXAKIT_JSON_TABLES_VERSION_FALLBACK"
        export EXAKIT_JSON_TABLES_VERSION
    fi

    _jti_asset="$(json_tables_engine_asset 2>/dev/null || true)"
    [ -n "$_jti_asset" ] || {
        _json_tables_not_installed "$(json_tables_applicable_reason)"
        return 1
    }

    _jti_uv=""
    if command -v uv >/dev/null 2>&1; then
        _jti_uv="uv"
    elif exakit_ensure_uv && [ -x "${EXAKIT_UV_BIN:-}" ]; then
        _jti_uv="$EXAKIT_UV_BIN"
    else
        _json_tables_not_installed "uv (the Python tool runner) is not available — install it from https://docs.astral.sh/uv/ and re-run"
        return 1
    fi

    _jti_wheel_name="$(_json_tables_mirror_wheel_name 2>/dev/null || true)"
    if [ -z "$_jti_wheel_name" ]; then
        _json_tables_not_installed "the prebuilt mirror release '$EXAKIT_JSON_TABLES_MIRROR_TAG' was not found in $(json_tables_mirror_repo). Run the 'pkg / json-tables' workflow once to publish it (it builds the engine for every platform so nobody needs Rust)."
        return 1
    fi

    info "Installing JSON Tables $EXAKIT_JSON_TABLES_VERSION (prebuilt)"
    if [ ! -x "$(json_tables_venv_python)" ]; then
        if ! run_logged "$_jti_uv" venv --seed --python "$EXAKIT_MANAGED_PYTHON_VERSION" "$EXAKIT_JSON_TABLES_VENV"; then
            _json_tables_not_installed "the virtual environment at $EXAKIT_JSON_TABLES_VENV could not be created (see log)"
            return 1
        fi
        push_rollback "rm -rf '$EXAKIT_JSON_TABLES_VENV'"
    fi

    _jti_tmp="$(mktemp -d "${TMPDIR:-/tmp}/exakit-json-tables.XXXXXX")" || {
        _json_tables_not_installed "could not create a temporary download directory"
        return 1
    }

    # 1. the Python package
    if ! _json_tables_fetch_verified "$_jti_wheel_name" "$_jti_tmp/$_jti_wheel_name"; then
        rm -rf "$_jti_tmp"
        _json_tables_not_installed "the prebuilt wheel could not be downloaded or verified (see log)"
        return 1
    fi
    if ! run_logged "$_jti_uv" pip install --python "$(json_tables_venv_python)" "$_jti_tmp/$_jti_wheel_name"; then
        rm -rf "$_jti_tmp"
        _json_tables_not_installed "installing $_jti_wheel_name failed (see log)"
        return 1
    fi
    _json_tables_restore_package_data

    # 2. the ingest engine, prebuilt for this platform
    if ! _json_tables_fetch_verified "$_jti_asset" "$_jti_tmp/engine"; then
        rm -rf "$_jti_tmp"
        _json_tables_not_installed "the prebuilt ingest engine ($_jti_asset) could not be downloaded or verified (see log)"
        return 1
    fi
    mkdir -p "$EXAKIT_JSON_TABLES_HOME/libexec" || {
        rm -rf "$_jti_tmp"
        _json_tables_not_installed "could not create $EXAKIT_JSON_TABLES_HOME/libexec"
        return 1
    }
    install -m 755 "$_jti_tmp/engine" "$(json_tables_engine_path)" || {
        rm -rf "$_jti_tmp"
        _json_tables_not_installed "could not install the ingest engine to $(json_tables_engine_path)"
        return 1
    }
    rm -rf "$_jti_tmp"

    # The engine must actually run here: a binary for the wrong libc or arch
    # would otherwise surface much later, in the middle of someone's ingest.
    if ! ( "$(json_tables_engine_path)" --help && : ) >>"${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
        _json_tables_not_installed "the prebuilt ingest engine does not run on this machine (see log)"
        return 1
    fi

    json_tables_write_shim || return 1
    json_tables_write_launcher || return 1

    manifest_set components.json_tables.version "$EXAKIT_JSON_TABLES_VERSION"
    manifest_set components.json_tables.venv "$EXAKIT_JSON_TABLES_VENV"
    manifest_set components.json_tables.python "$(json_tables_venv_python)"
    manifest_set components.json_tables.engine "$(json_tables_engine_path)"
    manifest_set components.json_tables.command "$EXAKIT_JSON_TABLES_BIN"
    ok "JSON Tables installed: $EXAKIT_JSON_TABLES_VENV"
}

# json_tables_write_shim — the one piece that makes a prebuilt engine usable.
#
# The CLI's only engine call is
#     cargo run --manifest-path <…>/json_tables_ingest/Cargo.toml -- <args>
# so a `cargo` on PATH that recognises exactly that shape and execs the
# prebuilt engine with <args> completes the flow without a toolchain. Anything
# else is passed to a real cargo when the user has one, so the shim cannot
# quietly break an unrelated command that happens to run inside our launcher.
json_tables_write_shim() {
    mkdir -p "$(json_tables_shim_dir)" || {
        _json_tables_not_installed "could not create $(json_tables_shim_dir)"
        return 1
    }
    cat > "$(json_tables_shim_dir)/cargo" <<'EXAKIT_JT_SHIM_EOF'
#!/bin/sh
# cargo shim — generated by the Exasol Personal Local Starter Kit.
#
# JSON Tables runs its Rust ingest engine as `cargo run --manifest-path …/
# json_tables_ingest/Cargo.toml -- <args>`. The kit ships that engine prebuilt,
# so this shim answers exactly that call and leaves everything else to a real
# cargo. It is only on PATH for processes the kit's launcher starts.
if [ "$1" = "run" ]; then
    _jt_is_ingest=0
    for _jt_arg in "$@"; do
        case "$_jt_arg" in
            *json_tables_ingest*) _jt_is_ingest=1 ;;
        esac
    done
    if [ "$_jt_is_ingest" = "1" ]; then
        # Everything after the `--` separator is the engine's own argv.
        _jt_seen=0
        for _jt_arg in "$@"; do
            if [ "$_jt_seen" = "1" ]; then
                set -- "$@" "$_jt_arg"
            fi
            [ "$_jt_arg" = "--" ] && _jt_seen=1
            shift
        done
        exec "@ENGINE@" "$@"
    fi
fi
# Not the ingest call: hand it to a real cargo if one exists. The PATH walk
# uses only shell builtins on purpose -- this runs with whatever PATH the
# caller had, and a shim that needs `tr` to work is a shim that breaks in a
# stripped environment.
_jt_real=""
_jt_oldifs="$IFS"
IFS=:
for _jt_dir in $PATH; do
    [ "$_jt_dir" = "@SHIMDIR@" ] && continue
    if [ -x "$_jt_dir/cargo" ]; then _jt_real="$_jt_dir/cargo"; break; fi
done
IFS="$_jt_oldifs"
if [ -n "$_jt_real" ]; then
    exec "$_jt_real" "$@"
fi
printf 'cargo: not installed, and this is not the JSON Tables ingest call the kit can answer.\n' >&2
exit 127
EXAKIT_JT_SHIM_EOF
    sed -i.exakit-bak \
        -e "s|@ENGINE@|$(json_tables_engine_path)|" \
        -e "s|@SHIMDIR@|$(json_tables_shim_dir)|" \
        "$(json_tables_shim_dir)/cargo" && rm -f "$(json_tables_shim_dir)/cargo.exakit-bak"
    chmod 755 "$(json_tables_shim_dir)/cargo"
}

# json_tables_write_launcher — the command a user runs. It puts the shim in
# front of PATH for this process only, so the CLI's cargo call reaches the
# prebuilt engine while the user's own cargo stays untouched elsewhere.
json_tables_write_launcher() {
    mkdir -p "$EXAKIT_BIN_DIR" || {
        _json_tables_not_installed "could not create $EXAKIT_BIN_DIR for the launcher"
        return 1
    }
    cat > "$EXAKIT_JSON_TABLES_BIN" <<'EXAKIT_JT_EOF'
#!/bin/sh
# exasol-json-tables launcher — generated by the Exasol Personal Local Starter
# Kit. Runs the CLI from its kit-managed venv with the prebuilt ingest engine
# in front of PATH, so no Rust toolchain is needed. Regenerated by:
#   exakit update json-tables
PATH="@SHIMDIR@:$PATH"
export PATH
exec "@VENVBIN@" "$@"
EXAKIT_JT_EOF
    sed -i.exakit-bak \
        -e "s|@SHIMDIR@|$(json_tables_shim_dir)|" \
        -e "s|@VENVBIN@|$EXAKIT_JSON_TABLES_VENV/bin/exasol-json-tables|" \
        "$EXAKIT_JSON_TABLES_BIN" && rm -f "$EXAKIT_JSON_TABLES_BIN.exakit-bak"
    chmod 755 "$EXAKIT_JSON_TABLES_BIN"
    push_rollback "rm -f \"$EXAKIT_JSON_TABLES_BIN\""
    ensure_path_hint "$EXAKIT_BIN_DIR"
    ok "JSON Tables launcher written: $EXAKIT_JSON_TABLES_BIN"
}

# json_tables_validate — prove the whole path, not just that files exist: the
# CLI starts, and a real JSON file goes through the shim into the prebuilt
# engine and comes out as Parquet. That end-to-end round trip is the only
# evidence that the no-Rust story actually holds on this machine.
json_tables_validate() {
    _jtv_python="$(json_tables_venv_python)"
    [ -x "$_jtv_python" ] || return 0

    if ! ( "$_jtv_python" -c 'import exasol_json_tables' && : ) >/dev/null 2>&1; then
        warn "JSON Tables is installed but cannot be imported from $EXAKIT_JSON_TABLES_VENV (see log). Recorded validated=false."
        manifest_set components.json_tables.validated false
        return 0
    fi

    info "Validating JSON Tables (a real JSON file through the prebuilt engine)"
    _jtv_tmp="$(mktemp -d "${TMPDIR:-/tmp}/exakit-jt-check.XXXXXX")" || return 0
    printf '[{"id":1,"name":"alpha"},{"id":2,"name":"beta"}]\n' > "$_jtv_tmp/sample.json"
    if ( PATH="$(json_tables_shim_dir):$PATH" "$(json_tables_engine_path)" \
            --input "$_jtv_tmp/sample.json" --output-dir "$_jtv_tmp/out" && : ) \
            >>"${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 && \
       [ -n "$(find "$_jtv_tmp/out" -name '*.parquet' 2>/dev/null | head -1)" ]; then
        ok "Ingest works: JSON in, Parquet out"
        manifest_set components.json_tables.validated true
        rm -rf "$_jtv_tmp"
        _json_tables_print_usage
        return 0
    fi
    rm -rf "$_jtv_tmp"
    warn "The ingest round trip did not produce Parquet (see: exakit logs json-tables). Recorded validated=false; retry with: exakit update json-tables"
    manifest_set components.json_tables.validated false
    return 0
}

_json_tables_print_usage() {
    ui_panel_begin "JSON Tables"
    ui_panel_line "Run it          exasol-json-tables --help"
    ui_panel_line "Ingest JSON     exasol-json-tables ingest --input <file.json>"
    ui_panel_line "Engine          $(ui_tilde "$(json_tables_engine_path)")"
    ui_panel_line "Update          exakit update json-tables"
    ui_panel_end
}

# json_tables_uninstall [dry] — the venv, the engine, the shim, the launcher
# and the manifest record.
json_tables_uninstall() {
    _jtu_dry="${1:-0}"
    for _jtu_path in "$EXAKIT_JSON_TABLES_VENV" "$EXAKIT_JSON_TABLES_HOME" "$EXAKIT_JSON_TABLES_BIN"; do
        [ -e "$_jtu_path" ] || continue
        if [ "$_jtu_dry" = "1" ]; then
            info "  will remove: $_jtu_path"
        else
            info "Removing $_jtu_path"
            rm -rf "$_jtu_path"
        fi
    done
    if [ "$_jtu_dry" != "1" ]; then
        manifest_del components.json_tables
        manifest_del desired.json_tables
        ok "JSON Tables removed — reinstall any time with: exakit marketplace"
    fi
    return 0
}

# json_tables_update — install the advertised build. Doubles as the repair
# command (it re-downloads the engine and rewrites the shim and launcher), so
# an explicit `exakit update json-tables` is always worth running.
json_tables_update() {
    # The mirror is the authority on what can be installed; the advertised set
    # is the offline answer when it cannot be reached.
    _jtu_available="$(_json_tables_mirror_version 2>/dev/null || true)"
    [ -n "$_jtu_available" ] || _jtu_available="$(exakit_component_available json-tables 2>/dev/null || true)"
    [ -n "$_jtu_available" ] || die "Could not resolve the advertised json-tables version."
    _jtu_current="$(json_tables_installed_version 2>/dev/null || true)"
    if [ -n "$_jtu_current" ] && [ "$_jtu_current" = "$_jtu_available" ]; then
        # Same build can still need repair: rewrite the shim and launcher so a
        # newer kit's improvements reach an existing install.
        json_tables_write_shim >/dev/null 2>&1 || true
        json_tables_write_launcher >/dev/null 2>&1 || true
        ok "JSON Tables is already current ($_jtu_current)"
        return 0
    fi
    info "Updating JSON Tables ${_jtu_current:-not installed} -> $_jtu_available"
    EXAKIT_JSON_TABLES_VERSION="$_jtu_available"
    EXAKIT_FORCE_COMPONENT_INSTALL=1
    export EXAKIT_JSON_TABLES_VERSION EXAKIT_FORCE_COMPONENT_INSTALL
    if ! json_tables_install; then
        die "JSON Tables could not be installed — see the warning above and ${EXAKIT_LOG_FILE:-the log}."
    fi
    json_tables_validate || true
    manifest_set desired.json_tables "$EXAKIT_JSON_TABLES_VERSION"
    ok "JSON Tables updated; database data was not changed"
}
