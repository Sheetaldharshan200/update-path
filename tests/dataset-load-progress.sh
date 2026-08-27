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

# COUNT NOTHING IN BYTES: COMPARE THE WHOLE BAR.
#
# These used to count full blocks with `ui_bar 50 | tr -dc "$UI_BAR_FULL" |
# wc -c | awk '{print $1/3}'`, and it was wrong in a way only Linux showed.
# GNU tr is BYTE-oriented, and the two glyphs share their first two bytes --
# U+2588 is e2 96 88, U+2591 is e2 96 91 -- so a filter meant to keep only
# FULL blocks also kept two bytes out of every EMPTY one. At 50% that is 30
# bytes of full plus 20 bytes of empty, and 50/3 = 16.6667: a count of
# characters came out fractional, which is the tell. BSD tr on macOS treats
# the argument as one multibyte character and drops the empties, so the same
# line passed there and failed only on ubuntu.
#
# The two clamping checks passed everywhere for a reason worth keeping in
# mind: both clamp to a COMPLETELY FULL bar, so there were no empty blocks to
# contaminate the count. The idiom was equally broken in all three; only the
# mixed bar could ever reveal it.
#
# So compare the entire rendered string. No byte arithmetic, no locale, no
# division -- and it asserts the ORDER too (filled first, then remaining),
# which counting never did. bar_glyphs deliberately does not call ui_repeat:
# an expected value must not be built by the code under test.
bar_glyphs() { # bar_glyphs <glyph> <count>
    _bg_out=""
    _bg_i=0
    while [ "$_bg_i" -lt "$2" ]; do
        _bg_out="$_bg_out$1"
        _bg_i=$((_bg_i + 1))
    done
    printf '%s' "$_bg_out"
}

check "0% is all empty"   "$(bar_glyphs "$UI_BAR_EMPTY" 20)" "$(ui_bar 0)"
check "100% is all full"  "$(bar_glyphs "$UI_BAR_FULL" 20)" "$(ui_bar 100)"
check "50% is half full"  "$(bar_glyphs "$UI_BAR_FULL" 10)$(bar_glyphs "$UI_BAR_EMPTY" 10)" "$(ui_bar 50)"
check "over 100% is clamped" "$(bar_glyphs "$UI_BAR_FULL" 20)" "$(ui_bar 140)"
check "a narrower bar is honoured" "$(bar_glyphs "$UI_BAR_FULL" 8)" "$(ui_bar 100 8)"

printf '\n== the row total is readable ==\n'

check "thousands are grouped"  "173,745" "$(exakit_group_digits 173745)"
check "millions too"           "1,234,567" "$(exakit_group_digits 1234567)"
check "small numbers untouched" "25" "$(exakit_group_digits 25)"

printf '\n== the load is weighted by bytes, not by step count ==\n'

# TPC-H is twelve steps and lineitem.csv is fifteen megabytes of twenty-one.
# Counted as steps the bar reached 25% while the file that is most of the job was
# still going; weighted by bytes it reports what is actually left.
BIG="$WORK/big.csv"; SMALL="$WORK/small.csv"
head -c 400000 /dev/zero | tr '\0' 'x' > "$BIG"
head -c 1000 /dev/zero   | tr '\0' 'x' > "$SMALL"
check "a file weighs its bytes" "400000" "$(exakit_load_weight_of "$BIG")"
check "a small one weighs less" "1000"   "$(exakit_load_weight_of "$SMALL")"
check "a file that is not there weighs nothing" "0" "$(exakit_load_weight_of "$WORK/absent.csv")"

# Seconds are an estimate, and a floor keeps a tiny file from claiming zero.
check "a big file is given time"   "2" "$(exakit_load_secs_for 2097152)"
check "a tiny one gets the floor"  "2" "$(exakit_load_secs_for 10)"

# The step reports where it is and where the stage ends, as percentages of the
# whole weight.
LOAD_STATE="$WORK/load-state"
exakit_load_step "$LOAD_STATE" 0 400000 500000 4 "tpch · big.csv"
check "it starts at nought"        "0"  "$(cut -d'|' -f1 "$LOAD_STATE")"
check "and ends at four fifths"    "80" "$(cut -d'|' -f2 "$LOAD_STATE")"
has "naming the file"              "big.csv" "$(cut -d'|' -f5 "$LOAD_STATE")"
exakit_load_step "$LOAD_STATE" 400000 100000 500000 2 "tpch · small.csv"
check "the next stage starts where that ended" "80" "$(cut -d'|' -f1 "$LOAD_STATE")"
check "and finishes the job"                   "100" "$(cut -d'|' -f2 "$LOAD_STATE")"
# A weightless total must not divide by zero.
exakit_load_step "$LOAD_STATE" 0 0 0 2 "empty"
check "an empty load reports nought" "0" "$(cut -d'|' -f1 "$LOAD_STATE")"

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
has "exapump.ps1 weighs its files"     "function Get-ExakitLoadWeight"  "$EXAPUMP_PS1"
has "...and reports each stage"        "function Set-ExakitLoadStep"    "$EXAPUMP_PS1"
has "...driving the shared bar"        "Start-ExakitProgress -Pct 0"    "$EXAPUMP_PS1"
has "ui.ps1 has the progress line"     "function Write-ExakitProgressLine" "$UI_PS1"
has "...and the animator"              "function Start-ExakitProgress"     "$UI_PS1"
has "it groups the row total"          "function Get-ExakitGroupedDigits"   "$EXAPUMP_PS1"
lacks "no row-count panel on Windows either" 'Start-ExakitPanel "Row counts"' "$EXAPUMP_PS1"
lacks "no unconditional verify header" 'Info "Verification ($Id 03_verify_setup.sql):"' "$EXAPUMP_PS1"
has "its SQL narration is gated too"   'if (-not $script:ExakitUploadQuiet) { Info "Running $Description" }' "$EXAPUMP_PS1"

printf '\n== the datasets table is the menu AND the progress ==\n'

UI_TABLE_TITLE="Datasets to load"
exakit_pending_datasets() {
    printf 'tpch|TPC-H retail benchmark\nenergy|Smart-meter energy readings\nweather|City weather daily history\n'
}
TBL="$WORK/table"
exakit_data_table_build "$TBL"

check "a row per dataset, plus the group, the file row and Skip" "6" "$(grep -c '.' "$TBL")"
check "the group row leads"        "group"      "$(sed -n 1p "$TBL" | cut -d'|' -f1)"
check "the last dataset corners"   "corner"     "$(sed -n 4p "$TBL" | cut -d'|' -f1)"
check "the file row is 5"          "5"          "$EXAKIT_TABLE_ROW_LOCAL"
check "Skip is 6, and exclusive"   "6"          "$EXAKIT_TABLE_EXCLUSIVE"
check "the group is all-or-none"   "1:2:4:all"  "$EXAKIT_TABLE_GROUP"
check "everything loadable is pre-ticked" "1,2,3,4" "$EXAKIT_TABLE_DEFAULTS"
# A label with spaces in it is ONE row: an accumulator split on whitespace turned
# "TPC-H retail benchmark" into three rows of the table.
check "a multi-word label stays one row" "TPC-H retail benchmark" "$(sed -n 2p "$TBL" | cut -d'|' -f2)"
check "a dataset knows its own row"      "3" "$(exakit_data_table_row energy)"
check "and a non-dataset does not"       "0" "$(exakit_data_table_row nonesuch)"

# With every bundled dataset in, the pre-ticked row is the local-file one — the
# only thing the screen can still do. Enter must never be a no-op.
exakit_pending_datasets() { :; }
exakit_data_table_build "$TBL"
check "nothing pending: the file row is pre-ticked" "$EXAKIT_TABLE_ROW_LOCAL" "$EXAKIT_TABLE_DEFAULTS"
lacks "...and Skip is not"  ",$EXAKIT_TABLE_ROW_SKIP," ",$EXAKIT_TABLE_DEFAULTS,"

printf '\n== a row carries its own state, and keeps its clock ==\n'

exakit_pending_datasets() {
    printf 'tpch|TPC-H retail benchmark\nenergy|Smart-meter energy readings\nweather|City weather daily history\n'
}
exakit_data_table_build "$TBL"
ui_table_set "$TBL" 2 running 10 40 8 "creating schema TPCH"
check "the row is running"  "running"              "$(sed -n 2p "$TBL" | cut -d'|' -f4)"
check "at its milestone"    "10"                   "$(sed -n 2p "$TBL" | cut -d'|' -f5)"
check "with a ceiling"      "40"                   "$(sed -n 2p "$TBL" | cut -d'|' -f6)"
has "and a phase"           "creating schema TPCH" "$(sed -n 2p "$TBL" | cut -d'|' -f9)"
CLOCK="$(sed -n 2p "$TBL" | cut -d'|' -f8)"
# A new PHASE inside the same job must not restart the elapsed count the reader
# is watching.
ui_table_set "$TBL" 2 running 40 88 20 "loading 8 data files"
check "a phase change keeps the clock" "$CLOCK" "$(sed -n 2p "$TBL" | cut -d'|' -f8)"
check "...but moves the bar"           "40"     "$(sed -n 2p "$TBL" | cut -d'|' -f5)"
ui_table_set "$TBL" 2 done "" "" "" "" "completed · 8 tables, 173,745 rows (23s)"
check "finishing clears the clock" "" "$(sed -n 2p "$TBL" | cut -d'|' -f8)"
has "and states the outcome" "8 tables, 173,745 rows" "$(sed -n 2p "$TBL" | cut -d'|' -f10)"
# Only the named row changes.
check "its neighbour is untouched" "idle" "$(sed -n 3p "$TBL" | cut -d'|' -f4)"

printf '\n== it draws square, at every width ==\n'

UI_FANCY=1
UI_BAR_FULL="$(printf '\xe2\x96\x88')"; UI_BAR_EMPTY="$(printf '\xe2\x96\x91')"
UI_VB="$(printf '\xe2\x94\x82')"; UI_HR="$(printf '\xe2\x94\x80')"
UI_TL="$(printf '\xe2\x95\xad')"; UI_TR="$(printf '\xe2\x95\xae')"
UI_BL="$(printf '\xe2\x95\xb0')"; UI_BR="$(printf '\xe2\x95\xaf')"
UI_TEE="$(printf '\xe2\x94\x9c\xe2\x94\x80')"; UI_CORNER="$(printf '\xe2\x94\x94\xe2\x94\x80')"
UI_TICK="$(printf '\xe2\x9c\x93')"
UI_PROGRESS_EIGHTHS=' ▏▎▍▌▋▊▉'
ui_table_set "$TBL" 3 running 42 88 12 "loading 1 data file"
for _w in 80 100 120; do
    OUT="$(COLUMNS=$_w ui_table_render "$TBL" 0)"
    # Every row of a table has to be the same width, or the right border walks.
    # _ui_visible_len prints WITHOUT a trailing newline, so the loop has to add
    # one or every row's width runs into the next.
    WIDTHS="$(printf '%s\n' "$OUT" | while IFS= read -r _l; do printf '%s\n' "$(_ui_visible_len "$_l")"; done | sort -u | grep -c .)"
    check "at $_w columns every row is one width" "1" "$WIDTHS"
    FITS="$(printf '%s\n' "$OUT" | while IFS= read -r _l; do printf '%s\n' "$(_ui_visible_len "$_l")"; done | sort -rn | sed -n 1p)"
    check "at $_w columns it fits the screen" "yes" \
        "$([ "$FITS" -le "$_w" ] && echo yes || echo "no: $FITS")"
done
# The status column must NOT change width when the last row finishes, or the
# whole table would jump at the end.
W_RUNNING="$(COLUMNS=110 ui_table_render "$TBL" 0 | sed -n 1p | wc -c)"
ui_table_set "$TBL" 3 done "" "" "" "" "completed · 2 tables, 108,050 rows (4s)"
W_DONE="$(COLUMNS=110 ui_table_render "$TBL" 0 | sed -n 1p | wc -c)"
check "the table does not resize when work finishes" "$W_RUNNING" "$W_DONE"

printf '\n== off a terminal it prints once and takes the defaults ==\n'

UI_FANCY=0
exakit_data_table_build "$TBL"
# NOT in $( ): the function reports through EXAKIT_TABLE_SELECTION, which a
# command substitution's subshell would throw away.
EXAKIT_TABLE_SELECTION=""
# A width the labels actually fit in: at 80 the name column shrinks to 24 and
# the assertion below would be measuring the truncation, not the printing.
COLUMNS=110
ui_table_menu "$TBL" > "$WORK/plain.out" 2>&1
PLAIN="$(cat "$WORK/plain.out")"
check "the selection is the defaults" "$EXAKIT_TABLE_DEFAULTS" "$EXAKIT_TABLE_SELECTION"
has "and the table was printed"       "TPC-H retail benchmark" "$PLAIN"
lacks "with no keyboard hint"         "Space to toggle"        "$PLAIN"

printf '\n== a byteless step is worth more than a share of the bytes ==\n'

# energy is the counter-example that broke this: 1,882 bytes of CSV and an
# 02_load_data.sql that GENERATES 108,000 readings. Five percent of 1,882 is 94,
# so the step that was the whole job got four percent of the bar, the upload
# segment capped at 86% and sat there.
check "a tiny dataset gets the floor"  "262144" "$(exakit_load_nominal 1882)"
check "so does an empty one"           "262144" "$(exakit_load_nominal 0)"
# A big one is still a share of itself, because there the files ARE the cost.
check "a big dataset scales with its bytes" "1083337" "$(exakit_load_nominal 21666755)"
check "the floor is the larger of the two" "yes" \
    "$([ "$(exakit_load_nominal 21666755)" -gt "$(exakit_load_nominal 1882)" ] && echo yes || echo no)"

# Measured on the datasets the kit actually ships: the generator-driven one must
# not hand its whole bar to an upload worth two kilobytes.
_wt_share() {   # _wt_share <dataset-dir> -> "<upload-pct> <script-pct>"
    _ws_b=0
    for _ws_f in "$1"/data/*.csv; do
        [ -s "$_ws_f" ] && _ws_b=$(( _ws_b + $(exakit_load_weight_of "$_ws_f") ))
    done
    _ws_n="$(exakit_load_nominal "$_ws_b")"
    _ws_t=$(( _ws_b + _ws_n + _ws_n ))
    [ -s "$1/02_load_data.sql" ]    && _ws_t=$(( _ws_t + _ws_n ))
    [ -s "$1/03_verify_setup.sql" ] && _ws_t=$(( _ws_t + _ws_n ))
    printf '%s %s\n' "$(( _ws_b * 100 / _ws_t ))" "$(( _ws_n * 100 / _ws_t ))"
}
set -- $(_wt_share "$ROOT/data/datasets/energy")
check "energy's uploads are almost nothing" "yes" "$([ "$1" -le 5 ] && echo yes || echo "no: $1%")"
check "and its scripts carry the bar"       "yes" "$([ "$2" -ge 15 ] && echo yes || echo "no: $2%")"
set -- $(_wt_share "$ROOT/data/datasets/tpch")
check "tpch's uploads still carry its bar"  "yes" "$([ "$1" -ge 70 ] && echo yes || echo "no: $1%")"

printf '\n== the label drops the estimate the Status column measures ==\n'

exakit_pending_datasets() {
    printf 'tpch|TPC-H retail benchmark (~175k rows)\nenergy|Smart-meter energy readings (time series, ~108k rows)\n'
}
exakit_data_table_build "$TBL"
check "the hint is gone"      "TPC-H retail benchmark"      "$(sed -n 2p "$TBL" | cut -d'|' -f2)"
check "...on every row"       "Smart-meter energy readings" "$(sed -n 3p "$TBL" | cut -d'|' -f2)"
# Only a TRAILING parenthetical goes: a name that legitimately contains brackets
# in the middle keeps them.
exakit_pending_datasets() { printf 'x|Orders (EU) by quarter\n'; }
exakit_data_table_build "$TBL"
check "brackets in the middle survive" "Orders (EU) by quarter" "$(sed -n 2p "$TBL" | cut -d'|' -f2)"

printf '\n== BOTH callers drive the table, not just the standalone one ==\n'

# This is the gap that shipped: exakit_data_load_menu started the table and the
# installer's own loop did not, so during an install the table drew, stayed
# empty, and every dataset fell back to the single-line bar underneath it. The
# install path is the one that matters and it was the one untested.
COMMON_SH="$(cat "$ROOT/setup/lib/common.sh")"
EXAPUMP_SH2="$(cat "$ROOT/setup/lib/exapump.sh")"
has "the standalone command starts it" 'ui_table_begin "$EXAKIT_TABLE_STATE"' "$EXAPUMP_SH2"
has "...and stops it"                  'ui_table_end "$EXAKIT_TABLE_STATE"'   "$EXAPUMP_SH2"
has "the installer offer starts it"    'ui_table_begin "$EXAKIT_TABLE_STATE"' "$COMMON_SH"
has "...and stops it"                  'ui_table_end "$EXAKIT_TABLE_STATE"'   "$COMMON_SH"
# A warning printed into a frame that is still being repainted lands inside the
# box, so the installer collects them and speaks after the table has stopped.
has "warnings wait for the table"      '_data_notes="${_data_notes}warn|'      "$COMMON_SH"
has "...and are said afterwards"       'EXAKIT_DATA_NOTES_EOF'                "$COMMON_SH"

printf '\n== under a REAL terminal, one table is left, not three ==\n'

# Everything above reads the state file or a captured string, and neither can see
# the bug that shipped twice: the table STACKED. The first stack was an animator
# whose opening frame printed instead of overwriting; the second was an animator
# killed part-way through a frame, after which every cursor-up landed inside the
# frame before it.
#
# Both are invisible without a terminal to be wrong in. tests/lib/tty-replay.py
# runs the scenario under a pty and replays the escape codes the way a terminal
# would — cursor-up, clear-to-end, carriage return — then asserts what is left on
# screen. It is the only test here that could have caught either.
if command -v python3 >/dev/null 2>&1; then
    if python3 "$ROOT/tests/lib/tty-replay.py" \
            "$ROOT/tests/lib/table-scenario.sh" "$ROOT" > "$WORK/tty.out" 2>&1; then
        check "exactly one table survives" "yes" "yes"
    else
        check "exactly one table survives" "yes" \
            "no: $(grep 'tables on screen' "$WORK/tty.out" || echo 'replay failed')"
    fi
    SCREEN="$(sed -n '/=== FINAL SCREEN ===/,/=== tables/p' "$WORK/tty.out")"
    has "and it is the finished one"  "173,745 rows" "$SCREEN"
    has "with every row accounted for" "10,970 rows" "$SCREEN"
    lacks "no half-drawn bar left behind" "loading 8 data files" "$SCREEN"
else
    check "exactly one table survives" "skipped" "skipped"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
