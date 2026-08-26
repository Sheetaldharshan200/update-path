#!/usr/bin/env bash
# dataset-load-progress.sh — proves a bundled dataset load narrates itself on
# ONE line instead of a dozen per file.
#
#   bash tests/dataset-load-progress.sh
#
# The exapump binary is stubbed, so this runs with no database and no network:
# what is under test is what reaches the SCREEN, what still reaches the LOGFILE,
# and that a failed verification still shows everything it used to.

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
# shellcheck source=/dev/null
. "$ROOT/setup/lib/exapump.sh"

# The glyph palette follows whether stdout is a terminal, and a test run is
# never one. Force the fancy table so the bar is asserted on the characters a
# user actually sees, not on the ASCII fallback.
UI_FANCY=1
UI_BAR_FULL="$(printf '\xe2\x96\x88')"
UI_BAR_EMPTY="$(printf '\xe2\x96\x91')"

printf '\n== the bar renders as a string, for embedding in a label ==\n'

check "0% is all empty"   "$(printf '\xe2\x96\x91%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20)" "$(ui_bar 0)"
check "100% is all full"  "$(printf '\xe2\x96\x88%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20)" "$(ui_bar 100)"
check "50% is half full"  "10" "$(ui_bar 50 | tr -dc "$UI_BAR_FULL" | wc -c | tr -d ' ' | awk '{print $1/3}')"
check "over 100% is clamped" "20" "$(ui_bar 140 | tr -dc "$UI_BAR_FULL" | wc -c | tr -d ' ' | awk '{print $1/3}')"
check "a narrower bar is honoured" "8" "$(ui_bar 100 8 | tr -dc "$UI_BAR_FULL" | wc -c | tr -d ' ' | awk '{print $1/3}')"

printf '\n== the row total is readable ==\n'

check "thousands are grouped"  "173,745" "$(exakit_group_digits 173745)"
check "millions too"           "1,234,567" "$(exakit_group_digits 1234567)"
check "small numbers untouched" "25" "$(exakit_group_digits 25)"

printf '\n== the progress label carries the whole story ==\n'

_exakit_dataset_progress tpch 3 12 "lineitem.csv"
LABEL="$EXAKIT_ACTIVE_LABEL"
has "the dataset id"    "tpch"          "$LABEL"
has "the percentage"    "25%"           "$LABEL"
has "the current file"  "lineitem.csv"  "$LABEL"
has "a filled bar"      "$UI_BAR_FULL"  "$LABEL"
has "a remaining bar"   "$UI_BAR_EMPTY" "$LABEL"
# The label is what the spinner paints. It must never print on its own, or a
# non-terminal run would get one of these per step.
check "setting it prints nothing" "" "$(_exakit_dataset_progress tpch 1 4 x)"

printf '\n== a SQL script is quiet when the caller narrates ==\n'

QUIET_OUT="$(EXAKIT_UPLOAD_QUIET=1 exapump_run_sql_file "$WORK/missing.sql" "x" 2>&1 || true)"
has "a missing file still warns" "SQL file missing or empty" "$QUIET_OUT"
EXAPUMP_SH="$(cat "$ROOT/setup/lib/exapump.sh")"
has "the narration is gated on entry" '[ "${EXAKIT_UPLOAD_QUIET:-0}" = 1 ] || info "Running' "$EXAPUMP_SH"
has "and on the way out"              '[ "${EXAKIT_UPLOAD_QUIET:-0}" = 1 ] || ok "${2:-' "$EXAPUMP_SH"

printf '\n== a dataset load prints two lines, not a hundred ==\n'

# A stub exapump: uploads succeed silently, a row count answers with the token
# the real one emits, and the verify script gets a canned result grid.
cat > "$EXAKIT_BIN_DIR/exapump" <<'STUBEOF'
#!/bin/sh
case "$1" in
    upload) exit 0 ;;
    sql)
        shift; shift; shift
        if [ -n "${1:-}" ]; then
            case "$1" in *EXAKIT_RC*) echo "EXAKIT_RC[3000]" ;; esac
            exit 0
        fi
        body="$(cat)"
        case "$body" in
            *CHECK_NAME*)
                echo "CHECK_NAME,STATUS,DETAIL"
                echo "fk: customer.c_nationkey -> nation,${EXAKIT_STUB_STATUS:-OK},0 orphaned row(s)"
                echo 'row_count: customer,OK,"expected 3000, found 3000"'
                ;;
        esac
        exit 0 ;;
esac
exit 0
STUBEOF
chmod +x "$EXAKIT_BIN_DIR/exapump"
exapump_cli() { printf '%s\n' "$EXAKIT_BIN_DIR/exapump"; }
EXAKIT_EXAPUMP_PROFILE="starter-kit"
manifest_get() { [ "$1" = "components.exapump.profile" ] && printf 'starter-kit\n'; return 0; }
manifest_set() { return 0; }
exakit_dataset_loaded() { return 1; }
exakit_schema_present() { return 0; }

EXAKIT_LOG_FILE="$WORK/install.log"
: > "$EXAKIT_LOG_FILE"
OUT="$(exakit_load_dataset_dir "$ROOT" tpch 2>&1)"
RC=$?

check "the load succeeds" "0" "$RC"
check "two lines on screen" "2" "$(printf '%s\n' "$OUT" | grep -c .)"
has "line 1 names the dataset and schema" "Loading the 'tpch' dataset into schema TPCH" "$OUT"
has "line 2 is the result"                "Dataset 'tpch' loaded and verified"          "$OUT"

lacks "no per-file loading line"  "Loading customer.csv into"  "$OUT"
lacks "no per-file loaded line"   "customer.csv loaded"        "$OUT"
lacks "no per-script line"        "01_create_schema.sql) done" "$OUT"
lacks "no verification header"    "Verification (tpch"         "$OUT"
lacks "no verification rows"      "CHECK_NAME,STATUS,DETAIL"   "$OUT"
lacks "no orphaned-row chatter"   "orphaned row(s)"            "$OUT"
lacks "no row-count panel"        "Row counts"                 "$OUT"

printf '\n== the result line carries what the panel used to ==\n'

has "the table count" "8 tables" "$OUT"
# 8 stubbed tables at 3000 rows each, grouped.
has "the row total, grouped" "24,000 rows" "$OUT"
has "and how long it took"   "s)"          "$OUT"

printf '\n== nothing is lost: the logfile still has all of it ==\n'

LOG="$(cat "$EXAKIT_LOG_FILE")"
check "every table is counted in the log" "8" "$(grep -c 'DATA  TPCH\.' "$EXAKIT_LOG_FILE")"
has "with its schema and rows"    "TPCH.CUSTOMER" "$LOG"
has "the verification is logged"  "CHECK_NAME,STATUS,DETAIL" "$LOG"
has "so are the commands"         "exapump" "$LOG"

printf '\n== a FAILED verification still shows everything ==\n'

: > "$EXAKIT_LOG_FILE"
OUT="$(EXAKIT_STUB_STATUS=FAIL exakit_load_dataset_dir "$ROOT" tpch 2>&1)"
RC=$?
check "a failed dataset fails the run" "1" "$RC"
has "it says which dataset"      "Verification failed for dataset 'tpch'" "$OUT"
has "it prints the checks"       "CHECK_NAME,STATUS,DETAIL"               "$OUT"
has "including the failing row"  ",FAIL,"                                 "$OUT"
has "and names the remedy"       "re-run with --force"                    "$OUT"
# The rows are printed AND logged, but only once each: exakit_stream_foreign
# would have logged them a second time on top of the capture.
check "the checks are logged once" "1" "$(grep -c 'CHECK_NAME,STATUS,DETAIL' "$EXAKIT_LOG_FILE")"

printf '\n== the PowerShell twin moves with it ==\n'

UI_PS1="$(cat "$ROOT/setup/lib/ui.ps1")"
EXAPUMP_PS1="$(cat "$ROOT/setup/lib/exapump.ps1")"
has "ui.ps1 has the bar helper"        "function Get-ExakitBar"           "$UI_PS1"
has "exapump.ps1 sets the progress"    "function Set-ExakitDatasetProgress" "$EXAPUMP_PS1"
has "...and runs steps under it"       "function Invoke-ExakitDatasetStep"  "$EXAPUMP_PS1"
has "it groups the row total"          "function Get-ExakitGroupedDigits"   "$EXAPUMP_PS1"
lacks "no row-count panel on Windows either" 'Start-ExakitPanel "Row counts"' "$EXAPUMP_PS1"
lacks "no unconditional verify header" 'Info "Verification ($Id 03_verify_setup.sql):"' "$EXAPUMP_PS1"
has "its SQL narration is gated too"   'if (-not $script:ExakitUploadQuiet) { Info "Running $Description" }' "$EXAPUMP_PS1"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
