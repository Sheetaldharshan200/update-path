# exapump.ps1 - exapump installation, connection, and guided data-loading
# module (Windows / PowerShell path).
#
# Dot-sourced by setup-windows-docker.ps1 and setup/exakit.ps1 after
# exakit-common.ps1. Mirrors setup/lib/exapump.sh function-for-function.
#
# exapump facts:
#   - release assets: exapump-<ver>-{macos,linux}-{aarch64,x86_64},
#     exapump-<ver>-windows-x86_64.exe (no Windows ARM64 build published)
#   - profiles: %USERPROFILE%\.exapump\config.toml (TOML, one section/profile)
#   - SQL from a file: exapump sql -p <profile> < file.sql
#   - CSV/Parquet load: exapump upload <file> --table <schema.table>

$script:ExapumpProfile = if ($env:EXAKIT_EXAPUMP_PROFILE) { $env:EXAKIT_EXAPUMP_PROFILE } else { "starter-kit" }
$script:ExapumpBinPath = Join-Path $script:BinDir "exapump.exe"
$script:ExapumpConfigPath = Join-Path $HOME ".exapump\config.toml"

# Test-ExapumpSucceeded - decide whether an exapump invocation succeeded.
#
# The Windows exapump.exe build can return a NON-ZERO exit code even when the
# statement executed successfully (observed: `SELECT 1` returns "[1/1]
# SELECT 1 1 rows" and exits non-zero), so exit code alone is not a reliable
# success signal on Windows. macOS/Linux exapump exits 0 on success, so exit
# code 0 is still trusted as the fast path; a non-zero exit is only treated
# as failure when the *output* actually looks like an error. This keeps
# behavior identical where exit codes are reliable and recovers correctly
# where they are not, while still catching genuine failures (auth, refused
# connection, syntax errors) which always print error text.
function Test-ExapumpSucceeded {
    param([int]$ExitCode, [AllowEmptyString()][string]$Output)
    $text = "$Output"
    # exapump prints an authoritative per-run summary: "<n> statement(s)
    # executed, <m> failed". Trust it FIRST - the exit code is unreliable on
    # Windows (non-zero even on success), and that summary line itself contains
    # the word "failed" ("0 failed"), which the generic error scan below would
    # otherwise treat as a failure. m == 0 means every statement succeeded.
    if ($text -match '(?im)(\d+)\s+statements?\s+executed,\s*(\d+)\s+failed') {
        return ([int]$Matches[2] -eq 0)
    }
    if ($ExitCode -eq 0) { return $true }
    if ($text -match '(?im)\b(error|exception|failed|failure|denied|refused|unable|cannot|could not|not found|no such|timeout|timed out|syntax error|invalid|unauthorized|authentication)\b') {
        return $false
    }
    if ($text -match '\[\d+/\d+\]' -or $text -match '(?im)\b\d+\s+rows?\b') {
        return $true
    }
    return $false
}

# Write-ExapumpOutput - print captured exapump output indented under a header,
# skipping empty output. Centralizes the "yellow header + indented lines" block
# that several loaders used to inline so the presentation stays consistent.
function Write-ExapumpOutput {
    param([AllowEmptyString()][string]$Output, [string]$Header = "exapump output:")
    if (-not "$Output".Trim()) { return }
    # Tool output: warn-style header on the gutter, lines in the dim | gutter
    # (same contained shape the verify step uses).
    Write-Host "      ! $Header" -ForegroundColor Yellow
    "$Output".Trim() -split "`n" | ForEach-Object {
        if ($script:UiFancy) { Write-Host ("      {0}{1} {2}{3}" -f $script:UiDim, $script:UiVB, $_, $script:UiReset) }
        else { Write-Host ("      | {0}" -f $_) }
    }
}

# Invoke-Exapump - run one exapump invocation, capturing combined output and
# the (unreliable-on-Windows) exit code, and return a structured result whose
# .Success is computed by Test-ExapumpSucceeded. Every exapump call site goes
# through this so success detection is consistent and the exit-code quirk is
# handled in exactly one place.
#
# Arguments are passed as an explicit array (NOT ValueFromRemainingArguments):
# exapump's own flags include "-p", which PowerShell's parameter binder would
# otherwise try to resolve against this function's common parameters
# (-ProgressAction / -PipelineVariable) and fail with an "ambiguous parameter"
# error before the args ever reach exapump.
function Invoke-Exapump {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $out = ""
    $code = 1
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # exapump writes its progress/summary lines to stderr on Windows. Under
        # the module-global $ErrorActionPreference = 'Stop', 2>&1 turns that very
        # first stderr write into a terminating error, so the catch below would
        # capture ONLY that first line and discard the actual result grid and the
        # "N statements executed" summary. That silently broke every caller that
        # reads query results back (the DDL-readiness probe, Test-ExapumpSchemaPresent,
        # row counts) - they saw a truncated output and concluded the schema was
        # missing / the database was not ready, spinning or failing on a database
        # that was in fact fine. Switch to 'Continue' for the native call so the
        # whole output is captured, exactly as Invoke-ExapumpAdminSql already does.
        $ErrorActionPreference = "Continue"
        $out = & (Get-ExapumpCli) @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    } catch {
        $out = "$_"
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($script:LogFile) { "exapump $($Arguments -join ' ')" | Add-Content -Path $script:LogFile; $out | Add-Content -Path $script:LogFile }
    return @{ Output = $out; ExitCode = $code; Success = (Test-ExapumpSucceeded -ExitCode $code -Output $out) }
}

function Get-ExapumpAssetName {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        "AMD64" { return "exapump-$($script:ExapumpVersion)-windows-x86_64.exe" }
        default { return $null }  # no Windows ARM64 build published
    }
}

# Get-ExapumpExpectedSha256 <asset> - the digest the download is verified
# against:
#
#   1. versions.json, but ONLY when the version being installed is the advertised
#      one. An env override must never borrow another release's digest - that
#      would either fail confusingly or, worse, match the wrong artifact.
#   2. the digest of the release shipped with this kit (below).
#   3. the release API for the version in question.
#
# $null means "no digest available"; the caller decides what to do with that (it
# refuses to install unless explicitly overridden).
# Twin of exapump_expected_sha256 in exapump.sh.
function Get-ExapumpExpectedSha256 {
    param([Parameter(Mandatory)][string]$AssetName)
    $advertised = Get-ExakitVersionsValue -Path "components.exapump.version"
    if ($advertised -and $advertised -eq $script:ExapumpVersion) {
        # The asset name is exapump-<version>-<os>-<arch>.exe, and versions.json
        # keys its digests by that same <os>-<arch> token.
        $platform = $AssetName
        $prefix = "exapump-$($script:ExapumpVersion)-"
        if ($platform.StartsWith($prefix)) { $platform = $platform.Substring($prefix.Length) }
        if ($platform.EndsWith(".exe")) { $platform = $platform.Substring(0, $platform.Length - 4) }
        $digest = Get-ExakitVersionsValue -Path "components.exapump.sha256.$platform"
        if ($digest -and $digest -match '^[0-9a-f]{64}$') { return $digest }
    }
    $digest = Get-ExapumpPinnedSha256 $AssetName
    if ($digest) { return $digest }
    return (Get-ExapumpDigestFromApi $AssetName)
}

# Digest of the pinned release (published by the release API). When the
# version is overridden the digest is fetched from the API instead.
function Get-ExapumpPinnedSha256 {
    param([Parameter(Mandatory)][string]$AssetName)
    switch ($AssetName) {
        "exapump-0.11.2-windows-x86_64.exe" { return "8a2e8199a94f1b21782e4c68179948bfa43217c82c9b9b2a25eaec4532305237" }
        default { return $null }
    }
}

function Get-ExapumpDigestFromApi {
    param([Parameter(Mandatory)][string]$AssetName)
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$($script:ExapumpRepo)/releases/tags/v$($script:ExapumpVersion)" -UseBasicParsing
    } catch {
        return $null
    }
    $asset = $release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
    if (-not $asset -or -not $asset.digest) { return $null }
    if ($asset.digest -notlike "sha256:*") { return $null }
    return $asset.digest.Substring(7)
}

function Get-ExapumpCli {
    $cmd = Get-Command exapump -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $script:ExapumpBinPath
}

function Install-Exapump {
    $exiT0 = Get-Date
    $asset = Get-ExapumpAssetName
    if (-not $asset) {
        Fail "Unsupported CPU architecture: $($env:PROCESSOR_ARCHITECTURE). exapump publishes a Windows build for x86_64 only."
    }

    $existing = Get-ExapumpCli
    if (Test-Path $existing) {
        # Trust the existing binary only if it actually runs - an interrupted
        # earlier download can leave a broken file at the same path. Wrapped:
        # a broken binary's stderr write must mean "reinstall", not an
        # uncaught exception under $ErrorActionPreference = 'Stop'.
        $existingWorks = $false
        $previousEAP = $ErrorActionPreference
        try {
            # Continue (not the global Stop) so a working binary that writes an
            # incidental line to stderr isn't turned into a terminating error on
            # Windows PowerShell 5.1 and needlessly reinstalled - the exit code
            # is the real signal. Same fix as Get-NanoEngine / Invoke-ExakitLogged.
            $ErrorActionPreference = "Continue"
            & $existing --version *> $null
            $existingWorks = ($LASTEXITCODE -eq 0)
        } catch { } finally {
            $ErrorActionPreference = $previousEAP
        }
        if ($existingWorks) {
            Ok "exapump already installed: $existing"
            Set-ExapumpManifest
            return
        }
        Warn2 "Existing exapump binary does not run (interrupted download?) - reinstalling"
        Remove-Item -Force $existing -ErrorAction SilentlyContinue
    }

    $url = "https://github.com/$($script:ExapumpRepo)/releases/download/v$($script:ExapumpVersion)/$asset"
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-exapump-$([guid]::NewGuid().ToString('N')).exe"

    # Named per phase so the one animated line says what is happening now. The
    # checksum has no phase of its own: it is sub-second on a 20 MB binary, and
    # its own tick is gone - it named a temp path, never the asset. The
    # verification itself is untouched.
    $script:ExakitActiveLabel = "Downloading exapump v$($script:ExapumpVersion)"
    Info "Downloading exapump v$($script:ExapumpVersion) ($asset)"
    Get-ExakitFile -Url $url -Dest $tmp

    $expected = Get-ExapumpExpectedSha256 $asset
    if ($expected) {
        Test-ExakitSha256 -Path $tmp -Expected $expected
    } elseif ($env:EXAKIT_ALLOW_UNVERIFIED_EXAPUMP -eq "1") {
        Warn2 "No digest available for $asset - proceeding WITHOUT checksum verification (EXAKIT_ALLOW_UNVERIFIED_EXAPUMP=1)."
    } else {
        # Match the launcher's bar (and the bash twin in exapump.sh): never
        # install a downloaded-and-executed binary we could not verify. For an
        # advertised version the digest comes from versions.json, and for the
        # shipped one from the pinned table, so this only fires on a version this
        # kit knows nothing about plus an unreachable release API.
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
        Fail "No checksum available for $asset; refusing to install an unverified exapump binary. Add its digest to versions.json (components.exapump.sha256) or check network access to the release API. Override at your own risk with EXAKIT_ALLOW_UNVERIFIED_EXAPUMP=1."
    }

    New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
    Move-Item -Force $tmp $script:ExapumpBinPath
    Confirm-ExakitOnPath $script:BinDir
    OkStep "exapump v$($script:ExapumpVersion) installed to $(Get-ExakitTilde $script:ExapumpBinPath) ($([int]((Get-Date) - $exiT0).TotalSeconds)s)"
    Set-ExapumpManifest
}

function Set-ExapumpManifest {
    Set-ExakitManifestValue "components.exapump.version" $script:ExapumpVersion
    Set-ExakitManifestValue "components.exapump.path" (Get-ExapumpCli)
}

# Confirm-ExapumpInstalledVersion - ask the binary what it is, now that this run has
# installed one, and make the record agree with the answer. Set-ExapumpManifest
# writes the version the run INTENDED to install; only the binary can say what is
# actually there. Returns $false when they disagree, so the caller does not announce
# a move that did not happen.
#
# Silence is left alone deliberately: Get-ExakitComponentCurrent answers nothing only
# when there is no binary at all, and a correction invented from silence would be
# worse than the record. That reader lives in setup/exakit.ps1, which the installer
# entry point. That skip is gone: Get-ExakitComponentCurrent is in the shared
# layer now, so the confirmation runs during an install too - which is where a
# version that does not match what was just installed is most worth hearing
# about.
# Twin of exapump_confirm_installed_version in setup/lib/exapump.sh.
function Confirm-ExapumpInstalledVersion {
    $live = Get-ExakitComponentCurrent "exapump"
    if (-not $live) { return $true }
    if ($live -eq $script:ExapumpVersion) { return $true }
    Warn2 "The exapump on disk reports $live, not the $($script:ExapumpVersion) this update installed - recording what is there"
    Set-ExakitManifestValue "components.exapump.version" $live
    return $false
}

# New-ExapumpProfile - write the kit's connection profile from the manifest.
# Managed section, safe to re-run; other profiles in the same file untouched.
function New-ExapumpProfile {
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    if (-not $dsn) { Fail "No runtime DSN in the manifest - install the database first." }
    $host_, $port = $dsn -split ":", 2
    $user = Get-ExakitManifestValue "runtime.user"
    if (-not $user) { $user = "sys" }

    $pwFile = Get-ExakitManifestValue "runtime.password_file"
    $password = ""
    if ($pwFile -and (Test-Path $pwFile)) {
        $password = (Get-Content $pwFile -Raw).TrimEnd("`r", "`n")
    }
    if (-not $password) {
        $password = Read-ExakitPrompt "Database password for user $user (leave blank to skip profile creation)" ""
    }
    if (-not $password) {
        Warn2 "No database password available - create the profile manually with: exapump profile init $($script:ExapumpProfile)"
        return
    }

    # If the runtime password wasn't already on file (mirrors exapump.sh: an
    # adopted deployment with unreadable secrets, so the password came from the
    # prompt above), remember it so Test-ExapumpConnection can persist it AFTER
    # confirming it works. The MCP step needs runtime.password_file, but saving
    # a mistyped password before validation would make the next run reuse it
    # instead of re-prompting.
    if (-not $pwFile -or -not (Test-Path $pwFile)) {
        $script:PendingRuntimePassword = $password
    }

    New-Item -ItemType Directory -Force -Path (Split-Path $script:ExapumpConfigPath -Parent) | Out-Null
    Set-ExapumpTomlSection -ConfigPath $script:ExapumpConfigPath -Profile $script:ExapumpProfile -Host_ $host_ -Port $port -User $user -Password $password
    Protect-ExakitFile $script:ExapumpConfigPath
    Set-ExakitManifestValue "components.exapump.profile" $script:ExapumpProfile
    OkStep "Connection profile [$($script:ExapumpProfile)] written to $(Get-ExakitTilde $script:ExapumpConfigPath)"
}

function Format-TomlString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $escaped = $Value.Replace("\", "\\").Replace('"', '\"')
    return "`"$escaped`""
}

# Set-ExapumpTomlSection - replace/append a [profile] section in a TOML file,
# preserving every other section. Atomic write (temp file + rename) so an
# interrupted run never truncates a config that may hold other profiles.
function Set-ExapumpTomlSection {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$Host_,
        [Parameter(Mandatory)][string]$Port,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Password,
        [string]$Schema = ""
    )
    $content = ""
    if (Test-Path $ConfigPath) { $content = Get-Content $ConfigPath -Raw }
    if (-not $content) { $content = "" }

    $lines = @(
        "[$Profile]",
        "host = $(Format-TomlString $Host_)",
        "port = $Port",
        "user = $(Format-TomlString $User)",
        "password = $(Format-TomlString $Password)"
    )
    if ($Schema) { $lines += "schema = $(Format-TomlString $Schema)" }
    $lines += "tls = true"
    $lines += "validate_certificate = false"
    $section = ($lines -join "`n") + "`n"

    $escapedProfile = [regex]::Escape($Profile)
    $pattern = "(?s)\[$escapedProfile\][^\[]*"
    if ($content -match $pattern) {
        $content = [regex]::Replace($content, $pattern, ($section + "`n"))
        $content = $content.TrimEnd("`n") + "`n"
    } else {
        if ($content -and -not $content.EndsWith("`n`n")) {
            $content = $content.TrimEnd("`n") + "`n`n"
        }
        $content += $section
    }

    $tmp = "$ConfigPath.tmp"
    Set-Content -Path $tmp -Value $content -NoNewline
    Move-Item -Force $tmp $ConfigPath
}

# Test-ExapumpDdlRoundtrip - one DDL write-readback round through the profile.
# Returns $true ONLY if a freshly created schema+table is durably persisted and
# visible from SUBSEQUENT connections (each exapump invocation reconnects).
#
# This is the real readiness signal. Right after first boot the Nano database
# accepts a connection and answers SELECT 1 while still stabilizing, and in that
# window it can ACKNOWLEDGE a DDL batch ("N statements executed, 0 failed")
# without durably persisting it - so the schema-creation step "succeeds" but the
# very next `exapump upload` fails with "schema STARTER_KIT not found". The probe
# reproduces exactly that sequence (create schema in one connection, reference it
# from the next) so we only proceed once the database really is ready.
function Test-ExapumpDdlRoundtrip {
    $probe = "EXAKIT_READY_PROBE"
    # Best-effort clean slate - a probe schema left by an interrupted earlier
    # attempt must not make this one look like a success. Result ignored.
    Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "DROP SCHEMA IF EXISTS $probe CASCADE") | Out-Null
    if (-not (Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "CREATE SCHEMA $probe")).Success) { return $false }
    # A NEW connection must see the just-created schema (this is the exact
    # cross-connection visibility that failed during install) and persist a table.
    $tableOk = (Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "CREATE TABLE $probe.READY_PROBE (n DECIMAL(9,0))")).Success `
        -and (Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "INSERT INTO $probe.READY_PROBE VALUES (42)")).Success
    $readBack = $false
    if ($tableOk) {
        # Confirm from yet another fresh connection that the row is durably
        # visible. Judge this on exapump's OWN signals - statement success plus
        # its "<n> rows" progress line - NOT by scraping the rendered result grid
        # for a data token. When exapump's stdout is a pipe (as it is here, and
        # as every install runs it) it omits the result grid and the "N
        # statements executed" summary entirely, so a token like EXAKIT_DDL[42]
        # never appears in the captured output. Keying the probe on that token
        # made it spin until EXAKIT_DDL_READY_TIMEOUT and fail the install even
        # though every statement had succeeded and the database was fully ready.
        # A missing schema/table instead makes the SELECT error (Success=false)
        # and a lost row makes it return "0 rows", so both real failures are
        # still caught.
        $read = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "SELECT n FROM $probe.READY_PROBE WHERE n = 42")
        $readBack = ($read.Success -and "$($read.Output)" -match '(?im)\b1\s+rows?\b')
    }
    Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "DROP SCHEMA IF EXISTS $probe CASCADE") | Out-Null
    return $readBack
}

# Confirm-ExapumpDatabaseReady - block until the database can durably persist a
# schema, not merely answer SELECT 1. Polls Test-ExapumpDdlRoundtrip with a
# bounded budget (EXAKIT_DDL_READY_TIMEOUT, default 180s) so the sample-data and
# MCP steps that follow can trust that CREATE SCHEMA/TABLE will stick.
function Confirm-ExapumpDatabaseReady {
    $timeout = if ($env:EXAKIT_DDL_READY_TIMEOUT) { [int]$env:EXAKIT_DDL_READY_TIMEOUT } else { 180 }
    Info "Confirming the database can persist schema changes"
    # Announced by the caller, not here: answering SELECT 1 and persisting a
    # schema are one fact to the reader - the database is ready - and two ticks
    # for it read as two things to keep track of. This one stays in the logfile;
    # Test-ExapumpConnection prints the merged line.
    # Twin of exapump_confirm_database_ready (exapump.sh).
    Start-ExakitSpinner "Confirming the database can persist schema changes"
    $waited = 0
    while ($true) {
        if (Test-ExapumpDdlRoundtrip) {
            Stop-ExakitSpinner
            if ($waited -eq 0) { Ok "Database is ready for schema changes" }
            else { Ok "Database is ready for schema changes (after ~${waited}s)" }
            return
        }
        if ($waited -ge $timeout) { break }
        Start-Sleep -Seconds 5
        $waited += 5
        if ($waited % 30 -eq 0) {
            # Only where the spinner is not already counting - a line printed
            # under a live animator is erased by its next frame.
            if ($script:UiFancy) { Write-ExakitLog "INFO" "Database still stabilizing... (${waited}s)" }
            else { Info "Database still stabilizing... (${waited}s)" }
        }
    }
    Stop-ExakitSpinner
    Fail "The database accepts connections but could not durably persist a schema within ${timeout}s (first-boot stabilization window). Wait a moment, then retry: exakit data-load"
}

# Test-ExapumpConnection - validate the profile with SELECT 1, then confirm the
# database can durably persist DDL (Confirm-ExapumpDatabaseReady) before any
# caller relies on CREATE SCHEMA sticking.
function Test-ExapumpConnection {
    if (-not (Get-ExakitManifestValue "components.exapump.profile")) {
        Fail "No connection profile exists (no database password was available to write one). Create it manually with 'exapump profile init $($script:ExapumpProfile)', then re-run this script."
    }
    Info "Validating the database connection (SELECT 1)"
    $evcT0 = Get-Date
    $script:ExakitActiveLabel = "Validating the database connection"
    $connected = $false
    $lastOutput = ""
    for ($tries = 0; $tries -lt 6; $tries++) {
        $result = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "SELECT 1")
        $lastOutput = $result.Output
        if ($result.Success) { $connected = $true; break }
        Start-Sleep -Seconds 5
    }
    if (-not $connected) {
        # Surface the actual error inline instead of only in the log file - the
        # exapump/database error text (auth failure vs. connection refused vs.
        # TLS handshake error) is exactly what's needed to diagnose this, and
        # making someone go dig through a log file for it is not production-grade.
        Write-ExapumpOutput -Output $lastOutput -Header "Last attempt's output:"
        Fail "SELECT 1 failed via profile '$($script:ExapumpProfile)' after 6 attempts. Try: exapump sql -p $($script:ExapumpProfile) 'SELECT 1'"
    }
    Ok "Connection works"

    # A working connection is NOT proof the database can persist schema changes
    # yet - see Test-ExapumpDdlRoundtrip. Gate here so both the data-load and MCP
    # steps that follow run against a database that is genuinely ready.
    Confirm-ExapumpDatabaseReady

    # One line for both checks. Reaching here means SELECT 1 answered AND a
    # schema round-tripped durably; either failing fails with its own message.
    OkStep "Database ready - connection and schema changes verified ($([int]((Get-Date) - $evcT0).TotalSeconds)s)"

    Set-ExakitManifestValue "components.exapump.validated" $true
    # Now that the password is proven to work, persist it as the runtime
    # password if the runtime step could not (adopted deployment with
    # unreadable secrets) - the MCP step needs runtime.password_file.
    if ($script:PendingRuntimePassword) {
        Set-ExakitCredential "runtime_sys_password" $script:PendingRuntimePassword
        Set-ExakitManifestValue "runtime.password_file" (Join-Path $script:CredsDir "runtime_sys_password")
        $script:PendingRuntimePassword = $null
    }
}

# Invoke-ExapumpSqlFile <file> [description] - execute a SQL file, logged.
# Returns $true/$false instead of dying so callers (Invoke-ExakitSampleDataLoad)
# can decide whether a missing/empty file is fatal.
# Invoke-ExapumpSqlFileCapture <file> - feed a SQL file to exapump's stdin and
# return a structured result ({ Output; ExitCode; Success }) matching
# Invoke-Exapump's shape, logging the invocation. Shared by
# Invoke-ExapumpSqlFile (needs only pass/fail) and the sample-data verification
# step (also scans output for FAIL rows), so the stdin feed + quirk-aware
# success detection lives in one place.
#
# The file's RAW BYTES are handed to exapump via System.Diagnostics.Process,
# NOT a PowerShell pipeline (Get-Content -Raw | exapump 2>&1). Two independent
# Windows PowerShell 5.1 behaviors made the pipeline form silently destroy the
# sample-data load:
#   1. Under the module-global $ErrorActionPreference = 'Stop', 2>&1 turned
#      exapump's first stderr progress line into a terminating error that tore
#      the pipeline down - killing exapump at statement 1 of the batch - while
#      the lone captured "[1/10] ..." line satisfied Test-ExapumpSucceeded's
#      [n/m] marker, so schema creation reported "done" without CREATE SCHEMA
#      ever running.
#   2. Under the system-wide UTF-8 codepage (65001), a UTF-8 BOM gets
#      prepended to whatever reaches exapump's stdin, and Exasol rejects the
#      batch's first statement: "'<U+FEFF>' character is not allowed within
#      unquoted identifier". PowerShell's own pipe writer adds one (even with
#      $OutputEncoding set to ASCII or BOM-less UTF-8), and on .NET Framework
#      Process.StandardInput adds another: merely accessing that property
#      builds a StreamWriter over Console.InputEncoding (BOM-emitting UTF-8
#      under CP 65001) with AutoFlush = $true, whose setter flushes the
#      encoder preamble into the pipe before any payload byte. Verified: with
#      Console.InputEncoding left alone the probe payload arrives as
#      EF BB BF + bytes on 5.1; with a BOM-less UTF-8 InputEncoding it
#      arrives byte-exact (and PowerShell 7 is byte-exact either way).
# Raw-byte stdin bypasses every re-encoding layer, and keeping exapump's
# stderr out of PowerShell's error stream sidesteps the 'Stop' teardown too.
# stdout/stderr reads start BEFORE stdin is written to avoid the classic
# full-pipe deadlock.
function Invoke-ExapumpSqlFileCapture {
    param([Parameter(Mandatory)][string]$Path)
    $out = ""
    $code = 1
    $previousInputEncoding = $null
    try {
        # Best-effort (throws when the process has no console): see BOM note
        # above. Restored in finally.
        try {
            $previousInputEncoding = [Console]::InputEncoding
            [Console]::InputEncoding = New-Object System.Text.UTF8Encoding $false
        } catch { $previousInputEncoding = $null }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Get-ExapumpCli
        $psi.Arguments = "sql -p `"$($script:ExapumpProfile)`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $proc.StandardInput.Close()
        $proc.WaitForExit()
        $out = $stdoutTask.Result + $stderrTask.Result
        $code = $proc.ExitCode
    } catch {
        $out = "$_"
    } finally {
        if ($previousInputEncoding) {
            try { [Console]::InputEncoding = $previousInputEncoding } catch { }
        }
    }
    if ($script:LogFile) { "exapump sql -p $($script:ExapumpProfile) < $Path" | Add-Content -Path $script:LogFile; $out | Add-Content -Path $script:LogFile }
    return @{ Output = $out; ExitCode = $code; Success = (Test-ExapumpSucceeded -ExitCode $code -Output $out) }
}

function Invoke-ExapumpSqlFile {
    param([Parameter(Mandatory)][string]$Path, [string]$Description = "")
    if (-not $Description) { $Description = Split-Path $Path -Leaf }
    if (-not (Test-Path $Path) -or (Get-Item $Path).Length -eq 0) {
        Warn2 "SQL file missing or empty: $Path"
        return $false
    }
    # ExakitUploadQuiet covers this the same way it covers Invoke-ExapumpUpload:
    # a caller narrating a whole job on one line does not want "Running x" / "x
    # done" for each of its scripts underneath. The failure path is never quiet.
    if (-not $script:ExakitUploadQuiet) { Info "Running $Description" }
    $result = Invoke-ExapumpSqlFileCapture $Path
    if (-not $result.Success) {
        Write-ExapumpOutput -Output $result.Output
        # Translate the common faults into their remedy before dying, so
        # "Connection refused" arrives WITH "exakit start" instead of leaving the
        # reader to map one to the other.
        Show-ExakitDbErrorRemedy $result.Output
        Fail "SQL file failed: $Path (see log)"
    }
    if (-not $script:ExakitUploadQuiet) { Ok "$Description done" }
    return $true
}

# Invoke-ExapumpUpload <file> <schema.table> - load a CSV/Parquet file, logged.
# $script:ExakitUploadQuiet - twin of EXAKIT_UPLOAD_QUIET in exapump.sh.
# `exakit data-load` narrates the whole job with a single "Loading your data"
# spinner, so per-file chatter is noise there. The installer leaves it false
# and keeps its step-by-step narration.
$script:ExakitUploadQuiet = $false

function Invoke-ExapumpUpload {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Target, [switch]$Soft)
    if (-not (Test-Path $Path) -or (Get-Item $Path).Length -eq 0) {
        Warn2 "Data file missing or empty: $Path"
        return $false
    }
    if (-not $script:ExakitUploadQuiet) { Info "Loading $(Split-Path $Path -Leaf) into $Target" }
    $result = Invoke-Exapump @("upload", $Path, "--table", $Target, "-p", $script:ExapumpProfile)
    if (-not $result.Success) {
        Write-ExapumpOutput -Output $result.Output
        Show-ExakitDbErrorRemedy $result.Output
        # -Soft: a bulk folder load must not lose the other thirty-nine files to
        # one bad one. Fail() exits the whole PROCESS here - PowerShell has no
        # subshell to contain it, which is how the bash twin keeps this soft - so
        # a caller that means to carry on asks for a return value instead.
        if ($Soft) { return $false }
        Fail "Upload failed: $Path -> $Target (see log)"
    }
    if (-not $script:ExakitUploadQuiet) { Ok "$(Split-Path $Path -Leaf) loaded" }
    return $true
}

# Get-ExakitUploadParallel - how many uploads may run at once.
#
# WHY UPLOADS RUN CONCURRENTLY AT ALL: an exapump call is a process launch, and
# on a fresh Windows install each one measured ~4.4s against 185ms once warm.
# A dataset load is dominated by that, not by row throughput - weather (10,970
# rows) took as long as energy (108,050) because both made the same number of
# launches. The uploads cannot be merged into one call: exapump upload takes
# many FILES but only one --table, and IMPORT ... FROM LOCAL CSV FILE is
# refused by the server over this protocol ("only supported via JDBC or
# EXAplus"). So the launches have to overlap instead.
#
# Verified against the nano container before building this: four concurrent
# exapump sessions all succeeded, 302ms against 723ms for the same four run
# one after another.
#
# EXAKIT_UPLOAD_PARALLEL=1 restores exactly the old serial behaviour, and is
# the escape hatch if a database ever objects to the concurrency.
function Get-ExakitUploadParallel {
    $n = 4
    if ($env:EXAKIT_UPLOAD_PARALLEL) {
        $parsed = 0
        if ([int]::TryParse($env:EXAKIT_UPLOAD_PARALLEL, [ref]$parsed)) { $n = $parsed }
    }
    if ($n -lt 1) { $n = 1 }
    if ($n -gt 8) { $n = 8 }
    return $n
}

# ConvertTo-ExapumpArgumentLine - quote an argument vector into the single
# string ProcessStartInfo.Arguments expects.
#
# ProcessStartInfo.ArgumentList, which would do this properly, is .NET Core
# only - PowerShell 5.1 runs on .NET Framework, where Arguments is one string.
# Every argument is quoted unconditionally rather than only those containing a
# space, so there is no rule to get wrong; backslashes immediately before the
# closing quote are doubled, or they would escape it.
function ConvertTo-ExapumpArgumentLine {
    param([Parameter(Mandatory)][string[]]$Argv)
    $quoted = @()
    foreach ($a in $Argv) {
        $v = "$a"
        $v = [regex]::Replace($v, '(\\+)$', '$1$1')
        $v = $v.Replace('"', '\"')
        $quoted += ('"' + $v + '"')
    }
    return ($quoted -join " ")
}

# Collected by Invoke-ExapumpUploadMany. A script-scoped list rather than a
# return value on purpose: PowerShell unrolls collections into the pipeline,
# and this function is called inside a spinner body whose output the caller
# discards, so a returned list would be lost or flattened without warning.
$script:ExakitUploadFailures = @()

# Invoke-ExapumpUploadMany - upload several files CONCURRENTLY, one exapump
# process each, at most Get-ExakitUploadParallel at a time.
#
# Every file still gets its own launch, its own log lines and its own entry in
# the progress bar; what changes is that up to four of them are in flight at
# once. The bar advances as each finishes, so it names the file that JUST
# COMPLETED rather than the one being started - with several running there is
# no single "current" file to name.
#
# Failures are collected, not thrown: with several processes in flight, dying
# on the first would leave the others running and unreaped. The caller decides
# what to do once every process has been waited for.
function Invoke-ExapumpUploadMany {
    param(
        [Parameter(Mandatory)][object[]]$Files,
        [Parameter(Mandatory)][string]$Id
    )
    $script:ExakitUploadFailures = @()
    $cli = Get-ExapumpCli
    $cap = Get-ExakitUploadParallel
    $queue = New-Object System.Collections.Queue
    foreach ($f in $Files) { [void]$queue.Enqueue($f) }
    $running = New-Object 'System.Collections.Generic.List[object]'
    $done = 0
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($queue.Count -gt 0 -and $running.Count -lt $cap) {
            $f = $queue.Dequeue()
            if (-not (Test-Path $f.Path) -or (Get-Item $f.Path).Length -eq 0) {
                Warn2 "Data file missing or empty: $($f.Path)"
                $script:ExakitUploadFailures += "$($f.Path) (missing or empty)"
                $done++
                continue
            }
            # NOT Start-Process: it does not retain the process handle, so
            # .ExitCode comes back EMPTY even after HasExited and WaitForExit().
            # Measured here - a deliberately failing exapump call reported an
            # empty exit code, which Test-ExapumpSucceeded would then have had
            # to judge on output alone. System.Diagnostics.Process reports it
            # properly (the same failing call gives 2).
            #
            # Both streams are drained with ReadToEndAsync BEFORE waiting: a
            # redirected pipe that nobody reads fills up and blocks the child
            # forever, and with several uploads in flight that would hang the
            # install rather than slow it.
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $cli
            $psi.Arguments = ConvertTo-ExapumpArgumentLine @("upload", $f.Path, "--table", $f.Target, "-p", $script:ExapumpProfile)
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            [void]$running.Add(@{
                File = $f; Proc = $proc
                Out  = $proc.StandardOutput.ReadToEndAsync()
                Err  = $proc.StandardError.ReadToEndAsync()
            })
        }
        if ($running.Count -eq 0) { continue }
        Start-Sleep -Milliseconds 100
        $still = New-Object 'System.Collections.Generic.List[object]'
        foreach ($r in $running) {
            if (-not $r.Proc.HasExited) { [void]$still.Add($r); continue }
            $done++
            # Settles the exit code and guarantees both async reads completed.
            $r.Proc.WaitForExit()
            $out = ""
            try { $out = "$($r.Out.Result)$($r.Err.Result)" } catch { }
            # Logged per file, after that file finishes, so the log still reads
            # as one block per upload instead of interleaved fragments.
            if ($script:LogFile) {
                "exapump upload $($r.File.Path) --table $($r.File.Target) -p $($script:ExapumpProfile)" |
                    Add-Content -Path $script:LogFile
                $out | Add-Content -Path $script:LogFile
            }
            if (Test-ExapumpSucceeded -ExitCode $r.Proc.ExitCode -Output $out) {
                if (-not $script:ExakitUploadQuiet) { Ok "$($r.File.Name) loaded" }
            } else {
                Write-ExapumpOutput -Output $out
                Show-ExakitDbErrorRemedy $out
                $script:ExakitUploadFailures += "$($r.File.Path) -> $($r.File.Target)"
            }
            # No position to report: the whole upload is ONE segment of the
            # caller's bar, precisely because concurrent waves have no "current"
            # file. What each landing DOES refine is the phase text, so the
            # reader can see the batch draining.
            Set-ExakitProgressPhase "$Id - loaded $done of $($Files.Count) data files"
        }
        $running = $still
    }
}

# Get-ExapumpProfilePassword <profile> - the password stored in an exapump
# profile ($script:ExapumpConfigPath), or $null. Symmetric with the writer in
# Set-ExapumpTomlSection. Lets the MCP step recover the admin password when the
# runtime step could not record runtime.password_file.
function Get-ExapumpProfilePassword {
    param([Parameter(Mandatory)][string]$Profile)
    if (-not (Test-Path $script:ExapumpConfigPath)) { return $null }
    $content = Get-Content $script:ExapumpConfigPath -Raw
    $section = [regex]::Match($content, "(?s)\[$([regex]::Escape($Profile))\](.*?)(?:\n\[|\z)")
    if (-not $section.Success) { return $null }
    $pw = [regex]::Match($section.Groups[1].Value, '(?m)^\s*password\s*=\s*"(.*)"\s*$')
    if (-not $pw.Success) { return $null }
    return $pw.Groups[1].Value
}

# Get-ExapumpRowCount <schema.table> - row count, or $null if it could not be
# read. Best-effort only: the row-count summary it feeds is cosmetic (shows
# "?" on failure) and the real load validation is 03_verify_setup.sql.
function Get-ExapumpRowCount {
    param([Parameter(Mandatory)][string]$Target)
    # Wrap the count in a unique delimited token (EXAKIT_RC[<n>]) so it can be
    # recovered from exapump's output no matter how the value is laid out - grid
    # vs compact, interactive TTY vs the piped, non-TTY install run. Scraping the
    # bare number was unreliable: during install exapump prints only a
    # "[1/1] ... 1 rows" status line, and the old digit-stripping fallback
    # collapsed that to "111" for EVERY table (from "[1/1]" + the single row a
    # COUNT(*) always returns). The token can't collide with that status line,
    # and the echoed query literal ("EXAKIT_RC[' || ...") never forms
    # "EXAKIT_RC[<digits>]", so only the actual result value matches.
    $sql = "SELECT 'EXAKIT_RC[' || CAST(COUNT(*) AS VARCHAR(40)) || ']' AS EXAKIT_RC FROM $Target"
    $result = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, $sql)
    if (-not $result.Success) { return $null }
    $m = [regex]::Match("$($result.Output)", 'EXAKIT_RC\[(\d+)\]')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# Get-ExapumpRowCountMany <schema> <tables> - count EVERY table in ONE exapump
# invocation instead of one per table. Returns a hashtable of table -> count,
# or $null if any table did not come back.
#
# WHY THIS EXISTS: every exapump call is a separate PROCESS LAUNCH, and on
# Windows a freshly downloaded, unsigned exapump.exe is re-scanned by Defender
# on each one - measured at ~4.4s per launch during an install, against 88ms
# once the scan is cached. A tpch load made 20 launches, 8 of them nothing but
# one COUNT(*) per table. That is why loading weather (10,970 rows) took as
# long as energy (108,050 rows): both made 7 launches. The row counts never
# mattered; the launch count did.
#
# $null is deliberately all-or-nothing: a UNION ALL fails as a whole, so a
# partial read must send the caller back to counting one at a time rather than
# let it report a total that is quietly short.
#
# The token carries the table name (EXAKIT_RC[CUSTOMER=1500]) because one
# result set now holds every count and they have to be told apart. As with
# Get-ExapumpRowCount the echoed query literal cannot match: after "=" it has
# a quote, not a digit.
function Get-ExapumpRowCountMany {
    param(
        [Parameter(Mandatory)][string]$Schema,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Tables
    )
    if ($Tables.Count -eq 0) { return @{} }
    $parts = @()
    foreach ($t in $Tables) {
        $parts += "SELECT 'EXAKIT_RC[$t=' || CAST(COUNT(*) AS VARCHAR(40)) || ']' AS EXAKIT_RC FROM $Schema.$t"
    }
    $result = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, ($parts -join " UNION ALL "))
    if (-not $result.Success) { return $null }
    $counts = @{}
    foreach ($m in [regex]::Matches("$($result.Output)", 'EXAKIT_RC\[([A-Za-z0-9_]+)=(\d+)\]')) {
        $counts[$m.Groups[1].Value] = $m.Groups[2].Value
    }
    foreach ($t in $Tables) {
        if (-not $counts.ContainsKey($t)) { return $null }
    }
    return $counts
}

function Get-ExakitTableName {
    param([Parameter(Mandatory)][string]$Path)
    $base = (Split-Path $Path -Leaf) -replace '\?.*$', ''
    $base = [System.IO.Path]::GetFileNameWithoutExtension($base)
    # Parentheses required: without them "-replace" binds as a parameter of
    # ConvertTo-UpperInvariantString instead of acting as the operator.
    $table = ((ConvertTo-UpperInvariantString $base) -replace '[^A-Z0-9_]', '_')
    $table = ($table -replace '^_+', '') -replace '_+$', ''
    $table = $table -replace '_{2,}', '_'
    if (-not $table) { return "MY_TABLE" }
    return $table
}

function Get-ExakitNormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -eq "~") { return $HOME }
    if ($Path.StartsWith("~/") -or $Path.StartsWith("~\")) { return Join-Path $HOME $Path.Substring(2) }
    return $Path
}

function Test-ExakitTableTarget {
    param([Parameter(Mandatory)][string]$Target)
    if ($Target -notmatch '^[A-Za-z0-9_]+\.[A-Za-z0-9_]+$') { return $false }
    return $true
}

function Get-ExakitTargetSchema {
    param([Parameter(Mandatory)][string]$Target)
    return ConvertTo-UpperInvariantString (($Target -split '\.', 2)[0])
}

function Get-ExakitUpperTableTarget {
    param([Parameter(Mandatory)][string]$Target)
    $parts = $Target -split '\.', 2
    return "$(ConvertTo-UpperInvariantString $parts[0]).$(ConvertTo-UpperInvariantString $parts[1])"
}

# Test-ExapumpSchemaPresent - read-only check that a schema exists, from a fresh
# connection. Distinct from Confirm-ExakitSchemaExists, which also creates it.
function Test-ExapumpSchemaPresent {
    param([Parameter(Mandatory)][string]$Schema)
    $schemaUc = ConvertTo-UpperInvariantString $Schema
    if (-not $schemaUc) { return $false }
    # Decide presence from the ROW COUNT of a row-returning query, not by
    # scraping a sentinel token out of the rendered result grid. When exapump's
    # stdout is a pipe (every install runs it that way) it omits the result grid
    # entirely, so a sentinel like EXAKIT_SCHEMA_PRESENT never reaches the
    # captured output and this check always reported the schema missing - which
    # aborted the sample-data load even though the schema existed. The "<n> rows"
    # count on exapump's progress line IS reliably captured: a present schema
    # yields "1 rows", an absent one "0 rows".
    $sql = "SELECT 1 FROM EXA_ALL_SCHEMAS WHERE SCHEMA_NAME = '$schemaUc'"
    $check = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, $sql)
    return ($check.Success -and "$($check.Output)" -match '(?im)\b[1-9]\d*\s+rows?\b')
}

function Confirm-ExakitSchemaExists {
    param([Parameter(Mandatory)][string]$Schema)
    $schemaUc = ConvertTo-UpperInvariantString $Schema
    if (-not $schemaUc) { return $false }
    if (Test-ExapumpSchemaPresent $schemaUc) { return $true }
    if (-not $script:ExakitUploadQuiet) { Info "Creating schema $schemaUc" }
    $create = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "CREATE SCHEMA $schemaUc")
    if (-not $create.Success) { Fail "Could not create schema $schemaUc" }
    return $true
}

function Confirm-ExakitLoadedTable {
    param([Parameter(Mandatory)][string]$Target)
    $rows = Get-ExapumpRowCount $Target
    if ($null -eq $rows) { Fail "Could not verify row count for $Target." }
    if ($rows -eq "0") {
        Warn2 "Verified $Target, but it currently has 0 rows."
    } else {
        if (-not $script:ExakitUploadQuiet) { Ok "Verified $Target ($rows rows)" }
    }
    Set-ExakitManifestValue "data.last_load.verified_table" $Target
    Set-ExakitManifestValue "data.last_load.verified_rows" $rows
}

function Request-ExakitOptionalVerification {
    param([string]$Default = "")
    $target = Read-ExakitPrompt "Verify table after script/import (SCHEMA.TABLE, blank to skip)" $Default
    if (-not $target) { Info "Skipping table verification for this script/import."; return }
    if (-not (Test-ExakitTableTarget $target)) {
        Fail "Verification table must look like SCHEMA.TABLE and use letters, numbers, or underscores."
    }
    Confirm-ExakitLoadedTable (Get-ExakitUpperTableTarget $target)
}

# Get-ExakitDataFileKind <path> - csv | parquet | json | unknown, from the
# name. Twin of exakit_data_file_kind in exapump.sh. Windows cannot run the
# JSON engine (see json-tables.ps1), so this exists to REFUSE a JSON file with
# its reason rather than hand it to exapump, which would fail obscurely.
function Get-ExakitDataFileKind {
    param([Parameter(Mandatory)][string]$Path)
    $name = (Split-Path $Path -Leaf).ToLowerInvariant()
    if ($name -match '\.(gz|bz2|zst|xz)$') { $name = $name -replace '\.(gz|bz2|zst|xz)$', '' }
    if ($name -match '\.(json|ndjson|jsonl)$')  { return "json" }
    if ($name -match '\.(parquet|pq)$')         { return "parquet" }
    if ($name -match '\.(csv|tsv|txt)$')        { return "csv" }
    return "unknown"
}

# Show-ExakitJsonUnsupported - one honest explanation, with the reason the
# add-on itself gives, instead of a load that fails at the first ingest.
function Show-ExakitJsonUnsupported {
    $why = ""
    if (Get-Command Get-JsonTablesApplicableReason -ErrorAction SilentlyContinue) {
        $why = Get-JsonTablesApplicableReason
    }
    if ($why) {
        Warn2 "JSON files need an engine that is not available on this machine: $why"
    } else {
        Warn2 "JSON files need an engine that is not available on this machine."
    }
    Info "CSV and Parquet load without it. Convert the file, or load it from macOS, Linux or WSL."
}

function Import-ExakitLocalFile {
    $defaultPath = if ($env:EXAKIT_DATA_FILE) { $env:EXAKIT_DATA_FILE } else { "" }
    while ($true) {
        $rawPath = Read-ExakitPrompt "Local CSV/Parquet file - or a folder of them (type back to return)" $defaultPath
        if ($rawPath -match '^(b|back)$') {
            Info "Returning to data loading options."
            return "back"
        }
        if (-not $rawPath) {
            Warn2 "Please enter a local CSV/Parquet file, a folder of them, or type back to return."
            # No console means Read-ExakitPrompt returns the same default
            # forever, so a bad or missing EXAKIT_DATA_FILE must fail here
            # instead of looping.
            if (-not (Test-ExakitInteractive)) {
                Fail "No local file to load - set EXAKIT_DATA_FILE to a readable CSV/Parquet file."
            }
            continue
        }
        $path = Get-ExakitNormalizedPath $rawPath
        # A FOLDER is a bulk load: every data file in it, one table each. It is
        # answered by the same prompt (and the same EXAKIT_DATA_FILE) as a single
        # file, because "here is my data" is the same request either way.
        if (Test-Path $path -PathType Container) { return (Import-ExakitLocalFolder -Path $path) }
        if ((Test-Path $path) -and (Get-Item $path).Length -gt 0) { break }
        Warn2 "File not found or empty: $path"
        if (-not (Test-ExakitInteractive)) {
            Fail "File not found or empty: $path"
        }
    }
    # A JSON file cannot be loaded on Windows at all, so say so here rather
    # than after the user has picked a table for a load that cannot happen.
    if ((Get-ExakitDataFileKind $path) -eq "json") {
        Show-ExakitJsonUnsupported
        # An unattended run (EXAKIT_DATA_FILE) has nobody to read that advice:
        # it must FAIL, or the agent reads success off a load that never ran.
        if (-not (Test-ExakitInteractive)) {
            Fail "JSON files cannot be loaded on Windows - convert $path to CSV/Parquet, or load it from macOS, Linux or WSL."
        }
        return "back"
    }
    $schema = if ($env:EXAKIT_SCHEMA) { $env:EXAKIT_SCHEMA } else { "STARTER_KIT" }
    $defaultTable = "$schema.$(Get-ExakitTableName $path)"
    # EXAKIT_DATA_TABLE pre-answers the target the same way the path is
    # pre-answered - as the prompt's default, which a no-console run keeps.
    if ($env:EXAKIT_DATA_TABLE) { $defaultTable = $env:EXAKIT_DATA_TABLE }
    while ($true) {
        $target = Read-ExakitPrompt "Target table (SCHEMA.TABLE, back to return)" $defaultTable
        if ($target -match '^(b|back)$') {
            Info "Returning to data loading options."
            return "back"
        }
        if (Test-ExakitTableTarget $target) { break }
        Warn2 "Target table must look like SCHEMA.TABLE and use letters, numbers, or underscores."
        if (-not (Test-ExakitInteractive)) {
            Fail "EXAKIT_DATA_TABLE must look like SCHEMA.TABLE and use letters, numbers, or underscores."
        }
    }
    $target = Get-ExakitUpperTableTarget $target

    # One label, one spinner, for the whole job - the twin of what exapump.sh
    # does with EXAKIT_UPLOAD_QUIET and EXAKIT_ACTIVE_LABEL.
    $script:ExakitUploadQuiet = $true
    $script:ExakitActiveLabel = "Loading your data"
    try {
        Confirm-ExakitSchemaExists (Get-ExakitTargetSchema $target) | Out-Null
        Invoke-ExapumpUpload $path $target | Out-Null
        Set-ExakitManifestValue "data.last_load.type" "local_file"
        Set-ExakitManifestValue "data.last_load.target" $target
        Set-ExakitManifestValue "data.last_load.source" $path
        Confirm-ExakitLoadedTable $target
    } finally {
        $script:ExakitUploadQuiet = $false
        $script:ExakitActiveLabel = ""
    }
    Ok "Loaded $path into $target"
}

# --- bulk folder load --------------------------------------------------------
# Twin of the bulk folder load in exapump.sh. One folder in, every data file in
# it loaded, one table per file. The folder is read at its TOP LEVEL only:
# subfolders are never descended into and hidden files are left alone, so a
# directory of exports loads without dragging in a nested archive\, the images
# beside the data, or a desktop.ini.

# Get-ExakitBulkFileKind - Get-ExakitDataFileKind, minus .txt.
#
# Naming one file says "this is my data, whatever it is called", and .txt is a
# reasonable CSV there. Scanning a folder says nothing of the kind: a README.txt
# beside the exports is not a table, and loading one as CSV would be a silent
# surprise rather than a service. Twin of exakit_bulk_file_kind.
function Get-ExakitBulkFileKind {
    param([Parameter(Mandatory)][string]$Path)
    $name = (Split-Path $Path -Leaf).ToLowerInvariant()
    if ($name -match '\.txt(\.(gz|bz2|zst|xz))?$') { return "unknown" }
    return (Get-ExakitDataFileKind $Path)
}

# Get-ExakitBulkFolderPlan <dir> - the plan for a folder, one string per
# top-level file, in the order the files will load:
#
#   load|<kind>|<table>|<path>          kind: csv | parquet | json
#   skip|<reason>|<detail>|<path>       reason: unsupported | empty | json-unsupported
#                                             | duplicate-content | duplicate-table
#
# For a skipped duplicate, <detail> names the file it duplicates. Two kinds of
# duplicate are refused, because both silently lose data: byte-identical files
# would load the same rows into two tables, and two names that resolve to the
# SAME table would have the second overwrite the first.
#
# JSON is reported as json-unsupported here rather than loaded: this kit has no
# prebuilt ingest engine for Windows (see Get-JsonTablesApplicableReason), which
# is the same answer Import-ExakitLocalFile gives for a single JSON file.
#
# Files are ordered by ORDINAL bytes, not by the machine's culture, so which of
# two duplicates wins is the same answer on every machine - the twin sorts with
# LC_ALL=C for exactly that reason.
function Get-ExakitBulkFolderPlan {
    param([Parameter(Mandatory)][string]$Path)
    $names = @(Get-ChildItem -Path $Path -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name })
    if ($names.Count -gt 1) { [Array]::Sort($names, [StringComparer]::Ordinal) }

    $plan = New-Object 'System.Collections.Generic.List[string]'
    $keptPaths  = New-Object 'System.Collections.Generic.List[string]'
    $keptTables = New-Object 'System.Collections.Generic.List[string]'
    $keptSizes  = New-Object 'System.Collections.Generic.List[long]'
    $keptHashes = New-Object 'System.Collections.Generic.List[string]'

    foreach ($name in $names) {
        $full = Join-Path $Path $name
        $table = Get-ExakitTableName $full
        $kind = Get-ExakitBulkFileKind $full
        if ($kind -eq "unknown") { [void]$plan.Add("skip|unsupported||$full"); continue }
        if ($kind -eq "json")    { [void]$plan.Add("skip|json-unsupported||$full"); continue }
        $size = (Get-Item $full).Length
        if ($size -le 0) { [void]$plan.Add("skip|empty||$full"); continue }

        $hash = ""
        $dupe = ""
        $reason = ""
        for ($i = 0; $i -lt $keptPaths.Count; $i++) {
            if ($keptTables[$i] -eq $table) {
                $dupe = $keptPaths[$i]; $reason = "duplicate-table"; break
            }
            if ($keptSizes[$i] -eq $size) {
                # Hash only what could actually match: same-size files are the
                # only candidates, so a folder of differently sized exports is
                # never read twice just to prove they differ.
                if (-not $hash) { $hash = (Get-FileHash -Algorithm SHA256 -Path $full).Hash.ToLowerInvariant() }
                if (-not $keptHashes[$i]) {
                    $keptHashes[$i] = (Get-FileHash -Algorithm SHA256 -Path $keptPaths[$i]).Hash.ToLowerInvariant()
                }
                if ($keptHashes[$i] -eq $hash) {
                    $dupe = $keptPaths[$i]; $reason = "duplicate-content"; break
                }
            }
        }
        if ($dupe) {
            [void]$plan.Add("skip|$reason|$(Split-Path $dupe -Leaf)|$full")
            continue
        }
        [void]$keptPaths.Add($full)
        [void]$keptTables.Add($table)
        [void]$keptSizes.Add($size)
        [void]$keptHashes.Add($hash)
        [void]$plan.Add("load|$kind|$table|$full")
    }
    return $plan.ToArray()
}

# Get-ExakitBulkKindsPresent <plan> - the loadable kinds in the plan, in the
# order the format menu shows them.
function Get-ExakitBulkKindsPresent {
    param([string[]]$Plan)
    $found = New-Object 'System.Collections.Generic.List[string]'
    foreach ($kind in @("csv", "parquet", "json")) {
        if ($Plan | Where-Object { $_.StartsWith("load|$kind|") }) { [void]$found.Add($kind) }
    }
    return $found.ToArray()
}

# Get-ExakitBulkLabel <kind> - the format's name as the menu says it.
function Get-ExakitBulkLabel {
    param([Parameter(Mandatory)][string]$Kind)
    switch ($Kind) {
        "csv"     { return "CSV" }
        "parquet" { return "Parquet" }
        "json"    { return "JSON" }
        default   { return $Kind }
    }
}

# Select-ExakitBulkFormats <plan> - which formats to load, returned as an array
# of kinds (empty = cancel).
#
# Only asked when the folder actually holds more than one loadable format: with
# a single format there is nothing to choose, and a menu whose every answer is
# the same answer is just a keystroke. EXAKIT_DATA_FORMATS pre-answers it for an
# unattended run, the same way EXAKIT_DATASETS pre-answers the dataset menu.
function Select-ExakitBulkFormats {
    param([string[]]$Plan)
    $kinds = @(Get-ExakitBulkKindsPresent $Plan)

    if ($env:EXAKIT_DATA_FORMATS) {
        $chosen = New-Object 'System.Collections.Generic.List[string]'
        foreach ($raw in ($env:EXAKIT_DATA_FORMATS -split ',')) {
            $want = $raw.Trim().ToLowerInvariant()
            if (-not $want) { continue }
            if ($want -eq "pq") { $want = "parquet" }
            if ($want -eq "ndjson" -or $want -eq "jsonl") { $want = "json" }
            if ($kinds -contains $want) {
                if (-not ($chosen -contains $want)) { [void]$chosen.Add($want) }
            } else {
                Warn2 "No $(Get-ExakitBulkLabel $want) files in this folder (EXAKIT_DATA_FORMATS)."
            }
        }
        return $chosen.ToArray()
    }

    if ($kinds.Count -le 1) { return $kinds }

    $labels = New-Object 'System.Collections.Generic.List[string]'
    $defaults = New-Object 'System.Collections.Generic.List[int]'
    for ($i = 0; $i -lt $kinds.Count; $i++) {
        $count = @($Plan | Where-Object { $_.StartsWith("load|$($kinds[$i])|") }).Count
        if ($count -eq 1) { $unit = "file" } else { $unit = "files" }
        [void]$labels.Add("$(Get-ExakitBulkLabel $kinds[$i]) ($count $unit)")
        [void]$defaults.Add($i + 1)
    }
    [void]$labels.Add("Skip")
    $finalIdx = $labels.Count
    $selection = Read-ExakitCheckboxMenu `
        -Title "This folder has more than one format - which do you want to load?" `
        -Options $labels.ToArray() -Defaults $defaults.ToArray() -ExclusiveIndex $finalIdx
    if ($selection -contains $finalIdx) { return @() }
    return @($selection | Where-Object { $_ -ge 1 -and $_ -lt $finalIdx } | ForEach-Object { $kinds[$_ - 1] })
}

# Show-ExakitBulkPlan - what is about to happen, and what will not. Duplicates
# are named one by one, because being skipped is a surprise worth explaining;
# files of other kinds are counted, because a folder of exports beside two
# hundred images should not print two hundred lines.
function Show-ExakitBulkPlan {
    param([string[]]$Plan, [string[]]$Chosen, [string]$Schema, [string]$Path)
    Info "From $Path into ${Schema}:"
    foreach ($row in $Chosen) {
        $parts = $row.Split('|', 3)
        Write-Host ("      {0}{1}{2} {3} {4}->{5} {6}.{7}" -f $script:UiDim, $script:UiBullet, $script:UiReset,
            (Split-Path $parts[2] -Leaf), $script:UiDim, $script:UiReset, $Schema, $parts[1])
    }
    foreach ($row in ($Plan | Where-Object { $_.StartsWith("skip|duplicate") })) {
        $parts = $row.Split('|', 4)
        if ($parts[1] -eq "duplicate-content") { $why = "identical to $($parts[2])" }
        else { $why = "same target table as $($parts[2])" }
        Write-Host ("      {0}! {1} skipped ({2}){3}" -f $script:UiDim,
            (Split-Path $parts[3] -Leaf), $why, $script:UiReset)
    }
    $json = @($Plan | Where-Object { $_.StartsWith("skip|json-unsupported|") }).Count
    if ($json -gt 0) {
        $why = ""
        if (Get-Command Get-JsonTablesApplicableReason -ErrorAction SilentlyContinue) {
            $why = Get-JsonTablesApplicableReason
        }
        if ($why) { Warn2 "$json JSON file(s) skipped: $why" }
        else { Warn2 "$json JSON file(s) skipped: no ingest engine is available on this machine." }
        Info "CSV and Parquet load without it. Load the JSON files from macOS, Linux or WSL."
    }
    $other = @($Plan | Where-Object { $_.StartsWith("skip|unsupported|") }).Count
    if ($other -gt 0) {
        Write-Host ("      {0}{1} file(s) of other kinds ignored{2}" -f $script:UiDim, $other, $script:UiReset)
    }
    $empty = @($Plan | Where-Object { $_.StartsWith("skip|empty|") }).Count
    if ($empty -gt 0) {
        Write-Host ("      {0}{1} empty file(s) ignored{2}" -f $script:UiDim, $empty, $script:UiReset)
    }
}

# Import-ExakitLocalFolder <dir> - load every data file in one folder.
#
# The schema is asked once, not once per file: a folder is one job, and its
# tables are named after the files (sales.csv -> SALES). Returns "back" when the
# user backs out, "failed" when something failed, "" when everything asked for
# was loaded. Twin of exakit_load_local_folder.
function Import-ExakitLocalFolder {
    param([Parameter(Mandatory)][string]$Path)
    $plan = @(Get-ExakitBulkFolderPlan -Path $Path)
    $loadable = @($plan | Where-Object { $_.StartsWith("load|") })
    if ($loadable.Count -eq 0) {
        $json = @($plan | Where-Object { $_.StartsWith("skip|json-unsupported|") }).Count
        if ($json -gt 0) {
            Show-ExakitBulkPlan -Plan $plan -Chosen @() -Schema "" -Path $Path
        } else {
            Warn2 "No CSV or Parquet files in $Path."
            Info "Only the folder itself is read - subfolders and files of other kinds are left alone."
        }
        return "failed"
    }

    $formats = @(Select-ExakitBulkFormats $plan)
    if ($formats.Count -eq 0) {
        Info "Nothing selected - no files were loaded."
        return "back"
    }
    $chosen = @($loadable | Where-Object { $formats -contains $_.Split('|', 3)[1] } |
        ForEach-Object { $_.Substring(5) })
    if ($chosen.Count -eq 0) {
        Info "Nothing selected - no files were loaded."
        return "back"
    }

    # One schema for the whole folder, asked once.
    if ($env:EXAKIT_SCHEMA) { $schema = $env:EXAKIT_SCHEMA } else { $schema = "STARTER_KIT" }
    while ($true) {
        $schema = Read-ExakitPrompt "Target schema for all $($chosen.Count) file(s) (back to return)" $schema
        if ($schema -match '^(b|back)$') {
            Info "Returning to data loading options."
            return "back"
        }
        if ($schema -match '^[A-Za-z0-9_]+$') { break }
        Warn2 "Schema must use letters, numbers or underscores."
        if (-not (Test-ExakitInteractive)) { return "failed" }
    }
    $schema = $schema.ToUpperInvariant()

    Show-ExakitBulkPlan -Plan $plan -Chosen $chosen -Schema $schema -Path $Path
    if (-not (Confirm-ExakitEnvPrompt -EnvName "EXAKIT_BULK_CONFIRM" `
            -Question "Load these $($chosen.Count) file(s) into $schema?" -DefaultYes $true)) {
        Info "Nothing was loaded."
        return "back"
    }

    Confirm-ExakitSchemaExists $schema | Out-Null
    $script:ExakitUploadQuiet = $true
    # Weighted by BYTES, like a bundled dataset: a folder is usually one big
    # export and a handful of small ones, and counting files would put the bar at
    # 90% while the only file that matters is still going.
    $totalWeight = [long]0
    foreach ($row in $chosen) { $totalWeight += (Get-ExakitLoadWeight $row.Split('|', 3)[2]) }
    $doneWeight = [long]0
    $done = 0
    $failed = 0
    $i = 0
    [void](Start-ExakitProgress -Pct 0 -Ceiling 1 -Secs 2 -Phase "reading $($chosen.Count) file(s)")
    try {
        foreach ($row in $chosen) {
            $i++
            $parts = $row.Split('|', 3)
            $file = $parts[2]
            $target = "$schema.$($parts[1])"
            # The spinner names the file it is actually on, and how far through
            # the folder it is - a forty-file load must never animate under one
            # label.
            $w = Get-ExakitLoadWeight $file
            Set-ExakitLoadStep -DoneWeight $doneWeight -StepWeight $w -TotalWeight $totalWeight `
                -Seconds (Get-ExakitLoadSeconds $w) `
                -Phase "$(Split-Path $file -Leaf) ($i/$($chosen.Count))"
            # @(...)[-1]: the function writes its progress with Write-Host, but
            # taking the LAST emitted value keeps the boolean even if a helper
            # underneath it ever starts writing to the pipeline.
            $uploaded = $false
            try {
                $uploaded = [bool](@(Invoke-ExapumpUpload $file $target -Soft)[-1])
            } catch {
                $uploaded = $false
            }
            if ($uploaded) {
                # To the logfile: the plan above the confirm already listed every
                # file and its target, and a redrawing bar cannot share the row.
                Write-ExakitLog "OK" "$(Split-Path $file -Leaf) -> $target"
                $done++
                $doneWeight += $w
            } else {
                Warn2 "$(Split-Path $file -Leaf) could not be loaded (see log) - the rest of the folder continues."
                $failed++
            }
        }
    } finally {
        Stop-ExakitProgress
        $script:ExakitUploadQuiet = $false
        $script:ExakitActiveLabel = ""
    }

    Set-ExakitManifestValue "data.last_load.type" "local_folder"
    Set-ExakitManifestValue "data.last_load.source" $Path
    Set-ExakitManifestValue "data.last_load.target" $schema
    Set-ExakitManifestValue "data.last_load.files" $done

    if ($failed -gt 0) {
        Warn2 "Loaded $done of $($chosen.Count) file(s) into $schema; $failed failed (see log)."
        return "failed"
    }
    Ok "Loaded $done file(s) into $schema"
    return ""
}

function Import-ExakitRemoteFile {
    $url = Read-ExakitPrompt "Remote CSV/Parquet URL" ""
    if (-not $url) { Fail "Remote URL is required." }
    $name = Split-Path ($url -replace '\?.*$', '') -Leaf
    if (-not $name) { $name = "remote-data.csv" }
    if ((Get-ExakitDataFileKind $name) -eq "json") {
        Show-ExakitJsonUnsupported
        return
    }
    # Both questions are asked before the download starts, so the whole job is
    # one uninterrupted "Loading your data" from here on.
    $schema = if ($env:EXAKIT_SCHEMA) { $env:EXAKIT_SCHEMA } else { "STARTER_KIT" }
    $defaultTable = "$schema.$(Get-ExakitTableName $name)"
    $target = Read-ExakitPrompt "Target table (SCHEMA.TABLE)" $defaultTable
    if (-not (Test-ExakitTableTarget $target)) {
        Fail "Target table must look like SCHEMA.TABLE and use letters, numbers, or underscores."
    }
    $target = Get-ExakitUpperTableTarget $target

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-remote-data-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $tmpFile = Join-Path $tmpDir $name

    $script:ExakitUploadQuiet = $true
    $script:ExakitActiveLabel = "Loading your data"
    try {
        # Get-ExakitFile draws nothing of its own, so the dot loader is started
        # here: a download is part of loading your data, not a step of its own.
        Start-ExakitSpinner "Loading your data"
        try {
            Get-ExakitFile -Url $url -Dest $tmpFile
        } finally {
            Stop-ExakitSpinner
        }
        Confirm-ExakitSchemaExists (Get-ExakitTargetSchema $target) | Out-Null
        Invoke-ExapumpUpload $tmpFile $target | Out-Null
        Set-ExakitManifestValue "data.last_load.type" "remote_file"
        Set-ExakitManifestValue "data.last_load.target" $target
        Set-ExakitManifestValue "data.last_load.source" $url
        Confirm-ExakitLoadedTable $target
    } finally {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        $script:ExakitUploadQuiet = $false
        $script:ExakitActiveLabel = ""
    }
    Ok "Loaded $url into $target"
}

function Invoke-ExakitSqlScript {
    $rawPath = Read-ExakitPrompt "SQL script path" ""
    $path = Get-ExakitNormalizedPath $rawPath
    if (-not (Test-Path $path) -or (Get-Item $path).Length -eq 0) { Fail "SQL script not found or empty: $path" }
    Invoke-ExapumpSqlFile $path "SQL script ($(Split-Path $path -Leaf))" | Out-Null
    Set-ExakitManifestValue "data.last_load.type" "sql_script"
    Set-ExakitManifestValue "data.last_load.source" $path
    Request-ExakitOptionalVerification ""
    Ok "SQL script completed"
}

# --- bundled dataset registry (mirrors exapump.sh) --------------------------
# TPC-H is the original flat-layout dataset; every additional dataset is a
# self-contained directory data/datasets/<id>/ with a dataset.conf (id=,
# label=, markers=, schema=), a schema script, optional bulk CSVs, an optional
# transform, and an optional verify script. Each dataset loads into its own
# schema (schema=, default the id uppercased); the read-only MCP user has
# database-wide read (USE ANY SCHEMA + SELECT ANY TABLE), so it sees every
# dataset schema with no per-schema grant.
function Get-ExakitBundledDatasets {
    # Every dataset (TPC-H included) is discovered from its dataset.conf;
    # nothing is hardcoded. A conf may set flag= to override the default
    # manifest key (TPC-H keeps the historical data.loaded) and schema= to name
    # the schema it loads into (default: the id, uppercased).
    $datasets = @()
    $kitRoot = Get-ExakitRepoRoot
    if ($kitRoot) {
        foreach ($conf in (Get-ChildItem -Path (Join-Path $kitRoot "data\datasets\*\dataset.conf") -ErrorAction SilentlyContinue)) {
            $kv = @{}
            foreach ($line in (Get-Content $conf)) {
                if ($line -match '^([a-z_]+)=(.*)$') { $kv[$Matches[1]] = $Matches[2] }
            }
            if (-not $kv.id -or -not $kv.label) { continue }
            $markers = @(($kv.markers -split ',') | Where-Object { $_ })
            $flag = if ($kv.flag) { $kv.flag } else { "data.datasets.$($kv.id).loaded" }
            $schema = if ($kv.schema) { $kv.schema } else { $kv.id.ToUpper() }
            $order = 50
            if ($kv.order -match '^[0-9]+$') { $order = [int]$kv.order }
            $datasets += @{ Id = $kv.id; Label = $kv.label; Flag = $flag; Markers = $markers; Schema = $schema; Order = $order }
        }
    }
    return @($datasets | Sort-Object { $_.Order }, { $_.Id })
}

# Test-ExakitDbReachable - can we run SQL right now?
#
# ONLY A "YES" IS CACHED. Caching the "no" too is what let one installer run
# report a full database while looking at an empty one: the probe ran before the
# runtime step, the deployment was down (or being replaced), and that answer was
# still cached when the data step asked afterwards. Every dataset then fell
# through to the manifest flag and printed "already loaded" against a database
# with no schemas in it. A "yes" cannot go stale the same way - nothing in a kit
# run takes the database down without going through Stop-ExakitNano /
# Stop-ExasolPersonal, and those call Clear-ExakitDbReachable.
# twin: exakit_db_reachable in setup/lib/exapump.sh.
$script:ExakitDbReachable = $null
function Test-ExakitDbReachable {
    if ($script:ExakitDbReachable -ne $true) {
        $script:ExakitDbReachable = $false
        if (Get-ExakitManifestValue "components.exapump.profile") {
            $result = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "SELECT 1")
            $script:ExakitDbReachable = [bool]$result.Success
        }
    }
    return $script:ExakitDbReachable
}

# Clear-ExakitDbReachable - drop the cached "yes" after the kit itself takes the
# database down, so a later check re-probes instead of trusting a state this run
# has just ended.
# twin: exakit_forget_db_reachable in setup/lib/exapump.sh.
function Clear-ExakitDbReachable {
    $script:ExakitDbReachable = $null
}

# Test-ExakitTablePresent <table> [schema] - does the table exist in the given
# schema (default STARTER_KIT / $EXAKIT_SCHEMA)?
function Test-ExakitTablePresent {
    param([Parameter(Mandatory)][string]$Table, [string]$Schema)
    $schema = if ($Schema) { $Schema.ToUpper() } elseif ($env:EXAKIT_SCHEMA) { $env:EXAKIT_SCHEMA.ToUpper() } else { "STARTER_KIT" }
    $tableUc = $Table.ToUpper()
    $sql = "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_ALL_TABLES WHERE TABLE_SCHEMA = '$schema' AND TABLE_NAME = '$tableUc') THEN 'EXAKIT_TABLE_PRESENT' ELSE 'EXAKIT_TABLE_MISSING' END AS STATUS"
    $result = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, $sql)
    return ($result.Success -and $result.Output -match "EXAKIT_TABLE_PRESENT")
}

# Sync-ExakitDatasetFlag - write one manifest flag only when it disagrees with
# what was observed.
function Sync-ExakitDatasetFlag {
    param([string]$Key, [bool]$Value)
    if (-not $Key) { return }
    if ((Get-ExakitManifestValue $Key) -ne $Value) { Set-ExakitManifestValue $Key $Value }
}

# Test-ExakitDatasetLoaded - the DATABASE is the source of truth: when it is
# reachable, every marker table must exist, and BOTH manifest keys are synced to
# what was observed, so a destroy+redeploy that left a stale "loaded" flag
# self-heals. Only when the database is unreachable do we fall back to the
# manifest.
#
# TWO KEYS, on purpose. A dataset.conf may set flag= to override the manifest key
# (TPC-H keeps the historical data.loaded so older installs stay recognized),
# while `exakit status` reads the canonical data.datasets.<id>.loaded for every
# dataset alike. Syncing only the override is what let status keep listing tpch
# as loaded against a database with no schemas in it.
# twin: exakit_dataset_loaded in setup/lib/exapump.sh.
# ONE LISTING, NOT A REACHABILITY PROBE PLUS A QUERY PER MARKER.
#
# This used to ask Test-ExakitDbReachable (a SELECT 1) and then run one
# EXA_ALL_TABLES query PER MARKER TABLE - four exapump launches for tpch, eight
# across the three bundled datasets. Every launch is a process start, a TLS
# handshake and an authentication, ~2.5s warm, which is why
# Invoke-ExakitDatasetLoad measured 11.5s to do nothing but print
# "already loaded".
#
# Get-ExakitVerifiedDatasets already learned exactly this - "THE TABLE LISTING
# IS THE REACHABILITY PROBE ... asking SELECT 1 first bought no information the
# listing does not already give, and doubled the cost" - but this function was
# never brought along. It is now: one listing answers reachability AND every
# marker at once.
#
# Cached for the process and dropped whenever a dataset finishes loading, so a
# second dataset checked in the same run does not pay for it again, and nothing
# can read a listing taken before its own tables landed.
$script:ExakitTableListing = $null

function Clear-ExakitTableListing { $script:ExakitTableListing = $null }

function Get-ExakitTableListing {
    if ($null -eq $script:ExakitTableListing) {
        $script:ExakitTableListing = Get-ExakitQualifiedTables
    }
    return $script:ExakitTableListing
}

function Test-ExakitDatasetLoaded {
    param([Parameter(Mandatory)][hashtable]$Dataset)
    $canonical = "data.datasets.$($Dataset.Id).loaded"
    if ($canonical -eq $Dataset.Flag) { $canonical = "" }
    if ($Dataset.Markers.Count -gt 0) {
        $present = Get-ExakitTableListing
        # $null means the database could not be ASKED - not that it is empty.
        # Falling through to the manifest is what stops an unreachable database
        # from being reported as one with no data in it.
        if ($null -ne $present) {
            foreach ($table in $Dataset.Markers) {
                if (-not $present.ContainsKey("$($Dataset.Schema).$table".ToUpper())) {
                    Sync-ExakitDatasetFlag $Dataset.Flag $false
                    Sync-ExakitDatasetFlag $canonical $false
                    return $false
                }
            }
            Sync-ExakitDatasetFlag $Dataset.Flag $true
            Sync-ExakitDatasetFlag $canonical $true
            return $true
        }
    }
    return ((Get-ExakitManifestValue $Dataset.Flag) -eq $true)
}

# Get-ExakitVerifiedDatasets - the ids of bundled datasets whose marker tables
# are ACTUALLY in the database right now, with the manifest flags healed to
# match. Returns $null when the database cannot be asked, so the caller keeps
# the manifest's answer instead of reporting an empty database.
# twin: exakit_verified_datasets in setup/lib/exapump.sh.
# Get-ExakitQualifiedTables - every table in the database as SCHEMA.TABLE, in
# ONE query.
#
# `exakit status` verifies the bundled datasets against their marker tables.
# Asking per table meant one exapump process per marker - process start, TLS
# handshake, auth, query - and the bundled datasets carry seven markers between
# them, so status took 27 SECONDS on a healthy machine. The shell side has
# always asked once; this is the missing twin of that.
# Returns $null when the query itself fails, which the caller must not confuse
# with "the database has no tables".
# Twin of the single SELECT in exakit_verified_datasets (exapump.sh).
function Get-ExakitQualifiedTables {
    $result = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile,
        "SELECT TABLE_SCHEMA || '.' || TABLE_NAME AS QUALIFIED FROM SYS.EXA_ALL_TABLES")
    if (-not $result.Success) { return $null }
    $set = @{}
    foreach ($line in (("" + $result.Output) -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -match '^([A-Za-z0-9_$]+)\.([A-Za-z0-9_$]+)$') { $set[$t.ToUpper()] = $true }
    }
    return $set
}

function Get-ExakitVerifiedDatasets {
    $datasets = @(Get-ExakitBundledDatasets)
    # THE TABLE LISTING IS THE REACHABILITY PROBE. Asking SELECT 1 first bought
    # no information the listing does not already give, and doubled the cost:
    # every exapump call is a process start, a TLS handshake and an
    # authentication, about 2.5s on a warm machine, so `exakit status` paid ~5s
    # where ~2.5s answers the same question. A listing that comes back proves
    # the database is up, so the cached flag is set from here.
    $present = Get-ExakitQualifiedTables
    if ($null -ne $present) { $script:ExakitDbReachable = $true }
    if ($null -eq $present) {
        # Could not list: unreachable, or the query failed. Ask properly before
        # reporting anything - an empty answer must never be mistaken for an
        # empty database.
        if (-not (Test-ExakitDbReachable)) { return $null }
        # The one query failed. Fall back to the per-table path rather than
        # reporting an empty database off a failed lookup.
        $loaded = @()
        foreach ($dataset in $datasets) {
            if (Test-ExakitDatasetLoaded $dataset) { $loaded += $dataset.Id }
        }
        return ,@($loaded)
    }
    $loaded = @()
    foreach ($dataset in $datasets) {
        $canonical = "data.datasets.$($dataset.Id).loaded"
        if ($canonical -eq $dataset.Flag) { $canonical = "" }
        # No markers declared means nothing to verify - keep the manifest's word
        # rather than silently demoting the dataset to "not loaded".
        if ($dataset.Markers.Count -eq 0) {
            if ((Get-ExakitManifestValue $dataset.Flag) -eq $true) { $loaded += $dataset.Id }
            continue
        }
        $schema = if ($dataset.Schema) { $dataset.Schema } elseif ($env:EXAKIT_SCHEMA) { $env:EXAKIT_SCHEMA } else { "STARTER_KIT" }
        $all = $true
        foreach ($table in $dataset.Markers) {
            if (-not $present.ContainsKey(("$schema.$table").ToUpper())) { $all = $false; break }
        }
        # Same healing the per-table path did: BOTH keys, always, so a
        # destroy+redeploy that left a stale "loaded" flag corrects itself.
        Sync-ExakitDatasetFlag $dataset.Flag $all
        Sync-ExakitDatasetFlag $canonical $all
        if ($all) { $loaded += $dataset.Id }
    }
    return ,@($loaded)
}

# Datasets that are NOT loaded yet - drives the dynamic data menus.
function Get-ExakitPendingDatasets {
    return @(Get-ExakitBundledDatasets | Where-Object { -not (Test-ExakitDatasetLoaded $_) })
}

function Invoke-ExakitDatasetLoad {
    param([Parameter(Mandatory)][string]$KitRoot, [Parameter(Mandatory)][string]$Id, [switch]$Force)
    switch ($Id) {
        "tpch" { Invoke-ExakitSampleDataLoad -KitRoot $KitRoot -Force:$Force }
        default { Invoke-ExakitDatasetDirLoad -KitRoot $KitRoot -Id $Id -Force:$Force }
    }
}

# Invoke-ExakitDatasetDirLoad - generic pipeline for a directory-based bundled
# dataset: schema script, bulk files, optional transform, optional verify,
# then record the manifest flag. Mirrors exakit_load_dataset_dir in exapump.sh.
# Get-ExakitGroupedDigits <n> - 173745 -> 173,745. Worth doing: the row total is
# the one number in a dataset's result line that a reader compares against what
# they were expecting. Invariant culture, so the separator does not follow the
# machine's locale. Twin of exakit_group_digits in exapump.sh.
function Get-ExakitGroupedDigits {
    param([Parameter(Mandatory)][long]$Value)
    return $Value.ToString("N0", [System.Globalization.CultureInfo]::InvariantCulture)
}

# --- weighting a load by what it actually costs ------------------------------
# A dataset is a dozen steps and one of them is most of the wall clock: TPC-H's
# lineitem.csv is fifteen megabytes of twenty-one, so counted as steps the bar
# reached 25% while the file that is 63% of the job was still going.
#
# So the denominator is BYTES. The steps that move no bytes (a schema script,
# the load statements, the verification, the row counts) are worth a nominal
# share each, measured on the same scale.
# Twin of the same block in exapump.sh.
$script:ExakitLoadStepShare = 5          # percent of the byte total, per byteless step
$script:ExakitLoadBytesPerSec = 1048576

function Get-ExakitLoadWeight {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return 0 }
    try { return [long](Get-Item $Path).Length } catch { return 0 }
}

# How long that much weight usually takes, for the creep to fill in with. Only
# ever an estimate, and a safe one: the creep is capped below the next stage, so
# guessing short makes the bar wait and guessing long makes it move slowly.
function Get-ExakitLoadSeconds {
    param([long]$Weight)
    $s = [int]($Weight / $script:ExakitLoadBytesPerSec)
    if ($s -lt 2) { $s = 2 }
    return $s
}

# Set-ExakitLoadStep - the load has reached a new stage: where it is, and where
# this stage ends. Prints nothing; the progress animator is what draws.
function Set-ExakitLoadStep {
    param(
        [long]$DoneWeight, [long]$StepWeight, [long]$TotalWeight,
        [int]$Seconds, [string]$Phase
    )
    $pct = 0; $ceil = 0
    if ($TotalWeight -gt 0) {
        $pct = [int]($DoneWeight * 100 / $TotalWeight)
        $ceil = [int](($DoneWeight + $StepWeight) * 100 / $TotalWeight)
    }
    if ($ceil -gt 100) { $ceil = 100 }
    if ($pct -gt 100) { $pct = 100 }
    # A dataset being loaded from the table reports into its ROW; anything else
    # (a folder, a single named file) still owns the one-line bar.
    if ($script:ExakitTableRow -gt 0) {
        Set-ExakitTableRow -Row $script:ExakitTableRow -State "running" `
            -Pct $pct -Ceiling $ceil -Secs $Seconds -Phase $Phase
        return
    }
    Set-ExakitProgress -Pct $pct -Ceiling $ceil -Secs $Seconds -Phase $Phase
}

function Invoke-ExakitDatasetDirLoad {
    param([Parameter(Mandatory)][string]$KitRoot, [Parameter(Mandatory)][string]$Id, [switch]$Force)
    $dir = Join-Path $KitRoot "data\datasets\$Id"
    $flag = "data.datasets.$Id.loaded"
    # Each dataset loads into its own schema (schema= in dataset.conf, default
    # the id uppercased); the dataset's SQL scripts create and OPEN that schema.
    $schema = $Id.ToUpper()
    $confPath = Join-Path $dir "dataset.conf"
    if (Test-Path $confPath) {
        foreach ($line in (Get-Content $confPath)) {
            if ($line -match '^flag=(.+)$') { $flag = $Matches[1] }
            if ($line -match '^schema=(.+)$') { $schema = $Matches[1] }
        }
    }
    if (-not (Test-Path $dir)) { Fail "Unknown bundled dataset: $Id (no $dir)" }
    if (-not (Get-ExakitManifestValue "components.exapump.profile")) {
        Fail "No exapump connection profile is recorded - the exapump setup step has not completed. Re-run the installer, then retry."
    }
    # Ask the DATABASE, not the manifest. Reading the flag directly here is what
    # let an install that had just replaced the deployment print "already loaded"
    # into a database with no schemas in it, and exit 0.
    $markers = @()
    if (Test-Path $confPath) {
        foreach ($line in (Get-Content $confPath)) {
            if ($line -match '^markers=(.+)$') {
                $markers = @($Matches[1].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
        }
    }
    $probe = @{ Id = $Id; Flag = $flag; Markers = $markers; Schema = $schema }
    if ((-not $Force) -and (Test-ExakitDatasetLoaded $probe)) {
        Ok "Dataset '$Id' already loaded"
        return
    }
    # The table already names the dataset in its own row, so announcing it again
    # would be the same fact twice - and the line would scroll the table.
    if ($script:ExakitTableLive) {
        Write-ExakitLog "INFO" "Loading the '$Id' dataset into schema $schema"
    } else {
        Info "Loading the '$Id' dataset into schema $schema"
    }

    # ONE line for the whole dataset, not one line per file. Loading three
    # bundled datasets used to print about a hundred and thirty lines - every
    # CSV twice, every script twice, eighteen rows of verification CSV and a
    # row-count panel per dataset - and none of it is something the person
    # waiting for a database can act on.
    #
    # The steps are counted up front, so the percentage is a real fraction of
    # the work rather than a guess: the schema script, one per CSV, the load
    # statements, the verification, and the row count at the end.
    # ExakitUploadQuiet silences the narration underneath; the progress line IS
    # the narration now (see Set-ExakitLoadStep). Nothing is lost - every
    # suppressed line still goes to the logfile, including the per-table row
    # counts, and a FAILED verification still prints in full.
    $schemaSql = Join-Path $dir "01_create_schema.sql"
    $loadSql = Join-Path $dir "02_load_data.sql"
    $verifySql = Join-Path $dir "03_verify_setup.sql"
    $csvFiles = @(Get-ChildItem -Path (Join-Path $dir "data\*.csv") -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 0 })
    $bytes = [long]0
    foreach ($csv in $csvFiles) { $bytes += [long]$csv.Length }
    $nominal = [long]($bytes * $script:ExakitLoadStepShare / 100)
    if ($nominal -lt 1) { $nominal = 1 }
    $totalWeight = $bytes + $nominal + $nominal          # + schema + row counts
    if ((Test-Path $loadSql) -and (Get-Item $loadSql).Length -gt 0) { $totalWeight += $nominal }
    if ((Test-Path $verifySql) -and (Get-Item $verifySql).Length -gt 0) { $totalWeight += $nominal }
    $doneWeight = [long]0
    $started = Get-Date
    # Which row of the table this dataset owns, if a table is on screen. Zero
    # means there is none, and the single-line bar takes over.
    $script:ExakitTableRow = 0
    if ($script:ExakitTableLive) { $script:ExakitTableRow = Get-ExakitDataTableRow -Id $Id }
    if ($script:ExakitTableRow -gt 0) {
        Set-ExakitTableRow -Row $script:ExakitTableRow -State "running" `
            -Pct 0 -Ceiling 1 -Secs 2 -Phase "$Id - reading the dataset"
    } else {
        [void](Start-ExakitProgress -Pct 0 -Ceiling 1 -Secs 2 -Phase "$Id - reading the dataset")
    }
    $script:ExakitUploadQuiet = $true
    $tableCount = 0
    $rowTotal = [long]0
    $rowsKnown = $true
    try {

    # Schema script is OPTIONAL: exapump infers column types and creates the
    # table itself when none exists; the script exists to pin exact types and
    # primary keys. Verify the DDL really landed and re-run once if not.
    if ((Test-Path $schemaSql) -and (Get-Item $schemaSql).Length -gt 0) {
        Set-ExakitLoadStep -DoneWeight $doneWeight -StepWeight $nominal -TotalWeight $totalWeight `
            -Seconds 2 -Phase "$Id - creating schema $schema"
        Invoke-ExapumpSqlFile $schemaSql "$Id schema (01_create_schema.sql)" | Out-Null
        if (-not (Test-ExapumpSchemaPresent $schema.ToUpper())) {
            Warn2 "Schema $schema is not present after creation - re-running the schema script"
            Invoke-ExapumpSqlFile $schemaSql "$Id schema (re-run)" | Out-Null
            if (-not (Test-ExapumpSchemaPresent $schema.ToUpper())) {
                Fail "Schema $schema was reported created but does not exist. The database may still be stabilizing; wait a moment and retry: exakit data-load"
            }
        }
    } else {
        Set-ExakitLoadStep -DoneWeight $doneWeight -StepWeight $nominal -TotalWeight $totalWeight `
            -Seconds 2 -Phase "$Id - creating schema $schema"
        $r = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "CREATE SCHEMA IF NOT EXISTS $($schema.ToUpper())")
        if (-not $r.Success) { Fail "Could not create schema $schema." }
    }

    $doneWeight += $nominal
    # Uploads run CONCURRENTLY (see Invoke-ExapumpUploadMany). One launch per
    # file either way - what changes is how many are in flight at once, which is
    # the only lever left: exapump upload cannot target more than one table per
    # call, and the server refuses IMPORT of local files over this protocol.
    if ($csvFiles.Count -gt 0) {
        $uploadFiles = @()
        foreach ($csv in $csvFiles) {
            $uploadFiles += @{
                Path   = $csv.FullName
                Target = "$schema." + [System.IO.Path]::GetFileNameWithoutExtension($csv.Name).ToUpper()
                Name   = $csv.Name
            }
        }
        # ONE segment for the whole upload. The files go up concurrently, so
        # there is no per-file position to report any more - which is fine,
        # because the bytes were never the interesting part of the position. They
        # still set the PACE: the segment spans every byte of the dataset and is
        # expected to take as long as those bytes usually take, so the bar moves
        # across it instead of parking until the last wave lands. The ceiling is
        # where the upload ends, so it cannot overrun into the load statements
        # however long the waves take.
        if ($csvFiles.Count -eq 1) { $unit = "file" } else { $unit = "files" }
        Set-ExakitLoadStep -DoneWeight $doneWeight -StepWeight $bytes -TotalWeight $totalWeight `
            -Seconds (Get-ExakitLoadSeconds $bytes) `
            -Phase "$Id - loading $($csvFiles.Count) data $unit"
        Invoke-ExapumpUploadMany -Files $uploadFiles -Id $Id | Out-Null
        if ($script:ExakitUploadFailures.Count -gt 0) {
            Fail "Upload failed: $($script:ExakitUploadFailures -join '; ') (see log)"
        }
        $doneWeight += $bytes
    }

    if ((Test-Path $loadSql) -and (Get-Item $loadSql).Length -gt 0) {
        Set-ExakitLoadStep -DoneWeight $doneWeight -StepWeight $nominal -TotalWeight $totalWeight `
            -Seconds 3 -Phase "$Id - running load statements"
        Invoke-ExapumpSqlFile $loadSql "$Id load statements (02_load_data.sql)" | Out-Null
        $doneWeight += $nominal
    }

    if ((Test-Path $verifySql) -and (Get-Item $verifySql).Length -gt 0) {
        Set-ExakitLoadStep -DoneWeight $doneWeight -StepWeight $nominal -TotalWeight $totalWeight `
            -Seconds 3 -Phase "$Id - verifying"
        $result = Invoke-ExapumpSqlFileCapture $verifySql
        $doneWeight += $nominal
        # Grade on the STATUS *column value* ",FAIL," - not the bare word. The
        # verify SQL is full of the literal string (the header comment "a 'FAIL'
        # row means..." and 17 "CASE ... ELSE 'FAIL' END" clauses), and exapump
        # echoes that text back, so matching bare "FAIL" fails a dataset even
        # when every row reads OK. A real failing check emits an unquoted STATUS
        # column (check_name,FAIL,detail); OK rows and the echoed SQL never do.
        #
        # Every check is in the logfile whatever the outcome (the capture writes
        # it there); they reach the SCREEN only when one of them failed.
        # Eighteen rows of "OK, 0 orphaned row(s)" say nothing the result line
        # does not already say - a FAIL row says everything.
        if (-not $result.Success -or $result.Output -match ",FAIL,") {
            Stop-ExakitProgress
            if ($script:ExakitTableRow -gt 0) {
                Set-ExakitTableRow -Row $script:ExakitTableRow -State "failed" `
                    -Final "failed $($script:UiMidDot) verification (see log)"
                $script:ExakitTableRow = 0
            }
            # The table has to stop animating before anything is printed over it,
            # or the checks scroll under a repainting frame. Stopped AFTER the row
            # was marked failed, so the frame left on screen says which one it was.
            Stop-ExakitDataTableRun
            $script:ExakitUploadQuiet = $false
            $script:ExakitActiveLabel = ""
            Write-ExapumpOutput -Output $result.Output -Header "Verification failed for dataset '$Id':"
            Fail "Verification failed for dataset '$Id' - see the log. Data is loaded but not marked ready; fix the underlying issue and re-run with -Force."
        }
    }

    # Row-count summary over the dataset's tables (uploaded CSVs + markers).
    $tables = New-Object 'System.Collections.Generic.List[string]'
    foreach ($csv in (Get-ChildItem -Path (Join-Path $dir "data\*.csv") -ErrorAction SilentlyContinue)) {
        $t = [System.IO.Path]::GetFileNameWithoutExtension($csv.Name).ToUpper()
        if (-not $tables.Contains($t)) { [void]$tables.Add($t) }
    }
    if (Test-Path $confPath) {
        foreach ($line in (Get-Content $confPath)) {
            if ($line -match '^markers=(.+)$') {
                foreach ($t in ($Matches[1] -split ',')) {
                    $tu = $t.Trim().ToUpper()
                    if ($tu -and -not $tables.Contains($tu)) { [void]$tables.Add($tu) }
                }
            }
        }
    }
    # The per-table numbers still go to the logfile, exactly as before; what
    # changed is that they no longer take a ten-line panel on screen per
    # dataset. Their totals land in the result line instead, which is the part a
    # reader actually checks against what they expected.
    if ($tables.Count -gt 0) {
        $tableList = $tables
        $schemaName = $schema
        Set-ExakitLoadStep -DoneWeight $doneWeight -StepWeight $nominal -TotalWeight $totalWeight `
            -Seconds 2 -Phase "$Id - counting rows"
        $counted = & {
            $acc = New-Object 'System.Collections.Generic.List[string]'
            # ONE invocation for every table. $batch is $null unless all of
            # them came back, and that sends the loop to the per-table call -
            # so a batch that cannot run costs correctness nothing, only the
            # speed it was meant to buy.
            $batch = Get-ExapumpRowCountMany -Schema $schemaName -Tables $tableList
            foreach ($t in $tableList) {
                if ($null -ne $batch) { $rows = $batch[$t] }
                else { $rows = Get-ExapumpRowCount "$schemaName.$t" }
                if ($rows) { $shown = $rows } else { $shown = "?" }
                $line = "{0,-30} {1} rows" -f "$schemaName.$t", $shown
                if ($script:LogFile) { "DATA  $line" | Add-Content -Path $script:LogFile }
                [void]$acc.Add("$shown")
            }
            return $acc.ToArray()
        }
        foreach ($value in @($counted)) {
            $tableCount++
            if ($value -eq "?") { $rowsKnown = $false } else { $rowTotal += [long]$value }
        }
    }

    } finally {
        # Only the one-line bar is stopped here. A row of the table is not an
        # animation of its own - the table owns the animation and outlives this
        # dataset, because the next one fills in the row underneath.
        if ($script:ExakitTableRow -le 0) { Stop-ExakitProgress }
        $script:ExakitUploadQuiet = $false
        $script:ExakitActiveLabel = ""
    }

    Set-ExakitManifestValue $flag $true
    # Also record the canonical per-dataset key so data.datasets is a complete
    # map even for datasets that keep a legacy flag (TPC-H uses data.loaded for
    # backward compatibility). data.loaded is left untouched for existing installs.
    $canonicalFlag = "data.datasets.$Id.loaded"
    if ($flag -ne $canonicalFlag) { Set-ExakitManifestValue $canonicalFlag $true }
    # RECORDED HERE BECAUSE THEY ARE ALREADY COMPUTED for the result line
    # below. `exakit status` shows a dataset's shape without asking the
    # database at all, which is what keeps that screen instant - counting three
    # datasets live would put two more exapump launches on every status, and
    # process launches are exactly what made the old status slow.
    #
    # They describe the state AS OF THIS LOAD. Anyone who changes these tables
    # behind the kit's back will read stale numbers, which is the price of not
    # querying; `exakit data-load` rewrites them.
    Set-ExakitManifestValue "data.datasets.$Id.schema" $schema
    Set-ExakitManifestValue "data.datasets.$Id.tables" $tableCount
    if ($rowsKnown) { Set-ExakitManifestValue "data.datasets.$Id.rows" $rowTotal }
    Set-ExakitManifestValue "data.last_load.source" "dataset:$Id"
    # This dataset's tables exist now, so any listing taken before it is stale.
    Clear-ExakitTableListing
    $elapsed = [int]((Get-Date) - $started).TotalSeconds
    if ($elapsed -lt 0) { $elapsed = 0 }
    $resultLine = "Dataset '$Id' loaded and verified"
    if ($tableCount -eq 1) { $unit = "table" } else { $unit = "tables" }
    if ($tableCount -gt 0) {
        $resultLine = "$resultLine - $tableCount $unit"
        if ($rowsKnown) { $resultLine = "$resultLine, $(Get-ExakitGroupedDigits $rowTotal) rows" }
    }
    if ($script:ExakitTableRow -gt 0) {
        # Built for the COLUMN, not for a sentence: the row already says which
        # dataset it is, so the prefix goes, and the two numbers are padded to a
        # fixed width so they line up down the table instead of wandering with the
        # length of the text in front of them.
        #
        #   completed - 8 tables, 173,745 rows  (23s)
        #   completed - 2 tables, 108,050 rows   (4s)
        #   completed - 2 tables,  10,970 rows   (2s)
        $cell = "completed $($script:UiMidDot) $tableCount $unit"
        if ($rowsKnown) {
            $cell = "$cell, $((Get-ExakitGroupedDigits $rowTotal).PadLeft(7)) rows"
        }
        $stamp = "({0}s)" -f $elapsed
        $cell = "$cell $($stamp.PadLeft(5))"
        Set-ExakitTableRow -Row $script:ExakitTableRow -State "done" -Final $cell
        Write-ExakitLog "OK" "$resultLine (${elapsed}s)"
        $script:ExakitTableRow = 0
    } else {
        Ok "$resultLine (${elapsed}s)"
    }
}

# --- the datasets table -------------------------------------------------------
# One table for the whole job: the rows you tick are the rows that fill in. See
# the ui_table_* / *-ExakitTable* family in ui.ps1 for the mechanism; what lives
# here is which rows there are and what their Status column says.
# Twin of the same block in exapump.sh.
$script:ExakitTableIds = @()          # the dataset id per row ("" for the rest)
$script:ExakitTableRowLocal = 0
$script:ExakitTableRowSkip = 0
$script:ExakitTableDefaults = @()
$script:ExakitTableGroupFirst = 0
$script:ExakitTableGroupLast = 0
$script:ExakitTableLive = $false      # is the table animating right now
$script:ExakitTableRow = 0            # the row the dataset being loaded owns

# New-ExakitDataTable <final_label> - build the rows, in the order they are
# drawn, and record the defaults / group range / exclusive row the way the
# selection layer expects. Twin of exakit_data_table_build in exapump.sh.
function New-ExakitDataTable {
    param([Parameter(Mandatory)][string]$FinalLabel)
    [void](New-ExakitTable -Title "Datasets to load")
    $ids = New-Object 'System.Collections.Generic.List[string]'
    $defaults = New-Object 'System.Collections.Generic.List[int]'
    $script:ExakitTableGroupFirst = 0
    $script:ExakitTableGroupLast = 0
    $pending = @(Get-ExakitPendingDatasets)
    if ($pending.Count -gt 0) {
        # The group row is itself a checkbox: pre-selected with every dataset;
        # unchecking it clears them all, after which they can be picked
        # individually. Each dataset hangs off it with a tree connector, which the
        # table draws from the palette - the connectors must never be literals in
        # this file, which has no BOM and would be misread byte for byte by
        # Windows PowerShell 5.1 (see tests/ps-encoding-guard.sh).
        [void](Add-ExakitTableRow -Kind "group" -Label "Select All" -Ticked)
        [void]$ids.Add("")
        for ($i = 0; $i -lt $pending.Count; $i++) {
            if ($i -eq $pending.Count - 1) { $kind = "corner" } else { $kind = "tee" }
            # The label loses its trailing "(~175k rows)": the Status column
            # carries the real count when the row finishes, and an estimate beside
            # a measurement is the same fact twice, worse. Only a TRAILING
            # parenthetical goes - "Orders (EU) by quarter" keeps its brackets.
            $label = [regex]::Replace($pending[$i].Label, ' *\([^()]*\)$', '')
            [void](Add-ExakitTableRow -Kind $kind -Label $label -Ticked)
            [void]$ids.Add($pending[$i].Id)
        }
        $script:ExakitTableGroupFirst = 2
        $script:ExakitTableGroupLast = $pending.Count + 1
        for ($i = 1; $i -le ($pending.Count + 1); $i++) { [void]$defaults.Add($i) }
    }
    # The label is NARROWER than the shell twin's on purpose: exapump.ps1 does not
    # route a .json file to the JSON Tables add-on the way exapump.sh does, so
    # naming JSON here would offer what this side cannot do. When that routing
    # lands, widen the label and the assertion in tests/test_sample_data_schema.py
    # together - never the label alone.
    [void](Add-ExakitTableRow -Kind "plain" -Label "A local CSV/Parquet file, or a folder of them")
    [void]$ids.Add("local")
    $script:ExakitTableRowLocal = $ids.Count
    [void](Add-ExakitTableRow -Kind "plain" -Label $FinalLabel)
    [void]$ids.Add("")
    $script:ExakitTableRowSkip = $ids.Count
    # With every bundled dataset already loaded there is nothing to tick but the
    # local-file row, which is the only thing this screen can still do. Enter must
    # never be a no-op.
    if ($pending.Count -eq 0) {
        $defaults.Clear()
        [void]$defaults.Add($script:ExakitTableRowLocal)
    }
    $script:ExakitTableIds = $ids.ToArray()
    $script:ExakitTableDefaults = $defaults.ToArray()
}

# Get-ExakitDataTableRow <dataset-id> - which row that dataset is on, or 0.
# Twin of exakit_data_table_row in exapump.sh.
function Get-ExakitDataTableRow {
    param([Parameter(Mandatory)][string]$Id)
    for ($i = 0; $i -lt $script:ExakitTableIds.Count; $i++) {
        if ($script:ExakitTableIds[$i] -eq $Id) { return $i + 1 }
    }
    return 0
}

# Select-ExakitDataLoad <final_label> - the data-source choice, made in the
# TABLE that will show the progress: every bundled dataset that is not loaded yet
# under a "Select All" group row, then the local-file option, then <final_label>
# as the mutually exclusive opt-out (Cancel/Skip). When every bundled dataset is
# already loaded the group disappears and the local-file row is the default, so
# Enter still does something. Returns a string array of ids ("tpch", "local") or
# @("none"). Twin of exakit_data_load_select in exapump.sh.
function Select-ExakitDataLoad {
    param([Parameter(Mandatory)][string]$FinalLabel)
    # EXAKIT_DATA_FILE mirrors the EXAKIT_DATASETS contract: naming a file IS
    # choosing the local-file option, so the table never draws. The path (and
    # EXAKIT_DATA_TABLE) are consumed by Import-ExakitLocalFile as its answers.
    if ($env:EXAKIT_DATA_FILE) {
        Info "Loading a local file (EXAKIT_DATA_FILE)."
        # No table was built, so nothing may animate one. The row ids ARE that
        # signal, the way an empty EXAKIT_TABLE_STATE is on the shell side.
        $script:ExakitTableIds = @()
        return @("local")
    }
    New-ExakitDataTable -FinalLabel $FinalLabel
    # The local-file row being row 1 means there was no group above it, which
    # means nothing is pending.
    if ($script:ExakitTableRowLocal -eq 1) {
        Info "Every bundled dataset is already loaded (reload with: exakit data-load -Force)."
    }
    $groupParent = 0
    if ($script:ExakitTableGroupFirst -gt 0) { $groupParent = 1 }
    Write-Host ""
    $selection = @(Invoke-ExakitTableMenu -Defaults $script:ExakitTableDefaults `
        -ExclusiveIndex $script:ExakitTableRowSkip `
        -GroupParent $groupParent -GroupFirst $script:ExakitTableGroupFirst `
        -GroupLast $script:ExakitTableGroupLast -GroupMode "all")
    if ($selection -contains $script:ExakitTableRowSkip) { return @("none") }
    $chosen = New-Object 'System.Collections.Generic.List[string]'
    foreach ($row in $selection) {
        if ($row -lt 1 -or $row -gt $script:ExakitTableIds.Count) { continue }
        $id = $script:ExakitTableIds[$row - 1]
        # The group row and the opt-out carry no id: they are answers about the
        # other rows, not data sources of their own.
        if ($id -and -not $chosen.Contains($id)) { [void]$chosen.Add($id) }
    }
    if ($chosen.Count -eq 0) { return @("none") }
    return $chosen.ToArray()
}

function Show-ExakitDataLoadMenu {
    if (-not (Get-ExakitManifestValue "components.exapump.profile")) {
        Fail "No exapump connection profile is recorded - re-run the installer, then retry."
    }
    $chosen = Select-ExakitDataLoad -FinalLabel "Skip"
    if ($chosen -contains "none") {
        Info "Data loading cancelled."
        return
    }
    Start-ExakitDataTableRun
    try {
        foreach ($id in $chosen) {
            if ($id -eq "local") {
                Stop-ExakitDataTableRun
                $result = Import-ExakitLocalFile
                if ($result -eq "back") { Info "Local file load skipped. Run it any time with: exakit data-load" }
            } else {
                $kitRoot = Get-ExakitRepoRoot
                if (-not $kitRoot) { Fail "Could not find the kit's sql/ and data/ files to load." }
                Invoke-ExakitDatasetLoad -KitRoot $kitRoot -Id $id
            }
        }
    } finally {
        Stop-ExakitDataTableRun
    }
}

# Start-ExakitDataTableRun / Stop-ExakitDataTableRun - the same table the
# selection was made in now becomes the progress display: the rows do not move,
# so nobody has to map one screen onto another. It animates only where there is a
# console to animate on; everywhere else the loaders narrate in plain lines
# exactly as they did before.
#
# Both entry points into a load - the standalone `exakit data-load` and the
# installer's offer - have to drive it. That is the gap the shell side shipped
# with: only the standalone command started the table, so during an install it
# drew, stayed empty, and every dataset fell back to the single-line bar.
function Start-ExakitDataTableRun {
    $script:ExakitTableRow = 0
    $script:ExakitTableLive = $false
    # No rows means no table was built for this run (EXAKIT_DATA_FILE answers the
    # screen without drawing one), and an empty box animating over nothing is
    # worse than no box. Twin of the `[ -n "$EXAKIT_TABLE_STATE" ]` guard.
    if ($script:ExakitTableIds.Count -lt 1) { return }
    $script:ExakitTableLive = [bool](Start-ExakitTable)
}
function Stop-ExakitDataTableRun {
    # A prompt cannot share the screen with a repainting frame, so the local-file
    # branch stops the table before it asks anything - which is also why this is
    # safe to call more than once.
    if (-not $script:ExakitTableLive) { return }
    Stop-ExakitTable
    $script:ExakitTableLive = $false
    $script:ExakitTableRow = 0
}

# Invoke-ExakitSampleDataLoad <kit_root> [-Force] - the TPC-H sample-data
# entry point, kept for its long-standing callers (the installer offer,
# `exakit data-load -Force`, and setup-windows-docker.ps1). TPC-H now lives in
# data\datasets\tpch like every other bundled dataset, so this simply
# delegates to the generic directory pipeline.
function Invoke-ExakitSampleDataLoad {
    param([Parameter(Mandatory)][string]$KitRoot, [switch]$Force)
    Invoke-ExakitDatasetDirLoad -KitRoot $KitRoot -Id "tpch" -Force:$Force
}

# Request-ExakitDataLoadOffer <kit_root> - interactively offer the guided
# data loading menu during install. Non-interactive installs print the
# follow-up command and continue. Runs in a try/catch so a Fail() inside the
# loading flow (which calls exit) is still contained by the caller... note:
# unlike bash's subshell isolation, PowerShell's exit terminates the whole
# process, so callers that must survive a failed load run this in a child
# pwsh process instead (see setup-windows-docker.ps1).
function Request-ExakitDataLoadOffer {
    param([Parameter(Mandatory)][string]$KitRoot)

    # EXAKIT_DATASETS names bundled datasets directly (csv of ids from
    # data\datasets\<id>\, e.g. "tpch,weather") so an agent-driven or scripted
    # install picks an exact selection without a tty. Unknown ids warn and are
    # skipped; if none are valid the load fails. EXAKIT_DATASETS takes
    # precedence over EXAKIT_LOAD_SAMPLE. Twin of exakit_maybe_offer_data_load
    # in common.sh - the .ps1 path used to ignore these documented vars.
    if ($env:EXAKIT_DATASETS) {
        $knownIds = @(Get-ExakitBundledDatasets | ForEach-Object { $_.Id })
        $validAny = $false
        foreach ($envId in ($env:EXAKIT_DATASETS -split ',')) {
            $envId = $envId.Trim()
            if (-not $envId) { continue }
            if ($knownIds -contains $envId) {
                $validAny = $true
                Info "Loading dataset '$envId' (EXAKIT_DATASETS)."
                Invoke-ExakitDatasetLoad -KitRoot $KitRoot -Id $envId
            } else {
                Warn2 "Unknown dataset id '$envId' in EXAKIT_DATASETS (available: $($knownIds -join ', '))."
            }
        }
        if (-not $validAny) { Fail "EXAKIT_DATASETS='$($env:EXAKIT_DATASETS)' matched no bundled dataset - nothing was loaded." }
        return
    }

    # EXAKIT_LOAD_SAMPLE decides up front: =0 skips data loading entirely, =1
    # loads the bundled TPC-H sample without asking. Twin of common.sh.
    if ($env:EXAKIT_LOAD_SAMPLE -eq "0") {
        Info "Skipping data loading (EXAKIT_LOAD_SAMPLE=0). Run it any time with: exakit data-load"
        return
    }
    if ($env:EXAKIT_LOAD_SAMPLE -eq "1") {
        Info "Loading the bundled sample data (EXAKIT_LOAD_SAMPLE=1)."
        Invoke-ExakitSampleDataLoad -KitRoot $KitRoot
        return
    }

    # Dynamic dataset checkbox (shared with `exakit data-load`): only bundled
    # datasets that are not loaded yet are offered, pre-selected, plus the
    # local-file option and an explicit skip. Non-interactive installs keep
    # the pre-selected defaults.
    Info "The database is ready for data. Loading data now lets MCP validate against real tables."
    $chosen = Select-ExakitDataLoad -FinalLabel "Skip"
    if ($chosen -contains "none") {
        Info "Skipping data loading. Run it any time with: exakit data-load"
        return
    }
    Start-ExakitDataTableRun
    try {
        foreach ($id in $chosen) {
            if ($id -eq "local") {
                Stop-ExakitDataTableRun
                $result = Import-ExakitLocalFile
                if ($result -eq "back") { Info "Local file load skipped. Run it any time with: exakit data-load" }
            } else {
                Invoke-ExakitDatasetLoad -KitRoot $KitRoot -Id $id
            }
        }
    } finally {
        Stop-ExakitDataTableRun
    }
}
