#!/usr/bin/env bash
# exasol-vscode.sh — Exasol for VS Code (editor extension): managed install +
# validation.
#
# A MARKETPLACE ADD-ON: never installed by the setup scripts. The user picks it
# from `exakit marketplace`; once installed it joins `exakit update` like every
# other component. Sourced by the exakit CLI after common.sh.
#
# Extension facts:
#   - github.com/exasol-labs/exasol-vscode; extension id exasol.exasol-vscode
#   - releases carry ONE platform-independent asset, exasol-vscode-<ver>.vsix,
#     with a sha256 digest published by the release API — so the download is
#     checksum-verified with the same three-tier chain exapump uses
#     (versions.json -> the pinned digest below -> the release API).
#   - installed with VS Code's own CLI: code --install-extension <vsix>.
#     The extension lives in VS Code's extensions dir, NOT under the kit home;
#     `exakit uninstall` removes a KIT-INSTALLED copy through the
#     exasol_vscode_uninstall hook below (selectable on its own from the
#     uninstall menu), and never touches one the user installed themselves.
#   - a copy the user already installed from the VS Code Marketplace counts as
#     "on this system": the kit never offers a second one and never manages it.
#
# Safe to re-run: an installed extension at the desired version is kept.

EXAKIT_EXASOL_VSCODE_VERSION="${EXAKIT_EXASOL_VSCODE_VERSION:-}"
EXAKIT_EXASOL_VSCODE_VERSION_FALLBACK="${EXAKIT_EXASOL_VSCODE_VERSION_FALLBACK:-1.7.0}"
EXAKIT_EXASOL_VSCODE_REPO="${EXAKIT_EXASOL_VSCODE_REPO:-exasol-labs/exasol-vscode}"
EXAKIT_EXASOL_VSCODE_EXT_ID="${EXAKIT_EXASOL_VSCODE_EXT_ID:-exasol.exasol-vscode}"
# Optional extensions-dir override: tests point this at a sandbox so a real
# install never touches the user's VS Code profile.
EXAKIT_EXASOL_VSCODE_EXTDIR="${EXAKIT_EXASOL_VSCODE_EXTDIR:-}"

# exasol_vscode_code_cli — VS Code's `code` command, discovered the way the
# kit discovers Docker Desktop: PATH first, then the places the app actually
# lives when the user never ran "Shell Command: Install 'code' command".
# Empty output means "no VS Code on this machine".
# ⇄ twin: Get-ExasolVscodeCodeCli in exasol-vscode.ps1.
exasol_vscode_code_cli() {
    _evc_recorded="$(manifest_get components.exasol_vscode.code_cli 2>/dev/null || true)"
    if [ -n "$_evc_recorded" ] && [ -x "$_evc_recorded" ]; then
        printf '%s\n' "$_evc_recorded"
        return 0
    fi
    if command -v code >/dev/null 2>&1; then
        command -v code
        return 0
    fi
    for _evc_app in \
        "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
        "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
        "/usr/share/code/bin/code"; do
        if [ -x "$_evc_app" ]; then
            printf '%s\n' "$_evc_app"
            return 0
        fi
    done
    return 1
}

# _exasol_vscode_code — run the code CLI with the optional sandbox
# extensions-dir applied. First argument onward is the code command line.
_exasol_vscode_code() {
    _evr_cli="$(exasol_vscode_code_cli)" || return 1
    if [ -n "$EXAKIT_EXASOL_VSCODE_EXTDIR" ]; then
        "$_evr_cli" --extensions-dir "$EXAKIT_EXASOL_VSCODE_EXTDIR" "$@"
    else
        "$_evr_cli" "$@"
    fi
}

# _exasol_vscode_live_version — the version VS Code itself reports for the
# extension, empty when it is not installed there. The single source of truth
# for "is it really on this machine".
_exasol_vscode_live_version() {
    _elv_out="$(_exasol_vscode_code --list-extensions --show-versions 2>/dev/null | \
        grep -i "^${EXAKIT_EXASOL_VSCODE_EXT_ID}@" | head -1)"
    [ -n "$_elv_out" ] || return 1
    printf '%s\n' "${_elv_out#*@}" | tr -d '\r'
}

# exasol_vscode_installed_version — KIT-MANAGED install only: the manifest
# record proves the kit installed it, and VS Code's own listing proves it is
# still there (and answers with the live version, so a copy the user updated
# inside VS Code reads as what actually runs).
exasol_vscode_installed_version() {
    [ -n "$(manifest_get components.exasol_vscode.version 2>/dev/null || true)" ] || return 1
    _exasol_vscode_live_version
}

# exasol_vscode_system_present — the extension is in VS Code but the kit never
# installed it (a VS Code Marketplace install): covered, and not managed.
# Overrides the generic same-named-binary PATH probe, which would never fire
# for an editor extension.
exasol_vscode_system_present() {
    [ -z "$(manifest_get components.exasol_vscode.version 2>/dev/null || true)" ] || return 1
    _exasol_vscode_live_version >/dev/null 2>&1
}

# exasol_vscode_applicable — an editor extension is only an option when the
# editor is here. Without VS Code the add-on is not offered at all: no row in
# the marketplace, no mention in the closing offer or the discovery lines.
# (An already kit-installed copy stays visible either way, so it can still be
# updated or removed — see _exakit_addon_offerable.)
exasol_vscode_applicable() {
    exasol_vscode_code_cli >/dev/null 2>&1
}

exasol_vscode_applicable_reason() {
    printf '%s\n' "VS Code was not found (install it from https://code.visualstudio.com, then run: exakit marketplace)"
}

exasol_vscode_asset_name() {
    printf 'exasol-vscode-%s.vsix\n' "$1"
}

# exasol_vscode_expected_sha256 <version> — the digest the download is
# verified against, same three-tier chain as exapump (see
# exapump_expected_sha256): versions.json only for the advertised version,
# then the pinned digest of the release shipped with this kit, then the
# release API. Empty means "no digest available"; the caller refuses.
exasol_vscode_expected_sha256() {
    _evs_advertised="$(exakit_versions_value components.exasol-vscode.version 2>/dev/null || true)"
    if [ -n "$_evs_advertised" ] && [ "$_evs_advertised" = "$1" ]; then
        _evs_digest="$(exakit_versions_value components.exasol-vscode.sha256.vsix 2>/dev/null || true)"
        case "$_evs_digest" in
            *[!0-9a-f]*) _evs_digest="" ;;
        esac
        if [ -n "$_evs_digest" ] && [ "${#_evs_digest}" -eq 64 ]; then
            printf '%s\n' "$_evs_digest"
            return 0
        fi
    fi
    _evs_digest="$(exasol_vscode_pinned_sha256 "$1")"
    if [ -n "$_evs_digest" ]; then
        printf '%s\n' "$_evs_digest"
        return 0
    fi
    exasol_vscode_release_digest_from_api "$1"
}

# Digest of the bundled fallback release (published by the release API).
exasol_vscode_pinned_sha256() {
    case "$1" in
        1.7.0) echo "901badff486da4f41bb285463be152dd036437cdd54fbbde51328954c8e9b3c5" ;;
        *) echo "" ;;
    esac
}

exasol_vscode_release_digest_from_api() {
    _era_json="$(curl -fsSL --retry 3 --connect-timeout 15 \
        "https://api.github.com/repos/${EXAKIT_EXASOL_VSCODE_REPO}/releases/tags/v$1" \
        2>/dev/null || true)"
    [ -n "$_era_json" ] || return 1
    _era_asset="$(exasol_vscode_asset_name "$1")"
    if exakit_can_run_python; then
        printf '%s' "$_era_json" | run_python -c '
import json, sys
name = sys.argv[1]
doc = json.load(sys.stdin)
for asset in doc.get("assets", []):
    if asset["name"] == name and asset.get("digest", "").startswith("sha256:"):
        print(asset["digest"].split(":", 1)[1])
        break
' "$_era_asset"
        return $?
    fi
    printf '%s' "$_era_json" | tr '{' '\n' | awk -v name="$_era_asset" '
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

# _exasol_vscode_not_installed <reason> — report a soft failure and return 1.
# Marketplace add-ons follow the pyexasol contract: nothing here may end the
# caller's run.
_exasol_vscode_not_installed() {
    warn "Exasol for VS Code was not installed: $1"
    warn "Everything else in the kit is unaffected. Retry with: exakit update exasol-vscode"
    command -v exakit_note_failure >/dev/null 2>&1 && exakit_note_failure "$1"
    manifest_set components.exasol_vscode.validated false
    return 1
}

exasol_vscode_install() {
    # The marketplace path runs from the exakit CLI, where the installer's
    # version resolution has not run — resolve the advertised version here.
    if [ -z "${EXAKIT_EXASOL_VSCODE_VERSION:-}" ]; then
        EXAKIT_EXASOL_VSCODE_VERSION="$(exakit_component_available exasol-vscode 2>/dev/null || true)"
        [ -n "$EXAKIT_EXASOL_VSCODE_VERSION" ] || EXAKIT_EXASOL_VSCODE_VERSION="$EXAKIT_EXASOL_VSCODE_VERSION_FALLBACK"
        export EXAKIT_EXASOL_VSCODE_VERSION
    fi

    _evi_cli="$(exasol_vscode_code_cli)" || {
        _exasol_vscode_not_installed "VS Code's 'code' command was not found — install VS Code (https://code.visualstudio.com), then retry"
        return 1
    }

    _evi_live="$(_exasol_vscode_live_version 2>/dev/null || true)"
    if [ -n "$_evi_live" ] && [ "$_evi_live" = "$EXAKIT_EXASOL_VSCODE_VERSION" ] && \
       [ "${EXAKIT_FORCE_COMPONENT_INSTALL:-0}" != "1" ]; then
        ok "Exasol for VS Code $_evi_live already installed"
    else
        _evi_asset="$(exasol_vscode_asset_name "$EXAKIT_EXASOL_VSCODE_VERSION")"
        _evi_url="https://github.com/${EXAKIT_EXASOL_VSCODE_REPO}/releases/download/v${EXAKIT_EXASOL_VSCODE_VERSION}/${_evi_asset}"
        _evi_tmp="$(mktemp "${TMPDIR:-/tmp}/exakit-exasol-vscode.XXXXXX")" || {
            _exasol_vscode_not_installed "could not create a temporary download file"
            return 1
        }
        info "Downloading Exasol for VS Code v${EXAKIT_EXASOL_VSCODE_VERSION} ($_evi_asset)"
        # fetch dies on failure; the subshell keeps that soft here.
        if ! ( fetch "$_evi_url" "$_evi_tmp" ) >>"${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
            rm -f "$_evi_tmp"
            _exasol_vscode_not_installed "the download failed (see log): $_evi_url"
            return 1
        fi

        # Same verification bar as exapump: a downloaded-and-executed artifact
        # is never installed unverified — soft-fail instead of die, because the
        # marketplace contract says nothing here may end the caller's run.
        _evi_expected="$(exasol_vscode_expected_sha256 "$EXAKIT_EXASOL_VSCODE_VERSION" 2>/dev/null || true)"
        if [ -n "$_evi_expected" ]; then
            _evi_actual="$(sha256_of "$_evi_tmp")"
            if [ "$_evi_actual" != "$_evi_expected" ]; then
                rm -f "$_evi_tmp"
                _exasol_vscode_not_installed "checksum mismatch for $_evi_asset (expected $_evi_expected, got $_evi_actual)"
                return 1
            fi
            ok "Checksum verified: $_evi_asset"
        elif [ "${EXAKIT_ALLOW_UNVERIFIED_EXASOL_VSCODE:-0}" = "1" ]; then
            warn "No digest available for $_evi_asset — proceeding WITHOUT checksum verification (EXAKIT_ALLOW_UNVERIFIED_EXASOL_VSCODE=1)."
        else
            rm -f "$_evi_tmp"
            _exasol_vscode_not_installed "no checksum is available for $_evi_asset; refusing an unverified extension. Add its digest to versions.json (components.exasol-vscode.sha256.vsix) or check network access to the release API. Override at your own risk with EXAKIT_ALLOW_UNVERIFIED_EXASOL_VSCODE=1"
            return 1
        fi

        # code refuses a vsix without the extension: install expects the file
        # suffix, so give the verified download its real name.
        _evi_vsix="${_evi_tmp}.vsix"
        mv "$_evi_tmp" "$_evi_vsix" || {
            rm -f "$_evi_tmp"
            _exasol_vscode_not_installed "could not stage the downloaded extension file"
            return 1
        }
        info "Installing the extension into VS Code"
        if ! _exasol_vscode_code --install-extension "$_evi_vsix" --force \
                >>"${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
            rm -f "$_evi_vsix"
            _exasol_vscode_not_installed "code --install-extension failed (see log)"
            return 1
        fi
        rm -f "$_evi_vsix"
        # The install is not done until VS Code can answer for the version.
        _evi_now="$(_exasol_vscode_live_version 2>/dev/null || true)"
        if [ -z "$_evi_now" ]; then
            _exasol_vscode_not_installed "VS Code does not list ${EXAKIT_EXASOL_VSCODE_EXT_ID} after the install (see log)"
            return 1
        fi
        ok "Exasol for VS Code installed ($_evi_now)"
    fi

    manifest_set components.exasol_vscode.version "$EXAKIT_EXASOL_VSCODE_VERSION"
    manifest_set components.exasol_vscode.extension_id "$EXAKIT_EXASOL_VSCODE_EXT_ID"
    manifest_set components.exasol_vscode.code_cli "$_evi_cli"
}

# exasol_vscode_validate — VS Code's own listing is the proof. Soft, like
# every marketplace validation: a miss records validated=false and warns.
exasol_vscode_validate() {
    _evv_live="$(_exasol_vscode_live_version 2>/dev/null || true)"
    if [ -z "$_evv_live" ]; then
        warn "VS Code does not list ${EXAKIT_EXASOL_VSCODE_EXT_ID}. Recorded validated=false; retry with: exakit update exasol-vscode"
        manifest_set components.exasol_vscode.validated false
        return 0
    fi
    manifest_set components.exasol_vscode.validated true
    ok "Exasol for VS Code answers: ${EXAKIT_EXASOL_VSCODE_EXT_ID}@${_evv_live}"
    ui_panel_begin "Exasol for VS Code"
    ui_panel_line "Open VS Code    the Exasol view appears in the activity bar"
    ui_panel_line "Connect it      DSN and credentials: exakit info"
    ui_panel_line "Update          exakit update exasol-vscode"
    ui_panel_line "Remove          exakit uninstall (pick Exasol for VS Code)"
    ui_panel_end
    return 0
}

# exasol_vscode_uninstall [dry] — remove the KIT-MANAGED extension from VS
# Code, through VS Code's own CLI, plus the manifest record. With "1" it only
# narrates the plan. A copy the kit never installed (no manifest record — a
# VS Code Marketplace install) is refused: the kit does not uninstall what it
# does not manage. Best-effort and idempotent.
exasol_vscode_uninstall() {
    _evd_dry="${1:-0}"
    if [ -z "$(manifest_get components.exasol_vscode.version 2>/dev/null || true)" ]; then
        info "The Exasol VS Code extension is not kit-managed — nothing to remove."
        info "A copy you installed yourself is removed inside VS Code, or with: code --uninstall-extension ${EXAKIT_EXASOL_VSCODE_EXT_ID}"
        return 0
    fi
    if [ "$_evd_dry" = "1" ]; then
        info "  will remove: the Exasol VS Code extension (${EXAKIT_EXASOL_VSCODE_EXT_ID}) from VS Code"
        return 0
    fi
    if _exasol_vscode_live_version >/dev/null 2>&1; then
        info "Removing the Exasol VS Code extension (${EXAKIT_EXASOL_VSCODE_EXT_ID})"
        if ! _exasol_vscode_code --uninstall-extension "$EXAKIT_EXASOL_VSCODE_EXT_ID" \
                >>"${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
            warn "code --uninstall-extension reported issues (see log) — remove it inside VS Code if it is still listed."
        fi
        if _exasol_vscode_live_version >/dev/null 2>&1; then
            warn "VS Code still lists ${EXAKIT_EXASOL_VSCODE_EXT_ID} — a running VS Code may hold it; remove it from the Extensions view."
        fi
    fi
    manifest_del components.exasol_vscode
    manifest_del desired.exasol_vscode
    ok "Exasol for VS Code removed — reinstall any time with: exakit marketplace"
    return 0
}

# exasol_vscode_update — install the advertised version. Doubles as the repair
# command after a failed marketplace install. Asked for explicitly, so a
# failure here IS a failure.
exasol_vscode_update() {
    _evu_available="$(exakit_component_available exasol-vscode 2>/dev/null || true)"
    [ -n "$_evu_available" ] || die "Could not resolve the advertised exasol-vscode version."
    _evu_current="$(exasol_vscode_installed_version 2>/dev/null || true)"
    if [ -n "$_evu_current" ] && [ "$_evu_current" = "$_evu_available" ]; then
        ok "Exasol for VS Code is already current ($_evu_current)"
        return 0
    fi
    info "Updating Exasol for VS Code ${_evu_current:-not installed} -> $_evu_available"
    EXAKIT_EXASOL_VSCODE_VERSION="$_evu_available"
    EXAKIT_FORCE_COMPONENT_INSTALL=1
    export EXAKIT_EXASOL_VSCODE_VERSION EXAKIT_FORCE_COMPONENT_INSTALL
    if ! exasol_vscode_install; then
        die "Exasol for VS Code could not be installed — see the warning above and ${EXAKIT_LOG_FILE:-the log}."
    fi
    exasol_vscode_validate || true
    manifest_set desired.exasol_vscode "$EXAKIT_EXASOL_VSCODE_VERSION"
    ok "Exasol for VS Code updated; database data was not changed"
}
