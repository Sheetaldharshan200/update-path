#!/usr/bin/env bash
# Guard: nothing a user can read names a component after `exakit update`.
#
# The per-component form still WORKS -- `exakit_update_targets` accepts it and
# `exakit update all` iterates it -- but it is deliberately not advertised: the
# everyday command is `exakit update`, and a reader who never learns the
# component form never has to choose between two ways of doing one thing.
#
# This is the opposite of the uninstall case, where the advertised form was
# rejected by the parser. Here the capability is real and stays; only its
# documentation goes. So the guard cannot simply run the command and check for
# an error -- it has to read the surfaces a user reads.
#
#   bash tests/update-command-surface.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# Every component that is a valid update target, plus the add-on-author template
# used in MARKETPLACE.md. Kept as a list rather than a wildcard so a NEW
# component has to be added here consciously.
COMPONENTS='dash-server runtime pyexasol exakit json-tables exapump personal exasol-vscode mcp kit2 my-tool'

printf '\n== no user-visible surface names a component after "exakit update" ==\n'

# CHANGELOG.md is a dated historical record of what shipped, and rewriting what
# a past release said is not the same as changing what the kit says now.
#
# Comment lines in shell and PowerShell are excluded because they explain the
# internals to whoever maintains this, and the component form is exactly what
# they have to talk about. A Markdown "#" is a heading, not a comment, so those
# files are read whole.
scan() { # scan <component>
    grep -rn "exakit update $1" \
        --include="*.sh" --include="*.ps1" --include="*.json" --include="*.md" --include="exakit" \
        "$ROOT" 2>/dev/null \
        | grep -v '/CHANGELOG.md:' \
        | grep -v "/tests/update-command-surface.sh:" \
        | grep -v '/.claude/' \
        | grep -vE ':[0-9]+: *#'
}

_offenders=0
for _c in $COMPONENTS; do
    _hits="$(scan "$_c" || true)"
    if [ -n "$_hits" ]; then
        _offenders=$((_offenders + 1))
        fail "\"exakit update $_c\" is still advertised"
        printf '%s\n' "$_hits" | sed "s|$ROOT/||" | sed 's/^/         /' | head -4
    fi
done
[ "$_offenders" -eq 0 ] && pass "no component name follows \"exakit update\" anywhere a user reads"

printf '\n== the flags that only exist on the component form are not advertised ==\n'
# --plan / --backup / --apply are parsed inside the Personal upgrade path, which
# is reached through `exakit update personal`. Written against bare
# `exakit update` they would be rejected, so documenting them there is worse
# than not documenting them at all.
_flaghits="$(grep -rn 'exakit update --\(plan\|backup\|apply\)' \
    --include="*.sh" --include="*.ps1" --include="*.json" --include="*.md" --include="exakit" \
    "$ROOT" 2>/dev/null | grep -v '/CHANGELOG.md:' | grep -v "/tests/update-command-surface.sh:" \
    | grep -v '/.claude/' || true)"
if [ -z "$_flaghits" ]; then
    pass "no staged-upgrade flag is written against bare \"exakit update\""
else
    fail "a flag that needs the component form is advertised on bare \"exakit update\""
    printf '%s\n' "$_flaghits" | sed "s|$ROOT/||" | sed 's/^/         /' | head -4
fi

printf '\n== the capability itself is untouched ==\n'
# The point is to stop ADVERTISING the form, not to remove it. If someone
# "fixed" this by deleting the targets, every check above would still pass while
# `exakit update` quietly stopped being able to update anything.
_targets="$(bash -c ". '$ROOT/setup/lib/common.sh' 2>/dev/null; exakit_update_targets all 2>/dev/null" | tr '\n' ' ' || true)"
for _want in exakit runtime exapump mcp pyexasol; do
    case " $_targets " in
        *" $_want "*) pass "\"$_want\" is still an update target" ;;
        *)            fail "\"$_want\" is no longer an update target - the capability was removed, not just hidden" ;;
    esac
done

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
