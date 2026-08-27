#!/usr/bin/env bash
# ps-table-twin.sh — the live datasets table exists on BOTH sides.
#
#   bash tests/ps-table-twin.sh
#
# setup/lib/ui.sh and setup/lib/ui.ps1 are documented twins, and the table is
# the component that arrived on the shell side first: for a while Windows still
# printed a line per dataset while macOS and WSL showed one persistent table.
# This pins the port so the two cannot drift apart again by omission —
# ui_table_* gaining a member with no PowerShell peer fails here.
#
# There is no pwsh on most dev boxes (CI's Linux runner has one), so this is a
# STATIC guard: names, wiring, the glyph rule, and a brace/paren/string balance
# check over every .ps1 — which is the one class of PowerShell mistake that is
# otherwise invisible until a Windows install fails to parse.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
checks=0

pass() { checks=$((checks + 1)); printf 'ok   %s\n' "$1"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL %s\n' "$1"; }

has() { # has <label> <needle> <file>
    if grep -qF -- "$2" "$3"; then pass "$1"; else fail "$1 (missing: $2)"; fi
}
lacks() { # lacks <label> <needle> <file>
    if grep -qF -- "$2" "$3"; then fail "$1 (present: $2)"; else pass "$1"; fi
}

UI_SH="$ROOT/setup/lib/ui.sh"
UI_PS1="$ROOT/setup/lib/ui.ps1"
PUMP_SH="$ROOT/setup/lib/exapump.sh"
PUMP_PS1="$ROOT/setup/lib/exapump.ps1"
COMMON_PS1="$ROOT/setup/lib/exakit-common.ps1"

printf '\n== every ui_table_* has a named PowerShell twin ==\n'

# The map is deliberately explicit: a reviewer can read which shell function
# each PowerShell one answers, and adding a shell function without a twin means
# adding a row here and finding there is nothing to put in it.
#
#   <shell function>|<powershell function>
while IFS='|' read -r sh_fn ps_fn; do
    [ -n "$sh_fn" ] || continue
    if ! grep -q "^${sh_fn}()" "$UI_SH"; then
        fail "$sh_fn is gone from ui.sh — update this map, do not delete the twin"
        continue
    fi
    if grep -q "^function ${ps_fn} " "$UI_PS1" || grep -q "^function ${ps_fn}\$" "$UI_PS1"; then
        pass "$sh_fn -> $ps_fn"
    else
        fail "$sh_fn has no twin: ui.ps1 defines no $ps_fn"
    fi
done <<'MAPEOF'
ui_table_widths|Get-ExakitTableWidths
ui_table_frame|Get-ExakitTableFrame
ui_table_render|Show-ExakitTable
ui_table_redraw|Update-ExakitTable
ui_table_set|Set-ExakitTableRow
ui_table_tick|Set-ExakitTableTicks
ui_table_begin|Start-ExakitTable
ui_table_end|Stop-ExakitTable
ui_table_menu|Invoke-ExakitTableMenu
ui_animation_stop|Stop-ExakitAnimation
MAPEOF

# The two helpers with no direct shell name (_ui_table_prep is a bash-only
# fork-avoidance trick; building rows is a file write there and two calls here).
has "ui.ps1 builds a table"    "function New-ExakitTable"      "$UI_PS1"
has "...and appends rows"      "function Add-ExakitTableRow"   "$UI_PS1"
has "...and renders one cell"  "function Get-ExakitTableCell"  "$UI_PS1"

printf '\n== the cell is a bar over a phase, with the numbers stacked ==\n'

# Column 1 tick, column 2 name, column 3 status: a bar and its percentage on the
# first line, the phase and its elapsed count directly underneath, so the
# percentage sits vertically above the seconds.
has "the eighths come from the palette" '$script:UiProgressEighths[$rem]' "$UI_PS1"
has "the percentage is right-aligned"   '$pctText.PadLeft($num)'          "$UI_PS1"

# The width budget, which is the one piece of arithmetic in here that cannot be
# checked by running it. Both halves of it were wrong on the shell side and made
# the table flicker into two: the two-column left margin every row is built with
# was missing from the budget, so the table wrote the console's LAST column and
# the row wrapped; and the status column was measured from the stored string
# while the cell renders "<tick> <final>", two columns wider.
has "the left margin is in the width budget" '$over = 11 + $nameW + $statW + 3 - $cols' "$UI_PS1"
has "the status column is measured as rendered" '$row.Final.Length + $script:UiTick.Length + 1' "$UI_PS1"
has "and the status column gives way too"      '$statW -= $rest' "$UI_PS1"
has "the second line carries the phase" '$cell.Text2 = $script:UiDim + $phase' "$UI_PS1"
# Floors keep the frame ONE height in every state, or a growing frame scrolls the
# screen and every later cursor-up lands one line off.
has "the frame reserves its phase line" '$want = [int]$Table.Reserve'     "$UI_PS1"
has "the status column has a floor"     '$statW = 44'                     "$UI_PS1"
# A PowerShell [int] cast ROUNDS (and rounds .5 to even), so 12 eighths became
# two whole cells plus a half-cell frontier - a bar one cell ahead of the number
# beside it. The shell twin divides in integers, and the table has to agree with
# it cell for cell.
has "the table's bar floors, not rounds" '[int][Math]::Floor($units / 8)'  "$UI_PS1"

printf '\n== glyphs live only in ui.ps1 ==\n'

# Windows PowerShell 5.1 reads a BOM-less .ps1 with the legacy ANSI codepage, so
# a raw box-drawing byte anywhere else breaks the parse of the whole script.
# tests/ps-encoding-guard.sh proves the bytes; this proves the CONSEQUENCE was
# understood - the table's callers reach for the palette instead.
has "the datasets table asks for a middot" '$script:UiMidDot'  "$PUMP_PS1"
has "...which the palette defines"         '$script:UiMidDot = "'  "$UI_PS1"
lacks "the tree connectors are not typed there" 'Label "|- ' "$PUMP_PS1"

printf '\n== BOTH Windows entry points drive the table ==\n'

# This is the gap the shell side shipped with: only the standalone command
# started the table, so during an install it drew, stayed empty, and every
# dataset fell back to the single-line bar. The install path is the one that
# matters and it was the one untested.
STANDALONE="$(sed -n '/^function Show-ExakitDataLoadMenu/,/^}/p' "$PUMP_PS1")"
OFFER="$(sed -n '/^function Request-ExakitDataLoadOffer/,/^}/p' "$PUMP_PS1")"
case "$STANDALONE" in
    *"Start-ExakitDataTableRun"*) pass "the standalone command starts it" ;;
    *) fail "Show-ExakitDataLoadMenu never starts the table" ;;
esac
case "$STANDALONE" in
    *"Stop-ExakitDataTableRun"*) pass "...and stops it" ;;
    *) fail "Show-ExakitDataLoadMenu never stops the table" ;;
esac
case "$OFFER" in
    *"Start-ExakitDataTableRun"*) pass "the installer offer starts it" ;;
    *) fail "Request-ExakitDataLoadOffer never starts the table" ;;
esac
case "$OFFER" in
    *"Stop-ExakitDataTableRun"*) pass "...and stops it" ;;
    *) fail "Request-ExakitDataLoadOffer never stops the table" ;;
esac

printf '\n== the selection happens IN the table that fills in ==\n'

has "the shell selects in the table" 'ui_table_menu "$EXAKIT_TABLE_STATE"' "$PUMP_SH"
has "...and so does Windows"         "Invoke-ExakitTableMenu -Defaults"    "$PUMP_PS1"
has "the rows are built once"        "function New-ExakitDataTable"        "$PUMP_PS1"
has "a dataset finds its own row"    "function Get-ExakitDataTableRow"     "$PUMP_PS1"
# A dataset with a row reports INTO it; anything else still owns the one-line bar.
has "the load step routes to the row" 'Set-ExakitTableRow -Row $script:ExakitTableRow -State "running"' "$PUMP_PS1"
has "the finished row states the outcome" 'completed $($script:UiMidDot)'  "$PUMP_PS1"
has "a failed one says so"            '-State "failed"'                    "$PUMP_PS1"
# A live table is the same single animation slot as the spinner, or a per-file
# spinner paints over the frame and its Stop tears the table down.
has "the spinner defers to a live table"  '$script:UiTableLive) { $script:UiSpinNested++' "$UI_PS1"
has "a failure stops the animation first" "Stop-ExakitAnimation"           "$COMMON_PS1"
# A missing ui.ps1 must degrade to plainer output, not to CommandNotFoundException.
has "the no-ui fallback stubs the table" 'function Start-ExakitTable($Table = $null) { return $false }' "$COMMON_PS1"

printf '\n== the PowerShell stays 5.1-compatible ==\n'

# Windows PowerShell 5.1 is the floor: no ternary, no null-coalescing, no Clean
# block. Checked over every .ps1, because the table is not the only thing that
# would be broken by one.
while IFS= read -r file; do
    rel="${file#"$ROOT"/}"
    bad=""
    # Comments and single-quoted strings first: this file's own header says "no
    # ternary, no ??", and half the regexes in the kit contain a literal "\?.".
    # Scanning the raw text reports both as PowerShell 7 syntax.
    code="$(sed -e "s/'[^']*'//g" -e 's/#.*$//' "$file")"
    printf '%s\n' "$code" | grep -qE '\?\?'       && bad="$bad ??"
    printf '%s\n' "$code" | grep -qE '\$[A-Za-z_][A-Za-z0-9_]*\?\.' && bad="$bad ?."
    printf '%s\n' "$code" | grep -qE '^[[:space:]]*[Cc]lean[[:space:]]*\{' && bad="$bad clean-block"
    # A ternary is `<expr> ? <a> : <b>`; the shape that cannot be anything else
    # is a closing paren followed by a bare `?`.
    printf '%s\n' "$code" | grep -qE '\)[[:space:]]*\?[[:space:]]' && bad="$bad ternary"
    if [ -n "$bad" ]; then
        fail "$rel uses PowerShell 7 syntax:$bad"
    else
        pass "$rel is 5.1 syntax"
    fi
done <<EOF
$(find "$ROOT" -name '*.ps1' -not -path "$ROOT/.git/*" -not -path "$ROOT/.claude/*" | sort -u)
EOF

printf '\n== every .ps1 still balances ==\n'

# Nothing else in the repo parses PowerShell, and a stray brace in a file that
# only Windows loads is invisible here until an install dies. This is a crude
# lexer - comments, both here-string forms, both quote forms, backtick escapes
# and $( ) inside a string - counting (), [] and {}. Not a parser; enough to
# catch the mistake you make when you cannot run pwsh.
if command -v python3 >/dev/null 2>&1; then
    _bal="$(python3 - "$ROOT" <<'PYEOF'
import io, os, sys, glob

def check(path):
    with io.open(path, encoding="utf-8-sig") as fh:
        s = fh.read()
    i, n, line = 0, len(s), 1
    stack, errs = [], []
    while i < n:
        c = s[i]
        in_dq = bool(stack) and stack[-1][0] == "DQ"
        if c == "\n":
            line += 1; i += 1; continue
        if in_dq:
            if c == "`":
                i += 2; continue
            if s[i:i+2] == '""':
                i += 2; continue
            if s[i:i+2] == "$(":
                stack.append(("(", line)); i += 2; continue
            if c == '"':
                stack.pop(); i += 1; continue
            i += 1; continue
        if s[i:i+2] == "<#":
            j = s.find("#>", i + 2)
            if j < 0:
                errs.append((line, "unterminated <# comment")); break
            line += s.count("\n", i, j); i = j + 2; continue
        if c == "#":
            j = s.find("\n", i)
            i = n if j < 0 else j
            continue
        if s[i:i+2] in ("@'", '@"'):
            q = s[i+1]
            term = "\n" + q + "@"
            j = s.find(term, i + 2)
            if j < 0:
                errs.append((line, "unterminated here-string")); break
            line += s.count("\n", i, j + len(term)); i = j + len(term); continue
        if c == "'":
            j = i + 1
            while j < n:
                if s[j] == "'":
                    if j + 1 < n and s[j+1] == "'":
                        j += 2; continue
                    break
                if s[j] == "\n":
                    line += 1
                j += 1
            if j >= n:
                errs.append((line, "unterminated ' string")); break
            i = j + 1; continue
        if c == '"':
            stack.append(("DQ", line)); i += 1; continue
        if c == "`":
            i += 2; continue
        if c in "([{":
            stack.append((c, line)); i += 1; continue
        if c in ")]}":
            want = {")": "(", "]": "[", "}": "{"}[c]
            if not stack:
                errs.append((line, "closing %s with nothing open" % c)); i += 1; continue
            o, ol = stack.pop()
            if o != want:
                errs.append((line, "closing %s but %s opened on line %d" % (c, o, ol)))
            i += 1; continue
        i += 1
    for o, ol in stack:
        errs.append((ol, "unclosed %s" % o))
    return errs

root = sys.argv[1]
bad = []
for path in sorted(glob.glob(os.path.join(root, "**", "*.ps1"), recursive=True)):
    # .claude holds other agents' worktrees when this runs from a shared
    # checkout: their half-finished files are not this suite's business.
    if os.sep + ".git" + os.sep in path or os.sep + ".claude" + os.sep in path:
        continue
    for line, msg in check(path):
        bad.append("%s:%d: %s" % (os.path.relpath(path, root), line, msg))
print("\n".join(bad))
PYEOF
)"
    if [ -z "$_bal" ]; then
        pass "every .ps1 balances its braces, parens and strings"
    else
        fail "unbalanced PowerShell:"
        printf '%s\n' "$_bal" | sed 's/^/       /'
    fi
else
    printf 'SKIP the balance check needs python3\n'
fi

printf '\n%d checks, %d failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
