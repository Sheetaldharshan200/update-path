# legacy-crossing.ps1 - moving an installation made by an OLDER kit onto this one.
#
# Twin of setup/lib/legacy-crossing.sh. Read that file's header for the whole
# rationale; the short version is that older kits (this one before the
# container runtime was removed, and the upstream
# exasol-labs/exasol-personal-local-starterkit) could deploy the database as a
# CONTAINER, and this kit deploys Exasol Personal and nothing else. An
# installation whose manifest records a container database therefore has a
# database that nothing in this tree can drive.
#
# This module is the ONE place that touches such an installation, through the
# manifest the old kit wrote and three engine verbs - inspect, start, stop. It
# does not reintroduce a runtime and it cannot deploy a container.
#
# THE ORDER IS FORCED BY THE PORT: the old container is listening on the port
# the new deployment wants, so it is stopped before the deploy on BOTH answers,
# and the data can only be read while it is still up. Hence two halves:
#
#   Invoke-LegacyCrossingBefore   ask, export, stop        (before step 1)
#   ... the install runs ...
#   Invoke-LegacyCrossingAfter    restore                  (after the kit steps)
#
# WHAT IS NEVER DONE: the old container and its data volume are not deleted, on
# either answer. The container is left stopped, named on screen, with the one
# command that removes it.
#
# AFTER THE INSTALL there is one more road, `exakit migrate docker-nano`
# (Invoke-LegacyMigrateNow, at the end of this file): the same copy in one
# sitting, for someone who answered "skip" and changed their mind, or whose
# container the installer never saw. On BOTH roads the kit's own bundled sample
# data is left out of the copy: the install loads it itself, and `exakit
# data-load` puts it back any time.

# Under the kit home rather than %TEMP%: it holds the user's data and has to
# survive a reboot between the two halves of a resumed install.
$script:LegacyExportDir = if ($env:EXAKIT_LEGACY_EXPORT_DIR) { $env:EXAKIT_LEGACY_EXPORT_DIR } else { Join-Path $script:ExakitHome "migration" }

# A SECOND exapump profile, not a rewrite of the kit's own: the kit's profile
# has to keep pointing at the new database throughout, and a password belongs
# in a 0600 config file rather than in argv where the process list can read it.
$script:LegacyProfile = if ($env:EXAKIT_LEGACY_PROFILE) { $env:EXAKIT_LEGACY_PROFILE } else { "starter-kit-legacy" }

# Exasol's own schemas. Everything else is the user's, including the kit's
# STARTER_KIT - a user who loaded their own tables into it means them when they
# say "my data".
$script:LegacySystemSchemas = "'SYS','EXA_STATISTICS'"

$script:LegacyChoice = ""
$script:LegacyRestored = 0
$script:LegacySkipped = 0
$script:LegacySkippedNames = ""
$script:LegacyRestoreFailed = 0
$script:LegacyExported = 0
$script:LegacyOwnTables = @()
$script:LegacySampleTables = @()
$script:LegacySampleIds = ""
# A password typed at the migrate command's prompt. A script variable, not an
# environment variable: nothing the kit starts inherits it.
$script:LegacyPassword = ""
$script:LegacyMigrateStatus = ""
$script:LegacyMigrateReason = ""
$script:LegacyMigrateRemedy = ""

# --- what the old install recorded, or what the command line names -----------
#
# Every accessor answers from an EXAKIT_LEGACY_* variable first and from the
# manifest second. The install-time crossing sets none of them and reads the
# record an older kit wrote under runtime.*. `exakit migrate docker-nano` runs
# AFTER an install, when runtime.* describes the new deployment and says nothing
# about the old container - so the CLI fills these from its options, or from the
# copy of the old record the crossing keeps under legacy.* (Save-LegacyRecord).

# Whether this machine has an installation whose database is a container. The
# predicate itself lives in exakit-common.ps1 so the CLI can ask the same
# question from the same place.
function Test-LegacyDbRecorded { return (Test-ExakitLegacyRuntimeRecorded) }

function Get-LegacyContainer {
    if ($env:EXAKIT_LEGACY_CONTAINER) { return "" + $env:EXAKIT_LEGACY_CONTAINER }
    return "" + (Get-ExakitManifestValue "runtime.container")
}
function Get-LegacyVolume {
    if ($env:EXAKIT_LEGACY_VOLUME) { return "" + $env:EXAKIT_LEGACY_VOLUME }
    return "" + (Get-ExakitManifestValue "runtime.volume")
}
function Get-LegacyDsn {
    if ($env:EXAKIT_LEGACY_DSN) { return "" + $env:EXAKIT_LEGACY_DSN }
    return "" + (Get-ExakitManifestValue "runtime.dsn")
}

function Get-LegacyUser {
    $u = "" + $env:EXAKIT_LEGACY_USER
    if (-not $u) { $u = "" + (Get-ExakitManifestValue "runtime.user") }
    if (-not $u) { return "sys" }
    return $u
}

function Get-LegacyPasswordFile {
    if ($env:EXAKIT_LEGACY_PASSWORD_FILE) { return "" + $env:EXAKIT_LEGACY_PASSWORD_FILE }
    return "" + (Get-ExakitManifestValue "runtime.password_file")
}

# The engine's NAME (docker, podman), from the option or the record, never
# re-detected: this is about the engine holding this particular container, and
# a machine can have another one installed.
function Get-LegacyEngineName {
    if ($env:EXAKIT_LEGACY_ENGINE) { return "" + $env:EXAKIT_LEGACY_ENGINE }
    return "" + (Get-ExakitManifestValue "runtime.engine")
}

# Get-LegacyEngine - that engine as a runnable path, or "". One that is named
# but no longer on PATH answers "", which is what makes the migrate option offer
# itself as unavailable rather than fail halfway through.
function Get-LegacyEngine {
    $name = Get-LegacyEngineName
    if (-not $name) { return "" }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return ""
}

# Save-LegacyRecord - the old record, copied under legacy.* before the install
# overwrites runtime.* with the new deployment. `exakit migrate docker-nano`
# reads it back, so a "skip" answered today needs no options when it is
# reversed next month, and `exakit status` reads it to say the old database is
# still there. Twin of legacy_remember_record.
function Save-LegacyRecord {
    $v = Get-LegacyContainer;    if ($v) { Set-ExakitManifestValue "legacy.container" $v }
    $v = Get-LegacyEngineName;   if ($v) { Set-ExakitManifestValue "legacy.engine" $v }
    $v = Get-LegacyVolume;       if ($v) { Set-ExakitManifestValue "legacy.volume" $v }
    $v = Get-LegacyDsn;          if ($v) { Set-ExakitManifestValue "legacy.dsn" $v }
    $v = Get-LegacyPasswordFile; if ($v) { Set-ExakitManifestValue "legacy.password_file" $v }
    Set-ExakitManifestValue "legacy.user" (Get-LegacyUser)
}

# One bounded engine call. Bounded for the reason every engine probe here is:
# an engine that is still starting does not answer, and the crossing must not
# hang an install behind it.
function Invoke-LegacyEngine {
    param([string[]]$Arguments)
    $bin = Get-LegacyEngine
    if (-not $bin) { return $null }
    $timeout = 20
    if ($env:EXAKIT_ENGINE_PROBE_TIMEOUT) { $timeout = [int]$env:EXAKIT_ENGINE_PROBE_TIMEOUT }
    return (Invoke-ExakitBounded -FilePath $bin -Arguments $Arguments -TimeoutSeconds $timeout)
}

# running | stopped | absent | unknown. "unknown" is its own answer: an engine
# that will not talk is not evidence that the user's database is gone.
function Get-LegacyContainerState {
    $name = Get-LegacyContainer
    if (-not $name) { return "absent" }
    if (-not (Get-LegacyEngine)) { return "unknown" }
    $out = Invoke-LegacyEngine -Arguments @("container", "inspect", "-f", "{{.State.Running}}", $name)
    if ($null -eq $out -or "$out".Trim() -eq "") {
        $exists = Invoke-LegacyEngine -Arguments @("container", "inspect", $name)
        if ($null -eq $exists -or "$exists".Trim() -eq "") { return "absent" }
        return "unknown"
    }
    if ("$out" -match "true")  { return "running" }
    if ("$out" -match "false") { return "stopped" }
    return "unknown"
}

function Start-LegacyContainer {
    $name = Get-LegacyContainer
    if (-not $name) { return $false }
    $out = Invoke-LegacyEngine -Arguments @("start", $name)
    # Started is not ready. The readiness probe is a real query, below.
    return ($null -ne $out)
}

# The one mutation the crossing makes to the old install, and it is reversible:
# the container is stopped, never removed, and its data volume is not touched.
#
# -Quiet is the twin of the sh side's `>/dev/null 2>&1` on the two calls that
# happen where NOTHING may reach the screen: a resumed attempt, and a gate that
# closed with no offer to make. Without it the Windows crossing said "Stopping
# the old database container ..." on exactly the re-runs that are supposed to
# pass in silence - the sh side never did, and the two had drifted.
function Stop-LegacyContainer {
    param([switch]$Quiet)
    $name = Get-LegacyContainer
    if (-not $name) { return $true }
    if ((Get-LegacyContainerState) -ne "running") { return $true }
    if (-not $Quiet) { Info "Stopping the old database container ($name) so the new deployment can take the port" }
    $out = Invoke-LegacyEngine -Arguments @("stop", $name)
    if ($null -eq $out) {
        if (-not $Quiet) { Warn2 "Could not stop the container $name - the new deployment may find its port busy" }
        return $false
    }
    Set-ExakitManifestValue "legacy.container_stopped" $true
    return $true
}

# The exact command that removes the old container and its data, printed for
# the user and never run by the kit.
function Get-LegacyRemoveCommand {
    $engine = Get-LegacyEngineName
    if (-not $engine) { $engine = "podman" }
    $c = Get-LegacyContainer
    $v = Get-LegacyVolume
    if (-not $c) { return "" }
    if ($v) { return "$engine rm -f $c; $engine volume rm $v" }
    return "$engine rm -f $c"
}

# --- talking to the old database --------------------------------------------

# The exapump profile for the OLD database, from what the old install recorded.
# $false when the password is not on file, which is the honest case for a
# deployment the old kit adopted rather than created.
function Write-LegacyProfile {
    $dsn = Get-LegacyDsn
    if (-not $dsn) { return $false }
    $parts = $dsn -split ":", 2
    if ($parts.Count -lt 2) { return $false }
    # The password: typed at the migrate command's prompt ($script:LegacyPassword),
    # given to a scripted run (EXAKIT_LEGACY_PASSWORD), or on file. Never on a
    # command line.
    $password = "" + $script:LegacyPassword
    if (-not $password) { $password = "" + $env:EXAKIT_LEGACY_PASSWORD }
    if (-not $password) {
        $pwFile = Get-LegacyPasswordFile
        if (-not $pwFile -or -not (Test-Path $pwFile)) { return $false }
        # "" + ..., because Get-Content -Raw on an EMPTY file returns $null, and
        # .TrimEnd() on $null is a terminating error - which, under the global
        # Stop preference, would have ended the install on a 0-byte password
        # file. The sh twin tests -s for the same case; here the empty string
        # falls to the test below and the profile is simply not written.
        $password = ("" + (Get-Content $pwFile -Raw)).TrimEnd("`r", "`n")
    }
    if (-not $password) { return $false }
    New-Item -ItemType Directory -Force -Path (Split-Path $script:ExapumpConfigPath -Parent) | Out-Null
    # The password goes straight into the 0600 config. It is never echoed,
    # logged, or passed on a command line.
    Set-ExapumpTomlSection -ConfigPath $script:ExapumpConfigPath -Profile $script:LegacyProfile `
        -Host_ $parts[0] -Port $parts[1] -User (Get-LegacyUser) -Password $password
    Protect-ExakitFile $script:ExapumpConfigPath
    return $true
}

# Invoke-LegacyQuery <sql> - one read from the OLD database, as text.
#
# INSIDE A CONTINUE WINDOW, and that is not a formality: every entry point sets
# $ErrorActionPreference = "Stop" globally, and under Stop a native command
# that writes to stderr becomes a TERMINATING error on Windows PowerShell 5.1 -
# before the exit code can be read. exapump writes progress to stderr while
# succeeding, so without this every one of these probes would throw instead of
# answering. Same guard Get-ExakitProbedVersion carries, for the same reason.
function Invoke-LegacyQuery {
    param([Parameter(Mandatory)][string]$Sql)
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $out = & (Get-ExapumpCli) sql -p $script:LegacyProfile $Sql 2>$null
        return ("" + ($out -join "`n"))
    } catch {
        return ""
    } finally {
        $ErrorActionPreference = $previous
    }
}

# A real query against the old database through its own profile. The readiness
# signal for everything below.
function Test-LegacyDbAnswers {
    return ((Invoke-LegacyQuery -Sql "SELECT 'EXAKIT_LEGACY_OK' AS P") -match "EXAKIT_LEGACY_OK")
}

# Poll the old database until it answers or the budget is spent, in five-second
# steps with the first ask immediate. Twin of legacy_wait_db_answers.
function Wait-LegacyDbAnswers {
    param([int]$Budget)
    $waited = 0
    while (-not (Test-LegacyDbAnswers) -and $waited -lt $Budget) {
        Start-Sleep -Seconds 5
        $waited += 5
    }
    return (Test-LegacyDbAnswers)
}

# SCHEMA.TABLE for every non-system table. The sentinel wrapper is the pattern
# Get-ExapumpCount uses, for the same reason: the echoed query literal must not
# be mistaken for a result row, and after "EXAKIT_LT[" the literal has a quote
# where a result has a name.
function Get-LegacyTables {
    $sql = "SELECT 'EXAKIT_LT[' || TABLE_SCHEMA || '.' || TABLE_NAME || ']' AS T FROM EXA_ALL_TABLES WHERE TABLE_SCHEMA NOT IN ($($script:LegacySystemSchemas)) ORDER BY TABLE_SCHEMA, TABLE_NAME"
    $out = Invoke-LegacyQuery -Sql $sql
    $found = @()
    foreach ($m in [regex]::Matches($out, 'EXAKIT_LT\[([^\]]*)\]')) {
        $found += $m.Groups[1].Value
    }
    return $found
}

# CREATE TABLE for the target, built from the SOURCE column types.
#
# THIS IS WHY THE ROUND TRIP KEEPS ITS TYPES. `exapump upload` into a table that
# does not exist INFERS the schema from the CSV, and inference turns a
# DECIMAL(12,4) into whatever the sample looks like. Creating the table with the
# original types first means the upload only has to parse into them.
function Get-LegacyTableDdl {
    param([string]$Schema, [string]$Table)
    $sql = "SELECT 'EXAKIT_LC[' || COLUMN_NAME || '<<:>>' || COLUMN_TYPE || ']' AS C FROM EXA_ALL_COLUMNS WHERE COLUMN_SCHEMA = '$Schema' AND COLUMN_TABLE = '$Table' ORDER BY COLUMN_ORDINAL_POSITION"
    $out = Invoke-LegacyQuery -Sql $sql
    $cols = @()
    foreach ($m in [regex]::Matches($out, 'EXAKIT_LC\[([^\]]*)\]')) {
        $spec = $m.Groups[1].Value
        # SPLIT ON THE MARKER, NOT ON WHITESPACE. A column name may contain a
        # space ("my col") and so may a type ("TIMESTAMP WITH LOCAL TIME
        # ZONE"), so neither end can be found from the first or the last space.
        $at = $spec.IndexOf("<<:>>")
        if ($at -lt 1) { continue }
        # Quoted identifiers: a column named ORDER or one with a lower-case
        # letter or a space is legal in Exasol and illegal unquoted.
        $cols += ('"' + $spec.Substring(0, $at) + '" ' + $spec.Substring($at + 5))
    }
    if ($cols.Count -eq 0) { return "" }
    return ('CREATE TABLE "' + $Schema + '"."' + $Table + '" (' + ($cols -join ", ") + ')')
}

# --- the kit's own sample data ----------------------------------------------
#
# The bundled datasets (data\datasets\<id>\) are the kit's, not the user's. The
# install that runs around the crossing loads them itself, and `exakit
# data-load` puts them back any time. Copying them out of the old database and
# into the new one would spend minutes on tables the new database already has -
# and the restore would then have to refuse each one as already there. So a
# table that IS a bundled sample table, unchanged, is left out of the copy and
# named as such. "Unchanged" means the same schema, the same table and the same
# number of rows as the CSV the kit ships; a sample table the user has changed
# is theirs and travels with the rest. Twin of the same section in the sh module.

# One entry per table the bundled datasets create, read from the kit's own
# files: Table (SCHEMA.TABLE), Id (the dataset), Rows (in the CSV). The schema
# comes from dataset.conf, the table from the CSV's name - the rule the loader
# applies - and the row count from the file itself.
function Get-LegacySampleCatalog {
    $catalog = @()
    if (-not (Get-Command Get-ExakitBundledDatasets -ErrorAction SilentlyContinue)) { return $catalog }
    $root = Get-ExakitRepoRoot
    if (-not $root) { return $catalog }
    foreach ($ds in @(Get-ExakitBundledDatasets)) {
        $dir = Join-Path $root ("data\datasets\" + $ds.Id + "\data")
        foreach ($csv in (Get-ChildItem -Path (Join-Path $dir "*.csv") -File -ErrorAction SilentlyContinue)) {
            # The header is not a row, and a last line without a newline still is.
            $lines = 0
            $reader = New-Object System.IO.StreamReader($csv.FullName)
            try { while ($null -ne $reader.ReadLine()) { $lines++ } } finally { $reader.Close() }
            $rows = if ($lines -gt 0) { $lines - 1 } else { 0 }
            $catalog += @{ Table = ($ds.Schema + "." + $csv.BaseName.ToUpper()); Id = $ds.Id; Rows = $rows }
        }
    }
    return $catalog
}

# SCHEMA.TABLE -> rows for every table of the old database in the given schemas,
# from the row count Exasol keeps in EXA_ALL_TABLES. One query for all of them;
# a table whose count is not known has no entry.
function Get-LegacyTableRows {
    param([string]$SchemaList)
    $rows = @{}
    $sql = "SELECT 'EXAKIT_LR[' || TABLE_SCHEMA || '.' || TABLE_NAME || '<<:>>' || CAST(TABLE_ROW_COUNT AS VARCHAR(40)) || ']' AS R FROM EXA_ALL_TABLES WHERE TABLE_SCHEMA IN ($SchemaList)"
    $out = Invoke-LegacyQuery -Sql $sql
    foreach ($m in [regex]::Matches($out, 'EXAKIT_LR\[([^\]]*)\]')) {
        $spec = $m.Groups[1].Value
        $at = $spec.IndexOf("<<:>>")
        if ($at -lt 1) { continue }
        $rows[$spec.Substring(0, $at)] = $spec.Substring($at + 5)
    }
    return $rows
}

# The old database's tables split into the user's own ($script:LegacyOwnTables)
# and the kit's unchanged sample tables ($script:LegacySampleTables), with the
# datasets those belong to in $script:LegacySampleIds. Asks the old database for
# row counts only when a table sits in a sample schema at all, and then once.
# Twin of legacy_classify.
function Split-LegacyTables {
    param([string[]]$Tables)
    $script:LegacyOwnTables = @()
    $script:LegacySampleTables = @()
    $script:LegacySampleIds = ""
    $catalog = @{}
    foreach ($entry in @(Get-LegacySampleCatalog)) { $catalog[$entry.Table] = $entry }
    $schemas = @()
    foreach ($t in @($Tables)) {
        if (-not $t -or -not $catalog.ContainsKey($t)) { continue }
        $s = "'" + $t.Substring(0, $t.IndexOf(".")) + "'"
        if ($schemas -notcontains $s) { $schemas += $s }
    }
    $rows = @{}
    if ($schemas.Count -gt 0) { $rows = Get-LegacyTableRows -SchemaList ($schemas -join ",") }
    foreach ($t in @($Tables)) {
        if (-not $t) { continue }
        $entry = $null
        if ($catalog.ContainsKey($t)) { $entry = $catalog[$t] }
        if ($entry -and $rows.ContainsKey($t) -and ("" + $rows[$t]) -eq ("" + $entry.Rows)) {
            $script:LegacySampleTables += $t
            $ids = @($script:LegacySampleIds -split "," | Where-Object { $_ })
            if ($ids -notcontains $entry.Id) { $ids += $entry.Id }
            $script:LegacySampleIds = ($ids -join ",")
        } else {
            $script:LegacyOwnTables += $t
        }
    }
}

# The sentence that says what is left out. Twin of legacy_sample_note.
function Write-LegacySampleNote {
    param([int]$Own, [int]$Sample)
    Info "$Sample of them belong to the kit's bundled sample data ($($script:LegacySampleIds)), unchanged - the kit loads that itself, so they are not copied. Your own: $Own table(s)."
}

# --- the two halves ---------------------------------------------------------

# The question, asked once. Two answers, and they are exclusive: this is a fork
# in the road, not a set of features. EXAKIT_LEGACY_DATA pre-answers it, and an
# unattended run with no answer SKIPS - copying a database is not something to
# start on someone's behalf while they are not there, and skipping destroys
# nothing.
function Select-LegacyChoice {
    param([int]$TableCount, [bool]$CanMigrate, [string]$Why)

    switch ("" + $env:EXAKIT_LEGACY_DATA) {
        { $_ -in @("migrate", "yes", "1") } {
            if ($CanMigrate) { $script:LegacyChoice = "migrate" }
            else {
                Warn2 "EXAKIT_LEGACY_DATA asked for a migration, but $Why"
                $script:LegacyChoice = "skip"
            }
            return
        }
        { $_ -in @("skip", "no", "0") } { $script:LegacyChoice = "skip"; return }
    }

    if (-not $CanMigrate) {
        Warn2 "Your data cannot be copied automatically: $Why"
        $script:LegacyChoice = "skip"
        return
    }

    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        Info "Nothing is asked in an unattended run, so the old database is left alone."
        Info "To copy it into the new one, re-run with EXAKIT_LEGACY_DATA=migrate - or afterwards: exakit migrate docker-nano"
        $script:LegacyChoice = "skip"
        return
    }

    # Row 2 is the exclusive one: picking "skip" clears "migrate" and the other
    # way round.
    $picked = Read-ExakitCheckboxMenu -Title "Your existing database" `
        -Options @(
            "Migrate my data - copy $TableCount table(s) into the new database",
            "Skip and continue - set up the new database empty, and leave the old one alone") `
        -Defaults @(1) -ExclusiveIndex 2
    if ($picked -contains 2) { $script:LegacyChoice = "skip" } else { $script:LegacyChoice = "migrate" }
}

# Every non-system table to CSV under $Dir, plus a plain index the second half
# reads back.
#
# CSV, not Parquet: `exapump export --format parquet` is broken in the versions
# this kit installs (it writes the rows as CSV and then fails re-parsing its own
# output), so asking for Parquet produces a 0-byte file and a confusing error.
# CSV round-trips faithfully INTO A TABLE THAT ALREADY EXISTS with the right
# types, which is what Get-LegacyTableDdl is for.
#
# THE ONE THING CSV CANNOT CARRY: an empty string and a NULL are the same three
# bytes in a CSV field, so a VARCHAR that held '' arrives as NULL. That is named
# on screen before the copy starts, not discovered afterwards.
function Export-LegacyTables {
    param([string]$Dir, [string[]]$Tables)
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $indexPath = Join-Path $Dir "index"
    Set-Content -Path $indexPath -Value @() -Encoding Ascii
    $ok = 0; $bad = 0; $n = 0
    foreach ($t in $Tables) {
        $n++
        $dot = $t.IndexOf(".")
        if ($dot -lt 1) { continue }
        $schema = $t.Substring(0, $dot)
        $table = $t.Substring($dot + 1)
        # The file name is positional, not derived from the table name: a
        # schema or table with a dot, a slash or a space in it is legal in
        # Exasol and would otherwise escape the directory.
        $file = "t$n.csv"
        $script:ExakitActiveLabel = "Copying out $t ($n/$($Tables.Count))"
        if ((Invoke-ExakitLogged (Get-ExapumpCli) "export" "-p" $script:LegacyProfile `
                "--table" $t "--format" "csv" "-o" (Join-Path $Dir $file)) -eq 0) {
            $ddl = Get-LegacyTableDdl -Schema $schema -Table $table
            # The index is read back by the other half, so it carries
            # everything that half needs: where the rows are, where they go,
            # and how to build the table that receives them.
            Add-Content -Path $indexPath -Value ("$file`t$schema`t$table`t$ddl") -Encoding Ascii
            $ok++
        } else {
            # The partial file goes. exapump creates the output before it
            # knows the query works, so a failed export leaves a 0-byte file -
            # harmless (nothing indexes it) but alarming to find in a
            # directory whose whole job is holding someone's data.
            Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Dir $file)
            Warn2 "Could not copy $t out of the old database - it is left there, untouched"
            $bad++
        }
    }
    $script:ExakitActiveLabel = ""
    Set-ExakitManifestValue "legacy.exported" $ok
    if ($bad -gt 0) { Set-ExakitManifestValue "legacy.export_failed" $bad }
    return ($ok -gt 0)
}

# The saved tables into the database that is now running.
#
# A table the fresh install has already created is SKIPPED, not appended to.
# The bundled sample data is loaded before this runs, so appending would double
# every row of every sample table a user also had.
function Import-LegacyTables {
    param([string]$Dir)
    $indexPath = Join-Path $Dir "index"
    if (-not (Test-Path $indexPath)) { return $false }
    $ok = 0; $skipped = 0; $bad = 0; $skippedNames = ""
    foreach ($line in (Get-Content $indexPath)) {
        if (-not $line) { continue }
        $parts = $line -split "`t", 4
        if ($parts.Count -lt 3) { continue }
        $file = $parts[0]; $schema = $parts[1]; $table = $parts[2]
        $ddl = ""
        if ($parts.Count -ge 4) { $ddl = $parts[3] }
        $path = Join-Path $Dir $file
        if (-not (Test-Path $path)) { continue }
        $target = '"' + $schema + '"."' + $table + '"'
        $script:ExakitActiveLabel = "Restoring $schema.$table"
        # CREATE SCHEMA is unconditional and harmless; CREATE TABLE is the test
        # for "does this already exist", so its failure is not an error here.
        [void](Invoke-ExakitLogged (Get-ExapumpCli) "sql" "-p" $script:ExapumpProfile `
            ('CREATE SCHEMA IF NOT EXISTS "' + $schema + '"'))
        if ($ddl) {
            if ((Invoke-ExakitLogged (Get-ExapumpCli) "sql" "-p" $script:ExapumpProfile $ddl) -ne 0) {
                # Already there - the fresh install created it. Leave it alone.
                $skipped++
                $skippedNames = "$skippedNames $schema.$table"
                continue
            }
        }
        if ((Invoke-ExakitLogged (Get-ExapumpCli) "upload" "-p" $script:ExapumpProfile `
                "--table" $target $path) -eq 0) {
            $ok++
        } else {
            Warn2 "Could not restore $schema.$table - the copy is kept at $(Get-ExakitTilde $path)"
            $bad++
        }
    }
    $script:ExakitActiveLabel = ""
    Set-ExakitManifestValue "legacy.restored" $ok
    if ($skipped -gt 0) { Set-ExakitManifestValue "legacy.restore_skipped" $skipped }
    if ($bad -gt 0) { Set-ExakitManifestValue "legacy.restore_failed" $bad }
    $script:LegacyRestored = $ok
    $script:LegacySkipped = $skipped
    $script:LegacySkippedNames = $skippedNames
    $script:LegacyRestoreFailed = $bad
    return $true
}

# The first half: say what was found, ask, copy out, stop the container. Never
# fails the install - every arm that cannot continue falls back to leaving the
# old database exactly where it is.
function Invoke-LegacyCrossingBefore {
    # ASKED ONCE, AND ONLY WHERE THERE IS SOMETHING TO ASK ABOUT.
    #
    # Three gates, cheapest first, and all three are silent when they close.
    # An installer that announces "your database is in a container" to someone
    # whose container is long gone, or on every re-run after the crossing has
    # already happened, is a nag - and this code runs on EVERY install.
    #
    #   1. the record says this is not a legacy install       -> nothing
    #   2. the crossing already happened on this machine      -> nothing
    #   3. there is no readable database with tables in it     -> nothing
    #
    # Only past all three does anything reach the screen.
    if (-not (Test-LegacyDbRecorded)) { return }
    if ("" + (Get-ExakitManifestValue "legacy.crossing_done") -eq "True") { return }

    # An earlier attempt at THIS install already answered. Finish the leftover
    # work and say nothing: the question was asked, and asking again (or
    # narrating a resume) is the same nag from the other direction. The restore
    # half does the talking, because it has something to report.
    $already = "" + (Get-ExakitManifestValue "legacy.choice")
    if ($already) {
        $script:LegacyChoice = $already
        Write-ExakitLog "INFO" "legacy crossing: resuming with choice=$already"
        [void](Stop-LegacyContainer -Quiet)
        return
    }

    $type = "" + (Get-ExakitManifestValue "runtime.type")
    $container = Get-LegacyContainer
    $state = Get-LegacyContainerState
    # The record, kept: the deployment step is about to overwrite runtime.*, and
    # `exakit migrate docker-nano` has to find the old database afterwards.
    Save-LegacyRecord

    # THE PROBE COMES BEFORE THE BANNER. Whether there is a database worth
    # talking about is answerable without saying a word, and if the answer is
    # no this function has nothing to tell anyone.
    $can = $true; $why = ""
    if (-not (Get-LegacyEngine)) {
        $can = $false; $why = "the container engine this database needs is not on this machine any more"
    } elseif ($state -eq "absent") {
        $can = $false; $why = "the container is gone, so there is nothing left to copy"
    } elseif (-not (Test-Path (Get-ExapumpCli))) {
        $can = $false; $why = "exapump is not installed, and it is what reads the tables out"
    }

    # A stopped container still holds the data, so it is started - but quietly,
    # and only once the gates above have said there is a point.
    $started = $false
    if ($can -and $state -eq "stopped") {
        if (Start-LegacyContainer) { $started = $true }
        else { $can = $false; $why = "the old container would not start" }
    }

    $tables = @()
    if ($can) {
        if (Write-LegacyProfile) {
            # Up to two minutes, and only for a container this run just
            # started: one that was already running answers on the first ask.
            $budget = 120
            if ($env:EXAKIT_LEGACY_READY_TIMEOUT) { $budget = [int]$env:EXAKIT_LEGACY_READY_TIMEOUT }
            if (-not $started) { $budget = 10 }
            if (Wait-LegacyDbAnswers -Budget $budget) {
                $tables = Get-LegacyTables
            } else {
                $can = $false; $why = "the old database did not answer in time"
            }
        } else {
            $can = $false; $why = "the password for the old database is not on file, so it cannot be read"
        }
    }

    # The kit's own sample data is not "my data": it is left out of the count
    # the user is asked about, and out of the copy.
    $total = @($tables).Count
    $sample = 0
    if ($can) {
        Split-LegacyTables -Tables @($tables)
        $sample = @($script:LegacySampleTables).Count
    } else {
        $script:LegacyOwnTables = @()
    }
    $count = @($script:LegacyOwnTables).Count
    if ($can -and $count -eq 0) {
        if ($sample -gt 0) {
            $can = $false; $why = "the old database holds only the kit's bundled sample data ($($script:LegacySampleIds)), unchanged, which this install loads itself"
        } else {
            $can = $false; $why = "the old database has no tables in it"
        }
    }

    # GATE 3. Nothing to offer, so nothing is said. The reason goes to the log,
    # where someone asking "why was I not offered a migration?" can find it,
    # and the crossing is marked done so this is never reconsidered.
    if (-not $can) {
        Write-ExakitLog "INFO" "legacy crossing: no offer made - $why"
        Set-ExakitManifestValue "legacy.choice" "skip"
        Set-ExakitManifestValue "legacy.crossed_from" $type
        if ($sample -gt 0) { Set-ExakitManifestValue "legacy.sample_left_out" $script:LegacySampleIds }
        Set-ExakitManifestValue "legacy.crossing_done" $true
        # It may still be holding the port, whether or not its data is readable.
        [void](Stop-LegacyContainer -Quiet)
        return
    }

    # Past all three gates: there is a real database with real tables in it,
    # and this is the one and only time the user is asked about it.
    Write-Host ""
    Warn2 "This machine has a starter kit installation whose database runs in a container."
    Info "This kit deploys Exasol Personal instead, so that container is not something it can manage."
    if ($container) { Info "The old database is the container '$container' ($state)." }
    Info "It holds $total table(s). Copying them takes a few minutes and changes nothing in the old database."
    if ($sample -gt 0) { Write-LegacySampleNote -Own $count -Sample $sample }
    Info "One caveat worth knowing: a text column that held an empty string arrives as NULL."

    Select-LegacyChoice -TableCount $count -CanMigrate $can -Why $why
    Set-ExakitManifestValue "legacy.choice" $script:LegacyChoice
    Set-ExakitManifestValue "legacy.crossed_from" $type
    if ($sample -gt 0) { Set-ExakitManifestValue "legacy.sample_left_out" $script:LegacySampleIds }

    if ($script:LegacyChoice -eq "migrate") {
        Info "Copying $count table(s) out of the old database"
        if (Export-LegacyTables -Dir $script:LegacyExportDir -Tables @($script:LegacyOwnTables)) {
            Set-ExakitManifestValue "legacy.export_dir" $script:LegacyExportDir
            Ok "Your data is saved at $(Get-ExakitTilde $script:LegacyExportDir) - it goes into the new database at the end of this install"
        } else {
            Warn2 "Nothing could be copied out. The old database is untouched; nothing is lost."
            $script:LegacyChoice = "skip"
            Set-ExakitManifestValue "legacy.choice" "skip"
        }
    }

    # BOTH answers stop the container: it is holding the port the new
    # deployment needs. Stopped, not removed - the data volume stays.
    [void](Stop-LegacyContainer)

    if ($script:LegacyChoice -eq "skip") {
        Info "The old database is left exactly as it was, stopped, with its data."
        Info "To copy it into the new database later: exakit migrate docker-nano"
        $rm = Get-LegacyRemoveCommand
        if ($rm) { Info "When you no longer want it: $rm" }
    }
    # The question has now been asked. It is never asked again on this machine,
    # whatever happens to the rest of this run.
    Set-ExakitManifestValue "legacy.crossing_done" $true
    Write-Host ""
}

# The second half: the saved tables into the database this install just
# deployed. Reports what landed and what did not.
function Invoke-LegacyCrossingAfter {
    $dir = "" + (Get-ExakitManifestValue "legacy.export_dir")
    if (-not $dir) { return }
    if (-not (Test-Path (Join-Path $dir "index"))) { return }
    if ("" + (Get-ExakitManifestValue "legacy.restored") -ne "") { return }

    Write-Host ""
    Info "Restoring your data into the new database"
    if (-not (Import-LegacyTables -Dir $dir)) {
        Warn2 "Your data could not be restored. The copy is kept at $(Get-ExakitTilde $dir)."
        return
    }
    [void](Write-LegacyRestoreReport -Dir $dir -Why "this install had already created them")
    Write-Host ""
}

# What landed and what did not, after Import-LegacyTables. $false when something
# did not restore, so the copy is named as still needed. Twin of
# legacy_report_restore.
function Write-LegacyRestoreReport {
    param([string]$Dir, [string]$Why)
    Ok "Restored $($script:LegacyRestored) table(s) from your previous database"
    if ($script:LegacySkipped -gt 0) {
        Info "Left alone ($Why):$($script:LegacySkippedNames)"
    }
    if ($script:LegacyRestoreFailed -gt 0) {
        Warn2 "$($script:LegacyRestoreFailed) table(s) did not restore - the copies are still at $(Get-ExakitTilde $Dir)"
        return $false
    }
    # The copy is only removed once every table is accounted for, and the old
    # container still has the original either way.
    Info "The copy at $(Get-ExakitTilde $Dir) is no longer needed; remove it whenever you like."
    $rm = Get-LegacyRemoveCommand
    if ($rm) { Info "The old container still holds the original. To remove it: $rm" }
    return $true
}

# --- after the install: exakit migrate docker-nano --------------------------
#
# The crossing asks once, during an install. Someone who answered "skip" then
# and wants the data after all, or whose container the installer never saw (made
# by hand, or by the upstream kit on a machine this kit was installed fresh on),
# still has a database in a container - and this is the same copy, in one
# sitting: the old database is read, its tables restored into the deployment
# that is already running, the kit's own sample data left where it is.
#
# THE PORT IS THE COMPLICATION. Both databases want 8563. When the container
# publishes the deployment's port, the deployment is stopped for the copy out
# and started again before the copy in; when it does not, nothing is stopped.
# The container ends as it began - except one holding the deployment's port,
# which stays stopped because the deployment has to have it back.
#
# Configured through the EXAKIT_LEGACY_* variables the accessors read, which the
# CLI fills from its options and from the record the crossing kept. Returns 0
# when done (or when there was nothing of the user's to copy), 1 when it
# failed, 5 when it was declined; $script:LegacyMigrateStatus and -Reason carry
# the outcome for the CLI's --json. Nothing here calls Fail(): the CLI decides
# how a failure is shown. Twin of legacy_migrate_now.

$script:LegacyMigrateStarted = $false
$script:LegacyMigrateClash = $false
$script:LegacyMigrateDbStopped = $false

function Set-LegacyMigrateFailure {
    param([string]$Reason, [string]$Remedy = "")
    $script:LegacyMigrateStatus = "failed"
    $script:LegacyMigrateReason = $Reason
    $script:LegacyMigrateRemedy = $Remedy
    Write-ExakitError $Reason
    if ($Remedy) { Info "Then: $Remedy" }
    Write-ExakitLog "ERROR" "legacy migrate: $Reason"
}

# Everything back the way it was found, except a container on the deployment's
# port, which stays stopped so the deployment can have the port back. $false
# when the deployment did not come back. Twin of _legacy_migrate_settle.
function Restore-LegacyMigrateState {
    if ($script:LegacyMigrateStarted -or $script:LegacyMigrateClash) {
        [void](Stop-LegacyContainer -Quiet)
    }
    if ($script:LegacyMigrateDbStopped -or -not (Test-PersonalDeploymentRunning)) {
        $script:ExakitActiveLabel = "Starting your database again"
        try {
            Start-Personal
            Wait-PersonalReady
        } catch {
            return $false
        }
    }
    return $true
}

function Invoke-LegacyMigrateNow {
    param([bool]$Yes = $false)
    $script:LegacyMigrateStatus = ""; $script:LegacyMigrateReason = ""; $script:LegacyMigrateRemedy = ""
    $script:LegacyRestored = 0; $script:LegacySkipped = 0; $script:LegacyRestoreFailed = 0
    $script:LegacyExported = 0; $script:LegacySampleIds = ""
    $script:LegacyMigrateStarted = $false; $script:LegacyMigrateClash = $false; $script:LegacyMigrateDbStopped = $false
    $container = Get-LegacyContainer
    $engineName = Get-LegacyEngineName
    if (-not $container) {
        Set-LegacyMigrateFailure "No container is named. Say which one holds the old database: exakit migrate docker-nano --container <name>"
        return 1
    }
    if (-not (Get-LegacyEngine)) {
        $shown = if ($engineName) { $engineName } else { "?" }
        Set-LegacyMigrateFailure "The container engine '$shown' is not on this machine, so the container '$container' cannot be reached." "exakit migrate docker-nano --engine docker|podman"
        return 1
    }
    $state = Get-LegacyContainerState
    if ($state -eq "absent") {
        Set-LegacyMigrateFailure "There is no container named '$container' in $engineName. List them with '$engineName ps -a' and name the right one with --container."
        return 1
    }
    if ($state -eq "unknown") {
        Set-LegacyMigrateFailure "$engineName did not answer about the container '$container'. Is the engine running?"
        return 1
    }
    if (-not (Test-Path (Get-ExapumpCli))) {
        Set-LegacyMigrateFailure "exapump is not installed, and it is what reads the tables out." "exakit update"
        return 1
    }

    # A copy from an earlier run that never landed is finished first: it is
    # the user's data, waiting, and a fresh copy over it would destroy it.
    $dir = $script:LegacyExportDir
    $indexPath = Join-Path $dir "index"
    if ((Test-Path $indexPath) -and (Get-Item $indexPath).Length -gt 0 -and ("" + (Get-ExakitManifestValue "legacy.restored")) -eq "") {
        Info "A copy from an earlier run is waiting at $(Get-ExakitTilde $dir) - restoring it first"
        if (-not (Import-LegacyTables -Dir $dir)) {
            Set-LegacyMigrateFailure "The waiting copy could not be restored; it is kept at $(Get-ExakitTilde $dir)."
            return 1
        }
        [void](Write-LegacyRestoreReport -Dir $dir -Why "the new database already had them")
        Set-ExakitManifestValue "legacy.choice" "migrate"
        Set-ExakitManifestValue "legacy.crossing_done" $true
        Info "Run the command again for a fresh copy of what is in the container now."
        $script:LegacyMigrateStatus = "done"
        return 0
    }

    # THE PORT. The container's published port against the deployment's.
    $dsn = Get-LegacyDsn
    $port = $dsn.Substring($dsn.LastIndexOf(":") + 1)
    $dbPort = "" + (Get-PersonalDbPort)
    $script:LegacyMigrateClash = ($port -eq $dbPort)
    $dbRunning = Test-PersonalDeploymentRunning

    Write-Host ""
    Info "Copying the tables of the container '$container' ($engineName, $state) into your database."
    Info "The kit's bundled sample data is left out - the kit loads that itself. Nothing in the container is changed or removed."
    Info "One caveat worth knowing: a text column that held an empty string arrives as NULL."
    if ($script:LegacyMigrateClash -and $dbRunning) {
        Warn2 "The container publishes port $port, the port your database uses, so the two cannot run at once."
        Info "Your database is stopped while the tables are copied out, and started again before they are copied in."
    }
    if (-not $Yes) {
        if (-not (Confirm-ExakitPrompt "Go ahead?" $true)) {
            Info "Nothing was changed."
            $script:LegacyMigrateStatus = "declined"
            return 5
        }
    }

    if ($script:LegacyMigrateClash -and $dbRunning) {
        $script:ExakitActiveLabel = "Stopping your database for the copy"
        try { Stop-Personal } catch {
            Set-LegacyMigrateFailure "Your database could not be stopped, so the container cannot take the port." "exakit stop, then exakit migrate docker-nano"
            return 1
        }
        $script:LegacyMigrateDbStopped = $true
    }
    if ($state -ne "running") {
        Info "Starting the container '$container'"
        if (-not (Start-LegacyContainer)) {
            if ($script:LegacyMigrateDbStopped) { try { Start-Personal } catch { } }
            Set-LegacyMigrateFailure "The container '$container' would not start (see '$engineName logs $container')."
            return 1
        }
        $script:LegacyMigrateStarted = $true
    }

    $ready = $false
    $why = ""
    if (-not (Write-LegacyProfile)) {
        $why = "The password of the old database is not on file. Pass it with --password-file <path> (a file holding only the password), or answer the prompt on a console."
    } else {
        $budget = 120
        if ($env:EXAKIT_LEGACY_READY_TIMEOUT) { $budget = [int]$env:EXAKIT_LEGACY_READY_TIMEOUT }
        if (-not $script:LegacyMigrateStarted) { $budget = 10 }
        $script:ExakitActiveLabel = "Waiting for the old database to answer"
        if (Wait-LegacyDbAnswers -Budget $budget) { $ready = $true }
        else { $why = "The old database did not answer within ${budget}s. Is the password right, and is $dsn where the container listens ('$engineName port $container')?" }
    }
    if (-not $ready) {
        [void](Restore-LegacyMigrateState)
        Set-LegacyMigrateFailure $why
        return 1
    }

    $tables = @(Get-LegacyTables)
    $total = $tables.Count
    Split-LegacyTables -Tables $tables
    $sample = @($script:LegacySampleTables).Count
    $own = @($script:LegacyOwnTables).Count
    if ($sample -gt 0) { Set-ExakitManifestValue "legacy.sample_left_out" $script:LegacySampleIds }
    if ($own -eq 0) {
        if ($sample -gt 0) {
            Info "The container holds $total table(s), all of them the kit's bundled sample data ($($script:LegacySampleIds)), unchanged - nothing of yours to copy."
            Info "The kit loads that data itself: exakit data-load"
        } else {
            Info "The old database has no tables in it - nothing to copy."
        }
        [void](Restore-LegacyMigrateState)
        Set-ExakitManifestValue "legacy.choice" "migrate"
        Set-ExakitManifestValue "legacy.crossing_done" $true
        $script:LegacyMigrateStatus = "nothing"
        return 0
    }

    Info "The container holds $total table(s)."
    if ($sample -gt 0) { Write-LegacySampleNote -Own $own -Sample $sample }
    # A copy that was restored before is spent; its files go before the new one
    # lands, or a smaller export would leave the old one's tail beside it.
    if (Test-Path $indexPath) { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    foreach ($k in @("legacy.restored", "legacy.restore_skipped", "legacy.restore_failed")) {
        try { Remove-ExakitManifestValue $k } catch { }
    }
    Info "Copying $own table(s) out of the old database"
    $exported = Export-LegacyTables -Dir $dir -Tables @($script:LegacyOwnTables)
    $script:LegacyExported = [int]("0" + (Get-ExakitManifestValue "legacy.exported"))
    if (-not $exported) {
        [void](Restore-LegacyMigrateState)
        Set-LegacyMigrateFailure "Nothing could be copied out. The old database is untouched; nothing is lost."
        return 1
    }
    Set-ExakitManifestValue "legacy.export_dir" $dir
    Ok "Copied $($script:LegacyExported) table(s) out; they are saved at $(Get-ExakitTilde $dir)"

    if (-not (Restore-LegacyMigrateState)) {
        Set-LegacyMigrateFailure "Your database did not come back, so the copy is not restored yet. It is kept at $(Get-ExakitTilde $dir)." "exakit start, then exakit migrate docker-nano"
        return 1
    }
    Info "Restoring your data into the new database"
    if (-not (Import-LegacyTables -Dir $dir)) {
        Set-LegacyMigrateFailure "Your data could not be restored. The copy is kept at $(Get-ExakitTilde $dir)." "exakit migrate docker-nano"
        return 1
    }
    Set-ExakitManifestValue "legacy.choice" "migrate"
    Set-ExakitManifestValue "legacy.crossing_done" $true
    Set-ExakitManifestValue "legacy.migrated_at" (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    if (Write-LegacyRestoreReport -Dir $dir -Why "the new database already had them") {
        $script:LegacyMigrateStatus = "done"
        return 0
    }
    $script:LegacyMigrateStatus = "partial"
    $script:LegacyMigrateReason = "$($script:LegacyRestoreFailed) table(s) did not restore"
    $script:LegacyMigrateRemedy = "exakit migrate docker-nano"
    return 1
}
