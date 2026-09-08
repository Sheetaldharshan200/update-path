#!/usr/bin/env bash
# Guard against calling a PowerShell function that does not exist.
#
# PowerShell resolves command names at call time, not at parse time, so a
# script that invokes Read-ExakitCredential parses clean, passes every
# brace-balance guard, and dies with CommandNotFoundException on the first
# Windows machine that reaches the line. That is exactly how the
# exasol-scheduler install shipped broken on Windows while CI stayed green:
# three call sites named functions defined nowhere in the repo.
#
# This suite parses every shipped .ps1 into its AST and checks each static
# Verb-Noun invocation against the set of functions defined anywhere in the
# repo plus the commands resolvable in this pwsh. Windows-only cmdlets that a
# Linux/macOS pwsh cannot see are allowlisted by name — the point is catching
# names that exist NOWHERE, not names that exist only on Windows.
#
#   bash tests/ps-undefined-functions.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# EXAKIT_PS_BIN picks the engine. `pwsh` (7) is the default because that is
# what a developer machine and the Linux runner have; the Windows runner sets
# it to `powershell`, i.e. real Windows PowerShell 5.1, where the Windows-only
# cmdlets below resolve for real instead of being taken on trust.
EXAKIT_PS_BIN="${EXAKIT_PS_BIN:-pwsh}"
if ! command -v "$EXAKIT_PS_BIN" >/dev/null 2>&1; then
    echo "skipped: $EXAKIT_PS_BIN is not installed - the PowerShell AST guard needs it"
    exit 0
fi

SWEEP="$(mktemp -t ps-sweep-XXXXXX).ps1"
trap 'rm -f "$SWEEP"' EXIT
cat > "$SWEEP" <<'PSEOF'
param([Parameter(Mandatory)][string]$Root)
$ErrorActionPreference = "Stop"

# Cmdlets that ship with Windows PowerShell (or Windows-only pwsh modules) and
# therefore do not resolve on the Linux/macOS pwsh running this guard. Each
# entry must be a name that genuinely exists on Windows - never add one to
# silence a finding without checking that first.
$windowsOnly = @(
    "Get-CimInstance", "Get-NetTCPConnection", "Set-Acl", "Get-Acl",
    "Get-ItemProperty", "Set-ItemProperty", "New-ItemProperty"
)

# On Windows the allowlist is not needed, so it becomes a check instead: every
# name on it must really resolve here. An entry that does not is either a typo
# or a cmdlet that no longer exists, and on the Linux runner it would sit there
# silencing a real finding forever.
if ($IsWindows -or $env:OS -eq "Windows_NT") {
    $stale = @($windowsOnly | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($stale.Count -gt 0) {
        Write-Output "STALE-ALLOWLIST $($stale -join ', ')"
        exit 1
    }
    $windowsOnly = @()
}

$files = @(Get-ChildItem (Join-Path $Root "setup") -Recurse -Filter *.ps1)
$files += Get-ChildItem $Root -Filter *.ps1

$defined = @()
$parseFailures = 0
foreach ($f in $files) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors) {
        Write-Output "PARSE $($f.FullName.Substring($Root.Length + 1)): $($errors[0].Message)"
        $parseFailures++
        continue
    }
    $defined += $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        ForEach-Object Name
}
$defined = $defined | Sort-Object -Unique

$undefined = 0
foreach ($f in $files) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors) { continue }
    $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($call in $calls) {
        $name = $call.GetCommandName()
        if (-not $name) { continue }                        # dynamic: & $var
        if ($name -notmatch '^[A-Z][A-Za-z0-9]*-[A-Z]') { continue }  # externals: python, uv, taskkill.exe
        if ($defined -contains $name) { continue }
        if ($windowsOnly -contains $name) { continue }
        if (Get-Command $name -ErrorAction SilentlyContinue) { continue }
        $rel = $f.FullName.Substring($Root.Length + 1)
        Write-Output "UNDEFINED $rel`:$($call.Extent.StartLineNumber): $name"
        $undefined++
    }
}
Write-Output "summary files=$($files.Count) defined=$($defined.Count) parse_failures=$parseFailures undefined=$undefined"
PSEOF

OUT="$("$EXAKIT_PS_BIN" -NoProfile -File "$SWEEP" -Root "$ROOT")"
printf '%s\n' "$OUT" | grep -v '^summary ' || true
SUMMARY="$(printf '%s\n' "$OUT" | grep '^summary ' || true)"
[ -n "$SUMMARY" ] && echo "$SUMMARY"

# The allowlist self-check runs before the sweep and exits early, so it leaves
# no summary line. Say what actually went wrong instead of blaming the sweep.
case "$OUT" in
    *STALE-ALLOWLIST*)
        echo "FAIL the Windows-only allowlist names a cmdlet that does not resolve on this Windows machine"
        echo "     Remove it: on the Linux runner that entry silences every call to that name."
        exit 1
        ;;
esac

case "$SUMMARY" in
    *"parse_failures=0 undefined=0")
        echo "ok   every static Verb-Noun call resolves to a function that exists"
        exit 0
        ;;
    *)
        echo "FAIL a shipped .ps1 calls a function that exists nowhere (or fails to parse)"
        exit 1
        ;;
esac
