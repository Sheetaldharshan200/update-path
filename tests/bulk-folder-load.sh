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
has "the summary counts them" "Loaded 4 file(s) into STARTER_KIT" "$OUT"

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
has "the failure names the file" "orders.parquet could not be loaded" "$OUT"
has "and the rest are counted" "Loaded 3 of 4 file(s)" "$OUT"
FAIL_ON=""

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
has "and the old variable no longer narrows anything" "Loaded 4 file(s)" "$OUT"

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
has "the shell says an add-on arrived"  'ok_step "JSON Tables installed'       "$EXAPUMP_SH_ALL"
has "...and so does Windows"            'OkStep "JSON Tables installed - the add-on that loads JSON into Exasol"' "$EXAPUMP_PS1"

# The comment that kept the refusal alive after the code outgrew it.
lacks "the stale claim is gone"         "Windows cannot run the"               "$EXAPUMP_PS1"
# ...and the advice no longer names three platforms, one of which is this one.
lacks "no misleading platform list"     "load it from macOS, Linux or WSL"     "$EXAPUMP_PS1"

# What the prompt offers is what it accepts.
has "the prompt offers JSON"            "Local CSV / Parquet / JSON file"      "$EXAPUMP_PS1"
has "...and so does the remote one"     "Remote CSV / Parquet / JSON URL"      "$EXAPUMP_PS1"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
