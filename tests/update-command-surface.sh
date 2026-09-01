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
#
# tests/ is skipped entirely, and not just this file. A suite that asserts the
# form is ABSENT from a screen has to spell the form out to say so -- six such
# `lacks` needles live in versions-manifest.sh -- so scanning tests counts every
# check that the form is gone as evidence that it is still there. Tests are not
# a surface anybody reads for guidance, which is what this guard is about.
scan() { # scan <component>
    grep -rn "exakit update $1" \
        --include="*.sh" --include="*.ps1" --include="*.json" --include="*.md" --include="exakit" \
        "$ROOT" 2>/dev/null \
        | grep -v '/CHANGELOG.md:' \
        | grep -v '/tests/' \
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
# Each component resolved ON ITS OWN, not via `all`. They are different arms:
# `all` prints the whole set from one branch, while `exakit update exapump` goes
# through the per-component branch -- which is the arm being hidden and so the
# only arm worth guarding. Asserting `all` here passed happily with the
# per-component arm deleted, which is the exact failure this section exists to
# catch.
for _want in exakit runtime exapump mcp pyexasol; do
    _got="$(bash -c ". '$ROOT/setup/lib/common.sh' 2>/dev/null; exakit_update_targets $_want 2>/dev/null" | tr '\n' ' ' || true)"
    case " $_got " in
        *" $_want "*) pass "\"$_want\" still resolves as an update target" ;;
        *)            fail "\"$_want\" no longer resolves - the capability was removed, not just hidden" ;;
    esac
done

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
