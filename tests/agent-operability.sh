#!/usr/bin/env bash
# agent-operability.sh — proves the machine-facing contract an unattended agent
# branches on: status exit codes and --json, the mcp-doctor stopped-database
# short-circuit, the read-only allowlist merge, the DB error translator, the
# dataset visibility in status, and dataset COMMENT coverage.
#
#   bash tests/agent-operability.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s = %s\n' "$1" "$3"; else FAIL=$((FAIL+1)); printf '  FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"; fi; }
has() { case "$3" in *"$2"*) check "$1" present present ;; *) check "$1" present MISSING ;; esac; }

# `lacks` exists because its ABSENCE was a footgun: calling it printed "command
# not found" to stderr and left the counters untouched, so a skipped assertion
# read as a pass. (A command_not_found_handle would be the general guard, but
# that is bash 4.0+ and this repo must run on the 3.2 macOS ships.)
lacks() { case "$3" in *"$2"*) check "$1" absent PRESENT ;; *) check "$1" absent absent ;; esac; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

echo "status exit codes are the answer:"
check "not installed exits 4" "4" "$(EXAKIT_HOME="$WORK/none" bash "$ROOT/setup/exakit" status >/dev/null 2>&1; echo $?)"
has "and the JSON form says so" '"installed": false' "$(EXAKIT_HOME="$WORK/none" bash "$ROOT/setup/exakit" status --json 2>/dev/null)"
check "not installed --json exits 4 too" "4" "$(EXAKIT_HOME="$WORK/none" bash "$ROOT/setup/exakit" status --json >/dev/null 2>&1; echo $?)"

# A manifest whose nano container does not exist reads as a stopped database.
mkdir -p "$WORK/stopped"
printf '{\n  "runtime": {\n    "type": "nano"\n  },\n  "data": {\n    "datasets": {\n      "tpch": {\n        "loaded": true\n      }\n    }\n  }\n}\n' > "$WORK/stopped/manifest.json"
check "stopped database exits 3" "3" "$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" status >/dev/null 2>&1; echo $?)"
_sj="$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" status --json 2>/dev/null)"
check "the JSON is valid JSON" "yes" "$(printf '%s' "$_sj" | python3 -m json.tool >/dev/null 2>&1 && echo yes || echo no)"
has "and carries running=false" '"running": false' "$_sj"
has "and the loaded datasets" '"tpch"' "$_sj"
has "prose names the datasets too" "tpch" "$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" status 2>/dev/null | grep '^Datasets:')"
has "prose names the fix" "exakit start" "$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" status 2>/dev/null | tail -1)"
check "an unknown status flag is refused nonzero" "1" "$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" status --nope >/dev/null 2>&1; echo $?)"

echo "mcp-doctor diagnoses the stopped database first:"
_doc="$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" mcp-doctor 2>&1)"
check "exit 3, same as status" "3" "$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" mcp-doctor >/dev/null 2>&1; echo $?)"
has "and names the remedy" "exakit start" "$_doc"
_docj="$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" mcp-doctor --json 2>/dev/null)"
check "the JSON form is valid" "yes" "$(printf '%s' "$_docj" | python3 -m json.tool >/dev/null 2>&1 && echo yes || echo no)"
has "and carries the remedy" '"remedy": "exakit start"' "$_docj"

echo "every subcommand answers --help from the catalog:"
for _cmd in status data-load logs uninstall marketplace; do
    _h="$(bash "$ROOT/setup/exakit" "$_cmd" --help 2>&1; echo "rc=$?")"
    has "$_cmd --help shows its entry" "exakit $_cmd" "$_h"
    has "and exits 0" "rc=0" "$_h"
done

echo "the read-only allowlist merge:"
. "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
_alh="$WORK/allow-home"
mkdir -p "$_alh"
# Counted from the source, not hardcoded: this assertion is about "a fresh file
# gets EVERY entry", and a literal number turns each new allowlist entry into a
# spurious test failure that says nothing about the behaviour.
_alw_n=$(sed -n '/^ALLOW = \[/,/^\]/p' "$ROOT/setup/lib/common.sh" | grep -c '^[[:space:]]*"')
_dny_n=$(sed -n '/^DENY = \[/,/^\]/p' "$ROOT/setup/lib/common.sh" | grep -c '^[[:space:]]*"')
check "fresh file gets the full list" "ADDED $((_alw_n + _dny_n))" "$(HOME="$_alh" exakit_apply_readonly_allowlist)"
check "second run adds nothing" "ADDED 0" "$(HOME="$_alh" exakit_apply_readonly_allowlist)"
printf '{"model": "opus", "permissions": {"allow": ["Bash(ls:*)"]}}' > "$_alh/.claude/settings.json"
HOME="$_alh" exakit_apply_readonly_allowlist >/dev/null
check "existing settings survive the merge" "opus ls-kept status-added deny-set" "$(python3 -c "
import json; d=json.load(open('$_alh/.claude/settings.json'))
print(d['model'],
      'ls-kept' if 'Bash(ls:*)' in d['permissions']['allow'] else 'ls-LOST',
      'status-added' if 'Bash(exakit status:*)' in d['permissions']['allow'] else 'status-MISSING',
      'deny-set' if 'Bash(exakit uninstall:*)' in d['permissions']['deny'] else 'deny-MISSING')")"
printf 'not json' > "$_alh/.claude/settings.json"
check "a malformed file is left alone" "SKIP unreadable|not json" \
    "$(HOME="$_alh" exakit_apply_readonly_allowlist)|$(cat "$_alh/.claude/settings.json")"

echo "the database error translator:"
has "connection refused names exakit start" "exakit start" \
    "$(exakit_explain_db_error "[Errno 61] Connection refused" 2>&1)"
has "FETCH FIRST names LIMIT" "LIMIT" \
    "$(exakit_explain_db_error "syntax error, unexpected FETCH_, expecting UNION_" 2>&1)"
has "object not found names describe" "describe" \
    "$(exakit_explain_db_error "object O_TOTALAMOUNT not found [line 1]" 2>&1)"
check "an unknown error adds nothing" "0" \
    "$(exakit_explain_db_error "some other failure" 2>&1 | wc -l | tr -d ' ')"

echo "dataset semantics ship as COMMENTs:"
for _ds in tpch energy weather; do
    check "$_ds schema carries table comments" "yes" \
        "$(grep -q 'COMMENT ON TABLE' "$ROOT/data/datasets/$_ds/01_create_schema.sql" && echo yes || echo no)"
done
# Every declared column in every dataset has a COMMENT ON COLUMN — a new
# column without one fails here, so the describe path never goes dark again.
check "every column of every dataset is commented" "all-covered" "$(python3 - "$ROOT" <<'PYEOF'
import re, sys
root = sys.argv[1]
missing = []
for ds in ("tpch", "energy", "weather"):
    s = open("%s/data/datasets/%s/01_create_schema.sql" % (root, ds)).read()
    commented = set(m.upper() for m in re.findall(r"COMMENT ON COLUMN (\w+)\.(\w+)", s) for m in [m[0] + "." + m[1]])
    for tbl, body in re.findall(r"TABLE (\w+) \((.*?)\n\)", s, re.S):
        for line in body.splitlines():
            line = line.strip()
            if not line or line.startswith("--") or line.upper().startswith("CONSTRAINT"):
                continue
            col = line.split()[0].upper().strip(",")
            if col and ("%s.%s" % (tbl.upper(), col)) not in commented:
                missing.append("%s:%s.%s" % (ds, tbl, col))
print("all-covered" if not missing else " ".join(missing[:5]))
PYEOF
)"

echo "menu rows never leave stale lines behind:"
# A row wider than the terminal wraps onto a second line. The redraw used to
# move up one line PER ROW, so every wrapped row left its overflow on screen
# and each keypress stacked another stale copy (an over-long EVERYTHING label
# turned the uninstall menu into a wall of repeated first rows). The menu now
# counts the lines it actually drew.
check "a row narrower than the terminal is one line" "1" "$(_ui_wrapped_lines 40 120)"
check "a row exactly the terminal width is one line" "1" "$(_ui_wrapped_lines 120 120)"
check "one column wider is two lines" "2" "$(_ui_wrapped_lines 121 120)"
check "a very long row counts every line" "3" "$(_ui_wrapped_lines 300 120)"
check "an empty row still occupies one" "1" "$(_ui_wrapped_lines 0 120)"
check "the redraw moves by what was drawn, not by row count" "yes" \
    "$(grep -q 'printf .\\033\[%dA\\033\[0J. "\$_cb_drawn"' "$ROOT/setup/lib/common.sh" && echo yes || echo no)"

# Rows are truncated so they CANNOT wrap: the redraw height is then exact by
# construction instead of trusting width detection, locales and terminal wrap
# rules to agree. And the width itself must come from /dev/tty — `tput cols`
# inside command substitution has a pipe for stdout, cannot ioctl the
# terminal, and silently answers 80, which made the menu climb over the lines
# above it on any terminal that was not 80 columns wide.
check "a short row is untouched" "hello" "$(_ui_fit_row "hello" 10 80)"
_fit_out="$(_ui_fit_row "$(printf 'x%.0s' $(seq 1 200))" 10 80)"
_fit_tail="plain"
case "$_fit_out" in *…) _fit_tail="ends-with-ellipsis" ;; esac
_fit_kept="${_fit_out%…}"
check "a long row is cut to one line with an ellipsis" "69 ends-with-ellipsis" "${#_fit_kept} $_fit_tail"
check "a row exactly at the width is untouched" "70" \
    "$(_ui_fit_row "$(printf 'x%.0s' $(seq 1 70))" 10 80 | awk '{print length($0)}')"
check "the checkbox rows go through the fit" "yes" \
    "$(grep -q '_ui_fit_row "\$_cb_label"' "$ROOT/setup/lib/common.sh" && echo yes || echo no)"
check "the width is read from /dev/tty, not tput-in-a-pipe" "yes" \
    "$(grep -q 'stty size < /dev/tty' "$ROOT/setup/lib/common.sh" && echo yes || echo no)"

# ...and the labels themselves stay inside a normal terminal, so nothing wraps
# in the first place. 100 columns is the bar: narrower than the 120 most
# terminals default to, wide enough for a descriptive label.
check "every menu label fits a normal terminal" "all-fit" "$(python3 - "$ROOT" <<'PYEOF'
import re, sys
root = sys.argv[1]
too_long = []
for path in ("setup/lib/common.sh",):
    for label in re.findall(r'_um_labels\+=\("([^"]+)"\)|_mm_menu_labels\+=\("([^"]+)"\)', open(root + "/" + path).read()):
        text = (label[0] or label[1]).lstrip("#!")
        # 10 columns of chrome: four leading spaces, the pointer, and "[x] ".
        if len(text) + 10 > 100:
            too_long.append("%d cols: %s" % (len(text) + 10, text[:50]))
print("all-fit" if not too_long else " | ".join(too_long))
PYEOF
)"


# ---------------------------------------------------------------------------
echo
echo "every state query answers machine-readably in BOTH states (audit regressions):"
# ---------------------------------------------------------------------------
# These four used to exit 1 with EMPTY stdout when nothing was installed, so an
# agent piping --json into a parser got "Expecting value: line 1 column 1" on
# exactly the path where structured signal decides the next action.
for _q in "info --json" "mcp-doctor --json"; do
    _out="$(EXAKIT_HOME="$WORK/none" bash "$ROOT/setup/exakit" $_q 2>/dev/null)"
    _rc="$(EXAKIT_HOME="$WORK/none" bash "$ROOT/setup/exakit" $_q >/dev/null 2>&1; echo $?)"
    check "$_q exits 4 when not installed" "4" "$_rc"
    check "$_q is parseable JSON when not installed" "yes" \
        "$(printf '%s' "$_out" | python3 -m json.tool >/dev/null 2>&1 && echo yes || echo no)"
    has  "$_q names a remedy" '"remedy"' "$_out"
done
check "mcp-doctor (human) exits 4 when not installed" "4" \
    "$(EXAKIT_HOME="$WORK/none" bash "$ROOT/setup/exakit" mcp-doctor >/dev/null 2>&1; echo $?)"
check "version exits 4 when not installed" "4" \
    "$(EXAKIT_HOME="$WORK/none" bash "$ROOT/setup/exakit" version >/dev/null 2>&1; echo $?)"
check "update-check exits 4 when not installed" "4" \
    "$(EXAKIT_HOME="$WORK/none" bash "$ROOT/setup/exakit" update-check >/dev/null 2>&1; echo $?)"

echo
echo "the JSON carries the remedy the prose already had:"
_rj="$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" status --json 2>/dev/null)"
has "status --json has a remedies map" '"remedies"' "$_rj"
has "a stopped database names exakit start" 'exakit start' "$_rj"
has "a missing pyexasol names its repair" 'exakit update pyexasol' "$_rj"
has "status --json exposes last_failure" '"last_failure"' "$_rj"

echo
echo "the read-only allowlist covers the read-only surface it documents:"
# The doc's principle is "allow what changes nothing". Every read-only command
# the catalog declares must be in ALLOW, or the friction it promises to remove
# is still being asked for.
# Entries only: the block's own comments mention the patterns it deliberately
# does NOT grant, so grepping them would assert the opposite of the truth.
_allow="$(sed -n '/^ALLOW = \[/,/^\]/p' "$ROOT/setup/lib/common.sh" | grep -v '^[[:space:]]*#')"
for _cmd in status info version mcp-doctor logs catalog preflight update-check guide mcp-status mcp-validate; do
    has "allowlist covers exakit $_cmd" "exakit $_cmd" "$_allow"
done
# ...and must NOT auto-allow anything that writes, including the command that
# writes this very settings file.
_deny="$(sed -n '/^DENY = \[/,/^\]/p' "$ROOT/setup/lib/common.sh" | grep -v '^[[:space:]]*#')"
case "$_allow" in
    *"exakit skills:*"*) check "allowlist does not prefix-match skills-install" "safe" "PREFIX-MATCHES-INSTALL" ;;
    *) check "allowlist does not prefix-match skills-install" "safe" "safe" ;;
esac
case "$_allow" in
    *"exapump"*) check "exapump sql still prompts" "gated" "ALLOWLISTED" ;;
    *) check "exapump sql still prompts" "gated" "gated" ;;
esac
has "uninstall stays denied" "exakit uninstall" "$_deny"

echo
echo "the error translator covers the faults that would otherwise loop:"
_xl="$(sed -n '/^exakit_explain_db_error()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "privilege denial is translated" "insufficient privileges" "$_xl"
has "and forbids escalating via exapump" "not sandboxed" "$_xl"
_ux="$(sed -n '/^exakit_explain_uv_python_error()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "corrupt uv Python is translated" "uv python install" "$_ux"

echo
echo "the kit copy staged for an installed machine carries skills/:"
# Omitting skills/ here does not fall back to the checkout -- exakit_repo_root
# PREFERS the staged copy, so it shadows it and every skills command reports
# "no skills/ directory in this kit build" on a working install.
_stage="$(grep -n 'cp -R "$_kit_root/' "$ROOT/setup/lib/common.sh")"
has "staging copies skills/" 'skills" "$EXAKIT_HOME/kit/"' "$_stage"
_mo="$(sed -n '/^exakit_maybe_offer_skills_install()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "a missing skills/ is a recorded failure, not a silent success" "exakit_note_failure" "$_mo"


# ---------------------------------------------------------------------------
echo
echo "round-2 audit regressions:"
# ---------------------------------------------------------------------------
# A failure note with no date cannot be told from a current one, and an undated
# note that outlived its cause is how a healthy machine came to look broken.
_nf="$(sed -n '/^exakit_note_failure()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "the failure note records when it happened" '_exakit_ts' "$_nf"
_sj2="$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" status --json 2>/dev/null)"
has "status --json exposes last_failure_at" '"last_failure_at"' "$_sj2"

# A kit update replaces the whole kit copy, so a release that adds or rewords a
# skill leaves the discovery folders holding the previous text. Detecting that
# and never resolving it just moves the work to the user.
_us="$(sed -n '/^exakit_update_self()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "a kit self-update refreshes the installed skills" "exakit_install_skills" "$_us"

# The library-not-found message named the default path even when EXAKIT_HOME
# pointed somewhere else, sending the reader to a directory the code never read.
has "the lib-not-found error names the path actually searched" \
    'kit/setup/lib)' "$(sed -n '1,80p' "$ROOT/setup/exakit")"

# doctor's findings carry remedies; returning next_actions=[] beside a non-empty
# findings list reads as "nothing to do" on a machine with problems.
has "doctor derives next_actions from its findings" "next_actions=next_actions" \
    "$(sed -n '/def _doctor/,/def _uninstall/p' "$ROOT/mcp/service.py")"
has "and NextAction is imported so it cannot NameError" "    NextAction," \
    "$(sed -n '1,40p' "$ROOT/mcp/service.py")"

# detect_container_runtime falls back to podman, so a docker-hang fixture that
# masks only docker lets a real podman answer -- and "podman" is then correct,
# which the assertion scored as a failure. Intermittent on Linux CI by nature.
has "the docker-hang fixture masks podman too" "for _hang_engine in docker podman" \
    "$(cat "$ROOT/tests/versions-manifest.sh")"

# common.sh derives EXAKIT_HOME from the environment, so a helper that forgets to
# isolate it writes into the developer's live installation.
_pld="$(sed -n '/^_pld_run()/,/^}/p' "$ROOT/tests/dry-run-matrix.sh")"
has "the downgrade-guard fixture isolates EXAKIT_HOME" 'EXAKIT_HOME="$_pld_dir/home"' "$_pld"
has "and the suite asserts it left the real home clean" "no failure note in the real kit home" \
    "$(cat "$ROOT/tests/dry-run-matrix.sh")"


# A subprocess-driven test cannot mock connectivity, so a hardcoded 127.0.0.1:8563
# made the result depend on whether the developer had the kit running: green for
# them, red on every clean machine and CI runner. The test must own its endpoint.
_cli_t="$(sed -n '/class StaleVersionPinCLITests/,$p' "$ROOT/mcp/tests/test_stale_version_pin.py")"
has "the CLI stale-pin test binds its own listener" "socket.socket(socket.AF_INET" "$_cli_t"
# The manifest must carry the port the test itself bound, not a fixed one.
has "and writes that port into its manifest" '_write_manifest(self.dsn)' "$_cli_t"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
