#!/usr/bin/env bash
# deploy-progress.sh — proves the two "something is happening" guarantees:
#
#   1. `exasol install local` is no longer echoed to the screen. Its output is
#      consumed into a progress line, while every raw byte still reaches the
#      logfile, the tail survives for a failed deploy, and the launcher's EULA
#      notice is replayed.
#   2. A long, silent step is animated under a truthful label: fetch_quiet keeps
#      the spinner outside the logfile redirect, and an add-on install names
#      itself instead of borrowing the previous step's title.
#
#   bash tests/deploy-progress.sh
#
# Pure logic against a sandboxed kit home: no network, no launcher, no install.

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

# Same isolation rule as the other suites: common.sh derives its paths at source
# time, so the kit home and HOME are redirected before it is read.
EXAKIT_HOME="$WORK/home"
EXAKIT_BIN_DIR="$WORK/bin"
HOME="$WORK/fake-home"
export HOME
mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR" "$HOME"

# shellcheck source=/dev/null
. "$ROOT/setup/lib/ui.sh"
# shellcheck source=/dev/null
. "$ROOT/setup/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/setup/lib/runtime-personal.sh"

EXAKIT_LOG_FILE="$WORK/install.log"
: > "$EXAKIT_LOG_FILE"

# A real `exasol install local` run, warm cache: the nine structured log lines
# and the connection overview that follows them. Trimmed only where the same
# shape repeats.
cat > "$WORK/launcher.txt" <<'LAUNCHEREOF'
{"time":"2026-08-26T05:18:24.887779+05:30","level":"INFO","msg":"validating presets"}
{"time":"2026-08-26T05:18:24.889452+05:30","level":"INFO","msg":"extracting preset files","infrastructure":{"Name":"local","Path":""}}
{"time":"2026-08-26T05:18:24.901145+05:30","level":"INFO","msg":"successfully initialized deployment","infrastructure":"local"}
{"time":"2026-08-26T05:18:25.067073+05:30","level":"INFO","msg":"found resource in cache","id":"exasol-local-runner","path":"/Users/x/Library/Caches/.exasol/personal/runtime-artifacts/artifacts/exasol-local-runner/darwin/arm64/74e3ef/unpack/launcher"}
{"time":"2026-08-26T05:18:33.433226+05:30","level":"INFO","msg":"found resource in cache","id":"exasol-local-runner","path":"/Users/x/Library/Caches/.exasol/personal/runtime-artifacts/artifacts/exasol-local-runner/darwin/arm64/74e3ef/unpack/launcher"}
{"time":"2026-08-26T05:18:49.020956+05:30","level":"INFO","msg":"waiting for database to start","elapsed_seconds":0,"next_retry_in_seconds":2,"remaining_seconds":297}
{"time":"2026-08-26T05:18:53.683701+05:30","level":"INFO","msg":"no installation steps defined; skipping"}
{"time":"2026-08-26T05:18:53.700245+05:30","level":"INFO","msg":"Completed deploying"}
Using default deployment directory: /Users/x/.exasol/personal/deployments/default
For your reference:
By using the Exasol Personal launcher, you accept its End User License Agreement (EULA):
https://www.exasol.com/terms-and-conditions/#h-exasol-personal-end-user-license-agreement

A copy of the EULA is also included as 'eula.txt' in this directory.

Exasol Personal Deployment Overview
Deployment directory: /Users/x/.exasol/personal/deployments/default
Deployment ID: 28e35d75
Deployment State: running
  - Password: <stored in /Users/x/.exasol/personal/deployments/default/secrets.json>
  Alternative: ssh -i local/node_access.pem root@127.0.0.1 -p 56732
=== Exasol Product Documentation ===
  https://docs.exasol.com/
LAUNCHEREOF
LAUNCHER_LINES="$(wc -l < "$WORK/launcher.txt" | tr -d ' ')"

printf '\n== the launcher stream is consumed, not printed ==\n'

STATE="$WORK/state"; TAIL="$WORK/tail"; NOTICE="$WORK/notice"
printf '0|5|3|0|Preparing to deploy\n' > "$STATE"
: > "$TAIL"; : > "$NOTICE"
# EXAKIT_DEPLOY_LIVE=1 is the animated case: the collector must print NOTHING,
# because the animator owns the screen.
EXAKIT_DEPLOY_LIVE=1
SCREEN="$(_personal_deploy_collect "$STATE" "$TAIL" "$NOTICE" < "$WORK/launcher.txt")"
check "animated run prints nothing" "" "$SCREEN"
lacks "no JSON on screen" '"level":"INFO"' "$SCREEN"
lacks "no secrets.json path on screen" "secrets.json" "$SCREEN"
lacks "no ssh line on screen" "node_access.pem" "$SCREEN"

# ...while the logfile still has every raw line, unchanged.
check "every raw line logged" "$LAUNCHER_LINES" "$(wc -l < "$EXAKIT_LOG_FILE" | tr -d ' ')"
has "raw JSON is in the log" '"msg":"Completed deploying"' "$(cat "$EXAKIT_LOG_FILE")"
has "overview is in the log" "Deployment ID: 28e35d75" "$(cat "$EXAKIT_LOG_FILE")"
check "tail file mirrors the stream" "$LAUNCHER_LINES" "$(wc -l < "$TAIL" | tr -d ' ')"

printf '\n== the bar reaches the end, and only ever moves forward ==\n'

# pct|ceiling|seconds|segment-start|phase — the segment's own clock is written
# with it, which is what lets the bar move while the launcher is silent.
check "the bar ends at 100" "100" "$(cut -d'|' -f1 "$STATE")"
check "with the final phase"  "Deployed" "$(cut -d'|' -f5 "$STATE")"

# Out-of-order and repeated milestones must not rewind the bar: a launcher that
# retries a stage would otherwise walk the percentage backwards on screen.
printf '0|5|3|0|Preparing to deploy\n' > "$STATE"
: > "$TAIL"; : > "$NOTICE"
printf '%s\n' \
    '{"msg":"validating presets"}' \
    '{"msg":"found resource in cache"}' \
    '{"msg":"found resource in cache"}' \
    '{"msg":"extracting preset files"}' \
    | _personal_deploy_collect "$STATE" "$TAIL" "$NOTICE" >/dev/null
check "a lower milestone never rewinds" "35" "$(cut -d'|' -f1 "$STATE")"
check "...keeping its phase"          "Getting Exasol ready" "$(cut -d'|' -f5 "$STATE")"

printf '\n== unknown output is harmless ==\n'

printf '10|20|2|0|Preparing to deploy\n' > "$STATE"
: > "$TAIL"; : > "$NOTICE"
NOISE="$(printf '%s\n' 'a line no launcher release ever wrote' '{"msg":"brand new message"}' \
    | _personal_deploy_collect "$STATE" "$TAIL" "$NOTICE")"
check "unknown lines print nothing" "" "$NOISE"
check "unknown lines do not move the bar" "10" "$(cut -d'|' -f1 "$STATE")"

printf '\n== without an animation, each phase gets one plain line ==\n'

printf '0|5|3|0|Preparing to deploy\n' > "$STATE"
: > "$TAIL"; : > "$NOTICE"
EXAKIT_DEPLOY_LIVE=0
PLAIN="$(_personal_deploy_collect "$STATE" "$TAIL" "$NOTICE" < "$WORK/launcher.txt")"
has "phase: preparing"  "Preparing to deploy"          "$PLAIN"
has "phase: getting ready" "Getting Exasol ready" "$PLAIN"
# The label has to hold for BOTH launcher messages this arm matches. It said
# "Fetching the Exasol runtime" for a cache hit too, where nothing is fetched
# and the launcher then goes quiet for the VM boot.
check "the cached path says the same" "Getting Exasol ready" \
    "$(_personal_deploy_milestone 'found resource in cache' | cut -d'|' -f4)"
check "and so does the download path" "Getting Exasol ready" \
    "$(_personal_deploy_milestone 'fetching resource abc' | cut -d'|' -f4)"
lacks "nothing still says 'runtime' at the reader" "Fetching the Exasol runtime" "$PLAIN"
has "phase: waiting"    "Waiting for Exasol" "$PLAIN"
has "phase: finishing"  "Finishing up"                      "$PLAIN"
has "phase: deployed"   "Deployed"                          "$PLAIN"
lacks "still no JSON" '"level":"INFO"' "$PLAIN"
# "Preparing to deploy" is three milestones; it must be said once.
check "a repeated phase is said once" "1" \
    "$(printf '%s\n' "$PLAIN" | grep -c 'Preparing to deploy')"

printf '\n== the EULA notice survives the stream being hidden ==\n'

NOTICE_OUT="$(_personal_deploy_print_notice "$NOTICE")"
has "EULA sentence replayed" "you accept its End User License Agreement" "$NOTICE_OUT"
has "EULA link replayed" "https://www.exasol.com/terms-and-conditions/" "$NOTICE_OUT"

printf '\n== a failed deploy still shows the launcher its own words ==\n'

TAIL_OUT="$(_personal_deploy_print_tail "$TAIL")"
has "tail is announced" "last lines from the exasol launcher" "$TAIL_OUT"
has "tail has the launcher's end" "https://docs.exasol.com/" "$TAIL_OUT"
check "tail is bounded (1 note + 12 lines)" "13" "$(printf '%s\n' "$TAIL_OUT" | wc -l | tr -d ' ')"
check "an empty tail prints nothing" "" "$(_personal_deploy_print_tail "$WORK/absent")"

printf '\n== the bar keeps moving while the launcher says nothing ==\n'

# The launcher is silent for about twenty-five seconds between "found resource
# in cache" and "waiting for database to start", which is the longest stretch of
# the deploy. Milestones stay the truth; the time between them is filled in.
SEG="$(_personal_deploy_milestone '{"msg":"found resource in cache"}')"
check "the segment knows where it ends" "35|65|25" "${SEG%|*}"
check "at the start it is the milestone" "35" "$(ui_progress_creep 35 65 25 0)"
check "a third of the way in"            "44" "$(ui_progress_creep 35 65 25 8)"
check "two thirds"                       "54" "$(ui_progress_creep 35 65 25 16)"
# Capped one point BELOW the next milestone: arriving at it must still be
# something the reader sees happen...
check "just before the next stage"       "64" "$(ui_progress_creep 35 65 25 25)"
# ...and a stage that runs long waits there rather than walking into the next
# one's territory.
check "a stage that overruns waits"      "64" "$(ui_progress_creep 35 65 25 300)"
check "never before its own milestone"   "35" "$(ui_progress_creep 35 65 25 0)"
# A milestone with nowhere to creep to just sits on its number.
check "the final milestone does not creep" "100" "$(ui_progress_creep 100 100 0 9)"
check "nor does a zero-length segment"     "65"  "$(ui_progress_creep 65 65 10 5)"

printf '\n== the progress line carries a bar, a percentage and a clock ==\n'

UI_SPIN_FRAMES=(a b c d e f g h i j)
BAR="$(ui_progress_line 65 "Waiting for Exasol" 42 0 100)"
has "percentage rendered" "65%" "$BAR"
has "phase rendered" "Waiting for Exasol" "$BAR"
has "elapsed rendered" "(42s)" "$BAR"
has "bar is filled" "$UI_BAR_FULL" "$BAR"
has "bar has a remainder" "$UI_BAR_EMPTY" "$BAR"
# 100% must fill the bar exactly, not overflow it.
FULL="$(ui_progress_line 100 Deployed 9 0 100)"
lacks "a full bar has no remainder" "$UI_BAR_EMPTY" "$FULL"

printf '\n== a download animates instead of going silent ==\n'

# fetch_quiet must start the spinner BEFORE redirecting to the log — the whole
# point of it. Proven by what reaches the caller: stdout stays clean, the
# command's chatter lands in the log, and a failure is soft (fetch would die).
fetch() { printf 'curl noise\n'; return 7; }   # stub: no network in this suite
: > "$EXAKIT_LOG_FILE"
FQ_OUT="$(fetch_quiet https://example.invalid/x "$WORK/dl" 2>&1)"
FQ_RC=$?
check "a failed download is soft" "7" "$FQ_RC"
check "its chatter is off screen" "" "$FQ_OUT"
has "its chatter is in the log" "curl noise" "$(cat "$EXAKIT_LOG_FILE")"
fetch() { printf 'curl noise\n'; return 0; }
fetch_quiet https://example.invalid/x "$WORK/dl" >/dev/null 2>&1
check "a good download reports success" "0" "$?"

# The ORDER is the fix. Give the spinner a voice: started before the redirect it
# reaches the caller, started inside it (what every add-on download used to do)
# it would be swallowed by the logfile. The stubs stay for the rest of the run;
# nothing below animates.
ui_spin_begin() { printf 'SPINNER\n'; }
ui_spin_end()   { :; }
: > "$EXAKIT_LOG_FILE"
SPIN_OUT="$(fetch_quiet https://example.invalid/x "$WORK/dl" 2>&1)"
has   "the spinner starts before the redirect" "SPINNER" "$SPIN_OUT"
lacks "the spinner is not swallowed by the log" "SPINNER" "$(cat "$EXAKIT_LOG_FILE")"

printf '\n== the wiring itself stays wired ==\n'

RP="$(cat "$ROOT/setup/lib/runtime-personal.sh")"
lacks "the launcher is not streamed to the screen" \
    "install local 2>&1 | exakit_stream_foreign" "$RP"
has "the launcher is piped into the collector" \
    '_personal_deploy_collect "$_deploy_state" "$_deploy_tail" "$_deploy_notice"' "$RP"
ADDONS="$(cat "$ROOT/setup/lib/exasol-vscode.sh" "$ROOT/setup/lib/dash-server.sh" \
    "$ROOT/setup/lib/json-tables.sh")"
lacks "no add-on redirects a fetch by hand" "( fetch " "$ADDONS"
lacks "the VS Code install is not a bare redirect" \
    '_exasol_vscode_code --install-extension "$(_exasol_vscode_host_path "$_evi_vsix")" --force' "$ADDONS"

printf '\n== an add-on install reports its own stages ==\n'

# The add-on install writes into the shared progress state now, not into the
# spinner's label. tests/install-output-brevity.sh owns the rest of that flow;
# what is asserted here is that the state carries this add-on and this stage.
ADDON_STATE="$WORK/addon-state"
_exakit_addon_progress "$ADDON_STATE" dash-server 0 65 40 "installing"
check "the stage it is at"       "0"  "$(cut -d'|' -f1 "$ADDON_STATE")"
check "and where that stage ends" "65" "$(cut -d'|' -f2 "$ADDON_STATE")"
has "the add-on is named"        "dash-server" "$(cut -d'|' -f5 "$ADDON_STATE")"
has "so is the phase"            "installing"  "$(cut -d'|' -f5 "$ADDON_STATE")"
_exakit_addon_progress "$ADDON_STATE" dash-server 65 90 8 "validating"
check "validating starts at 65"  "65" "$(cut -d'|' -f1 "$ADDON_STATE")"
has "...and says so"             "validating" "$(cut -d'|' -f5 "$ADDON_STATE")"

# Every phase must fit the cell it is drawn in. The phase gets 30% of the
# progress line, which is 21 columns on an 80-column terminal -- the narrowest
# the line supports -- so a longer phase is ellipsed for anyone not running a
# wide window. This has gone wrong twice: once when a phase was reworded to be
# accurate on both the download and cache-hit paths and grew to 33 characters,
# and once before that. Measuring the strings is cheaper than noticing on screen.
echo
echo "== every phase fits the 21-column cell =="
PHASE_SRC="$ROOT/setup/lib/runtime-personal.sh"
LONGEST=0
for _p in $(grep -ohE "printf '[0-9]+\|[0-9]+\|[0-9]+\|[^']+'" "$PHASE_SRC" \
            | sed "s/.*|//;s/'$//" | tr ' ' '_' | sort -u); do
    _phase="$(printf '%s' "$_p" | tr '_' ' ')"
    _len=${#_phase}
    [ "$_len" -gt "$LONGEST" ] && LONGEST=$_len
    if [ "$_len" -le 21 ]; then
        PASS=$((PASS + 1)); printf '  ok   %-28s fits (%d)\n' "$_phase" "$_len"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL %-28s is %d chars; the cell is 21 at 80 columns\n' "$_phase" "$_len"
    fi
done
check "a phase was actually measured" "yes" "$([ "$LONGEST" -gt 0 ] && echo yes || echo NONE-FOUND)"

printf '\n== a failing deploy tells the truth, and never offers to delete a database ==\n'

NANO_SH="$(cat "$ROOT/setup/lib/runtime-nano.sh")"
NANO_PS1="$(cat "$ROOT/setup/lib/nano.ps1")"
DETECT_SH="$(cat "$ROOT/setup/lib/detect.sh")"

# C1: the branch knew only that the CONTAINER was absent, and deployed over an
# existing data volume with a freshly minted password and single-use init args
# the image refuses on an initialised /exa. Worse, it registered a `volume rm`
# rollback unconditionally, so "undo the failed step?" deleted a database this
# run had merely adopted.
has   "the volume is probed first"     'volume inspect "$EXAKIT_NANO_VOLUME"'     "$NANO_SH"
has   "...and on Windows"              'volume inspect $script:NanoVolume'        "$NANO_PS1"
has   "an adopted volume is adopted"   'Adopting the existing database volume'    "$NANO_SH"
has   "...and on Windows"              'Adopting the existing database volume'    "$NANO_PS1"
# The rollback that can delete a database is registered once, inside the branch
# that created the volume - never beside the adopt path.
check "one volume rollback only"       "1" \
    "$(printf '%s\n' "$NANO_SH" | grep -c 'push_rollback "\$_engine volume rm')"

# C3: the container's own last words were read straight into the log file and
# the caller then called the exit a timeout, which it never was.
lacks "no log-only container tail"     'logs --tail 30 "$EXAKIT_NANO_CONTAINER" >> '  "$NANO_SH"
has   "the tail is kept and shown"     'The database container started and then exited'  "$NANO_SH"
has   "...and on Windows"              'The database container started and then exited'  "$NANO_PS1"
has   "an exit is not a timeout"       'EXAKIT_NANO_EXITED'                       "$NANO_SH"
has   "known causes are explained"     'nano_explain_container_exit'              "$NANO_SH"
has   "...and on Windows"              'Show-NanoContainerExitRemedy'             "$NANO_PS1"

# C4: the readiness timeout is reached from a first deploy, from `exakit start`
# on an established database, and from an update - and it printed `volume rm`
# to all three.
has   "the destructive remedy is gated" 'if [ "${EXAKIT_NANO_FIRST_DEPLOY:-0}" = "1" ]' "$NANO_SH"
has   "...and on Windows"               'if ($script:NanoFirstDeploy)'            "$NANO_PS1"
has   "an established database is warned" 'it IS your database'                   "$NANO_SH"
has   "...and on Windows"                 'it IS your database'                   "$NANO_PS1"

# C5: -f is true for a zero-byte file, and an empty secret makes the image
# refuse to deploy - which surfaces minutes later as C3's container exit.
has   "an empty secret is refused"     '[ -s "${EXAKIT_CREDS_DIR}/nano_sys_password" ]' "$NANO_SH"
lacks "...not merely an existing one"  '[ -f "${EXAKIT_CREDS_DIR}/nano_sys_password" ]' "$NANO_SH"
has   "Windows checks it too"          'Test-Path $pwFile -PathType Leaf'         "$NANO_PS1"
has   "...including the empty case"    '(Get-Item $pwFile).Length -eq 0'          "$NANO_PS1"

# H1: "Stop it" is unactionable when "it" is never named. On a machine with WSL
# the holder is often wslrelay, which only `wsl --shutdown` releases.
has   "the shell can name a holder"    'port_holder_desc()'                       "$DETECT_SH"
has   "...and Windows can"             'function Get-ExakitPortHolder'            "$NANO_PS1"
lacks "no unnamed culprit"             'already in use by another application'    "$NANO_SH"
lacks "...on Windows either"           'already in use by another application'    "$NANO_PS1"
has   "the WSL relay case is named"    'wsl --shutdown'                           "$NANO_PS1"

# MEDIUM: a one-line engine error was replaced with "(see log)".
has   "a start failure is quoted"      'nano_die_container_start'                 "$NANO_SH"
has   "...and on Windows"              'Show-NanoContainerStartFailure'           "$NANO_PS1"
lacks "no bare see-log on start"       'die "Container failed to start (see log)"' "$NANO_SH"

printf '\n== no function is defined twice ==\n'

# A duplicated definition is invisible to every check the repo already runs: the
# file parses, the encoding guard passes, and the LAST definition silently wins.
# It happened for real - a patch to Install-Nano in nano.ps1 computed its end
# offset from an anchor that occurs twice, re-included the region instead of
# replacing it, and left the PRE-FIX body as the effective one. Windows kept the
# old behaviour while every test went green.
for _dup_file in "$ROOT"/setup/lib/*.ps1 "$ROOT"/setup/*.ps1 "$ROOT"/install.ps1; do
    [ -f "$_dup_file" ] || continue
    _dup_names="$(grep -oE '^function [A-Za-z][A-Za-z0-9-]*' "$_dup_file" 2>/dev/null | sort | uniq -d | tr '\n' ' ')"
    check "$(basename "$_dup_file") defines each function once" "" "$(printf '%s' "$_dup_names" | sed 's/ *$//')"
done

# The shell side has the same hazard, and one real instance predates this guard:
# ui_rule is defined twice in ui.sh. It is listed here so the count cannot grow
# without someone noticing, rather than being quietly tolerated.
for _dup_sh in "$ROOT"/setup/lib/*.sh; do
    [ -f "$_dup_sh" ] || continue
    _dup_shnames="$(grep -oE '^[a-z_][a-z0-9_]*\(\) \{' "$_dup_sh" 2>/dev/null | sort | uniq -d | tr '\n' ' ')"
    _dup_shnames="$(printf '%s' "$_dup_shnames" | sed 's/ *$//')"
    case "$(basename "$_dup_sh")" in
        ui.sh) check "ui.sh has exactly the one known duplicate" "ui_rule() {" "$_dup_shnames" ;;
        *)     check "$(basename "$_dup_sh") defines each function once" "" "$_dup_shnames" ;;
    esac
done

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
