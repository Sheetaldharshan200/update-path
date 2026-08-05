#!/usr/bin/env bash
# marketplace.sh — proves the marketplace add-on layer: the registry, the
# installed/pending detection that gates `exakit update all`, the
# EXAKIT_MARKETPLACE_ADDONS non-interactive contract, and the dash-server
# module's version resolution, launcher generation and soft-fail accounting.
# Pure logic against a sandboxed kit home: no network, no installs.
#
#   bash tests/marketplace.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s = %s\n' "$1" "$3"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"
    fi
}

has() { # has <label> <needle> <haystack>
    case "$3" in *"$2"*) check "$1" "present" "present" ;; *) check "$1" "present" "MISSING" ;; esac
}

lacks() { # lacks <label> <needle> <haystack>
    case "$3" in *"$2"*) check "$1" "absent" "PRESENT" ;; *) check "$1" "absent" "absent" ;; esac
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The kit home is redirected for the whole run: nothing here may touch a real
# installation. common.sh derives its paths at source time, so this comes first.
EXAKIT_HOME="$WORK/home"
EXAKIT_BIN_DIR="$WORK/bin"
mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
. "$ROOT/setup/lib/common.sh"
. "$ROOT/setup/lib/dash-server.sh"

manifest_init >/dev/null 2>&1

echo "registry:"
check "addons list carries dash-server" "dash-server" "$(exakit_marketplace_addons | cut -d'|' -f1)"
check "addon module is loaded" "yes" "$(exakit_marketplace_addon_available dash-server && echo yes || echo no)"
check "component block" "components.dash-server" "$(_exakit_component_block dash-server)"
check "fallback version is the constant" "$EXAKIT_DASH_SERVER_VERSION_FALLBACK" "$(_exakit_component_fallback dash-server)"
# Both readers (python and the awk fallback) must agree with a plain json.load
# on the new component's path — the same parity promise versions-manifest.sh
# makes for every other component.
_shipped_ds="$(python3 -c 'import json; print(json.load(open("'"$ROOT"'/versions.json"))["components"]["dash-server"]["version"])')"
check "advertised version comes from versions.json" "$_shipped_ds" \
    "$(exakit_versions_value components.dash-server.version "$ROOT/versions.json")"
check "advertised version (awk fallback reader)" "$_shipped_ds" \
    "$( ( EXAKIT_DISABLE_SYSTEM_PYTHON=1; exakit_ensure_uv() { return 1; }; exakit_versions_value components.dash-server.version "$ROOT/versions.json" ) )"
# The published manifest can PREDATE an add-on (a kit copy ships it before the
# advertised set catches up): the available version must fall back to the
# module's constant instead of reading as unknown — that empty answer used to
# make `exakit update dash-server` die on a machine whose fetched doc had no
# dash-server block yet.
check "a manifest without the add-on falls back to the module constant" \
    "$EXAKIT_DASH_SERVER_VERSION_FALLBACK" \
    "$( ( exakit_versions_value() { return 1; }; exakit_component_available dash-server ) )"
check "env override wins" "9.9.9" "$(EXAKIT_DASH_SERVER_VERSION=9.9.9 _exakit_component_env_override dash-server)"
check "release url is the tag tarball" \
    "https://github.com/exasol-labs/dash-server/archive/refs/tags/v0.1.0.tar.gz" \
    "$(dash_server_release_url 0.1.0)"

echo "update targets never sneak an add-on in:"
check "not installed -> excluded from all" "exakit runtime exapump mcp pyexasol" \
    "$(exakit_update_targets all | tr '\n' ' ' | sed 's/ $//')"
check "explicit target still routable" "dash-server" "$(exakit_update_targets dash-server)"
check "pending detection sees the gap" "yes" "$(exakit_marketplace_has_pending && echo yes || echo no)"

# A fake installed venv: exakit_component_current probes this python stub, so
# from here on the add-on counts as installed.
mkdir -p "$EXAKIT_HOME/dash-server-venv/bin"
cat > "$EXAKIT_HOME/dash-server-venv/bin/python" <<'EOF'
#!/bin/sh
echo "0.1.0"
EOF
chmod +x "$EXAKIT_HOME/dash-server-venv/bin/python"
manifest_set components.dash_server.python "$EXAKIT_HOME/dash-server-venv/bin/python"
manifest_set components.dash_server.version "0.1.0"

echo "installed add-on state:"
check "live probe answers" "0.1.0" "$(exakit_component_current dash-server)"
check "installed -> joins update all" "exakit runtime exapump mcp pyexasol dash-server" \
    "$(exakit_update_targets all | tr '\n' ' ' | sed 's/ $//')"
check "installed-addons list" "dash-server" "$(exakit_marketplace_installed_addons)"
check "nothing pending once installed" "no" "$(exakit_marketplace_has_pending && echo yes || echo no)"

# Deleting the stub must flip everything back: a stale manifest record alone
# may never count as installed.
rm -rf "$EXAKIT_HOME/dash-server-venv"
echo "a stale record is not an install:"
check "probe fails without the venv" "absent" "$(exakit_component_current dash-server >/dev/null 2>&1 && echo present || echo absent)"
check "excluded from update all again" "exakit runtime exapump mcp pyexasol" \
    "$(exakit_update_targets all | tr '\n' ' ' | sed 's/ $//')"

echo "EXAKIT_MARKETPLACE_ADDONS (the non-interactive contract):"
# The install functions are stubbed: this proves the routing, not pip.
run_menu() ( # run_menu <env-answer> — echoes "installed:<ids>" + menu output
    _CALLED=""
    dash_server_install() { _CALLED="${_CALLED} dash-server"; return 0; }
    dash_server_validate() { return 0; }
    EXAKIT_MARKETPLACE_ADDONS="$1"
    exakit_marketplace_menu >/dev/null 2>&1
    printf 'rc=%s called=%s' "$?" "${_CALLED# }"
)
check "none installs nothing" "rc=0 called=" "$(run_menu none)"
check "naming the addon installs it" "rc=0 called=dash-server" "$(run_menu dash-server)"
check "all installs every pending addon" "rc=0 called=dash-server" "$(run_menu all)"
_unknown_out="$( (run_menu not-a-tool) 2>&1 || true)"
check "an unknown id refuses" "yes" "$( (EXAKIT_MARKETPLACE_ADDONS=not-a-tool exakit_marketplace_menu >/dev/null 2>&1); [ $? -ne 0 ] && echo yes || echo no )"
# An installer that fails must not report success.
check "a failing installer surfaces" "rc=1" "$( (
    dash_server_install() { return 1; }
    dash_server_validate() { return 0; }
    EXAKIT_MARKETPLACE_ADDONS="dash-server"
    exakit_marketplace_menu >/dev/null 2>&1
    printf 'rc=%s' "$?"
) )"

echo "launcher generation:"
printf 's3cr3t-value\n' > "$WORK/pwfile"
chmod 600 "$WORK/pwfile"
manifest_set runtime.dsn "127.0.0.1:8563"
manifest_set runtime.user "sys"
manifest_set runtime.password_file "$WORK/pwfile"
( dash_server_write_launcher >/dev/null 2>&1 )
_launcher="$EXAKIT_BIN_DIR/dash-server"
check "launcher exists and is executable" "yes" "$([ -x "$_launcher" ] && echo yes || echo no)"
_launcher_body="$(cat "$_launcher" 2>/dev/null)"
has  "launcher bakes the DSN" "127.0.0.1:8563" "$_launcher_body"
has  "launcher reads the credential file at run time" "$WORK/pwfile" "$_launcher_body"
lacks "the password itself never lands in the launcher" "s3cr3t-value" "$_launcher_body"
has  "user overrides win (setdefault DSN guard)" 'DASH_SERVER_EXASOL_DSN:-' "$_launcher_body"
has  "instance path is kit-managed" "$EXAKIT_HOME/dash-server/instance" "$_launcher_body"
has  "profile bootstrap goes through the env secret" "DASH_SERVER_EXASOL_SECRET_ENV_VAR" "$_launcher_body"

echo "generic registry (no per-add-on case arms):"
# The whole point of the generic arms: an id the registry does not carry must
# read as "unknown component" everywhere, without any case-statement edit.
check "unregistered id: no block" "no" "$(_exakit_component_block not-a-tool >/dev/null 2>&1 && echo yes || echo no)"
check "unregistered id: no update target" "no" "$(exakit_update_targets not-a-tool >/dev/null 2>&1 && echo yes || echo no)"
check "unregistered id: no fallback" "no" "$(_exakit_component_fallback not-a-tool >/dev/null 2>&1 && echo yes || echo no)"
check "addon env-var name derivation" "EXAKIT_DASH_SERVER_VERSION_FALLBACK" "$(_exakit_addon_env_var dash-server VERSION_FALLBACK)"
# The shared library must stay free of per-add-on case arms: a "dash-server)"
# pattern in common.sh would mean the generic registry regressed to surgery.
check "common.sh carries no dash-server case arm" "0" "$(grep -c 'dash-server)' "$ROOT/setup/lib/common.sh")"

echo "pip self-repair (dash-server app builds shell out to python -m pip):"
# The stub python fails `-m pip` until a marker file appears; the stubbed uv
# call plants it. Built OUTSIDE command substitution: bash 3.2 misparses a
# case close-paren inside $( ... ).
_pv="$WORK/pipless-venv"
mkdir -p "$_pv/bin"
cat > "$_pv/bin/python" <<'PYEOF'
#!/bin/sh
case "$*" in
    *"-m pip"*) [ -f "${0%/*}/pip-marker" ] || exit 1 ;;
    *) echo "0.1.0" ;;
esac
PYEOF
chmod +x "$_pv/bin/python"
_pip_repair="$( (
    EXAKIT_DASH_SERVER_VENV="$_pv"
    run_logged() { # the uv call: record it, then "install" pip
        printf '%s\n' "$*" >> "$WORK/uv-calls"
        : > "$_pv/bin/pip-marker"
    }
    : > "$WORK/uv-calls"
    _dash_server_ensure_pip fake-uv >/dev/null 2>&1 || { echo "repair-failed"; exit 0; }
    grep -q "fake-uv pip install --python $_pv/bin/python pip" "$WORK/uv-calls" && echo "repaired"
) )"
check "a pip-less venv is repaired through uv" "repaired" "$_pip_repair"
_pip_noop="$( (
    EXAKIT_DASH_SERVER_VENV="$_pv"   # now carries the pip-marker from the repair above
    run_logged() { printf '%s\n' "$*" >> "$WORK/uv-calls-2"; }
    : > "$WORK/uv-calls-2"
    _dash_server_ensure_pip fake-uv >/dev/null 2>&1
    [ -s "$WORK/uv-calls-2" ] && echo "reinstalled" || echo "left alone"
) )"
check "a venv that already has pip is left alone" "left alone" "$_pip_noop"

echo "soft-fail accounting:"
( _dash_server_not_installed "the disk caught fire" >/dev/null 2>&1 )
check "a soft miss records validated=false" "false" "$(manifest_get components.dash_server.validated)"

echo "update repair path:"
check "already-current says so and regenerates the launcher" "yes" "$( (
    dash_server_installed_version() { echo "0.0.1-test"; }
    exakit_component_available() { echo "0.0.1-test"; }
    rm -f "$EXAKIT_BIN_DIR/dash-server"
    dash_server_update >/dev/null 2>&1 && [ -x "$EXAKIT_BIN_DIR/dash-server" ] && echo yes || echo no
) )"

echo "a system install outside the kit is respected:"
# A same-named binary on PATH that is not the kit launcher: the tool is
# "present", so nothing advertises it — but the kit does NOT manage it, so it
# never joins the update flow either.
mkdir -p "$WORK/system-bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/system-bin/dash-server"
chmod +x "$WORK/system-bin/dash-server"
_sys_out="$( (
    PATH="$WORK/system-bin:$PATH"
    printf 'present=%s ' "$(_exakit_marketplace_addon_present dash-server && echo yes || echo no)"
    printf 'pending=%s ' "$(exakit_marketplace_has_pending && echo yes || echo no)"
    printf 'kit-managed=%s ' "$(exakit_marketplace_addon_installed dash-server && echo yes || echo no)"
    printf 'update-targets=%s' "$(exakit_update_targets all | tr '\n' ' ' | sed 's/ $//')"
) )"
check "system install covers the offer but stays unmanaged" \
    "present=yes pending=no kit-managed=no update-targets=exakit runtime exapump mcp pyexasol" "$_sys_out"
check "kit launcher on PATH is NOT a system install" "no" "$( (
    cp "$WORK/system-bin/dash-server" "$EXAKIT_BIN_DIR/dash-server"
    PATH="$EXAKIT_BIN_DIR:$PATH"
    _exakit_addon_system_present dash-server && echo yes || echo no
) )"
rm -f "$EXAKIT_BIN_DIR/dash-server"

echo "the closing offer (post-install):"
# Non-interactive (no TTY): the offer degrades to the one-line hint.
_offer_notty="$( (exakit_marketplace_offer) 2>&1 )"
has "no TTY -> one-line hint, no prompt" "exakit marketplace" "$_offer_notty"
lacks "no TTY -> no yes/no question" "marketplace now" "$_offer_notty"
# A scripted answer installs without asking.
check "EXAKIT_MARKETPLACE_ADDONS pre-answers the offer" "rc=0 called=dash-server" "$( (
    dash_server_install() { _CALLED="dash-server"; return 0; }
    dash_server_validate() { return 0; }
    _CALLED=""
    EXAKIT_MARKETPLACE_ADDONS="dash-server"
    exakit_marketplace_offer >/dev/null 2>&1
    printf 'rc=%s called=%s' "$?" "$_CALLED"
) )"
# Everything already present: the offer disappears entirely — no hint, no ask.
check "nothing pending -> the offer is silent" "" "$( (
    PATH="$WORK/system-bin:$PATH"
    exakit_marketplace_offer 2>&1
) )"
# Soft failures: the hint, never the "done and working" celebration.
_offer_soft="$( (
    EXAKIT_SOFT_FAILED="pyexasol"
    exakit_marketplace_offer 2>&1
) )"
lacks "soft failures -> no victory lap" "done and working" "$_offer_soft"
has "soft failures -> still hints at the marketplace" "exakit marketplace" "$_offer_soft"

echo "module missing from this kit copy (old kit updated over the wire):"
# The env answer names a real add-on whose module file did not ship: the
# refusal must name the fix (update the kit), not call the add-on unknown.
_missing_out="$( (
    unset -f dash_server_install
    EXAKIT_MARKETPLACE_ADDONS="dash-server"
    exakit_marketplace_menu 2>&1
) )"
has "env answer with module missing names the fix" "exakit update exakit" "$_missing_out"
lacks "and does not call the add-on unknown" "Unknown marketplace add-on" "$_missing_out"
# The generic installer path gives the same answer.
has "install-one with module missing names the fix" "exakit update exakit" "$( (
    unset -f dash_server_install
    _exakit_marketplace_install_one dash-server 2>&1
    :
) )"
# The update dispatch refuses cleanly too.
_upd_missing="$( (
    unset -f dash_server_update
    exakit_update_component dash-server 2>&1
) )"
check "update dispatch with module missing refuses" "no" "$(
    ( unset -f dash_server_update; exakit_update_component dash-server ) >/dev/null 2>&1 \
        && echo yes || echo no
)"
has "update dispatch refusal names the module" "dash-server module is not available" "$_upd_missing"

echo "install refuses a venv that cannot answer for its version:"
_noversion_out="$( (
    EXAKIT_DASH_SERVER_VENV="$WORK/hollow-venv"
    run_logged() { return 0; }               # venv creation and pip install "succeed"
    dash_server_installed_version() { return 1; }   # ...but the package never materializes
    dash_server_install 2>&1
    printf 'rc=%s' "$?"
) )"
has "a hollow install is refused, not reported" "cannot report a dash-server version" "$_noversion_out"
has "and it returns failure" "rc=1" "$_noversion_out"

echo "validation shortcut when the port already answers:"
mkdir -p "$WORK/live-venv/bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/live-venv/bin/python"
chmod +x "$WORK/live-venv/bin/python"
_live_out="$( (
    EXAKIT_DASH_SERVER_VENV="$WORK/live-venv"
    _dash_server_http_answers() { return 0; }    # something already serves /mcp
    dash_server_validate 2>&1
) )"
has "an already-running server validates without a second bind" "control plane answers" "$_live_out"
check "and records validated=true" "true" "$(manifest_get components.dash_server.validated)"

echo "everything covered — the menu becomes a status screen:"
mkdir -p "$EXAKIT_HOME/dash-server-venv/bin"
printf '#!/bin/sh\necho 0.1.0\n' > "$EXAKIT_HOME/dash-server-venv/bin/python"
chmod +x "$EXAKIT_HOME/dash-server-venv/bin/python"
_covered_out="$(exakit_marketplace_menu 2>&1)"
has "no selectable rows -> covered list, no menu" "Everything available is already" "$_covered_out"
has "the covered list shows the install" "installed" "$_covered_out"
rm -rf "$EXAKIT_HOME/dash-server-venv"

echo "the module system-present hook overrides the PATH check:"
check "hook says present -> present (no binary needed)" "yes" "$( (
    dash_server_system_present() { return 0; }
    _exakit_addon_system_present dash-server && echo yes || echo no
) )"
check "hook says absent -> absent (even with a binary on PATH)" "no" "$( (
    dash_server_system_present() { return 1; }
    PATH="$WORK/system-bin:$PATH"
    _exakit_addon_system_present dash-server && echo yes || echo no
) )"

echo "the CLI gate:"
_nomanifest_out="$( (
    _nm_home="$WORK/no-install"
    mkdir -p "$_nm_home/home" "$_nm_home/bin"
    EXAKIT_HOME="$_nm_home/home" EXAKIT_BIN_DIR="$_nm_home/bin" bash "$ROOT/setup/exakit" marketplace 2>&1
    printf 'rc=%s' "$?"
) )"
has "marketplace without an install refuses" "No installation found" "$_nomanifest_out"
has "and exits non-zero" "rc=1" "$_nomanifest_out"

echo "discovery one-liners:"
has "update-check discovery line names the addon" "dash-server" "$(exakit_print_marketplace_discovery_line)"
has "connection panel advertises the marketplace" "exakit marketplace" "$(connection_panel 2>/dev/null)"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
