#!/usr/bin/env bash
# Guard `exakit status`: every soft component reports its absence, not one.
#
# exapump, the MCP server and pyexasol all install through exakit_soft_step, so
# any of them can be missing from an install that "finished". The install-time
# report (exakit_print_soft_failures) prints once, from setup-macos.sh /
# setup-wsl.sh, and is long gone by the time anyone types `exakit status`.
#
# The status screen used to hardcode a single pyexasol check. A failed exapump
# was then visible only as an absence from the steps_completed array, which is
# the kind of signal a reader does not notice, while a failed pyexasol got a
# dedicated line with a repair command. Same failure, three treatments.
#
# The trap is that the pyexasol case keeps working while the other two silently
# do not, so a targeted test on pyexasol alone would stay green through the
# whole regression. Each component is therefore checked on its own. Run:
#
#   bash tests/status-soft-components.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
checks=0

pass() { checks=$((checks + 1)); printf 'ok   %s\n' "$1"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A kit home whose manifest says all three components were installed, so the
# "was it attempted" guard passes and absence is the only variable.
export HOME="$WORK/home"; mkdir -p "$HOME"
export EXAKIT_HOME="$WORK/kit-home"; mkdir -p "$EXAKIT_HOME"
export EXAKIT_BIN_DIR="$WORK/bin"; mkdir -p "$EXAKIT_BIN_DIR"
cat > "$EXAKIT_HOME/manifest.json" <<'JSON'
{
  "kit_level": 1,
  "runtime": { "type": "personal" },
  "steps_completed": ["launcher", "runtime", "exapump", "mcp", "pyexasol"],
  "components": {
    "exapump":    { "validated": true, "version": "0.12.0" },
    "mcp_server": { "validated": true, "version": "2.0.0" },
    "pyexasol":   { "validated": true, "version": "2.3.1" }
  }
}
JSON

# exakit with a stub that makes named components report absent. Injected after
# the library sourcing so it overrides the real probe.
STUB="$WORK/exakit"
# exakit resolves its library relative to its OWN directory, so the stub needs a
# lib/ beside it or it dies before printing a single row.
ln -s "$ROOT/setup/lib" "$WORK/lib"
{
    # Everything up to and including the last library source line...
    sed -n '1,/^\[ -f "\$_lib_dir\/json-tables.sh" \]/p' "$ROOT/setup/exakit"
    # ...then the override, so it wins over the real probe...
    cat <<'STUB_EOF'
if [ -n "${EXAKIT_TEST_ABSENT:-}${EXAKIT_TEST_PRESENT:-}" ]; then
    eval "exakit_component_current_real() $(declare -f exakit_component_current | tail -n +2)"
    exakit_component_current() {
        case " ${EXAKIT_TEST_ABSENT:-} " in *" $1 "*) return 1 ;; esac
        case " ${EXAKIT_TEST_PRESENT:-} " in *" $1 "*) printf '9.9.9\n'; return 0 ;; esac
        exakit_component_current_real "$@"
    }
fi
STUB_EOF
    # ...then the rest of the script.
    sed -n '/^\[ -f "\$_lib_dir\/json-tables.sh" \]/,$p' "$ROOT/setup/exakit" | tail -n +2
} > "$STUB"
chmod +x "$STUB"
# The stub is worthless if the injection missed, and a silent miss would make
# every check below "pass" by reporting nothing.
grep -q 'EXAKIT_TEST_ABSENT' "$STUB" || { printf 'FAIL could not build the test stub (injection point moved in setup/exakit)\n'; exit 1; }
bash -n "$STUB" || { printf 'FAIL the test stub does not parse\n'; exit 1; }

status_with_absent() { EXAKIT_TEST_ABSENT="$1" bash "$STUB" status 2>/dev/null; }

# 1. Each soft component, alone, must name itself AND its repair command.
while IFS='|' read -r id fix; do
    [ -n "$id" ] || continue
    out="$(status_with_absent "$id")"
    case "$out" in
        *"$id"*) : ;;
        *) fail "a missing $id is not reported by exakit status at all"; continue ;;
    esac
    case "$out" in
        *"$fix"*) pass "a missing $id is reported with: $fix" ;;
        *)        fail "a missing $id is named but its repair command ($fix) is not shown" ;;
    esac
done <<EOF
exapump|exakit update exapump
mcp|exakit update mcp
pyexasol|exakit update pyexasol
EOF

# 2. All three at once must each get their own line, not just the first.
out="$(status_with_absent "exapump mcp pyexasol")"
missing_named=0
for id in exapump mcp pyexasol; do
    case "$out" in *"exakit update $id"*) missing_named=$((missing_named + 1)) ;; esac
done
if [ "$missing_named" -eq 3 ]; then
    pass "all three missing components are listed together"
else
    fail "only $missing_named of 3 missing components were listed"
fi

# 3. A healthy screen stays quiet: no "Missing:" block, and no component version
#    row. Versions belong to `exakit version`. Every soft component is forced
#    PRESENT here - the sandbox has none of them on disk, so an unforced run is
#    not a healthy install and would "pass" this for the wrong reason.
out="$(EXAKIT_TEST_PRESENT="exapump mcp pyexasol" bash "$STUB" status 2>/dev/null)"
case "$out" in
    *Missing:*) fail "a healthy install still prints a Missing: block" ;;
    *)          pass "a healthy install prints no Missing: block" ;;
esac

# 4. steps_completed is machine data and must stay OUT of the human screen but
#    IN --json: dropping it from both would break agents parsing the install.
case "$out" in
    *"Steps done"*) fail "steps_completed is back on the human status screen" ;;
    *)              pass "the human screen does not print the steps array" ;;
esac
json="$(EXAKIT_TEST_PRESENT="exapump mcp pyexasol" bash "$STUB" status --json 2>/dev/null || true)"
case "$json" in
    *steps_completed*) pass "status --json still carries steps_completed" ;;
    *)                 fail "status --json lost steps_completed - agents parse this" ;;
esac

# 5. Labels line up. "dash-server:" is 12 characters against the old 11-column
#    pad, so any label at or past the pad width pushed its value out of line.
misaligned=""
col=""
while IFS= read -r line; do
    # Only "Label: value" rows. Split on the FIRST colon: a value may contain
    # colons of its own ("repair: exakit update ..."), and splitting on ": "
    # measured the label instead of where the value starts.
    case "$line" in
        *:*) ;;
        *) continue ;;
    esac
    # PANEL rows are not "Label: value" rows. This loop is about the plain rows
    # printed under the panels, where the values must line up with each other;
    # a panel draws its own interior and a colon inside one ("connect one with:
    # exakit mcp-setup") is prose, not a label. Scanning them too compared a
    # column inside a box against a column outside it, which is why this failed
    # on main for as long as status has drawn panels.
    case "$(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-3)" in
        '|'*|'+'*|'╭'*|'│'*|'╰'*|'─'*) continue ;;
    esac
    _lbl="${line%%:*}"
    _rest="${line#*:}"
    # the value column is the label, its colon, and the run of spaces after it
    _spaces="${_rest%%[! ]*}"
    _c=$(( ${#_lbl} + 1 + ${#_spaces} ))
    if [ -z "$col" ]; then col="$_c"
    elif [ "$_c" -ne "$col" ]; then misaligned="$misaligned ${_lbl}:@${_c}"
    fi
done <<EOF
$out
EOF
if [ -z "$misaligned" ]; then
    pass "every status row starts its value in the same column"
else
    fail "status rows are misaligned:$misaligned (label pad too narrow)"
fi

printf '\n%d checks, %d failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
