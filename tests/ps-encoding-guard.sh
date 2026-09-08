#!/usr/bin/env bash
# Guard against the Windows PowerShell 5.1 encoding trap.
#
# PowerShell 5.1 reads BOM-less .ps1 files using the legacy ANSI codepage, so
# raw non-ASCII bytes are misread (UTF-8 "├─" becomes garbage that can even
# terminate strings early and break parsing of the whole script). The repo
# rule: glyphs live only in setup/lib/ui.ps1 (which carries a UTF-8 BOM);
# every other .ps1 must be pure ASCII and reference the palette variables.
#
# This has bitten twice already (an em dash in mcp.ps1, tree connectors in
# exapump.ps1 that made the Windows install fail to parse). Run:
#
#   bash tests/ps-encoding-guard.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
checks=0

pass() { checks=$((checks + 1)); printf 'ok   %s\n' "$1"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL %s\n' "$1"; }

# 1. ui.ps1 must keep its UTF-8 BOM (PS 5.1 needs it to decode the glyphs).
bom="$(head -c 3 "$ROOT/setup/lib/ui.ps1" | od -An -tx1 | tr -d ' \n')"
if [ "$bom" = "efbbbf" ]; then
    pass "setup/lib/ui.ps1 has a UTF-8 BOM"
else
    fail "setup/lib/ui.ps1 lost its UTF-8 BOM (found: $bom)"
fi

# 2. Every other .ps1 must be pure ASCII (no bytes above 0x7F anywhere).
while IFS= read -r file; do
    rel="${file#"$ROOT"/}"
    case "$rel" in setup/lib/ui.ps1) continue ;; esac
    if LC_ALL=C grep -q $'[\x80-\xff]' "$file"; then
        offenders="$(LC_ALL=C grep -n $'[\x80-\xff]' "$file" | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')"
        fail "$rel contains non-ASCII bytes (lines $offenders) - use the ui palette variables instead"
    else
        pass "$rel is pure ASCII"
    fi
# .claude/ is excluded because a git worktree under .claude/worktrees/ is a
# FULL second checkout: its setup/lib/ui.ps1 is a copy of the one file allowed
# to hold glyphs, but the exemption above matches an exact path, so the copy
# reported as an offender. CI never sees this -- a fresh checkout has no
# worktrees -- so it only ever failed on a developer's machine, which is the
# worst place to spend a false failure.
done <<EOF
$(find "$ROOT" -name '*.ps1' -not -path "$ROOT/.git/*" -not -path "$ROOT/.claude/*" | sort)
EOF

# 3. "$var:" inside a double-quoted string is a PARSE ERROR, not a runtime one.
#
# PowerShell reads $name: as a drive-qualified variable ($env:, $script:,
# $global: are the ones people know), so "FAIL $label: expected ..." refuses to
# parse and the WHOLE FILE dies before a single line of it runs. There is no
# pwsh on the machine this kit is developed on, so the first time anyone found
# out was a red Windows job - which is a full CI round to learn something a
# regular expression can say in a second. ${label} is the fix.
#
# Only the known scope prefixes are allowed; anything else is the mistake.
while IFS= read -r file; do
    rel="${file#"$ROOT"/}"
    # Whole-line comments are skipped: they discuss the hazard (this file's own
    # note, and Test-ExakitLocalPath's "answers $true: ...") without being it.
    # The known scope prefixes are removed before the test, since $env: and
    # $script: are the legitimate form of exactly this syntax.
    hits="$(awk '
        /^[[:space:]]*#/ { next }
        {
            line = $0
            gsub(/\$(env|script|global|local|private|using|workflow):/, "", line)
            if (line ~ /"[^"]*\$[A-Za-z_][A-Za-z0-9_]*:/) print NR
        }' "$file" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
    if [ -n "$hits" ]; then
        fail "$rel has \$name: in a string (lines $hits) - PowerShell reads it as a drive; write \${name}:"
    else
        pass "$rel has no drive-ambiguous variable reference"
    fi
done <<EOF
$(find "$ROOT" -name '*.ps1' -not -path "$ROOT/.git/*" -not -path "$ROOT/.claude/*" | sort)
EOF

printf '\n%d checks, %d failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
