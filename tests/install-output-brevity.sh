#!/usr/bin/env bash
# install-output-brevity.sh — proves the closing stretch of an install says what
# the reader has to act on and nothing else: no reference panels whose every row
# is one command away, no nine ticked lines where a count will do, and nothing
# dropped that was not recoverable somewhere named.
#
#   bash tests/install-output-brevity.sh
#
# Pure rendering against a sandboxed kit home: no database, no network.

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

EXAKIT_HOME="$WORK/home"
EXAKIT_BIN_DIR="$WORK/bin"
HOME="$WORK/fake-home"
export HOME
mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR" "$HOME"

# shellcheck source=/dev/null
. "$ROOT/setup/lib/ui.sh"
# shellcheck source=/dev/null
. "$ROOT/setup/lib/common.sh"

EXAKIT_LOG_FILE="$WORK/install.log"
: > "$EXAKIT_LOG_FILE"
: > "$EXAKIT_MANIFEST"

manifest_get() {
    case "$1" in
        runtime.dsn)  printf '127.0.0.1:8563\n' ;;
        runtime.user) printf 'sys\n' ;;
        runtime.tls)  printf 'self-signed\n' ;;
        components.mcp_server.connection.user) printf 'mcp_readonly\n' ;;
        components.mcp_server.command)         printf '/home/u/.local/bin/uvx\n' ;;
        components.mcp_server.package)         printf 'exasol-mcp-server\n' ;;
        components.mcp_server.version)         printf '2.1.0\n' ;;
    esac
    return 0
}
manifest_set() { return 0; }
exakit_marketplace_addon_installed() { return 1; }

printf '\n== MCP setup: what to do, not what was written where ==\n'

cat > "$WORK/result.json" <<'JSONEOF'
{"status":"success_with_warnings",
 "selected_clients":["claude_desktop","claude_code","codex","vscode_copilot"],
 "artifacts":[{"client":"claude_desktop","path":"/h/Library/Application Support/Claude/claude_desktop_config.json"},
              {"client":"codex","path":"/h/.codex/config.toml"}],
 "findings":[{"message":"The database credential is stored as plaintext in the client configuration file."}],
 "next_actions":[{"message":"Restart Claude to load the updated MCP configuration."},
                 {"message":"Start a new Claude Code session (or run /mcp in an existing one) to load the updated MCP configuration."}]}
JSONEOF
SUMMARY="$(exakit_print_mcp_setup_summary "$WORK/result.json" 2>&1)"

has "the clients are named"        "MCP configured for Claude, Claude Code (CLI), Codex, GitHub Copilot" "$SUMMARY"
has "the credential warning stays" "stored as plaintext"  "$SUMMARY"
has "each client's next step stays" "Restart Claude to load" "$SUMMARY"
has "including the /mcp one"        "run /mcp in an existing one" "$SUMMARY"
has "and where the rest lives"      "exakit mcp-status" "$SUMMARY"

lacks "no Mode row"      "Mode:"      "$SUMMARY"
lacks "no Meaning row"   "Meaning:"   "$SUMMARY"
lacks "no Status row"    "Status:"    "$SUMMARY"
lacks "no per-file rows" "config.toml" "$SUMMARY"
lacks "no box"           "MCP setup summary" "$SUMMARY"
check "it fits in six lines" "yes" \
    "$([ "$(printf '%s\n' "$SUMMARY" | grep -c .)" -le 6 ] && echo yes || echo "no: $(printf '%s\n' "$SUMMARY" | grep -c .)")"

# A run that did NOT succeed must not be reported with a tick.
printf '%s\n' '{"status":"failed","selected_clients":["codex"]}' > "$WORK/bad.json"
BAD="$(exakit_print_mcp_setup_summary "$WORK/bad.json" 2>&1)"
has "a failed status says so" "finished as 'failed'" "$BAD"

printf '\n== MCP is ready: one line, with the rest in the log ==\n'

: > "$EXAKIT_LOG_FILE"
# No terminal in a test run, so the clipboard is never taken — which is exactly
# the branch that must still PRINT the prompt.
READY="$(exakit_print_mcp_ready_panel permanent 2>&1)"
has "the server, the DSN and the user" "MCP server 'exasol' — 127.0.0.1:8563 as mcp_readonly (read-only)" "$READY"
lacks "no reference box"     "MCP is ready"   "$READY"
lacks "no command row"       "exasol-mcp-server@2.1.0" "$READY"
lacks "no managed-state row" "Managed state"  "$READY"
has "the command is in the log"       "MCP command: /home/u/.local/bin/uvx exasol-mcp-server@2.1.0" "$(cat "$EXAKIT_LOG_FILE")"
has "so is the managed state"         "MCP managed state:" "$(cat "$EXAKIT_LOG_FILE")"

printf '\n== the first prompt is shown only when it was not handed over ==\n'

# No tty here: the clipboard is not ours to take, so the text is the only way to
# pass the prompt on and the panel MUST appear.
has "without a clipboard, the prompt is printed" "First prompt to try in your AI client" "$READY"
has "...in full"  "do not create, update, or delete anything" "$READY"

# With a terminal and a working clipboard, one line replaces the panel.
exakit_stdin_is_tty()   { return 0; }
exakit_copy_clipboard() { cat >/dev/null; return 0; }
COPIED="$(exakit_print_mcp_ready_panel permanent 2>&1)"
has "on the clipboard, it is one line" "is on your clipboard" "$COPIED"
lacks "and the panel is gone"          "First prompt to try"  "$COPIED"

printf '\n== the closing panel is four rows, and exakit info is still complete ==\n'

SHORT="$(connection_summary 2>&1)"
has "the DSN and admin user" "127.0.0.1:8563   (admin sys, TLS self-signed)" "$SHORT"
has "where the passwords are" "credentials" "$SHORT"
has "a SQL client"            "DBeaver"     "$SHORT"
has "and where everything is" "exakit info" "$SHORT"
lacks "no manifest row"       "Manifest"    "$SHORT"
lacks "no logs row"           "Logs:"       "$SHORT"
lacks "no MCP backups row"    "MCP backups" "$SHORT"

# The full panel is what `exakit info` prints. Collapsing the INSTALL must not
# collapse the reference screen.
FULL="$(connection_panel 2>&1)"
has "exakit info still has the runtime"  "Runtime:"     "$FULL"
has "...the manifest"                    "Manifest:"    "$FULL"
has "...the logs"                        "Logs:"        "$FULL"
has "...and the MCP user"                "MCP user:"    "$FULL"
check "the install panel is shorter than the reference one" "yes" \
    "$([ "$(printf '%s\n' "$SHORT" | grep -c .)" -lt "$(printf '%s\n' "$FULL" | grep -c .)" ] && echo yes || echo no)"

printf '\n== the installers end with the short one ==\n'

for _script in setup-macos.sh setup-wsl.sh; do
    has "$_script ends with the summary" "connection_summary" "$(cat "$ROOT/setup/$_script")"
    lacks "$_script does not print the full panel" "
connection_panel" "$(cat "$ROOT/setup/$_script")"
done
has "the Windows installer too" "Show-ExakitConnectionSummary" "$(cat "$ROOT/setup/setup-windows-docker.ps1")"

printf '\n== skills: a count, not a roll call ==\n'

COMMON="$(cat "$ROOT/setup/lib/common.sh")"
lacks "no per-skill screen line" 'ok "Installed skill: $_name"' "$COMMON"
has "the names still reach the log" '_exakit_log_file "OK    Installed skill: $_name"' "$COMMON"
has "and the count is announced"   'ok "Installed $_installed AI skill' "$COMMON"

printf '\n== the PowerShell twin moves with it ==\n'

MCP_PS1="$(cat "$ROOT/setup/lib/mcp.ps1")"
COMMON_PS1="$(cat "$ROOT/setup/lib/exakit-common.ps1")"
lacks "no MCP setup summary panel"  'Start-ExakitPanel "MCP setup summary"' "$MCP_PS1"
lacks "no MCP is ready panel"       'Start-ExakitPanel "MCP is ready"'      "$MCP_PS1"
has "the clients are named there too" 'Ok "MCP configured for $clientList"' "$MCP_PS1"
has "the prompt panel is conditional" 'if ($copied) {'                     "$MCP_PS1"
has "a short closing panel exists"  'function Show-ExakitConnectionSummary' "$COMMON_PS1"
has "the full panel is still there" 'function Show-ExakitConnectionPanel'   "$COMMON_PS1"
lacks "no per-skill screen line"    'Ok "Installed skill: $name"'           "$COMMON_PS1"
has "the count is announced there"  'Ok "Installed $installed $skillUnit'   "$COMMON_PS1"

printf '\n== every menu row is one plain word or phrase ==\n'

EXAPUMP_SH="$(cat "$ROOT/setup/lib/exapump.sh")"
EXAPUMP_PS1="$(cat "$ROOT/setup/lib/exapump.ps1")"
MCP_PS1_ALL="$(cat "$ROOT/setup/lib/mcp.ps1")"

# The parent of a checkbox tree IS the select-all, so it says so on both sides.
has "the add-on group row"  '_mm_menu_labels=("Select All")'                    "$COMMON"
has "the dataset group row" '_dls_labels+=("Select All")'                       "$EXAPUMP_SH"
has "...and on Windows"     '[void]$menuLabels.Add("Select All")'               "$COMMON_PS1"
has "...for datasets too"   '[void]$labels.Add("Select All"); [void]$ids.Add("__group__")' "$EXAPUMP_PS1"

# One word for the opt-out row, in every menu that has one. Five call sites on
# the shell side, four on the PowerShell side.
lacks "no 'Available add-ons'"        "Available add-ons"                   "$COMMON"
lacks "no 'Cancel (install nothing)'" "Cancel (install nothing)"            "$COMMON$COMMON_PS1"
lacks "no 'Cancel (load nothing)'"    "Cancel (load nothing)"               "$EXAPUMP_SH$EXAPUMP_PS1"
lacks "no 'Skip for now (no dataset loading)'" "Skip for now (no dataset loading)" "$COMMON$EXAPUMP_PS1"
lacks "no 'Skip for now (no MCP client changes)'" "Skip for now (no MCP client changes)" "$COMMON$MCP_PS1_ALL"
has "the MCP menu opts out with Skip"  '_menu_labels+=("Skip")'             "$COMMON"
has "...and its twin"                  '[void]$menuLabels.Add("Skip")'      "$MCP_PS1_ALL"
has "the bulk-format menu too"         '_bsl_labels+=("Skip")'             "$EXAPUMP_SH"

printf '\n== the closing offer is two words and a question ==\n'

has "the pitch"            'info "Supercharge starterkit with exasol add-ons"' "$COMMON"
has "...on Windows too"    'Info "Supercharge starterkit with exasol add-ons"' "$COMMON_PS1"
lacks "no three-line pitch" "editor integration, extra data formats"          "$COMMON$COMMON_PS1"
has "the question"         'ui_checkbox_menu "Explore ?" "1"'                 "$COMMON"
has "...on Windows too"    '-Title "Explore ?"'                               "$COMMON_PS1"
lacks "no 'Browse it now?'" "Browse it now?"                                  "$COMMON$COMMON_PS1"
lacks "no 'open the marketplace' row" "Yes, open the marketplace"             "$COMMON$COMMON_PS1"
lacks "no 'maybe later' row"          "No, maybe later"                       "$COMMON$COMMON_PS1"
has "just Yes and No"      '-Options @("Yes", "No")'                          "$COMMON_PS1"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
