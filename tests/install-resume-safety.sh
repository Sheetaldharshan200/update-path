#!/usr/bin/env bash
# Guard two ways a RE-RUN of the installer could undo what the user already had.
#
# Both are resume-path bugs: the first run is fine, and the damage only appears
# on the second run, which is the run nobody tests by hand.
#
#   1. A resumed runtime step leaves its destroy/volume-rm armed. mark_step is
#      the only thing that clears the rollback stack, and a resume branch has no
#      mark_step to make -- the step is already recorded as done. So the undo
#      registered by the redeploy stays armed for the rest of the run, and any
#      later die offers to run it under a prompt that calls it "the failed
#      step's changes".
#
#   2. The installer overwrites a recorded `exakit autostart off`. An
#      unconditional exakit_autostart_enable wrote autostart.enabled=true before
#      exakit_autostart_default_on -- the function whose whole job is to leave a
#      recorded answer alone -- ever looked at it.
#
#   bash tests/install-resume-safety.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf '\n== rollback_clear empties the stack without disabling it ==\n'

# The pure helpers, lifted out so this stays hermetic and never sources a file
# that would try to touch a real install.
eval "$(sed -n '/^rollback_init()/,/^}/p;/^push_rollback()/,/^}/p;/^rollback_discard()/,/^}/p;/^rollback_clear()/,/^}/p' "$ROOT/setup/lib/common.sh")"

if ! command -v rollback_clear >/dev/null 2>&1; then
    fail "rollback_clear does not exist - a resumed deploy cannot disarm its undo"
else
    EXAKIT_ROLLBACK_FILE="$WORK/rb"
    : > "$EXAKIT_ROLLBACK_FILE"
    push_rollback "echo one"
    push_rollback "exasol destroy --remove --auto-approve"
    if [ "$(wc -l < "$EXAKIT_ROLLBACK_FILE" | tr -d ' ')" = "2" ]; then
        pass "two undo commands registered"
    else
        fail "push_rollback did not register both commands"
    fi

    rollback_clear
    if [ ! -s "$EXAKIT_ROLLBACK_FILE" ]; then
        pass "rollback_clear emptied the stack"
    else
        fail "rollback_clear left commands armed: $(cat "$EXAKIT_ROLLBACK_FILE")"
    fi
    # The distinction from rollback_discard is the whole point: the run has more
    # steps to go and they still need an undo of their own.
    if [ -n "${EXAKIT_ROLLBACK_FILE:-}" ] && [ -f "$EXAKIT_ROLLBACK_FILE" ]; then
        pass "...and left the stack itself live for the steps still to come"
    else
        fail "rollback_clear discarded the stack - later steps lose their undo"
    fi
    push_rollback "echo later"
    if [ -s "$EXAKIT_ROLLBACK_FILE" ]; then
        pass "...so a later step can still register one"
    else
        fail "nothing can be registered after rollback_clear"
    fi
fi

printf '\n== every resume branch disarms what it re-registered ==\n'

# Matched WITH CONTEXT, not merely "the file mentions rollback_clear": the call
# has to follow the redeploy in the resume branch. The bug was a branch that
# re-ran the deploy and said nothing, while the branch beside it was correct.
if grep -A6 'Deployment marked done but not reachable' "$ROOT/setup/setup-macos.sh" | grep -q 'rollback_clear'; then
    pass "macOS resume clears after redeploying"
else
    fail "macOS resume redeploys and leaves 'destroy --remove --auto-approve' armed"
fi
if grep -A8 'Runtime marked done but not running' "$ROOT/setup/setup-wsl.sh" | grep -q 'rollback_clear'; then
    pass "WSL resume clears after re-installing Nano"
else
    fail "WSL resume re-installs Nano and leaves 'volume rm' armed"
fi
# The first-run branches must NOT need it - they have a mark_step, which clears
# the stack as its side effect. A rollback_clear there would be noise that hides
# the fact that mark_step is what normally does this.
if grep -q 'personal_deploy_local$' "$ROOT/setup/setup-macos.sh" && \
   grep -A1 'personal_deploy_local$' "$ROOT/setup/setup-macos.sh" | grep -q 'mark_step runtime'; then
    pass "the first-run branch still relies on mark_step"
else
    fail "the first-run branch no longer marks the step"
fi

printf '\n== the installer does not overwrite a recorded autostart choice ==\n'

# exakit_autostart_enable writes autostart.enabled=true unconditionally, so
# calling it from the shared steps overrides an answer the user already gave.
# The setup scripts call exakit_autostart_default_on instead, near the end.
# Stated as an INVARIANT rather than "the bad line is gone": there must be
# exactly ONE call, and it must sit inside exakit_autostart_default_on. A guard
# that greps for the specific line that was removed passes the moment the same
# call comes back two lines higher, or spelled slightly differently -- which is
# exactly what happened when this check was first written.
_F="$ROOT/setup/lib/common.sh"
_calls="$(grep -n 'exakit_autostart_enable' "$_F" \
          | grep -v ':[[:space:]]*#' \
          | grep -v 'exakit_autostart_enable() {' \
          | cut -d: -f1)"
_ncalls="$(printf '%s\n' "$_calls" | grep -c '[0-9]' || true)"
_dstart="$(grep -n '^exakit_autostart_default_on()' "$_F" | cut -d: -f1)"
_dend="$(awk -v s="$_dstart" 'NR>=s && /^}/ { print NR; exit }' "$_F")"
if [ "$_ncalls" = "1" ]; then
    pass "exakit_autostart_enable has exactly one caller"
else
    fail "exakit_autostart_enable is called $_ncalls times - one of them overrides the user's choice (lines: $(printf '%s' "$_calls" | tr '\n' ' '))"
fi
_outside=0
for _l in $_calls; do
    if [ "$_l" -lt "$_dstart" ] || [ "$_l" -gt "$_dend" ]; then _outside=1; fi
done
if [ "$_outside" = "0" ]; then
    pass "...and it is inside exakit_autostart_default_on, which respects a recorded answer"
else
    fail "exakit_autostart_enable is called from outside exakit_autostart_default_on, so 'exakit autostart off' does not survive a re-run"
fi
for f in setup-macos.sh setup-wsl.sh; do
    if grep -q 'exakit_autostart_default_on' "$ROOT/setup/$f"; then
        pass "$f still defaults it on for a fresh install"
    else
        fail "$f no longer sets an autostart default - a fresh install loses it"
    fi
done

# And the function itself must keep leaving a recorded answer alone. Run, not
# read: this is the behaviour the whole finding turns on.
eval "$(sed -n '/^exakit_autostart_default_on()/,/^}/p' "$ROOT/setup/lib/common.sh")"
_recorded=""
manifest_get() { printf '%s\n' "$_recorded"; }
exakit_autostart_enable() { printf 'ENABLE-CALLED\n'; }
for _want in true false; do
    _recorded="$_want"
    if [ -z "$(exakit_autostart_default_on 2>&1)" ]; then
        pass "a recorded '$_want' is left alone"
    else
        fail "a recorded '$_want' was overwritten by the installer"
    fi
done
_recorded=""
if [ "$(exakit_autostart_default_on 2>&1)" = "ENABLE-CALLED" ]; then
    pass "and a manifest with no opinion still defaults to on"
else
    fail "a fresh install no longer turns autostart on"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
