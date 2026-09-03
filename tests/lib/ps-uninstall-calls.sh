#!/usr/bin/env bash
# Every helper Invoke-ExakitUninstallRun calls must resolve when
# tests/uninstall-ps.ps1 runs it in isolation -- either because the test
# extracts the CLI's own functions, or because the test stubs it.
#
# This exists because that suite had NO caller anywhere and, on its first ever
# execution, died on a helper it did not stub -- with three more queued behind
# it, each costing a full CI round to discover. pwsh is not on the machine this
# kit is developed on, so without a check like this the only way to find the
# next one is to push and wait.
#
#   bash tests/lib/ps-uninstall-calls.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$ROOT/setup/exakit.ps1"
TEST="$ROOT/tests/uninstall-ps.ps1"
fails=0

awk '/^function Invoke-ExakitUninstallRun/,/^}/' "$CLI" > "/tmp/ps-uninst-fn.$$"
# PowerShell built-ins the test does not have to supply.
BUILTINS=" Get-Command Get-ChildItem Get-Content Remove-Item Test-Path Join-Path New-Item Set-Variable Write-Host Out-Null Where-Object ForEach-Object Select-Object Start-Process Split-Path "

while read -r call; do
    case "$BUILTINS" in *" $call "*) continue ;; esac
    [ "$call" = "Invoke-ExakitUninstallRun" ] && continue
    if grep -q "^function $call" "$CLI"; then continue; fi        # extracted
    if grep -q "^function $call" "$TEST"; then continue; fi       # stubbed
    printf 'FAIL %s is neither defined in exakit.ps1 nor stubbed in uninstall-ps.ps1\n' "$call"
    fails=$((fails + 1))
done < <(grep -oE '\b(Get|Set|New|Remove|Invoke|Test|Write|Unregister|Register|Stop|Start|Confirm|Show|Read)-[A-Za-z]+' "/tmp/ps-uninst-fn.$$" | sort -u)

# The kit's bare output helpers (OkStep, Warn2, ...) carry no Verb-Noun hyphen,
# so the pattern above never saw them -- and the first time the pwsh suite ran
# in CI it died on exactly one of those: `OkStep` had no stub. They live in
# exakit-common.ps1, which the test does not load, so each one the function
# calls has to be stubbed in the test.
while read -r call; do
    if grep -q "function $call\b" "$TEST"; then continue; fi
    printf 'FAIL %s (bare output helper) is not stubbed in uninstall-ps.ps1\n' "$call"
    fails=$((fails + 1))
done < <(grep -oE '(^|[{;(]|\|) *(Info|InfoStep|Ok|OkStep|Warn2|Fail|Heading)\b' "/tmp/ps-uninst-fn.$$" | grep -oE '[A-Za-z0-9]+$' | sort -u)
rm -f "/tmp/ps-uninst-fn.$$"

if [ "$fails" -eq 0 ]; then
    echo "ok   every helper Invoke-ExakitUninstallRun calls resolves in the test"
    exit 0
fi
printf '\n%d unresolved call(s) -- uninstall-ps.ps1 would die on the first one\n' "$fails"
exit 1
