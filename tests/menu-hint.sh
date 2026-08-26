#!/usr/bin/env bash
# Guard the checkbox menu's keyboard hint: it must describe what the keys do.
#
# On an either/or menu - exactly two selectable rows, one of them exclusive -
# Space does not toggle anything a reader would call a toggle. It moves the tick
# from one answer to the other, which is choosing. The kit asks two such
# questions (the marketplace offer, the JSON Tables offer) and both said
# "Space to toggle", inviting the reader to switch both answers off (Enter then
# silently refuses, because a selection is required) or to read two answers to
# one question as two independent switches.
#
# A real multi-select keeps "toggle" - that IS what Space does there - so this
# checks BOTH shapes. A fix that said "select" everywhere would be just as wrong
# in the other direction, and a test that only looked at the either/or menu
# would not notice.
#
# The verb is derived from the menu's shape, not set per call site, so this also
# pins that behaviour: a new either/or menu must get it without anyone
# remembering to ask. Run:
#
#   bash tests/menu-hint.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
checks=0

pass() { checks=$((checks + 1)); printf 'ok   %s\n' "$1"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
export EXAKIT_HOME="$WORK/kit-home"; mkdir -p "$EXAKIT_HOME"

# The hint is only drawn on a terminal, so each case runs under a pty and the
# menu is answered with a single Enter.
render() { # render <script-body> -> the drawn frames, escape codes stripped
    printf '%s\n' "$1" > "$WORK/case.sh"
    printf '\n' | script -q /dev/null bash "$WORK/case.sh" 2>&1 \
        | sed 's/\x1b\[[0-9;]*[A-Za-z]//g'
}

PRELUDE=". '$ROOT/setup/lib/ui.sh' 2>/dev/null; ui_detect 2>/dev/null
. '$ROOT/setup/lib/common.sh'"

# 1. Either/or: two selectable rows and an exclusive index.
out="$(render "$PRELUDE
EXAKIT_CHECKBOX_EXCLUSIVE=2 ui_checkbox_menu 'Explore ?' '1' \
    'Yes' 'No'")"
case "$out" in
    *"Space to select"*) pass "an either/or menu says 'Space to select'" ;;
    *"Space to toggle"*) fail "an either/or menu still says 'Space to toggle' - Space chooses there, it does not toggle" ;;
    *)                   fail "an either/or menu drew no keyboard hint at all" ;;
esac

# 2. Multi-select with an exclusive Skip row: Space really does toggle the
#    add-on rows, so the wording must NOT change here.
out="$(render "$PRELUDE
EXAKIT_CHECKBOX_EXCLUSIVE=3 ui_checkbox_menu 'Select add-ons to install' '1' \
    'dash-server' 'json-tables' 'Skip'")"
case "$out" in
    *"Space to toggle"*) pass "a multi-select with an exclusive row keeps 'Space to toggle'" ;;
    *"Space to select"*) fail "a real multi-select now says 'Space to select' - Space toggles there, the fix is too broad" ;;
    *)                   fail "a multi-select menu drew no keyboard hint at all" ;;
esac

# 3. Plain multi-select, no exclusive row at all.
out="$(render "$PRELUDE
ui_checkbox_menu 'Pick datasets' '1' 'tpch' 'weather' 'energy'")"
case "$out" in
    *"Space to toggle"*) pass "a plain multi-select keeps 'Space to toggle'" ;;
    *)                   fail "a plain multi-select lost its 'Space to toggle' hint" ;;
esac

# 4. Two rows but NO exclusive index: still a real multi-select (both can be
#    on), so "toggle" is right. This is the case a count-only check gets wrong.
out="$(render "$PRELUDE
ui_checkbox_menu 'Pick some' '1' 'first' 'second'")"
case "$out" in
    *"Space to toggle"*) pass "two rows without an exclusive index keep 'Space to toggle'" ;;
    *"Space to select"*) fail "two non-exclusive rows say 'Space to select' - both CAN be on, so Space toggles" ;;
    *)                   fail "the two-row menu drew no keyboard hint at all" ;;
esac

# 5. The PowerShell twin must decide the same way. It cannot be executed here
#    (no pwsh on every dev box), so the shape of the rule is checked instead:
#    both verbs present, and the either/or condition on exclusive AND count.
PS="$ROOT/setup/lib/exakit-common.ps1"
if grep -q 'Space to select' "$PS" && grep -q 'Space to toggle' "$PS"; then
    pass "the PowerShell twin carries both verbs"
else
    fail "the PowerShell twin does not carry both verbs - Windows keeps the wrong hint"
fi
if grep -qE 'ExclusiveIndex -ge 1 -and \$selectableCount -eq 2' "$PS"; then
    pass "the PowerShell twin gates on exclusive AND exactly two selectable rows"
else
    fail "the PowerShell twin's either/or condition is missing or changed shape"
fi

printf '\n%d checks, %d failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
