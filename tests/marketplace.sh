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
#
# HOME IS REDIRECTED TOO, and that is not belt-and-braces. Redirecting only
# EXAKIT_HOME and EXAKIT_BIN_DIR left every path spelled "$HOME/..." pointing at
# the developer's real home, and this suite exercises component removal — so a
# run of these tests deleted the developer's actual ~/.exapump profiles, and the
# machine only said so later, from an unrelated command. Anything derived from
# HOME at source time has to be redirected before common.sh is read.
EXAKIT_HOME="$WORK/home"
EXAKIT_BIN_DIR="$WORK/bin"
HOME="$WORK/fake-home"
export HOME
EXAKIT_EXAPUMP_CONFIG_DIR="$HOME/.exapump"
export EXAKIT_EXAPUMP_CONFIG_DIR
mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR" "$HOME"
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
. "$ROOT/setup/lib/json-tables.sh"

# ...and its own port. The default 5100 is where a developer's REAL dash-server
# listens, and the ownership probe would rightly call that a foreign process
# holding the suite's port. A sandbox-unique high port keeps every machine
# reading the same. Explicit, so the manifest never overrides it.
EXAKIT_DASH_SERVER_PORT="$((5900 + $$ % 90))"
_EXAKIT_DS_PORT_EXPLICIT=1

manifest_init >/dev/null 2>&1

# cover_every_addon — stub <id>_system_present for EVERY registered add-on, so
# "the user already has all of these" is expressed once instead of add-on by
# add-on. Call it inside the subshell whose result depends on nothing pending.
cover_every_addon() {
    for _cea_id in $(exakit_marketplace_addons | cut -d'|' -f1); do
        eval "$(printf '%s' "$_cea_id" | tr '-' '_')_system_present() { return 0; }"
    done
}

echo "registry:"
check "addons list carries every registered add-on" "dash-server exasol-vscode json-tables" \
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
# rm -f first: a uv-created venv's bin/python is a SYMLINK to the shared
# managed interpreter, and `>` follows symlinks -- writing through it
# replaced the developer's real 18 MB CPython with this 17-byte stub and
# broke uv for every later component install.
rm -f "$EXAKIT_HOME/dash-server-venv/bin/python"
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
    cover_every_addon
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
    json_tables_install() { _CALLED="${_CALLED} json-tables"; return 0; }
    json_tables_validate() { return 0; }
    EXAKIT_MARKETPLACE_ADDONS="$1"
    exakit_marketplace_menu >/dev/null 2>&1
    printf 'rc=%s called=%s' "$?" "${_CALLED# }"
)
check "none installs nothing" "rc=0 called=" "$(run_menu none)"
check "naming one addon installs only it" "rc=0 called=dash-server" "$(run_menu dash-server)"
check "all installs every pending addon" "rc=0 called=dash-server exasol-vscode json-tables" "$(run_menu all)"
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
rm -f "$_pv/bin/python"
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
# Naming an add-on explicitly must reach its module even when the version
# matches: the hook doubles as the repair command (it rewrites a launcher a
# newer kit improved). `update all` must still skip it — routine updates are a
# work plan, not a sweep of every repair path.
# The hook records into a file: exakit_update's own stdout is noisy, so the
# marker cannot be read off it.
: > "$WORK/hook-marker"
( exakit_component_current() { printf '0.1.0\n'; }
  exakit_component_available() { printf '0.1.0\n'; }
  dash_server_update() { printf 'hook-ran' > "$WORK/hook-marker"; }
  exakit_update dash-server ) >/dev/null 2>&1
check "explicit update reaches the hook when versions match" "hook-ran" "$(cat "$WORK/hook-marker")"
: > "$WORK/hook-marker"
( exakit_component_current() { printf '0.1.0\n'; }
  exakit_component_available() { printf '0.1.0\n'; }
  dash_server_update() { printf 'hook-ran' > "$WORK/hook-marker"; }
  exakit_update all ) >/dev/null 2>&1
check "update all still skips an already-current add-on" "" "$(cat "$WORK/hook-marker")"
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
    cover_every_addon                              # cover the other add-ons too
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
    cover_every_addon
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
rm -f "$WORK/live-venv/bin/python"
printf '#!/bin/sh\nexit 0\n' > "$WORK/live-venv/bin/python"
chmod +x "$WORK/live-venv/bin/python"
_live_out="$( (
    EXAKIT_DASH_SERVER_VENV="$WORK/live-venv"
    _dash_server_port_foreign_desc() { return 1; }   # nobody else holds the port
    _dash_server_http_answers() { return 0; }    # something already serves /mcp
    dash_server_validate 2>&1
) )"
has "an already-running server validates without a second bind" "control plane answers" "$_live_out"
check "and records validated=true" "true" "$(manifest_get components.dash_server.validated)"

echo "everything covered — the menu becomes a status screen:"
mkdir -p "$EXAKIT_HOME/dash-server-venv/bin"
rm -f "$EXAKIT_HOME/dash-server-venv/bin/python"
printf '#!/bin/sh\necho 0.1.0\n' > "$EXAKIT_HOME/dash-server-venv/bin/python"
chmod +x "$EXAKIT_HOME/dash-server-venv/bin/python"
_covered_out="$( (
    cover_every_addon
    exakit_marketplace_menu 2>&1
) )"
has "no selectable rows -> covered list, no menu" "Everything available is already" "$_covered_out"
has "the covered list shows the install" "Installed. Update:" "$_covered_out"
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
    cover_every_addon
    exasol_vscode_code_cli() { return 1; }          # no VS Code anywhere
    exasol_vscode_system_present() { return 1; }    # ...and not present either
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

echo "the browser UI is validated separately from the control plane:"
# The packaging gap that shipped a 500 to a user looked healthy on /mcp. A
# broken page must be reported, never pass silently — and it must not fail the
# install, because agents can still drive the add-on over MCP.
_ui_bad="$( (
    _dash_server_ui_answers() { return 1; }
    _dash_server_check_ui 2>&1
) )"
has "a broken dashboards page is called out" "does not render" "$_ui_bad"
check "and recorded, not swallowed" "false" "$(manifest_get components.dash_server.ui_validated)"
_ui_good="$( (
    _dash_server_ui_answers() { return 0; }
    _dash_server_check_ui 2>&1
) )"
has "a working page is confirmed" "Dashboards page answers" "$_ui_good"
check "and recorded" "true" "$(manifest_get components.dash_server.ui_validated)"

# The fresh-install path starts its own probe server, and the browser page must
# be probed WHILE that server is alive. Probing after the kill asked a DEAD
# port whether it renders, so every fresh install warned "the dashboards page
# does not render" about a page that worked the moment the user opened it.
# The fake server below drops its marker when killed, so a probe that happens
# after the kill genuinely sees nothing — which is what makes this discriminate.
_ui_order="$( (
    dash_server_venv_python() { printf '%s\n' "$EXAKIT_HOME/dash-server-venv/bin/python"; }
    mkdir -p "$EXAKIT_HOME/dash-server-venv/bin"
    rm -f "$EXAKIT_HOME/dash-server-venv/bin/python"
    printf '#!/bin/sh\nexit 0\n' > "$EXAKIT_HOME/dash-server-venv/bin/python"
    chmod 755 "$EXAKIT_HOME/dash-server-venv/bin/python"
    _dash_server_resolve_port() { :; }
    _dash_server_port_foreign_desc() { return 1; }
    _dash_server_http_answers() { [ -f "$WORK/probe-up" ]; }
    _dash_server_ui_answers() { [ -f "$WORK/probe-up" ]; }
    EXAKIT_DASH_SERVER_BIN="$WORK/fake-dash-server"
    cat > "$WORK/fake-dash-server" <<FAKEEOF
#!/bin/sh
trap 'rm -f "$WORK/probe-up"; exit 0' TERM INT
touch "$WORK/probe-up"
while :; do sleep 1; done
FAKEEOF
    chmod 755 "$WORK/fake-dash-server"
    _dash_server_print_usage() { :; }
    rm -f "$WORK/probe-up"
    dash_server_validate >/dev/null 2>&1
    printf 'ui=%s' "$(manifest_get components.dash_server.ui_validated)"
) )"
check "the UI is probed while the probe server is alive" "ui=true" "$_ui_order"

# The stale-process repair: a server started BEFORE the package-data restore
# serves 500 on templates that are on disk, and re-validating the same process
# can never heal it. When the broken page is on OUR OWN instance, validation
# restarts it once; a foreign holder is never touched.
_ui_heal="$( (
    dash_server_venv_python() { printf '%s\n' "$EXAKIT_HOME/dash-server-venv/bin/python"; }
    mkdir -p "$EXAKIT_HOME/dash-server-venv/bin"
    rm -f "$EXAKIT_HOME/dash-server-venv/bin/python"
    printf '#!/bin/sh\nexit 0\n' > "$EXAKIT_HOME/dash-server-venv/bin/python"
    chmod 755 "$EXAKIT_HOME/dash-server-venv/bin/python"
    _dash_server_resolve_port() { :; }
    _dash_server_port_foreign_desc() { return 1; }
    _dash_server_http_answers() { return 0; }
    _dash_server_ui_answers() { return 1; }
    _dash_server_port_is_ours() { return 0; }
    dash_server_stop() { printf 'STOPPED ' >> "$WORK/heal-trace"; }
    dash_server_start() { printf 'STARTED ' >> "$WORK/heal-trace"; _dash_server_ui_answers() { return 0; }; }
    _dash_server_print_usage() { :; }
    : > "$WORK/heal-trace"
    dash_server_validate >/dev/null 2>&1
    printf '%sui=%s' "$(cat "$WORK/heal-trace")" "$(manifest_get components.dash_server.ui_validated)"
) )"
check "a stale instance of ours is restarted, then judged" "STOPPED STARTED ui=true" "$_ui_heal"
_ui_foreign="$( (
    dash_server_venv_python() { printf '%s\n' "$EXAKIT_HOME/dash-server-venv/bin/python"; }
    _dash_server_resolve_port() { :; }
    _dash_server_port_foreign_desc() { return 1; }
    _dash_server_http_answers() { return 0; }
    _dash_server_ui_answers() { return 1; }
    _dash_server_port_is_ours() { return 1; }
    dash_server_stop() { printf 'STOPPED ' >> "$WORK/heal-trace2"; }
    dash_server_start() { printf 'STARTED ' >> "$WORK/heal-trace2"; }
    _dash_server_print_usage() { :; }
    : > "$WORK/heal-trace2"
    dash_server_validate >/dev/null 2>&1
    [ -s "$WORK/heal-trace2" ] && printf 'restarted' || printf 'untouched'
) )"
check "a foreign holder is never restarted" "untouched" "$_ui_foreign"
# The restore only fills GAPS: a file the install already placed is never
# overwritten, so a fixed upstream release makes it a silent no-op.
check "restoring package data leaves existing files alone" "original" "$( (
    _drp_dir="$WORK/site/dash_server"
    mkdir -p "$_drp_dir/templates"
    printf 'original' > "$_drp_dir/templates/keep.html"
    dash_server_venv_python() { printf '%s\n' "$WORK/stub-py"; }
    printf '#!/bin/sh\nprintf "%s\\n" "'"$_drp_dir"'"\n' > "$WORK/stub-py"; chmod +x "$WORK/stub-py"
    fetch() { return 1; }          # no network in the suite: the restore bails out
    _dash_server_restore_package_data >/dev/null 2>&1
    cat "$_drp_dir/templates/keep.html"
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
rm -f "$EXAKIT_HOME/dash-server-venv/bin/python"
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
mkdir -p "$EXAKIT_HOME/logs" "$EXAKIT_HOME/dash-server-venv/bin"
# The stand-in server must look like ours to the ownership probe, which matches
# on the venv path. The real console script is run as
# `<venv>/bin/python <venv>/bin/dash-server`, so the venv shows up in argv - a
# bare `python3 -m http.server` never would. A script INSIDE the venv bin
# reproduces that shape (a symlinked interpreter does not: macOS resolves
# argv[0] to the framework binary).
cat > "$EXAKIT_HOME/dash-server-venv/bin/serve.py" <<'SERVEEOF'
import http.server, socketserver, sys
with socketserver.TCPServer(("127.0.0.1", int(sys.argv[1])), http.server.SimpleHTTPRequestHandler) as httpd:
    httpd.serve_forever()
SERVEEOF
check "not installed reads as such, never 'stopped'" "not installed" "$(
    ( EXAKIT_DASH_SERVER_BIN="$WORK/nope"; dash_server_status )
)"
cat > "$EXAKIT_BIN_DIR/dash-server" <<SRVEOF
#!/bin/sh
exec python3 "$EXAKIT_HOME/dash-server-venv/bin/serve.py" $EXAKIT_DASH_SERVER_PORT
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

echo "a port held by someone else is never mistaken for dash-server:"
# The old probe asked "does something answer HTTP here", so ANY web server on
# the port made the kit report a healthy add-on it never started. Ownership is
# matched on the venv path, the way the real console script is recognised.
#
# The foreign listener must PROVABLY be up before anything is asserted about
# it: a fixed sleep was not enough on GitHub's macOS runners (a cold python
# can take longer than 2s to serve), and every check below reads as a product
# failure when the fixture silently is not there. So: try a few candidate
# ports (the first choice can be genuinely taken on a shared runner), poll
# until the listener ANSWERS, and if none can be started, skip the section
# with the reason instead of failing on a fixture.
_foreign_port=""
_foreign_pid=""
for _fp_try in "$((6100 + $$ % 80))" "$((6300 + $$ % 80))" "$((6500 + $$ % 80))"; do
    python3 -m http.server "$_fp_try" --bind 127.0.0.1 >/dev/null 2>&1 &
    _fp_pid=$!
    _fp_up=0
    _fp_n=0
    while [ "$_fp_n" -lt 40 ]; do
        if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$_fp_try/" 2>/dev/null; then
            _fp_up=1
            break
        fi
        # The process dying (port taken, python unhappy) ends the wait early.
        kill -0 "$_fp_pid" 2>/dev/null || break
        sleep 0.5
        _fp_n=$((_fp_n + 1))
    done
    if [ "$_fp_up" -eq 1 ]; then
        _foreign_port="$_fp_try"
        _foreign_pid="$_fp_pid"
        break
    fi
    kill "$_fp_pid" 2>/dev/null
    wait "$_fp_pid" 2>/dev/null || true
done
if [ -z "$_foreign_port" ]; then
    echo "  SKIP  no local test listener could be started on this machine — port-ownership checks not run"
else
_port_verdict="$( (
    EXAKIT_DASH_SERVER_PORT="$_foreign_port"
    printf 'status=%s ' "$(dash_server_status | cut -d'(' -f1 | sed 's/ *$//')"
    printf 'ours=%s ' "$(_dash_server_port_is_ours && echo yes || echo no)"
    printf 'foreign=%s' "$(_dash_server_port_foreign_desc >/dev/null 2>&1 && echo yes || echo no)"
) )"
check "a foreign listener reads as stopped, not running" "status=stopped ours=no foreign=yes" "$_port_verdict"
has "status names the process holding it" "held by another process" \
    "$( ( EXAKIT_DASH_SERVER_PORT="$_foreign_port"; dash_server_status ) )"
_start_refusal="$( ( EXAKIT_DASH_SERVER_PORT="$_foreign_port"; dash_server_start 2>&1 ) )"
has "start refuses instead of claiming success" "cannot bind" "$_start_refusal"
has "and says how to move to a free port" "EXAKIT_DASH_SERVER_PORT" "$_start_refusal"
_val_refusal="$( ( EXAKIT_DASH_SERVER_PORT="$_foreign_port"; dash_server_validate 2>&1 ) )"
has "validation refuses to claim health on someone else's port" "was not validated" "$_val_refusal"
# An install with no explicit port steps over the busy one instead of failing.
_settled="$( (
    EXAKIT_DASH_SERVER_PORT="$_foreign_port"
    _EXAKIT_DS_PORT_EXPLICIT=0
    _dash_server_settle_port >/dev/null 2>&1
    printf '%s' "$EXAKIT_DASH_SERVER_PORT"
) )"
check "an unnamed port steps past the collision" "$((_foreign_port + 1))" "$_settled"
# A port the user NAMED is refused rather than silently moved.
_explicit="$( (
    EXAKIT_DASH_SERVER_PORT="$_foreign_port"
    _EXAKIT_DS_PORT_EXPLICIT=1
    _dash_server_settle_port 2>&1 | head -1
) )"
has "a named port is refused, never moved behind your back" "is held by another process" "$_explicit"
kill "$_foreign_pid" 2>/dev/null
wait "$_foreign_pid" 2>/dev/null || true
fi

# The service registry: database first, then any installed add-on that serves.
manifest_set runtime.type personal
mkdir -p "$EXAKIT_HOME/dash-server-venv/bin"
rm -f "$EXAKIT_HOME/dash-server-venv/bin/python"
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

echo "json-tables (prebuilt engine, no Rust toolchain):"
check "the add-on is registered" "json-tables" \
    "$(exakit_marketplace_addons | cut -d'|' -f1 | grep -x json-tables)"
# The one-liner is what a first-time user reads in the table and the menu, so
# it says what the add-on DOES, in one short clause. The prebuilt-engine fact
# (no Rust toolchain needed) is real but is installation trivia, not a reason
# to pick it; it lives in skills/json-tables/SKILL.md where someone hitting a
# build question will look.
has "its one-liner says what the add-on does" "Load JSON files into Exasol" \
    "$(exakit_marketplace_addons | grep '^json-tables|')"

# The asset name is the contract between the packaging workflow and the
# installer: a mismatch means every download 404s. Pin both halves.
_jt_asset() { ( detect_os() { printf '%s\n' "$1"; }; detect_arch() { printf '%s\n' "$2"; }
    json_tables_engine_asset 2>/dev/null || printf 'NONE\n' ); }
check "macOS arm64 asks for the macos-aarch64 engine" "exasol-json-tables-ingest-macos-aarch64" \
    "$( ( detect_os() { printf 'macos\n'; }; detect_arch() { printf 'arm64\n'; }; json_tables_engine_asset ) )"
check "Linux x86_64 asks for the linux-x86_64 engine" "exasol-json-tables-ingest-linux-x86_64" \
    "$( ( detect_os() { printf 'linux\n'; }; detect_arch() { printf 'x86_64\n'; }; json_tables_engine_asset ) )"
check "Linux arm64 asks for the linux-aarch64 engine" "exasol-json-tables-ingest-linux-aarch64" \
    "$( ( detect_os() { printf 'linux\n'; }; detect_arch() { printf 'arm64\n'; }; json_tables_engine_asset ) )"
# An Intel Mac has no published engine and building one needs the toolchain the
# add-on exists to avoid: it must be HIDDEN, not offered and then failed.
check "an Intel Mac is not applicable" "hidden" \
    "$( ( detect_os() { printf 'macos\n'; }; detect_arch() { printf 'x86_64\n'; }
        json_tables_applicable && printf 'offered\n' || printf 'hidden\n' ) )"
has "and says why, in terms the user can act on" "no prebuilt ingest engine" \
    "$( ( detect_os() { printf 'macos\n'; }; detect_arch() { printf 'x86_64\n'; }
        json_tables_applicable_reason ) )"

# The mirror must be looked up where THIS kit came from: a user who installed
# from a fork gets that fork's mirror release, not the canonical repo's (which
# may not have one). Explicit override still wins; a checkout falls back.
check "the mirror follows the recorded install source" "some-fork/update-path" "$( (
    manifest_set kit.source "some-fork/update-path@main" >/dev/null 2>&1
    json_tables_mirror_repo
) )"
check "an explicit mirror override wins over the source" "elsewhere/mirror" "$( (
    manifest_set kit.source "some-fork/update-path@main" >/dev/null 2>&1
    EXAKIT_JSON_TABLES_MIRROR_REPO="elsewhere/mirror"
    json_tables_mirror_repo
) )"
check "a checkout install falls back to the kit repo" "$EXAKIT_KIT_REPO" "$( (
    manifest_set kit.source "checkout:/tmp/somewhere" >/dev/null 2>&1
    json_tables_mirror_repo
) )"

# The shim is the whole no-Rust story. Upstream's ONLY engine call is
#   cargo run --manifest-path <...>/json_tables_ingest/Cargo.toml -- <engine argv>
# so the shim must hand <engine argv> to the prebuilt binary verbatim: an extra
# or dropped argument here is a broken ingest for every user.
_jt_shim="$( (
    EXAKIT_JSON_TABLES_HOME="$WORK/jt"
    mkdir -p "$WORK/jt/libexec"
    printf '#!/bin/sh\nprintf "ARGV"; for a in "$@"; do printf " <%%s>" "$a"; done; printf "\\n"\n' \
        > "$WORK/jt/libexec/json_to_parquet"
    chmod 755 "$WORK/jt/libexec/json_to_parquet"
    json_tables_write_shim >/dev/null 2>&1
    "$WORK/jt/shim/cargo" run --manifest-path /x/crates/json_tables_ingest/Cargo.toml \
        -- --input /tmp/a.json --output-dir /tmp/out --schema-sql
) )"
check "the shim replays the engine argv exactly" \
    "ARGV <--input> </tmp/a.json> <--output-dir> </tmp/out> <--schema-sql>" "$_jt_shim"
# A user with their own cargo must keep it: the shim is only ever on PATH
# inside our launcher, and even there it must not swallow unrelated commands.
_jt_passthru="$( (
    EXAKIT_JSON_TABLES_HOME="$WORK/jt2"
    mkdir -p "$WORK/jt2/libexec" "$WORK/real-cargo"
    printf '#!/bin/sh\necho REAL-CARGO "$@"\n' > "$WORK/real-cargo/cargo"
    chmod 755 "$WORK/real-cargo/cargo"
    : > "$WORK/jt2/libexec/json_to_parquet"; chmod 755 "$WORK/jt2/libexec/json_to_parquet"
    json_tables_write_shim >/dev/null 2>&1
    PATH="$WORK/jt2/shim:$WORK/real-cargo" "$WORK/jt2/shim/cargo" build --release
) )"
check "anything else reaches the real cargo untouched" "REAL-CARGO build --release" "$_jt_passthru"

_jt_launcher="$( (
    EXAKIT_JSON_TABLES_HOME="$WORK/jt3"
    EXAKIT_JSON_TABLES_VENV="$WORK/jt3-venv"
    EXAKIT_JSON_TABLES_BIN="$WORK/bin/exasol-json-tables"
    json_tables_write_launcher >/dev/null 2>&1
    grep -c "$WORK/jt3/shim" "$WORK/bin/exasol-json-tables"
    grep -c "$WORK/jt3-venv/bin/exasol-json-tables" "$WORK/bin/exasol-json-tables"
) )"
check "the launcher fronts PATH with the shim and runs the venv CLI" "1
1" "$_jt_launcher"

# Half an install is not an install: a venv whose engine never arrived would
# pass an import check and then fail at the first ingest.
_jt_half="$( (
    EXAKIT_JSON_TABLES_VENV="$WORK/jt-half-venv"
    EXAKIT_JSON_TABLES_HOME="$WORK/jt-half"
    mkdir -p "$WORK/jt-half-venv/bin"
    rm -f "$WORK/jt-half-venv/bin/python"
    printf '#!/bin/sh\nexit 0\n' > "$WORK/jt-half-venv/bin/python"; chmod 755 "$WORK/jt-half-venv/bin/python"
    manifest_set components.json_tables.version 50d05da0f6da >/dev/null 2>&1
    json_tables_installed_version >/dev/null 2>&1 && printf 'installed\n' || printf 'not installed\n'
) )"
check "a venv without the engine does not count as installed" "not installed" "$_jt_half"

# The mirror release is published by our own workflow. Until it exists the
# add-on must fail SOFT and name the fix, never end the caller's run.
_jt_missing="$( (
    EXAKIT_JSON_TABLES_MIRROR_TAG="does-not-exist-$$"
    _json_tables_mirror_wheel_name() { return 1; }
    exakit_ensure_uv() { return 0; }
    EXAKIT_UV_BIN="$WORK/bin/uv"; printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/uv"; chmod 755 "$WORK/bin/uv"
    detect_os() { printf 'linux\n'; }; detect_arch() { printf 'x86_64\n'; }
    json_tables_install 2>&1 | tr '\n' ' '
    printf 'rc=%s' "$?"
) )"
has "a missing mirror release names the workflow to run" "pkg / json-tables" "$_jt_missing"
has "and stays a soft failure" "Everything else in the kit is unaffected" "$_jt_missing"

_jt_uninst="$( (
    EXAKIT_JSON_TABLES_VENV="$WORK/jt-u-venv"
    EXAKIT_JSON_TABLES_HOME="$WORK/jt-u"
    EXAKIT_JSON_TABLES_BIN="$WORK/bin/exasol-json-tables-u"
    mkdir -p "$EXAKIT_JSON_TABLES_VENV" "$EXAKIT_JSON_TABLES_HOME"
    : > "$EXAKIT_JSON_TABLES_BIN"
    manifest_set components.json_tables.version 50d05da0f6da >/dev/null 2>&1
    json_tables_uninstall 1 >/dev/null 2>&1
    [ -d "$EXAKIT_JSON_TABLES_VENV" ] && printf 'dry-kept '
    json_tables_uninstall 0 >/dev/null 2>&1
    for _p in "$EXAKIT_JSON_TABLES_VENV" "$EXAKIT_JSON_TABLES_HOME" "$EXAKIT_JSON_TABLES_BIN"; do
        [ -e "$_p" ] && printf 'LEFT ' || printf 'gone '
    done
    manifest_get components.json_tables.version >/dev/null 2>&1 && printf 'record' || printf 'cleared'
) )"
check "uninstall keeps a dry run, then removes every part" "dry-kept gone gone gone cleared" "$_jt_uninst"

echo "manual installs are never re-offered:"
# A tool the user installed themselves is "present": the marketplace must not
# advertise it, and the kit must never manage or remove it. The launcher name
# often differs from the add-on id, so this is keyed on EXAKIT_<ID>_BIN too --
# without that, a manual `pip install exasol-json-tables` would still be
# offered as if it were missing.
mkdir -p "$WORK/manual-bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/manual-bin/exasol-json-tables"
chmod 755 "$WORK/manual-bin/exasol-json-tables"
check "a manually installed add-on reads as present" "present" "$( (
    PATH="$WORK/manual-bin:$PATH"
    _exakit_marketplace_addon_present json-tables && printf 'present\n' || printf 'missing\n'
) )"
check "the menu says so instead of offering an install" "on this system" "$( (
    PATH="$WORK/manual-bin:$PATH"
    exakit_marketplace_menu 2>/dev/null | grep '^ *json-tables' | grep -o 'on this system' | head -1
) )"
check "and it cannot be selected" "not-selectable" "$( (
    PATH="$WORK/manual-bin:$PATH"
    EXAKIT_MARKETPLACE_ADDONS="json-tables"
    exakit_marketplace_menu 2>/dev/null | grep -q '^json-tables$' && printf 'selectable\n' || printf 'not-selectable\n'
) )"
check "with it gone, it is offerable again" "offered" "$( (
    _exakit_addon_offerable json-tables && printf 'offered\n' || printf 'not-offered\n'
) )"
# ...but the kit still must not claim to MANAGE it: a manual copy is not a kit
# install, so update/uninstall leave it alone.
check "a manual copy is never counted as kit-managed" "not-managed" "$( (
    PATH="$WORK/manual-bin:$PATH"
    exakit_marketplace_addon_installed json-tables && printf 'managed\n' || printf 'not-managed\n'
) )"
rm -f "$WORK/manual-bin/exasol-json-tables"

echo "nothing is advertised before it is built:"
# The mirror release is the authority on what can be installed. If the
# packaging workflow has not built a version yet, the update flow must not
# offer it -- an offer the user cannot act on is worse than no offer.
check "the advertised version comes from the mirror, not the manifest" "mirror-2026aa" "$( (
    _json_tables_mirror_version() { printf 'mirror-2026aa\n'; }
    exakit_component_latest json-tables
) )"
check "an unreachable mirror advertises nothing rather than guessing" "none" "$( (
    _json_tables_mirror_version() { return 1; }
    _out="$(exakit_component_latest json-tables 2>/dev/null || true)"
    [ -n "$_out" ] && printf '%s\n' "$_out" || printf 'none\n'
) )"
echo "data-load routes JSON through the add-on:"
. "$ROOT/setup/lib/exapump.sh"
check "file kinds are classified from the name" "csv parquet json json json csv unknown" "$(
    for _f in a.csv b.parquet c.json d.ndjson e.jsonl.gz f.CSV.gz g.xlsx; do
        printf '%s ' "$(exakit_data_file_kind "$_f")"
    done | sed 's/ $//')"

# Not applicable on this platform: the add-on is not even offered, and the
# reason names the platform rather than leaving the user guessing.
_jl_unsupported="$( (
    json_tables_installed_version() { return 1; }
    json_tables_applicable() { return 1; }
    exapump_upload() { printf 'UPLOAD-CALLED\n'; }
    exakit_load_local_json "$WORK/sample.json" "STARTER_KIT.SAMPLE" 2>&1
) )"
has "an unsupported platform says so" "not available on this machine" "$_jl_unsupported"
has "and points at what does work" "CSV and Parquet load without it" "$_jl_unsupported"
lacks "and offers no install" "Install it now" "$_jl_unsupported"

# Installed: the file is ingested and the resulting tables are pushed in by
# data-load itself -- the user hands over one JSON file and gets tables.
mkdir -p "$WORK/jt-bin"
cat > "$WORK/jt-bin/exasol-json-tables" <<'JTSTUBEOF'
#!/bin/sh
# stub CLI: writes the Parquet files a real ingest would produce
_out=""
while [ $# -gt 0 ]; do
    case "$1" in --output-dir) _out="$2"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$_out"
: > "$_out/orders.parquet"
[ -n "${JT_STUB_TABLES:-}" ] && : > "$_out/order_items.parquet"
exit 0
JTSTUBEOF
chmod 755 "$WORK/jt-bin/exasol-json-tables"
printf '[{"id":1}]\n' > "$WORK/sample.json"

# Not installed: the engine installs itself, silently. The user asked for a
# JSON file to be loaded -- the engine that reads one is an implementation
# detail, so nothing is asked and no install or download step is announced.
rm -f "$WORK/install-called"
_jl_silent="$( (
    EXAKIT_JSON_TABLES_BIN="$WORK/jt-bin/exasol-json-tables"
    : > "$WORK/ready-calls"
    # not ready on the first look, ready once the install has run
    _exakit_json_tables_ready() {
        printf 'x' >> "$WORK/ready-calls"
        [ "$(wc -c < "$WORK/ready-calls" | tr -d ' ')" -gt 1 ]
    }
    _exakit_json_tables_load_module() { return 0; }
    _exakit_addon_applicable() { return 0; }
    _exakit_marketplace_install_one() { printf '%s' "$1" > "$WORK/install-called"; return 0; }
    prompt_text() { printf 'PROMPTED '; }
    ui_checkbox_menu() { printf 'MENU '; }
    ui_panel_begin() { printf 'PANEL '; }
    run_logged() { "$@" >/dev/null 2>&1; }
    exakit_ensure_schema() { :; }
    exapump_upload() { printf 'UPLOAD:%s ' "$2"; }
    exakit_verify_loaded_table() { :; }
    exakit_load_local_json "$WORK/sample.json" "STARTER_KIT.SAMPLE" 2>&1
) )"
check "a missing engine installs itself" "json-tables" "$(cat "$WORK/install-called" 2>/dev/null)"
lacks "without asking the user anything" "PROMPTED" "$_jl_silent"
lacks "and without a checkbox" "MENU" "$_jl_silent"
lacks "and without an explanation panel" "PANEL" "$_jl_silent"
lacks "and without narrating the install" "Installing" "$_jl_silent"
has "and the data still lands" "UPLOAD:STARTER_KIT.SAMPLE" "$_jl_silent"

_jl_one="$( (
    EXAKIT_JSON_TABLES_BIN="$WORK/jt-bin/exasol-json-tables"
    json_tables_installed_version() { printf '50d05da0f6da\n'; }
    run_logged() { "$@" >/dev/null 2>&1; }
    info() { :; }; ok() { :; }
    exakit_ensure_schema() { printf 'SCHEMA:%s ' "$1"; }
    exapump_upload() { printf 'UPLOAD:%s->%s ' "${1##*/}" "$2"; }
    exakit_verify_loaded_table() { printf 'VERIFY:%s' "$1"; }
    exakit_load_local_json "$WORK/sample.json" "STARTER_KIT.SAMPLE" 2>/dev/null
) )"
check "one table: ingested, then loaded and verified" \
    "SCHEMA:STARTER_KIT UPLOAD:orders.parquet->STARTER_KIT.SAMPLE VERIFY:STARTER_KIT.SAMPLE" "$_jl_one"

# Nested JSON legitimately produces several tables: all of them must land, not
# just the first one.
_jl_many="$( (
    EXAKIT_JSON_TABLES_BIN="$WORK/jt-bin/exasol-json-tables"
    JT_STUB_TABLES=1; export JT_STUB_TABLES
    json_tables_installed_version() { printf '50d05da0f6da\n'; }
    run_logged() { "$@" >/dev/null 2>&1; }
    info() { :; }; ok() { :; }
    exakit_ensure_schema() { printf 'SCHEMA:%s ' "$1"; }
    exapump_upload() { printf 'UPLOAD:%s ' "$2"; }
    exakit_verify_loaded_table() { :; }
    exakit_load_local_json "$WORK/sample.json" "JSONDATA.SAMPLE" 2>/dev/null
) )"
check "every table from a nested document lands, under the name you gave" \
    "SCHEMA:JSONDATA UPLOAD:JSONDATA.SAMPLE_ORDER_ITEMS UPLOAD:JSONDATA.SAMPLE_ORDERS" \
    "$(printf '%s' "$_jl_many" | sed 's/ *$//')"

# A failed ingest must leave the database alone and name the log.
_jl_failed="$( (
    EXAKIT_JSON_TABLES_BIN="$WORK/jt-bin/exasol-json-tables"
    json_tables_installed_version() { printf '50d05da0f6da\n'; }
    run_logged() { return 1; }
    exapump_upload() { printf 'UPLOAD-CALLED\n'; }
    exakit_load_local_json "$WORK/sample.json" "STARTER_KIT.SAMPLE" 2>&1
    printf 'rc=%s' "$?"
) )"
has "a failed ingest names the log" "exakit logs json-tables" "$_jl_failed"
has "and says the database is unchanged" "database is unchanged" "$_jl_failed"
lacks "and uploads nothing" "UPLOAD-CALLED" "$_jl_failed"

# The CSV path must be completely untouched by all of this.
check "a CSV still never mentions the add-on" "csv" "$(exakit_data_file_kind "$WORK/x.csv")"

echo "discovery one-liners:"
_disc_line="$(exakit_print_marketplace_discovery_line)"
has "update-check discovery line advertises the marketplace" "exakit marketplace" "$_disc_line"
check "and names exactly the add-ons still pending" "$( (
    exakit_marketplace_addons | cut -d'|' -f1 | while read -r _dl_id; do
        [ -n "$_dl_id" ] || continue
        _exakit_addon_offerable "$_dl_id" || continue
        _exakit_marketplace_addon_present "$_dl_id" || printf '%s\n' "$_dl_id"
    done | paste -sd, - | sed 's/,/, /g'
) )" "$(printf '%s' "$_disc_line" | sed -n 's/.*available (\([^)]*\)).*/\1/p')"
has "connection panel advertises the marketplace" "exakit marketplace" "$(connection_panel 2>/dev/null)"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
