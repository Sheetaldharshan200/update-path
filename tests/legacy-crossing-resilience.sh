#!/usr/bin/env bash
# legacy-crossing-resilience.sh — the crossing from a container database onto
# Exasol Personal, under every fault the road can throw at it.
#
#   bash tests/legacy-crossing-resilience.sh
#
# tests/legacy-crossing.sh pins WHAT the crossing decides. This suite pins what
# it does when the things it depends on misbehave: an engine that hangs,
# refuses, or loses the container between two calls; a database that has no
# password on file, never answers, answers late, or has nothing in it; a copy
# that fails for some tables, or all of them, or cannot even make its
# directory; a restore that finds files missing, tables taken, uploads
# refused; a run that dies between the two halves and comes back. In every one
# of those the install must go on, nothing of the user's may be destroyed, the
# question must be asked at most once, and the manifest must tell the truth.
#
# Both stubs are fault-injection programs in tests/lib/, driven by plain files
# in a per-scenario control directory - one engine, one exapump, no per-test
# rewrites. The engine is named `fakeengine`, which exists nowhere but the
# sandbox; exapump is reached through EXAKIT_EXAPUMP_BIN AND PATH, so no fix in
# the kit is the only thing between this suite and a real database.
#
# Every run is traced, and the suite ends by measuring how much of
# setup/lib/legacy-crossing.sh it walked. The floor is a gate, not a note.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib/line-coverage.sh"

PASS=0; FAIL=0
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s = %s\n' "$1" "$3"
    else FAIL=$((FAIL+1)); printf '  FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"; fi
}
has()   { case "$3" in *"$2"*) check "$1" present present ;; *) check "$1" present MISSING ;; esac; }
lacks() { case "$3" in *"$2"*) check "$1" absent PRESENT ;;  *) check "$1" absent absent ;;   esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/exakit-legacy-res.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
TRACE="$WORK/trace"; : > "$TRACE"
SCREENS="$WORK/screens"; : > "$SCREENS"

# The developer's real exapump config must come out of this untouched. Its
# hash is taken now and compared at the end; every run below points the kit at
# a config directory inside the sandbox.
REAL_EXAPUMP_CONFIG="$HOME/.exapump/config.toml"
_hash() { [ -f "$1" ] && cksum < "$1" || printf 'absent'; }
REAL_CONFIG_BEFORE="$(_hash "$REAL_EXAPUMP_CONFIG")"

# --- the two stubs ------------------------------------------------------------
# Two directories, so a scenario can take exapump off PATH and keep the engine.
STUB="$WORK/stub"; mkdir -p "$STUB/engine" "$STUB/exapump"
cp "$ROOT/tests/lib/legacy-fault-engine.sh"  "$STUB/engine/fakeengine"
cp "$ROOT/tests/lib/legacy-fault-exapump.sh" "$STUB/exapump/exapump"
chmod +x "$STUB/engine/fakeengine" "$STUB/exapump/exapump"

PASSWORD="legacysecret-Zq7"

# seed <dir> — a kit home holding what an OLDER kit recorded. Knobs are
# environment variables so a scenario reads as a sentence:
#   SEED_TYPE=personal        the runtime the record names        (nano)
#   SEED_NO_PASSWORD=1        no password file at all
#   SEED_EMPTY_PASSWORD=1     a password file with nothing in it
#   SEED_NO_DSN=1             no runtime.dsn
#   SEED_NO_CONTAINER=1       no runtime.container
#   SEED_NO_VOLUME=1          no runtime.volume
#   SEED_ENGINE=<name>        the recorded engine                 (fakeengine)
seed() {
    _s="$1"; mkdir -p "$_s/credentials" "$_s/ctrl" "$_s/bin" "$_s/exapump"
    _pw="$_s/credentials/nano_sys_password"
    if [ "${SEED_NO_PASSWORD:-0}" != 1 ]; then
        if [ "${SEED_EMPTY_PASSWORD:-0}" = 1 ]; then : > "$_pw"; else printf '%s\n' "$PASSWORD" > "$_pw"; fi
        chmod 600 "$_pw"
    fi
    _rt='"type": "'"${SEED_TYPE:-nano}"'", "engine": "'"${SEED_ENGINE:-fakeengine}"'", "user": "sys", "status": "healthy", "image": "docker.io/exasol/nano:2026.2.0-nano.2"'
    [ "${SEED_NO_CONTAINER:-0}" = 1 ] || _rt="$_rt"', "container": "exasol-nano"'
    [ "${SEED_NO_VOLUME:-0}" = 1 ]    || _rt="$_rt"', "volume": "exasol-nano-data"'
    [ "${SEED_NO_DSN:-0}" = 1 ]       || _rt="$_rt"', "dsn": "127.0.0.1:8563"'
    _rt="$_rt"', "password_file": "'"$_pw"'"'
    printf '{"manifest_version": 1, "kit_level": 1,\n "kit": {"version": "0.1.0", "source": "exasol-labs/exasol-personal-local-starterkit@0.1.0"},\n "runtime": {%s},\n "steps_completed": ["runtime"]}\n' "$_rt" > "$_s/manifest.json"
    # A healthy old database unless a scenario says otherwise: three tables in
    # two schemas, with column types the DDL builder has to carry across.
    printf 'S1.T1\nS1.T2\nS2.T3\n' > "$_s/ctrl/db.tables"
    printf 'S1.T1|ID<<:>>DECIMAL(18,0)\nS1.T1|NAME<<:>>VARCHAR(25) UTF8\nS1.T2|WHEN_TS<<:>>TIMESTAMP WITH LOCAL TIME ZONE\nS2.T3|my col<<:>>DOUBLE\n' > "$_s/ctrl/db.columns"
}
fault() { printf '%s' "$3" > "$1/ctrl/$2"; }        # fault <home> <file> <value>

# A PATH with no exapump on it, for the one scenario that takes the stub away:
# the developer's real binary must not step in and read a real database.
PATH_WITHOUT_EXAPUMP="$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r _d; do
    [ -n "$_d" ] && [ ! -x "$_d/exapump" ] && printf '%s:' "$_d"; done | sed 's/:$//')"

# run <home> <env> <body> — the module against <home>, with <env> (a string of
# VAR=value words) in force and <body> as the statements. The scenario's
# variables come LAST so they outrank the defaults. Traced through the coverage
# helper; the stamps go to $TRACE, the rest to stdout and to $SCREENS for the
# aggregate invariants at the end. stdin is /dev/null so "is this a terminal?"
# always has the same answer.
# Two knobs a scenario sets in its own environment rather than in <env>, because
# their values are paths and <env> is split on spaces: PROBE_TIMEOUT (the
# engine probe budget, default 2) and NO_EXAPUMP=1 (no exapump reachable by
# any route - not the stub, not the developer's real one).
RAW_TRACE="$WORK/trace.raw"; : > "$RAW_TRACE"
run() {
    _r_home="$1"; _r_env="$2"; _r_body="$3"
    : > "$_r_home/out"
    _r_path="$STUB/engine:$STUB/exapump:$PATH"; _r_exapump="$STUB/exapump/exapump"
    if [ "${NO_EXAPUMP:-0}" = 1 ]; then _r_path="$STUB/engine:$PATH_WITHOUT_EXAPUMP"; _r_exapump="$_r_home/no-such-exapump"; fi
    # shellcheck disable=SC2086
    env -u EXAKIT_LEGACY_DATA \
        EXAKIT_HOME="$_r_home" EXAKIT_BIN_DIR="$_r_home/bin" \
        EXAKIT_EXAPUMP_BIN="$_r_exapump" EXAKIT_EXAPUMP_CONFIG_DIR="$_r_home/exapump" \
        EXAKIT_LEGACY_EXPORT_DIR="$_r_home/migration" EXAKIT_FAULT_DIR="$_r_home/ctrl" \
        EXAKIT_ENGINE_PROBE_TIMEOUT="${PROBE_TIMEOUT:-2}" EXAKIT_NO_FANCY=1 \
        PATH="$_r_path" PS4="$COVERAGE_PS4" ROOT="$ROOT" $_r_env \
        bash -c "$(coverage_prelude "$RAW_TRACE")"'
            . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/detect.sh"; . "$ROOT/setup/lib/exapump.sh"
            set -x
            . "$ROOT/setup/lib/legacy-crossing.sh"
            '"$_r_body" </dev/null > "$_r_home/out" 2> "$_r_home/err"
    # stdout is the screen. stderr holds the kit's warn/error lines AND, on a
    # bash without BASH_XTRACEFD, the trace - and xtrace prints a multi-line
    # argument across several lines with the stamp on the FIRST only, so the
    # rest cannot be told from output by the stamp. The kit's stderr lines have
    # a shape of their own ("      ! ...", "      [x] ..."); only those are kept.
    {
        cat "$_r_home/out"
        coverage_collect "$_r_home/err" "$RAW_TRACE" "$TRACE" | grep -E '^ *(!|\[x\]) ' || true
    } | tee -a "$SCREENS"
}
before() { run "$1" "${2:-}" 'legacy_crossing_before; echo "RC=$?"'; }    # the first half, with its exit code
after()  { run "$1" "${2:-}" 'legacy_crossing_after; echo "RC=$?"'; }     # the second half
rc_of()  { printf '%s\n' "$1" | sed -n 's/^RC=\([0-9]*\)$/\1/p' | tail -1; }
quiet()  { printf '%s\n' "$1" | grep -v '^RC=' | tr -d '[:space:]'; }     # everything but the exit code
# mget <home> <dotted.key> — the record, printed as manifest_get prints it
# (true/false for booleans, nothing when absent) but without sourcing ten
# thousand lines of common.sh for each of the dozens of reads below.
mget() {
    python3 - "$1/manifest.json" "$2" <<'MGET_PY'
import json, sys
try:
    node = json.load(open(sys.argv[1]))
    for part in sys.argv[2].split("."):
        node = node[part]
except Exception:
    sys.exit(0)
print("true" if node is True else "false" if node is False else node)
MGET_PY
}
calls()  { cat "$1/ctrl/$2.calls" 2>/dev/null; }
verbs()  { calls "$1" engine | awk '{ print $1 }' | tr '\n' ' ' | sed 's/ $//'; }
BEFORE_RCS=""     # every crossing_before exit code, for the invariant at the end
note_rc() { BEFORE_RCS="$BEFORE_RCS $(rc_of "$1")"; }

# =============================================================================
echo "the engine misbehaves:"

# A hanging engine cannot hold the install hostage. Each bounded probe gives up
# at EXAKIT_ENGINE_PROBE_TIMEOUT; the whole crossing has to be over well before
# the container would have answered.
#
# The stub hangs as ONE process (exec sleep), which is the shape of a wedged
# engine CLI and the shape the kit's bounded runner can end. A hang in a CHILD
# of the engine is a different matter: on a machine without timeout(1) the
# runner's group kill has no group to hit in a non-interactive shell, the
# grandchild keeps the capture pipe open, and the crossing waits out the whole
# hang. That is a limit of exakit_run_bounded, noted here rather than hidden.
H="$WORK/hang"; seed "$H"; fault "$H" engine.state hang; fault "$H" engine.hang_seconds 60
_t0=$(date +%s); _o="$(PROBE_TIMEOUT=1 before "$H")"; _dt=$(( $(date +%s) - _t0 )); note_rc "$_o"
check "a hanging engine does not block the install" "0" "$(rc_of "$_o")"
check "...and it gives up promptly, not after the hang" "yes" "$([ "$_dt" -lt 30 ] && echo yes || echo "no: ${_dt}s")"
check "...saying nothing on screen" "" "$(quiet "$_o")"
check "...and settling the question for good" "true" "$(mget "$H" legacy.crossing_done)"

# A stopped container that will not start: there is data in there, and no way
# to read it. Silent skip, marked done, and the engine was asked exactly once.
H="$WORK/nostart"; seed "$H"; fault "$H" engine.state stopped; fault "$H" engine.start_rc 1
_o="$(before "$H")"; note_rc "$_o"
check "a container that will not start is not an error" "0" "$(rc_of "$_o")"
check "...nothing reaches the screen" "" "$(quiet "$_o")"
check "...the choice falls to skip" "skip" "$(mget "$H" legacy.choice)"
check "start was attempted once" "1" "$(calls "$H" engine | grep -c '^start ')"
lacks "and no export was tried" "export" "$(calls "$H" exapump)"

# The engine refuses to STOP on the skip path. The port may stay busy, and the
# crossing says so - but it still records itself done and lets the install
# continue to its own port check.
H="$WORK/nostop"; seed "$H"; fault "$H" engine.stop_rc 1
_o="$(before "$H" EXAKIT_LEGACY_DATA=skip)"; note_rc "$_o"
check "a stop that fails does not fail the crossing" "0" "$(rc_of "$_o")"
has "...it warns the port may still be held" "may find its port busy" "$_o"
check "...and the question is still settled" "true" "$(mget "$H" legacy.crossing_done)"
check "...with the container NOT recorded as stopped" "" "$(mget "$H" legacy.container_stopped)"

# The same refusal on the MIGRATE path: the copy is already safe on disk, so
# the warning is the only consequence.
H="$WORK/nostop-migrate"; seed "$H"; fault "$H" engine.stop_rc 1
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
has "on migrate too, the copy lands" "Your data is saved" "$_o"
has "...and the stop failure is named" "may find its port busy" "$_o"
check "...with the export still recorded" "3" "$(mget "$H" legacy.exported)"

# The recorded engine is not on this machine any more (Docker uninstalled,
# Podman never installed). Gate 3 names the reason in the log and closes.
H="$WORK/noengine"; SEED_ENGINE=no-such-engine seed "$H"
_o="$(before "$H")"; note_rc "$_o"
check "a recorded engine that is gone closes the gate" "0" "$(rc_of "$_o")"
check "...silently" "" "$(quiet "$_o")"
check "...and the state it reports is unknown, not absent" "unknown" "$(run "$H" "" 'legacy_container_state')"
check "the engine is never asked for" "" "$(calls "$H" engine)"

# No container name recorded at all: an older kit that died before writing it.
H="$WORK/noname"; SEED_NO_CONTAINER=1 seed "$H"
_o="$(before "$H")"; note_rc "$_o"
check "a record with no container name reads as absent" "absent" "$(run "$H" "" 'legacy_container_state')"
check "...and closes silently" "" "$(quiet "$_o")"
check "...the removal command has nothing to name and says so" "1" \
    "$(run "$H" "" 'legacy_remove_command >/dev/null; echo $?' | tail -1)"

# An engine whose answer cannot be parsed. "unknown" is not "gone": the
# database is probed, answers, and the offer is made - with the state shown
# for what it is.
H="$WORK/unknown"; seed "$H"; fault "$H" engine.state unknown
_o="$(before "$H" EXAKIT_LEGACY_DATA=skip)"; note_rc "$_o"
has "an unparseable state still leads to the offer" "runs in a container" "$_o"
has "...and the banner shows the state honestly" "(unknown)" "$_o"

# An engine that refuses `inspect -f` but answers a plain `inspect` (too old
# for the template flag): the container exists, its state cannot be read, and
# that is "unknown" - never "absent", which would forfeit the offer.
H="$WORK/noformat"; seed "$H"; fault "$H" engine.state noformat
check "an engine without the template flag reads as unknown" "unknown" "$(run "$H" "" 'legacy_container_state')"

# The volume name is missing from the record: the removal command still names
# the container, and only the container.
H="$WORK/novolume"; SEED_NO_VOLUME=1 seed "$H"
_rm="$(run "$H" "" 'legacy_remove_command')"
has "without a recorded volume the command still removes the container" "rm -f exasol-nano" "$_rm"
lacks "...and invents no volume" "volume rm" "$_rm"
check "with one, it removes both, container first" "fakeengine rm -f exasol-nano && fakeengine volume rm exasol-nano-data" \
    "$(run "$WORK/unknown" "" 'legacy_remove_command')"

# =============================================================================
echo
echo "the old database misbehaves:"

# No password on file - the honest case for a deployment the old kit adopted
# rather than created. Nothing can be read, so nothing is offered.
H="$WORK/nopw"; SEED_NO_PASSWORD=1 seed "$H"
_o="$(before "$H")"; note_rc "$_o"
check "no password file: silent skip" "" "$(quiet "$_o")"
check "...marked done" "true" "$(mget "$H" legacy.crossing_done)"
lacks "...and the database was never queried" "EXAKIT_LEGACY_OK" "$(calls "$H" exapump)"
check "...and the container is still stopped, because it holds the port" "1" "$(calls "$H" engine | grep -c '^stop ')"

# An EMPTY password file is the same as none: -s, not -f.
H="$WORK/emptypw"; SEED_EMPTY_PASSWORD=1 seed "$H"
_o="$(before "$H")"; note_rc "$_o"
check "an empty password file is treated as missing" "" "$(quiet "$_o")"
check "...profile writer refuses it" "1" "$(run "$H" "" 'legacy_write_profile; echo $?' | tail -1)"

# No DSN recorded: the profile cannot be written either.
H="$WORK/nodsn"; SEED_NO_DSN=1 seed "$H"
check "no dsn: the profile writer refuses" "1" "$(run "$H" "" 'legacy_write_profile; echo $?' | tail -1)"
_o="$(before "$H")"; note_rc "$_o"
check "...and the crossing closes silently" "" "$(quiet "$_o")"

# A running container whose database never answers. The wait is capped at ten
# seconds for a container that was ALREADY running - it should have answered
# on the first ask - and then the gate closes.
H="$WORK/silent-running"; seed "$H"; fault "$H" db.answer_after never
_t0=$(date +%s); _o="$(before "$H")"; _dt=$(( $(date +%s) - _t0 )); note_rc "$_o"
check "a database that never answers closes the gate" "" "$(quiet "$_o")"
check "...within the short budget for an already-running container" "yes" "$([ "$_dt" -lt 25 ] && echo yes || echo "no: ${_dt}s")"
check "...the probe was retried, not asked once" "yes" "$([ "$(calls "$H" exapump | grep -c EXAKIT_LEGACY_OK)" -ge 2 ] && echo yes || echo no)"

# A STOPPED container the crossing started itself gets the long budget - and
# EXAKIT_LEGACY_READY_TIMEOUT is that budget, so a scenario can make it short.
H="$WORK/silent-started"; seed "$H"; fault "$H" engine.state stopped; fault "$H" db.answer_after never
_t0=$(date +%s); _o="$(before "$H" EXAKIT_LEGACY_READY_TIMEOUT=5)"; _dt=$(( $(date +%s) - _t0 )); note_rc "$_o"
check "a started container that never answers closes the gate" "" "$(quiet "$_o")"
check "...within the configured budget" "yes" "$([ "$_dt" -lt 15 ] && echo yes || echo "no: ${_dt}s")"
check "...and the container was started for the attempt" "1" "$(calls "$H" engine | grep -c '^start ')"
check "...then stopped again, holding nothing" "1" "$(calls "$H" engine | grep -c '^stop ')"

# SELF-HEALING WAIT: a database that is slow to come up answers on the second
# ask, and the crossing proceeds as if it had answered on the first.
H="$WORK/late"; seed "$H"; fault "$H" db.answer_after 2
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
has "a database that answers late is still copied" "Your data is saved" "$_o"
check "...all three tables" "3" "$(mget "$H" legacy.exported)"

# A database with nothing in it. Nothing to offer; nothing said.
H="$WORK/empty"; seed "$H"; : > "$H/ctrl/db.tables"
_o="$(before "$H")"; note_rc "$_o"
check "an empty database is not worth a question" "" "$(quiet "$_o")"
check "...but is marked done" "true" "$(mget "$H" legacy.crossing_done)"
check "...and stopped, for the port" "1" "$(calls "$H" engine | grep -c '^stop ')"

# exapump is not there to read the tables out. The gate closes before the
# database is touched at all.
H="$WORK/noexapump"; seed "$H"
_o="$(NO_EXAPUMP=1 before "$H")"; note_rc "$_o"
check "no exapump: silent skip" "" "$(quiet "$_o")"
check "...done" "true" "$(mget "$H" legacy.crossing_done)"
check "...no query was attempted" "" "$(calls "$H" exapump)"

# =============================================================================
echo
echo "copying out tolerates partial failure:"

# One of three tables refuses to export. The other two land, the failed one is
# named, its half-written file is removed, and the run goes on as a migration.
H="$WORK/partial"; seed "$H"; fault "$H" export.fail "S1.T2"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
has "a table that will not copy is named" "Could not copy S1.T2" "$_o"
has "...and the run still saves the rest" "Your data is saved" "$_o"
check "two of three exported" "2" "$(mget "$H" legacy.exported)"
check "...one recorded as failed" "1" "$(mget "$H" legacy.export_failed)"
check "the failed table is not in the index" "0" "$(grep -c 'S1	T2' "$H/migration/index")"
check "...and its partial file is gone" "no" "$([ -e "$H/migration/t2.csv" ] && echo yes || echo no)"
check "the files that landed are the positional ones" "t1.csv t3.csv" "$(cd "$H/migration" && ls t*.csv | tr '\n' ' ' | sed 's/ $//')"
check "the choice stays migrate" "migrate" "$(mget "$H" legacy.choice)"

# EVERY table refuses. Nothing is lost - the old database is untouched - and
# the crossing downgrades itself to skip, saying so, with no export_dir left
# behind for the second half to trip on.
H="$WORK/allfail"; seed "$H"; printf 'S1.T1\nS1.T2\nS2.T3\n' > "$H/ctrl/export.fail"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
has "when nothing copies, it says so" "Nothing could be copied out" "$_o"
has "...and that nothing is lost" "nothing is lost" "$_o"
check "the choice is downgraded to skip" "skip" "$(mget "$H" legacy.choice)"
check "...no export_dir is recorded" "" "$(mget "$H" legacy.export_dir)"
check "...zero exported, three failed" "0/3" "$(mget "$H" legacy.exported)/$(mget "$H" legacy.export_failed)"
has "...and the removal command is offered, as on any skip" "rm -f exasol-nano" "$_o"
_o2="$(after "$H")"
check "the second half then has nothing to do" "" "$(quiet "$_o2")"

# The column catalogue has nothing for one table (a view, a table dropped
# between the listing and the copy). The index carries an EMPTY ddl for it and
# the restore falls back to letting upload infer the shape.
H="$WORK/noddl"; seed "$H"; printf 'S1.T1|ID<<:>>DECIMAL(18,0)\n' > "$H/ctrl/db.columns"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
check "a table with no column catalogue still exports" "3" "$(mget "$H" legacy.exported)"
check "...its index line ends in an empty ddl" "1" "$(awk -F'\t' '$3 == "T2" && $4 == ""' "$H/migration/index" | wc -l | tr -d ' ')"
check "...while the catalogued one carries its types" "1" "$(awk -F'\t' '$3 == "T1" && $4 ~ /DECIMAL\(18,0\)/' "$H/migration/index" | wc -l | tr -d ' ')"
_o2="$(after "$H")"
check "the restore then uploads it without a CREATE TABLE" "0" "$(calls "$H" exapump | grep -c 'CREATE TABLE "S1"."T2"')"
check "...and counts it restored" "3" "$(mget "$H" legacy.restored)"

# The export directory cannot be made (its parent is a FILE). The copy fails
# before any table, which is the "nothing could be copied" road.
H="$WORK/nodir"; seed "$H"; : > "$H/migration"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
has "an unwritable export directory is survived" "Nothing could be copied out" "$_o"
check "...and reads as skip" "skip" "$(mget "$H" legacy.choice)"
check "...with the install unblocked" "0" "$(rc_of "$_o")"

# The DDL builder on its own: types carried, identifiers quoted, a table with
# no catalogue refused rather than emitted as an empty CREATE.
H="$WORK/ddl"; seed "$H"; run "$H" "" 'legacy_write_profile' >/dev/null
check "the DDL carries the source types, quoted" 'CREATE TABLE "S1"."T1" ("ID" DECIMAL(18,0), "NAME" VARCHAR(25) UTF8)' \
    "$(run "$H" "" 'legacy_table_ddl S1 T1')"
has "a multi-word type survives the marker split" '"WHEN_TS" TIMESTAMP WITH LOCAL TIME ZONE' "$(run "$H" "" 'legacy_table_ddl S1 T2')"
check "a table with no catalogue yields no DDL" "1" "$(run "$H" "" 'legacy_table_ddl S9 NOPE; echo $?' | tail -1)"

# Identifiers Exasol allows and file systems do not: a dot inside the table
# name, a space in the schema. The split is on the FIRST dot; the files are
# positional; the DDL quotes both halves.
H="$WORK/odd"; seed "$H"; printf 'My Schema.T.with.dots\n' > "$H/ctrl/db.tables"
printf 'My Schema.T.with.dots|order<<:>>VARCHAR(10)\n' > "$H/ctrl/db.columns"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
# ONE table, not two: the name has a space in it, and the list of names used
# to be handed on unquoted with the default IFS, so "My Schema.T.with.dots"
# arrived as "My" and "Schema.T.with.dots".
check "a name with a space exports as ONE table" "1" "$(mget "$H" legacy.exported)"
check "...and nothing was reported failed" "" "$(mget "$H" legacy.export_failed)"
check "...to a positional file" "yes" "$([ -f "$H/migration/t1.csv" ] && echo yes || echo no)"
has "...with the schema split at the first dot" 'My Schema	T.with.dots' "$(cat "$H/migration/index")"
has "...and both halves quoted in the DDL" 'CREATE TABLE "My Schema"."T.with.dots" ("order" VARCHAR(10))' "$(cat "$H/migration/index")"

# =============================================================================
echo
echo "restoring tolerates partial failure and heals what it can:"

# A mixed restore: one lands, one was already created by the fresh install,
# one upload fails. Every count is recorded, every line of the summary is said,
# and the copy is KEPT because something did not land.
H="$WORK/mixed"; seed "$H"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
fault "$H" import.exists "S1.T2"; fault "$H" upload.fail "S2.T3"
_o2="$(after "$H")"
check "one restored" "1" "$(mget "$H" legacy.restored)"
check "one left alone" "1" "$(mget "$H" legacy.restore_skipped)"
check "one failed" "1" "$(mget "$H" legacy.restore_failed)"
has "the summary counts the restored" "Restored 1 table(s)" "$_o2"
has "...names the one left alone" "Left alone (this install had already created them): S1.T2" "$_o2"
has "...and says the copies stay for the failure" "did not restore" "$_o2"
lacks "...so the copy is NOT declared expendable" "no longer needed" "$_o2"
# Matched on the quoted target, not on "T2": the sandbox lives under a random
# mktemp suffix, and one run drew a suffix containing T2 - every upload PATH
# then matched and a correct restore read as two illicit uploads.
check "no upload was issued for the table left alone" "0" "$(calls "$H" exapump | grep '^upload' | grep -c '"S1"."T2"')"
check "the failed table's file is kept" "yes" "$([ -f "$H/migration/t3.csv" ] && echo yes || echo no)"
check "the second half returns cleanly" "0" "$(rc_of "$_o2")"

# Everything lands: the copy is declared expendable and the old container is
# named as still holding the original.
H="$WORK/clean"; seed "$H"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"; _o2="$(after "$H")"
has "a clean restore says the copy can go" "no longer needed" "$_o2"
has "...and that the original is still in the container" "still holds the original" "$_o2"
has "...with the exact removal command" "rm -f exasol-nano && fakeengine volume rm exasol-nano-data" "$_o2"
check "every table restored" "3" "$(mget "$H" legacy.restored)"
check "...none skipped, none failed" "/" "$(mget "$H" legacy.restore_skipped)/$(mget "$H" legacy.restore_failed)"

# The second half is IDEMPOTENT: a re-run after a completed restore does
# nothing - not one more upload - because the record says it is done.
_uploads_before="$(calls "$H" exapump | grep -c '^upload')"
_o3="$(after "$H")"
check "a second run of the restore is silent" "" "$(quiet "$_o3")"
check "...and issues no further uploads" "$_uploads_before" "$(calls "$H" exapump | grep -c '^upload')"

# A file the index names has gone missing between the halves. That row is
# skipped without a word and without a count: it is neither restored nor
# failed, and the others are unaffected.
H="$WORK/gonefile"; seed "$H"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
rm -f "$H/migration/t2.csv"
_o2="$(after "$H")"
check "a missing file is skipped, the rest restored" "2" "$(mget "$H" legacy.restored)"
check "...and not counted as a failure" "" "$(mget "$H" legacy.restore_failed)"
check "...no upload was attempted for it" "0" "$(calls "$H" exapump | grep '^upload' | grep -c 't2.csv')"

# CREATE SCHEMA refuses (a permission the new user lacks, say). It is not the
# test for anything, so the restore carries on to the table.
H="$WORK/noschema"; seed "$H"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
fault "$H" import.schema_rc 1
_o2="$(after "$H")"
check "a failed CREATE SCHEMA does not stop the restore" "3" "$(mget "$H" legacy.restored)"

# The index has blank lines and a line with too few fields (a hand edit, a
# truncated write). Blank lines are skipped; a short line has no file and is
# skipped too; the well-formed rows restore.
H="$WORK/badindex"; seed "$H"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
{ printf '\n\nnot-a-real-line\n'; cat "$H/migration/index"; printf '\n'; } > "$H/migration/index.new"
mv "$H/migration/index.new" "$H/migration/index"
_o2="$(after "$H")"
check "blank and malformed index lines are stepped over" "3" "$(mget "$H" legacy.restored)"
check "...with nothing counted as failed" "" "$(mget "$H" legacy.restore_failed)"

# An export_dir is recorded but the index is EMPTY (the copy died after
# creating it). The second half has nothing to restore and says nothing.
H="$WORK/emptyindex"; seed "$H"
run "$H" "" 'manifest_set legacy.export_dir "$EXAKIT_HOME/migration"' >/dev/null
mkdir -p "$H/migration"; : > "$H/migration/index"
_o2="$(after "$H")"
check "an empty index restores nothing, silently" "" "$(quiet "$_o2")"
check "...and returns cleanly" "0" "$(rc_of "$_o2")"

# The whole export directory is gone (the user deleted it). Same answer.
H="$WORK/gonedir"; seed "$H"
run "$H" "" 'manifest_set legacy.export_dir "$EXAKIT_HOME/migration"' >/dev/null
_o2="$(after "$H")"
check "a deleted export directory is survived" "" "$(quiet "$_o2")"

# legacy_import on a directory with no index at all: the honest non-zero.
H="$WORK/noindex"; seed "$H"; mkdir -p "$H/migration"
check "the importer refuses a directory with no index" "1" "$(run "$H" "" 'legacy_import "$EXAKIT_HOME/migration"; echo $?' | tail -1)"
# ...and the second half turns that into a kept copy, not a crash.
run "$H" "" 'manifest_set legacy.export_dir "$EXAKIT_HOME/migration"' >/dev/null
printf 'x\n' > "$H/migration/index"; : > "$H/migration/x"      # an index with a row, no file
_o2="$(after "$H")"
check "a restore that lands nothing keeps the copy" "0" "$(mget "$H" legacy.restored)"
check "...and returns cleanly" "0" "$(rc_of "$_o2")"

# =============================================================================
echo
echo "the two halves survive a crash between them:"

# The run died after the export was recorded but before the container was
# stopped or the crossing marked done. On resume the first half asks nothing,
# says nothing, stops the container it left running, and the second half
# restores what the first had saved.
H="$WORK/crash"; seed "$H"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
# Roll the record back to "died after export": choice and export_dir stand,
# crossing_done does not, and the container is running again.
fault "$H" engine.state running
python3 - "$H/manifest.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d.get("legacy", {}).pop("crossing_done", None)
json.dump(d, open(p, "w"), indent=2)
PY
_stops_before="$(calls "$H" engine | grep -c '^stop ')"
_exports_before="$(calls "$H" exapump | grep -c '^export')"
_o2="$(before "$H")"; note_rc "$_o2"
check "the resumed first half says nothing" "" "$(quiet "$_o2")"
check "...asks no question (the record already answers)" "migrate" "$(mget "$H" legacy.choice)"
check "...copies nothing twice" "$_exports_before" "$(calls "$H" exapump | grep -c '^export')"
check "...but does stop the container it left running" "$(( _stops_before + 1 ))" "$(calls "$H" engine | grep -c '^stop ')"
_o3="$(after "$H")"
has "and the second half restores the first half's copy" "Restored 3 table(s)" "$_o3"

# The run died AFTER crossing_done but before the deployment recorded itself
# as personal - the record still says nano. Gate 2 closes before any probe:
# zero engine calls, zero exapump calls, nothing on screen.
H="$WORK/done-still-nano"; seed "$H"
run "$H" "" 'manifest_set legacy.crossing_done true' >/dev/null
_o="$(before "$H")"; note_rc "$_o"
check "a crossing already done is never reconsidered" "" "$(quiet "$_o")"
check "...and costs no engine call" "" "$(calls "$H" engine)"
check "...and no database call" "" "$(calls "$H" exapump)"

# The normal post-crossing state: the deployment recorded itself as personal.
# Gate 1 closes; the machine is simply a Personal install now.
H="$WORK/personal"; SEED_TYPE=personal seed "$H"
_o="$(before "$H")"; note_rc "$_o"
check "a Personal install passes straight through" "" "$(quiet "$_o")"
check "...touching neither stub" "/" "$(calls "$H" engine)/$(calls "$H" exapump)"
_o2="$(after "$H")"
check "...and so does the second half" "" "$(quiet "$_o2")"

# =============================================================================
echo
echo "the whole road, end to end:"

# MIGRATE, container running. Every record the two halves leave, and the exact
# sequence of verbs the engine saw.
H="$WORK/e2e-migrate"; seed "$H"
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
has "the banner names the container and its state" "container 'exasol-nano' (running)" "$_o"
has "...the table count" "It holds 3 table(s)" "$_o"
has "...and the one caveat CSV carries" "empty string arrives as NULL" "$_o"
check "choice" "migrate" "$(mget "$H" legacy.choice)"
check "crossed_from" "nano" "$(mget "$H" legacy.crossed_from)"
check "export_dir" "$H/migration" "$(mget "$H" legacy.export_dir)"
check "exported" "3" "$(mget "$H" legacy.exported)"
check "container_stopped" "true" "$(mget "$H" legacy.container_stopped)"
check "crossing_done" "true" "$(mget "$H" legacy.crossing_done)"
check "the engine saw inspect, then inspect, then stop - and nothing else" "container container stop" "$(verbs "$H")"
check "every export went through the LEGACY profile" "3" "$(calls "$H" exapump | grep '^export' | grep -c -- '-p starter-kit-legacy')"
_o2="$(after "$H")"
has "the second half restores" "Restored 3 table(s)" "$_o2"
check "every upload went through the KIT's profile" "3" "$(calls "$H" exapump | grep '^upload' | grep -c -- '-p starter-kit ')"
check "...into the new database, never the old" "0" "$(calls "$H" exapump | grep '^upload' | grep -c -- 'starter-kit-legacy')"
check "restored" "3" "$(mget "$H" legacy.restored)"
# A THIRD run - the next install of any kind - sees a machine that has crossed.
_o3="$(before "$H")"; note_rc "$_o3"
check "and a later install asks nothing again" "" "$(quiet "$_o3")"

# MIGRATE, container stopped: it is started for the copy and stopped after.
H="$WORK/e2e-stopped"; seed "$H"; fault "$H" engine.state stopped
_o="$(before "$H" EXAKIT_LEGACY_DATA=migrate)"; note_rc "$_o"
has "a stopped container is copied too" "Your data is saved" "$_o"
has "...and the banner reports the state it found" "(stopped)" "$_o"
check "the engine saw a start before the stop" "yes" \
    "$(calls "$H" engine | awk '$1=="start"{s=NR} $1=="stop"{t=NR} END{ print (s && t && s < t) ? "yes" : "no" }')"

# SKIP: no copy, container stopped, removal command printed, nothing deleted.
H="$WORK/e2e-skip"; seed "$H"
_o="$(before "$H" EXAKIT_LEGACY_DATA=skip)"; note_rc "$_o"
has "skip leaves the old database alone, and says so" "left exactly as it was, stopped, with its data" "$_o"
has "...with the command that removes it when wanted" "fakeengine rm -f exasol-nano && fakeengine volume rm exasol-nano-data" "$_o"
check "no export was issued" "0" "$(calls "$H" exapump | grep -c '^export')"
check "the container was stopped" "1" "$(calls "$H" engine | grep -c '^stop ')"
check "and the crossing is done" "true" "$(mget "$H" legacy.crossing_done)"
_o2="$(after "$H")"
check "the second half has nothing to restore" "" "$(quiet "$_o2")"

# =============================================================================
echo
echo "answers from the environment and from the keyboard:"

H="$WORK/answers"; seed "$H"
_choice() { # _choice <env> [can] [why] -> the choice; the narration is left on stdout and filtered, not redirected away
    run "$H" "$1" "legacy_choose 3 ${2:-yes} '${3:-}'; printf 'CHOICE=%s' \"\$EXAKIT_LEGACY_CHOICE\"" | sed -n 's/.*CHOICE=\([a-z]*\).*/\1/p' | tail -1
}
check "a copy that cannot be made is refused even when asked for" "skip" "$(_choice EXAKIT_LEGACY_DATA=migrate no 'no reason at all')"
has "...and the refusal names why" "no reason at all" "$(run "$H" EXAKIT_LEGACY_DATA=migrate "legacy_choose 3 no 'no reason at all'")"
check "no answer and no possible copy is skip" "skip" "$(_choice "" no 'the container is gone')"
has "...saying why" "the container is gone" "$(run "$H" "" "legacy_choose 3 no 'the container is gone'")"
check "EXAKIT_LEGACY_DATA=1 means migrate" "migrate" "$(_choice EXAKIT_LEGACY_DATA=1)"
check "EXAKIT_LEGACY_DATA=0 means skip"    "skip"    "$(_choice EXAKIT_LEGACY_DATA=0)"
# A value the kit does not know is not an answer. It falls through to the
# terminal question, and off a terminal that is the unattended skip.
check "a value the kit does not know is no answer" "skip" "$(_choice EXAKIT_LEGACY_DATA=maybe)"
has "...and the hint says how to answer" "EXAKIT_LEGACY_DATA=migrate" "$(run "$H" EXAKIT_LEGACY_DATA=maybe 'legacy_choose 3 yes ""')"

# THE KEYBOARD. The terminal check and the menu are stubbed in the run, so the
# mapping from the menu's answer to the choice is exercised for real: row 1 is
# migrate, row 2 is skip, and row 2 is the exclusive one.
# The terminal check and the menu are replaced by functions in a FILE that the
# run sources, not defined inline in the run's own script: a function defined
# in `bash -c` has no BASH_SOURCE, and on bash 3.2 calling one from inside the
# module wipes the module's own source attribution for the rest of the caller -
# the menu lines ran, and the trace stamped them as belonging to nowhere.
cat > "$H/ctrl/keyboard.sh" <<'KEYBOARD'
exakit_stdin_is_tty() { return 0; }
ui_checkbox_menu() {
    printf '%s\n' "$@" > "$EXAKIT_FAULT_DIR/menu.args"
    printf '%s' "$EXAKIT_CHECKBOX_EXCLUSIVE" > "$EXAKIT_FAULT_DIR/menu.exclusive"
    EXAKIT_CHECKBOX_SELECTION="$MENU_PICK"
}
KEYBOARD
_menu() { # _menu <pick> -> "CHOICE=<c> EXCLUSIVE=<n> LABEL=<count-in-labels>"
    run "$H" "MENU_PICK=$1" '
        . "$EXAKIT_FAULT_DIR/keyboard.sh"
        legacy_choose 7 yes ""
        printf "CHOICE=%s EXCLUSIVE=%s LABEL=%s" "$EXAKIT_LEGACY_CHOICE" "$(cat "$EXAKIT_FAULT_DIR/menu.exclusive")" "$(grep -c "7 table" "$EXAKIT_FAULT_DIR/menu.args")"' | grep '^CHOICE='
}
_m1="$(_menu 1)"; _m2="$(_menu 2)"
has "row 1 on the keyboard is migrate" "CHOICE=migrate" "$_m1"
has "row 2 on the keyboard is skip"    "CHOICE=skip"    "$_m2"
has "row 2 is the exclusive one"       "EXCLUSIVE=2"    "$_m1"
has "the labels carry the table count" "LABEL=1"        "$_m1"
# The menu's default is row 1, so an Enter with nothing changed is migrate.
has "an unchanged menu (empty selection) reads as migrate" "CHOICE=migrate" "$(_menu "")"

# =============================================================================
echo
echo "the CLI's view of a legacy install:"

H="$WORK/notice"; seed "$H"
_n="$(run "$H" "" 'exakit_legacy_runtime_notice')"
has "the notice explains the container" "runs in a container, which this kit no longer manages" "$_n"
has "...and names the crossing as the installer" "Re-run the installer to move across" "$_n"
has "...promising that nothing is deleted" "deletes nothing either way" "$_n"
H2="$WORK/notice-personal"; SEED_TYPE=personal seed "$H2"
check "and is silent on a Personal install" "" "$(run "$H2" "" 'exakit_legacy_runtime_notice' | tr -d '[:space:]')"
# The set of legacy runtime names is one variable, overridable, so a future
# record type can be taught to the kit without a code change here.
check "the legacy set is a variable" "yes" \
    "$(run "$H2" "EXAKIT_LEGACY_RUNTIME_TYPES=personal" 'exakit_legacy_runtime_recorded && echo yes || echo no' | tail -1)"

# =============================================================================
echo
echo "invariants that held across every scenario above:"

_all_engine="$(cat "$WORK"/*/ctrl/engine.calls 2>/dev/null)"
_all_exapump="$(cat "$WORK"/*/ctrl/exapump.calls 2>/dev/null)"
check "the engine was used, so the next lines mean something" "yes" "$([ -n "$_all_engine" ] && echo yes || echo no)"
check "exapump was used" "yes" "$([ -n "$_all_exapump" ] && echo yes || echo no)"
# THE INVARIANT: the crossing copies and stops. It never deletes.
check "no engine call ever removed a container" "0" "$(printf '%s\n' "$_all_engine" | grep -cE '^(rm|container rm|volume|destroy|kill|prune)')"
check "only inspect, start and stop were ever issued" "" \
    "$(printf '%s\n' "$_all_engine" | awk '$1 != "container" && $1 != "start" && $1 != "stop"' | sort -u | tr '\n' ' ')"
check "every inspect was of the recorded container" "0" "$(printf '%s\n' "$_all_engine" | grep '^container' | grep -vc 'exasol-nano$')"
# THE PASSWORD. It is checked where it would leak - on screen, and in the argv
# handed to another process (what `ps` shows) - and not in the xtrace, which
# expands every argument of every in-process function by design.
check "the password never reached the screen" "0" "$(grep -c -- "$PASSWORD" "$SCREENS")"
check "...nor any process the crossing ran" "0" "$(printf '%s\n' "$_all_engine" "$_all_exapump" | grep -c -- "$PASSWORD")"
check "...and it did land in a 0600 profile inside the sandbox" "yes" \
    "$(grep -lq -- "$PASSWORD" "$WORK"/e2e-migrate/exapump/config.toml 2>/dev/null && [ "$(stat -f '%Lp' "$WORK/e2e-migrate/exapump/config.toml" 2>/dev/null || stat -c '%a' "$WORK/e2e-migrate/exapump/config.toml")" = 600 ] && echo yes || echo no)"
check "the developer's real exapump config is untouched" "$REAL_CONFIG_BEFORE" "$(_hash "$REAL_EXAPUMP_CONFIG")"
# THE INSTALL IS NEVER FAILED BY THE CROSSING.
check "every first half returned 0" "" "$(printf '%s\n' $BEFORE_RCS | grep -v '^0$' | tr '\n' ' ')"
# THE RECORD STAYS READABLE.
_bad_json=""
for _m in "$WORK"/*/manifest.json; do python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$_m" 2>/dev/null || _bad_json="$_bad_json ${_m#$WORK/}"; done
check "every manifest is still valid JSON" "" "$_bad_json"
# THE TWO PROFILES NEVER CROSS. Reads of the old database go through the
# legacy profile; writes into the new one go through the kit's.
check "no read of the old database used the kit's profile" "0" \
    "$(printf '%s\n' "$_all_exapump" | grep -E '^(export|sql -p [^ ]+ SELECT)' | grep -c -- '-p starter-kit ')"
check "no upload used the legacy profile" "0" "$(printf '%s\n' "$_all_exapump" | grep '^upload' | grep -c -- 'starter-kit-legacy')"
check "no parquet was ever asked for" "0" "$(printf '%s\n' "$_all_exapump" | grep -c parquet)"

# =============================================================================
if coverage_report "$ROOT/setup/lib/legacy-crossing.sh" "$TRACE" 85; then
    PASS=$((PASS+1)); printf '  ok   coverage floor held\n'
else
    FAIL=$((FAIL+1)); printf '  FAIL coverage is below the floor\n'
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
