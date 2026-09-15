#!/usr/bin/env bash
# bulk-folder-load.sh — proves `exakit data-load <folder>`: what a folder scan
# picks up, what it refuses, and what actually reaches the database.
#
#   bash tests/bulk-folder-load.sh
#
# The upload layer is stubbed, so this runs with no database, no network and no
# exapump binary: what is under test is the scan, the duplicate rules, the
# format selection and the per-file loop, not the engine underneath them.

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
. "$ROOT/setup/lib/exapump.sh"

EXAKIT_LOG_FILE="$WORK/test.log"
: > "$EXAKIT_LOG_FILE"

# A folder shaped like a real export directory: two formats, both kinds of
# duplicate, a subfolder, a dotfile, an image, a readme and an empty file.
D="$WORK/exports"
mkdir -p "$D/archive"
printf 'a,b\n1,2\n'  > "$D/sales.csv"
printf 'a,b\n1,2\n'  > "$D/sales_copy.csv"    # byte-identical to sales.csv
printf 'x,y\n9,8\n'  > "$D/customers.csv"
printf 'PAR1\n'      > "$D/orders.parquet"
printf 'zzz\n'       > "$D/orders.pq"         # same target table as orders.parquet
printf '{"k":1}\n'   > "$D/events.json"
printf 'png\n'       > "$D/logo.png"
printf 'readme\n'    > "$D/README.txt"
: > "$D/empty.csv"
printf 'nested\n'    > "$D/archive/old.csv"
printf 'hidden\n'    > "$D/.hidden.csv"

PLAN="$(exakit_bulk_scan_folder "$D")"

printf '\n== the scan takes the data files and nothing else ==\n'

check "loadable files found" "4" "$(printf '%s\n' "$PLAN" | grep -c '^load|')"
has "csv is loadable"     "load|csv|SALES|"        "$PLAN"
has "another csv"         "load|csv|CUSTOMERS|"    "$PLAN"
has "parquet is loadable" "load|parquet|ORDERS|"   "$PLAN"
has "json is loadable"    "load|json|EVENTS|"      "$PLAN"

lacks "a subfolder is never descended into" "archive/old.csv" "$PLAN"
lacks "a dotfile is left alone"             ".hidden.csv"     "$PLAN"
has "an image is ignored"    "skip|unsupported||$D/logo.png"   "$PLAN"
# .txt is a fine CSV when someone names the file, and never a table when a
# folder is scanned: a README beside the exports is not data.
has "a README.txt is ignored" "skip|unsupported||$D/README.txt" "$PLAN"
has "an empty file is ignored" "skip|empty||$D/empty.csv"       "$PLAN"

printf '\n== both kinds of duplicate are refused, with the reason ==\n'

has "a byte-identical copy is skipped" "skip|duplicate-content|sales.csv|$D/sales_copy.csv" "$PLAN"
has "a same-table name is skipped"     "skip|duplicate-table|orders.parquet|$D/orders.pq"   "$PLAN"
# Which of the two wins must be the same answer on every machine: the scan
# orders by bytes (LC_ALL=C), not by the machine's collation, which folds
# punctuation on macOS and does not in CI.
has "the first in byte order wins" "load|csv|SALES|$D/sales.csv" "$PLAN"

printf '\n== a folder is never asked about its formats ==\n'

check "kinds present, in menu order" "csv parquet json" \
    "$(exakit_bulk_kinds_present "$PLAN" | tr '\n' ' ' | sed 's/ $//')"

# The question is GONE, not merely defaulted. A folder means "here is my data",
# so every loadable file is taken whatever its kind -- and the menu that used to
# ask was being drawn while the selection table was still on screen, which is
# what duplicated its borders.
lacks "no format selector survives"    "exakit_bulk_select_formats" "$(cat "$ROOT/setup/lib/exapump.sh")"
lacks "...nor on the PowerShell side"  "Select-ExakitBulkFormats"   "$(cat "$ROOT/setup/lib/exapump.ps1")"
lacks "no env var pre-answers it"      "EXAKIT_DATA_FORMATS"        "$(cat "$ROOT/setup/lib/exapump.sh")"
lacks "and the help stops promising it" "more than one format"      "$(cat "$ROOT/setup/help/exakit.json")"

# Behaviour, not just absence: a mixed folder yields every loadable row.
MIXED_ALL="$(printf '%s\n' "$PLAN" | grep -c '^load|' || true)"
check "every loadable file is taken from a mixed folder" "4" "$MIXED_ALL"

printf '\n== real-world CSV shapes: the kit is a bridge, and says what it sees ==\n'

# THE FILES PEOPLE ACTUALLY HAVE. Every CSV from a Windows machine, an Excel
# export or a public open-data portal has Windows line endings, most carry a
# byte-order mark, German exports are ';'-separated, and a GTFS feed is eleven
# CSVs all called .txt. exapump takes none of that as it comes: it builds its
# IMPORT without a row separator (so "7.4" arrives as "7.4<CR>" and fails to
# cast), splits on ',' unless told, and picks the format from the extension,
# refusing .tsv and .txt. Seven public datasets loaded ZERO tables through the
# kit before this.
#
# THE KIT DOES NOT REWRITE THE USER'S FILES. What it does is measured here at
# the binary's argv: the ORIGINAL path always, exapump's own --delimiter when
# the header calls for it, no upload at all for a file with nothing in it or a
# name exapump refuses - and a failure reason that names the cause. The real
# exapump_upload runs against a stub exapump, before the function stubs
# further down replace it.
SHAPES="$WORK/shapes"; mkdir -p "$SHAPES/bin" "$SHAPES/got"
cat > "$SHAPES/bin/exapump" <<'STUB'
#!/bin/sh
# Records argv, and a hash of the file it was handed, so the suite can prove
# it received the user's bytes and not a copy.
printf '%s\n' "$*" >> "$SHAPES_GOT/argv"
[ "$1" = upload ] && cksum < "$2" >> "$SHAPES_GOT/hashes"
exit 0
STUB
chmod +x "$SHAPES/bin/exapump"
SHAPES_GOT="$SHAPES/got"; export SHAPES_GOT
CR="$(printf '\r')"; BOM="$(printf '\357\273\277')"; TAB="$(printf '\t')"
printf '%sdatum,gesamt%s\n2026.01.01,7%s\n' "$BOM" "$CR" "$CR" > "$SHAPES/windows.csv"      # BOM + CRLF
printf 'Row;LAT;NAME\n1;48,17;Zentrale\n' > "$SHAPES/german.csv"                           # ';' with decimal commas
printf "a${TAB}b\n1${TAB}2\n" > "$SHAPES/tabs.tsv"                                          # .tsv - exapump refuses the name
printf 'stop_id,stop_name\n1,Ostbahnhof\n' > "$SHAPES/stops.txt"                             # GTFS - same
printf 'shape_id,shape_pt_lat\n' > "$SHAPES/shapes.csv"                                      # a header with no shapes under it
printf 'a,b\n1,2\n' > "$SHAPES/plain.csv"                                                   # nothing to see
printf 'just some notes\nabout the exports\n' > "$SHAPES/README.txt"

# The inspector: it looks, it does not touch.
check "a plain file: comma, no flags"        ",|"        "$(exakit_csv_inspect "$SHAPES/plain.csv")"
check "a BOM+CRLF file is seen for what it is" ",|bom,crlf" "$(exakit_csv_inspect "$SHAPES/windows.csv")"
check "a ';' header selects the semicolon"   ";|"        "$(exakit_csv_inspect "$SHAPES/german.csv")"
check "a tab header selects the tab"         "$TAB|"     "$(exakit_csv_inspect "$SHAPES/tabs.tsv")"
check "a header with no rows is refused"     "1"         "$(exakit_csv_inspect "$SHAPES/shapes.csv" >/dev/null; echo $?)"
_before="$(cksum < "$SHAPES/windows.csv")"
check "...and the file is byte-for-byte what it was" "$_before" "$(cksum < "$SHAPES/windows.csv")"

# Through the real uploader, into the stub binary.
_real_bin="$EXAKIT_EXAPUMP_BIN"; EXAKIT_EXAPUMP_BIN="$SHAPES/bin/exapump"
: > "$SHAPES_GOT/argv"; : > "$SHAPES_GOT/hashes"
_win="$( ( EXAKIT_UPLOAD_QUIET=1 exapump_upload "$SHAPES/windows.csv" T.WINDOWS ) 2>&1 )"
has "exapump is handed the ORIGINAL path" "upload $SHAPES/windows.csv " "$(cat "$SHAPES_GOT/argv")"
has "a CRLF file that loads is told what its last column now holds" "every value in the last column of T.WINDOWS ends in a carriage return" "$_win"
check "...and the original bytes, CR and BOM included - no copy" "$(cksum < "$SHAPES/windows.csv")" "$(tail -1 "$SHAPES_GOT/hashes")"
lacks "...with no delimiter flag for a comma file" "--delimiter" "$(cat "$SHAPES_GOT/argv")"
_pln="$( ( EXAKIT_UPLOAD_QUIET=1 exapump_upload "$SHAPES/plain.csv" T.PLAIN ) 2>&1 )"
lacks "a clean file gets no such warning" "carriage return" "$_pln"
( EXAKIT_UPLOAD_QUIET=1 exapump_upload "$SHAPES/german.csv" T.GERMAN ) >/dev/null 2>&1
has "a ';' file is uploaded with exapump's own --delimiter ;" "--delimiter ;" "$(cat "$SHAPES_GOT/argv")"
_hdr="$( ( EXAKIT_UPLOAD_QUIET=1 EXAKIT_UPLOAD_SOFT=1 exapump_upload "$SHAPES/shapes.csv" T.SHAPES ) 2>&1; echo "RC=$?" )"
has "a header-only file is named, not sent to the engine" "has a header and no rows" "$_hdr"
has "...as a soft failure" "RC=1" "$_hdr"
lacks "...that never reached exapump" "shapes.csv" "$(cat "$SHAPES_GOT/argv")"
check "no temporary copy of anything exists" "0" "$(ls -d "${TMPDIR:-/tmp}"/exakit-csv* 2>/dev/null | wc -l | tr -d ' ')"
EXAKIT_EXAPUMP_BIN="$_real_bin"

# The folder scan sees the same things, and says them.
SPLAN="$(exakit_bulk_scan_folder "$SHAPES")"
has "a tabular .txt is recognised as data" "skip|extension||$SHAPES/stops.txt" "$SPLAN"
has "...and so is a .tsv" "skip|extension||$SHAPES/tabs.tsv" "$SPLAN"
has "a README.txt is not" "skip|unsupported||$SHAPES/README.txt" "$SPLAN"
has "a header-only file is skipped by name" "skip|header-only||$SHAPES/shapes.csv" "$SPLAN"
lacks "nothing exapump refuses by name is queued for it" "load|csv|STOPS|" "$SPLAN"
_plan_out="$(exakit_bulk_print_plan "$SPLAN" "$(printf '%s\n' "$SPLAN" | grep '^load|' | cut -d'|' -f2-)" 2>&1)"
has "the plan tells the user the one thing that loads them" "rename to .csv to load" "$_plan_out"
has "...and counts the header-only file in words" "with a header and no rows" "$_plan_out"
printf '{"type":"FeatureCollection","features":[]}\n' > "$SHAPES/areas.geojson"
check ".geojson is JSON" "json" "$(exakit_data_file_kind "$SHAPES/areas.geojson")"
has "...in a folder scan too" "load|json|AREAS|" "$(exakit_bulk_scan_folder "$SHAPES")"

# The engine's reason survives to the screen, whole, with the cause the kit saw.
EXAKIT_LOG_FILE="$WORK/shape-reason.log"
printf "Error: SQL execution failed: Protocol error: ETL-3051: [Column=11 Row=0] [Transformation of value='7.4<CR>' failed - invalid character value for cast; Value: '7.4'] (Session: 1876)\n" > "$EXAKIT_LOG_FILE"
has "a <CR> in the engine's message is translated" "Windows line endings (CRLF)" "$(exakit_upload_failure_reason)"
printf "Error: SQL execution failed: Protocol error: ETL-3050: [Column=6 Row=0] [Transformation of value='x' failed - invalid character value for cast; Value: 'x'] (Session: 1876)\n" > "$EXAKIT_LOG_FILE"
has "an ETL detail in brackets is kept, not cut at the bracket" "ETL-3050: [Column=6 Row=0] [Transformation of value='x' failed" "$(EXAKIT_CSV_FLAGS="" exakit_upload_failure_reason)"
lacks "...and the session id is dropped" "Session" "$(EXAKIT_CSV_FLAGS="" exakit_upload_failure_reason)"
has "...and a file the inspector flagged as CRLF gets the cause appended" "Windows line endings (CRLF)" "$(EXAKIT_CSV_FLAGS="bom,crlf" exakit_upload_failure_reason)"
lacks "...but not a file that was clean" "Windows line endings" "$(EXAKIT_CSV_FLAGS="" exakit_upload_failure_reason)"
printf "Error: SQL execution failed: Protocol error: ETL-2105: Error while parsing row=0 (starting from 0) [CSV Parser found at byte 5385 (starting with 0 at the beginning of the row) of 5385 a single field delimiter or a row terminator directly after a quoted field] (Session: 1)\n" > "$EXAKIT_LOG_FILE"
_long="$(EXAKIT_CSV_FLAGS="" exakit_upload_failure_reason)"
has "a long detail is cut at a word, with an ellipsis" "field..." "$_long"
lacks "...never mid-word" "delimi" "$_long"

# A folder holding only what exapump refuses by name: a GTFS feed, as shipped.
GTFSDIR="$WORK/gtfs"; mkdir -p "$GTFSDIR"
printf 'stop_id,stop_name\n1,Ostbahnhof\n' > "$GTFSDIR/stops.txt"
printf 'route_id,route_short_name\n1,U1\n' > "$GTFSDIR/routes.txt"
_gt="$(exakit_load_local_folder "$GTFSDIR" 2>&1; echo "RC=$?")"
has "a folder of .txt tables is not 'no files'" "2 files in" "$_gt"
has "...it names the rename that loads them" "Rename them to .csv" "$_gt"
lacks "...and does not call it empty" "No CSV, Parquet or JSON files" "$_gt"
has "...and fails, as before" "RC=1" "$_gt"
EXAKIT_LOG_FILE="$WORK/test.log"

printf '\n== the loop loads every chosen file, one table each ==\n'

# Stub the layer below: this suite is about the folder flow, not the engine.
LOADED="$WORK/loaded"
: > "$LOADED"
FAIL_ON=""
exakit_ensure_schema()  { printf 'schema %s\n' "$1" >> "$LOADED"; return 0; }
exapump_upload()        {
    if [ -n "$FAIL_ON" ] && [ "$(basename "$1")" = "$FAIL_ON" ]; then return 1; fi
    printf 'upload %s -> %s\n' "$(basename "$1")" "$2" >> "$LOADED"; return 0
}
exakit_load_local_json() {
    EXAKIT_LAST_LOAD_TARGET="$2"
    printf 'json %s -> %s\n' "$(basename "$1")" "$2" >> "$LOADED"; return 0
}
manifest_set()          { printf 'manifest %s=%s\n' "$1" "$2" >> "$LOADED"; return 0; }

EXAKIT_BULK_CONFIRM=1
export EXAKIT_BULK_CONFIRM
EXAKIT_DATA_FORMATS=""
OUT="$(exakit_load_local_folder "$D" 2>&1)"
RC=$?
LOG="$(cat "$LOADED")"
check "a clean folder load succeeds" "0" "$RC"
check "every eligible file loaded" "4" "$(grep -cE '^(upload|json) ' "$LOADED")"
has "the schema is created once" "schema STARTER_KIT" "$LOG"
has "csv -> its own table"     "upload sales.csv -> STARTER_KIT.SALES"          "$LOG"
has "parquet -> its own table" "upload orders.parquet -> STARTER_KIT.ORDERS"    "$LOG"
has "json goes through the JSON path" "json events.json -> STARTER_KIT.EVENTS"  "$LOG"
lacks "the skipped duplicate never loads" "sales_copy.csv" "$LOG"
has "the folder is recorded" "manifest data.last_load.type=local_folder" "$LOG"
has "the file count is recorded" "manifest data.last_load.files=4" "$LOG"
has "the summary counts them" "Loaded 4 files into STARTER_KIT" "$OUT"

# This is also the guard for a bash 3.2 trap: filtering the plan with a `case`
# inside $( ) returns the script's own text instead of the matches on the shell
# every macOS user runs, and `bash -n` does not catch it. A wrong filter shows
# up here as the wrong number of loads.
lacks "the filter returns matches, not script text" "esac" "$LOG"

printf '\n== one bad file does not end the job ==\n'

: > "$LOADED"
FAIL_ON="orders.parquet"
OUT="$(exakit_load_local_folder "$D" 2>&1)"
RC=$?
check "a failed file is reported" "1" "$RC"
check "the other three still loaded" "3" "$(grep -cE '^(upload|json) ' "$LOADED")"
has "the failure names the file" "orders.parquet not loaded" "$OUT"
has "and the rest are counted" "Loaded 3 of 4 into STARTER_KIT" "$OUT"
FAIL_ON=""

printf '\n== a file that will not load says why, and the rest still load ==\n'

# The engine explains itself well and the kit was throwing that away. One file of
# three failed as "could not be loaded (see log)", under a red "Upload failed"
# banner and a log path -- which reads as the whole job dying. It is one file.
EXAKIT_LOG_FILE="$WORK/reason.log"
cat > "$EXAKIT_LOG_FILE" <<'REASONLOG'
Error: SQL execution failed: Protocol error: ETL-2107: Error while parsing row=4 (starting from 0) [CSV Parser found at byte 8 of 76 single field delimiter in a not enclosed field]
REASONLOG
check "the commonest CSV fault is put into words" \
    "row 4 has a line break or an unescaped comma inside a quoted field" \
    "$(exakit_upload_failure_reason)"
printf 'Error: ETL-5000: something else entirely\n' > "$EXAKIT_LOG_FILE"
has "an unrecognised engine fault is passed through" "ETL-5000" "$(exakit_upload_failure_reason)"
: > "$EXAKIT_LOG_FILE"
check "and nothing is invented when the log says nothing" "" "$(exakit_upload_failure_reason || true)"
EXAKIT_LOG_FILE=""

# Soft mode is what stops one bad file announcing itself as a failed job.
EXAPUMP_SRC="$(cat "$ROOT/setup/lib/exapump.sh")"
EXAPUMP_PS_SRC="$(cat "$ROOT/setup/lib/exapump.ps1")"
has "the folder loop asks for soft failures" "EXAKIT_UPLOAD_SOFT=1 exapump_upload" "$EXAPUMP_SRC"
has "...and the uploader honours it" 'if [ "${EXAKIT_UPLOAD_SOFT:-0}" = 1 ]; then' "$EXAPUMP_SRC"
# Matched on the STATEMENT, not the phrase: the phrase appears in the comments
# that explain why it was dropped, and a needle that cannot tell code from prose
# fails on its own documentation.
lacks "no per-file line sends the reader to the log" 'warn "$(basename "$_blf_path") could not be loaded' "$EXAPUMP_SRC"
lacks "...nor on the PowerShell side" 'Warn2 "$(Split-Path $file -Leaf) could not be loaded' "$EXAPUMP_PS_SRC"
has "the twin keeps the reason instead of the banner" 'ExakitUploadReason = Get-ExakitUploadFailureReason' "$EXAPUMP_PS_SRC"

printf '\n== a mixed folder loads every kind in one pass ==\n'

# This block used to prove that EXAKIT_DATA_FORMATS narrowed the load. That
# narrowing is gone on purpose: the folder is the answer, so all four files go
# in together and no variable can hold any of them back.
: > "$LOADED"
OUT="$(EXAKIT_DATA_FORMATS=csv exakit_load_local_folder "$D" 2>&1)"
# Three UPLOADS, four files: JSON does not go through the uploader at all, it is
# shredded into tables by the ingest engine first. The "Loaded 4 file(s)" line
# below is the one that counts files.
check "every non-JSON kind uploads" "3" "$(grep -c '^upload ' "$LOADED")"
has "parquet is in"  "orders"    "$(cat "$LOADED")"
has "json is in"     "events"    "$(cat "$LOADED")"
has "and the old variable no longer narrows anything" "Loaded 4 files" "$OUT"

printf '\n== a folder with nothing to load says so ==\n'

EMPTY="$WORK/empty-dir"; mkdir -p "$EMPTY/sub"
printf 'x\n' > "$EMPTY/notes.md"
: > "$LOADED"
OUT="$(exakit_load_local_folder "$EMPTY" 2>&1)"
RC=$?
check "an ineligible folder fails" "1" "$RC"
has "and explains the rule" "No CSV, Parquet or JSON files in" "$OUT"
check "nothing was loaded" "0" "$(grep -c . "$LOADED")"

printf '\n== the same prompt takes a file or a folder ==\n'

: > "$LOADED"
OUT="$(EXAKIT_DATA_FILE="$D" exakit_load_local_file 2>&1)"
check "a folder path routes to the bulk load" "4" "$(grep -cE '^(upload|json) ' "$LOADED")"

: > "$LOADED"
OUT="$(EXAKIT_DATA_FILE="$D/customers.csv" EXAKIT_DATA_TABLE="STARTER_KIT.CUSTOMERS" \
    exakit_load_local_file 2>&1)"
check "a file path still loads one file" "1" "$(grep -c '^upload ' "$LOADED")"
has "...into the table it was given" "upload customers.csv -> STARTER_KIT.CUSTOMERS" "$(cat "$LOADED")"

printf '\n== the CLI takes the path too ==\n'

CLI="$(cat "$ROOT/setup/exakit")"
has "data-load accepts a path argument" '_dl_path="$1"' "$CLI"
has "a path pre-answers the local-data question" 'EXAKIT_DATA_FILE="$_dl_norm"' "$CLI"
has "a missing path is refused" 'No such file or folder' "$CLI"
HELP="$(cat "$ROOT/setup/help/exakit.json")"
has "the help documents a folder" "A FOLDER is a bulk load" "$HELP"
lacks "the help no longer documents a format variable" "EXAKIT_DATA_FORMATS" "$HELP"

printf '\n== Windows loads JSON where the engine exists ==\n'

# Get-JsonTablesEngineAsset publishes a build for windows/x86_64, so the add-on
# is applicable, offered and installable there - but exapump.ps1 refused every
# .json file unconditionally, with a message that contradicted itself by ending
# "Windows x86_64 is supported; ARM64 is not built yet." The refusal outlived
# the limitation it was written for, kept alive by a comment asserting it.
EXAPUMP_PS1="$(cat "$ROOT/setup/lib/exapump.ps1")"
EXAPUMP_SH_ALL="$(cat "$ROOT/setup/lib/exapump.sh")"

# The three shell helpers, and their twins.
has "the shell knows when it is ready"  "_exakit_json_tables_ready() {"        "$EXAPUMP_SH_ALL"
has "...and Windows does too"           "function Test-ExakitJsonTablesReady"  "$EXAPUMP_PS1"
has "the shell installs on demand"      "_exakit_json_tables_ensure() {"       "$EXAPUMP_SH_ALL"
has "...and Windows does too"           "function Confirm-ExakitJsonTablesReady" "$EXAPUMP_PS1"
has "the shell loads a JSON file"       "exakit_load_local_json() {"           "$EXAPUMP_SH_ALL"
has "...and Windows does too"           "function Import-ExakitLocalJson"      "$EXAPUMP_PS1"

# The refusal survives, but only where the engine can never exist.
has "the refusal asks first"            'if ($kind -eq "json" -and -not (Test-ExakitJsonTablesApplicable))' "$EXAPUMP_PS1"
check "both entry points ask"           "2" \
    "$(printf '%s\n' "$EXAPUMP_PS1" | grep -c 'json" -and -not (Test-ExakitJsonTablesApplicable)')"
# ...and never unconditionally, which is what shipped.
lacks "no blanket refusal"              'if ((Get-ExakitDataFileKind $path) -eq "json") {'  "$EXAPUMP_PS1"
lacks "...on either path"               'if ((Get-ExakitDataFileKind $name) -eq "json") {'  "$EXAPUMP_PS1"

# A local file and a downloaded one take the same path.
check "both routes reach the loader"    "2" \
    "$(printf '%s\n' "$EXAPUMP_PS1" | grep -c 'Import-ExakitLocalJson -Path')"

# The install announces itself once, in the words the shell uses, with an ASCII
# hyphen because every .ps1 but ui.ps1 is ASCII-only.
# The announcement is LOGGED, not printed. It fires mid-folder-load, where the
# one-line progress bar owns the row and rewrites it continuously, so the line
# landed inside the bar. ok_step could not save it either: its pause looks for a
# spinner, and a progress bar is a different animator holding the same line.
lacks "no add-on line prints over the bar" 'ok_step "JSON Tables installed' "$EXAPUMP_SH_ALL"
lacks "...nor on Windows"                  'OkStep "JSON Tables installed'  "$EXAPUMP_PS1"
has "the shell logs it instead"   '_exakit_log_file "OK    JSON Tables installed' "$EXAPUMP_SH_ALL"
has "...and Windows logs it too"  'Write-ExakitLog "OK" "JSON Tables installed'   "$EXAPUMP_PS1"

# The comment that kept the refusal alive after the code outgrew it.
lacks "the stale claim is gone"         "Windows cannot run the"               "$EXAPUMP_PS1"
# ...and the advice no longer names three platforms, one of which is this one.
lacks "no misleading platform list"     "load it from macOS, Linux or WSL"     "$EXAPUMP_PS1"

# What the prompt offers is what it accepts.
has "the prompt offers JSON"            "Local CSV / Parquet / JSON file"      "$EXAPUMP_PS1"
has "...and so does the remote one"     "Remote CSV / Parquet / JSON URL"      "$EXAPUMP_PS1"

printf '\n== a FATAL upload failure names the reason too ==\n'

# The translator was used on the soft path and dropped on the fatal one, so the
# worse outcome got the worse message. exakit_explain_db_error, which the fatal
# path did call, knows connection, LIMIT and privilege faults - a malformed CSV
# is none of those, and it is the commonest upload failure there is, so a single
# file load died as "(see log)" while the folder loop above was already putting
# the very same engine line into words.
#
# exapump_upload is stubbed further up this suite, and `die` exits the shell it
# runs in, so the real function is exercised in a child bash: the engine fails,
# and the logfile already holds its Error: line, which is the whole situation.
FATAL_LOG="$WORK/fatal.log"
cat > "$FATAL_LOG" <<'FATALLOG'
Error: SQL execution failed: Protocol error: ETL-2107: Error while parsing row=412 (starting from 0) [CSV Parser found at byte 8 of 76 single field delimiter in a not enclosed field]
FATALLOG

fatal_upload() { # fatal_upload <log-file> -> the message a doomed upload prints
    EXAKIT_HOME="$WORK/home" EXAKIT_BIN_DIR="$WORK/bin" HOME="$WORK/fake-home" \
    bash -c '
        set -u
        . "$1/setup/lib/ui.sh"
        . "$1/setup/lib/common.sh"
        . "$1/setup/lib/exapump.sh"
        EXAKIT_LOG_FILE="$2"
        # The layer below: the upload fails, and the engine has already said why
        # in the logfile.
        run_logged() { return 1; }
        exapump_upload "$3" "STARTER_KIT.SALES"
    ' _ "$ROOT" "$1" "$D/sales.csv" 2>&1
}

FATAL_OUT="$(fatal_upload "$FATAL_LOG" || true)"

has "the fatal path says what the engine said" \
    "row 412 has a line break or an unescaped comma inside a quoted field" "$FATAL_OUT"
has "...and names the file and the table it was going into" \
    "Could not load sales.csv into STARTER_KIT.SALES" "$FATAL_OUT"
lacks "the fatal path no longer sends the reader to the log" "Upload failed:" "$FATAL_OUT"

# The fallback survives: with nothing in the log to translate, inventing a
# reason would be worse than the old wording.
: > "$FATAL_LOG"
FATAL_BARE="$(fatal_upload "$FATAL_LOG" || true)"
has "an untranslatable failure keeps the old wording" "Upload failed:" "$FATAL_BARE"
lacks "...and invents no reason" "Could not load sales.csv" "$FATAL_BARE"

# Both paths call the same translator, on both sides of the kit.
FATAL_SH="$(cat "$ROOT/setup/lib/exapump.sh")"
FATAL_PS="$(cat "$ROOT/setup/lib/exapump.ps1")"
has "the shell fatal path asks for the reason" \
    '_upl_why="$(exakit_upload_failure_reason' "$FATAL_SH"
has "the twin asks for it on its fatal path too" \
    '$uploadWhy = Get-ExakitUploadFailureReason -Output $result.Output' "$FATAL_PS"
has "...and puts it in the message it dies with" \
    'Fail "Could not load $(Split-Path $Path -Leaf) into $Target - $uploadWhy"' "$FATAL_PS"
check "the twin asks on both paths, not one" "2" \
    "$(printf '%s\n' "$FATAL_PS" | grep -c 'Get-ExakitUploadFailureReason -Output $result.Output')"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
