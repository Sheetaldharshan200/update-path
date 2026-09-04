# exasol-scheduler.ps1 - Exasol Scheduler (table-driven SQL jobs): Windows
# counterpart of exasol-scheduler.sh.
#
# A MARKETPLACE ADD-ON: never installed by the setup scripts. See the shell
# twin's header for the full design; the properties that shape both sides:
#
#   - SCHED_TASKS is a CODE-EXECUTION SURFACE, so the scheduler runs as a
#     dedicated SCHEDULER_SVC database user, never the admin. Bootstrap
#     privileges (CREATE SCHEMA / CREATE TABLE) are granted for first startup
#     and revoked by validate once the schema exists.
#   - The engine EXITS on fatal errors; the launcher supervises it (restart
#     with backoff, crash-loop stop), waits for the database at login, and
#     refuses a second copy - two pollers on one task table run every job
#     twice.
#   - Missed occurrences are never replayed; the help page says so.
#
# Windows x86_64 is fully supported - upstream ships a prebuilt engine and no
# shim is needed (the binary is invoked directly, unlike json-tables' cargo
# indirection). Windows ARM64 has no published engine yet.

$script:ExasolSchedulerVersionFallback = if ($env:EXAKIT_EXASOL_SCHEDULER_VERSION_FALLBACK) { $env:EXAKIT_EXASOL_SCHEDULER_VERSION_FALLBACK } else { "v0.2" }
$script:ExasolSchedulerVersion = if ($env:EXAKIT_EXASOL_SCHEDULER_VERSION) { $env:EXAKIT_EXASOL_SCHEDULER_VERSION } else { "" }
$script:ExasolSchedulerRepo = if ($env:EXAKIT_EXASOL_SCHEDULER_REPO) { $env:EXAKIT_EXASOL_SCHEDULER_REPO } else { "exasol-labs/exasol-scheduler" }
$script:ExasolSchedulerReleaseTag = if ($env:EXAKIT_EXASOL_SCHEDULER_RELEASE_TAG) { $env:EXAKIT_EXASOL_SCHEDULER_RELEASE_TAG } else { "" }
$script:ExasolSchedulerDbUser = if ($env:EXAKIT_EXASOL_SCHEDULER_USER) { $env:EXAKIT_EXASOL_SCHEDULER_USER } else { "scheduler_svc" }
$script:ExasolSchedulerSchema = if ($env:EXAKIT_EXASOL_SCHEDULER_SCHEMA) { $env:EXAKIT_EXASOL_SCHEDULER_SCHEMA } else { "SCHED" }

function Get-ExasolSchedulerHome {
    return (Join-Path $script:ExakitHome "exasol-scheduler")
}

function Get-ExasolSchedulerEnginePath {
    return (Join-Path (Join-Path (Get-ExasolSchedulerHome) "libexec") "exasol_scheduler.exe")
}

function Get-ExasolSchedulerLauncherPath {
    return (Join-Path $script:BinDir "exasol-scheduler.ps1")
}

function Get-ExasolSchedulerPidFile {
    return (Join-Path (Get-ExasolSchedulerHome) "exasol-scheduler.pid")
}

function Get-ExasolSchedulerLogPath {
    return (Join-Path $script:LogDir "exasol-scheduler.log")
}

function Get-ExasolSchedulerCredentialPath {
    return (Join-Path $script:CredsDir "exasol_scheduler_password")
}

# --- version + release resolution -------------------------------------------

# Deliberately the version versions.json ADVERTISES: only a build the pkg
# workflow has published and pinned is installable. Twin of
# exasol_scheduler_latest.
function Get-ExasolSchedulerLatest {
    $advertised = Get-ExakitVersionsValue "components.exasol-scheduler.version"
    if ($advertised) { return $advertised }
    return $script:ExasolSchedulerVersionFallback
}

function Get-ExasolSchedulerTargetVersion {
    if ($script:ExasolSchedulerVersion) { return $script:ExasolSchedulerVersion }
    return (Get-ExasolSchedulerLatest)
}

function Test-ExasolSchedulerPinApplies {
    if ($script:ExasolSchedulerReleaseTag) { return $false }
    if (-not $script:ExasolSchedulerVersion) { return $true }
    $advertised = Get-ExakitVersionsValue "components.exasol-scheduler.version"
    return ($advertised -and $advertised -eq $script:ExasolSchedulerVersion)
}

function Get-ExasolSchedulerMirrorRepo {
    if ($env:EXAKIT_EXASOL_SCHEDULER_MIRROR_REPO) { return $env:EXAKIT_EXASOL_SCHEDULER_MIRROR_REPO }
    $source = Get-ExakitManifestValue "kit.source"
    if ($source -and $source -match "^([^@]+/[^@]+)@") { return $Matches[1] }
    return $script:KitRepo
}

function Get-ExasolSchedulerReleaseTag {
    if ($script:ExasolSchedulerReleaseTag) { return $script:ExasolSchedulerReleaseTag }
    if (Test-ExasolSchedulerPinApplies) {
        $pin = Get-ExakitVersionsValue "components.exasol-scheduler.release"
        if ($pin) { return $pin }
    }
    return ("exasol-scheduler-" + (Get-ExasolSchedulerTargetVersion))
}

# --- platform ----------------------------------------------------------------

# The engine built for THIS machine, by the kit release's own naming (bare
# binaries, repackaged by the pkg workflow). Twin of exasol_scheduler_asset.
function Get-ExasolSchedulerAsset {
    if ((Get-ExakitHostArch) -eq "arm64") { return "" }
    return "exasol-scheduler-windows-x86_64.exe"
}

function Test-ExasolSchedulerApplicable {
    return ((Get-ExasolSchedulerAsset) -ne "")
}

function Get-ExasolSchedulerApplicableReason {
    return "no prebuilt scheduler binary is published for this platform (windows/arm64). Windows x86_64, macOS and Linux are supported."
}

# A copy the user installed themselves is respected, never managed.
function Get-ExasolSchedulerSystemPresent {
    $found = Get-Command "exasol_scheduler" -ErrorAction SilentlyContinue
    if ($found -and $found.Source -and $found.Source -ne (Get-ExasolSchedulerEnginePath)) { return $true }
    return $false
}

function Get-ExasolSchedulerInstalledVersion {
    if (-not (Test-Path (Get-ExasolSchedulerEnginePath))) { return "" }
    $recorded = Get-ExakitManifestValue "components.exasol_scheduler.version"
    if ($recorded) { return $recorded }
    return ""
}

# --- verified download --------------------------------------------------------

function Get-ExasolSchedulerAssetUrl {
    param([Parameter(Mandatory)][string]$Asset)
    return ("https://github.com/" + (Get-ExasolSchedulerMirrorRepo) + "/releases/download/" + (Get-ExasolSchedulerReleaseTag) + "/" + $Asset)
}

# Pinned first (versions.json cannot be rate limited), else the digest GitHub
# publishes for the asset on the release being installed. An unverifiable
# download is refused. Twin of _exasol_scheduler_digest.
function Get-ExasolSchedulerDigest {
    param([Parameter(Mandatory)][string]$Asset)
    $key = $Asset -replace "^exasol-scheduler-", "" -replace "\.exe$", ""
    if (Test-ExasolSchedulerPinApplies) {
        $pin = Get-ExakitVersionsValue ("components.exasol-scheduler.sha256." + $key)
        if ($pin) { return $pin.ToLower() }
    }
    try {
        $headers = @{}
        if ($env:GITHUB_TOKEN) { $headers["Authorization"] = "Bearer $($env:GITHUB_TOKEN)" }
        $api = "https://api.github.com/repos/" + (Get-ExasolSchedulerMirrorRepo) + "/releases/tags/" + (Get-ExasolSchedulerReleaseTag)
        $doc = Invoke-RestMethod -Uri $api -Headers $headers -TimeoutSec 30
        foreach ($entry in $doc.assets) {
            if ($entry.name -eq $Asset -and $entry.digest -and $entry.digest.StartsWith("sha256:")) {
                return $entry.digest.Substring(7).ToLower()
            }
        }
    } catch { }
    return ""
}

function Get-ExasolSchedulerVerifiedAsset {
    param([Parameter(Mandatory)][string]$Asset, [Parameter(Mandatory)][string]$Destination)
    $url = Get-ExasolSchedulerAssetUrl -Asset $Asset
    Info "Downloading $Asset"
    try {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 -Uri $url -OutFile $Destination
    } catch {
        Warn2 "Download failed: $url ($_)"
        return $false
    }
    $expected = Get-ExasolSchedulerDigest -Asset $Asset
    if (-not $expected) {
        Remove-Item -Force -ErrorAction SilentlyContinue $Destination
        Warn2 "No checksum is available for $Asset; refusing an unverified artifact."
        return $false
    }
    $actual = (Get-FileHash -Algorithm SHA256 -Path $Destination).Hash.ToLower()
    if ($actual -ne $expected) {
        Remove-Item -Force -ErrorAction SilentlyContinue $Destination
        Warn2 "Checksum mismatch for $Asset (expected $expected, got $actual)"
        return $false
    }
    Ok "Checksum verified: $Asset"
    return $true
}

# --- the dedicated database user ----------------------------------------------

function Invoke-ExasolSchedulerSql {
    param([Parameter(Mandatory)][string]$Sql)
    # SQL over stdin, never argv: CREATE/ALTER USER carries a password, and an
    # argv is visible to every local process for the life of the call.
    $result = ($Sql | & (Get-ExapumpBinPath) sql -p $script:ExapumpProfile 2>&1)
    return @{ Success = ($LASTEXITCODE -eq 0); Output = ($result | Out-String) }
}

function Confirm-ExasolSchedulerDbUser {
    $password = Read-ExakitCredential "exasol_scheduler_password"
    if (-not (Test-ExakitSqlPasswordToken $password)) {
        $password = New-ExakitSqlPasswordToken
        Save-ExakitCredential "exasol_scheduler_password" $password
    }
    $userUc = $script:ExasolSchedulerDbUser.ToUpperInvariant()
    $probe = Invoke-ExasolSchedulerSql ("SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_USERS WHERE USER_NAME = '" + $userUc + "') THEN 'EXAKIT_SCHED_USER_PRESENT' ELSE 'EXAKIT_SCHED_USER_MISSING' END AS STATUS")
    if ($probe.Success -and $probe.Output.Contains("EXAKIT_SCHED_USER_PRESENT")) {
        $rotate = Invoke-ExasolSchedulerSql ("ALTER USER " + $userUc + " IDENTIFIED BY " + $password)
        if (-not $rotate.Success) { Warn2 "Could not rotate the scheduler database user's password."; return $false }
    } else {
        Info ("Creating the dedicated scheduler database user (" + $script:ExasolSchedulerDbUser + ")")
        $create = Invoke-ExasolSchedulerSql ("CREATE USER " + $userUc + " IDENTIFIED BY " + $password)
        if (-not $create.Success) { Warn2 "Could not create the scheduler database user."; return $false }
    }
    foreach ($grant in @("CREATE SESSION", "CREATE SCHEMA", "CREATE TABLE")) {
        $granted = Invoke-ExasolSchedulerSql ("GRANT " + $grant + " TO " + $userUc)
        if (-not $granted.Success) { Warn2 ("Could not grant " + $grant + " to " + $userUc); return $false }
    }
    return $true
}

function Test-ExasolSchedulerSchemaExists {
    $schemaUc = $script:ExasolSchedulerSchema.ToUpperInvariant()
    $probe = Invoke-ExasolSchedulerSql ("SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_SCHEMAS WHERE SCHEMA_NAME = '" + $schemaUc + "') THEN 'EXAKIT_SCHED_SCHEMA_PRESENT' ELSE 'EXAKIT_SCHED_SCHEMA_MISSING' END AS STATUS")
    return ($probe.Success -and $probe.Output.Contains("EXAKIT_SCHED_SCHEMA_PRESENT"))
}

# Bootstrap-then-revoke, upstream's least-privilege posture. Failures are
# logged, never fatal - REVOKE of a privilege already gone errors.
function Revoke-ExasolSchedulerBootstrap {
    if ((Get-ExakitManifestValue "components.exasol_scheduler.bootstrap_revoked") -eq "true") { return }
    $userUc = $script:ExasolSchedulerDbUser.ToUpperInvariant()
    [void](Invoke-ExasolSchedulerSql ("REVOKE CREATE SCHEMA FROM " + $userUc))
    [void](Invoke-ExasolSchedulerSql ("REVOKE CREATE TABLE FROM " + $userUc))
    Set-ExakitManifestValue "components.exasol_scheduler.bootstrap_revoked" "true"
    Ok ("Bootstrap privileges revoked from " + $script:ExasolSchedulerDbUser + " (schema exists; upstream's least-privilege posture)")
}

# --- launcher -----------------------------------------------------------------

# The launcher IS the supervisor: singleton pidfile guard, bounded database
# wait, restart with backoff, crash-loop stop. Only the PATH of the credential
# file is baked in; the password is read at RUN time into the environment.
function Write-ExasolSchedulerLauncher {
    $home2 = Get-ExasolSchedulerHome
    New-Item -ItemType Directory -Force -Path $script:BinDir, $home2 | Out-Null
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    $dbHost = "127.0.0.1"; $dbPort = "8563"
    if ($dsn -and $dsn.Contains(":")) {
        $dbHost = $dsn.Split(":")[0]
        $dbPort = $dsn.Split(":")[1]
    }
    $lines = @(
        '# exasol-scheduler launcher - generated by the Exasol Personal Local Starter Kit.'
        '# Supervises the scheduler engine: waits for the database, restarts on failure,'
        '# refuses a second copy, stops on a crash loop. Regenerated by exakit update.'
        '$pidFile = "' + (Get-ExasolSchedulerPidFile) + '"'
        '$engine  = "' + (Get-ExasolSchedulerEnginePath) + '"'
        '$pwFile  = "' + (Get-ExasolSchedulerCredentialPath) + '"'
        'if (Test-Path $pidFile) {'
        '    $old = Get-Content $pidFile -ErrorAction SilentlyContinue'
        '    if ($old -match "^[0-9]+$" -and (Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue)) {'
        '        Write-Host "exasol-scheduler is already running (pid $old)."'
        '        Write-Host "One instance per task table: a second poller would run every job twice."'
        '        exit 0'
        '    }'
        '}'
        'Set-Content -Path $pidFile -Value $PID'
        'try {'
        '    if (-not $env:EXA_HOST) { $env:EXA_HOST = "' + $dbHost + '" }'
        '    if (-not $env:EXA_PORT) { $env:EXA_PORT = "' + $dbPort + '" }'
        '    if (-not $env:EXA_USER) { $env:EXA_USER = "' + $script:ExasolSchedulerDbUser + '" }'
        '    if (-not $env:EXA_TLS) { $env:EXA_TLS = "true" }'
        '    if (-not $env:EXA_VALIDATE_SERVER_CERT) { $env:EXA_VALIDATE_SERVER_CERT = "false" }'
        '    if (-not $env:EXA_SCHEMA) { $env:EXA_SCHEMA = "' + $script:ExasolSchedulerSchema + '" }'
        '    if (-not $env:EXA_PASSWORD) {'
        '        if (-not (Test-Path $pwFile)) {'
        '            Write-Error "exasol-scheduler: credential file missing: $pwFile (repair: exakit update exasol-scheduler)"'
        '            exit 1'
        '        }'
        '        $env:EXA_PASSWORD = (Get-Content -Raw $pwFile).Trim()'
        '    }'
        '    # Wait for the database, bounded: at login the boot entries race.'
        '    $waited = 0'
        '    while ($waited -lt 120) {'
        '        $probe = Test-NetConnection -ComputerName $env:EXA_HOST -Port ([int]$env:EXA_PORT) -WarningAction SilentlyContinue'
        '        if ($probe.TcpTestSucceeded) { break }'
        '        Start-Sleep -Seconds 3'
        '        $waited += 3'
        '    }'
        '    # Supervise: restart on failure with backoff, stop on a crash loop.'
        '    $fails = 0'
        '    while ($true) {'
        '        $t0 = Get-Date'
        '        & $engine'
        '        $rc = $LASTEXITCODE'
        '        if ($rc -eq 0) { exit 0 }'
        '        if (((Get-Date) - $t0).TotalSeconds -lt 60) { $fails += 1 } else { $fails = 1 }'
        '        if ($fails -ge 5) {'
        '            Write-Error "exasol-scheduler: engine failed $fails times in quick succession (last exit $rc) - giving up. Diagnose: exakit logs exasol-scheduler"'
        '            exit $rc'
        '        }'
        '        Write-Host "exasol-scheduler: engine exited ($rc) - restarting in 5s (attempt $fails/5)"'
        '        Start-Sleep -Seconds 5'
        '    }'
        '} finally {'
        '    Remove-Item -Force -ErrorAction SilentlyContinue $pidFile'
        '}'
    )
    Set-Content -Path (Get-ExasolSchedulerLauncherPath) -Value ($lines -join "`r`n") -Encoding ASCII
    return $true
}

# --- install / validate / lifecycle -------------------------------------------

function Write-ExasolSchedulerNotInstalled {
    param([Parameter(Mandatory)][string]$Reason)
    Warn2 ("exasol-scheduler was not installed: " + $Reason)
    Warn2 "Everything else in the kit is unaffected. Retry with: exakit update exasol-scheduler"
    if (Get-Command Set-ExakitFailureReason -ErrorAction SilentlyContinue) {
        Set-ExakitFailureReason ("exasol-scheduler: " + $Reason)
    }
    Set-ExakitManifestValue "components.exasol_scheduler.validated" "false"
    return $false
}

function Install-ExasolScheduler {
    if (-not (Test-ExasolSchedulerApplicable)) {
        return (Write-ExasolSchedulerNotInstalled (Get-ExasolSchedulerApplicableReason))
    }
    $version = Get-ExasolSchedulerTargetVersion
    $current = Get-ExasolSchedulerInstalledVersion
    if ($env:EXAKIT_FORCE_COMPONENT_INSTALL -ne "1" -and $current -and $current -eq $version) {
        Ok ("exasol-scheduler " + $current + " is already installed")
        return $true
    }
    Info ("Installing exasol-scheduler " + $version + " (prebuilt - table-driven SQL job scheduling)")
    $asset = Get-ExasolSchedulerAsset
    $libexec = Join-Path (Get-ExasolSchedulerHome) "libexec"
    New-Item -ItemType Directory -Force -Path $libexec | Out-Null
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-scheduler-" + [guid]::NewGuid().ToString("N") + ".exe")
    if (-not (Get-ExasolSchedulerVerifiedAsset -Asset $asset -Destination $tmp)) {
        return (Write-ExasolSchedulerNotInstalled ("the prebuilt scheduler binary (" + $asset + ") could not be downloaded or verified (see log)"))
    }
    Move-Item -Force $tmp (Get-ExasolSchedulerEnginePath)
    & (Get-ExasolSchedulerEnginePath) --help *> $null
    if ($LASTEXITCODE -ne 0) {
        return (Write-ExasolSchedulerNotInstalled "the prebuilt engine does not run on this machine (unsigned-binary policy? see log)")
    }
    if (-not (Confirm-ExasolSchedulerDbUser)) {
        return (Write-ExasolSchedulerNotInstalled "the dedicated database user could not be created - is the database running? (exakit start)")
    }
    if (-not (Write-ExasolSchedulerLauncher)) {
        return (Write-ExasolSchedulerNotInstalled "the launcher could not be written")
    }
    Set-ExakitManifestValue "components.exasol_scheduler.version" $version
    Set-ExakitManifestValue "components.exasol_scheduler.engine" (Get-ExasolSchedulerEnginePath)
    Set-ExakitManifestValue "components.exasol_scheduler.db_user" $script:ExasolSchedulerDbUser
    Set-ExakitManifestValue "components.exasol_scheduler.schema" $script:ExasolSchedulerSchema
    Set-ExakitManifestValue "components.exasol_scheduler.bootstrap_revoked" "false"
    Ok ("exasol-scheduler " + $version + " installed")
    return $true
}

function Test-ExasolScheduler {
    if (-not (Test-Path (Get-ExasolSchedulerEnginePath))) {
        Warn2 "exasol-scheduler is not installed."
        return $false
    }
    if (-not (Start-ExasolScheduler)) { return $false }
    Info ("Waiting for the scheduler to bootstrap its schema (" + $script:ExasolSchedulerSchema + ")")
    $waited = 0
    while ($waited -lt 60) {
        if (Test-ExasolSchedulerSchemaExists) {
            Revoke-ExasolSchedulerBootstrap
            Set-ExakitManifestValue "components.exasol_scheduler.validated" "true"
            Ok ("exasol-scheduler is running and its schema exists - define jobs in " + $script:ExasolSchedulerSchema + ".SCHED_TASKS")
            return $true
        }
        Start-Sleep -Seconds 3
        $waited += 3
    }
    Warn2 "The scheduler is running but its schema has not appeared yet - check: exakit logs exasol-scheduler"
    return $false
}

function Get-ExasolSchedulerProcessIds {
    $pids = @()
    $pidFile = Get-ExasolSchedulerPidFile
    if (Test-Path $pidFile) {
        $recorded = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($recorded -match "^[0-9]+$" -and (Get-Process -Id ([int]$recorded) -ErrorAction SilentlyContinue)) {
            $pids += [int]$recorded
        }
    }
    foreach ($proc in (Get-Process -Name "exasol_scheduler" -ErrorAction SilentlyContinue)) {
        if ($pids -notcontains $proc.Id) { $pids += $proc.Id }
    }
    return $pids
}

function Get-ExasolSchedulerStatus {
    if (-not (Test-Path (Get-ExasolSchedulerLauncherPath))) { return "not installed" }
    if ((Get-ExasolSchedulerProcessIds).Count -gt 0) { return "running" }
    return "stopped"
}

function Start-ExasolScheduler {
    if (-not (Test-Path (Get-ExasolSchedulerLauncherPath))) {
        Warn2 "exasol-scheduler is not installed - add it with: exakit marketplace"
        return $false
    }
    if ((Get-ExasolSchedulerProcessIds).Count -gt 0) {
        Ok "exasol-scheduler is already running"
        return $true
    }
    New-Item -ItemType Directory -Force -Path (Get-ExasolSchedulerHome), $script:LogDir | Out-Null
    Info "Starting exasol-scheduler"
    Start-Process -WindowStyle Hidden -FilePath "powershell.exe" `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Get-ExasolSchedulerLauncherPath)) `
        -RedirectStandardOutput (Get-ExasolSchedulerLogPath) `
        -RedirectStandardError ((Get-ExasolSchedulerLogPath) + ".err") | Out-Null
    Start-Sleep -Seconds 2
    if ((Get-ExasolSchedulerProcessIds).Count -gt 0) {
        Ok ("exasol-scheduler is running (jobs live in " + $script:ExasolSchedulerSchema + ".SCHED_TASKS)")
        return $true
    }
    Warn2 ("exasol-scheduler did not stay up - see " + (Get-ExasolSchedulerLogPath))
    return $false
}

function Stop-ExasolScheduler {
    $pids = Get-ExasolSchedulerProcessIds
    if ($pids.Count -eq 0) {
        Ok "exasol-scheduler is already stopped"
        Remove-Item -Force -ErrorAction SilentlyContinue (Get-ExasolSchedulerPidFile)
        return $true
    }
    Info "Stopping exasol-scheduler"
    foreach ($procId in $pids) {
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Force -ErrorAction SilentlyContinue (Get-ExasolSchedulerPidFile)
    Ok "exasol-scheduler stopped (missed occurrences are not replayed on restart)"
    return $true
}

function Get-ExasolSchedulerAutostartCommand {
    return ('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Get-ExasolSchedulerLauncherPath) + '"')
}

function Get-ExasolSchedulerSummary {
    return ("SQL jobs in " + $script:ExasolSchedulerSchema + ".SCHED_TASKS")
}

function Uninstall-ExasolScheduler {
    param([switch]$DryRun)
    if (-not $DryRun) { [void](Stop-ExasolScheduler) }
    $targets = @((Get-ExasolSchedulerHome), (Get-ExasolSchedulerLauncherPath), (Get-ExasolSchedulerCredentialPath))
    foreach ($path in $targets) {
        if (-not (Test-Path $path)) { continue }
        if ($DryRun) {
            Info ("  will remove: " + $path)
        } else {
            Info ("Removing " + $path)
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $path
        }
    }
    if ($DryRun) {
        Info ("  will drop:   database user " + $script:ExasolSchedulerDbUser + " (the " + $script:ExasolSchedulerSchema + " schema and its history stay - they are your data)")
        return $true
    }
    # Kit-created user whose credential is being deleted; the schema it
    # bootstrapped holds the user's job definitions and history, so that stays.
    [void](Invoke-ExasolSchedulerSql ("DROP USER " + $script:ExasolSchedulerDbUser.ToUpperInvariant()))
    Remove-ExakitManifestValue "components.exasol_scheduler"
    Remove-ExakitManifestValue "desired.exasol_scheduler"
    Ok ("exasol-scheduler removed - the " + $script:ExasolSchedulerSchema + " schema (your job definitions and history) was left in the database. Reinstall any time with: exakit marketplace")
    return $true
}

function Update-ExasolScheduler {
    $available = Get-ExakitComponentAvailable "exasol-scheduler"
    if (-not $available) { Fail "Could not resolve the advertised exasol-scheduler version." }
    $current = Get-ExasolSchedulerInstalledVersion
    if ($current -and $current -eq $available) {
        [void](Write-ExasolSchedulerLauncher)
        Ok ("exasol-scheduler is already current (" + $current + ")")
        return $true
    }
    Info ("Updating exasol-scheduler " + $(if ($current) { $current } else { "not installed" }) + " -> " + $available)
    $wasRunning = ((Get-ExasolSchedulerProcessIds).Count -gt 0)
    if ($wasRunning) { [void](Stop-ExasolScheduler) }
    $script:ExasolSchedulerVersion = $available
    $env:EXAKIT_FORCE_COMPONENT_INSTALL = "1"
    try {
        if (-not (Install-ExasolScheduler)) {
            Fail "exasol-scheduler could not be installed - see the warning above and the log."
        }
    } finally {
        $env:EXAKIT_FORCE_COMPONENT_INSTALL = ""
    }
    if ($wasRunning) { [void](Test-ExasolScheduler) }
    Set-ExakitManifestValue "desired.exasol_scheduler" $available
    Ok "exasol-scheduler updated; your job definitions and history were not changed"
    return $true
}
