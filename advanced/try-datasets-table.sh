#!/usr/bin/env bash
# try-datasets-table.sh — the datasets table, from this checkout, with no
# database and no install.
#
#   bash advanced/try-datasets-table.sh
#
# It draws the real table with the real dataset labels, hands you the real
# selection menu (arrow keys, Space, Enter), and then animates a load whose
# timings are made up but whose PROGRESS ARITHMETIC is not — the same weights,
# the same creep, the same renderer the installer uses.
#
# For looking at the screen and nothing else: there is no Exasol here, nothing
# is written outside a temp directory, and the only thing being exercised is
# setup/lib/ui.sh and the table builder in setup/lib/exapump.sh.
#
# To drive the REAL thing against a real database instead, from this checkout:
#
#   bash setup/exakit data-load
#
# (setup/exakit prefers its own setup/lib, so that runs the code you are editing
# rather than the copy under ~/.exasol-starter-kit.)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; printf "\033[?25h"' EXIT INT TERM

# A sandboxed home, so nothing here can touch a real install.
export HOME="$WORK/home"
mkdir -p "$HOME"
EXAKIT_HOME="$WORK/kit"
EXAKIT_BIN_DIR="$WORK/bin"
mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"

# shellcheck source=/dev/null
. "$ROOT/setup/lib/ui.sh"
# shellcheck source=/dev/null
. "$ROOT/setup/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/setup/lib/exapump.sh"

EXAKIT_LOG_FILE="$WORK/log"
: > "$EXAKIT_LOG_FILE"

# The labels come from the datasets this checkout actually ships, so what you see
# is what an install would show — including anything you have just edited in a
# dataset.conf.
exakit_pending_datasets() {
    for _tt_conf in "$ROOT"/data/datasets/*/dataset.conf; do
        [ -f "$_tt_conf" ] || continue
        _tt_id="$(basename "$(dirname "$_tt_conf")")"
        _tt_label="$(sed -n 's/^label=//p' "$_tt_conf" | head -1)"
        printf '%s|%s\n' "$_tt_id" "${_tt_label:-$_tt_id}"
    done
}

printf '\n'
info "A preview of the datasets table. No database is involved."
info "Arrow keys or j/k to move, Space to toggle, Enter to start."

UI_TABLE_TITLE="Datasets to load"
STATE="$WORK/table"
exakit_data_table_build "$STATE"
printf '\n'
ui_table_menu "$STATE"

if [ "$EXAKIT_TABLE_SELECTION" = "none" ] || \
   case ",$EXAKIT_TABLE_SELECTION," in *",$EXAKIT_TABLE_ROW_SKIP,"*) true ;; *) false ;; esac; then
    info "Nothing selected — that is the Skip path."
    exit 0
fi

# Walk each ticked dataset through the stages a real load goes through, weighted
# the way a real load weights them: bytes for the files it ships, a floor for the
# steps that move no bytes. Only the sleeps are invented.
ui_table_begin "$STATE" || info "(not a terminal — printing one frame instead)"
_tt_row=0
while IFS= read -r _tt_id; do
    _tt_row=$(( _tt_row + 1 ))
    [ -n "$_tt_id" ] || continue
    [ "$_tt_id" = "local" ] && continue
    case ",$EXAKIT_TABLE_SELECTION," in *",$_tt_row,"*) ;; *) continue ;; esac
    _tt_dir="$ROOT/data/datasets/$_tt_id"
    [ -d "$_tt_dir" ] || continue

    _tt_bytes=0
    _tt_files=0
    for _tt_csv in "$_tt_dir"/data/*.csv; do
        [ -s "$_tt_csv" ] || continue
        _tt_bytes=$(( _tt_bytes + $(exakit_load_weight_of "$_tt_csv") ))
        _tt_files=$(( _tt_files + 1 ))
    done
    _tt_nom="$(exakit_load_nominal "$_tt_bytes")"
    _tt_total=$(( _tt_bytes + _tt_nom + _tt_nom ))
    [ -s "$_tt_dir/02_load_data.sql" ]    && _tt_total=$(( _tt_total + _tt_nom ))
    [ -s "$_tt_dir/03_verify_setup.sql" ] && _tt_total=$(( _tt_total + _tt_nom ))
    _tt_done=0
    _tt_schema="$(printf '%s' "$_tt_id" | tr '[:lower:]' '[:upper:]')"

    _tt_step() {   # _tt_step <weight> <secs> <phase> <sleep>
        _ts_pct=$(( _tt_done * 100 / _tt_total ))
        _ts_ceil=$(( (_tt_done + $1) * 100 / _tt_total ))
        [ "$_ts_ceil" -gt 100 ] && _ts_ceil=100
        ui_table_set "$STATE" "$_tt_row" running "$_ts_pct" "$_ts_ceil" "$2" "$_tt_id · $3"
        sleep "$4"
        _tt_done=$(( _tt_done + $1 ))
    }
    _tt_step "$_tt_nom" 3 "creating schema $_tt_schema" 1
    if [ "$_tt_files" -gt 0 ]; then
        _tt_step "$_tt_bytes" "$(exakit_load_secs_for "$_tt_bytes")" \
            "loading $_tt_files data file$([ "$_tt_files" = 1 ] || printf 's')" 3
    fi
    [ -s "$_tt_dir/02_load_data.sql" ]    && _tt_step "$_tt_nom" 30 "running load statements" 2
    [ -s "$_tt_dir/03_verify_setup.sql" ] && _tt_step "$_tt_nom" 10 "verifying" 1
    _tt_step "$_tt_nom" 5 "counting rows" 1

    _tt_tables=$(( _tt_files + 1 ))
    ui_table_set "$STATE" "$_tt_row" done "" "" "" "" \
        "completed · $_tt_tables tables, $(printf '%7s' "$(exakit_group_digits $(( _tt_bytes / 120 )))") rows $(printf '%5s' '(6s)')"
done <<TRY_IDS_EOF
$EXAKIT_TABLE_IDS
TRY_IDS_EOF
ui_table_end "$STATE"
printf '\n'
ok "That is the whole screen. Nothing was installed and no database was touched."
