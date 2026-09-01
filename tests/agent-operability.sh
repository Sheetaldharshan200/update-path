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

# The command surface now lives in setup/help/*.json (one document per
# component plus one for the CLI), not in a TSV. This prints every command
# name the CLI document declares, which is what the catalog assertions want.
exakit_help_commands() {
    python3 -c "
import json
doc = json.load(open('$ROOT/setup/help/exakit.json'))
print(chr(10).join(c['command'] for c in doc['commands']))"
}

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
# Asserted against the whole screen, not a `grep '^Datasets:'`. That prose line
# stopped existing when the Data PANEL replaced it, and grepping for a line that
# is never there made this assertion fail on main for as long as the panel has
# been the way datasets are shown. What it was really guarding is that an agent
# reading the human output can still see which datasets are loaded, and the
# panel row says so.
has "the human screen names the datasets too" "tpch" \
    "$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" status 2>/dev/null)"
has "prose names the fix" "exakit start" "$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" status 2>/dev/null | tail -1)"
# 2, not 1: bad input has its own code across the CLI now (the same one an
# unknown subcommand uses), so an agent can tell "I typed it wrong" from "the
# command ran and failed". It also records no failure note — see the reject
# assertions further down.
check "an unknown status flag is refused with the bad-input code" "2" "$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" status --nope >/dev/null 2>&1; echo $?)"

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
# Counted from what was actually written, not from the source text: the lists are
# generated (one entry per command per invocation spelling), so a literal number
# — or a grep for quoted source lines — turns every new entry into a spurious
# failure that says nothing about the behaviour.
_alw_first="$(HOME="$_alh" exakit_apply_readonly_allowlist)"
_alw_total=$(python3 -c "
import json; d=json.load(open('$_alh/.claude/settings.json'))['permissions']
print(len(d['allow']) + len(d['deny']))")
check "fresh file gets the full list" "ADDED $_alw_total" "$_alw_first"
check "second run adds nothing" "ADDED 0" "$(HOME="$_alh" exakit_apply_readonly_allowlist)"

# THE REGRESSION THIS PINS: the rules matched only a bare `exakit`, while
# AGENTS.md tells agents ~/.local/bin is off a non-interactive PATH and to call
# the binary by absolute path. Every "pre-approved" read-only command therefore
# kept prompting. Each spelling the docs hand an agent has to be covered.
check "every invocation spelling is allowlisted" "bare ok | tilde ok | home ok | deny all 3" "$(python3 -c "
import json; a=json.load(open('$_alh/.claude/settings.json'))['permissions']
allow, deny = a['allow'], a['deny']
print('bare ok' if 'Bash(exakit status:*)' in allow else 'bare MISSING',
      '| tilde ok' if 'Bash(~/.local/bin/exakit status:*)' in allow else '| tilde MISSING',
      '| home ok' if 'Bash(\$HOME/.local/bin/exakit status:*)' in allow else '| home MISSING',
      '| deny all 3' if len([d for d in deny if 'uninstall' in d]) == 3 else '| deny ONLY %d' % len([d for d in deny if 'uninstall' in d]))")"
check "and the PowerShell twin lists the same spellings" "yes" \
    "$(grep -q '\$prefixes = @("exakit", "~/.local/bin/exakit"' "$ROOT/setup/lib/exakit-common.ps1" && echo yes || echo no)"
# exapump sql must NEVER be pre-approved: that profile is the admin connection,
# and auto-allowing it is exactly the trust model the kit sells being switched off.
check "exapump sql is still gated" "gated" "$(python3 -c "
import json; a=json.load(open('$_alh/.claude/settings.json'))['permissions']['allow']
print('LEAKED' if any('exapump' in e for e in a) else 'gated')")"
check "and so is exakit sql" "gated" "$(python3 -c "
import json; a=json.load(open('$_alh/.claude/settings.json'))['permissions']['allow']
print('LEAKED' if any('exakit sql' in e for e in a) else 'gated')")"
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
# `exakit update-check` was merged into `exakit version`; it is not a command any
# more, so it must answer like any other unknown one rather than lingering as a
# hidden alias an agent could keep depending on.
check "update-check is gone, and exits like an unknown command" "2" \
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
# Asserted against the settings file the merge WRITES, not against the source
# text: the lists are generated (one entry per command per invocation spelling),
# so grepping the source would assert the shape of the code rather than the
# behaviour — and the block's own comments name the patterns it deliberately does
# NOT grant, so a source grep can assert the exact opposite of the truth.
_surface_home="$WORK/allow-surface"
mkdir -p "$_surface_home"
HOME="$_surface_home" exakit_apply_readonly_allowlist >/dev/null
_allow="$(python3 -c "
import json; print('\n'.join(json.load(open('$_surface_home/.claude/settings.json'))['permissions']['allow']))")"
for _cmd in status info version mcp-doctor logs catalog preflight guide mcp-status; do
    has "allowlist covers exakit $_cmd" "exakit $_cmd" "$_allow"
done
# ...and must NOT auto-allow anything that writes, including the command that
# writes this very settings file.
_deny="$(python3 -c "
import json; print('\n'.join(json.load(open('$_surface_home/.claude/settings.json'))['permissions']['deny']))")"
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
# Matched against the whole file, not a fixed line range: the range was the
# header comment's length, so adding a command to the usage block broke an
# assertion that has nothing to do with the usage block.
has "the lib-not-found error names the path actually searched" \
    'kit/setup/lib)' "$(grep -n 'cannot find the kit library' -A2 "$ROOT/setup/exakit")"

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


# ---------------------------------------------------------------------------
echo
echo "no test writes through a symlink into a shared interpreter:"
# ---------------------------------------------------------------------------
# A uv-created venv's bin/python is a SYMLINK to the shared managed CPython, and
# `>` follows symlinks. Writing a stub through one replaced the developer's real
# 18 MB interpreter with 17 bytes and broke uv for every later component install
# -- which then surfaced as an unrelated-looking "the virtual environment could
# not be created". Every such write must rm -f the path first.
_sym_unguarded=0
for _sym_file in "$ROOT"/tests/*.sh; do
    # Skip this file: the patterns below are themselves quoted globs that would
    # match, so the linter would only ever report itself.
    case "$_sym_file" in *agent-operability.sh) continue ;; esac
    _sym_prev=""
    while IFS= read -r _sym_line; do
        case "$_sym_line" in
            *'> "'*'/bin/python"'*|*'> "'*'venv/bin/python"'*)
                case "$_sym_line" in *"rm -f"*) ;; *)
                    case "$_sym_prev" in
                        *"rm -f"*) ;;
                        *) _sym_unguarded=$((_sym_unguarded + 1))
                           printf '       unguarded: %s: %s\n' "$(basename "$_sym_file")" \
                               "$(printf '%s' "$_sym_line" | sed 's/^[[:space:]]*//' | cut -c1-58)" ;;
                    esac ;;
                esac ;;
        esac
        _sym_prev="$_sym_line"
    done < "$_sym_file"
done
check "every stub-python write rm -f's the path first" "0" "$_sym_unguarded"


# A module that says "Retry with: <command>" without first explaining the
# underlying fault turns a corrupt uv managed-Python into an infinite loop: the
# retry fails identically and advises itself. pyexasol had the explanation and
# dash-server and json-tables did not, so the same fault looped for two of three.
for _rt_mod in pyexasol dash-server json-tables; do
    _rt_file="$ROOT/setup/lib/$_rt_mod.sh"
    [ -f "$_rt_file" ] || continue
    if grep -q "Retry with:" "$_rt_file" 2>/dev/null; then
        has "$_rt_mod explains the fault before offering a retry" \
            "exakit_explain_last_log_error" "$(cat "$_rt_file")"
    fi
done


# ---------------------------------------------------------------------------
echo
echo "every hermetic suite is actually wired into CI:"
# ---------------------------------------------------------------------------
# A suite CI never runs rots silently. That is how the MCP tests came to depend
# on the developer's own database, and how the data-load schema test came to
# assert a prompt wording the JSON support had changed. The two exclusions below
# are deliberate and need a live database or a full install to mean anything.
_wf="$ROOT/.github/workflows/versions.yml"
for _suite in agent-operability dry-run-matrix marketplace noninteractive-answers \
              ps-encoding-guard skills uninstall versions-manifest reap-orphan-daemon smoke-test; do
    has "CI runs tests/$_suite.sh" "tests/$_suite.sh" "$(cat "$_wf")"
done
has "CI runs the MCP python tests" "unittest discover -s mcp/tests" "$(cat "$_wf")"
has "CI runs the sample-data schema test" "tests/test_sample_data_schema.py" "$(cat "$_wf")"


# ---------------------------------------------------------------------------
echo
echo "concurrent manifest writes do not lose each other:"
# ---------------------------------------------------------------------------
# manifest_set is a read-modify-write. Unlocked, concurrent writers each read the
# same document and the last save wins: 17 of 20 parallel writes were lost, and
# all 30 mixed rounds lost something. Two kit processes at once is ordinary --
# `exakit start` brings up the database and every service, autostart can fire at
# boot while another command runs, and an agent may issue two in parallel.
_mr_home="$WORK/manifest-race"
mkdir -p "$_mr_home"
printf '{"components":{}}\n' > "$_mr_home/manifest.json"
_mr_n=12
_mr_i=1
while [ "$_mr_i" -le "$_mr_n" ]; do
    ( EXAKIT_HOME="$_mr_home" EXAKIT_MANIFEST="$_mr_home/manifest.json" \
        bash -c ". \"$ROOT/setup/lib/common.sh\" >/dev/null 2>&1; manifest_set race.k$_mr_i v$_mr_i" \
        >/dev/null 2>&1 ) &
    _mr_i=$((_mr_i + 1))
done
wait
_mr_got="$(python3 -c "
import json
try:
    print(len(json.load(open('$_mr_home/manifest.json')).get('race', {})))
except Exception:
    print('unreadable')" 2>/dev/null)"
check "every concurrent write survives" "$_mr_n" "$_mr_got"
# os.replace keeps the document valid even unlocked, so validity alone would not
# have caught this -- assert completeness, not just parseability.
check "and the manifest is still valid JSON" "yes" \
    "$(python3 -c "import json;json.load(open('$_mr_home/manifest.json'))" 2>/dev/null && echo yes || echo no)"
# The lock must span read AND write, in both shells.
has "bash locks the read-modify-write" "_exakit_locked" "$(cat "$ROOT/setup/lib/common.sh")"
has "and no writer uses a shared temp name" "tempfile.mkstemp" "$(cat "$ROOT/setup/lib/common.sh")"
lacks "no fixed .tmp write remains" 'tmp = path + ".tmp"' "$(cat "$ROOT/setup/lib/common.sh")"
_psc="$(cat "$ROOT/setup/lib/exakit-common.ps1")"
has "PowerShell twin takes the same lock" "Enter-ExakitManifestLock" "$_psc"
has "and releases it in a finally block" "Exit-ExakitManifestLock \$lock" "$_psc"
lacks "PowerShell has no shared temp name either" 'ManifestPath.tmp"' "$_psc"

# ---------------------------------------------------------------------------
# The agent-operability audit's findings, each pinned so it cannot come back.
# Every assertion below FAILS without the fix it guards; that is the point of
# having it. The comment on each says what the agent actually saw.
# ---------------------------------------------------------------------------

echo "a database that cannot start is not reported as merely stopped:"
# THE BUG: SIGKILL the runner and the launcher records the deployment as
# interrupted, after which every `exakit start` fails identically forever.
# personal_status collapsed that into "stopped", so status said "Start it:
# exakit start" -- the loop the reader was already in -- and the installer
# skipped the deployment step as already done and failed the same way on every
# re-run, with EXAKIT_REUSE_DB=0 never getting a say.
_wedge="$WORK/wedged"
mkdir -p "$_wedge/deploy"
printf '{"currentWorkflowState": {"interrupted": {"error": "local VM state contains invalid database port: 0", "interruptedDuringOperation": "start"}}}\n' \
    > "$_wedge/deploy/.exasolLauncherState.json"
. "$ROOT/setup/lib/runtime-personal.sh" >/dev/null 2>&1
EXAKIT_PERSONAL_DEPLOY_DIR="$_wedge/deploy"
check "an interrupted deployment is detected" "wedged" \
    "$(personal_deployment_wedged >/dev/null 2>&1 && echo wedged || echo missed)"
check "and the remedy is the repair, not a start" "exakit repair-runtime" "$(exakit_runtime_remedy)"
# The livelock itself: begin_step skips a step whose artifact state is anything
# but a proven "missing", so runtime answering "unknown" here is what made a
# wedged database unrecoverable by ANY documented route.
check "the runtime step re-runs instead of being skipped" "missing" "$(step_artifact_state runtime)"
# Called WITHOUT a subshell: the reason travels in a variable, and $( ) would
# discard it along with the subshell that set it.
EXAKIT_STEP_RERUN_REASON=""
step_artifact_state runtime >/dev/null
has "and says why, rather than 'what it installed is missing'" "interrupted" \
    "${EXAKIT_STEP_RERUN_REASON:-}"
# A merely stopped deployment must NOT be judged missing: that would redeploy a
# healthy database and destroy its data.
EXAKIT_PERSONAL_DEPLOY_DIR="$_wedge/absent"
check "a stopped deployment is still left alone" "unknown" "$(step_artifact_state runtime)"
has "repair-runtime is a real command" "repair-runtime" "$(grep -c '^    repair-runtime)' "$ROOT/setup/exakit" >/dev/null && echo repair-runtime)"
has "and it is in the catalog" "repair-runtime" "$(exakit_help_commands)"
has "and the PowerShell twin exists" "Invoke-CmdRepairRuntime" "$(cat "$ROOT/setup/exakit.ps1")"

echo "a removed exapump profile is repaired by re-running the installer:"
# THE BUG: the exapump step writes a binary AND a connection profile, but its
# artifact check looked only at the binary. A profile that had been removed --
# by a test suite that sandboxed EXAKIT_HOME but not HOME, in the case that
# found this -- left the step "already done, skipping" on every re-run while
# `exapump sql -p starter-kit` answered "Profile 'starter-kit' not found in
# config" forever. Re-running the installer is meant to be the cure for exactly
# that shape of damage.
_xp="$WORK/exapump-step"
mkdir -p "$_xp/bin"
printf '#!/bin/sh\nexit 0\n' > "$_xp/bin/exapump"; chmod +x "$_xp/bin/exapump"
( EXAKIT_HOME="$_xp/home" bash -c '
    . "'"$ROOT"'/setup/lib/common.sh" >/dev/null 2>&1
    manifest_get() { [ "$1" = components.exapump.path ] && printf "%s\n" "'"$_xp"'/bin/exapump"; }
    EXAPUMP_CONFIG="'"$_xp"'/missing/config.toml"
    printf "profile-gone=%s\n" "$(step_artifact_state exapump)"
    mkdir -p "'"$_xp"'/present"; printf "x\n" > "'"$_xp"'/present/config.toml"
    EXAPUMP_CONFIG="'"$_xp"'/present/config.toml"
    printf "profile-there=%s\n" "$(step_artifact_state exapump)"
' ) > "$WORK/xp.out" 2>/dev/null
has "a missing profile re-runs the step" "profile-gone=missing" "$(cat "$WORK/xp.out")"
has "and a present one leaves it alone" "profile-there=present" "$(cat "$WORK/xp.out")"
# begin_step reads the artifact state in a command substitution, so the reason
# the state set died with the subshell and every re-run reported the generic
# "what it installed is missing" -- the one line that could have said which
# artifact was actually gone.
_xp_reason="$(EXAKIT_HOME="$_xp/home2" bash -c '
    . "'"$ROOT"'/setup/lib/common.sh" >/dev/null 2>&1
    manifest_get() { [ "$1" = components.exapump.path ] && printf "%s\n" "'"$_xp"'/bin/exapump"; }
    step_done() { return 0; }
    EXAPUMP_CONFIG="'"$_xp"'/gone/config.toml"
    begin_step exapump "exapump" 2>&1' 2>/dev/null)"
has "and the re-run says WHICH artifact was gone" "connection profile is gone" "$_xp_reason"
# The removal that caused it must go through the shared variable, so a suite
# that sandboxes it cannot reach the developer's real profile directory.
lacks "uninstall never hardcodes the real HOME for profiles" 'rm -rf "$HOME/.exapump"' \
    "$(cat "$ROOT/setup/lib/common.sh")"
has "and the marketplace suite sandboxes HOME" 'HOME="$WORK/fake-home"' \
    "$(cat "$ROOT/tests/marketplace.sh")"

echo "status reports the datasets that are really there:"
# THE BUG: after a destroy+redeploy, `exakit status --json` reported
# datasets_loaded ["energy","tpch","weather"] against a database with ZERO
# schemas -- the worst possible answer for an agent rebuilding its bearings,
# because it goes straight to "object TPCH.LINEITEM not found" with the real
# cause recorded nowhere.
has "loaded datasets are verified against the database, not just read" \
    "exakit_verified_datasets" "$(sed -n '/^exakit_loaded_datasets()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "and the PowerShell twin verifies too" "Get-ExakitVerifiedDatasets" \
    "$(sed -n '/^function Get-ExakitLoadedDatasets/,/^}/p' "$ROOT/setup/exakit.ps1")"
# THE SECOND HALF: the self-heal wrote data.loaded (tpch's flag= override) while
# status read data.datasets.tpch.loaded, so the heal fired and status kept lying.
has "the self-heal writes the key status reads" "data.datasets.\${_dl_id}.loaded" \
    "$(sed -n '/^exakit_dataset_loaded()/,/^}/p' "$ROOT/setup/lib/exapump.sh")"
has "the load path asks the database, not the manifest flag" "exakit_dataset_loaded" \
    "$(sed -n '/already loaded (pass --force/,+0p;/_ld_markers=/,+3p' "$ROOT/setup/lib/exapump.sh")"
# THE THIRD: exakit_db_reachable cached its "no" for the whole process, so an
# installer run that redeployed the database kept the answer it got while the
# old one was down and reported every dataset "already loaded" into an empty DB.
lacks "a negative db-reachable answer is never cached" '[ -z "$_EXAKIT_DB_REACHABLE" ]' \
    "$(sed -n '/^exakit_db_reachable()/,/^}/p' "$ROOT/setup/lib/exapump.sh")"
has "and stopping the database drops the cached yes" "exakit_forget_db_reachable" \
    "$(cat "$ROOT/setup/lib/runtime-personal.sh" "$ROOT/setup/lib/runtime-nano.sh")"

echo "every --json answer has the same three keys:"
# THE BUG: healthy mcp-doctor returned status/findings/next_actions, a stopped
# database returned {"database","remedy"}, and not-installed returned
# {"installed":false,...}. No key was common to all three, so a parser that read
# .status off the healthy shape hit a KeyError on the two states worth branching
# on. Asserted on the two shapes that need no live database.
# Through a FILE, not an interpolated string: the payloads contain quotes and
# newlines, and embedding them in a python literal tests the quoting, not the kit.
_common_keys() {
    python3 - "$1" <<'PY'
import json, sys
want = {"installed", "status", "remedy"}
try:
    with open(sys.argv[1]) as handle:
        doc = json.load(handle)
except (OSError, ValueError) as exc:
    print("unparseable: %s" % exc)
    raise SystemExit(0)
missing = sorted(want - set(doc))
print("yes" if not missing else "missing %s" % missing)
PY
}
for _shape in status mcp-doctor; do
    EXAKIT_HOME="$WORK/none" bash "$ROOT/setup/exakit" $_shape --json > "$WORK/shape.json" 2>/dev/null
    check "$_shape --json (not installed) carries installed/status/remedy" "yes" \
        "$(_common_keys "$WORK/shape.json")"
    EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" $_shape --json > "$WORK/shape.json" 2>/dev/null
    check "$_shape --json (database down) carries them too" "yes" \
        "$(_common_keys "$WORK/shape.json")"
done

echo "the documented exit codes are the real ones:"
# THE BUG: AGENTS.md promised 0/3/4 on status, version, info --json
# and mcp-doctor. Measured with the database stopped: only status and mcp-doctor
# returned 3. info --json returned 0 -- so an agent branching the way it was told
# read "healthy" off a stopped database.
check "info --json exits 3 when the database is down" "3" \
    "$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" info --json >/dev/null 2>&1; echo $?)"
check "info --json exits 4 when nothing is installed" "4" \
    "$(EXAKIT_HOME="$WORK/none" bash "$ROOT/setup/exakit" info --json >/dev/null 2>&1; echo $?)"
check "and still prints an object in both states" "yes" "$(
    EXAKIT_HOME="$WORK/none" bash "$ROOT/setup/exakit" info --json 2>/dev/null | python3 -m json.tool >/dev/null 2>&1 && echo yes || echo no)"
# `exakit version` reports on VERSIONS, which a stopped database does not
# change. AGENTS.md must not promise a database-health code they never return.
check "version does not fake a database-health code" "0" \
    "$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" version >/dev/null 2>&1; echo $?)"
lacks "and AGENTS.md no longer claims otherwise" \
    'Exit codes on `status`, `version`, `update-check`, `info --json` and `mcp-doctor`: `0` healthy/running, `3` database not running' \
    "$(cat "$ROOT/AGENTS.md")"
check "an unknown subcommand still exits 2" "2" \
    "$(bash "$ROOT/setup/exakit" frobnicate >/dev/null 2>&1; echo $?)"

echo "the SQL path an agent is told to use names its remedy:"
# THE BUG: exakit_explain_db_error was wired ONLY into the kit's internal setup
# SQL -- the one path no agent ever sees. Running SQL the documented way gave the
# raw engine text, so "every error message names its remedy" was true of the
# lifecycle commands and false of the SQL path the skill mandates for every
# validation.
has "exakit sql exists" "cmd_sql" "$(cat "$ROOT/setup/exakit")"
has "and routes failures through the translator" "exakit_explain_db_error" \
    "$(sed -n '/^cmd_sql()/,/^}/p' "$ROOT/setup/exakit")"
has "and is in the catalog" "sql" "$(exakit_help_commands)"
has "the PowerShell twin exists" "Invoke-CmdSql" "$(cat "$ROOT/setup/exakit.ps1")"
# PowerShell had NO translator at all: the Windows and Nano paths got raw engine
# text and nothing else, making the promise macOS-only.
has "PowerShell has the translator too" "Show-ExakitDbErrorRemedy" \
    "$(cat "$ROOT/setup/lib/exakit-common.ps1")"
for _case in "LIMIT" "exakit start" "describe it first"; do
    has "PowerShell translator covers '$_case'" "$_case" \
        "$(sed -n '/^function Show-ExakitDbErrorRemedy/,/^}/p' "$ROOT/setup/lib/exakit-common.ps1")"
done
# The gate: a seatbelt, not a sandbox -- but it must at least refuse the two
# shapes that are never wanted from a "read" command.
_sqlw="$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" sql "DROP TABLE T" 2>&1)"
has "a write is refused without --write" "not a read statement" "$_sqlw"
_sqlm="$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" sql "SELECT 1; DROP TABLE T" 2>&1)"
has "and a smuggled second statement is refused" "Only one statement" "$_sqlm"
# A REJECTED STATEMENT IS NOT AN INSTALL FAILURE. `.last-failure` is what
# `exakit status --json` reports as `last_failure`, so recording a typo there
# hangs a stale "failure" off an otherwise healthy machine — and an agent that
# reads status to reconstruct its bearings acts on it.
check "a rejected statement leaves no failure note" "clean" \
    "$([ -f "$WORK/stopped/.last-failure" ] && echo "POLLUTED: $(head -1 "$WORK/stopped/.last-failure")" || echo clean)"
check "and exits 2, like any other bad input" "2" \
    "$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" sql "DROP TABLE T" >/dev/null 2>&1; echo $?)"

echo "data-load --force honours the dataset selection:"
# THE BUG: EXAKIT_DATASETS=tpch,energy,weather exakit data-load --force reloaded
# tpch ALONE and reported success, with no non-interactive way to reload the
# others short of a full re-install. --force means "reload anyway", not "reload
# something else".
_dlf="$(sed -n '/^cmd_data_load()/,/^}/p' "$ROOT/setup/exakit")"
has "--force still reads EXAKIT_DATASETS" "EXAKIT_DATASETS" "$_dlf"
has "and the PowerShell twin does too" "EXAKIT_DATASETS" \
    "$(sed -n '/^function Invoke-CmdDataLoad/,/^}/p' "$ROOT/setup/exakit.ps1")"
# ...and it has to be discoverable from the CLI, not only from AGENTS.md.
has "the catalog documents the variable" "EXAKIT_DATASETS" "$(cat "$ROOT/setup/help/exakit.json")"

echo "data-load loads a named local file without a terminal:"
# THE BUG: the local-file option was prompt-only — an agent without a tty
# could neither choose it nor name the file, so AGENTS.md sent agents around
# exakit entirely. EXAKIT_DATA_FILE / EXAKIT_DATA_TABLE now answer the menu,
# the path, and the target table — the same contract as EXAKIT_DATASETS.
has "the menu honours EXAKIT_DATA_FILE" "EXAKIT_DATA_FILE" \
    "$(sed -n '/^exakit_data_load_select()/,/^}/p' "$ROOT/setup/lib/exapump.sh")"
has "the local-file loader honours it too" "EXAKIT_DATA_FILE" \
    "$(sed -n '/^exakit_load_local_file()/,/^}/p' "$ROOT/setup/lib/exapump.sh")"
has "and the target table" "EXAKIT_DATA_TABLE" \
    "$(sed -n '/^exakit_load_local_file()/,/^}/p' "$ROOT/setup/lib/exapump.sh")"
has "the PowerShell menu twin honours it" "EXAKIT_DATA_FILE" \
    "$(sed -n '/^function Select-ExakitDataLoad/,/^}/p' "$ROOT/setup/lib/exapump.ps1")"
has "and the PowerShell loader too" "EXAKIT_DATA_FILE" \
    "$(sed -n '/^function Import-ExakitLocalFile/,/^}/p' "$ROOT/setup/lib/exapump.ps1")"
has "with the target table" "EXAKIT_DATA_TABLE" \
    "$(sed -n '/^function Import-ExakitLocalFile/,/^}/p' "$ROOT/setup/lib/exapump.ps1")"
has "the catalog documents EXAKIT_DATA_FILE" "EXAKIT_DATA_FILE" "$(cat "$ROOT/setup/help/exakit.json")"
has "and EXAKIT_DATA_TABLE" "EXAKIT_DATA_TABLE" "$(cat "$ROOT/setup/help/exakit.json")"
# The runbook must stop steering agents away from data-load: that sentence
# described the prompt-only behaviour this contract replaces.
lacks "AGENTS.md no longer routes agents around data-load" \
    "prompts for the path on a TTY and is skipped without one" "$(cat "$ROOT/AGENTS.md")"

echo "the discovery surfaces are machine-readable:"
# THE BUG: an agent told to "discover every command with exakit catalog" had to
# pattern-match an ANSI-decorated screen; `exakit logs` was prose only too.
check "catalog --json is one object" "yes" \
    "$(bash "$ROOT/setup/exakit" catalog --json 2>/dev/null | python3 -m json.tool >/dev/null 2>&1 && echo yes || echo no)"
bash "$ROOT/setup/exakit" catalog --json > "$WORK/catalog.json" 2>/dev/null
check "and it finds the commands" "yes" "$(python3 - "$WORK/catalog.json" <<'PY'
import json, sys
want = {"status", "sql", "repair-runtime"}
doc = json.load(open(sys.argv[1]))
names = {command["command"] for command in doc["commands"]}
missing = sorted(want - names)
print("yes" if not missing else "missing %s" % missing)
PY
)"
# THE BUG: asking for an add-on's log before it is installed answered "No log
# called 'dash-server'. Available: setup json-tables ..." - a list that does not
# contain it, leaving the reader to work out why theirs is missing. A registered
# add-on that is simply not installed is a state, not an unknown name.
_log_addon="$(EXAKIT_HOME="$WORK/none" bash "$ROOT/setup/exakit" logs dash-server 2>&1 || true)"
has "an uninstalled add-on's log says it is not installed" "is not installed" "$_log_addon"
has "and says how to get it" "exakit marketplace" "$_log_addon"
lacks "and does not call it an unknown name" "No log called" "$_log_addon"
_log_bogus="$(EXAKIT_HOME="$WORK/none" bash "$ROOT/setup/exakit" logs banana 2>&1 || true)"
has "a name that is nothing at all is still unknown" "No log called" "$_log_bogus"

check "logs --json is one object even with no logs" "yes" \
    "$(EXAKIT_HOME="$WORK/none" bash "$ROOT/setup/exakit" logs --json 2>/dev/null | python3 -m json.tool >/dev/null 2>&1 && echo yes || echo no)"
# The rows go through argv, not stdin: run_python reads the PROGRAM from stdin,
# so a piped payload silently produced zero targets.
lacks "logs --json does not feed data on stdin" 'printf .%s. "$_loj_rows" | run_python' \
    "$(cat "$ROOT/setup/lib/common.sh")"

echo "mcp-doctor actually starts the server it calls connected:"
# THE BUG: every doctor stage inspected paperwork -- config syntax read the client
# file, "connectivity" opened a TCP socket to the DATABASE, manifest consistency
# compared hashes. Nothing ran the configured command, so a missing uvx or a
# package that would not resolve still reported connected, which is a healthy
# report and an AI client with no Exasol tools in it.
has "there is a server_launch stage" "def validate_server_launch" "$(cat "$ROOT/mcp/validator/service.py")"
has "and the doctor asks for it" "server_launch" "$(sed -n '/^def _doctor_stages/,/^def /p' "$ROOT/mcp/cli.py")"
has "with an opt-out for offline runs" "EXAKIT_MCP_SKIP_SERVER_PROBE" "$(cat "$ROOT/mcp/cli.py")"
# It must stay OUT of the default stage list: the hermetic suites must never
# spawn a subprocess or reach the network.
lacks "it is not in the default stage list" '"server_launch",' \
    "$(sed -n '/    stages: tuple\[str, ...\] = (/,/    )/p' "$ROOT/mcp/core/models.py")"
# communicate() closes stdin, and an MCP stdio server treats that EOF as "client
# gone" and exits without answering -- measured against the real server, which
# never replied to tools/list. The fix is to write the requests and leave the
# pipe open, draining stdout on a thread until the answer lands.
has "the handshake keeps stdin open while it waits" "process.stdin.flush()" \
    "$(sed -n '/def _mcp_handshake/,/^    def /p' "$ROOT/mcp/validator/service.py")"
lacks "and does not hand the requests to communicate()" "= process.communicate(" \
    "$(sed -n '/def _mcp_handshake/,/^    def /p' "$ROOT/mcp/validator/service.py")"
has "the server's stderr is never read into a finding" "stderr=subprocess.DEVNULL" \
    "$(sed -n '/def _mcp_handshake/,/^    def /p' "$ROOT/mcp/validator/service.py")"

echo "the install record does not contradict itself:"
# THE BUG: connection.schemas ["STARTER_KIT"] reads as "this user can only see
# STARTER_KIT", and an agent checking the record concluded exactly that -- while
# the MCP user was returning TPCH, ENERGY and WEATHER quite happily.
has "the read scope is spelled out, not inferred from 'schemas'" "read_scope" \
    "$(cat "$ROOT/setup/lib/common.sh")"
has "and the PowerShell twin records it too" "read_scope" "$(cat "$ROOT/setup/lib/mcp.ps1")"
# ...and a qualified status has to say WHY, or the manifest keeps a permanent
# "success_with_warnings" that names no warning.
has "a qualified client-setup status records its findings" "_setup_findings" \
    "$(cat "$ROOT/mcp/cli.py")"

echo "the small promises hold too:"
# An undated note is how a healthy machine looks broken: status --json reads the
# date off line 2, and install.sh's own fail() wrote only line 1.
has "install.sh dates its failure note" "date '+%Y-%m-%d %H:%M:%S'" "$(cat "$ROOT/install.sh")"
has "and install.ps1 writes one at all" ".last-failure" "$(cat "$ROOT/install.ps1")"
# The skill's closing step names this directory; nothing created it.
has "the workflows directory is created with the home" "EXAKIT_WORKFLOWS_DIR" \
    "$(sed -n '/^manifest_init()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "and the PowerShell twin creates it" "WorkflowsDir" \
    "$(sed -n '/^function Initialize-ExakitManifest/,/^}/p' "$ROOT/setup/lib/exakit-common.ps1")"
# The clipboard is the user's, and an unattended install has no business
# overwriting it for a prompt nobody is about to paste.
# Anchored on the function, not on the panel title: the prompt is only PRINTED
# when the clipboard could not take it, so the title now sits inside the else.
has "the clipboard is only touched with a terminal attached" "exakit_stdin_is_tty" \
    "$(sed -n '/^exakit_print_mcp_ready_panel()/,/^}/p' "$ROOT/setup/lib/common.sh")"
# The credential guardrail named only the credentials dir, while the password is
# also in clear text in every client config an agent reads while debugging MCP.
has "the guardrail covers the client configs too" ".claude.json" \
    "$(cat "$ROOT/AGENTS.md")"
# The tool gate is a keyword check: SELECT 1; DROP TABLE T passes it and reaches
# the engine. Claiming it stops a write "before it ever reaches the database"
# points the reader at the wrong layer.
lacks "no skill claims the tool gate is the boundary" "rejects a non-SELECT before it ever reaches the" \
    "$(cat "$ROOT"/skills/*/SKILL.md)"
# An agent that ran the install cannot use the MCP tools it just configured.
has "AGENTS.md says the MCP tools need a client restart" "no \`exasol\` tools until it restarts" \
    "$(cat "$ROOT/AGENTS.md")"

printf '\n== the help corpus survives into the installed kit ==\n'

# setup/help/ was never staged into ~/.exasol-starter-kit/kit, and
# exakit_repo_root PREFERS the staged copy once kit/mcp exists -- so it did not
# fall back to the checkout, it SHADOWED it. Every `exakit help <topic>` on
# every real install answered "No help entry for ...", and the marketplace lost
# all three tiers of its add-on descriptions with it: _exakit_addon_repo reads
# the `repo` field from these documents, so the GitHub About could not even be
# requested, the cache it fills stayed empty, and the `tagline` offline answer
# was in the same missing file.
#
# It shipped because nothing checked. This checks.
has "the staging copies the help corpus" \
    '[ -d "$_kit_root/setup/help" ] && cp -R "$_kit_root/setup/help" "$EXAKIT_HOME/kit/setup/"' \
    "$(cat "$ROOT/setup/lib/common.sh")"
has "...and the Windows twin does too" \
    'Copy-ExakitAsset -Source (Join-Path $KitRoot "setup\help")' \
    "$(cat "$ROOT/setup/setup-windows-docker.ps1")"

# Functional, not just textual: a kit staged the way the installer stages one
# must answer for every topic it ships.
HELPK="$WORK/staged"
mkdir -p "$HELPK/kit/setup" "$HELPK/kit/mcp"
cp -R "$ROOT/setup/lib" "$HELPK/kit/setup/"
cp -R "$ROOT/setup/help" "$HELPK/kit/setup/"
for _topic in "$ROOT"/setup/help/*.json; do
    _tid="$(basename "$_topic" .json)"
    check "a staged kit answers for '$_tid'" "found" \
        "$( EXAKIT_HOME="$HELPK" bash -c '
            . "'"$ROOT"'/setup/lib/ui.sh" 2>/dev/null
            . "'"$ROOT"'/setup/lib/common.sh" 2>/dev/null
            _exakit_addon_doc "'"$_tid"'" >/dev/null 2>&1 && printf found || printf MISSING
        ' )"
done
# And the inverse, so the guard cannot pass by accident: strip the corpus and
# the lookups must fail again. A test that only ever sees the fixed state would
# have passed against the bug too.
rm -rf "$HELPK/kit/setup/help"
check "without it, the lookup fails again" "MISSING" \
    "$( EXAKIT_HOME="$HELPK" bash -c '
        . "'"$ROOT"'/setup/lib/ui.sh" 2>/dev/null
        . "'"$ROOT"'/setup/lib/common.sh" 2>/dev/null
        _exakit_addon_doc dash-server >/dev/null 2>&1 && printf found || printf MISSING
    ' )"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
