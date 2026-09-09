#!/usr/bin/env bash
# setup-wsl.sh — Exasol Personal Local Starter Kit, Linux and WSL path.
#
# Installs and connects a database runtime, exapump, the Exasol MCP server, and
# pyexasol. Prints connection details when done. Which runtime is
# exakit_runtime_choice's answer (EXAKIT_RUNTIME, or the platform default):
#   nano      Exasol Nano container - Docker preferred, Podman fallback (default)
#   personal  the Exasol Personal launcher (Linux local deployments, Podman)
# The two runtimes differ ONLY in the requirements gate and the first two
# steps; everything from exapump on is runtime-blind and shared.
#
# Usually launched by install.sh, but runs standalone from a checkout too:
#   bash setup/setup-wsl.sh
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
for _lib in common.sh detect.sh; do
    [ -f "$LIB_DIR/$_lib" ] || {
        printf '\033[1;31m  ✗\033[0m Kit file missing: %s — the download looks incomplete. Re-run the installer.\n' "$LIB_DIR/$_lib" >&2
        exit 1
    }
done
. "$LIB_DIR/common.sh"
. "$LIB_DIR/detect.sh"
# The runtime module is chosen, not assumed - and only the chosen one loads,
# so the truncated-download check moves with the choice.
#
# AN INSTALLED KIT'S RECORD OUTRANKS THE KNOB. repair-runtime and a resumed
# install re-run this script over an existing manifest, and the knob is a
# fresh-install choice: honouring it here would rebuild the OTHER runtime
# beside the broken one it was asked to repair. Switching runtimes is an
# uninstall away, never a re-run away.
EXAKIT_SETUP_RUNTIME="$(manifest_get runtime.type 2>/dev/null || true)"
if [ -n "$EXAKIT_SETUP_RUNTIME" ]; then
    if [ -n "${EXAKIT_RUNTIME:-}" ] && [ "$EXAKIT_RUNTIME" != "$EXAKIT_SETUP_RUNTIME" ]; then
        printf '  ! This machine already runs the %s runtime; EXAKIT_RUNTIME=%s only applies to a fresh install (exakit uninstall first to switch).
' "$EXAKIT_SETUP_RUNTIME" "$EXAKIT_RUNTIME" >&2
    fi
else
    EXAKIT_SETUP_RUNTIME="$(exakit_runtime_choice)"
fi
case "$EXAKIT_SETUP_RUNTIME" in
    personal) _runtime_lib="runtime-personal.sh" ;;
    *)        _runtime_lib="runtime-nano.sh" ;;
esac
[ -f "$LIB_DIR/$_runtime_lib" ] || {
    printf '\033[1;31m  ✗\033[0m Kit file missing: %s — the download looks incomplete. Re-run the installer.\n' "$LIB_DIR/$_runtime_lib" >&2
    exit 1
}
. "$LIB_DIR/$_runtime_lib"
# Optional modules: a missing file legitimately skips its step, but a file
# that FAILS to load (e.g. CRLF-corrupted copy whose syntax breaks bash) must
# fail loudly - otherwise the step silently reports "not part of this
# installation" and the component is never installed.
if [ -f "$LIB_DIR/exapump.sh" ];  then . "$LIB_DIR/exapump.sh"  || die "Could not load $LIB_DIR/exapump.sh (corrupted kit copy? re-download and re-run)"; fi
if [ -f "$LIB_DIR/mcp.sh" ];      then . "$LIB_DIR/mcp.sh"      || die "Could not load $LIB_DIR/mcp.sh (corrupted kit copy? re-download and re-run)"; fi
if [ -f "$LIB_DIR/pyexasol.sh" ]; then . "$LIB_DIR/pyexasol.sh" || die "Could not load $LIB_DIR/pyexasol.sh (corrupted kit copy? re-download and re-run)"; fi

exakit_init_logging
# Where the bootstrap time went, in the log: the installer stamps its start,
# and this is the first line setup can write.
[ -n "${EXAKIT_INSTALL_T0:-}" ] && _exakit_log_file "INFO  setup started $(( $(date +%s) - EXAKIT_INSTALL_T0 ))s after the installer began (download, extraction and library load)"
manifest_init
exakit_enable_failure_handling
# The `exakit` command first, so `exakit status` answers from the first seconds
# of this install (AGENTS.md tells an agent to poll it). It used to be written
# by the LAST step, 105 s into a 107 s install.
exakit_install_helper_early "$SCRIPT_DIR"

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
case "$EXAKIT_SETUP_RUNTIME" in
    personal) personal_check_requirements ;;
    *)        nano_check_requirements ;;
esac

# --- step 2: the Runtime image ----------------------------------------------
# Its own step, matching the macOS shape and heading. On the container runtime
# what it fetches is the Nano image rather than a native launcher, so the lines
# UNDER the heading name the image - different things through the same step.
if begin_step launcher "Step 1/6  Exasol launcher"; then
    case "$EXAKIT_SETUP_RUNTIME" in
        personal) personal_install_launcher ;;
        *)        nano_pull_image ;;
    esac
    mark_step launcher
fi

# --- step 3: local deployment ------------------------------------------------
if begin_step runtime "Step 2/6  Local database deployment"; then
    case "$EXAKIT_SETUP_RUNTIME" in
        personal) personal_deploy_local ;;
        *)        nano_install ;;
    esac
    mark_step runtime
else
    case "$EXAKIT_SETUP_RUNTIME" in
        personal)
            # The macOS resume arms, verbatim: a recorded step whose deployment
            # is gone is redeployed (and the armed destroy disarmed by hand,
            # since there is no mark_step to do it); one that is merely stopped
            # is started - every later step talks SQL to it.
            if ! personal_deployment_exists; then
                info "Deployment marked done but not reachable — redeploying"
                personal_deploy_local
                rollback_clear
            elif ! personal_deployment_running; then
                info "Database is deployed but not running — starting it"
                personal_start
                personal_wait_ready
            fi
            ;;
        *)
            if [ "$(nano_status)" != "running" ]; then
                info "Runtime marked done but not running — starting it"
                nano_install
                # Same as the macOS resume: nano_install registers `volume rm` as its
                # undo, and with no mark_step here it would stay armed. Worse than the
                # macOS case, because that volume is armed whenever the CONTAINER is
                # missing even if the volume already held data -- so the rollback could
                # delete data this run never created.
                rollback_clear
            fi
            ;;
    esac
fi

# --- steps 3-6: exapump, MCP server, pyexasol, exakit helper (shared) ---------
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
# actually on offer. The subshell keeps any failure inside it from ending an
# install that already succeeded.
# Automatic start defaults to ON for a fresh install: the kit's promise is a
# database that is simply there, and leaving it off meant a reboot quietly
# took it away. Only ever applied when the manifest has no opinion yet, so
# `exakit autostart off` survives a re-run of the installer. This runs BEFORE
# the marketplace offer so an add-on installed from it joins the boot set.
exakit_autostart_default_on || true
( exakit_marketplace_offer ) || true
# A rule, then a heading: the last line on screen is where the reader is left,
# and run together with whatever the marketplace printed it read as one more of
# its bullets. The rule gives it air; the green arrow says it is not a step.
ui_rule
heading "Run \"exakit help\" for support"
# Two blank lines before the shell prompt returns. The installer's last line was
# landing directly against it, so the prompt read as part of the output.
printf '\n\n'
