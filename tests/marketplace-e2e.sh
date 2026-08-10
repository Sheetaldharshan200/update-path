#!/usr/bin/env bash
# marketplace-e2e.sh — end-to-end proof of the marketplace add-on flow, against
# a SANDBOXED kit home (the real ~/.exasol-starter-kit is never touched):
#
#   1. `exakit marketplace` (non-interactive, EXAKIT_MARKETPLACE_ADDONS)
#      installs dash-server from its real GitHub release into a kit-managed
#      venv, writes the launcher, and validates the HTTP control plane.
#   2. The installed add-on joins the update flow: update-check lists it,
#      `exakit update dash-server` answers "already current", `exakit version`
#      reports it, and a second marketplace run offers nothing to install.
#   3. `exakit_uninstall_run` sweeps the venv, state and launcher.
#
# Needs the network (GitHub + PyPI) and uv; SKIPs cleanly when either is
# missing so it is safe in a dry CI environment. No database is required:
# dash-server starts and answers /mcp without a bootstrapped profile.
#
#   bash tests/marketplace-e2e.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

say()  { printf '\n[marketplace-e2e] %s\n' "$1"; }
skip() { echo "SKIP: $1"; exit 0; }
fail() { echo "[marketplace-e2e] FAIL: $1" >&2; exit 1; }

command -v uv >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 || skip "neither uv nor curl is available"
# Probe the host the install actually downloads from; a HEAD of the release
# page avoids the API rate limit that a busy CI runner can hit.
curl -fsSIL --max-time 10 https://github.com >/dev/null 2>&1 || skip "no network (github.com unreachable)"

SANDBOX="$(mktemp -d)"
trap 'pkill -f "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

export EXAKIT_HOME="$SANDBOX/home"
export EXAKIT_BIN_DIR="$SANDBOX/bin"
# A quiet high port so a dash-server the user already runs on 5100 cannot
# collide with the validation probe.
export EXAKIT_DASH_SERVER_PORT="$((5300 + $$ % 400))"
mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"

# A minimal manifest so the CLI accepts commands; runtime credentials let the
# launcher bake its profile bootstrap (the value is fake — dash-server only
# reads it when a dashboard actually connects).
(
    . "$ROOT/setup/lib/common.sh"
    manifest_init >/dev/null
    mkdir -p "$EXAKIT_HOME/credentials"
    printf 'not-a-real-password\n' > "$EXAKIT_HOME/credentials/runtime_sys_password"
    chmod 600 "$EXAKIT_HOME/credentials/runtime_sys_password"
    manifest_set runtime.type "personal"
    manifest_set runtime.dsn "127.0.0.1:8563"
    manifest_set runtime.user "sys"
    manifest_set runtime.password_file "$EXAKIT_HOME/credentials/runtime_sys_password"
) || fail "could not seed the sandbox manifest"

say "1/8 exakit marketplace installs dash-server from its GitHub release"
if ! EXAKIT_MARKETPLACE_ADDONS=dash-server bash "$ROOT/setup/exakit" marketplace; then
    fail "exakit marketplace did not complete"
fi

say "2/8 the venv answers for the advertised version"
_advertised="$(
    . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
    exakit_versions_value components.dash-server.version "$ROOT/versions.json"
)"
_installed="$("$EXAKIT_HOME/dash-server-venv/bin/python" -c \
    'from importlib.metadata import version; print(version("dash-server"))' 2>/dev/null)"
[ -n "$_installed" ] || fail "no dash-server package in the venv"
[ "$_installed" = "$_advertised" ] || fail "installed $_installed but versions.json advertises $_advertised"
[ -x "$EXAKIT_BIN_DIR/dash-server" ] || fail "the dash-server launcher was not written"
grep -q "DASH_SERVER_EXASOL_DSN" "$EXAKIT_BIN_DIR/dash-server" || fail "the launcher carries no profile bootstrap"
grep -q "not-a-real-password" "$EXAKIT_BIN_DIR/dash-server" && fail "the launcher leaked the password"
echo "  ok  dash-server $_installed installed, launcher in place"

say "3/8 validation recorded the live HTTP probe"
_validated="$(
    . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
    manifest_get components.dash_server.validated
)"
[ "$_validated" = "true" ] || fail "components.dash_server.validated is '$_validated', expected true (did the control-plane probe fail?)"
echo "  ok  control plane answered on port $EXAKIT_DASH_SERVER_PORT during validation"

say "4/8 the installed add-on joins the update flow"
_targets="$(
    . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
    . "$ROOT/setup/lib/dash-server.sh" >/dev/null 2>&1
    exakit_update_targets all | tr '\n' ' '
)"
case "$_targets" in
    *dash-server*) echo "  ok  update all now covers: $_targets" ;;
    *) fail "exakit update targets (all) does not include dash-server: $_targets" ;;
esac
_version_out="$(bash "$ROOT/setup/exakit" version 2>/dev/null)"
case "$_version_out" in
    *dash-server*) echo "  ok  exakit version reports the add-on" ;;
    *) fail "exakit version does not report dash-server" ;;
esac

say "5/8 update says already current; a second marketplace run offers nothing"
_update_out="$(bash "$ROOT/setup/exakit" update dash-server 2>&1)" || fail "exakit update dash-server failed: $_update_out"
case "$_update_out" in
    *"already current"*) echo "  ok  exakit update dash-server: already current" ;;
    *) fail "unexpected update output: $_update_out" ;;
esac
_second="$(EXAKIT_MARKETPLACE_ADDONS=dash-server bash "$ROOT/setup/exakit" marketplace 2>&1)" || fail "second marketplace run failed"
case "$_second" in
    *"already installed"*|*"already present"*) echo "  ok  second run installs nothing" ;;
    *) fail "second marketplace run did not recognize the install: $_second" ;;
esac

say "6/8 exasol-vscode installs from its release, checksum-verified, into an isolated extensions dir"
# The extension add-on needs VS Code itself; without one this half SKIPs
# rather than failing (the dash-server half above has already proven the
# marketplace machinery). The sandbox extensions dir guarantees the user's
# real VS Code profile is never touched — even on a machine where the
# extension is genuinely installed.
_code_cli="$(
    . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
    . "$ROOT/setup/lib/exasol-vscode.sh" >/dev/null 2>&1
    exasol_vscode_code_cli 2>/dev/null
)"
if [ -z "$_code_cli" ]; then
    echo "  --  no VS Code on this machine; the exasol-vscode half is skipped"
else
    export EXAKIT_EXASOL_VSCODE_EXTDIR="$SANDBOX/vscode-ext"
    mkdir -p "$EXAKIT_EXASOL_VSCODE_EXTDIR"
    if ! EXAKIT_MARKETPLACE_ADDONS=exasol-vscode bash "$ROOT/setup/exakit" marketplace; then
        fail "exakit marketplace did not complete for exasol-vscode"
    fi
    _ext_live="$(
        . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
        . "$ROOT/setup/lib/exasol-vscode.sh" >/dev/null 2>&1
        _exasol_vscode_live_version
    )"
    _ext_advertised="$(
        . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
        exakit_versions_value components.exasol-vscode.version "$ROOT/versions.json"
    )"
    [ -n "$_ext_live" ] || fail "VS Code does not list the extension in the sandbox extensions dir"
    [ "$_ext_live" = "$_ext_advertised" ] || fail "installed $_ext_live but versions.json advertises $_ext_advertised"
    ls "$EXAKIT_EXASOL_VSCODE_EXTDIR" | grep -qi exasol || fail "nothing landed in the isolated extensions dir"
    echo "  ok  exasol.exasol-vscode@$_ext_live installed into the sandbox extensions dir"

    say "7/8 the extension joins the update flow and a second run offers nothing"
    _ext_update="$(bash "$ROOT/setup/exakit" update exasol-vscode 2>&1)" || fail "exakit update exasol-vscode failed: $_ext_update"
    case "$_ext_update" in
        *"already current"*) echo "  ok  exakit update exasol-vscode: already current" ;;
        *) fail "unexpected update output: $_ext_update" ;;
    esac
    _ext_targets="$(
        . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
        . "$ROOT/setup/lib/dash-server.sh" >/dev/null 2>&1
        . "$ROOT/setup/lib/exasol-vscode.sh" >/dev/null 2>&1
        exakit_update_targets all | tr '\n' ' '
    )"
    case "$_ext_targets" in
        *exasol-vscode*) echo "  ok  update all now covers: $_ext_targets" ;;
        *) fail "update targets (all) does not include exasol-vscode: $_ext_targets" ;;
    esac
    _ext_second="$(EXAKIT_MARKETPLACE_ADDONS=exasol-vscode bash "$ROOT/setup/exakit" marketplace 2>&1)" || fail "second exasol-vscode marketplace run failed"
    case "$_ext_second" in
        *"already installed"*|*"already present"*) echo "  ok  second run installs nothing" ;;
        *) fail "second run did not recognize the install: $_ext_second" ;;
    esac
fi

say "8/8 uninstall sweeps the add-on"
(
    . "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
    # The database/MCP steps are stubbed: this sandbox never had either.
    nano_teardown() { :; }
    personal_teardown() { :; }
    exakit_mcp_operation() { :; }
    manifest_get() { case "$1" in runtime.type) echo "" ;; *) command manifest_get "$1" ;; esac; }
    exakit_uninstall_run 0 >/dev/null 2>&1
    :
)
[ ! -e "$EXAKIT_HOME/dash-server-venv" ] || fail "uninstall left the dash-server venv behind"
[ ! -e "$EXAKIT_BIN_DIR/dash-server" ] || fail "uninstall left the dash-server launcher behind"
echo "  ok  venv, state and launcher removed"
# The VS Code extension deliberately survives: it lives in VS Code, not under
# the kit home, and removing a user's editor extension is not the kit's call.
if [ -n "${EXAKIT_EXASOL_VSCODE_EXTDIR:-}" ] && [ -d "$EXAKIT_EXASOL_VSCODE_EXTDIR" ]; then
    ls "$EXAKIT_EXASOL_VSCODE_EXTDIR" 2>/dev/null | grep -qi exasol \
        || fail "uninstall removed the VS Code extension — it must be left alone"
    echo "  ok  the VS Code extension is deliberately left alone (remove: code --uninstall-extension exasol.exasol-vscode)"
fi

say "PASS — marketplace install, update flow and uninstall all work end to end"
