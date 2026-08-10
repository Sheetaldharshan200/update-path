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
# The suite must behave the same on a machine that really has dash-server
# installed — the feature working must not fail its own tests. The generic
# system-present probe walks PATH, so rebuild PATH without any directory that
# carries a real dash-server (the system-install section below adds its own
# stub dir when it wants one).
_clean_path=""
_old_ifs="$IFS"; IFS=:
for _dir in $PATH; do
    [ -x "$_dir/dash-server" ] || _clean_path="${_clean_path:+$_clean_path:}$_dir"
done
IFS="$_old_ifs"
PATH="$_clean_path"
# Same isolation for the VS Code extension: its live probe asks the REAL VS
# Code unless an extensions dir is forced, so a developer machine that
# genuinely has the extension would silently cover the add-on. An empty
# sandbox dir makes every machine — with or without VS Code — read the same.
EXAKIT_EXASOL_VSCODE_EXTDIR="$WORK/vscode-ext"
mkdir -p "$EXAKIT_EXASOL_VSCODE_EXTDIR"
export EXAKIT_EXASOL_VSCODE_EXTDIR
# ...and a stub `code` ON PATH, so whether the extension add-on is APPLICABLE
# is fixed too. Without this the suite would read differently on a machine
# with VS Code than on a CI runner without it: the add-on is deliberately
# hidden where its host app is missing, which is exactly what the dedicated
# section below tests by hiding this stub again.
mkdir -p "$WORK/code-bin"
cat > "$WORK/code-bin/code" <<'CODESTUBEOF'
#!/bin/sh
echo "$*" >> "${CODE_CALLS:-/dev/null}"
case "$*" in
    *--list-extensions*) [ -n "${CODE_LISTING:-}" ] && printf '%s\n' "$CODE_LISTING" ;;
esac
exit 0
CODESTUBEOF
chmod +x "$WORK/code-bin/code"
PATH="$WORK/code-bin:$PATH"
. "$ROOT/setup/lib/common.sh"
. "$ROOT/setup/lib/dash-server.sh"
. "$ROOT/setup/lib/exasol-vscode.sh"

manifest_init >/dev/null 2>&1

echo "registry:"
check "addons list carries both add-ons" "dash-server exasol-vscode" \
    "$(exakit_marketplace_addons | cut -d'|' -f1 | tr '\n' ' ' | sed 's/ $//')"
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
# With a second add-on registered, one install no longer empties the offer —
# and once every add-on is covered, it does.
check "another add-on keeps the offer pending" "yes" "$(exakit_marketplace_has_pending && echo yes || echo no)"
check "nothing pending once ALL are covered" "no" "$( (
    exasol_vscode_system_present() { return 0; }
    exakit_marketplace_has_pending && echo yes || echo no
) )"

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
    exasol_vscode_install() { _CALLED="${_CALLED} exasol-vscode"; return 0; }
    exasol_vscode_validate() { return 0; }
    EXAKIT_MARKETPLACE_ADDONS="$1"
    exakit_marketplace_menu >/dev/null 2>&1
    printf 'rc=%s called=%s' "$?" "${_CALLED# }"
)
check "none installs nothing" "rc=0 called=" "$(run_menu none)"
check "naming one addon installs only it" "rc=0 called=dash-server" "$(run_menu dash-server)"
check "all installs every pending addon" "rc=0 called=dash-server exasol-vscode" "$(run_menu all)"
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
# Running the launcher while a copy is already serving must explain, not hand
# the user dash-server's single-coordinator traceback.
has  "the launcher refuses a duplicate politely" "already running" "$_launcher_body"
has  "and points at the state and log commands" "exakit logs dash-server" "$_launcher_body"

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
    exasol_vscode_system_present() { return 0; }   # cover the other add-on too
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
    exasol_vscode_system_present() { return 0; }
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
# The check is about the version probe, not uv — CI runners have no uv on
# PATH, so the bootstrap is stubbed to a fake binary either way (a machine
# with a real uv never reaches the stub).
printf '#!/bin/sh\nexit 0\n' > "$WORK/stub-uv"
chmod +x "$WORK/stub-uv"
_noversion_out="$( (
    EXAKIT_DASH_SERVER_VENV="$WORK/hollow-venv"
    exakit_ensure_uv() { EXAKIT_UV_BIN="$WORK/stub-uv"; return 0; }
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
_covered_out="$( (
    exasol_vscode_system_present() { return 0; }
    exakit_marketplace_menu 2>&1
) )"
has "no selectable rows -> covered list, no menu" "Everything available is already" "$_covered_out"
has "the covered list shows the install" "installed" "$_covered_out"
has "a system install reads as covered, not managed" "on this system" "$_covered_out"
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

echo "exasol-vscode (the VS Code extension add-on):"
# The stub `code` CLI created at the top answers the listing and records
# every invocation; CODE_LISTING and CODE_CALLS steer it per case.

check "live version parses publisher.id@version" "1.7.0" "$( (
    PATH="$WORK/code-bin:$PATH"
    CODE_LISTING="other.ext@2.0.0
exasol.exasol-vscode@1.7.0"
    export CODE_LISTING
    _exasol_vscode_live_version
) )"
check "extension in VS Code without a kit record = system install" "sys=yes kit=no" "$( (
    PATH="$WORK/code-bin:$PATH"
    CODE_LISTING="exasol.exasol-vscode@1.7.0"; export CODE_LISTING
    printf 'sys=%s ' "$(exasol_vscode_system_present && echo yes || echo no)"
    printf 'kit=%s' "$(exasol_vscode_installed_version >/dev/null 2>&1 && echo yes || echo no)"
) )"
check "kit record + live extension = kit-managed" "sys=no kit=1.7.0" "$( (
    PATH="$WORK/code-bin:$PATH"
    CODE_LISTING="exasol.exasol-vscode@1.7.0"; export CODE_LISTING
    manifest_set components.exasol_vscode.version "1.7.0"
    printf 'sys=%s ' "$(exasol_vscode_system_present && echo yes || echo no)"
    printf 'kit=%s' "$(exasol_vscode_installed_version)"
) )"
( . /dev/null; manifest_set components.exasol_vscode.version "" ) 2>/dev/null
python3 - "$EXAKIT_HOME/manifest.json" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
doc.get("components", {}).pop("exasol_vscode", None)
json.dump(doc, open(path, "w"))
PY
check "no record and no extension = simply pending" "no" "$( (
    PATH="$WORK/code-bin:$PATH"
    CODE_LISTING=""; export CODE_LISTING
    _exakit_marketplace_addon_present exasol-vscode && echo yes || echo no
) )"
check "the sandbox extensions dir is passed through" "yes" "$( (
    PATH="$WORK/code-bin:$PATH"
    CODE_CALLS="$WORK/code-calls"; export CODE_CALLS
    : > "$CODE_CALLS"
    _exasol_vscode_code --list-extensions >/dev/null 2>&1
    grep -q -- "--extensions-dir $EXAKIT_EXASOL_VSCODE_EXTDIR" "$CODE_CALLS" && echo yes || echo no
) )"

echo "an add-on that needs a host app is only offered when the app is there:"
# No VS Code on this machine → the extension is not an option at all: no menu
# row, no table line, nothing pending, nothing in the discovery line. The kit
# never advertises something it cannot install here.
_no_code="$( (
    exasol_vscode_code_cli() { return 1; }          # no VS Code anywhere
    printf 'applicable=%s ' "$(_exakit_addon_applicable exasol-vscode && echo yes || echo no)"
    printf 'offerable=%s ' "$(_exakit_addon_offerable exasol-vscode && echo yes || echo no)"
    printf 'in-menu=%s ' "$(exakit_marketplace_menu 2>&1 | grep -c exasol-vscode)"
    printf 'in-discovery=%s' "$(exakit_print_marketplace_discovery_line 2>&1 | grep -c exasol-vscode)"
) )"
check "without the host app it is hidden everywhere" \
    "applicable=no offerable=no in-menu=0 in-discovery=0" "$_no_code"
# With VS Code present it is a normal, selectable add-on again.
_with_code="$( (
    exasol_vscode_code_cli() { printf '/stub/code\n'; }
    printf 'applicable=%s ' "$(_exakit_addon_applicable exasol-vscode && echo yes || echo no)"
    printf 'in-menu=%s' "$(exakit_marketplace_menu 2>&1 | grep -c exasol-vscode)"
) )"
has "with the host app present it is offered again" "applicable=yes" "$_with_code"
check "and appears in the menu" "yes" "$(
    printf '%s' "$_with_code" | grep -q 'in-menu=0' && echo no || echo yes
)"
# Naming it explicitly on a machine without the app explains why, instead of
# claiming the add-on is unknown or failing deep in the installer.
_named="$( (
    exasol_vscode_code_cli() { return 1; }
    EXAKIT_MARKETPLACE_ADDONS="exasol-vscode"
    exakit_marketplace_menu 2>&1
) )"
has "naming it anyway explains the host app is missing" "VS Code was not found" "$_named"
lacks "and never calls it unknown" "Unknown marketplace add-on" "$_named"
# A kit-installed copy stays visible even if the app disappears afterwards, so
# it can still be updated or removed rather than becoming unreachable state.
check "an installed copy stays visible without the app" "yes" "$( (
    exasol_vscode_code_cli() { return 1; }
    exakit_marketplace_addon_installed() { return 0; }
    _exakit_addon_offerable exasol-vscode && echo yes || echo no
) )"

echo "exasol-vscode checksum chain (mirrors the exapump precedence):"
check "the advertised version verifies against versions.json" \
    "$(exakit_versions_value components.exasol-vscode.sha256.vsix "$ROOT/versions.json")" \
    "$(exasol_vscode_expected_sha256 "$(exakit_versions_value components.exasol-vscode.version "$ROOT/versions.json")")"
check "an unadvertised version falls to the pinned table, then the API" "pinned-empty from-api" "$( (
    exasol_vscode_pinned_sha256() { printf ''; }
    exasol_vscode_release_digest_from_api() { printf 'from-api\n'; }
    printf 'pinned-empty %s' "$(exasol_vscode_expected_sha256 0.0.0-not-advertised)"
) )"
check "a checksum mismatch refuses the install" "refused rc=1" "$( (
    PATH="$WORK/code-bin:$PATH"
    fetch() { printf 'not-the-real-vsix' > "$2"; }
    exasol_vscode_expected_sha256() { printf '%064d\n' 1; }
    exasol_vscode_install >/dev/null 2>&1 && printf 'installed' || printf 'refused rc=1'
) )"
check "no checksum anywhere refuses the install" "yes" "$( (
    PATH="$WORK/code-bin:$PATH"
    fetch() { printf 'payload' > "$2"; }
    exasol_vscode_expected_sha256() { return 1; }
    exasol_vscode_install 2>&1 | grep -q "refusing an unverified extension" && echo yes || echo no
) )"
check "no VS Code anywhere is a soft miss naming the fix" "yes" "$( (
    exasol_vscode_code_cli() { return 1; }
    exasol_vscode_install 2>&1 | grep -q "install VS Code" && echo yes || echo no
) )"

echo "add-on uninstall hooks (what folds them into exakit uninstall):"
# dash-server: dry narrates, real removes venv + state + launcher + record.
mkdir -p "$EXAKIT_HOME/dash-server-venv" "$EXAKIT_HOME/dash-server" "$EXAKIT_BIN_DIR"
: > "$EXAKIT_BIN_DIR/dash-server"
manifest_set components.dash_server.version "0.1.0"
_ds_dry="$(dash_server_uninstall 1 2>&1)"
has "dash-server dry-run narrates, removes nothing" "will remove" "$_ds_dry"
check "and the venv survives a dry-run" "yes" "$([ -d "$EXAKIT_HOME/dash-server-venv" ] && echo yes || echo no)"
dash_server_uninstall 0 >/dev/null 2>&1
check "real run removes venv, state and launcher" "GONE GONE GONE" "$(
    for p in "$EXAKIT_HOME/dash-server-venv" "$EXAKIT_HOME/dash-server" "$EXAKIT_BIN_DIR/dash-server"; do
        [ -e "$p" ] && printf 'KEPT ' || printf 'GONE '
    done | sed 's/ $//'
)"
check "and clears the manifest record" "absent" "$(manifest_get components.dash_server.version >/dev/null 2>&1 && echo present || echo absent)"

# exasol-vscode: a kit-managed copy is removed through VS Code's own CLI; a
# copy the kit never installed is refused, and the CLI is never invoked.
_vs_kit="$( (
    PATH="$WORK/code-bin:$PATH"
    CODE_LISTING="exasol.exasol-vscode@1.7.0"; export CODE_LISTING
    CODE_CALLS="$WORK/un-calls"; export CODE_CALLS
    : > "$CODE_CALLS"
    manifest_set components.exasol_vscode.version "1.7.0"
    exasol_vscode_uninstall 0 >/dev/null 2>&1
    grep -q -- "--uninstall-extension exasol.exasol-vscode" "$CODE_CALLS" && printf 'cli-called '
    manifest_get components.exasol_vscode.version >/dev/null 2>&1 && printf 'record-kept' || printf 'record-cleared'
) )"
check "kit-managed extension: removed via code CLI, record cleared" "cli-called record-cleared" "$_vs_kit"
_vs_sys="$( (
    PATH="$WORK/code-bin:$PATH"
    CODE_LISTING="exasol.exasol-vscode@1.7.0"; export CODE_LISTING
    CODE_CALLS="$WORK/un-calls-2"; export CODE_CALLS
    : > "$CODE_CALLS"
    exasol_vscode_uninstall 0 2>&1 | grep -q "not kit-managed" && printf 'refused '
    grep -q -- "--uninstall-extension" "$CODE_CALLS" && printf 'cli-called' || printf 'cli-untouched'
) )"
check "a Marketplace-installed copy is refused, CLI untouched" "refused cli-untouched" "$_vs_sys"

echo "EVERYTHING behaves as a master toggle (uninstall menu):"
# Layout under test — the shape exakit_uninstall_menu builds:
#   1 Skip · 2 #Components · 3,4 components · 5 #Add-ons · 6 add-on · 7 EVERYTHING
# Rows 2 and 5 are headers: a select-all must skip them, and the all-children
# rule must not wait on them. The primitive is pure, so these are exact.
_UI_CHECKBOX_SELECTABLE="1 3 4 6 7"
_GROUP="7:2:6:all"
sorted() { printf '%s' "$1" | tr ',' '\n' | sort -n | tr '\n' ',' | sed 's/,$//'; }
# Ticking EVERYTHING ticks every selectable child (never the headers).
check "picking EVERYTHING ticks every row" "3,4,6,7" \
    "$(sorted "$(_ui_checkbox_apply_group "7" 7 "$_GROUP")")"
# Unticking any single child releases EVERYTHING, and leaves the rest ticked.
check "unticking one row releases EVERYTHING" "3,6" \
    "$(sorted "$(_ui_checkbox_apply_group "3,6,7" 4 "$_GROUP")")"
# Ticking the last missing child re-derives EVERYTHING on its own.
check "ticking the last row re-derives EVERYTHING" "3,4,6,7" \
    "$(sorted "$(_ui_checkbox_apply_group "3,4,6" 6 "$_GROUP")")"
# Unticking EVERYTHING clears the whole selection.
check "unticking EVERYTHING clears every row" "" \
    "$(sorted "$(_ui_checkbox_apply_group "3,4,6" 7 "$_GROUP")")"
# A header can never be checked, so it never blocks the all-children rule.
check "headers never count as children" "3,4,6,7" \
    "$(sorted "$(_ui_checkbox_apply_group "3,4,6,7" 4 "$_GROUP")")"
# The default "any" mode is untouched — the data-load menu depends on it.
check "any-mode parent stays checked while one child is" "1,2" \
    "$( _UI_CHECKBOX_SELECTABLE="1 2 3"; sorted "$(_ui_checkbox_apply_group "2" 2 "1:2:3")" )"
_UI_CHECKBOX_SELECTABLE=""

echo "the selectable uninstall (registry-driven, zero wiring per add-on):"
check "the executor dispatches an add-on to its own hook" "hook-ran" "$( (
    dash_server_uninstall() { printf 'hook-ran'; }
    _exakit_uninstall_component dash-server 0
) )"
check "an add-on without a hook explains instead of failing" "yes" "$( (
    unset -f exasol_vscode_uninstall
    _exakit_uninstall_component exasol-vscode 0 2>&1 | grep -q "update the kit" && echo yes || echo no
) )"
check "an unknown target warns, never dies" "rc=0" "$( (
    _exakit_uninstall_component not-a-thing 0 >/dev/null 2>&1
    printf 'rc=%s' "$?"
) )"
# Partial bookkeeping: removing a piece unmarks its step so a re-run reinstalls.
manifest_set steps_completed '["exapump","pyexasol"]'
exakit_unmark_step exapump
check "a partial removal unmarks the step flag" '["pyexasol"]' "$(manifest_get steps_completed)"
manifest_set components.exapump.version "0.11.3"
manifest_del components.exapump
check "manifest_del clears the whole component block" "absent" "$(manifest_get components.exapump >/dev/null 2>&1 && echo present || echo absent)"

echo "component logs (one command reaches every one of them):"
mkdir -p "$EXAKIT_HOME/logs"
printf 'installer line one\ninstaller line two\n' > "$EXAKIT_HOME/logs/install-20260810-090000.log"
check "the setup log is a target" "setup" "$(exakit_log_targets | cut -d'|' -f1 | grep -x setup)"
# An add-on is viewable as soon as its module names a log — the same
# registry-driven contract the other hooks use.
printf 'dash line\n' > "$EXAKIT_HOME/logs/dash-server.log"
mkdir -p "$EXAKIT_HOME/dash-server-venv/bin"
printf '#!/bin/sh\necho 0.1.0\n' > "$EXAKIT_HOME/dash-server-venv/bin/python"
chmod +x "$EXAKIT_HOME/dash-server-venv/bin/python"
manifest_set components.dash_server.python "$EXAKIT_HOME/dash-server-venv/bin/python"
check "an installed add-on with a log hook is a target" "dash-server" \
    "$(exakit_log_targets | cut -d'|' -f1 | grep -x dash-server)"
check "--path prints the file, nothing else" "$EXAKIT_HOME/logs/dash-server.log" \
    "$(exakit_logs_show dash-server 0 200 1)"
has "viewing one tails its content" "dash line" "$(exakit_logs_show dash-server 0 200 0)"
has "the overview lists the targets in a table" "Target" "$(exakit_logs_overview)"
has "and names the add-on" "dash-server" "$(exakit_logs_overview)"
# An unknown name explains itself and lists what exists, rather than dying bare.
_log_unknown="$( (exakit_logs_show not-a-log 0 200 0) 2>&1 || true)"
has "an unknown target lists what is available" "Available:" "$_log_unknown"
check "and it fails rather than printing nothing" "no" "$(
    ( exakit_logs_show not-a-log 0 200 0 ) >/dev/null 2>&1 && echo yes || echo no
)"
# A log the module names but nothing has written yet is a clear message, not a
# confusing empty screen.
has "a not-yet-written log says so" "has not been written yet" "$( (
    dash_server_log_path() { printf '%s\n' "$WORK/never-written.log"; }
    exakit_logs_show dash-server 0 200 0
) 2>&1 || true)"
rm -f "$EXAKIT_HOME/logs/dash-server.log"

echo "services and autostart (is it running, and does it come back after a reboot):"
# A stand-in server on a quiet port: the status probe is an HTTP check, so
# anything that answers proves the plumbing without installing dash-server.
EXAKIT_DASH_SERVER_PORT="$((5900 + $$ % 90))"
mkdir -p "$EXAKIT_HOME/logs"
check "not installed reads as such, never 'stopped'" "not installed" "$(
    ( EXAKIT_DASH_SERVER_BIN="$WORK/nope"; dash_server_status )
)"
cat > "$EXAKIT_BIN_DIR/dash-server" <<SRVEOF
#!/bin/sh
exec python3 -m http.server $EXAKIT_DASH_SERVER_PORT --bind 127.0.0.1
SRVEOF
chmod +x "$EXAKIT_BIN_DIR/dash-server"
check "installed but down reads stopped" "stopped" "$(dash_server_status)"
dash_server_start >/dev/null 2>&1
check "start brings it up" "running" "$(dash_server_status)"
check "and records a pidfile" "yes" "$([ -f "$EXAKIT_DASH_SERVER_PIDFILE" ] && echo yes || echo no)"
has "starting twice is idempotent" "already running" "$(dash_server_start 2>&1)"
dash_server_stop >/dev/null 2>&1
check "stop takes it down and cleans the pidfile" "stopped cleaned" \
    "$(printf '%s %s' "$(dash_server_status)" "$([ -f "$EXAKIT_DASH_SERVER_PIDFILE" ] && echo kept || echo cleaned)")"
has "stopping twice is idempotent" "already stopped" "$(dash_server_stop 2>&1)"

# The service registry: database first, then any installed add-on that serves.
manifest_set runtime.type personal
mkdir -p "$EXAKIT_HOME/dash-server-venv/bin"
printf '#!/bin/sh\necho 0.1.0\n' > "$EXAKIT_HOME/dash-server-venv/bin/python"
chmod +x "$EXAKIT_HOME/dash-server-venv/bin/python"
manifest_set components.dash_server.python "$EXAKIT_HOME/dash-server-venv/bin/python"
check "the registry lists the database and the service add-on" "database dash-server" \
    "$(exakit_service_ids | tr '\n' ' ' | sed 's/ $//')"
# An add-on with no service hooks must not appear as a service.
check "a non-service add-on stays out of the registry" "no" "$(
    exakit_service_ids | grep -q exasol-vscode && echo yes || echo no
)"

# Autostart writes a real boot entry, into a sandbox dir, and takes it away.
EXAKIT_LAUNCHAGENT_DIR="$WORK/agents"
EXAKIT_SYSTEMD_USER_DIR="$WORK/systemd"
mkdir -p "$EXAKIT_LAUNCHAGENT_DIR" "$EXAKIT_SYSTEMD_USER_DIR"
_as_out="$( (
    launchctl() { :; }                     # never touch the real session
    systemctl() { return 1; }
    personal_cli() { printf '%s\n' "$EXAKIT_BIN_DIR/exasol"; }
    detect_os() { printf 'macos\n'; }
    exakit_autostart_enable >/dev/null 2>&1
    printf 'flag=%s ' "$(manifest_get autostart.enabled)"
    printf 'db=%s ' "$(_exakit_autostart_registered database && echo yes || echo no)"
    printf 'ds=%s' "$(_exakit_autostart_registered dash-server && echo yes || echo no)"
) )"
check "autostart on registers every service" "flag=true db=yes ds=yes" "$_as_out"
has "the entry runs the real launcher" "$EXAKIT_BIN_DIR/dash-server" \
    "$(cat "$EXAKIT_LAUNCHAGENT_DIR/com.exasol.exakit.dash-server.plist" 2>/dev/null)"
has "and starts at load, so a reboot brings it back" "RunAtLoad" \
    "$(cat "$EXAKIT_LAUNCHAGENT_DIR/com.exasol.exakit.dash-server.plist" 2>/dev/null)"
_as_off="$( (
    launchctl() { :; }
    systemctl() { return 1; }
    detect_os() { printf 'macos\n'; }
    exakit_autostart_disable >/dev/null 2>&1
    printf 'flag=%s entries=%s' "$(manifest_get autostart.enabled)" "$(ls "$EXAKIT_LAUNCHAGENT_DIR" | wc -l | tr -d ' ')"
) )"
check "autostart off removes every entry" "flag=false entries=0" "$_as_off"
# The full uninstall must not leave a boot entry pointing at deleted files.
# Its own kit home: the run removes $EXAKIT_HOME wholesale, and the checks
# after this one still need the suite's sandbox.
_as_sweep="$( (
    EXAKIT_HOME="$WORK/sweep-home"
    EXAKIT_BIN_DIR="$WORK/sweep-bin"
    EXAKIT_MANIFEST="$EXAKIT_HOME/manifest.json"
    EXAKIT_LAUNCHAGENT_DIR="$WORK/sweep-agents"
    mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR" "$EXAKIT_LAUNCHAGENT_DIR"
    launchctl() { :; }
    systemctl() { return 1; }
    detect_os() { printf 'macos\n'; }
    personal_cli() { printf '%s\n' "$EXAKIT_BIN_DIR/exasol"; }
    manifest_init >/dev/null 2>&1
    manifest_set runtime.type personal
    exakit_autostart_enable >/dev/null 2>&1
    # "some" not a count: how many services this sandbox happens to expose is
    # not the point — that entries existed and none survived is.
    [ "$(ls "$EXAKIT_LAUNCHAGENT_DIR" | wc -l | tr -d ' ')" -gt 0 ] && printf 'before=some ' || printf 'before=none '
    nano_teardown() { :; }; personal_teardown() { :; }; exakit_mcp_operation() { :; }
    exakit_uninstall_run 0 >/dev/null 2>&1
    printf 'after=%s' "$(ls "$EXAKIT_LAUNCHAGENT_DIR" 2>/dev/null | wc -l | tr -d ' ')"
) )"
check "uninstall sweeps the boot entries too" "before=some after=0" "$_as_sweep"

echo "discovery one-liners:"
has "update-check discovery line names the addon" "dash-server" "$(exakit_print_marketplace_discovery_line)"
has "connection panel advertises the marketplace" "exakit marketplace" "$(connection_panel 2>/dev/null)"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
