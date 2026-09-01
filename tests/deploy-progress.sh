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
printf '0|5|3|0|Preparing the deployment\n' > "$STATE"
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
printf '0|5|3|0|Preparing the deployment\n' > "$STATE"
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

printf '10|20|2|0|Preparing the deployment\n' > "$STATE"
: > "$TAIL"; : > "$NOTICE"
NOISE="$(printf '%s\n' 'a line no launcher release ever wrote' '{"msg":"brand new message"}' \
    | _personal_deploy_collect "$STATE" "$TAIL" "$NOTICE")"
check "unknown lines print nothing" "" "$NOISE"
check "unknown lines do not move the bar" "10" "$(cut -d'|' -f1 "$STATE")"

printf '\n== without an animation, each phase gets one plain line ==\n'

printf '0|5|3|0|Preparing the deployment\n' > "$STATE"
: > "$TAIL"; : > "$NOTICE"
EXAKIT_DEPLOY_LIVE=0
PLAIN="$(_personal_deploy_collect "$STATE" "$TAIL" "$NOTICE" < "$WORK/launcher.txt")"
has "phase: preparing"  "Preparing the deployment"          "$PLAIN"
has "phase: getting ready" "Getting Exasol ready" "$PLAIN"
# The label has to hold for BOTH launcher messages this arm matches. It said
# "Fetching the Exasol runtime" for a cache hit too, where nothing is fetched
# and the launcher then goes quiet for the VM boot.
check "the cached path says the same" "Getting Exasol ready" \
    "$(_personal_deploy_milestone 'found resource in cache' | cut -d'|' -f4)"
check "and so does the download path" "Getting Exasol ready" \
    "$(_personal_deploy_milestone 'fetching resource abc' | cut -d'|' -f4)"
lacks "nothing still says 'runtime' at the reader" "Fetching the Exasol runtime" "$PLAIN"
has "phase: waiting"    "Waiting for the database" "$PLAIN"
has "phase: finishing"  "Finishing up"                      "$PLAIN"
has "phase: deployed"   "Deployed"                          "$PLAIN"
lacks "still no JSON" '"level":"INFO"' "$PLAIN"
# "Preparing the deployment" is three milestones; it must be said once.
check "a repeated phase is said once" "1" \
    "$(printf '%s\n' "$PLAIN" | grep -c 'Preparing the deployment')"

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
BAR="$(ui_progress_line 65 "Waiting for the database" 42 0 100)"
has "percentage rendered" "65%" "$BAR"
has "phase rendered" "Waiting for the database" "$BAR"
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

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
