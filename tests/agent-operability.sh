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

# A manifest whose deployment does not exist reads as a stopped database.
#
# HERMETIC, and it has to be: the Personal probes fall back to an `exasol` on
# PATH and to the real ~/.exasol deployment, so a fixture that scrubs only
# EXAKIT_HOME answers from the developer's own running database and inverts
# every assertion here.
#
# PATH is FILTERED rather than replaced. Replacing it with the system
# directories also takes away the 3.11+ python3 the manifest reader needs
# (a stock macOS /usr/bin/python3 is 3.9), and the dataset rows then come back
# empty for a reason that has nothing to do with what is being tested. Only the
# directories that actually hold a launcher are dropped.
mkdir -p "$WORK/stopped" "$WORK/no-bin"
_HERMETIC_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r _hp_dir; do
    [ -n "$_hp_dir" ] || continue
    [ -x "$_hp_dir/exasol" ] && continue
    printf '%s:' "$_hp_dir"
done | sed 's/:$//')"
_stopped() {
    env -u EXAKIT_PERSONAL_VERSION \
        EXAKIT_HOME="$WORK/stopped" \
        EXAKIT_PERSONAL_DEPLOY_DIR="$WORK/no-deployment" \
        EXAKIT_BIN_DIR="$WORK/no-bin" \
        PATH="$_HERMETIC_PATH" \
        bash "$ROOT/setup/exakit" "$@"
}
printf '{\n  "runtime": {\n    "type": "personal"\n  },\n  "data": {\n    "datasets": {\n      "tpch": {\n        "loaded": true\n      }\n    }\n  }\n}\n' > "$WORK/stopped/manifest.json"
check "stopped database exits 3" "3" "$(_stopped status >/dev/null 2>&1; echo $?)"
_sj="$(_stopped status --json 2>/dev/null)"
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
    "$(_stopped status 2>/dev/null)"
# The fixture's container does not exist, so there is no runtime to start:
# "exakit start" was the pre-runtime remedy bug this suite used to PIN as
# correct (the audit's AGK-18). The fix an agent can act on is the installer -
# and the row names the RUNNABLE command, byte for byte the same string
# `status --json` hoists into `remedy`, not the prose "re-run the installer".
has "prose names the fix, as a runnable command" "curl -fsSL" "$(_stopped status 2>/dev/null | tail -1)"
# 2, not 1: bad input has its own code across the CLI now (the same one an
# unknown subcommand uses), so an agent can tell "I typed it wrong" from "the
# command ran and failed". It also records no failure note — see the reject
# assertions further down.
check "an unknown status flag is refused with the bad-input code" "2" "$(_stopped status --nope >/dev/null 2>&1; echo $?)"

echo "mcp-doctor diagnoses the stopped database first:"
_doc="$(_stopped mcp-doctor 2>&1)"
check "exit 3, same as status" "3" "$(_stopped mcp-doctor >/dev/null 2>&1; echo $?)"
has "and names the remedy" "exakit start" "$_doc"
_docj="$(_stopped mcp-doctor --json 2>/dev/null)"
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
# WINDOWS HOME RESOLUTION: install.ps1 used $HOME while exakit resolves from
# USERPROFILE, so a domain machine with a redirected home installed into one
# tree and looked in another - a successful install reported "not installed"
# and re-running never converged. And everything written FOR AN AGENT (skills,
# the ~/.claude allowlist) must build on the home agents resolve "~" from,
# which on Windows is USERPROFILE, never a redirected $HOME.
_ps_install="$(cat "$ROOT/install.ps1")"
_ps_common="$(cat "$ROOT/setup/lib/exakit-common.ps1")"
has "install.ps1 resolves its home like exakit does" "function Get-ExakitInstallHomeBase" "$_ps_install"
has "...and exports the result for the setup run" '$env:EXAKIT_HOME = $ExakitHome' "$_ps_install"
has "agent-facing paths have one resolver" "function Get-ExakitAgentHome" "$_ps_common"
check "no agent-facing path builds on raw \$HOME" "0" \
    "$(printf '%s\n' "$_ps_common" | grep -c 'Join-Path \$HOME "\.claude\|Join-Path \$HOME "\.agents')"
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
# A missing runtime (this fixture's container does not exist) is repaired by
# the installer; a merely STOPPED one still answers "exakit start" - see the
# remedy arms in the status heredoc.
# The remedy is the installer's RUNNABLE command now (AGK-08: "when remedy
# is not null, run it"); the resume note lives beside it in remedy_hints.
has "a missing runtime hands the runnable install command" 'curl -fsSL' "$_rj"
has "...with the resume note as its hint" '"remedy_hints"' "$_rj"
has "a missing pyexasol names its repair" 'exakit update' "$_rj"
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
_xl="$(sed -n '/^exakit_db_error_remedy()/,/^}/p' "$ROOT/setup/lib/common.sh")"
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

# The engine-hang fixture must mask the engine the kit actually reaches for: a
# fixture that masked something else let a real, working podman answer the probe
# -- and "podman" is then correct, which the assertion scored as a failure.
has "the engine-hang fixture masks podman" '> "$WORK/hang-bin/podman"' \
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
    "$(cat "$ROOT/setup/lib/runtime-personal.sh")"

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
    "$(_stopped info --json >/dev/null 2>&1; echo $?)"
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
has "and routes failures through the translator" "exakit_db_error_remedy" \
    "$(sed -n '/^cmd_sql()/,/^}/p' "$ROOT/setup/exakit")"
has "and is in the catalog" "sql" "$(exakit_help_commands)"
has "the PowerShell twin exists" "Invoke-CmdSql" "$(cat "$ROOT/setup/exakit.ps1")"
# PowerShell had NO translator at all: the Windows path got raw engine text and
# nothing else, making the promise macOS-only.
has "PowerShell has the translator too" "Show-ExakitDbErrorRemedy" \
    "$(cat "$ROOT/setup/lib/exakit-common.ps1")"
for _case in "LIMIT" "exakit start" "describe it first"; do
    has "PowerShell translator covers '$_case'" "$_case" \
        "$(sed -n '/^function Get-ExakitDbErrorRemedy/,/^}/p' "$ROOT/setup/lib/exakit-common.ps1")"
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
    "$(cat "$ROOT/setup/setup-windows.ps1")"

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

printf '\n== repair-runtime actually replaces the database ==\n'

# It warns "REPLACES the database. Its data is not recoverable", takes a yes for
# it, and then re-runs setup -- whose deployment step asks whether to reuse what
# is already there, defaulting to YES. So the command answered its own second
# question with "keep it", reported "Reusing the existing Exasol deployment",
# and repaired nothing.
#
# EXAKIT_REUSE_DB=0 is what makes the deployment step replace instead of adopt,
# and both halves of the mirror have to honour it or the command lies on that
# platform.
EXAKIT_SH="$(cat "$ROOT/setup/exakit")"
has "repair-runtime forces a fresh deployment" 'export EXAKIT_REUSE_DB=0' "$EXAKIT_SH"
has "...and the Windows twin does too" '$env:EXAKIT_REUSE_DB = "0"' "$(cat "$ROOT/setup/exakit.ps1")"
# The runtime asks, and takes the flag as the answer.
has "the personal runtime honours it" 'confirm_env EXAKIT_REUSE_DB' \
    "$(cat "$ROOT/setup/lib/runtime-personal.sh")"
# On macOS, declining reuse of a STOPPED deployment must be as harmless as
# declining it for a running one: the deletion has its own question and its
# own variable, so EXAKIT_REUSE_DB=0 alone can never destroy in one state
# what it safely refuses in the other. repair-runtime is the one caller
# allowed to pre-answer that question, because it just asked its own.
has "personal deletion has its own consent" 'confirm_env EXAKIT_REPLACE_DB' \
    "$(cat "$ROOT/setup/lib/runtime-personal.sh")"
has "repair-runtime carries that consent" 'export EXAKIT_REPLACE_DB=1' "$EXAKIT_SH"
has "the delete prompt names the consequence first" \
    'DELETE the stopped deployment and its data' \
    "$(cat "$ROOT/setup/lib/runtime-personal.sh")"
has "...and its twin gates the deletion the same way" 'EXAKIT_REPLACE_DB' \
    "$(cat "$ROOT/setup/lib/runtime-personal.ps1")"

echo
echo "the JSON contract holds on the unhappy paths too:"
# sql --json used to leave stdout EMPTY when the kit was not installed (a
# human error card on stderr, exit 1 where the contract says 4), and to hand
# the parser bash's own "No such file or directory" line-number noise when
# exapump was missing (exit 127).
_jc="$WORK/jc"; mkdir -p "$_jc"
_jc_out="$(EXAKIT_HOME="$_jc" bash "$ROOT/setup/exakit" sql --json 'SELECT 1' 2>/dev/null)"
check "sql --json answers JSON when not installed" "yes" \
    "$(printf '%s' "$_jc_out" | python3 -m json.tool >/dev/null 2>&1 && echo yes || echo no)"
has "and says why, with a runnable remedy" '"remedy": "curl -fsSL' "$_jc_out"
check "with the not-installed exit code" "4" \
    "$(EXAKIT_HOME="$_jc" bash "$ROOT/setup/exakit" sql --json 'SELECT 1' >/dev/null 2>&1; echo $?)"
printf '{\n  "runtime": {\n    "type": "personal"\n  }\n}\n' > "$_jc/manifest.json"
# EXAKIT_BIN_DIR must be sandboxed too: exapump.sh derives its binary path
# from it at load time, so leaving it at the default finds the developer's
# real exapump and runs a real query.
# The stripped PATH must starve the test of EXAPUMP, not of Python: hand the
# real uv through, and the suite's own python3 via a tools dir on the PATH.
# "On CI the system python suffices" was true only of the ubuntu runner - the
# macOS runner's /usr/bin/python3 is 3.9, below the kit's floor, and with no
# uv there every --json emission died empty the first time this suite ever
# ran on that runner.
_jc_tools="$_jc/tools"; mkdir -p "$_jc_tools"
_jc_py="$(command -v python3 2>/dev/null || true)"
[ -n "$_jc_py" ] && ln -sf "$_jc_py" "$_jc_tools/python3"
_jc_nx="$(EXAKIT_HOME="$_jc" EXAKIT_BIN_DIR="$_jc/bin" EXAKIT_UV_BIN="$(command -v uv 2>/dev/null || true)" PATH="$_jc_tools:/usr/bin:/bin" bash "$ROOT/setup/exakit" sql --json 'SELECT 1' 2>/dev/null)"
has "a missing exapump is a real error, not bash noise" '"error": "exapump (the SQL client) is not installed"' "$_jc_nx"
has "...with a runnable remedy" '"remedy": "exakit update"' "$_jc_nx"

# version --json: `status` is a fixed vocabulary a parser can switch on; the
# action a human would take moved to a per-row runnable `remedy`. An add-on
# row used to carry the literal command "exakit marketplace" AS its status.
# PATH scrubbed like the sql fixture above: version --json probes the host
# PATH for add-on binaries (system-present detection), so on a dev box with
# the kit really installed the add-on rows silently changed shape and the
# assertions below flipped on ambient host state — red locally, green in CI
# only because CI runners lack the binaries. uv is handed through so manifest
# reads still work where the system python is below the kit's floor.
_jc_ver="$(EXAKIT_HOME="$_jc" EXAKIT_BIN_DIR="$_jc/bin" EXAKIT_UV_BIN="$(command -v uv 2>/dev/null || true)" PATH="$_jc_tools:/usr/bin:/bin" bash "$ROOT/setup/exakit" version --json 2>/dev/null)"
check "no component status is a shell command" "0" \
    "$(printf '%s' "$_jc_ver" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(sum(1 for c in d['components'] if c['status'].startswith('exakit ')))")"
check "an uninstalled add-on reads as available, remedy runnable" "available|exakit marketplace json-tables" \
    "$(printf '%s' "$_jc_ver" | python3 -c "
import json,sys
d = json.load(sys.stdin)
row = next(c for c in d['components'] if c['component'] == 'json-tables')
print('%s|%s' % (row['status'], row['remedy']))")"

# status --json: 'installed: true' beside 'status: not installed' was one
# object contradicting itself; and a state query must never write the
# .last-failure note it reports.
EXAKIT_SH_JC="$(cat "$ROOT/setup/exakit")"
has "the kit-level status says no database, not 'not installed'" 'top_status = "no database"' "$EXAKIT_SH_JC"
has "...with the runnable installer command as the remedy, never exakit start" \
    'remedies["database"] = install_cmd' "$EXAKIT_SH_JC"
has "state queries raise the read-only flag" 'export EXAKIT_READONLY_QUERY=1' "$EXAKIT_SH_JC"
# IN A SCRATCH HOME, because this asks whether a FILE appeared. Run against the
# developer's real kit home it answers about a note some earlier, unrelated run
# left there - a failed data load is enough - and reports WROTE about a write
# this check never made. (It could not have written one itself: the read-only
# flag is the thing under test. But a green check that depends on the
# developer's machine being tidy is not a check.) Same hazard dry-run-matrix.sh
# guards against by name.
check "and the note writer honours it" "kept-clean" "$( (
    EXAKIT_HOME="$WORK/note-home"; mkdir -p "$EXAKIT_HOME"
    EXAKIT_READONLY_QUERY=1 exakit_note_failure "should never land" 2>/dev/null
    [ -f "$(exakit_failure_note_file)" ] && echo WROTE || echo kept-clean
) )"
has "status --json carries per-service urls" '"urls": umap' "$EXAKIT_SH_JC"

echo
echo "every remedy is runnable, and nothing advertises a rejected command:"
# AGK-08: AGENTS.md line 21 says "when remedy is not null, run it" - so an
# English sentence at that key breaks the very contract the doc states. Every
# remedy in the remedies map is now a command; prose moved to remedy_hints.
_rem_check="$(printf '%s' "$_rj" | python3 -c "
import json, sys
d = json.load(sys.stdin)
bad = [k for k, v in d.get('remedies', {}).items()
       if ' — ' in v or v.split(' ', 1)[0] not in ('exakit', 'curl', 'irm', 'bash', 'sh')]
print('all-runnable' if not bad else 'PROSE in ' + ','.join(bad))")"
check "every remedies value starts with a command" "all-runnable" "$_rem_check"
# SKL-06: `exakit autostart on` was named by three skills and two help
# documents, and the CLI hard-rejects it. No shipped guidance may advertise it.
check "no skill advertises 'exakit autostart on'" "0" \
    "$(grep -rl 'exakit autostart on' "$ROOT/skills" 2>/dev/null | wc -l | tr -d ' ')"
check "...and no help document either" "0" \
    "$(grep -rl 'exakit autostart on' "$ROOT/setup/help" 2>/dev/null | wc -l | tr -d ' ')"
has "dash-server declares its url hook" 'dash_server_url()' "$(cat "$ROOT/setup/lib/dash-server.sh")"

echo
echo "the lifecycle keeps its promises on the unhappy paths:"
# ADD-04: uninstalling one add-on removes its boot entry too - left behind,
# launchd/systemd fired a launcher that no longer exists on every login.
has "add-on uninstall retires the boot entry" '_exakit_autostart_unregister "$_uc_key"' \
    "$(cat "$ROOT/setup/lib/common.sh")"
has "...and on Windows too" 'Unregister-ExakitAutostart -Id $Key' "$(cat "$ROOT/setup/exakit.ps1")"
# AGK-07: the uv bootstrap runs lazily from INSIDE a --json answer; its
# narration must never share stdout with the JSON object.
check "uv bootstrap narration goes to stderr" "4" \
    "$(sed -n '/^exakit_ensure_uv()/,/^}/p' "$ROOT/setup/lib/common.sh" | grep -c '>&2$')"
# MAC-05: adopting or reusing a deployment records the version ON DISK, never
# the advertised one.
has "the manifest records the deployed version first" 'personal_deployed_version 2>/dev/null' \
    "$(sed -n '/^personal_record_manifest()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh")"
# CPY-16: the read-only guardrail speaks to whoever is reading, with an action.
lacks "the guardrail no longer talks past the human" "say so and let the user decide" \
    "$(cat "$ROOT/setup/lib/common.sh" "$ROOT/setup/lib/exakit-common.ps1")"
has "...and names the deliberate write path" "exakit sql --write" \
    "$(sed -n '/insufficient privileges/,+8p' "$ROOT/setup/lib/common.sh")"
# SAY-08: the documented Personal major-upgrade route is accepted by the
# option guard instead of being a phantom.
_su="$WORK/say08"; mkdir -p "$_su"
printf '{\n  "runtime": {\n    "type": "personal"\n  }\n}\n' > "$_su/manifest.json"
# EXAKIT_BIN_DIR sandboxed too, and not only for tidiness: this fixture runs
# the REAL update path, and that path deletes $EXAKIT_PERSONAL_BIN before
# installing. Unscrubbed it inherits the developer's ~/.local/bin and takes
# their launcher with it - which is exactly what happened, downgrading a
# working machine mid-test-run.
_su_out="$(EXAKIT_HOME="$_su" EXAKIT_BIN_DIR="$_su/bin" bash "$ROOT/setup/exakit" update runtime --plan 2>&1)"
lacks "update runtime --plan is not refused" "Unknown option" "$_su_out"
# ...and --plan DESCRIBES. It used to describe only across a major gap and
# install across every other one, so the flag that promises to touch nothing
# replaced the launcher binary without asking.
lacks "update runtime --plan installs nothing" "Installing launcher" "$_su_out"
has "...and says how to apply it instead" "Apply it with: exakit update runtime" "$_su_out"
check "...leaving no launcher behind" "absent" \
    "$([ -e "$_su/bin/exasol" ] && echo PRESENT || echo absent)"
# AGK-02: a DEAD installer answers with installing:false, the step it died at,
# and remedies.install naming the re-run - the exact shape AGENTS.md promises.
printf '{\n  "runtime": {\n    "type": "personal"\n  },\n  "install": {\n    "current_step": "mcp"\n  }\n}\n' > "$_su/manifest.json"
_su_dead="$(EXAKIT_HOME="$_su" bash "$ROOT/setup/exakit" status --json 2>/dev/null)"
check "dead installer keeps its step and remedy" "False|mcp|yes" "$(printf '%s' "$_su_dead" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print('%s|%s|%s' % (d['installing'], d['install_step'],
                    'yes' if d['remedies'].get('install') else 'no'))")"
# CPY-05: a panel never wraps what a capture will grep - the width cap applies
# only where a terminal is rendering.
has "the panel width cap is tty-gated" '[ -t 1 ]' \
    "$(sed -n '/^ui_panel_end()/,/^}/p' "$ROOT/setup/lib/ui.sh")"
echo "windows and wsl keep their promises:"
_ps_inst="$(cat "$ROOT/install.ps1")"
# WIN-05: HTTPS_PROXY is honoured by the download, not just documented -
# Invoke-WebRequest ignores the environment variable on its own - and a 407 is
# named as the proxy refusing, not a generic network failure.
has "the installer passes HTTPS_PROXY explicitly" '$webArgs["Proxy"] = $env:HTTPS_PROXY' "$_ps_inst"
has "...and names a 407 for what it is" "HTTP 407, authentication required" "$_ps_inst"
# WIN-06: Group Policy outranks -ExecutionPolicy Bypass; the installer detects
# the pinned policy before downloading anything and names the real fix.
has "GPO-pinned execution policy is detected up front" 'Get-ExecutionPolicy -Scope $gpoScope' "$_ps_inst"
# WIN-07: Move-Item cannot move a directory across volumes, so the update
# stages BESIDE the kit, never in TEMP - or an EXAKIT_HOME on another drive
# recorded a version it never installed.
_ps_common_w="$(cat "$ROOT/setup/lib/exakit-common.ps1")"
has "the kit update stages beside the kit"   '.kit-stage-' "$_ps_common_w"
has "...and the skills update does too"      '.skills-stage-' "$_ps_common_w"
lacks "no stage directory lives in TEMP" 'GetTempPath()) "exakit-kit-stage' "$_ps_common_w"
# WIN-08: chmod is a no-op on Windows; the Python runtime protects secrets
# with an owner-only ACL there and never reports a protection it did not apply.
# protect_path in mcp/runtime/filesystem.py is the single implementation - the
# snapshot copies and the directories holding them need the same thing the
# client configs do, and a second copy of the icacls call is how they drift.
_py_fs="$(cat "$ROOT/mcp/runtime/filesystem.py")"
has "the python runtime uses an ACL on Windows" '"icacls", str(path)' "$_py_fs"
has "...and posix keeps the 0600 chmod" 'stat.S_IRUSR | stat.S_IWUSR' "$_py_fs"
has "...and the security policy shares it" 'return protect_path(path)' "$(cat "$ROOT/mcp/security/policy.py")"
has "snapshot copies are protected too" 'protect_path(target)' "$_py_fs"
has "...and so are the directories holding them" 'protect_path(directory)' "$(cat "$ROOT/mcp/runtime/paths.py")"
# WSL-04: the after-a-restart promise names the one case that still needs a
# hand - a headless Linux session without lingering - instead of promising
# unconditionally.
has "the restart promise names the lingering case" "loginctl enable-linger" "$(cat "$ROOT/AGENTS.md")"
# WSL-06: EXAKIT_RUNTIME chose between the two database runtimes and there is
# only one now, so no document may still offer the knob. (This check used to be
# labelled as a WSL one; it never tested WSL, and WSL is supported now.)
for _wsl_doc in README.md AGENTS.md QUICKSTART.md quickstarts/linux.md quickstarts/windows.md; do
    lacks "no doc offers the removed runtime knob: $_wsl_doc" 'EXAKIT_RUNTIME' "$(cat "$ROOT/$_wsl_doc")"
done
echo
echo "round-3 residuals stay fixed:"
# MAC-02: a start that fails once is NOT a licence to destroy. The reap runs
# BEFORE any replace decision, start gets a second chance, and no path reaches
# destroy without the explicit EXAKIT_REPLACE_DB consent - the _pdl_replace
# bypass variable is gone entirely.
RP_SH="$(cat "$ROOT/setup/lib/runtime-personal.sh")"
has "a failed start reaps orphans and retries" "started after clearing an orphaned runner" "$RP_SH"
lacks "the consent-bypass flag is gone" "_pdl_replace" "$RP_SH"
has "no deploy path destroys without consent" "NO PATH DESTROYS WITHOUT THIS CONSENT" "$RP_SH"
# MAC-01: one PATH-persistence policy - the second writer delegates to the
# Darwin-aware ensure_path_hint instead of preferring ~/.bashrc.
has "the second PATH writer delegates to the one Darwin-aware policy" \
    'ensure_path_hint "$1"' \
    "$(sed -n '/^_exakit_add_bin_to_shell_rc()/,/^}/p' "$ROOT/setup/lib/common.sh")"
# AGK-10: sql --json separates the runnable command from the sentence.
_r3="$WORK/r3"; mkdir -p "$_r3/bin"
printf '#!/bin/sh\necho "Error: Connection refused (Errno 61)" >&2\nexit 1\n' > "$_r3/bin/exapump"
chmod +x "$_r3/bin/exapump"
printf '{\n  "runtime": {\n    "type": "personal"\n  },\n  "components": {\n    "exapump": {\n      "profile": "starter-kit"\n    }\n  }\n}\n' > "$_r3/manifest.json"
# The same interpreter hand-through as the _jc fixtures, for the same macOS
# runner reason - the stub exapump on this PATH is the thing under test.
_r3_tools="$_r3/tools"; mkdir -p "$_r3_tools"
[ -n "$_jc_py" ] && ln -sf "$_jc_py" "$_r3_tools/python3"
_r3_out="$(EXAKIT_HOME="$_r3" EXAKIT_BIN_DIR="$_r3/bin" EXAKIT_UV_BIN="$(command -v uv 2>/dev/null || true)" PATH="$_r3_tools:$_r3/bin:/usr/bin:/bin" bash "$ROOT/setup/exakit" sql --json 'SELECT 1' 2>/dev/null)"
check "sql --json remedy is the runnable command" "exakit start" "$(printf '%s' "$_r3_out" | python3 -c "
import json,sys
print(json.load(sys.stdin).get('remedy'))" 2>/dev/null)"
has "and the sentence lives in remedy_hint" '"remedy_hint":' "$_r3_out"
echo
echo "personal 2.3 readiness (P0):"
# The launcher's 2.3 breaking change: a non-interactive host preparation now
# FAILS rather than proceeding without approval, and the kit's deploy is a
# pipeline - the definition of non-interactive. Every launcher call that can
# trigger preparation carries the flag, and it is resolved per SUBCOMMAND
# because a subcommand's flags never appear in the top-level help the older
# capability probe reads.
has "the deploy approves host preparation" \
    'install local $(personal_auto_approve_flag install)' "$RP_SH"
has "...and so does the reuse start" \
    'run_logged "$(personal_cli)" start $(personal_auto_approve_flag start)' "$RP_SH"
has "...and the start command itself" \
    'if ! run_logged "$(personal_cli)" start $(personal_auto_approve_flag start); then' "$RP_SH"
# A launcher that does not take the flag must never be handed it: 2.2 is still
# a supported deployment and an unknown flag is a hard failure, not a warning.
# Behavioural, against a stub whose install advertises the flag and whose start
# does not - the text of the probe proves nothing about what it answers.
_aa="$WORK/autoapprove"; mkdir -p "$_aa/bin"
cat > "$_aa/bin/exasol" <<'STUB'
#!/bin/sh
case "$1 $2" in
  "install --help") printf 'Flags:\n  -a, --auto-approve   Approve host preparation\n' ;;
  "start --help")   printf 'Flags:\n      --help    help\n' ;;
  *)                printf 'Commands:\n  install\n  start\n' ;;
esac
STUB
chmod +x "$_aa/bin/exasol"
_aa_probe() {
    bash -c '
        . "$0/setup/lib/common.sh" 2>/dev/null
        . "$0/setup/lib/detect.sh" 2>/dev/null
        . "$0/setup/lib/runtime-personal.sh"
        EXAKIT_PERSONAL_BIN="$1"
        personal_auto_approve_flag "$2"' "$ROOT" "$_aa/bin/exasol" "$1" 2>/dev/null
}
check "a launcher that takes the flag gets it"      "--auto-approve" "$(_aa_probe install)"
check "a launcher that does not is left alone"      "" "$(_aa_probe start)"

# 2.3 selects and persists a concrete database port. Asking the constant made
# status wrong on any deployment that chose another one, so every liveness read
# goes through personal_db_port, which prefers the launcher's deployment.json.
has "liveness reads the deployment's own port" \
    'port_in_use "$(personal_db_port)" || return 1' "$RP_SH"
has "...status too" 'if port_in_use "$(personal_db_port)"; then' "$RP_SH"
# The readiness wait is a TLS handshake (an open port is pasta's, not the
# database's), and the handshake probe asks the same deployment for its port.
has "...and the readiness wait" 'if personal_tls_answers; then' "$RP_SH"
has "...whose handshake probe reads it too" '_pta_port="$(personal_db_port)"' "$RP_SH"
has "the port comes from the launcher's deployment.json" '"dbPort"' "$RP_SH"
_p0="$WORK/p0"; mkdir -p "$_p0/deploy"
printf '{"connection": {"host": "127.0.0.1", "dbPort": 8571, "username": "sys"}}\n' > "$_p0/deploy/deployment.json"
_p0_probe() {
    EXAKIT_PERSONAL_DEPLOY_DIR="$1" bash -c '
        . "$0/setup/lib/common.sh" 2>/dev/null
        . "$0/setup/lib/detect.sh" 2>/dev/null
        . "$0/setup/lib/runtime-personal.sh"
        personal_db_port' "$ROOT" 2>/dev/null
}
check "a configured port is read back" 8571 "$(_p0_probe "$_p0/deploy")"
check "no deployment falls back to the default" 8563 "$(_p0_probe "$_p0/absent")"

# The one-time VM guest rebuild after a launcher change does not fit the
# ordinary readiness budget, and overrunning it reported a successful upgrade
# as a crash. A number the user chose still wins over the kit's guess.
has "a guest rebuild gets its own budget" 'EXAKIT_PERSONAL_REBUILD_TIMEOUT' "$RP_SH"
has "...only when the user set no ceiling of their own" \
    '[ -z "${EXAKIT_PERSONAL_READY_TIMEOUT:-}" ] && personal_guest_rebuild_expected' "$RP_SH"
has "...and the timeout names the variable that raises it" 'raise it with ${_pwr_raise}' "$RP_SH"
has "the rebuild is announced before the start, not after the wait" \
    'personal_note_guest_rebuild' "$RP_SH"

# A COMPLETED UPDATE MUST STOP ADVERTISING ITSELF. runtime.version is the
# component versions.json names - the LAUNCHER - so it is read from the binary;
# the deployment keeps the version that created it and gets its own key. With
# the two conflated, `exakit update` swapped the launcher, recorded the
# deployment's unchanged number, and offered the same update forever (stopping
# the database each time it was accepted).
has "the launcher binary is asked for its own version" 'personal_launcher_version()' "$RP_SH"
has "...and that is what runtime.version records" \
    'manifest_set runtime.version "${_prm_ver:-${_prm_dep:-$EXAKIT_PERSONAL_VERSION}}"' "$RP_SH"
has "...with the deployment's version beside it, not in its place" \
    'manifest_set runtime.deployment_version' "$RP_SH"
# ...and the rebuild notice retires itself, or it promises on every start a
# wait that is already behind the user.
has "a completed start records the launcher it completed under" \
    'manifest_set runtime.guest_rebuilt_for' "$RP_SH"
has "...and the notice checks that record" \
    'runtime.guest_rebuilt_for 2>/dev/null' "$RP_SH"
_gr="$WORK/guest"; mkdir -p "$_gr/dep" "$_gr/bin"
printf '2.2.0' > "$_gr/dep/.exasolLauncher.version"
printf '#!/bin/sh\n[ "$1" = version ] && echo 2.3.0-rc2\nexit 0\n' > "$_gr/bin/exasol"
chmod +x "$_gr/bin/exasol"
_gr_probe() { # _gr_probe <recorded-guest_rebuilt_for> -> yes|no
    printf '{"runtime":{"type":"personal","guest_rebuilt_for":"%s"}}\n' "$1" > "$_gr/manifest.json"
    EXAKIT_HOME="$_gr" EXAKIT_PERSONAL_DEPLOY_DIR="$_gr/dep" EXAKIT_PERSONAL_BIN="$_gr/bin/exasol" \
        bash -c '
            . "$0/setup/lib/common.sh" 2>/dev/null
            . "$0/setup/lib/detect.sh" 2>/dev/null
            . "$0/setup/lib/runtime-personal.sh"
            EXAKIT_PERSONAL_BIN="'"$_gr/bin/exasol"'"
            personal_guest_rebuild_expected && echo yes || echo no' "$ROOT" 2>/dev/null
}
check "a 2.2 deployment under a 2.3 launcher owes a rebuild" "yes" "$(_gr_probe "")"
check "...and stops owing it once a start has completed" "no" "$(_gr_probe "2.3.0-rc2")"

# THE LAUNCHER OWNS THE LIFECYCLE. 2.3's `stop` leaves the deployment's own
# runner alive and still answering SQL on the port, so a port-only probe called
# a stopped database "running" - and `exakit start` then answered "already
# running" and did nothing, leaving no way to restart it at all. The launcher's
# own status is the tiebreaker, and the runner it left behind is reaped before
# the next start rather than diagnosed after it.
_ls="$WORK/lstate"; mkdir -p "$_ls/dep" "$_ls/bin"
printf '{}' > "$_ls/dep/deployment.json"
_ls_stub() { # _ls_stub <status-word> [--text-only]
    if [ "${2:-}" = "--text-only" ]; then
        printf '#!/bin/sh\n[ "$1" = status ] && [ "$2" = --json ] && exit 1\n[ "$1" = status ] && printf "  Status: %s\\n"\nexit 0\n' "$1" > "$_ls/bin/exasol"
    else
        printf '#!/bin/sh\n[ "$1" = status ] && printf "{\\"status\\": \\"%s\\"}\\n"\nexit 0\n' "$1" > "$_ls/bin/exasol"
    fi
    chmod +x "$_ls/bin/exasol"
}
_ls_probe() { # _ls_probe <fn> -> the function's answer with the stub launcher
    EXAKIT_HOME="$_ls" EXAKIT_PERSONAL_DEPLOY_DIR="$_ls/dep" bash -c '
        . "$0/setup/lib/common.sh" 2>/dev/null
        . "$0/setup/lib/detect.sh" 2>/dev/null
        . "$0/setup/lib/runtime-personal.sh"
        EXAKIT_PERSONAL_BIN="'"$_ls/bin/exasol"'"
        # The deployment exists, the port answers, SQL answers - the exact
        # shape a stopped 2.3 deployment presents while its runner lingers.
        personal_deployment_exists() { return 0; }
        port_in_use() { return 0; }
        personal_db_answers() { return 0; }
        '"$1" "$ROOT" 2>/dev/null
}
_ls_stub stopped
check "the launcher's own word is read from its json" "stopped" "$(_ls_probe personal_launcher_state)"
check "a stopped deployment whose runner still answers reads as stopped" "stopped" "$(_ls_probe personal_status)"
_ls_stub stopped --text-only
check "...and a launcher without --json is still understood" "stopped" "$(_ls_probe personal_launcher_state)"
_ls_stub database_ready
check "a launcher that says ready, with SQL answering, is running" "running" "$(_ls_probe personal_status)"
# The runner the 2.3 launcher leaves behind must be recognised as OURS, or the
# reaper calls the kit's own process foreign and refuses to clear the port.
has "the reaper knows the 2.3 runner" '*exasol-local-runner*)   return 0 ;;' "$RP_SH"
has "...and still knows the 2.2 one" '*mac-runner*__daemon__*) return 0 ;;' "$RP_SH"
has "a stopped deployment holding its port is cleared before the start" \
    'Clearing a leftover Exasol runner still holding port' "$RP_SH"

# An update prompt that covers a several-minute start has to say so, and only
# for the launcher versions that actually behave that way.
has "the update explains the guest rebuild" 'rebuilds the deployment'"'"'s VM guest' \
    "$(cat "$ROOT/setup/lib/common.sh")"
has "...gated on 2.3 or newer" '_rue_guest_rebuild_from=2.2.99999' \
    "$(cat "$ROOT/setup/lib/common.sh")"

echo
echo "personal beyond macos (P2):"
# The module's macOS assumptions are out: the requirements gate admits Linux
# (requiring Podman, which the launcher does not install there), refuses WSL by
# name, and the asset map speaks the release's exact spelling - a lowercased
# guess is a 404 at download time.
_p2() { # _p2 <os> <arch> -> asset name under stubbed detection
    bash -c '
        . "$0/setup/lib/detect.sh" 2>/dev/null
        detect_os() { echo "'"$1"'"; }
        detect_arch() { echo "'"$2"'"; }
        eval "$(sed -n "/^personal_asset_name()/,/^}/p" "$0/setup/lib/runtime-personal.sh")"
        personal_asset_name' "$ROOT" 2>/dev/null
}
check "asset(macos/arm64)"  "exasol-personal_macOS_arm64.tar.gz"  "$(_p2 macos arm64)"
check "asset(macos/x86_64)" "exasol-personal_macOS_x86_64.tar.gz" "$(_p2 macos x86_64)"
check "asset(linux/arm64)"  "exasol-personal_Linux_arm64.tar.gz"  "$(_p2 linux arm64)"
check "asset(linux/x86_64)" "exasol-personal_Linux_x86_64.tar.gz" "$(_p2 linux x86_64)"
# The gate, behaviourally: what it says when it refuses is the user's whole
# experience of the refusal, so the checks pin the die() reason - not the text
# of the case arm.
_p2gate() { _p2gate_setup "$@" | tail -1; }   # the verdict line alone
_p2gate_setup() { # _p2gate_setup <os> <with-podman:0|1> [installable] -> all output
    _pg_bin="$WORK/p2-bin-$1-$2"; mkdir -p "$_pg_bin"
    # A PATH with the tools the probe needs and NOTHING found by accident:
    # GitHub's ubuntu runners ship podman in /usr/bin, so scrubbing to
    # "$stub:/usr/bin:/bin" made the no-podman case find the real one and
    # pass a gate this check exists to see refuse.
    for _pg_tool in bash sed tr grep head cat uname sleep; do
        _pg_src="$(command -v "$_pg_tool" 2>/dev/null || true)"
        [ -n "$_pg_src" ] && ln -sf "$_pg_src" "$_pg_bin/$_pg_tool"
    done
    [ "$2" = 1 ] && { printf '#!/bin/sh\nexit 0\n' > "$_pg_bin/podman"; chmod +x "$_pg_bin/podman"; }
    # $3=installable: a package manager the kit knows, and a way to become root.
    if [ "${3:-0}" = 1 ]; then
        for _pg_have in apt-get sudo; do
            printf '#!/bin/sh\nexit 0\n' > "$_pg_bin/$_pg_have"; chmod +x "$_pg_bin/$_pg_have"
        done
    fi
    PATH="$_pg_bin" bash -c '
        die() { echo "DIED: $*"; exit 1; }
        error() { :; }; ok() { echo "OK: $*"; }
        # KEPT, not swallowed. What the gate SAYS when it defers is now the
        # whole of its refusal behaviour - there is no die() left to pin - so
        # the checks below read these lines. tail -1 still yields the verdict.
        info() { echo "INFO: $*"; }; warn() { echo "WARN: $*"; }
        confirm_env() { return 0; }
        . "$0/setup/lib/detect.sh" 2>/dev/null
        detect_os() { echo "'"$1"'"; }
        detect_arch() { echo arm64; }
        detect_ram_gb() { echo 16; }
        detect_free_disk_gb() { echo 100; }
        EXAKIT_BIN_DIR="$1"
        EXAKIT_PERSONAL_DEPLOY_DIR="$1/no-deployment"
        # BY NAME, not by position. This used to read "from the first constant
        # to the first closing brace", which silently stopped defining the gate
        # the moment a new function was added ANYWHERE above it - the checks
        # then compared against an empty string and blamed the gate. The
        # constants and the function under test are now each asked for by name.
        eval "$(sed -n "/^EXAKIT_PERSONAL_/p" "$0/setup/lib/runtime-personal.sh" | grep -v "()")"
        eval "$(sed -n "/^_personal_podman_install_cmd()/,/^}/p" "$0/setup/lib/runtime-personal.sh")"
        eval "$(sed -n "/^personal_podman_installable()/,/^}/p" "$0/setup/lib/runtime-personal.sh")"
        eval "$(sed -n "/^personal_check_requirements()/,/^}/p" "$0/setup/lib/runtime-personal.sh")"
        # The rootless heal is a different subject with its own suite; here it
        # must only not be missing.
        personal_heal_rootless_podman() { :; }
        unset EXAKIT_DB_PORT
        personal_check_requirements 2>/dev/null' "$ROOT" "$_pg_bin" 2>/dev/null
}
# NOT A HARD STOP ANY MORE, on either branch. Ending the run here cost the
# launcher, exapump, the AI bridge and the exakit command - none of which need
# Podman - before a single file was written. ONE PLACE decides what a missing
# Podman costs and it is the database step, which records it and lets the rest
# of the install finish. The gate still SAYS it, up front, so nobody watches a
# whole install to find out.
_p2nolinux="$(_p2gate_setup linux 0)"
check "gate(linux, no podman, uninstallable) carries on" \
    "OK: Compatibility check passed (linux arm64, 16 GB RAM, 100 GB free)" "$(printf '%s\n' "$_p2nolinux" | tail -1)"
has "...naming podman as what is missing" "Podman is not installed on Linux" "$_p2nolinux"
has "...and what it costs" "database step will be skipped" "$_p2nolinux"
has "...and the command that finishes the job later" "re-run the installer" "$_p2nolinux"
lacks "...which is the installer, never exakit update" "exakit update" "$_p2nolinux"
lacks "...and nothing dies" "DIED" "$_p2nolinux"
check "gate(linux, podman) passes" \
    "OK: Compatibility check passed (linux arm64, 16 GB RAM, 100 GB free)" "$(_p2gate linux 1)"
# WSL IS A SUPPORTED PLATFORM, and these four checks are why. The kit used to
# die on it; the launcher never did - its Linux local runtime asks for a podman
# on PATH and nothing else, and a WSL2 distro is an AMD64 Linux that can have
# one. So WSL now passes the same gate Linux passes, and fails it the same way,
# with a remedy written for the distro rather than for a machine the reader
# would have to go and buy.
# The documented promise has to match the gate: a WSL reader is now given the
# Linux road and the one prerequisite that differs, not an exit.
has "the README sends WSL down the Linux road" "WSL** is supported" "$(cat "$ROOT/README.md")"
has "...naming the podman that counts" "does not count" "$(cat "$ROOT/README.md")"
has "the Linux quickstart claims the WSL path" "also the WSL path" "$(cat "$ROOT/quickstarts/linux.md")"
has "the Windows quickstart hands WSL over" "supported too" "$(cat "$ROOT/quickstarts/windows.md")"
lacks "no doc still says Personal refuses WSL" "does not support WSL" \
    "$(cat "$ROOT/README.md" "$ROOT/quickstarts/linux.md" "$ROOT/quickstarts/windows.md" "$ROOT/setup/help/personal.json")"
check "gate(wsl, podman) passes like linux" \
    "OK: Compatibility check passed (wsl arm64, 16 GB RAM, 100 GB free)" "$(_p2gate wsl 1)"
_p2nowsl="$(_p2gate_setup wsl 0)"
check "gate(wsl, no podman, uninstallable) carries on" \
    "OK: Compatibility check passed (wsl arm64, 16 GB RAM, 100 GB free)" "$(printf '%s\n' "$_p2nowsl" | tail -1)"
has "...with the distro's own remedy" "uidmap" "$_p2nowsl"
has "...and the WINDOWS-side warning kept" "does not count" "$_p2nowsl"
lacks "...and nothing dies in WSL either" "DIED" "$_p2nowsl"
# A MACHINE THE KIT CAN FETCH PODMAN FOR IS NOT TURNED AWAY. Refusing here sent
# a user to their package manager and back to the beginning of the install; the
# database step installs it instead, between the launcher and the deployment
# (personal_install_podman), and asks before it touches the system. The gate
# still refuses where that cannot work - no package manager it knows, or no way
# to become root - which is what the two checks above are.
check "gate(linux, no podman but installable) carries on" \
    "OK: Compatibility check passed (linux arm64, 16 GB RAM, 100 GB free)" "$(_p2gate linux 0 1)"
check "gate(wsl, no podman but installable) carries on" \
    "OK: Compatibility check passed (wsl arm64, 16 GB RAM, 100 GB free)" "$(_p2gate wsl 0 1)"
# ...and it is the DATABASE step that does it, not the gate: a package install
# must not run in front of a machine that has not yet agreed to anything.
_p2dep="$(sed -n '/^personal_deploy_local()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh")"
has "the deployment installs podman before anything else" "personal_install_podman" "$_p2dep"
_p2first="$(printf '%s\n' "$_p2dep" | grep -nE '^\s+[a-z_]+' | grep -v '^\s*#' | head -1)"
has "...as its first act" "personal_install_podman" "$_p2first"
_p2ins="$(sed -n '/^personal_install_podman()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh")"
# NO QUESTION. The database runs through Podman and the user asked for the
# database; a y/n whose only sensible answer is yes bought nothing and cost a
# keystroke in the middle of an install. It is still announced - the warn says
# what is missing, the spinner says what is being done - and EXAKIT_INSTALL_PODMAN=0
# is the way out for a scripted run where package installs are someone else's job.
lacks "the podman install does not stop to ask" "confirm_env EXAKIT_INSTALL_PODMAN" "$_p2ins"
has "...but it is still announced" "Podman is not installed" "$_p2ins"
has "...and there is a way out for a run that must not install" \
    "EXAKIT_INSTALL_PODMAN=0" "$_p2ins"
# THE SCREEN SHOWS A QUESTION, A PASSWORD IF ONE IS NEEDED, AND A SPINNER.
# It used to show three screens of apt unpacking eighty packages, in the middle
# of an install that gives every other step one line. Nothing is hidden - every
# one of those lines is in the logfile - and the command itself is logged by
# run_logged, which is what puts it there.
has "the package manager runs behind the spinner" 'run_logged ${_pin_run}sh -c' "$_p2ins"
lacks "...not across the screen" 'info "Installing Podman' "$_p2ins"
has "...under a label that says what is happening" 'EXAKIT_ACTIVE_LABEL="Installing Podman"' "$_p2ins"
# THE PASSWORD IS ASKED FOR ON ITS OWN, BEFORE the capture. A captured sudo
# waiting on a password behind a spinner is a machine that looks hung.
has "the password is asked for in the open" "sudo -v" "$_p2ins"
has "...only when sudo will really ask" "sudo -n true" "$_p2ins"

# -n on the RUN: a sudoers that caches nothing would otherwise hang the
# captured command on a prompt nobody can see.
has "...while the captured run can never sit on a prompt" 'sudo -n ' "$_p2ins"
has "...and a run with no terminal says so instead of waiting" \
    "no terminal to type an administrator password on" "$_p2ins"
# ...and the compatibility check no longer says what the step below is about to
# say for itself.
lacks "the gate does not pre-announce the podman install" \
    "the kit installs it before the database step" \
    "$(sed -n '/^personal_check_requirements()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh")"
has "...and checks podman is really there afterwards" "still not on PATH" "$_p2ins"
lacks "...and never runs on macOS or Windows" "macos)" \
    "$(printf '%s\n' "$_p2ins" | sed -n '/case "$(detect_os)" in/,/esac/p' | grep -v '\*)')"
# Debian and Ubuntu need uidmap in the same breath: without it rootless Podman
# fails much later, inside a container start, naming neither.
# A CAPTURED PACKAGE INSTALL MUST NOT BE ABLE TO WAIT ON A PROMPT NOBODY SEES.
# Moving apt behind the spinner is what made this matter: needrestart ships by
# default on Ubuntu 22.04 and later and asks which services to restart, dpkg
# asks about config files, and with the output in the logfile the only thing on
# screen is a spinner counting past 500 seconds. The prompts are turned off at
# the source, and the redirect is the belt - anything that still asks reads EOF
# and fails in a second, which is a failure a reader can act on.
_p2auto="$(sed -n '/^_personal_podman_install_cmd_auto()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh")"
has "the captured apt cannot be asked a question" "DEBIAN_FRONTEND=noninteractive" "$_p2auto"
has "...including the one needrestart asks" "NEEDRESTART_MODE=a" "$_p2auto"
has "...and dpkg keeps the config already there" "force-confold" "$_p2auto"
has "...with EOF as the backstop for anything else" "</dev/null" "$_p2auto"
# EVERY package manager gets the backstop, not only apt.
check "...on every package manager the kit knows" "2" \
    "$(printf '%s' "$_p2auto" | grep -c '</dev/null')"
# ...and the command a HUMAN is told to run stays short enough to retype.
lacks "the printed command is still the short one" "DEBIAN_FRONTEND" \
    "$(sed -n '/^_personal_podman_install_cmd()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh")"
has "...while the run uses the hardened twin" '_pin_auto="$(_personal_podman_install_cmd_auto' "$_p2ins"

has "the apt command brings uidmap too" "apt-get install -y podman uidmap" \
    "$(sed -n '/^_personal_podman_install_cmd()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh")"
# WINDOWS DOES NOT INSTALL IT ITSELF - the launcher does, through winget, as
# part of `install local`. So the Windows half's job is to say what is about to
# happen and what to do when the machine refuses it: an unelevated winget on a
# managed laptop fails, and the first the user heard of it was the launcher's
# own error, mid-deploy, with no mention of Podman at all.
_p2win="$(sed -n '/^function Install-PersonalDeployment/,/^}/p' "$ROOT/setup/lib/runtime-personal.ps1")"
has "windows names podman when it is missing" "Podman is not installed on this machine" "$_p2win"
has "...saying the launcher does it, with admin" "may ask for administrator approval" "$_p2win"
has "...and the command to run if that fails" "winget install RedHat.Podman" "$_p2win"
has "...and a failed deploy blames podman when it is still absent" "Podman is still not installed" "$_p2win"
lacks "...and the every-deploy clause is gone" "installs Podman if needed" "$_p2win"
# ---------------------------------------------------------------------------
# NO PODMAN IS A STEP THAT DID NOT FINISH, NOT AN END TO THE RUN
#
# Saying no to the Podman install used to close the whole installer - the
# launcher, exapump, the AI bridge, pyexasol and the exakit command that
# repairs all of them, none of which the user had declined. It is now the same
# shape as every other step that cannot finish: recorded, named in the closing
# summary with the one command that completes it, and skipped past.
_p2ins2="$(sed -n '/^personal_install_podman()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh")"
lacks "a missing podman never ends the run" "die " "$_p2ins2"
check "...every refusal returns instead" "7"     "$(printf '%s' "$_p2ins2" | grep -c 'return 1')"
check "...and each one leaves a reason behind" "7"     "$(printf '%s' "$_p2ins2" | grep -c 'exakit_note_failure')"
has "the deployment stops when it cannot get podman" "personal_install_podman || return 1"     "$(sed -n '/^personal_deploy_local()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh")"

for _p2setup in setup-linux.sh setup-macos.sh; do
    _p2body="$(cat "$ROOT/setup/$_p2setup")"
    has "$_p2setup records the database step"         'exakit_record_soft_failure runtime "$(exakit_install_command)"' "$_p2body"
    has "...with the reason the deploy left" 'exakit_take_failure_note' "$_p2body"
    has "...and says the install carries on"         "carrying on so the rest of the install completes" "$_p2body"
    # THE RESUME ARM TOO. A re-run whose deployment is gone redeploys, and that
    # redeploy fails the same single way - it used to fall straight through to
    # rollback_clear and let every later step discover the missing database one
    # refused connection at a time.
    check "...on all three arms: the install, the redeploy and the start" "3"         "$(printf '%s' "$_p2body" | grep -c 'exakit_record_soft_failure runtime')"
done

# The steps that need a database say so ONCE, together, and the exakit helper
# still installs - it is the command that finishes the job later.
_p2kss="$(sed -n '/^kit_shared_steps()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "the db-dependent steps are skipped in one line"     "they all need the database, which is not installed" "$_p2kss"
has "...decided by the recorded failure" 'exakit_soft_failed runtime' "$_p2kss"
check "...guarding all four of them" "4"     "$(printf '%s' "$_p2kss" | grep -c 'if \[ "$_kss_nodb" = 1 \]')"
has "...and the exakit helper still runs" "begin_step exakit_helper" "$_p2kss"

# THE WINDOWS TWIN. There the LAUNCHER installs Podman, through winget, so the
# kit cannot retry it - but a machine whose winget refused must reach the end of
# the install exactly as the sh side does.
_p2winrt="$(cat "$ROOT/setup/lib/runtime-personal.ps1")"
_p2winsu="$(cat "$ROOT/setup/setup-windows.ps1")"
has "windows flags a podman-less deploy rather than failing it"     'script:PersonalNoDatabase = $true' "$_p2winrt"
has "...leaving the same kind of reason"     'Set-ExakitFailureReason "Podman is not installed and the launcher' "$_p2winrt"
has "...and the windows step records it"     'Register-ExakitSoftFailure -Component "runtime"' "$_p2winsu"
check "...on both arms, like the sh side" "2"     "$(printf '%s' "$_p2winsu" | grep -c 'Register-ExakitSoftFailure -Component "runtime"')"
has "...and the db-dependent steps skip in one line"     "they all need the database, which is not installed" "$_p2winsu"
check "...guarding all four of them too" "4"     "$(printf '%s' "$_p2winsu" | grep -c 'dbReady -and')"

# THE REPAIR IS THE INSTALLER. `exakit update` only moves components with a
# newer advertised version, so a deployment that never happened is "already
# current" to it - measured on a Nano-to-Personal upgrade, where it skipped
# nano and reported nothing to do. A re-run resumes at the database step.
has "windows names the installer as the database repair"     'Register-ExakitSoftFailure -Component "runtime" -Repair (Get-ExakitInstallCommand)' "$_p2winsu"
lacks "...and never exakit update"     'Component "runtime" -Repair "exakit update"' "$_p2winsu"
lacks "the deploy hints never send the reader to exakit update (sh)"     "run 'exakit update'" "$(cat "$ROOT/setup/lib/runtime-personal.sh")"
lacks "...nor on windows"     "run 'exakit update'" "$_p2winrt"
_p2sfsh="$(sed -n '/^exakit_print_soft_failures()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "a failed database is not called ready in the summary (sh)"     "Everything that does not need the database is ready" "$_p2sfsh"
_p2sfps="$(sed -n '/^function Write-ExakitSoftFailures/,/^}/p' "$ROOT/setup/lib/exakit-common.ps1")"
has "...nor on windows"     "Everything that does not need the database is ready" "$_p2sfps"

# A WINDOWS FILE LOCK IS RETRIED. The launcher renames a temp file over
# runtime-artifacts\index.json, and Windows refuses that while a scanner holds
# the target open ("Access is denied"); the next run went straight through.
_p2winil="$(sed -n '/^function Invoke-PersonalInstallLocal/,/^}/p' "$ROOT/setup/lib/runtime-personal.ps1")"
has "windows deploys through the lock-aware wrapper"     'Invoke-PersonalInstallLocal $installArgs' "$(sed -n '/^function Install-PersonalDeployment/,/^}/p' "$ROOT/setup/lib/runtime-personal.ps1")"
has "...which retries only on the lock signature"     'Access is denied|being used by another process' "$_p2winil"
has "...never over a deployment that exists"     'Test-PersonalDeploymentExists' "$_p2winil"
has "...and gives up after a bounded number of tries"     '$attempts = 3' "$_p2winil"

# ---------------------------------------------------------------------------
# INSTALLED IS NOT RUNNING
#
# `command -v podman` says the binary is on PATH and nothing about whether it
# can start a container. A rootless podman with no sub-id range, storage left
# by another uid, or - on Windows - a machine that is simply switched off, all
# pass that test and fail inside the launcher minutes later, with an error that
# names neither podman nor the kit. Both halves now ask podman itself.
_p2run="$(sed -n '/^personal_podman_running()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh")"
has "linux asks podman whether it works" "podman info" "$_p2run"
has "...repairing the commonest cause once before giving up"     "personal_heal_rootless_podman" "$_p2run"
has "...and says what podman said" "What it said" "$_p2run"
has "...leaving a reason for the summary" "exakit_note_failure" "$_p2run"
has "...and it is a soft failure like the rest" "return 1" "$_p2run"
_p2dep2="$(sed -n '/^personal_deploy_local()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh")"
has "the deployment asks before it deploys" "personal_podman_running || return 1" "$_p2dep2"

_p2winrun="$(sed -n '/^function Test-PersonalPodmanRunning/,/^}/p' "$ROOT/setup/lib/runtime-personal.ps1")"
has "windows asks podman whether it works too" "Test-PersonalPodmanAnswers" "$_p2winrun"
# THE ONE THING WINDOWS HAS THAT LINUX DOES NOT: podman there is a Linux VM,
# and after a reboot it is off. Starting it is not reconfiguring it.
has "...and starts a machine that is merely stopped" '"machine" "start"' "$_p2winrun"
has "...only when it really is stopped" 'machine", "list"' "$_p2winrun"
has "...putting the whole error in the log" 'Invoke-ExakitLogged $podman.Source "info"' "$_p2winrun"
has "...and naming the command that finishes the job" "re-run the installer" "$_p2winrun"
has "the windows deploy asks before it deploys"     "elseif (-not (Test-PersonalPodmanRunning))" "$(cat "$ROOT/setup/lib/runtime-personal.ps1")"

# ---------------------------------------------------------------------------
# A START THE LAUNCHER ACCEPTED IS NOT A DATABASE
#
# The launcher's `start` exits 0 and does nothing in more than one state. The
# kit knew about "deployment_failed"; it did not know about a deployment the
# launcher has initialized but never deployed, which takes the start, warns
# that a deploy is what it needs, and leaves nothing listening. The kit said
# "Reusing the existing Exasol deployment (started)", waited its whole
# 150-second budget, and ended the run - while `exasol deploy`, by hand, fixed
# it in twenty seconds. So the check reads the DATABASE, not the state string.
_p2ord="$(sed -n '/^personal_wait_ready_or_deploy()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh")"
has "a start that produced nothing is repaired, not waited out" \
    "_personal_wait_ready_probe" "$_p2ord"
has "...with the launcher's own deploy" 'deploy $(personal_auto_approve_flag deploy)' "$_p2ord"
has "...and asked again afterwards" "The database answered after the launcher's deploy" "$_p2ord"
has "...leaving a reason when even that fails" "exakit_note_failure" "$_p2ord"
lacks "...and never ending the run" "die " "$_p2ord"
# The probe and the fatal wrapper are separate, so every caller OUTSIDE the
# install still gets the hard stop it was written for.
has "the fatal wrapper is still there for its own callers" \
    "die " "$(sed -n '/^personal_wait_ready()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh")"
_p2dep3="$(sed -n '/^personal_deploy_local()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh")"
check "...and the three adoption paths all use the repairing one" "3" \
    "$(printf '%s' "$_p2dep3" | grep -c 'personal_wait_ready_or_deploy || return 1')"
# THE WAIT IS AT THE CALL SITE, not inside personal_start: two best-effort
# callers in legacy-crossing.sh run it as `personal_start >/dev/null 2>&1 ||
# true`, and a silent 150-second block is not what they asked for.
has "exakit start waits for the database it asked for" "personal_wait_ready_or_deploy" \
    "$(sed -n '/^exakit_runtime_start()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "...and the runtime self-heal uses the same repair" "personal_wait_ready_or_deploy" \
    "$(sed -n '/^exakit_ensure_runtime_running()/,/^}/p' "$ROOT/setup/lib/common.sh")"
lacks "...while personal_start stays a nudge its other callers can afford" \
    "personal_wait_ready_or_deploy" \
    "$(sed -n '/^personal_start()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh")"

# NOTHING IN THE DEPLOY STEP ENDS THE RUN ANY MORE except a machine that cannot
# make a temporary directory. Declining to reuse a running database closed the
# installer at step 2 of 6; so did declining to delete a stopped one, a foreign
# process on the port, and a deploy that failed. None of those leave anything
# half written, and none of them are reasons to withhold the rest of the kit.
check "the deploy step has one hard stop left, and it is the environment" "1" \
    "$(printf '%s' "$_p2dep3" | grep -c '^        die ')"
has "...declining a running database is recorded" \
    "Declined to reuse the database already running" "$_p2dep3"
has "...so is declining to delete a stopped one" \
    "deleting it was declined" "$_p2dep3"
has "...so is a port held by something else" \
    "is held by something that is not an Exasol Personal deployment" "$_p2dep3"
has "...and so is a deploy the launcher could not do" \
    "could not deploy the database locally" "$_p2dep3"
# THE DESTROY IS DISARMED, NOT FIRED. push_rollback arms a destroy before the
# deploy; the run is no longer ending, and a partial deployment is what a retry
# has to look at.
check "...disarming the undo it no longer wants" "2" \
    "$(printf '%s' "$_p2dep3" | grep -c 'rollback_clear')"
# ...and the deployment that survives has accepted the licence terms.
has "...and the licence notice survives that path" \
    '_personal_deploy_print_notice "$_deploy_notice"' "$_p2dep3"

for _p2setup2 in setup-linux.sh setup-macos.sh; do
    _p2body2="$(cat "$ROOT/setup/$_p2setup2")"
    # A SUBSHELL, because personal_start still dies - right for `exakit start`,
    # wrong for one step of six.
    has "$_p2setup2 survives a start that cannot finish" \
        "( personal_start && personal_wait_ready_or_deploy )" "$_p2body2"
    has "...recording it against the right repair" \
        'exakit_record_soft_failure runtime "exakit start"' "$_p2body2"
done

_p2winh="$(cat "$ROOT/setup/lib/runtime-personal.ps1")"
has "windows repairs the same start" "function Wait-PersonalReadyOrDeploy" "$_p2winh"
has "...keeping the fatal wrapper for its own callers" "function Wait-PersonalReady {" "$_p2winh"
has "...and the probe answers instead of failing" "function Test-PersonalReadyProbe" "$_p2winh"
has "...exakit start waits for it there too" "Wait-PersonalReadyOrDeploy" \
    "$(cat "$ROOT/setup/exakit.ps1")"
lacks "...while Start-Personal stays a nudge" "Wait-PersonalReadyOrDeploy" \
    "$(sed -n '/^function Start-Personal/,/^}/p' "$ROOT/setup/lib/runtime-personal.ps1")"
# ONE FLAG, because it stopped meaning "no podman" the moment a declined reuse
# and a failed deploy started using it.
lacks "...under one name for every cause" "PersonalNoPodman" "$_p2winh"
check "...set by each cause that leaves no database" "9" \
    "$(printf '%s' "$_p2winh" | grep -c 'PersonalNoDatabase = $true')"
has "the windows resume arm survives a start that cannot finish" \
    'Invoke-ExakitSoftStep -Component "runtime" -Repair "exakit start"' \
    "$(cat "$ROOT/setup/setup-windows.ps1")"

check "the installer no longer turns WSL away" "" \
    "$(grep -c 'it does not support WSL' "$ROOT/install.sh" "$ROOT/setup/lib/runtime-personal.sh" "$ROOT/setup/lib/detect.sh" 2>/dev/null | grep -v ':0$' | tr '\n' ' ')"
check "...and routes it to the Linux setup" "setup/setup-linux.sh" \
    "$(sed -n '/^        Linux)/,/^            ;;/p' "$ROOT/install.sh" | sed -n 's/.*setup_script="\([^"]*\)".*/\1/p')"
check "gate(macos) unchanged" \
    "OK: Compatibility check passed (macos arm64, 16 GB RAM, 100 GB free)" "$(_p2gate macos 0)"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
