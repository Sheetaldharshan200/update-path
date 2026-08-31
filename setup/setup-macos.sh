#!/usr/bin/env bash
# setup-macos.sh — Exasol Personal Local Starter Kit, macOS path.
#
# Installs and connects: Exasol Personal (local deployment), exapump, the
# Exasol MCP server, and pyexasol. Prints connection details when done.
#
# Usually launched by install.sh, but runs standalone from a checkout too:
#   bash setup/setup-macos.sh
#
# Safe to re-run: completed steps are skipped, failed steps are retried.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Core libraries must exist; a truncated/partial download otherwise collapses
# into a wall of "command not found". die() isn't defined until common.sh
# loads, so report with a plain printf.
for _lib in common.sh detect.sh runtime-personal.sh; do
    [ -f "$LIB_DIR/$_lib" ] || {
        printf '\033[1;31m  ✗\033[0m Kit file missing: %s — the download looks incomplete. Re-run the installer.\n' "$LIB_DIR/$_lib" >&2
        exit 1
    }
done
. "$LIB_DIR/common.sh"
. "$LIB_DIR/detect.sh"
. "$LIB_DIR/runtime-personal.sh"
# Optional modules: a missing file legitimately skips its step, but a file
# that FAILS to load (e.g. CRLF-corrupted copy whose syntax breaks bash) must
# fail loudly - otherwise the step silently reports "not part of this
# installation" and the component is never installed.
if [ -f "$LIB_DIR/exapump.sh" ];  then . "$LIB_DIR/exapump.sh"  || die "Could not load $LIB_DIR/exapump.sh (corrupted kit copy? re-download and re-run)"; fi
if [ -f "$LIB_DIR/mcp.sh" ];      then . "$LIB_DIR/mcp.sh"      || die "Could not load $LIB_DIR/mcp.sh (corrupted kit copy? re-download and re-run)"; fi
if [ -f "$LIB_DIR/pyexasol.sh" ]; then . "$LIB_DIR/pyexasol.sh" || die "Could not load $LIB_DIR/pyexasol.sh (corrupted kit copy? re-download and re-run)"; fi

exakit_init_logging
manifest_init
exakit_enable_failure_handling

[ "${EXAKIT_BANNER_SHOWN:-0}" = 1 ] || ui_banner "Personal Local Starter Kit"

manifest_set os "$(detect_os)"
manifest_set arch "$(detect_arch)"
manifest_set kit.source "${EXAKIT_KIT_SOURCE:-checkout:$KIT_ROOT}"
# The kit's own version comes from the versions manifest shipping with THIS
# tree, not from whatever copy an earlier install left under the kit home.
# Record the move BEFORE kit.version is overwritten: the "What's new" box at the
# end of the run reads that record, and it survives a run that dies partway.
exakit_note_kit_upgrade "$KIT_ROOT" || true
_kit_version="$(exakit_kit_version_at "$KIT_ROOT" 2>/dev/null || true)"
[ -n "$_kit_version" ] && manifest_set kit.version "$_kit_version"
exakit_resolve_install_versions

# --- step 1: requirements ---------------------------------------------------
EXAKIT_CURRENT_STEP="requirements"
personal_check_requirements

# --- step 2: launcher -------------------------------------------------------
if begin_step launcher "Step 1/6  Exasol launcher"; then
    personal_install_launcher
    mark_step launcher
fi

# --- step 3: local deployment ----------------------------------------------
if begin_step runtime "Step 2/6  Local database deployment"; then
    personal_deploy_local
    mark_step runtime
else
    if ! personal_deployment_exists; then
        info "Deployment marked done but not reachable — redeploying"
        personal_deploy_local
    elif ! personal_deployment_running; then
        # Exists but merely STOPPED (exakit stop, a reboot — the Personal
        # runtime does not auto-start): start it, don't skip it. Every step
        # after this one talks SQL to the database, so skipping here used to
        # surface minutes later as "Connection refused" in the MCP read-only
        # user creation — with the data-load offer silently trusting the
        # manifest in between. Mirrors the Nano paths, which restart a
        # non-running container on re-run (setup-wsl.sh, setup-windows-docker.ps1).
        info "Database is deployed but not running — starting it"
        personal_start
        personal_wait_ready
    fi
fi

# --- steps 3-6: exapump, MCP server, pyexasol, exakit helper (shared) -------
kit_shared_steps 3 6 "$SCRIPT_DIR" "$KIT_ROOT"

exakit_finish
connection_summary
# Only when the kit version moved during this run, and never able to fail it: the
# trap is already released and every reader inside degrades to silence.
exakit_print_whats_new_box "$KIT_ROOT" || true
# Last on screen, after the payoff panel: anything that did not complete, with
# the one command that installs it. A step that failed mid-run scrolls away;
# this is what the user is still looking at when the installer exits.
exakit_print_soft_failures
# The install's one closing line, after the panel and after anything that did
# not finish. Silent when a soft failure was recorded.
exakit_print_ready_line
# The closing offer: optional marketplace add-ons, asked exactly once, only on
# an interactive run whose steps all completed, and only while something is
# actually on offer (an add-on already on this machine is never advertised).
# The subshell keeps any failure inside it from ending an install that
# already succeeded.
# Automatic start defaults to ON for a fresh install: the kit's promise is a
# database that is simply there, and leaving it off meant a reboot quietly
# took it away. Only ever applied when the manifest has no opinion yet, so
# `exakit autostart off` survives a re-run of the installer. This runs BEFORE
# the marketplace offer so an add-on installed from it joins the boot set.
exakit_autostart_default_on || true
( exakit_marketplace_offer ) || true
info "Run \"exakit help\" for support"
