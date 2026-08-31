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
# connection_panel batches its six reads through manifest_get_many (one python
# process instead of six), so stubbing manifest_get alone leaves it empty.
# One line PER KEY, empty ones included: the panel reads the answers
# positionally, so a missing key that emits nothing would shift every row after
# it onto the wrong variable.
manifest_get_many() {
    for _k in "$@"; do printf '%s\n' "$(manifest_get "$_k")"; done
}
exakit_marketplace_addon_installed() { return 1; }

printf '\n== MCP setup: what to do, not what was written where ==\n'

cat > "$WORK/result.json" <<'JSONEOF'
{"status":"success_with_warnings",
 "selected_clients":["claude_desktop","claude_code","codex","vscode_copilot"],
 "artifacts":[{"client":"claude_desktop","path":"/h/Library/Application Support/Claude/claude_desktop_config.json"},
              {"client":"codex","path":"/h/.codex/config.toml"}],
 "findings":[{"code":"plaintext_credential_reference","severity":"warning","message":"The database credential is stored as plaintext in the client configuration file."},
             {"code":"some_other_finding","severity":"warning","message":"A finding the reader can actually act on."}],
 "next_actions":[{"kind":"restart_client","message":"Restart Claude to load the updated MCP configuration."},
                 {"kind":"restart_client","message":"Start a new Claude Code session (or run /mcp in an existing one) to load the updated MCP configuration."},
                 {"kind":"repair_something","message":"An action that is not a restart."}]}
JSONEOF
# The fixture carries `code` and `kind` because the RENDERER filters on them.
# Without those fields it exercised neither filter, so the suppression could
# have been deleted outright and this block would still have passed.
: > "$EXAKIT_LOG_FILE"
SUMMARY="$(exakit_print_mcp_setup_summary "$WORK/result.json" 2>&1)"
SUMMARY_LOG="$(cat "$EXAKIT_LOG_FILE")"

has "the clients are named"        "MCP configured for Claude, Claude Code (CLI), Codex, GitHub Copilot" "$SUMMARY"
# The plaintext credential is a standing property of how every client stores a
# credential -- and it is the READ-ONLY user's password. Warning about it on
# every install taught people to read past warnings.
lacks "the credential warning is gone" "stored as plaintext"  "$SUMMARY"
has "...but the log still answers for it" "stored as plaintext" "$SUMMARY_LOG"
has "a finding that IS actionable still shows" "act on" "$SUMMARY"
# One "restart your client" line per configured client is the same action said
# four times; the skills step closes the install with the generic form.
lacks "no per-client restart lines"  "Restart Claude to load" "$SUMMARY"
lacks "...nor the /mcp one"          "run /mcp in an existing one" "$SUMMARY"
has "...and the log keeps those too" "run /mcp in an existing one" "$SUMMARY_LOG"
has "an action that is not a restart survives" "not a restart" "$SUMMARY"
# Already in the closing panel as "MCP configs: ... (list: exakit mcp-status)".
lacks "no duplicate mcp-status pointer" "exakit mcp-status" "$SUMMARY"

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
UI_SH_TEXT="$(cat "$ROOT/setup/lib/ui.sh")"
UI_PS1_TEXT="$(cat "$ROOT/setup/lib/ui.ps1")"
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
# The add-on and data-load screens are live TABLES now; each writes its parent
# row into the table's own state file rather than into a label array.
has "the add-on group row"  "printf 'group|Select All|1|idle" "$COMMON"
has "the dataset group row" "printf 'group|Select All|1|idle" "$EXAPUMP_SH"
# Windows draws the same live table now - for all three selections, not only
# datasets - so every parent row is a table row rather than an entry in a label
# array.
has "...and on Windows"     'Add-ExakitTableRow -Kind "group" -Label "Select All" -Table $script:ExakitAddonTable' "$COMMON_PS1"
has "...for datasets too"   'Add-ExakitTableRow -Kind "group" -Label "Select All"' "$EXAPUMP_PS1"
has "...and for AI clients" 'Add-ExakitTableRow -Kind "group" -Label "Select All" -Table $script:McpTable' "$MCP_PS1_ALL"

# One word for the opt-out row, in every menu that has one. Five call sites on
# the shell side, four on the PowerShell side.
lacks "no 'Available add-ons'"        "Available add-ons"                   "$COMMON"
lacks "no 'Cancel (install nothing)'" "Cancel (install nothing)"            "$COMMON$COMMON_PS1"
lacks "no 'Cancel (load nothing)'"    "Cancel (load nothing)"               "$EXAPUMP_SH$EXAPUMP_PS1"
lacks "no 'Skip for now (no dataset loading)'" "Skip for now (no dataset loading)" "$COMMON$EXAPUMP_PS1"
lacks "no 'Skip for now (no MCP client changes)'" "Skip for now (no MCP client changes)" "$COMMON$MCP_PS1_ALL"
# The MCP client menu is a live table on both sides now, so its opt-out is the
# table's own last row rather than an entry in a label array. Still one word.
has "the MCP menu opts out with Skip"  'printf '"'"'plain|Skip|0|idle|||||| \n'"'"' >> "$EXAKIT_MCP_TABLE_STATE"' "$COMMON"
has "...and its twin"                  'Add-ExakitTableRow -Kind "plain" -Label "Skip" -Table $script:McpTable' "$MCP_PS1_ALL"
has "the bulk-format menu too"         '_bsl_labels+=("Skip")'             "$EXAPUMP_SH"

printf '\n== the closing offer is two words and a question ==\n'

# A HEADING, not an action: the dim bullet marked the offer as one more thing
# being done TO the machine, and sat level with the question it introduces.
has "the pitch"            'heading "Supercharge Exasol with add-ons"'          "$COMMON"
has "...on Windows too"    'Write-ExakitHeading "Supercharge Exasol with add-ons"' "$COMMON_PS1"
# Two spaces, the same column as begin_step's own arrow: at four it sat in the
# action gutter, level with the question it introduces.
has "the heading is at the STEP indent" "printf '  %s%s%s %s" "$COMMON"
lacks "no three-line pitch" "editor integration, extra data formats"          "$COMMON$COMMON_PS1"
# The bare "Explore ?" never said what it was asking about.
has "the question"         'ui_checkbox_menu "Explore marketplace ?" "1"'      "$COMMON"
has "...on Windows too"    '-Title "Explore marketplace ?"'                    "$COMMON_PS1"
lacks "no 'Browse it now?'" "Browse it now?"                                  "$COMMON$COMMON_PS1"
lacks "no 'open the marketplace' row" "Yes, open the marketplace"             "$COMMON$COMMON_PS1"
lacks "no 'maybe later' row"          "No, maybe later"                       "$COMMON$COMMON_PS1"
has "just Yes and No"      '-Options @("Yes", "No")'                          "$COMMON_PS1"

printf '\n== the quiet gate silences the screen, never the log ==\n'

: > "$EXAKIT_LOG_FILE"
QUIET_OUT="$( (EXAKIT_QUIET_DETAIL=1; info "a step nobody has to read"; ok "a tick nobody has to read") 2>/dev/null )"
lacks "info is off screen" "a step nobody has to read" "$QUIET_OUT"
lacks "ok is off screen"   "a tick nobody has to read" "$QUIET_OUT"
# A job that says nothing while it works must still say something when it fails.
QUIET_ERR="$( (EXAKIT_QUIET_DETAIL=1; warn "something actually went wrong"; error "and something worse") 2>&1 )"
has "warn still speaks"  "something actually went wrong" "$QUIET_ERR"
has "error still speaks" "and something worse"           "$QUIET_ERR"
LOGGED="$(cat "$EXAKIT_LOG_FILE")"
has "info reached the log" "a step nobody has to read" "$LOGGED"
has "ok reached the log"   "a tick nobody has to read" "$LOGGED"
# Unset, everything prints as it always did.
LOUD="$(info "back to normal")"
has "off, info prints again" "back to normal" "$LOUD"

printf '\n== the seam between the install and the offer ==\n'

RULE="$(COLUMNS=40 ui_rule)"
# A command substitution eats the trailing newline, so the blank line BELOW is
# asserted from the function's own bytes, not from the capture.
check "the rule has air above it" "" "$(printf '%s\n' "$RULE" | sed -n 1p)"
check "one divider line"          "1" "$(printf '%s\n' "$RULE" | grep -c "$UI_HR")"
has "and air below it in the source" "'\\n  %s%s%s\\n\\n'" "$(cat "$ROOT/setup/lib/ui.sh")"
has "and it draws a divider" "$UI_HR$UI_HR$UI_HR" "$RULE"
has "the offer is behind the seam" 'ui_rule
    # A heading, not an action: what follows the rule is a separate offer, and
    # the dim bullet marked it as one more thing being done TO the machine.
    heading "Supercharge Exasol with add-ons"' "$COMMON"
has "...on Windows too" 'Write-ExakitRule
    # A heading, not an action: what follows the rule is a separate offer, and
    # the dim bullet marked it as one more thing being done TO the machine.
    Write-ExakitHeading "Supercharge Exasol with add-ons"' "$COMMON_PS1"
has "ui.sh has the rule"  "ui_rule()"                  "$(cat "$ROOT/setup/lib/ui.sh")"
has "ui.ps1 has its twin" "function Write-ExakitRule"  "$(cat "$ROOT/setup/lib/ui.ps1")"

printf '\n== an add-on install is two lines and its own panel ==\n'

# The add-on install writes into the shared progress state, which the animator
# draws — rather than baking a bar into the spinner's label, which could only
# change when a phase did.
ADDON_STATE="$WORK/addon-progress"
_exakit_addon_progress "$ADDON_STATE" dash-server 65 90 8 "validating"
check "the stage it is at"        "65" "$(cut -d'|' -f1 "$ADDON_STATE")"
check "and where that stage ends" "90" "$(cut -d'|' -f2 "$ADDON_STATE")"
check "how long it usually takes" "8"  "$(cut -d'|' -f3 "$ADDON_STATE")"
has "the add-on is named"  "dash-server" "$(cut -d'|' -f5 "$ADDON_STATE")"
has "the phase"            "validating"  "$(cut -d'|' -f5 "$ADDON_STATE")"

# One add-on, stubbed end to end: chatter, a usage panel, autostart and a start
# hook — the same shape every real add-on module has.
dash_server_install() {
    info "Installing dash-server 0.1.0"
    ok "dash-server installed: /somewhere/dash-server-venv"
    ok "dash-server launcher written: /somewhere/bin/dash-server"
    return 0
}
dash_server_validate() {
    info "Validating dash-server (MCP control plane on port 5100)"
    ok "dash-server control plane answers on port 5100"
    ui_panel_begin "dash-server"
    ui_panel_line "Start it   dash-server"
    ui_panel_end
    return 0
}
dash_server_autostart_command() { printf 'dash-server\n'; }
dash_server_start() { return 0; }
_exakit_autostart_register() { ok "dash-server: starts at login (~/Library/LaunchAgents/x.plist)"; return 0; }
manifest_get() { [ "$1" = "autostart.enabled" ] && printf 'true\n'; return 0; }

: > "$EXAKIT_LOG_FILE"
EXAKIT_ACTIVE_LABEL="Step 6/6  exakit helper"
ADDON="$(_exakit_marketplace_install_one dash-server 2>&1)"
check "the install succeeds" "0" "$?"

lacks "no version line"      "Installing dash-server 0.1.0"  "$ADDON"
lacks "no venv path"         "dash-server-venv"              "$ADDON"
lacks "no launcher line"     "launcher written"              "$ADDON"
lacks "no validating line"   "Validating dash-server"        "$ADDON"
lacks "no control-plane line" "control plane answers"        "$ADDON"
lacks "no autostart line"    "starts at login"               "$ADDON"
# The add-on's OWN panel is the payoff — how to use the thing just installed —
# and it is the one part that stays on screen.
has "its usage panel stays"  "Start it   dash-server"        "$ADDON"

LOGGED="$(cat "$EXAKIT_LOG_FILE")"
has "the version is in the log"   "Installing dash-server 0.1.0" "$LOGGED"
has "the venv is in the log"      "dash-server-venv"             "$LOGGED"
has "the autostart is in the log" "starts at login"              "$LOGGED"

check "the label is handed back" "Step 6/6  exakit helper" "$EXAKIT_ACTIVE_LABEL"
check "and so is the quiet flag" "0" "${EXAKIT_QUIET_DETAIL:-0}"

# A failing install must hand both back too, or every later line goes silent.
dash_server_install() { return 1; }
_exakit_marketplace_install_one dash-server >/dev/null 2>&1
check "a failed install restores the label" "Step 6/6  exakit helper" "$EXAKIT_ACTIVE_LABEL"
check "...and the quiet flag" "0" "${EXAKIT_QUIET_DETAIL:-0}"
LOUD="$(info "still speaking")"
has "the screen is not left silent" "still speaking" "$LOUD"

printf '\n== the result line does not repeat the panel ==\n'

# The outcome is the id plus, at most, the add-on's own one-line summary.
has "one line for the outcome" 'ok "$_mp_id installed${_mp_note:+' "$COMMON"
lacks "no doubled update hint" 'installed — it now updates with: exakit update (or exakit update' "$COMMON"
has "...on Windows too"        'Ok "$id installed - $note"' "$COMMON_PS1"

printf '\n== the PowerShell twin gates at the same sink ==\n'

has "Info is gated"        'if (-not $script:ExakitQuietDetail) {' "$COMMON_PS1"
has "the flag is declared" '$script:ExakitQuietDetail = $false'    "$COMMON_PS1"
has "the progress helper"  'function Set-ExakitAddonProgress'      "$COMMON_PS1"
has "the apply loop starts the bar" 'Start-ExakitProgress -Pct 0 -Ceiling 65 -Secs 40' "$COMMON_PS1"
has "...and reports each stage"      'Set-ExakitAddonProgress -Id $id -Pct 65 -Ceiling 90' "$COMMON_PS1"
has "...and stops it"                'Stop-ExakitProgress' "$COMMON_PS1"
has "and hands it back"      '$script:ExakitQuietDetail = $prevQuiet' "$COMMON_PS1"

printf '\n== exakit help lists each command once ==\n'

# NO_COLOR so the rows can be matched without stripping escapes (BSD sed has no
# \x1b). The screen is rendered for real, not read out of the catalog: the
# catalog is ALLOWED to name a command in two groups - what must not happen is
# printing it twice.
HELP_OUT="$(NO_COLOR=1 EXAKIT_NO_UPDATE_NOTICE=1 /bin/bash "$ROOT/setup/exakit" help 2>&1)"
HELP_ROWS="$(printf '%s\n' "$HELP_OUT" | grep -oE '^    exakit [a-z-]+' || true)"
check "no command is listed twice" "" "$(printf '%s\n' "$HELP_ROWS" | sort | uniq -d)"
# The catalog still names mcp-setup in two groups, so this proves the RENDERER
# dedupes rather than the catalog having been edited to hide the overlap.
check "the catalog still lists it twice" "2" \
    "$(grep -c '^        "mcp-setup",' "$ROOT/setup/help/exakit.json")"
has "the first group keeps it" "exakit mcp-setup" "$HELP_OUT"
check "and only once" "1" "$(printf '%s\n' "$HELP_ROWS" | grep -c 'exakit mcp-setup')"
# A group emptied by the dedupe must not leave its heading behind.
check "no heading with nothing under it" "" "$(printf '%s\n' "$HELP_OUT" | awk '
    /^  [A-Z]/ { if (heading != "" && rows == 0) print heading; heading = $0; rows = 0; next }
    /^    exakit / { rows++ }
    END { if (heading != "" && rows == 0) print heading }')"
has "the --all view dedupes too" "if not entry or name in seen" "$(cat "$ROOT/setup/lib/help.sh")"
has "and so does its twin"       'if (-not $entry -or $seen[$name]) { continue }' "$(cat "$ROOT/setup/lib/help.ps1")"

printf '\n== a reference card is not part of an add-on install ==\n'

# The add-on modules are sourced here, not stubbed: what is under test is that
# each one's real panel steps aside under the quiet flag.
# shellcheck source=/dev/null
. "$ROOT/setup/lib/dash-server.sh"
# shellcheck source=/dev/null
. "$ROOT/setup/lib/json-tables.sh"
# shellcheck source=/dev/null
. "$ROOT/setup/lib/exasol-vscode.sh"

: > "$EXAKIT_LOG_FILE"
PANEL_QUIET="$(EXAKIT_QUIET_DETAIL=1 _dash_server_print_usage 2>&1)"
check "the dash-server panel steps aside" "" "$PANEL_QUIET"
has "...leaving its address in the log" "dash-server: http://127.0.0.1:" "$(cat "$EXAKIT_LOG_FILE")"
PANEL_LOUD="$(_dash_server_print_usage 2>&1)"
has "and it still prints outside an install" "MCP endpoint" "$PANEL_LOUD"

: > "$EXAKIT_LOG_FILE"
JT_QUIET="$(EXAKIT_QUIET_DETAIL=1 _json_tables_print_usage 2>&1)"
check "the JSON Tables panel steps aside" "" "$JT_QUIET"
has "...leaving its command in the log" "exasol-json-tables ingest" "$(cat "$EXAKIT_LOG_FILE")"
has "and it still prints outside an install" "Ingest JSON" "$(_json_tables_print_usage 2>&1)"

# The VS Code panel lives inside its validate function rather than a printer of
# its own, so the gate is asserted at the source.
has "the VS Code panel is gated too" \
    'if [ "${EXAKIT_QUIET_DETAIL:-0}" = 1 ]; then
        _exakit_log_file "DATA  exasol-vscode:' "$(cat "$ROOT/setup/lib/exasol-vscode.sh")"

printf '\n== ...but its one useful fact rides out on the result line ==\n'

EXAKIT_DASH_SERVER_PORT=5100
has "dash-server names its address"  "http://127.0.0.1:5100" "$(dash_server_summary)"
# Each summary must fit the finished cell, which has room for 33 -- that is
# 44 minus the tick, the padded elapsed and two spaces, and the PLAIN palette's
# tick is the four-character "[ok]", not a one-character glyph. Longer than that
# and the cell truncates with an ellipsis, which is what these used to do.
has "json-tables names its command"  "exasol-json-tables" "$(json_tables_summary)"
has "exasol-vscode names where to look" "sidebar" "$(exasol_vscode_summary)"
for _sum in "$(json_tables_summary)" "$(exasol_vscode_summary)" "$(dash_server_summary)"; do
    check "\"$_sum\" fits the finished cell" "yes" \
        "$([ "${#_sum}" -le 33 ] && echo yes || echo "no: ${#_sum} chars")"
done

# The hook is OPTIONAL and resolved generically: no add-on id appears in the
# apply loop, so a new add-on gets this by defining the function and nothing in
# common.sh has to learn its name.
has "the hook is resolved by name"   '_mp_summary_fn="$(_exakit_addon_fn "$_mp_id" summary)"' "$COMMON"
has "and only used when it exists"   'command -v "$_mp_summary_fn" >/dev/null 2>&1' "$COMMON"
has "the result line carries it"     'ok "$_mp_id installed${_mp_note:+ — $_mp_note}"' "$COMMON"
# "Browse again: exakit marketplace · how to use one: exakit help <add-on>"
# stood here. The table above has just said what was installed and what each
# gives you, and the closing support line already names `exakit help`.
lacks "no browse-again pointer"      "how to use one: exakit help <add-on>" "$COMMON"
lacks "...nor on Windows"            "how to use one: exakit help <add-on>" "$COMMON_PS1"

printf '\n== the PowerShell twin does the same ==\n'

DS_PS1="$(cat "$ROOT/setup/lib/dash-server.ps1")"
JT_PS1="$(cat "$ROOT/setup/lib/json-tables.ps1")"
VS_PS1="$(cat "$ROOT/setup/lib/exasol-vscode.ps1")"
has "dash-server gates its panel"   'if ($script:ExakitQuietDetail) {' "$DS_PS1"
has "json-tables gates its panel"   'if ($script:ExakitQuietDetail) {' "$JT_PS1"
has "exasol-vscode gates its panel" 'if ($script:ExakitQuietDetail) {' "$VS_PS1"
has "dash-server has a summary"     'function Get-DashServerSummary'     "$DS_PS1"
has "json-tables has a summary"     'function Get-JsonTablesSummary'     "$JT_PS1"
has "exasol-vscode has a summary"   'function Get-ExasolVscodeSummary'   "$VS_PS1"
check "all three are registered" "3" "$(printf '%s\n' "$COMMON_PS1" | grep -cE 'SummaryFn *= *"')"
has "the apply loop reads the hook" '$addon.PSObject.Properties["SummaryFn"]' "$COMMON_PS1"
has "and only when it resolves"     'Get-Command $addon.SummaryFn -ErrorAction SilentlyContinue' "$COMMON_PS1"

printf '\n== a folded description lines up under the one above it ==\n'

# The marketplace table prints its rows with '%-14s %-14s %s' — thirty columns
# of prefix — and folded description lines have to start at that same column.
# They were indented by a hand-counted 32, so every continuation sat two columns
# to the right of the line above it.
# The description is no longer folded into a panel cell by the marketplace: it
# is a COLUMN of the one table, and the table wraps it at draw time. What has to
# hold now is that the wrap never truncates, never forks, and is bounded.
has "the table wraps, in full"      "_ui_wrap() {"                     "$UI_SH_TEXT"
lacks "and never truncates a description" 'UI_TABLE_COL3_W - 1 ))}…'   "$UI_SH_TEXT"
has "the width is fixed"            'UI_TABLE_COL3_FIXED="${UI_TABLE_COL3_FIXED:-44}"' "$UI_SH_TEXT"
has "...and bounded when it grows"  'UI_TABLE_COL3_MAX="${UI_TABLE_COL3_MAX:-90}"'     "$UI_SH_TEXT"
lacks "the wrap forks nothing"      'exakit_about_wrap' "$(sed -n "/^_ui_wrap()/,/^}/p" "$ROOT/setup/lib/ui.sh")"
has "the twin wraps too"            "function Split-ExakitWrap"        "$UI_PS1_TEXT"
# exakit_about_wrap itself stays -- it has its own tests in marketplace.sh and
# is the renderer `exakit help` uses; it simply has no marketplace caller now.
has "the helper still exists"       "exakit_about_wrap() {"            "$COMMON"

printf '\n== every version is spelled the same way ==\n'

# json-tables takes its version from a git tag and reported "v0.2" — one row in
# two tables wearing a prefix none of its neighbours wore.
check "a tag prefix is dropped"        "0.2"   "$(exakit_version_plain v0.2)"
check "so is a longer one"             "1.7.0" "$(exakit_version_plain v1.7.0)"
check "a bare version is untouched"    "0.1.0" "$(exakit_version_plain 0.1.0)"
# Only a "v" followed by a DIGIT is a tag prefix. A version that legitimately
# starts with a letter keeps it.
check "a codename keeps its letter"    "vNext" "$(exakit_version_plain vNext)"
check "and so does a word"             "unknown" "$(exakit_version_plain unknown)"
check "nothing in, nothing out"        ""      "$(exakit_version_plain '')"

# Applied where versions are DISPLAYED, never where they are compared or stored.
has "the version table spells it"   'exakit_version_plain "$(exakit_version_installed_cell' "$COMMON"
has "...both columns"               'exakit_version_plain "$(exakit_component_available' "$COMMON"
# The marketplace no longer formats rows of its own: the version is a COLUMN of
# the one table, filled by the row builder.
has "the marketplace table too"     'exakit_version_plain "$(exakit_component_available "$_atb_id"' "$COMMON"
has "...and for a covered add-on"   'Installed ($(exakit_version_plain "${_mm_cv:-?}"))' "$COMMON"
has "the twin has the helper"       'function Get-ExakitVersionPlain'           "$COMMON_PS1"
has "...and uses it in its table"   'Get-ExakitVersionPlain $advertised'        "$COMMON_PS1"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
