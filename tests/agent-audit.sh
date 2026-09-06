#!/usr/bin/env bash
# agent-audit.sh — the findings of the 2026-09-03/04 agent-operability audits (round 1: twelve, round 2: ten, round 3: seven),
# each pinned so it cannot come back. The audit drove the kit the way an agent
# with no TTY does: unattended install and uninstall, the sql path, the state
# queries, deliberate breakage. Every check here is the shape of one of those
# findings. Sandboxed kit home, no network, no database.
#
#   bash tests/agent-audit.sh

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
has() { case "$3" in *"$2"*) check "$1" "present" "present" ;; *) check "$1" "present" "MISSING" ;; esac; }
lacks() { case "$3" in *"$2"*) check "$1" "absent" "PRESENT" ;; *) check "$1" "absent" "absent" ;; esac; }

if ! command -v python3 >/dev/null 2>&1; then echo "SKIP: python3 is needed"; exit 0; fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
EXAKIT_HOME="$WORK/home"
EXAKIT_BIN_DIR="$WORK/bin"
EXAKIT_MANIFEST="$EXAKIT_HOME/manifest.json"
HOME="$WORK/fake-home"
export EXAKIT_HOME EXAKIT_BIN_DIR EXAKIT_MANIFEST HOME
export NO_COLOR=1 EXAKIT_NO_FANCY=1 EXAKIT_NO_UPDATE_NOTICE=1
export EXAKIT_VERSIONS_URL="https://offline.invalid/versions.json"
mkdir -p "$EXAKIT_HOME/cache" "$EXAKIT_BIN_DIR" "$HOME"
# No real kit may answer for the sandbox: the machine running this may have a
# live database on 8563 and an `exasol` launcher on PATH, and the runtime probe
# would read them as this sandbox's. Scrub the user's bin dir from PATH.
PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '/\.local/bin$' | tr '\n' ':' | sed 's/:$//')"
export PATH
cp "$ROOT/versions.json" "$EXAKIT_HOME/cache/versions.json"
EXAKIT_VERSIONS_CACHE="$EXAKIT_HOME/cache/versions.json"; export EXAKIT_VERSIONS_CACHE
# A minimal install record: a kit, no runtime, nothing running.
cat > "$EXAKIT_MANIFEST" <<JSON
{"manifest_version": 1, "kit_level": 1, "installed_at": "2026-09-03T10:00:00Z",
 "kit": {"version": "0.2.1", "source": "example/kit@main"},
 "runtime": {"type": "personal", "dsn": "127.0.0.1:8563"},
 "components": {}, "steps_completed": ["launcher", "runtime"]}
JSON
CLI="$ROOT/setup/exakit"
. "$ROOT/setup/lib/common.sh"

echo "1. EXAKIT_MCP_CLIENTS=all means the clients detected on this machine:"
_all="$( (
    exakit_mcp_discover_status() { printf 'claude_desktop missing\nclaude_code pending\ncursor missing\ncodex connected\nvscode_copilot missing\ngemini_cli missing\nopencode missing\ncontinue missing\n'; }
    exakit_mcp_detected_clients ) )"
check "detected set, canonical order" "claude_code,codex" "$_all"
check "the parser itself still knows every client (doctor and uninstall use it)" \
    "claude_desktop,claude_code,cursor,codex,vscode_copilot,gemini_cli,opencode,continue" "$(exakit_parse_mcp_client_selection all)"
has "the env path narrows all to the detected set" 'all|ALL|All)' "$(sed -n '/^exakit_mcp_setup()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "...and says which were skipped" "not installed here, skipped" "$(cat "$ROOT/setup/lib/common.sh")"
has "the twin narrows it too" 'Get-McpClientStates' "$(sed -n '/EXAKIT_MCP_CLIENTS -match .*all/,/Configuring MCP clients from EXAKIT_MCP_CLIENTS/p' "$ROOT/setup/lib/mcp.ps1")"
has "AGENTS.md defines all" "every client detected on this machine" "$(cat "$ROOT/AGENTS.md")"

echo "2. the exakit command exists before step 1, and status says installing:"
for _f in setup/setup-macos.sh setup/setup-wsl.sh; do
    _early="$(grep -n 'exakit_install_helper_early\|begin_step launcher' "$ROOT/$_f" | head -2 | cut -d: -f2 | tr '\n' ' ')"
    has "$_f installs the helper before the launcher step" "exakit_install_helper_early" "$(printf '%s' "$_early" | awk '{print $1}')"
done
has "the Windows installer writes the shim early too" 'Set-ExakitCmdShim -PsTarget $earlyPs1' "$(cat "$ROOT/setup/setup-windows-docker.ps1")"
mkdir -p "$WORK/kitsrc"; printf '#!/bin/sh\necho stub\n' > "$WORK/kitsrc/exakit"
( exakit_install_helper_early "$WORK/kitsrc" >/dev/null 2>&1 )
check "the helper is installed executable" "yes" "$( [ -x "$EXAKIT_BIN_DIR/exakit" ] && echo yes || echo no )"
# A live install: the step marker plus a lock naming a LIVE pid.
manifest_set install.current_step runtime >/dev/null 2>&1
printf '%s' "$$" > "$EXAKIT_HOME/.install.lock"
_st="$(bash "$CLI" status --json 2>/dev/null)"; _rc="$(bash "$CLI" status --json >/dev/null 2>&1; echo $?)"
check "status --json says installing" "installing" "$(printf '%s' "$_st" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
check "...with the step" "runtime" "$(printf '%s' "$_st" | python3 -c 'import json,sys; print(json.load(sys.stdin)["install_step"])')"
has "...and a remedy that says to wait" "installer is still running" "$_st"
check "...exit 3, never 0, while installing" "3" "$_rc"
has "the human screen says so too" "in progress" "$(bash "$CLI" status 2>&1)"
# A dead pid is not an install in progress (a crashed run must not read as one).
printf '%s' "999999" > "$EXAKIT_HOME/.install.lock"
check "a stale lock is not installing" "false" "$(bash "$CLI" status --json 2>/dev/null | python3 -c 'import json,sys; print(str(json.load(sys.stdin)["installing"]).lower())')"
rm -f "$EXAKIT_HOME/.install.lock"; manifest_del install.current_step >/dev/null 2>&1
has "begin_step records the step" 'manifest_set install.current_step' "$(sed -n '/^begin_step()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "exakit_finish clears it" 'manifest_del install.current_step' "$(sed -n '/^exakit_finish()/,/^}/p' "$ROOT/setup/lib/common.sh")"

echo "3. a busy port is a conflict, not a running database:"
_conf="$( (
    . "$ROOT/setup/lib/detect.sh" 2>/dev/null
    . "$ROOT/setup/lib/runtime-personal.sh"
    mkdir -p "$WORK/stub-exasol"; EXAKIT_PERSONAL_BIN="$WORK/stub-exasol/exasol"; printf '#!/bin/sh\nexit 0\n' > "$EXAKIT_PERSONAL_BIN"; chmod +x "$EXAKIT_PERSONAL_BIN"
    personal_deployment_exists() { return 0; }
    port_in_use() { return 0; }
    personal_db_answers() { return 1; }
    personal_status
    personal_deployment_running && echo running || echo not-running ) 2>&1 | tr '\n' ' ')"
check "status is conflict, and the start probe says not running" "conflict not-running " "$_conf"
has "cmd_start refuses on conflict with the remedy" "held by another process" "$(sed -n '/^cmd_start()/,/^}/p' "$CLI")"
has "status --json names the conflict remedy" "another process is listening on the database port" "$(cat "$CLI")"

echo "4. info --json carries the contract keys:"
_info="$(bash "$CLI" info --json 2>/dev/null)"; _irc="$(bash "$CLI" info --json >/dev/null 2>&1; echo $?)"
check "installed/status/remedy present" "True database not running exakit start" \
    "$(printf '%s' "$_info" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["installed"], d["status"], d["remedy"])')"
check "the record is still the manifest" "0.2.1" "$(printf '%s' "$_info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["kit"]["version"])')"
check "exit 3 with the database down" "3" "$_irc"

echo "5. unattended data-load of a loaded dataset is a no-op, exit 0:"
has "the named-dataset branch exists without --force" 'elif [ -n "${EXAKIT_DATASETS:-}" ] && [ -z "${EXAKIT_DATA_FILE:-}" ]; then' "$(cat "$CLI")"
has "...and says already loaded" "is already loaded — nothing to do" "$(cat "$CLI")"
has "the twin has the branch" 'elseif ($env:EXAKIT_DATASETS -and -not $env:EXAKIT_DATA_FILE)' "$(cat "$ROOT/setup/exakit.ps1")"

echo "6. uninstall keeps the client-config snapshots and never deletes VS Code's file:"
has "snapshots are moved beside the kit home before it goes" '-backups-$(date' "$(sed -n '/^exakit_uninstall_run()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "...and the twin does the same" 'backups-$(Get-Date' "$(cat "$ROOT/setup/exakit.ps1")"
has "the VS Code adapter never removes the file" "remove_file=False" "$(sed -n '/def render_removal/,/def validate_render/p' "$ROOT/mcp/adapters/vscode_copilot.py")"

echo "7. sql remedies come first, on stdout, without the generic hint:"
has "the remedy is data" "exakit_db_error_remedy()" "$(cat "$ROOT/setup/lib/common.sh")"
check "FETCH FIRST names LIMIT" "yes" "$(exakit_db_error_remedy 'syntax error, unexpected FETCH_' | grep -q 'LIMIT' && echo yes || echo no)"
_sqlbody="$(sed -n '/^cmd_sql()/,/^}/p' "$CLI")"
has "cmd_sql prints the remedy before the output" '_sql_remedy="$(exakit_db_error_remedy' "$_sqlbody"
has "...and drops exapump's generic hint" "grep -v '^[[:space:]]*Hint: '" "$_sqlbody"
lacks "...and no longer warns to stderr after the output" 'exakit_explain_db_error "$_sql_out"' "$_sqlbody"

echo "8. doctor derives client state from health:"
has "the service builds details.clients" 'details["clients"] = client_states' "$(cat "$ROOT/mcp/service.py")"
has "...with the five states" "configured_client_missing" "$(cat "$ROOT/mcp/service.py")"
has "the shell renders that map for doctor" 'if doc.get("operation") == "doctor" and client_states:' "$(cat "$ROOT/setup/lib/common.sh")"
has "the twin renders it too" 'configured_client_missing = "configured, not installed"' "$(cat "$ROOT/setup/lib/mcp.ps1")"
has "remedy comes from a warning or error only" 'RANK = {"critical": 0, "error": 1, "warning": 2}' "$(cat "$ROOT/setup/lib/common.sh")"

echo "9. sql reruns a saved file, reads stdin, answers --help:"
printf -- '-- saved by the skill\n-- second comment\nDROP TABLE T;\n' > "$WORK/saved.sql"
has "--file is read and its comments dropped (the gate sees DROP)" "not a read statement" "$(bash "$CLI" sql --file "$WORK/saved.sql" 2>&1)"
has "stdin is read too" "not a read statement" "$(bash "$CLI" sql < "$WORK/saved.sql" 2>&1)"
has "a missing file is a clear rejection" "No such file" "$(bash "$CLI" sql --file "$WORK/nope.sql" 2>&1)"
check "--help renders the page, exit 0" "0" "$(bash "$CLI" sql --help >/dev/null 2>&1; echo $?)"
has "...and it is the sql page" "exakit sql" "$(bash "$CLI" sql --help 2>&1)"
check "an unknown option still exits 2" "2" "$(bash "$CLI" sql --bogus 'SELECT 1' >/dev/null 2>&1; echo $?)"

echo "10. a typo is a typo, not a write:"
_typo="$(bash "$CLI" sql 'SELCT 1' 2>&1)"
has "SELCT is reported as unrecognised" "is not an SQL statement this command recognises" "$_typo"
lacks "...and is not pointed at --write as a write" "not a read statement" "$_typo"
has "a real write is still a write" "not a read statement" "$(bash "$CLI" sql 'DROP TABLE T' 2>&1)"
check "both exit 2" "2 2" "$(bash "$CLI" sql 'SELCT 1' >/dev/null 2>&1; printf '%s ' $?; bash "$CLI" sql 'DROP TABLE T' >/dev/null 2>&1; echo $?)"

echo "11. --json on version and mcp-status, unknown options rejected:"
_v="$(bash "$CLI" version --json 2>/dev/null)"
check "version --json is one object with the contract keys" "yes" \
    "$(printf '%s' "$_v" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["installed"] is True; assert d["status"] in ("current","updates_pending"); assert (d["remedy"] is None) == (d["status"] == "current"); print("yes")' 2>/dev/null || echo no)"
has "...with component rows" '"component": "exakit"' "$_v"
check "version --bogus exits 2" "2" "$(bash "$CLI" version --bogus >/dev/null 2>&1; echo $?)"
_ms="$(bash "$CLI" mcp-status --json 2>/dev/null)"
check "mcp-status --json is one object with a client list" "yes" \
    "$(printf '%s' "$_ms" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["installed"] is True and "status" in d and "remedy" in d and isinstance(d["details"]["clients"], list); print("yes")' 2>/dev/null || echo no)"
check "mcp-status --bogus exits 2" "2" "$(bash "$CLI" mcp-status --bogus >/dev/null 2>&1; echo $?)"
lacks "the client-name error no longer lists three of eight" "claude_desktop, cursor, codex, or all" "$(cat "$ROOT/setup/lib/common.sh")"

echo "12. a successful repair clears the failure note:"
has "cmd_mcp_doctor clears it" "exakit_clear_failure_note" "$(sed -n '/^cmd_mcp_doctor()/,/^}/p' "$CLI")"

# --- Round 2 (kit 0.2.3 audit) ---------------------------------------------

echo "R2-1. mcp-setup refuses options and arguments instead of ignoring them:"
check "mcp-setup --bogus exits 2" "2" "$(bash "$CLI" mcp-setup --bogus >/dev/null 2>&1; echo $?)"
has "...and names the EXAKIT_MCP_CLIENTS form" "EXAKIT_MCP_CLIENTS=" "$(bash "$CLI" mcp-setup --clients vscode_copilot 2>&1)"
check "a bare client name exits 2 too" "2" "$(bash "$CLI" mcp-setup vscode_copilot >/dev/null 2>&1; echo $?)"
lacks "nothing was set up on the way out" "MCP setup will edit" "$(bash "$CLI" mcp-setup --bogus 2>&1)"

echo "R2-2. status --json names a remedy for every install step that never finished:"
_sj="$(bash "$CLI" status --json 2>/dev/null)"
check "steps_missing lists the four unfinished steps" "exapump,mcp,pyexasol,exakit_helper" \
    "$(printf '%s' "$_sj" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["steps_missing"]))' 2>/dev/null)"
check "remedies.mcp is exakit mcp-setup" "exakit mcp-setup" "$(printf '%s' "$_sj" | python3 -c 'import json,sys; print(json.load(sys.stdin)["remedies"]["mcp"])' 2>/dev/null)"
check "remedies.pyexasol is exakit update" "exakit update" "$(printf '%s' "$_sj" | python3 -c 'import json,sys; print(json.load(sys.stdin)["remedies"]["pyexasol"])' 2>/dev/null)"
check "a stopped database still ranks first in the hoisted remedy" "exakit start" "$(printf '%s' "$_sj" | python3 -c 'import json,sys; print(json.load(sys.stdin)["remedy"])' 2>/dev/null)"
_sj_full="$(python3 - "$EXAKIT_MANIFEST" "$CLI" <<'PY'
import json, os, subprocess, sys
manifest, cli = sys.argv[1:3]
doc = json.load(open(manifest))
saved = doc["steps_completed"]
doc["steps_completed"] = ["launcher", "runtime", "exapump", "mcp", "pyexasol", "exakit_helper"]
json.dump(doc, open(manifest, "w"))
try:
    out = subprocess.run(["bash", cli, "status", "--json"], capture_output=True, text=True).stdout
finally:
    doc["steps_completed"] = saved
    json.dump(doc, open(manifest, "w"))
d = json.loads(out)
print("%s|%s" % (",".join(d["steps_missing"]), "mcp" in d["remedies"]))
PY
)"
check "with every step done, nothing is missing and no step remedy appears" "|False" "$_sj_full"

echo "R2-3. the remedy matcher reads the statement for TOP, and knows a TLS handshake failure:"
has "SELECT TOP n (engine: unexpected UNSIGNED_INTEGER_) gets the LIMIT remedy" "LIMIT" \
    "$(exakit_db_error_remedy 'Query execution failed: Protocol error: syntax error, unexpected UNSIGNED_INTEGER_, expecting UNION_' 'SELECT TOP 3 * FROM TPCH.NATION')"
check "a column called TOPIC is not TOP" "" "$(exakit_db_error_remedy 'syntax error, unexpected ;' 'SELECT TOPIC FROM T GROUP BY')"
check "a non-syntax error with TOP in the text stays quiet" "" "$(exakit_db_error_remedy 'some other failure' 'SELECT TOP 3 * FROM T')"
has "tls handshake eof points at exakit status" "exakit status" "$(exakit_db_error_remedy 'Error: Failed to connect to 127.0.0.1:8563: TLS error: tls handshake eof')"
lacks "...and is not mistaken for a stopped database" "stopped or unreachable" "$(exakit_db_error_remedy 'TLS error: tls handshake eof')"
has "cmd_sql hands the statement to the matcher" 'exakit_db_error_remedy "$_sql_out" "$_sql_text"' "$(sed -n '/^cmd_sql()/,/^}/p' "$CLI")"

echo "R2-4. a successful start retires only a runtime failure note:"
exakit_note_failure "Port 8563 is held by another process (pid 1, Python), not by Exasol, so the database cannot start. Stop that process, then: exakit start"
exakit_clear_runtime_failure_note
check "the port-conflict note is gone" "absent" "$([ -f "$EXAKIT_HOME/.last-failure" ] && echo present || echo absent)"
exakit_note_failure "the AI client configuration did not finish (see the log)"
exakit_clear_runtime_failure_note
check "an install-step note stays" "present" "$([ -f "$EXAKIT_HOME/.last-failure" ] && echo present || echo absent)"
exakit_clear_failure_note
has "cmd_start calls it once the database runs" "exakit_clear_runtime_failure_note" "$(sed -n '/^cmd_start()/,/^}/p' "$CLI")"

echo "R2-5. exakit sql --json is an option, and the gate still runs first:"
check "sql --json 'SELCT 1' exits 2 (typo gate before any connection)" "2" "$(bash "$CLI" sql --json 'SELCT 1' >/dev/null 2>&1; echo $?)"
has "the unknown-option message lists --json" "--json" "$(bash "$CLI" sql --bogus 'SELECT 1' 2>&1)"
has "the --json branch uses exapump's own json format" "-f json" "$(sed -n '/^cmd_sql()/,/^}/p' "$CLI")"
has "help names --json" "--json" "$(python3 -c 'import json; d=json.load(open("'"$ROOT"'/setup/help/exakit.json")); print([c for c in d["commands"] if c["command"]=="sql"][0]["options"])' 2>/dev/null)"

echo "R2-6. doctor names the client on every per-artifact finding, and the remedy names the command:"
check "no per-artifact finding is left without a client in scope" "0" "$(grep -c 'scope={"path": artifact.path}' "$ROOT/mcp/validator/service.py")"
check "no finding says the bare 'Run repair' any more" "0" "$(grep -c 'recommended_action="Run repair' "$ROOT/mcp/validator/service.py")"
has "the shared remedy names exakit mcp-doctor" "exakit mcp-doctor" "$(grep -A2 '^REPAIR_ACTION' "$ROOT/mcp/validator/service.py")"
has "discover-clients checks the file, not only the record" "_managed_entry_present" "$(cat "$ROOT/mcp/cli.py")"

echo "R2-7. the docs and skills carry the texts an agent actually sees:"
has "AGENTS.md: the TOP engine text" "UNSIGNED_INTEGER_" "$(cat "$ROOT/AGENTS.md")"
has "AGENTS.md: the masked MCP error" "A database error occurred" "$(cat "$ROOT/AGENTS.md")"
has "AGENTS.md: the TLS conflict text" "tls handshake" "$(cat "$ROOT/AGENTS.md")"
has "exasol-mcp skill: the masked MCP error" "A database error occurred" "$(cat "$ROOT/skills/exasol-mcp/SKILL.md")"
has "exasol-exapump skill: exakit sql --file" "exakit sql --file" "$(cat "$ROOT/skills/exasol-exapump/SKILL.md")"
has "exasol-exapump skill: discovery via SYS.EXA_ALL_TABLES" "SYS.EXA_ALL_TABLES" "$(cat "$ROOT/skills/exasol-exapump/SKILL.md")"
has "starter skill: discovery without MCP" "SYS.EXA_ALL_TABLES" "$(cat "$ROOT/skills/local-agent-ready-starter/SKILL.md")"
lacks "exasol-exapump skill no longer sends script files to exapump wholesale" "Drop to \`exapump\` for script files" "$(cat "$ROOT/skills/exasol-exapump/SKILL.md")"

# --- Round 3 (fresh 0.2.4 install audit) -----------------------------------

echo "R3-1. every command refuses an unknown option with exit 2, before doing anything:"
for _c in stop start info guide whats-new skills-install marketplace help catalog mcp-doctor mcp-remove update skills preflight; do
    check "exakit $_c --bogus exits 2" "2" "$(bash "$CLI" $_c --bogus >/dev/null 2>&1 </dev/null; echo $?)"
done
check "update with an unknown target exits 2" "2" "$(bash "$CLI" update nosuch-component >/dev/null 2>&1; echo $?)"
check "...and records no failure note" "absent" "$([ -f "$EXAKIT_HOME/.last-failure" ] && echo present || echo absent)"
has "help --bogus is a refusal, not a grep usage error" "Unknown option" "$(bash "$CLI" help --bogus 2>&1)"
check "info --json still answers" "yes" "$(bash "$CLI" info --json 2>/dev/null | python3 -c 'import json,sys; json.load(sys.stdin); print("yes")' 2>/dev/null || echo no)"

echo "R3-2. sql --json refusals are JSON on stdout:"
_rj="$(bash "$CLI" sql --json 'SELCT 1' 2>/dev/null)"
check "a typo is {ok:false, rejected:true}" "False True" "$(printf '%s' "$_rj" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["ok"], d["rejected"])' 2>/dev/null)"
check "...exit 2" "2" "$(bash "$CLI" sql --json 'SELCT 1' >/dev/null 2>&1; echo $?)"
check "two statements: JSON too" "False" "$(bash "$CLI" sql --json 'SELECT 1; SELECT 2' 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["ok"])' 2>/dev/null)"
check "an unknown option with --json: JSON too" "False" "$(bash "$CLI" sql --json --bogus 'SELECT 1' 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["ok"])' 2>/dev/null)"
check "without --json the refusal is still the human line" "" "$(bash "$CLI" sql 'SELCT 1' 2>/dev/null)"

echo "R3-3. exakit mcp-remove exists and takes client names:"
check "no client named: exit 2" "2" "$(bash "$CLI" mcp-remove >/dev/null 2>&1; echo $?)"
check "'all' refused: exit 2" "2" "$(bash "$CLI" mcp-remove all >/dev/null 2>&1; echo $?)"
has "help documents it" '"command": "mcp-remove"' "$(cat "$ROOT/setup/help/exakit.json")"
has "the doctor remedy that names it is now true" "exakit mcp-remove" "$(cat "$ROOT/mcp/validator/service.py")"
has "AGENTS.md names it" "exakit mcp-remove" "$(cat "$ROOT/AGENTS.md")"

echo "R3-4. the not-found hint knows file-loaded columns keep their case:"
has "STARTER_KIT table: says to quote" 'must be quoted' "$(exakit_db_error_remedy 'Query execution failed: object VISITS not found [line 1, column 12]' 'SELECT SUM(VISITS) FROM STARTER_KIT.VISITS')"
lacks "a bundled TPCH table: no such line" 'must be quoted' "$(exakit_db_error_remedy 'object N_NAM not found' 'SELECT N_NAM FROM TPCH.NATION')"
has "the exapump skill says the same" 'keep the file' "$(cat "$ROOT/skills/exasol-exapump/SKILL.md")"

echo "R3-5. uninstall removes exactly the permission rules the kit added:"
mkdir -p "$HOME/.claude"
printf '%s\n' '{"permissions": {"allow": ["Bash(exakit status:*)", "Bash(git status:*)", "mcp__exasol"], "deny": ["Bash(exakit uninstall:*)", "Bash(rm -rf:*)"]}, "theme": "dark"}' > "$HOME/.claude/settings.json"
check "reports what it removed" "REMOVED 3" "$(exakit_remove_readonly_allowlist)"
check "the user's own rules and settings stay" "Bash(git status:*)|Bash(rm -rf:*)|dark" \
    "$(python3 -c 'import json; d=json.load(open("'"$HOME"'/.claude/settings.json")); print("|".join(d["permissions"]["allow"]+d["permissions"]["deny"]+[d["theme"]]))')"
check "a second run removes nothing" "REMOVED 0" "$(exakit_remove_readonly_allowlist)"
has "the uninstall step calls it" "exakit_remove_readonly_allowlist" "$(sed -n '/^_exakit_remove_installed_skills()/,/^}/p' "$ROOT/setup/lib/common.sh")"

echo "R3-6. doctor repairs a repairable WARNING, and blames one file once:"
_rr="$WORK/result.json"
printf '%s' '{"operation":"doctor","status":"success_with_warnings","findings":[{"code":"permission_drift","severity":"warning","scope":{"path":"/x","client":"codex"}}]}' > "$_rr"
check "a loosened mode is repairable" "yes" "$(_exakit_mcp_result_repairable "$_rr" && echo yes || echo no)"
printf '%s' '{"operation":"doctor","status":"success_with_warnings","findings":[{"code":"managed_client_missing","severity":"warning","scope":{"client":"cursor"}}]}' > "$_rr"
check "an absent client is not" "no" "$(_exakit_mcp_result_repairable "$_rr" && echo yes || echo no)"
has "cmd_mcp_doctor acts on the flag" "EXAKIT_MCP_LAST_REPAIRABLE" "$(sed -n '/^cmd_mcp_doctor()/,/^}/p' "$CLI")"
has "one finding per file in the validator" "seen_paths" "$(cat "$ROOT/mcp/validator/service.py")"
has "the hoisted remedy ranks the worst finding about a file first" "RANK = " "$(cat "$ROOT/setup/lib/common.sh")"

echo "R3-7. add-on endpoints go only to connected clients; configured means the exasol entry:"
has "repair scopes the add-on to connected clients" "_connected_clients(repository" "$(cat "$ROOT/mcp/cli.py")"
lacks "...and never to the whole supported list" "clients=clients or list(SETUP_CLIENT_IDS)" "$(cat "$ROOT/mcp/cli.py")"
has "discover counts the exasol entry only" '_record_entry_name(record) != "exasol"' "$(cat "$ROOT/mcp/cli.py")"

printf '\npassed: %d, failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
