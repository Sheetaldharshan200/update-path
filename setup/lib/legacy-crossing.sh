#!/usr/bin/env bash
# legacy-crossing.sh — moving an installation made by an OLDER kit onto this one.
#
# Older kits (this one before the container runtime was removed, and the
# upstream exasol-labs/exasol-personal-local-starterkit) could deploy the
# database as a CONTAINER. This kit deploys Exasol Personal and nothing else,
# so an installation whose manifest records a container database has a database
# that nothing in this tree can drive.
#
# This module is the ONE place that touches such an installation, and the way it
# touches it matters: it reads the manifest the old kit wrote and shells out to
# the recorded engine for exactly three verbs — inspect, start, stop. It does
# not reintroduce a runtime, it cannot deploy a container, and nothing outside
# the crossing calls into it. When the crossing is done the module has no work
# left to do on that machine, for ever.
#
# THE ORDER IS FORCED BY THE PORT. The old container is listening on the port
# the new deployment wants, so the container must be stopped before the deploy —
# on BOTH answers, including the one that keeps it. And the data can only be
# read while it is still up. That is why the crossing is in two halves with the
# install between them:
#
#   legacy_crossing_before   ask, export, stop the container      (before step 1)
#   ... the install runs: launcher, deployment, exapump, datasets ...
#   legacy_crossing_after    restore into the new database        (after the kit steps)
#
# The second half runs last on purpose. It needs three things the install itself
# provides: a database that is up, an exapump binary, and a connection profile
# pointing at the NEW database. Anything earlier and it would be writing into
# the database it just came from.
#
# WHAT IS NEVER DONE: the old container and its data volume are not deleted, on
# either answer. A migration that has just copied data out is exactly the wrong
# moment to destroy the only other copy, and "skip" means skip. The container is
# left stopped, named on screen, with the one command that removes it.
#
# Twin: setup/lib/legacy-crossing.ps1. Keep the two in step.

# Where the export lands. Under the kit home rather than /tmp: it holds the
# user's data and it has to survive a reboot between the two halves of a
# resumed install.
EXAKIT_LEGACY_EXPORT_DIR="${EXAKIT_LEGACY_EXPORT_DIR:-$EXAKIT_HOME/migration}"

# The exapump profile pointing at the OLD database. A second profile, not a
# rewrite of the kit's own: the kit's profile has to keep pointing at the new
# database throughout, and a password belongs in a 0600 config file rather than
# in argv where `ps` can read it.
EXAKIT_LEGACY_PROFILE="${EXAKIT_LEGACY_PROFILE:-starter-kit-legacy}"

# Exasol's own schemas. Everything else on the machine is the user's, including
# the kit's STARTER_KIT — a user who loaded their own tables into it means them
# when they say "my data".
EXAKIT_LEGACY_SYSTEM_SCHEMAS="'SYS','EXA_STATISTICS'"

# migrate | skip — set by legacy_choose, read by both halves.
EXAKIT_LEGACY_CHOICE=""

# --- what the old install recorded ------------------------------------------

# Whether this machine has an installation whose database is a container. The
# predicate itself lives in common.sh so the CLI can ask the same question from
# the same place - see exakit_legacy_runtime_recorded there.
legacy_db_recorded() { exakit_legacy_runtime_recorded; }

legacy_container() { manifest_get runtime.container 2>/dev/null || true; }
legacy_volume()    { manifest_get runtime.volume 2>/dev/null || true; }
legacy_dsn()       { manifest_get runtime.dsn 2>/dev/null || true; }

legacy_user() {
    _lu="$(manifest_get runtime.user 2>/dev/null || true)"
    printf '%s' "${_lu:-sys}"
}

# legacy_engine — the recorded engine, as a runnable path, or empty.
#
# The NAME is taken from the record and never re-detected: this is about the
# engine that holds this particular container, and a machine can have another
# one installed. An engine that is recorded but no longer on PATH answers empty,
# which is what makes the migrate option offer itself as unavailable rather than
# fail halfway through.
legacy_engine() {
    _le_name="$(manifest_get runtime.engine 2>/dev/null || true)"
    [ -n "$_le_name" ] || return 0
    command -v "$_le_name" 2>/dev/null || true
}

# legacy_engine_run <args...> — one bounded engine call, output on stdout.
#
# Bounded for the reason every engine probe in this kit is bounded: an engine
# that is still starting does not answer, and the crossing must not hang an
# install behind it.
legacy_engine_run() {
    _ler_bin="$(legacy_engine)"
    [ -n "$_ler_bin" ] || return 1
    exakit_run_bounded "${EXAKIT_ENGINE_PROBE_TIMEOUT:-20}" "$_ler_bin" "$@" 2>/dev/null
}

# legacy_container_state — running | stopped | absent | unknown.
# "unknown" is its own answer: an engine that will not talk is not evidence
# that the user's database is gone.
legacy_container_state() {
    _lcs_name="$(legacy_container)"
    [ -n "$_lcs_name" ] || { echo "absent"; return 0; }
    [ -n "$(legacy_engine)" ] || { echo "unknown"; return 0; }
    _lcs_out="$(legacy_engine_run container inspect -f '{{.State.Running}}' "$_lcs_name")" || {
        # A refusal is ambiguous on its own; ask whether it exists at all.
        if legacy_engine_run container inspect "$_lcs_name" >/dev/null 2>&1; then
            echo "unknown"
        else
            echo "absent"
        fi
        return 0
    }
    case "$_lcs_out" in
        *true*)  echo "running" ;;
        *false*) echo "stopped" ;;
        *)       echo "unknown" ;;
    esac
}

legacy_start_container() {
    _lsc_name="$(legacy_container)"
    [ -n "$_lsc_name" ] || return 1
    legacy_engine_run start "$_lsc_name" >/dev/null 2>&1 || return 1
    # Started is not ready. The readiness probe is a real query, below.
    return 0
}

# legacy_stop_container — the one mutation the crossing makes to the old
# install, and it is reversible: the container is stopped, never removed, and
# its data volume is not touched.
legacy_stop_container() {
    _ltc_name="$(legacy_container)"
    [ -n "$_ltc_name" ] || return 0
    [ "$(legacy_container_state)" = "running" ] || return 0
    info "Stopping the old database container ($_ltc_name) so the new deployment can take the port"
    legacy_engine_run stop "$_ltc_name" >/dev/null 2>&1 || {
        warn "Could not stop the container $_ltc_name — the new deployment may find its port busy"
        return 1
    }
    manifest_set legacy.container_stopped true
    return 0
}

# legacy_remove_command — the exact command that removes the old container and
# its data, printed for the user and never run by the kit.
legacy_remove_command() {
    _lrc_engine="$(manifest_get runtime.engine 2>/dev/null || true)"
    _lrc_engine="${_lrc_engine:-podman}"
    _lrc_c="$(legacy_container)"; _lrc_v="$(legacy_volume)"
    [ -n "$_lrc_c" ] || return 1
    if [ -n "$_lrc_v" ]; then
        printf '%s rm -f %s && %s volume rm %s' "$_lrc_engine" "$_lrc_c" "$_lrc_engine" "$_lrc_v"
    else
        printf '%s rm -f %s' "$_lrc_engine" "$_lrc_c"
    fi
}

# --- talking to the old database --------------------------------------------

# legacy_write_profile — the exapump profile for the OLD database, from what the
# old install recorded. Returns non-zero when the password is not on file, which
# is the honest case for a deployment the old kit adopted rather than created.
legacy_write_profile() {
    _lwp_dsn="$(legacy_dsn)"
    [ -n "$_lwp_dsn" ] || return 1
    _lwp_host="${_lwp_dsn%%:*}"
    _lwp_port="${_lwp_dsn##*:}"
    _lwp_pwfile="$(manifest_get runtime.password_file 2>/dev/null || true)"
    [ -n "$_lwp_pwfile" ] && [ -s "$_lwp_pwfile" ] || return 1
    # The password is read into a variable and handed to the writer, which puts
    # it in a 0600 file. It is never echoed, logged, or passed on a command line.
    exapump_write_profile "$EXAKIT_LEGACY_PROFILE" "$_lwp_host" "$_lwp_port" \
        "$(legacy_user)" "$(cat "$_lwp_pwfile")" || return 1
    return 0
}

# legacy_db_answers — a real query against the old database through its own
# profile. The readiness signal for everything below.
legacy_db_answers() {
    "$(exapump_cli)" sql -p "$EXAKIT_LEGACY_PROFILE" \
        "SELECT 'EXAKIT_LEGACY_OK' AS P" 2>/dev/null | grep -q 'EXAKIT_LEGACY_OK'
}

# legacy_tables — SCHEMA.TABLE, one per line, for every non-system table.
#
# The sentinel wrapper is the pattern exapump_count uses and it is here for the
# same reason: the echoed query literal must not be mistaken for a result row,
# and after "EXAKIT_LT[" the literal has a quote where a result has a name.
legacy_tables() {
    "$(exapump_cli)" sql -p "$EXAKIT_LEGACY_PROFILE" \
        "SELECT 'EXAKIT_LT[' || TABLE_SCHEMA || '.' || TABLE_NAME || ']' AS T FROM EXA_ALL_TABLES WHERE TABLE_SCHEMA NOT IN ($EXAKIT_LEGACY_SYSTEM_SCHEMAS) ORDER BY TABLE_SCHEMA, TABLE_NAME" \
        2>/dev/null | sed -n 's/.*EXAKIT_LT\[\([^]]*\)\].*/\1/p'
}

# legacy_table_ddl <schema> <table> — CREATE TABLE for the target, built from
# the SOURCE column types.
#
# THIS IS WHY THE ROUND TRIP KEEPS ITS TYPES. `exapump upload` into a table that
# does not exist INFERS the schema from the CSV, and inference turns a
# DECIMAL(12,4) into whatever the sample looks like. Creating the table with the
# original types first means the upload only has to parse into them.
legacy_table_ddl() {
    _ltd_schema="$1"; _ltd_table="$2"
    _ltd_cols="$("$(exapump_cli)" sql -p "$EXAKIT_LEGACY_PROFILE" \
        "SELECT 'EXAKIT_LC[' || COLUMN_NAME || '<<:>>' || COLUMN_TYPE || ']' AS C FROM EXA_ALL_COLUMNS WHERE COLUMN_SCHEMA = '$_ltd_schema' AND COLUMN_TABLE = '$_ltd_table' ORDER BY COLUMN_ORDINAL_POSITION" \
        2>/dev/null | sed -n 's/.*EXAKIT_LC\[\([^]]*\)\].*/\1/p')"
    [ -n "$_ltd_cols" ] || return 1
    _ltd_list=""
    while IFS= read -r _ltd_c; do
        [ -n "$_ltd_c" ] || continue
        # SPLIT ON THE MARKER, NOT ON WHITESPACE. A column name may contain a
        # space ("my col") and so may a type ("TIMESTAMP WITH LOCAL TIME
        # ZONE"), so neither end can be found from the first or the last space.
        _ltd_name="${_ltd_c%%<<:>>*}"
        _ltd_type="${_ltd_c#*<<:>>}"
        # Quoted identifiers: a column named ORDER or one with a lower-case
        # letter or a space is legal in Exasol and illegal unquoted.
        [ -n "$_ltd_list" ] && _ltd_list="$_ltd_list, "
        _ltd_list="$_ltd_list\"$_ltd_name\" $_ltd_type"
    done <<EOF
$_ltd_cols
EOF
    [ -n "$_ltd_list" ] || return 1
    printf 'CREATE TABLE "%s"."%s" (%s)' "$_ltd_schema" "$_ltd_table" "$_ltd_list"
}

# --- the two halves ---------------------------------------------------------

# legacy_choose — the question, asked once.
#
# Two answers, and they are exclusive: this is a fork in the road, not a set of
# features. EXAKIT_LEGACY_DATA pre-answers it for an unattended run, and an
# unattended run with no answer SKIPS — copying a database is not something to
# start on someone's behalf while they are not there, and skipping destroys
# nothing.
legacy_choose() {
    _lc_tables="$1"
    _lc_can_migrate="$2"
    _lc_why="$3"

    case "${EXAKIT_LEGACY_DATA:-}" in
        migrate|yes|1)
            EXAKIT_LEGACY_CHOICE="migrate"
            [ "$_lc_can_migrate" = yes ] || {
                warn "EXAKIT_LEGACY_DATA asked for a migration, but $_lc_why"
                EXAKIT_LEGACY_CHOICE="skip"
            }
            return 0 ;;
        skip|no|0)
            EXAKIT_LEGACY_CHOICE="skip"; return 0 ;;
    esac

    if [ "$_lc_can_migrate" != yes ]; then
        warn "Your data cannot be copied automatically: $_lc_why"
        EXAKIT_LEGACY_CHOICE="skip"
        return 0
    fi

    if ! exakit_stdin_is_tty; then
        info "Nothing is asked in an unattended run, so the old database is left alone."
        info "To copy it into the new one, re-run with EXAKIT_LEGACY_DATA=migrate"
        EXAKIT_LEGACY_CHOICE="skip"
        return 0
    fi

    # Row 2 is the exclusive one: picking "skip" clears "migrate" and the other
    # way round.
    EXAKIT_CHECKBOX_EXCLUSIVE=2
    ui_checkbox_menu "Your existing database" "1" \
        "Migrate my data — copy $_lc_tables table(s) into the new database" \
        "Skip and continue — set up the new database empty, and leave the old one alone"
    case "${EXAKIT_CHECKBOX_SELECTION:-1}" in
        *2*) EXAKIT_LEGACY_CHOICE="skip" ;;
        *)   EXAKIT_LEGACY_CHOICE="migrate" ;;
    esac
    return 0
}

# legacy_export — every non-system table to CSV under <dir>, plus a plain index
# the second half reads back.
#
# CSV, not Parquet: `exapump export --format parquet` is broken in the versions
# this kit installs (it writes the rows as CSV and then fails re-parsing its own
# output), so asking for Parquet produces a 0-byte file and a confusing error.
# CSV round-trips faithfully INTO A TABLE THAT ALREADY EXISTS with the right
# types, which is what legacy_table_ddl is for.
#
# THE ONE THING CSV CANNOT CARRY: an empty string and a NULL are the same three
# bytes in a CSV field, so a VARCHAR that held '' arrives as NULL. That is named
# on screen before the copy starts, not discovered afterwards.
legacy_export() {
    _lex_dir="$1"; shift
    mkdir -p "$_lex_dir" || return 1
    chmod 700 "$_lex_dir" 2>/dev/null || true
    : > "$_lex_dir/index"
    _lex_ok=0
    _lex_bad=0
    _lex_total=$#
    _lex_n=0
    for _lex_t in "$@"; do
        _lex_n=$(( _lex_n + 1 ))
        _lex_schema="${_lex_t%%.*}"
        _lex_table="${_lex_t#*.}"
        # The file name is positional, not derived from the table name: a
        # schema or table with a dot, a slash or a space in it is legal in
        # Exasol and would otherwise escape the directory.
        _lex_file="$_lex_dir/t${_lex_n}.csv"
        EXAKIT_ACTIVE_LABEL="Copying out $_lex_t ($_lex_n/$_lex_total)"
        if run_logged "$(exapump_cli)" export -p "$EXAKIT_LEGACY_PROFILE" \
                --table "$_lex_t" --format csv -o "$_lex_file"; then
            _lex_ddl="$(legacy_table_ddl "$_lex_schema" "$_lex_table" 2>/dev/null || true)"
            # The index is read back by the other half, so it carries
            # everything that half needs: where the rows are, where they go,
            # and how to build the table that receives them.
            printf '%s\t%s\t%s\t%s\n' "t${_lex_n}.csv" "$_lex_schema" "$_lex_table" "$_lex_ddl" \
                >> "$_lex_dir/index"
            _lex_ok=$(( _lex_ok + 1 ))
        else
            # The partial file goes. exapump creates the output before it
            # knows the query works, so a failed export leaves a 0-byte file -
            # harmless (nothing indexes it) but alarming to find in a
            # directory whose whole job is holding someone's data.
            rm -f "$_lex_file"
            warn "Could not copy $_lex_t out of the old database — it is left there, untouched"
            _lex_bad=$(( _lex_bad + 1 ))
        fi
    done
    EXAKIT_ACTIVE_LABEL=""
    manifest_set legacy.exported "$_lex_ok"
    [ "$_lex_bad" -gt 0 ] && manifest_set legacy.export_failed "$_lex_bad"
    [ "$_lex_ok" -gt 0 ]
}

# legacy_import <dir> — the saved tables into the database that is now running.
#
# A table the fresh install has already created is SKIPPED, not appended to.
# The bundled sample data is loaded before this runs, so appending would double
# every row of every sample table a user also had.
legacy_import() {
    _lim_dir="$1"
    [ -s "$_lim_dir/index" ] || return 1
    _lim_ok=0; _lim_skipped=0; _lim_bad=0
    _lim_skipped_names=""
    while IFS="$(printf '\t')" read -r _lim_file _lim_schema _lim_table _lim_ddl; do
        [ -n "$_lim_file" ] || continue
        [ -f "$_lim_dir/$_lim_file" ] || continue
        _lim_target="\"$_lim_schema\".\"$_lim_table\""
        EXAKIT_ACTIVE_LABEL="Restoring $_lim_schema.$_lim_table"
        # CREATE SCHEMA is unconditional and harmless; CREATE TABLE is the test
        # for "does this already exist", so its failure is not an error here.
        run_logged "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" \
            "CREATE SCHEMA IF NOT EXISTS \"$_lim_schema\"" || true
        if [ -n "$_lim_ddl" ]; then
            if ! run_logged "$(exapump_cli)" sql -p "$EXAKIT_EXAPUMP_PROFILE" "$_lim_ddl"; then
                # Already there — the fresh install created it. Leave it alone.
                _lim_skipped=$(( _lim_skipped + 1 ))
                _lim_skipped_names="$_lim_skipped_names $_lim_schema.$_lim_table"
                continue
            fi
        fi
        if run_logged "$(exapump_cli)" upload -p "$EXAKIT_EXAPUMP_PROFILE" \
                --table "$_lim_target" "$_lim_dir/$_lim_file"; then
            _lim_ok=$(( _lim_ok + 1 ))
        else
            warn "Could not restore $_lim_schema.$_lim_table — the copy is kept at $(ui_tilde "$_lim_dir/$_lim_file")"
            _lim_bad=$(( _lim_bad + 1 ))
        fi
    done < "$_lim_dir/index"
    EXAKIT_ACTIVE_LABEL=""
    manifest_set legacy.restored "$_lim_ok"
    [ "$_lim_skipped" -gt 0 ] && manifest_set legacy.restore_skipped "$_lim_skipped"
    [ "$_lim_bad" -gt 0 ] && manifest_set legacy.restore_failed "$_lim_bad"
    EXAKIT_LEGACY_RESTORED="$_lim_ok"
    EXAKIT_LEGACY_SKIPPED="$_lim_skipped"
    EXAKIT_LEGACY_SKIPPED_NAMES="$_lim_skipped_names"
    EXAKIT_LEGACY_RESTORE_FAILED="$_lim_bad"
    return 0
}

# legacy_crossing_before — the first half: say what was found, ask, copy out,
# stop the container. Never fails the install: every arm that cannot continue
# falls back to leaving the old database exactly where it is.
legacy_crossing_before() {
    # ASKED ONCE, AND ONLY WHERE THERE IS SOMETHING TO ASK ABOUT.
    #
    # Three gates, cheapest first, and all three are silent when they close.
    # An installer that announces "your database is in a container" to someone
    # whose container is long gone, or on every re-run after the crossing has
    # already happened, is a nag - and this code runs on EVERY install.
    #
    #   1. the record says this is not a legacy install       -> nothing
    #   2. the crossing already happened on this machine      -> nothing
    #   3. there is no readable database with tables in it    -> nothing
    #
    # Only past all three does anything reach the screen.
    legacy_db_recorded || return 0
    [ "$(manifest_get legacy.crossing_done 2>/dev/null || true)" = "true" ] && return 0

    # An earlier attempt at THIS install already answered. Finish the leftover
    # work and say nothing: the question was asked, and asking again (or
    # narrating a resume) is the same nag from the other direction. The restore
    # half does the talking, because it has something to report.
    if [ -n "$(manifest_get legacy.choice 2>/dev/null || true)" ]; then
        EXAKIT_LEGACY_CHOICE="$(manifest_get legacy.choice)"
        _exakit_log_file "INFO  legacy crossing: resuming with choice=$EXAKIT_LEGACY_CHOICE" 2>/dev/null || true
        legacy_stop_container >/dev/null 2>&1 || true
        return 0
    fi

    _lcb_type="$(manifest_get runtime.type 2>/dev/null || true)"
    _lcb_container="$(legacy_container)"
    _lcb_state="$(legacy_container_state)"

    # THE PROBE COMES BEFORE THE BANNER. Whether there is a database worth
    # talking about is answerable without saying a word, and if the answer is
    # no this function has nothing to tell anyone.
    _lcb_can=yes; _lcb_why=""
    if [ -z "$(legacy_engine)" ]; then
        _lcb_can=no; _lcb_why="the container engine this database needs is not on this machine any more"
    elif [ "$_lcb_state" = "absent" ]; then
        _lcb_can=no; _lcb_why="the container is gone, so there is nothing left to copy"
    elif ! command -v "$(exapump_cli)" >/dev/null 2>&1 && [ ! -x "$(exapump_cli)" ]; then
        _lcb_can=no; _lcb_why="exapump is not installed, and it is what reads the tables out"
    fi

    # A stopped container still holds the data, so it is started - but quietly,
    # and only once the gates above have said there is a point.
    _lcb_started=0
    if [ "$_lcb_can" = yes ] && [ "$_lcb_state" = "stopped" ]; then
        if legacy_start_container; then
            _lcb_started=1
        else
            _lcb_can=no; _lcb_why="the old container would not start"
        fi
    fi

    _lcb_tables=""
    if [ "$_lcb_can" = yes ]; then
        if legacy_write_profile; then
            # Up to two minutes, and only for a container this run just
            # started: one that was already running answers on the first ask.
            _lcb_budget="${EXAKIT_LEGACY_READY_TIMEOUT:-120}"
            [ "$_lcb_started" -eq 0 ] && _lcb_budget=10
            _lcb_waited=0
            until legacy_db_answers; do
                _lcb_waited=$(( _lcb_waited + 5 ))
                [ "$_lcb_waited" -ge "$_lcb_budget" ] && break
                sleep 5
            done
            if legacy_db_answers; then
                _lcb_tables="$(legacy_tables)"
            else
                _lcb_can=no; _lcb_why="the old database did not answer in time"
            fi
        else
            _lcb_can=no; _lcb_why="the password for the old database is not on file, so it cannot be read"
        fi
    fi

    _lcb_count="$(printf '%s\n' "$_lcb_tables" | grep -c '[^[:space:]]' || true)"
    _lcb_count="${_lcb_count:-0}"
    if [ "$_lcb_can" = yes ] && [ "$_lcb_count" -eq 0 ]; then
        _lcb_can=no; _lcb_why="the old database has no tables in it"
    fi

    # GATE 3. Nothing to offer, so nothing is said. The reason goes to the log,
    # where someone asking "why was I not offered a migration?" can find it,
    # and the crossing is marked done so this is never reconsidered.
    if [ "$_lcb_can" != yes ]; then
        _exakit_log_file "INFO  legacy crossing: no offer made — $_lcb_why" 2>/dev/null || true
        manifest_set legacy.choice "skip"
        manifest_set legacy.crossed_from "$_lcb_type"
        manifest_set legacy.crossing_done true
        # It may still be holding the port, whether or not its data is readable.
        legacy_stop_container >/dev/null 2>&1 || true
        return 0
    fi

    # Past all three gates: there is a real database with real tables in it,
    # and this is the one and only time the user is asked about it.
    echo
    warn "This machine has a starter kit installation whose database runs in a container."
    info "This kit deploys Exasol Personal instead, so that container is not something it can manage."
    [ -n "$_lcb_container" ] && info "The old database is the container '$_lcb_container' ($_lcb_state)."
    info "It holds $_lcb_count table(s). Copying them takes a few minutes and changes nothing in the old database."
    info "One caveat worth knowing: a text column that held an empty string arrives as NULL."

    legacy_choose "$_lcb_count" "$_lcb_can" "$_lcb_why"
    manifest_set legacy.choice "$EXAKIT_LEGACY_CHOICE"
    manifest_set legacy.crossed_from "$_lcb_type"

    if [ "$EXAKIT_LEGACY_CHOICE" = "migrate" ]; then
        info "Copying $_lcb_count table(s) out of the old database"
        _lcb_list=""
        while IFS= read -r _lcb_t; do
            [ -n "$_lcb_t" ] || continue
            _lcb_list="$_lcb_list $_lcb_t"
        done <<EOF
$_lcb_tables
EOF
        # shellcheck disable=SC2086
        if legacy_export "$EXAKIT_LEGACY_EXPORT_DIR" $_lcb_list; then
            manifest_set legacy.export_dir "$EXAKIT_LEGACY_EXPORT_DIR"
            ok "Your data is saved at $(ui_tilde "$EXAKIT_LEGACY_EXPORT_DIR") — it goes into the new database at the end of this install"
        else
            warn "Nothing could be copied out. The old database is untouched; nothing is lost."
            EXAKIT_LEGACY_CHOICE="skip"
            manifest_set legacy.choice "skip"
        fi
    fi

    # BOTH answers stop the container: it is holding the port the new
    # deployment needs. Stopped, not removed — the data volume stays.
    legacy_stop_container || true

    if [ "$EXAKIT_LEGACY_CHOICE" = "skip" ]; then
        info "The old database is left exactly as it was, stopped, with its data."
        _lcb_rm="$(legacy_remove_command 2>/dev/null || true)"
        [ -n "$_lcb_rm" ] && info "When you no longer want it: $_lcb_rm"
    fi
    # The question has now been asked. It is never asked again on this machine,
    # whatever happens to the rest of this run.
    manifest_set legacy.crossing_done true
    echo
    return 0
}

# legacy_crossing_after — the second half: the saved tables into the database
# this install just deployed. Reports what landed and what did not.
legacy_crossing_after() {
    _lca_dir="$(manifest_get legacy.export_dir 2>/dev/null || true)"
    [ -n "$_lca_dir" ] || return 0
    [ -s "$_lca_dir/index" ] || return 0
    [ "$(manifest_get legacy.restored 2>/dev/null || true)" = "" ] || return 0

    echo
    info "Restoring your data into the new database"
    legacy_import "$_lca_dir" || {
        warn "Your data could not be restored. The copy is kept at $(ui_tilde "$_lca_dir")."
        return 0
    }

    ok "Restored ${EXAKIT_LEGACY_RESTORED:-0} table(s) from your previous database"
    if [ "${EXAKIT_LEGACY_SKIPPED:-0}" -gt 0 ]; then
        info "Left alone (this install had already created them):${EXAKIT_LEGACY_SKIPPED_NAMES}"
    fi
    if [ "${EXAKIT_LEGACY_RESTORE_FAILED:-0}" -gt 0 ]; then
        warn "${EXAKIT_LEGACY_RESTORE_FAILED} table(s) did not restore — the copies are still at $(ui_tilde "$_lca_dir")"
        return 0
    fi
    # The copy is only removed once every table is accounted for, and the old
    # container still has the original either way.
    info "The copy at $(ui_tilde "$_lca_dir") is no longer needed; remove it whenever you like."
    _lca_rm="$(legacy_remove_command 2>/dev/null || true)"
    [ -n "$_lca_rm" ] && info "The old container still holds the original. To remove it: $_lca_rm"
    echo
    return 0
}
