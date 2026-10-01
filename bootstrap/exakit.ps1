# exakit.ps1 - the Windows launcher. Finds the kit and its Python, runs `python -m exakit`. Nothing else.
# The `exakit` command on PATH is a .cmd shim that runs this file with -ExecutionPolicy Bypass;
# setup\exakit.ps1 is a byte-identical copy so the 0.2.0 self-update installs this file.
param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments = @())

if (-not $env:EXAKIT_HOME) { $env:EXAKIT_HOME = Join-Path $HOME ".exasol-starter-kit" }
$here = Split-Path -Parent $PSCommandPath
$kitDir = Join-Path $env:EXAKIT_HOME "kit"
if (Test-Path (Join-Path (Split-Path -Parent $here) "exakit\__main__.py")) { $kitDir = Split-Path -Parent $here }
$env:EXAKIT_KIT_DIR = $kitDir

$json = ($Arguments -contains "--json" -or $Arguments -contains "-j")
if (-not (Test-Path (Join-Path $kitDir "exakit\__main__.py"))) {
    if ($json) {
        Write-Output ('{"installed": false, "status": "not installed", "manifest": "' + (Join-Path $env:EXAKIT_HOME "manifest.json").Replace("\", "\\") + '", "reason": "no kit copy", "remedy": "irm https://www.exasol.com/install/starter-kit.ps1 | iex"}')
    } else {
        Write-Host "exakit: no kit at $kitDir (run the installer first)"
    }
    exit 4
}
$first = if ($Arguments.Count -gt 0) { $Arguments[0] } else { "help" }
if ($first -in @("status", "info", "version", "help", "catalog", "whats-new", "skills", "logs", "mcp-status")) {
    $env:EXAKIT_READONLY_QUERY = "1"
}
. (Join-Path $kitDir "bootstrap\ensure-python.ps1")
$code = Confirm-ExakitPython
if ($code -ne 0) {
    if ($json) {
        Write-Output '{"installed": true, "status": "unknown", "remedy": "exakit update", "remedy_hint": "no Python runtime is available on this machine, so the kit cannot read its own install record; exakit update restores it"}'
    } else {
        Write-Host "exakit: the kit's Python is not set up yet - run: exakit update"
    }
    exit $code
}
$env:PYTHONPATH = if ($env:PYTHONPATH) { "$kitDir;$($env:PYTHONPATH)" } else { $kitDir }
& $env:EXAKIT_PYTHON -m exakit @Arguments
exit $LASTEXITCODE
