# json-tables.ps1 - JSON Tables (ingest, query and reshape JSON-shaped data in
# Exasol): Windows counterpart of json-tables.sh.
#
# A MARKETPLACE ADD-ON: never installed by the setup scripts.
#
# WHY THIS SIDE ONLY GATES, AND DOES NOT INSTALL
#
# The kit's whole point with this add-on is that nobody needs a Rust toolchain:
# .github/workflows/pkg-json-tables.yml builds the ingest engine for every
# platform (Windows included) and the wheel, and publishes both to the
# 'mirror-json-tables' release. On macOS and Linux the kit then puts a tiny
# 'cargo' shim in front of the CLI, because upstream runs the engine with
# exactly one call shape and no prebuilt-binary escape hatch:
#
#     subprocess.run(["cargo", "run", "--manifest-path", <crate>/Cargo.toml,
#                     "--", "--input", ...])          python/exasol_json_tables/cli.py
#
# That shim cannot work on Windows. subprocess.run with an argument list goes
# to CreateProcess, and CreateProcess resolves a bare name by appending .exe
# only - it never consults PATHEXT - so a cargo.cmd or cargo.bat placed on PATH
# is simply not found. A real .exe shim would have to be compiled, which is the
# toolchain requirement this add-on exists to remove. Shipping the crate source
# instead would put the Rust build back on the user.
#
# So on Windows the add-on reports itself not applicable, with that reason, and
# the marketplace does not offer it - the same treatment an Intel Mac gets in
# json-tables.sh for a platform with no published engine. Nothing is half
# installed and no one is handed a CLI that fails at the first ingest.
#
# WHAT UNBLOCKS WINDOWS
# Either upstream honouring a prebuilt engine (an env var, a PATH lookup, or
# --ingest-binary alongside the existing --cargo-manifest-path flag), or the
# kit publishing a compiled launcher .exe. When one of those lands, this file
# gains the Install/Update/Validate bodies its twin already has - the registry
# row below and the mirror workflow are already in place.

$script:JsonTablesVersionFallback = if ($env:EXAKIT_JSON_TABLES_VERSION_FALLBACK) { $env:EXAKIT_JSON_TABLES_VERSION_FALLBACK } else { "v0.2" }
$script:JsonTablesVersion = if ($env:EXAKIT_JSON_TABLES_VERSION) { $env:EXAKIT_JSON_TABLES_VERSION } else { "" }
$script:JsonTablesMirrorTag = if ($env:EXAKIT_JSON_TABLES_MIRROR_TAG) { $env:EXAKIT_JSON_TABLES_MIRROR_TAG } else { "mirror-json-tables" }

function Get-JsonTablesLogPath {
    return (Join-Path $script:LogDir "json-tables.log")
}

# Twin of json_tables_engine_asset in json-tables.sh: the workflow does build a
# Windows engine, so the name is defined here even though nothing consumes it
# yet - it is what the future install path downloads.
function Get-JsonTablesEngineAsset {
    if ([System.Environment]::Is64BitOperatingSystem) {
        return "exasol-json-tables-ingest-windows-x86_64.exe"
    }
    return ""
}

# Twin of json_tables_applicable. See the header: false on Windows, always,
# and for a reason the user can act on rather than a silent omission.
function Test-JsonTablesApplicable {
    return $false
}

function Get-JsonTablesApplicableReason {
    return "the ingest engine cannot be wired in on Windows yet - JSON Tables runs it through 'cargo run', and Windows resolves only .exe on PATH, so the kit's prebuilt engine is unreachable without a Rust toolchain. macOS and Linux are supported today."
}

# Nothing is ever installed here, so the probe answers honestly rather than
# guessing from a manifest record written by another machine.
function Get-JsonTablesInstalledVersion {
    return ""
}

function Install-JsonTables {
    Warn2 ("JSON Tables was not installed: " + (Get-JsonTablesApplicableReason))
    if (Get-Command Set-ExakitFailureReason -ErrorAction SilentlyContinue) {
        Set-ExakitFailureReason (Get-JsonTablesApplicableReason)
    }
    Set-ExakitManifestValue "components.json_tables.validated" "false"
    return $false
}

function Update-JsonTables {
    Warn2 ("JSON Tables is not available on Windows: " + (Get-JsonTablesApplicableReason))
    return $false
}

function Test-JsonTables {
    return $true
}

# Kept so `exakit uninstall` has a hook for every registered add-on: it clears
# a manifest record left by an older kit and is a no-op otherwise.
function Uninstall-JsonTables {
    param([switch]$DryRun)
    if ($DryRun) { return $true }
    Remove-ExakitManifestValue "components.json_tables"
    Remove-ExakitManifestValue "desired.json_tables"
    return $true
}
