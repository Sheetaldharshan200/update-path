#!/usr/bin/env pwsh
# legacy-crossing-ps.ps1 - behavioural tests for setup/lib/legacy-crossing.ps1,
# the Windows twin of the crossing from a container database onto Exasol
# Personal. tests/legacy-crossing.sh proves the twin EXISTS function for
# function; this file runs it, against a sandboxed kit home, a fault-injection
# engine and a fault-injection exapump, through the same faults the sh suite
# throws at the sh module - and ends by measuring how much of the module it
# walked, with a floor.
#
#   pwsh -NoProfile -File tests/legacy-crossing-ps.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/legacy-crossing-ps.ps1
#
# The stubs are the PowerShell twins in tests/lib/, behind a .cmd wrapper on
# Windows and a #!/bin/sh wrapper elsewhere, so one stub implementation meets
# the module on every host. Their behaviour comes from files in a control
# directory, exactly as for the sh suite.

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label = $actual" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected $expected, got $actual" }
}
function Has($label, $needle, $haystack) {
    if (("" + $haystack).Contains($needle)) { Check $label "present" "present" } else { Check $label "present" "MISSING" }
}
function Lacks($label, $needle, $haystack) {
    if (("" + $haystack).Contains($needle)) { Check $label "absent" "PRESENT" } else { Check $label "absent" "absent" }
}

# --- sandbox ----------------------------------------------------------------
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-legacy-ps-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
# The exapump profile writer puts its file under the PROFILE home. That is the
# developer's real ~/.exapump unless this is set - and one of these runs writes
# a legacy profile. USERPROFILE outranks HOME in Get-ExakitProfileHome.
$env:USERPROFILE = Join-Path $work "profile"
New-Item -ItemType Directory -Force -Path $env:USERPROFILE, $env:EXAKIT_HOME, $env:EXAKIT_BIN_DIR | Out-Null
Remove-Item Env:EXAKIT_LEGACY_DATA -ErrorAction SilentlyContinue
$env:EXAKIT_ENGINE_PROBE_TIMEOUT = "2"
$onWindows = ($env:OS -like "*Windows*")

# --- the two stubs, once, reached through PATH and EXAKIT_EXAPUMP_BIN ----------
$stub = Join-Path $work "stub"
New-Item -ItemType Directory -Force -Path $stub | Out-Null
Copy-Item (Join-Path $repo "tests/lib/legacy-fault-engine.ps1")  (Join-Path $stub "fault-engine.ps1")
Copy-Item (Join-Path $repo "tests/lib/legacy-fault-exapump.ps1") (Join-Path $stub "fault-exapump.ps1")
function New-StubWrapper([string]$Name, [string]$Target) {
    if ($onWindows) {
        $path = Join-Path $stub "$Name.cmd"
        Set-Content -Path $path -Encoding Ascii -Value @(
            "@echo off",
            "powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0$Target`" %*",
            "exit /b %ERRORLEVEL%")
    } else {
        $path = Join-Path $stub $Name
        $pwsh = (Get-Process -Id $PID).Path
        Set-Content -Path $path -Value @(
            "#!/bin/sh",
            "exec `"$pwsh`" -NoProfile -File `"`$(dirname `"`$0`")/$Target`" `"`$@`"")
        chmod +x $path
    }
    return $path
}
[void](New-StubWrapper "fakeengine" "fault-engine.ps1")
$env:EXAKIT_EXAPUMP_BIN = New-StubWrapper "exapump" "fault-exapump.ps1"
$env:PATH = "$stub" + [IO.Path]::PathSeparator + $env:PATH

# --- line coverage, by breakpoint --------------------------------------------
# Every line of the module that can hold a statement gets a breakpoint whose
# action records the line. Breakpoints are set BEFORE the module is
# dot-sourced, so the top-level assignments count too. What is excluded is
# what a breakpoint can never fire on: blank and comment lines, a lone brace,
# the `} else {` / `} catch {` / `} finally {` joints, a function header, and
# the continuation lines of a statement split with a backtick, a comma or an
# open parenthesis - which are folded into the line the statement starts on.
$module = (Resolve-Path (Join-Path $repo "setup/lib/legacy-crossing.ps1")).Path
$script:covHits = @{}
$lines = Get-Content $module
$executable = @{}; $groupOf = @{}
$prevContinues = $false; $group = 0
for ($i = 0; $i -lt $lines.Count; $i++) {
    $n = $i + 1; $t = $lines[$i].Trim()
    if (-not $prevContinues) { $group = $n }
    $groupOf[$n] = $group
    $exe = $true
    if ($t -eq "" -or $t.StartsWith("#")) { $exe = $false }
    elseif ($prevContinues) { $exe = $false }
    elseif ($t -match '^(\}|\{|\}\s*else\s*\{|else\s*\{|try\s*\{|\}\s*catch\s*\{|\}\s*finally\s*\{)$') { $exe = $false }
    elseif ($t -match '^function\s+[A-Za-z-]+\s*\{$') { $exe = $false }
    elseif ($t -match '^param\(') { $exe = $false }
    if ($exe) { $executable[$n] = $true }
    $prevContinues = ($t -match '(`|,|\()$')
}
$breakpoints = @()
foreach ($n in $executable.Keys) {
    $action = [scriptblock]::Create("`$script:covHits[$n] = 1")
    $breakpoints += Set-PSBreakpoint -Script $module -Line $n -Action $action
}

. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/exapump.ps1")
. $module

# --- scenario plumbing ---------------------------------------------------------
$PASSWORD = "legacysecret-Zq7"
$script:allEngine = @(); $script:allExapump = @(); $script:screens = @()

# Seed - a kit home holding what an OLDER kit recorded. -Type, -NoPassword,
# -EmptyPassword, -NoDsn, -NoContainer, -NoVolume and -Engine shape the record.
function Seed {
    param([string]$Type = "nano", [switch]$NoPassword, [switch]$EmptyPassword, [switch]$NoDsn,
          [switch]$NoContainer, [switch]$NoVolume, [string]$Engine = "fakeengine")
    Remove-Item -Recurse -Force $env:EXAKIT_HOME -ErrorAction SilentlyContinue
    $ctrl = Join-Path $env:EXAKIT_HOME "ctrl"
    New-Item -ItemType Directory -Force -Path (Join-Path $env:EXAKIT_HOME "credentials"), $ctrl, $env:EXAKIT_BIN_DIR | Out-Null
    $env:EXAKIT_FAULT_DIR = $ctrl
    $script:LegacyExportDir = Join-Path $env:EXAKIT_HOME "migration"
    $pw = Join-Path $env:EXAKIT_HOME "credentials\nano_sys_password"
    if (-not $NoPassword) {
        if ($EmptyPassword) { Set-Content -Path $pw -Value "" -NoNewline } else { Set-Content -Path $pw -Value $PASSWORD }
    }
    $rt = [ordered]@{ type = $Type; engine = $Engine; user = "sys"; status = "healthy"; image = "docker.io/exasol/nano:2026.2.0-nano.2" }
    if (-not $NoContainer) { $rt.container = "exasol-nano" }
    if (-not $NoVolume)    { $rt.volume = "exasol-nano-data" }
    if (-not $NoDsn)       { $rt.dsn = "127.0.0.1:8563" }
    $rt.password_file = $pw
    $doc = [ordered]@{ manifest_version = 1; kit_level = 1
        kit = [ordered]@{ version = "0.1.0"; source = "exasol-labs/exasol-personal-local-starterkit@0.1.0" }
        runtime = $rt; steps_completed = @("runtime") }
    Set-Content -Path (Join-Path $env:EXAKIT_HOME "manifest.json") -Value ($doc | ConvertTo-Json -Depth 5)
    Set-Content -Path (Join-Path $ctrl "db.tables") -Value "S1.T1`nS1.T2`nS2.T3"
    Set-Content -Path (Join-Path $ctrl "db.columns") -Value "S1.T1|ID<<:>>DECIMAL(18,0)`nS1.T1|NAME<<:>>VARCHAR(25) UTF8`nS1.T2|WHEN_TS<<:>>TIMESTAMP WITH LOCAL TIME ZONE`nS2.T3|my col<<:>>DOUBLE"
    # The module caches nothing between calls, but its result variables do
    # carry over; a scenario starts from zero.
    $script:LegacyChoice = ""; $script:LegacyRestored = 0; $script:LegacySkipped = 0
    $script:LegacySkippedNames = ""; $script:LegacyRestoreFailed = 0
}
function Fault([string]$Name, [string]$Value) { Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR $Name) -Value $Value -NoNewline }
function Calls([string]$Which) {
    $p = Join-Path $env:EXAKIT_FAULT_DIR "$Which.calls"
    if (Test-Path $p) { return @(Get-Content $p) }
    return @()
}
function Verbs { return ((Calls "engine") | ForEach-Object { ($_ -split " ")[0] }) -join " " }
function MGet([string]$Path) { return ("" + (Get-ExakitManifestValue $Path)) }
# Screen - everything a call writes, on any stream, as one string; remembered
# for the invariants at the end.
function Screen([scriptblock]$Body) {
    # -Width, or the capture is folded at the HOST console width and these
    # assertions start matching the terminal rather than the module.
    #
    # It bit once, on the Windows runner only. The "no longer needed" line
    # carries the export directory, and a Windows temp path is long enough
    # (172 characters all told) that the fold landed at column 128 - inside
    # the phrase, splitting it into "no lo" and "nger needed". The module had
    # printed it correctly; the check read MISSING. The line after it passed
    # on the same screen because its phrase sits at column 24, before any
    # fold. Nothing reproduces this under pwsh 7, which does not fold these
    # records at all, so the suite was green everywhere except the one host
    # that matters for a 5.1 test.
    $out = (& $Body *>&1 | Out-String -Width 4096)
    $script:screens += $out
    return $out
}
function Remember {
    $script:allEngine += (Calls "engine"); $script:allExapump += (Calls "exapump")
}
$unattended = [Console]::IsInputRedirected -or -not [Environment]::UserInteractive

# =============================================================================
Write-Host "the record is the whole test:"
Seed
Check "a container runtime recorded is a legacy install" $true (Test-LegacyDbRecorded)
Seed -Type personal
Check "a Personal install is not" $false (Test-LegacyDbRecorded)
Seed -Type ""
Check "no runtime type at all is not" $false (Test-LegacyDbRecorded)

Write-Host ""
Write-Host "the container's state, through the recorded engine:"
Seed;                               Check "running"  "running" (Get-LegacyContainerState)
Fault "engine.state" "stopped";     Check "stopped"  "stopped" (Get-LegacyContainerState)
Fault "engine.state" "absent";      Check "absent"   "absent"  (Get-LegacyContainerState)
Fault "engine.state" "unknown";     Check "unparseable is unknown, never absent" "unknown" (Get-LegacyContainerState)
Seed -Engine "no-such-engine";      Check "an engine that is gone answers unknown" "unknown" (Get-LegacyContainerState)
Check "...and the engine is never asked for" 0 @(Calls "engine").Count
Seed -NoContainer;                  Check "no container name reads as absent" "absent" (Get-LegacyContainerState)
Check "...and the removal command has nothing to name" "" (Get-LegacyRemoveCommand)

Write-Host ""
Write-Host "start and stop, and what they change:"
Seed; Fault "engine.state" "stopped"
Check "a stopped container starts" $true (Start-LegacyContainer)
Check "...and then reads as running" "running" (Get-LegacyContainerState)
Check "stop succeeds" $true (Stop-LegacyContainer)
Check "...records itself" "True" (MGet "legacy.container_stopped")
Check "...and a second stop is a no-op, not an error" $true (Stop-LegacyContainer)
Check "exactly one stop was issued" 1 @((Calls "engine") | Where-Object { $_ -like "stop *" }).Count
Seed; Fault "engine.start_rc" "1"; Fault "engine.state" "stopped"
Check "a start the engine refuses is reported" $false (Start-LegacyContainer)
Seed; Fault "engine.stop_rc" "1"
$s = Screen { $script:stopResult = Stop-LegacyContainer }
Check "a stop the engine refuses is reported" $false $script:stopResult
Has "...and warned about" "may find its port busy" $s

Write-Host ""
Write-Host "the removal command names both things that hold data:"
Seed
$rm = Get-LegacyRemoveCommand
Has "the container" "exasol-nano" $rm
Has "the volume" "exasol-nano-data" $rm
Has "the recorded engine" "fakeengine" $rm
Seed -NoVolume
Lacks "without a recorded volume it invents none" "volume rm" (Get-LegacyRemoveCommand)

Write-Host ""
Write-Host "talking to the old database:"
Seed -NoPassword;   Check "no password file: no profile" $false (Write-LegacyProfile)
Seed -EmptyPassword; Check "an empty password file: no profile" $false (Write-LegacyProfile)
Seed -NoDsn;        Check "no dsn: no profile" $false (Write-LegacyProfile)
Seed
Check "a complete record writes the profile" $true (Write-LegacyProfile)
$cfg = Join-Path $env:USERPROFILE ".exapump\config.toml"
Check "...under the sandboxed profile home" $true (Test-Path $cfg)
Has "...as the LEGACY profile section" "[starter-kit-legacy]" (Get-Content $cfg -Raw)
Has "...pointing at the recorded port" "port = 8563" (Get-Content $cfg -Raw)
Check "the database answers through it" $true (Test-LegacyDbAnswers)
Check "the tables are listed" "S1.T1 S1.T2 S2.T3" ((Get-LegacyTables) -join " ")
Fault "db.answer_after" "never"
Check "a database that never answers says so" $false (Test-LegacyDbAnswers)
Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "db.tables") -Value ""
Check "an empty database lists nothing" 0 @(Get-LegacyTables).Count

Write-Host ""
Write-Host "the DDL keeps the source's types:"
Seed
$ddl = Get-LegacyTableDdl -Schema "S1" -Table "T1"
Check "both identifiers quoted, types carried" 'CREATE TABLE "S1"."T1" ("ID" DECIMAL(18,0), "NAME" VARCHAR(25) UTF8)' $ddl
Has "a multi-word type survives the marker split" '"WHEN_TS" TIMESTAMP WITH LOCAL TIME ZONE' (Get-LegacyTableDdl -Schema "S1" -Table "T2")
Has "a column name with a space is quoted" '"my col" DOUBLE' (Get-LegacyTableDdl -Schema "S2" -Table "T3")
Check "a table with no catalogue yields no DDL" "" (Get-LegacyTableDdl -Schema "S9" -Table "NOPE")

Write-Host ""
Write-Host "copying out tolerates partial failure:"
Seed; Fault "export.fail" "S1.T2"; [void](Write-LegacyProfile)
$dir = $script:LegacyExportDir
$s = Screen { $script:exportResult = Export-LegacyTables -Dir $dir -Tables @("S1.T1", "S1.T2", "S2.T3") }
Check "two of three land, so the copy counts as made" $true $script:exportResult
Has "the failed table is named" "Could not copy S1.T2" $s
Check "exported" "2" (MGet "legacy.exported")
Check "export_failed" "1" (MGet "legacy.export_failed")
$index = Get-Content (Join-Path $dir "index")
Check "two index lines" 2 @($index).Count
Check "the failed table is not indexed" 0 @($index | Where-Object { $_ -match "`tT2`t" }).Count
Check "...and its partial file is gone" $false (Test-Path (Join-Path $dir "t2.csv"))
Check "the files are positional" "t1.csv t3.csv" ((Get-ChildItem $dir -Filter "t*.csv" | Sort-Object Name | ForEach-Object { $_.Name }) -join " ")
Has "the index carries the DDL" 'CREATE TABLE "S1"."T1"' ($index -join "`n")
Seed; Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "export.fail") -Value "S1.T1`nS1.T2`nS2.T3"; [void](Write-LegacyProfile)
$s = Screen { $script:exportResult = Export-LegacyTables -Dir $script:LegacyExportDir -Tables @("S1.T1", "S1.T2", "S2.T3") }
Check "when every table fails, the copy is not made" $false $script:exportResult
Check "...zero exported, three failed" "0/3" ((MGet "legacy.exported") + "/" + (MGet "legacy.export_failed"))
Seed; [void](Write-LegacyProfile)
[void](Export-LegacyTables -Dir $script:LegacyExportDir -Tables @("My Schema.T.with.dots", "nodot"))
$index = Get-Content (Join-Path $script:LegacyExportDir "index")
Has "a schema is split at the FIRST dot" "My Schema`tT.with.dots" ($index -join "`n")
Check "a name with no dot is skipped, not mangled" 1 @($index).Count
Lacks "no parquet is ever asked for" "parquet" ((Calls "exapump") -join "`n")

Write-Host ""
Write-Host "restoring tolerates partial failure and heals what it can:"
Seed; [void](Write-LegacyProfile)
[void](Export-LegacyTables -Dir $script:LegacyExportDir -Tables @("S1.T1", "S1.T2", "S2.T3"))
Fault "import.exists" "S1.T2"; Fault "upload.fail" "S2.T3"
$s = Screen { $script:importResult = Import-LegacyTables -Dir $script:LegacyExportDir }
Check "a mixed restore returns" $true $script:importResult
Check "one restored" 1 $script:LegacyRestored
Check "one left alone" 1 $script:LegacySkipped
Check "...by name" " S1.T2" $script:LegacySkippedNames
Check "one failed" 1 $script:LegacyRestoreFailed
Has "...and named, with its kept copy" "Could not restore S2.T3" $s
Check "no upload for the table left alone" 0 @((Calls "exapump") | Where-Object { $_ -like "upload *" -and $_ -like '*"S1"."T2"*' }).Count
Check "the counts are recorded" "1/1/1" ((MGet "legacy.restored") + "/" + (MGet "legacy.restore_skipped") + "/" + (MGet "legacy.restore_failed"))
Seed; [void](Write-LegacyProfile)
[void](Export-LegacyTables -Dir $script:LegacyExportDir -Tables @("S1.T1", "S1.T2", "S2.T3"))
Remove-Item (Join-Path $script:LegacyExportDir "t2.csv")
Fault "import.schema_rc" "1"
[void](Import-LegacyTables -Dir $script:LegacyExportDir)
Check "a missing file is skipped without a count" "2" (MGet "legacy.restored")
Check "...not as a failure" "" (MGet "legacy.restore_failed")
Check "and a refused CREATE SCHEMA does not stop the restore" 2 $script:LegacyRestored
Add-Content -Path (Join-Path $script:LegacyExportDir "index") -Value "`n`nnot-a-real-line`n"
[void](Import-LegacyTables -Dir $script:LegacyExportDir)
Check "blank and malformed index lines are stepped over" 2 $script:LegacyRestored
Seed
Check "a directory with no index is refused" $false (Import-LegacyTables -Dir (Join-Path $env:EXAKIT_HOME "nowhere"))

Write-Host ""
Write-Host "the answers:"
Seed
$env:EXAKIT_LEGACY_DATA = "migrate"; Select-LegacyChoice -TableCount 3 -CanMigrate $true -Why "";  Check "migrate" "migrate" $script:LegacyChoice
$env:EXAKIT_LEGACY_DATA = "yes";     Select-LegacyChoice -TableCount 3 -CanMigrate $true -Why "";  Check "yes is migrate" "migrate" $script:LegacyChoice
$env:EXAKIT_LEGACY_DATA = "1";       Select-LegacyChoice -TableCount 3 -CanMigrate $true -Why "";  Check "1 is migrate" "migrate" $script:LegacyChoice
$env:EXAKIT_LEGACY_DATA = "skip";    Select-LegacyChoice -TableCount 3 -CanMigrate $true -Why "";  Check "skip" "skip" $script:LegacyChoice
$env:EXAKIT_LEGACY_DATA = "no";      Select-LegacyChoice -TableCount 3 -CanMigrate $true -Why "";  Check "no is skip" "skip" $script:LegacyChoice
$env:EXAKIT_LEGACY_DATA = "0";       Select-LegacyChoice -TableCount 3 -CanMigrate $true -Why "";  Check "0 is skip" "skip" $script:LegacyChoice
$env:EXAKIT_LEGACY_DATA = "migrate"
$s = Screen { Select-LegacyChoice -TableCount 3 -CanMigrate $false -Why "the container is gone" }
Check "a migration that cannot be done is refused" "skip" $script:LegacyChoice
Has "...with the reason" "the container is gone" $s
Remove-Item Env:EXAKIT_LEGACY_DATA
$s = Screen { Select-LegacyChoice -TableCount 3 -CanMigrate $false -Why "no password" }
Check "no answer and no possible copy: skip" "skip" $script:LegacyChoice
Has "...saying why" "no password" $s
if ($unattended) {
    $env:EXAKIT_LEGACY_DATA = "maybe"
    $s = Screen { Select-LegacyChoice -TableCount 3 -CanMigrate $true -Why "" }
    Check "a value the kit does not know, off a terminal, is skip" "skip" $script:LegacyChoice
    Has "...with the hint" "EXAKIT_LEGACY_DATA=migrate" $s
    Remove-Item Env:EXAKIT_LEGACY_DATA
} else {
    Check "unattended default (needs redirected stdin)" "skipped" "skipped"
    Check "unattended hint (needs redirected stdin)" "skipped" "skipped"
}

Write-Host ""
Write-Host "the first half, gate by gate:"
Seed -Type personal
$s = Screen { Invoke-LegacyCrossingBefore }
Check "a Personal install: nothing said" "" $s.Trim()
Check "...nothing asked of the engine" 0 @(Calls "engine").Count
Seed; Set-ExakitManifestValue "legacy.crossing_done" $true
$s = Screen { Invoke-LegacyCrossingBefore }
Check "a crossing already done: nothing said" "" $s.Trim()
Check "...and no probe at all" 0 @(Calls "engine").Count
Seed; Fault "engine.state" "absent"
$s = Screen { Invoke-LegacyCrossingBefore }
Check "a container that is gone: nothing said" "" $s.Trim()
Check "...but settled for good" "True" (MGet "legacy.crossing_done")
Check "...as skip" "skip" (MGet "legacy.choice")
Seed -Engine "no-such-engine"
$s = Screen { Invoke-LegacyCrossingBefore }
Check "a recorded engine that is gone: nothing said" "" $s.Trim()
Check "...settled as skip" "skip" (MGet "legacy.choice")
Seed
$realExapump = $env:EXAKIT_EXAPUMP_BIN; $env:EXAKIT_EXAPUMP_BIN = Join-Path $env:EXAKIT_HOME "no-such-exapump"
$s = Screen { Invoke-LegacyCrossingBefore }
$env:EXAKIT_EXAPUMP_BIN = $realExapump
Check "no exapump: nothing said" "" $s.Trim()
Check "...and no query attempted" 0 @(Calls "exapump").Count
Seed -NoPassword
$s = Screen { Invoke-LegacyCrossingBefore }
Check "no password: nothing said" "" $s.Trim()
Check "...the database never queried" 0 @((Calls "exapump") | Where-Object { $_ -like "*EXAKIT_LEGACY_OK*" }).Count
Check "...and the container stopped for the port" 1 @((Calls "engine") | Where-Object { $_ -like "stop *" }).Count
Seed; Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "db.tables") -Value ""
$s = Screen { Invoke-LegacyCrossingBefore }
Check "an empty database: nothing said" "" $s.Trim()
Check "...settled" "True" (MGet "legacy.crossing_done")
Seed; Fault "engine.state" "stopped"; Fault "engine.start_rc" "1"
$s = Screen { Invoke-LegacyCrossingBefore }
Check "a container that will not start: nothing said" "" $s.Trim()
Check "...start attempted once" 1 @((Calls "engine") | Where-Object { $_ -like "start *" }).Count
Seed; Fault "db.answer_after" "never"; Fault "engine.state" "stopped"; $env:EXAKIT_LEGACY_READY_TIMEOUT = "5"
$t0 = Get-Date
$s = Screen { Invoke-LegacyCrossingBefore }
Remove-Item Env:EXAKIT_LEGACY_READY_TIMEOUT
Check "a database that never answers: nothing said" "" $s.Trim()
Check "...within the configured budget" $true (((Get-Date) - $t0).TotalSeconds -lt 20)
Check "...and the container it started is stopped again" 1 @((Calls "engine") | Where-Object { $_ -like "stop *" }).Count
Seed; Fault "db.answer_after" "2"; $env:EXAKIT_LEGACY_DATA = "migrate"
$s = Screen { Invoke-LegacyCrossingBefore }
Has "a database that answers late is still copied" "Your data is saved" $s
Check "...all three tables" "3" (MGet "legacy.exported")
Remove-Item Env:EXAKIT_LEGACY_DATA
Seed; Set-ExakitManifestValue "legacy.choice" "migrate"
$s = Screen { Invoke-LegacyCrossingBefore }
Check "a resumed attempt: nothing said" "" $s.Trim()
Check "...the container it left running is stopped" 1 @((Calls "engine") | Where-Object { $_ -like "stop *" }).Count
Check "...and nothing is copied twice" 0 @((Calls "exapump") | Where-Object { $_ -like "export *" }).Count
Remember

Write-Host ""
Write-Host "the whole road, end to end:"
Seed; $env:EXAKIT_LEGACY_DATA = "migrate"
$s = Screen { Invoke-LegacyCrossingBefore }
Has "the banner names the container and its state" "container 'exasol-nano' (running)" $s
Has "...and the table count" "It holds 3 table(s)" $s
Has "...and the CSV caveat" "empty string arrives as NULL" $s
Check "choice" "migrate" (MGet "legacy.choice")
Check "crossed_from" "nano" (MGet "legacy.crossed_from")
Check "export_dir" $script:LegacyExportDir (MGet "legacy.export_dir")
Check "exported" "3" (MGet "legacy.exported")
Check "container_stopped" "True" (MGet "legacy.container_stopped")
Check "crossing_done" "True" (MGet "legacy.crossing_done")
Check "the engine saw inspect, inspect, stop - nothing else" "container container stop" (Verbs)
Check "every export used the LEGACY profile" 3 @((Calls "exapump") | Where-Object { $_ -like "export -p starter-kit-legacy *" }).Count
$s2 = Screen { Invoke-LegacyCrossingAfter }
Has "the second half restores" "Restored 3 table(s)" $s2
Has "...and declares the copy expendable" "no longer needed" $s2
Has "...naming the original's home" "still holds the original" $s2
Check "every upload used the KIT's profile" 3 @((Calls "exapump") | Where-Object { $_ -like "upload -p starter-kit *" }).Count
Check "restored" "3" (MGet "legacy.restored")
$uploads = @((Calls "exapump") | Where-Object { $_ -like "upload *" }).Count
$s3 = Screen { Invoke-LegacyCrossingAfter }
Check "a second restore is silent" "" $s3.Trim()
Check "...and issues no more uploads" $uploads @((Calls "exapump") | Where-Object { $_ -like "upload *" }).Count
$s4 = Screen { Invoke-LegacyCrossingBefore }
Check "and a later install asks nothing again" "" $s4.Trim()
Remember
Seed; Fault "engine.state" "stopped"; $env:EXAKIT_LEGACY_DATA = "migrate"
$s = Screen { Invoke-LegacyCrossingBefore }
Has "a stopped container is copied too" "(stopped)" $s
Check "...started, then stopped - inspect before each" "container start container stop" (Verbs)
Remember
Seed; $env:EXAKIT_LEGACY_DATA = "skip"
$s = Screen { Invoke-LegacyCrossingBefore }
Has "skip leaves the old database alone, and says so" "left exactly as it was, stopped, with its data" $s
Has "...with the removal command" "fakeengine rm -f exasol-nano; fakeengine volume rm exasol-nano-data" $s
Check "no export was issued" 0 @((Calls "exapump") | Where-Object { $_ -like "export *" }).Count
Check "the container was stopped" 1 @((Calls "engine") | Where-Object { $_ -like "stop *" }).Count
$s2 = Screen { Invoke-LegacyCrossingAfter }
Check "the second half has nothing to restore" "" $s2.Trim()
Remember
Seed; $env:EXAKIT_LEGACY_DATA = "migrate"; Set-Content -Path (Join-Path $env:EXAKIT_FAULT_DIR "export.fail") -Value "S1.T1`nS1.T2`nS2.T3"
$s = Screen { Invoke-LegacyCrossingBefore }
Has "when nothing copies, it says so" "Nothing could be copied out" $s
Check "...and downgrades to skip" "skip" (MGet "legacy.choice")
Check "...leaving no export_dir" "" (MGet "legacy.export_dir")
Remember
Seed; $env:EXAKIT_LEGACY_DATA = "migrate"; Fault "engine.stop_rc" "1"
$s = Screen { Invoke-LegacyCrossingBefore }
Has "a stop the engine refuses is warned about on the migrate road" "may find its port busy" $s
Check "...and the crossing is still done" "True" (MGet "legacy.crossing_done")
Remember
Seed; $env:EXAKIT_LEGACY_DATA = "migrate"
[void](Screen { Invoke-LegacyCrossingBefore }); Fault "upload.fail" "S2.T3"; Fault "import.exists" "S1.T2"
$s2 = Screen { Invoke-LegacyCrossingAfter }
Has "a mixed restore counts what landed" "Restored 1 table(s)" $s2
Has "...names what it left alone" "Left alone (this install had already created them): S1.T2" $s2
Has "...keeps the copy for the failure" "did not restore" $s2
Lacks "...and does not call it expendable" "no longer needed" $s2
Remember
Remove-Item Env:EXAKIT_LEGACY_DATA

Write-Host ""
Write-Host "invariants that held across every scenario above:"
Check "the engine was used" $true ($script:allEngine.Count -gt 0)
Check "exapump was used" $true ($script:allExapump.Count -gt 0)
Check "no engine call ever removed anything" 0 @($script:allEngine | Where-Object { $_ -match '^(rm|container rm|volume|destroy|kill|prune)' }).Count
Check "only inspect, start and stop were issued" "" (@($script:allEngine | ForEach-Object { ($_ -split " ")[0] } | Where-Object { $_ -notin @("container", "start", "stop") } | Sort-Object -Unique) -join " ")
Check "the password never reached the screen" 0 @($script:screens | Where-Object { $_.Contains($PASSWORD) }).Count
Check "...nor any process the crossing ran" 0 @(($script:allEngine + $script:allExapump) | Where-Object { $_.Contains($PASSWORD) }).Count
Check "...and it did land in the sandboxed profile" $true ((Get-Content $cfg -Raw).Contains($PASSWORD))
Check "no read of the old database used the kit's profile" 0 @($script:allExapump | Where-Object { $_ -match '^(export|sql) -p starter-kit ' -and $_ -notmatch 'CREATE|upload' }).Count
Check "no upload used the legacy profile" 0 @($script:allExapump | Where-Object { $_ -like "upload -p starter-kit-legacy *" }).Count

# --- coverage ------------------------------------------------------------------
foreach ($bp in $breakpoints) { Remove-PSBreakpoint $bp }
$hitGroups = @{}
foreach ($n in $script:covHits.Keys) { $hitGroups[$groupOf[[int]$n]] = 1 }
$total = @($executable.Keys).Count
$covered = @($executable.Keys | Where-Object { $hitGroups.ContainsKey($groupOf[$_]) }).Count
$pct = [int][math]::Floor($covered * 100 / [math]::Max($total, 1))
Write-Host ""
Write-Host "coverage of legacy-crossing.ps1: $covered of $total executable lines ($pct%), floor 85%"
$missed = @($executable.Keys | Where-Object { -not $hitGroups.ContainsKey($groupOf[$_]) } | Sort-Object)
if ($missed.Count -gt 0) {
    Write-Host "never reached:"
    foreach ($n in $missed) { Write-Host ("  {0,4}  {1}" -f $n, $lines[$n - 1].Trim()) }
}
Check "coverage floor held" $true ($pct -ge 85)

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "passed: $($script:PASS), failed: $($script:FAIL)"
if ($script:FAIL -gt 0) { exit 1 }
