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

if ! command -v pwsh >/dev/null 2>&1; then
    echo "skipped: pwsh is not installed - the PowerShell AST guard needs it"
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

OUT="$(pwsh -NoProfile -File "$SWEEP" -Root "$ROOT")"
printf '%s\n' "$OUT" | grep -v '^summary ' || true
SUMMARY="$(printf '%s\n' "$OUT" | grep '^summary ')"
echo "$SUMMARY"

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
