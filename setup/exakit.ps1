# exakit.ps1 - lifecycle helper for the Exasol Personal Local Starter Kit
# (Windows / PowerShell path). Mirrors setup/exakit function-for-function.
#
# usage: exakit <command> [args]
#
#   preflight            check this machine's requirements, install nothing
#   status                show what is installed and whether it is healthy
#   version               kit source, install date, component versions
#   update-check [what]   compare installed vs advertised versions
#                         (all, runtime, exakit, exapump, mcp, pyexasol)
#   update [what] [-Yes]  apply the advertised versions without deleting database
#                         data. A runtime change stops the database, so on a
#                         console it is offered ("stop the database and update it
#                         now?") and applied on yes; without a console it is
#                         deferred unless -Yes (or EXAKIT_CONFIRM_RUNTIME_UPDATE=1)
#                         says otherwise
#   info [--json]         print the connection details panel; --json prints the
#                         install record (manifest.json) verbatim, nothing else
#   guide                 friendly walkthrough: connect AI clients (MCP), SQL
#                         clients (DBeaver, DbVisualizer), and Python (pyexasol)
#   start                 start the local database and every add-on service
#   stop                  stop them again
#   autostart [on|off]    whether everything comes back after a restart
#   data-load [-Force]    open focused data loading options; -Force reloads bundled sample data
#   mcp-setup             permanently configure MCP in supported AI clients
#   mcp-doctor [clients]  check MCP config, connectivity, and managed state
#   mcp-status [clients]  show managed MCP state for the supported AI clients
#   mcp-validate [clients] validate managed MCP configs and test connectivity
#   mcp-repair [clients]  repair managed MCP config drift
#   mcp-remove [clients]  remove managed MCP config from the supported clients
#   mcp-restore [snapshot] restore the latest (or a chosen) MCP snapshot
#   skills-install        install the kit's AI skills for CLI agents
#                         (~\.claude\skills, ~\.agents\skills)
#   marketplace           browse optional add-ons (dash-server, ...) and install
#                         the ones you select; installed add-ons then update
#                         through `exakit update` like every other component
#   upgrade-kit2          add the Kit 2 trust assets (bash paths only for now)
#   rollback-kit2         remove what upgrade-kit2 added (bash paths only for now)
#   uninstall [-Yes] [-DryRun]
#                         remove EVERYTHING the kit installed: database + all
#                         data, MCP client configs, skills, exapump, the kit
#                         home and the CLI binaries. -DryRun previews; -Yes
#                         skips the typed confirmation
#   whats-new [version]   what changed in this kit version
#   logs [target]         every log the kit can show; no target lists them
#                         (-f follows, --lines N, --path prints the path)
#   catalog [search]      browse/search every exakit, exapump & exasol command
#   help                  this text
#
# Installed to %USERPROFILE%\.local\bin by setup-windows-docker.ps1; also
# runs straight from a repo checkout (setup\exakit.ps1).

param(
    [Parameter(Position = 0)][string]$Command = "help",
    [Parameter(Position = 1, ValueFromRemainingArguments)][string[]]$RestArgs = @()
)

$ErrorActionPreference = "Stop"

# Set by the machine-readable paths (`info --json`) so the update notice at the
# bottom of the dispatcher stays off stdout and the output remains parseable.
$script:JsonOutput = $false

# --- locate the kit's lib directory -----------------------------------------
$scriptDir = Split-Path -Parent $PSCommandPath
if (Test-Path (Join-Path $scriptDir "lib\exakit-common.ps1")) {
    $libDir = Join-Path $scriptDir "lib"
} else {
    $fallbackHome = if ($env:EXAKIT_HOME) { $env:EXAKIT_HOME } else { Join-Path $HOME ".exasol-starter-kit" }
    $fallbackLib = Join-Path $fallbackHome "kit\setup\lib"
    if (Test-Path (Join-Path $fallbackLib "exakit-common.ps1")) {
        $libDir = $fallbackLib
    } else {
        Write-Host "exakit: cannot find the kit library (looked in $scriptDir\lib and $fallbackHome\kit)" -ForegroundColor Red
        exit 1
    }
}

. (Join-Path $libDir "exakit-common.ps1")
. (Join-Path $libDir "nano.ps1")
. (Join-Path $libDir "exapump.ps1")
. (Join-Path $libDir "mcp.ps1")
# pyexasol is an update target of its own (and its own repair command), so the
# CLI needs the module even though it takes no part in the runtime commands.
. (Join-Path $libDir "pyexasol.ps1")
# Marketplace add-on modules: the CLI is where they are installed (exakit
# marketplace) and updated (exakit update <addon>). A missing file only makes
# the marketplace row unavailable - it must not break every other command.
if (Test-Path (Join-Path $libDir "dash-server.ps1")) { . (Join-Path $libDir "dash-server.ps1") }
if (Test-Path (Join-Path $libDir "exasol-vscode.ps1")) { . (Join-Path $libDir "exasol-vscode.ps1") }
if (Test-Path (Join-Path $libDir "json-tables.ps1")) { . (Join-Path $libDir "json-tables.ps1") }

function Get-RuntimeType { return (Get-ExakitManifestValue "runtime.type") }

function Assert-ExakitInstalled {
    if (-not (Test-Path $script:ManifestPath)) { Fail "No installation found. Run the installer first." }
    if (-not (Get-RuntimeType)) { Fail "No runtime recorded in the manifest yet." }
}

# Get-ExakitLoadedDatasets - the bundled datasets that are loaded. Twin of
# exakit_loaded_datasets.
#
# THE DATABASE IS ASKED FIRST. The manifest alone reported three loaded datasets
# against a database with zero schemas after a destroy+redeploy - the worst
# possible answer for an agent rebuilding its bearings after a context reset,
# because it sends it straight into "object not found" with the real cause
# recorded nowhere. Get-ExakitVerifiedDatasets checks the marker tables and heals
# the flags; it lives in exapump.ps1, which the CLI loads conditionally, and it
# returns $null when the database is unreachable. Either way the manifest read
# below is the fallback, never the first answer.
function Get-ExakitLoadedDatasets {
    if (Get-Command Get-ExakitVerifiedDatasets -ErrorAction SilentlyContinue) {
        $verified = Get-ExakitVerifiedDatasets
        if ($null -ne $verified) { return @($verified) }
    }
    $datasets = Get-ExakitManifestValue "data.datasets"
    if (-not $datasets) { return @() }
    $loaded = @()
    foreach ($property in $datasets.PSObject.Properties) {
        if ($property.Value -and $property.Value.loaded) { $loaded += $property.Name }
    }
    return ($loaded | Sort-Object)
}

# Invoke-CmdStatus [-Json] - what is installed and whether it is up. Twin of
# cmd_status, including THE EXIT CODE CONTRACT (agents branch on it, not on
# prose): 0 running, 3 installed but not running, 4 not installed.

# Write-ExakitNotInstalledAnswer [-Json] - the not-installed answer for a STATE
# QUERY, and it exits 4. Twin of _not_installed_answer. A bare Fail here fails
# an agent twice over: it exits 1 where the documented contract says 4, and it
# leaves stdout empty, so a caller piping -Json into a parser gets a decode
# error on precisely the path where structured signal decides the next action.
function Write-ExakitNotInstalledAnswer {
    param([switch]$Json)
    if ($Json) {
        Write-Output ([pscustomobject]@{
            installed = $false
            manifest  = $script:ManifestPath
            reason    = "no install record"
            remedy    = "run the installer"
        } | ConvertTo-Json -Compress)
    } else {
        Write-Host "Not installed (no manifest at $script:ManifestPath). Run the installer first."
    }
    exit 4
}

function Invoke-CmdStatus {
    param([switch]$Json)
    if (-not (Test-Path $script:ManifestPath)) {
        Write-ExakitNotInstalledAnswer -Json:$Json
    }
    $type = Get-RuntimeType
    $status = switch ($type) { "nano" { Get-NanoStatus } default { "unknown" } }
    $running = "$status".StartsWith("running")
    $steps = @(Get-ExakitManifestValue "steps_completed")
    $datasets = @(Get-ExakitLoadedDatasets)
    $pyexasol = Get-ExakitComponentCurrent "pyexasol"
    $services = @{}
    foreach ($svcId in (Get-ExakitServiceIds)) {
        if ($svcId -eq "database") { continue }
        $services[$svcId] = (Get-ExakitServiceStatus -Id $svcId)
    }

    if ($Json) {
        [ordered]@{
            installed       = $true
            kit_level       = "$(Get-ExakitManifestValue 'kit_level')"
            runtime         = [ordered]@{ type = $type; status = $status }
            running         = $running
            services        = $services
            autostart       = ((Get-ExakitManifestValue "autostart.enabled") -eq $true)
            datasets_loaded = $datasets
            steps_completed = $steps
            pyexasol        = $(if ($pyexasol) { "$pyexasol" } else { $null })
            manifest        = $script:ManifestPath
        } | ConvertTo-Json -Depth 4
        if ($running) { exit 0 } else { exit 3 }
    }

    # One label column for the whole screen. The pad was a hardcoded 11, but
    # "dash-server:" is 12, so every service row sat a column out of line - and
    # the registry can add longer ids than that. Measure instead of guessing.
    $lw = 12
    foreach ($svcId in $services.Keys) {
        if ($svcId -eq "database") { continue }
        if (($svcId.Length + 1) -gt $lw) { $lw = $svcId.Length + 1 }
    }
    function Write-StatusRow([string]$Label, [string]$Value) {
        Write-Host ($Label.PadRight($script:statusLabelWidth) + " " + $Value)
    }
    $script:statusLabelWidth = $lw

    Write-StatusRow "Kit level:" "$(Get-ExakitManifestValue 'kit_level')"
    if ($type) { Write-StatusRow "Runtime:" $type } else { Write-StatusRow "Runtime:" "none" }
    Write-StatusRow "Status:" $status
    foreach ($svcId in $services.Keys) {
        Write-StatusRow "${svcId}:" $services[$svcId]
    }
    if ((Get-ExakitManifestValue "autostart.enabled") -eq $true) {
        Write-StatusRow "Autostart:" "on"
    } else {
        Write-StatusRow "Autostart:" "off - turn it on with: exakit autostart on"
    }
    if ($datasets.Count -gt 0) {
        Write-StatusRow "Datasets:" ($datasets -join ', ')
    } else {
        Write-StatusRow "Datasets:" "none loaded - load some with: exakit data-load"
    }

    # Every SOFT component, not just one. exapump, the MCP server and pyexasol
    # all install through the soft-step path, so ANY of them can be missing from
    # an install that finished, and the install-time report is long gone by the
    # time anyone types `exakit status`. This screen used to give pyexasol a
    # dedicated line and say nothing about the other two.
    #
    # steps_completed is gone from the human screen: raw data that reported
    # trouble only by omission. `status --json` still carries it untouched.
    # Mirrors cmd_status in setup/exakit.
    $softRows = @()
    foreach ($soft in @(
        @{ Id = "exapump";  Key = "components.exapump.validated";    Fix = "exakit update exapump" },
        @{ Id = "mcp";      Key = "components.mcp_server.validated"; Fix = "exakit update mcp" },
        @{ Id = "pyexasol"; Key = "components.pyexasol.validated";   Fix = "exakit update pyexasol" }
    )) {
        # A manifest record is what says "this install attempted the component".
        if ($null -eq (Get-ExakitManifestValue $soft.Key)) { continue }
        if (Get-ExakitComponentCurrent $soft.Id) { continue }
        $softRows += ($soft.Id.PadRight(9) + " repair: " + $soft.Fix)
    }
    $softLabel = "Missing:"
    foreach ($row in $softRows) {
        Write-StatusRow $softLabel $row
        $softLabel = ""
    }
    Write-StatusRow "Manifest:" $script:ManifestPath
    if (-not $running) {
        Write-Host "Start it:   exakit start"
        exit 3
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Services and autostart (twin of the exakit_service_* set in common.sh)
# ---------------------------------------------------------------------------
# Every service answers the same three questions - running, start, stop - and
# add-ons opt in through the registry (StatusFn/StartFn/StopFn/AutostartFn), so
# `exakit start|stop|status` and the boot entry pick a new one up with no
# wiring here. Windows registers a Startup-folder entry; the Nano container
# carries its own restart policy, which Docker honours on boot.
function Get-ExakitServiceIds {
    $ids = @()
    if (Get-ExakitManifestValue "runtime.type") { $ids += "database" }
    foreach ($addonId in (Get-ExakitMarketplaceInstalledAddons)) {
        $addon = Get-ExakitMarketplaceAddon $addonId
        if ($addon -and $addon.PSObject.Properties["StatusFn"] -and
            (Get-Command $addon.StatusFn -ErrorAction SilentlyContinue)) { $ids += $addonId }
    }
    return $ids
}

function Get-ExakitServiceStatus {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -eq "database") {
        if ((Get-RuntimeType) -eq "nano") { return (Get-NanoStatus) }
        return "unknown"
    }
    $addon = Get-ExakitMarketplaceAddon $Id
    if ($addon -and (Get-Command $addon.StatusFn -ErrorAction SilentlyContinue)) { return (& $addon.StatusFn) }
    return "unknown"
}

function Start-ExakitService {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -eq "database") { Confirm-ExakitRuntimeRunning -Deploy; return }
    $addon = Get-ExakitMarketplaceAddon $Id
    if ($addon -and $addon.PSObject.Properties["StartFn"] -and
        (Get-Command $addon.StartFn -ErrorAction SilentlyContinue)) { [void](& $addon.StartFn) }
}

function Stop-ExakitService {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -eq "database") {
        if ((Get-RuntimeType) -eq "nano") { Stop-Nano }
        return
    }
    $addon = Get-ExakitMarketplaceAddon $Id
    if ($addon -and $addon.PSObject.Properties["StopFn"] -and
        (Get-Command $addon.StopFn -ErrorAction SilentlyContinue)) { [void](& $addon.StopFn) }
}

function Get-ExakitStartupDir {
    if ($env:EXAKIT_STARTUP_DIR) { return $env:EXAKIT_STARTUP_DIR }
    return (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup")
}

function Get-ExakitAutostartEntryPath {
    param([Parameter(Mandatory)][string]$Id)
    return (Join-Path (Get-ExakitStartupDir) "com.exasol.exakit.$Id.cmd")
}

function Register-ExakitAutostart {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -eq "database") {
        # The container's own restart policy is what survives a reboot.
        if ((Get-RuntimeType) -eq "nano") {
            if (Set-NanoRestartPolicy -Policy "always") {
                Ok "database: the container restarts with Docker"
                return $true
            }
            return $false
        }
        return $false
    }
    $addon = Get-ExakitMarketplaceAddon $Id
    if (-not ($addon -and $addon.PSObject.Properties["AutostartFn"] -and
              (Get-Command $addon.AutostartFn -ErrorAction SilentlyContinue))) { return $false }
    $command = & $addon.AutostartFn
    if (-not $command) { return $false }
    $dir = Get-ExakitStartupDir
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $entry = Get-ExakitAutostartEntryPath -Id $Id
    $lines = @(
        "@echo off",
        "rem Starts $Id at login - written by the Exasol Personal Local Starter Kit.",
        "rem Remove it with: exakit autostart off",
        "start `"`" /min $command"
    )
    Set-Content -Path $entry -Value ($lines -join "`r`n") -Encoding Ascii
    Ok "$Id`: starts at login ($entry)"
    return $true
}

function Unregister-ExakitAutostart {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -eq "database" -and (Get-RuntimeType) -eq "nano") {
        [void](Set-NanoRestartPolicy -Policy "no")
    }
    $entry = Get-ExakitAutostartEntryPath -Id $Id
    if (Test-Path $entry) {
        Remove-Item -Force -ErrorAction SilentlyContinue $entry
        Ok "$Id`: no longer starts at login"
    }
}

function Test-ExakitAutostartRegistered {
    param([Parameter(Mandatory)][string]$Id)
    if (Test-Path (Get-ExakitAutostartEntryPath -Id $Id)) { return $true }
    if ($Id -eq "database" -and (Get-RuntimeType) -eq "nano") {
        return (Test-NanoRestartPolicySet)
    }
    return $false
}

function Enable-ExakitAutostart {
    $any = $false
    foreach ($id in (Get-ExakitServiceIds)) {
        if (Register-ExakitAutostart -Id $id) { $any = $true }
    }
    Set-ExakitManifestValue "autostart.enabled" $any
    if ($any) { Info "Everything the kit runs comes back automatically after a restart." }
}

function Disable-ExakitAutostart {
    foreach ($id in (Get-ExakitServiceIds)) { Unregister-ExakitAutostart -Id $id }
    Set-ExakitManifestValue "autostart.enabled" $false
    Ok "Automatic start after a restart is off."
}

function Show-ExakitAutostart {
    Write-Host ""
    Write-Host "  Automatic start after a restart"
    Write-Host "  -------------------------------"
    # Indented to the title, matching exakit_autostart_print in common.sh.
    Write-Host ("  {0,-14} {1}" -f "Service", "Status")
    foreach ($id in (Get-ExakitServiceIds)) {
        $state = if (Test-ExakitAutostartRegistered -Id $id) { "yes" } else { "no" }
        Write-Host ("  {0,-14} {1}" -f $id, $state)
    }
    Write-Host ""
    Info "Turn it on with: exakit autostart on   -   off with: exakit autostart off"
}

function Invoke-CmdAutostart {
    param([string]$Action = "")
    Assert-ExakitInstalled
    Initialize-ExakitLogging
    switch ($Action) {
        { $_ -in @("on", "enable") }   { Enable-ExakitAutostart }
        { $_ -in @("off", "disable") } { Disable-ExakitAutostart }
        { $_ -in @("", "status") }     { Show-ExakitAutostart }
        default { Fail "Unknown option '$Action' for autostart (use: on, off, or no argument to show the state)." }
    }
}

function Invoke-CmdStart {
    Assert-ExakitInstalled
    # Logging first: launcher output belongs in the logfile, not interleaved
    # with the [ok] lines on stdout. Twin of the same fix in cmd_start.
    Initialize-ExakitLogging
    # Everything the kit runs, database first: self-heal semantics for the
    # runtime (a stopped one is started, a missing one created - `exakit start`
    # promises a running database), then every add-on service.
    if ((Get-RuntimeType) -eq "nano" -and (Get-NanoStatus) -eq "running") {
        Ok "Database is already running"
    } else {
        Confirm-ExakitRuntimeRunning -Deploy
    }
    foreach ($id in (Get-ExakitServiceIds)) {
        if ($id -eq "database") { continue }
        Start-ExakitService -Id $id
    }
}

function Invoke-CmdStop {
    Assert-ExakitInstalled
    Initialize-ExakitLogging
    # Add-on services first: they talk to the database, so they should be down
    # before it goes.
    foreach ($id in (Get-ExakitServiceIds)) {
        if ($id -eq "database") { continue }
        Stop-ExakitService -Id $id
    }
    switch (Get-RuntimeType) { "nano" { Stop-Nano } }
}

# Invoke-CmdRepairRuntime [-Yes] - rebuild a database that cannot be started.
#
# THE ESCAPE FROM A WEDGE. When a runtime is deployed but refuses to start, the
# installer used to skip its step as already done, fail at start, and close by
# advising a re-run that behaved the same way - a loop with no exit, and
# EXAKIT_REUSE_DB=0 never got a say because the skip happened first. Re-running
# the platform setup script IS the repair: the deployment step already knows how
# to try a start, watch it fail, and replace the deployment. Dropping the
# `runtime` tick first is what lets it be reached.
#
# DESTRUCTIVE: the deployment is replaced and its data is gone. Interactive runs
# are asked; -Yes and EXAKIT_CONFIRM_RUNTIME_REPAIR=1 pre-answer it.
# twin: cmd_repair_runtime in setup/exakit.
function Invoke-CmdRepairRuntime {
    param([switch]$Yes)
    Assert-ExakitInstalled
    $confirmed = [bool]$Yes
    if ($env:EXAKIT_CONFIRM_RUNTIME_REPAIR -eq "1") { $confirmed = $true }

    $kit = Get-ExakitRepoRoot
    if (-not $kit) { Fail "Could not find the kit copy to re-run setup from. Re-run the installer instead." }
    $setup = Join-Path $kit "setup\setup-windows-docker.ps1"
    if (-not (Test-Path $setup)) { Fail "The kit copy at $kit has no setup\setup-windows-docker.ps1. Re-run the installer instead." }

    Warn2 "Repairing the runtime REPLACES the database. Its data is not recoverable."
    Info "Bundled datasets are reloaded afterwards; anything you loaded yourself is not."
    if (-not $confirmed) {
        if (-not (Confirm-ExakitPrompt "Replace the database and rebuild it now?" $false)) {
            Fail "Nothing was changed. Re-run with -Yes (or EXAKIT_CONFIRM_RUNTIME_REPAIR=1) when you are ready."
        }
    }

    Initialize-ExakitLogging
    # Drop the tick so the deployment step runs even on a runtime whose wedged
    # state the kit cannot yet recognise on its own.
    Remove-ExakitStepDone "runtime"
    Info "Re-running setup\setup-windows-docker.ps1 to rebuild the database"
    $env:EXAKIT_BANNER_SHOWN = "1"
    & $setup
    exit $LASTEXITCODE
}

# Invoke-ExakitUninstallRun -DryRun - remove every artifact the kit installs, in
# dependency order: the local database and ALL its data, the managed MCP client
# configs, the installed AI skills, the exapump profile, the kit home, and the
# CLI binaries. With -DryRun it prints the plan and changes nothing. Mirrors
# exakit_uninstall_run in setup/lib/common.sh. uv/uvx (a shared tool) and the
# PATH entry are intentionally left in place and only reported.
function Invoke-ExakitUninstallRun {
    param([switch]$DryRun)

    # 0a) Boot entries first: a Startup entry left behind would try to start
    #     something that no longer exists at the next login.
    foreach ($svcId in (Get-ExakitServiceIds)) {
        if (Test-ExakitAutostartRegistered -Id $svcId) {
            if ($DryRun) { Info "  will remove: the automatic-start entry for $svcId" }
            else { Unregister-ExakitAutostart -Id $svcId }
        }
    }

    # 0b) Kit-managed marketplace add-ons that live OUTSIDE the kit home (the
    #    VS Code extension). Registry-driven: a new add-on ships its own
    #    UninstallFn and appears here with no edits. A system-installed copy
    #    the kit never managed is not touched (each hook enforces that).
    foreach ($addonId in (Get-ExakitMarketplaceInstalledAddons)) {
        $addonEntry = Get-ExakitMarketplaceAddon $addonId
        if ($addonEntry -and $addonEntry.PSObject.Properties["UninstallFn"] -and
            (Get-Command $addonEntry.UninstallFn -ErrorAction SilentlyContinue)) {
            try { [void](& $addonEntry.UninstallFn -DryRun:$DryRun) }
            catch { Warn2 "Removing the $addonId add-on reported issues (continuing uninstall)" }
        }
    }

    # 1) Database + all data (the Windows runtime is Nano).
    $type = Get-RuntimeType
    if ($type) {
        if ($DryRun) {
            Info "  will remove: local Exasol $type deployment and ALL its data"
        } else {
            Info "Removing the local Exasol $type deployment and all data"
            switch ($type) {
                "nano" { try { Remove-Nano -Data } catch { Warn2 "Database removal reported errors (continuing uninstall)" } }
                default { Warn2 "Unknown runtime type '$type'; skipping database removal" }
            }
        }
    }

    # 2) Managed MCP configuration in the AI clients. Best-effort.
    if (Get-Command Invoke-McpOperation -ErrorAction SilentlyContinue) {
        if ($DryRun) {
            Info "  will remove: managed MCP configuration in Claude (desktop + Claude Code CLI), Cursor, and Codex"
        } else {
            Info "Removing managed MCP configuration from AI clients"
            try { [void](Invoke-McpOperation -Operation "uninstall" -InputArgs @()) }
            catch { Warn2 "Removing the managed MCP client config reported issues (continuing uninstall)" }
        }
    }

    # 3) Installed AI skills: the live kit list, or what the install recorded
    #    once the checkout is gone. One helper, shared with the selectable
    #    uninstall below, so the two paths can never disagree about which
    #    skills belong to the kit.
    $skillNames = @(Get-ExakitKitSkillNames)
    foreach ($root in (Get-ExakitSkillRoots)) {
        foreach ($name in $skillNames) {
            $p = Join-Path $root $name
            if (Test-Path $p) {
                if ($DryRun) { Info "  will remove: AI skill $p" }
                else { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $p }
            }
        }
    }

    # 4) exapump profile store (the kit created it; the binary goes in step 6).
    $exapumpDir = Join-Path $HOME ".exapump"
    if (Test-Path $exapumpDir) {
        if ($DryRun) { Info "  will remove: exapump profiles at $exapumpDir" }
        else { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $exapumpDir }
    }

    # 5) Kit home: credentials, logs, manifest, cached kit copy, MCP snapshots.
    if (Test-Path $script:ExakitHome) {
        if ($DryRun) { Info "  will remove: kit home $script:ExakitHome (credentials, logs, manifest, snapshots)" }
        else { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $script:ExakitHome }
    }

    # 6) CLI binaries. Removed last so earlier steps can still call them.
    #    exakit.cmd is the wrapper cmd.exe is still executing right now; deleting
    #    it in-process makes cmd.exe print "The batch file cannot be found." when
    #    it re-reads the file after we exit. So collect the binaries and hand
    #    their removal to a detached process that waits for us to exit first.
    $binPaths = @()
    # Marketplace add-on launchers are swept by registry id - a new add-on
    # needs no edit here.
    $binNames = @("exakit.cmd", "exapump.exe", "exasol.exe", "exakit.ps1")
    if (Get-Command Get-ExakitMarketplaceAddons -ErrorAction SilentlyContinue) {
        foreach ($addon in Get-ExakitMarketplaceAddons) { $binNames += "$($addon.Id).cmd" }
    }
    foreach ($bin in $binNames) {
        $p = Join-Path $script:BinDir $bin
        if (Test-Path $p) {
            if ($DryRun) { Info "  will remove: CLI binary $p" }
            else { $binPaths += $p }
        }
    }
    if (-not $DryRun -and $binPaths.Count -gt 0) {
        Remove-ExakitBinariesDeferred -Paths $binPaths
    }
}

# Delete the CLI binaries from a short-lived detached PowerShell that first
# waits for this process (and the cmd.exe running exakit.cmd) to exit. Deleting
# exakit.cmd while cmd.exe is still executing it is what makes the shell print
# "The batch file cannot be found."; deferring avoids that entirely.
function Remove-ExakitBinariesDeferred {
    param([string[]]$Paths)
    $waitPids = @($PID)
    try {
        $me = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
        # The parent is the cmd.exe running exakit.cmd - the one that re-reads
        # the batch file after we return. Wait for it too, but not its parent
        # (the user's interactive shell, which never exits).
        if ($me.ParentProcessId) { $waitPids += [int]$me.ParentProcessId }
    } catch { }
    $waitPids = @($waitPids | Sort-Object -Unique)
    $pidList = $waitPids -join ','
    $quoted  = ($Paths | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
    $deferred = @"
foreach (`$id in @($pidList)) { try { Wait-Process -Id `$id -Timeout 60 -ErrorAction SilentlyContinue } catch {} }
Start-Sleep -Milliseconds 250
foreach (`$f in @($quoted)) { try { Remove-Item -Force -ErrorAction SilentlyContinue `$f } catch {} }
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($deferred))
    try {
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList @("-NoProfile", "-WindowStyle", "Hidden", "-EncodedCommand", $encoded) `
            -WindowStyle Hidden | Out-Null
    } catch {
        # If we cannot spawn the detached cleaner, fall back to deleting inline.
        # The batch-file message may reappear, but the binaries are still gone.
        foreach ($f in $Paths) { Remove-Item -Force -ErrorAction SilentlyContinue $f }
    }
}

function Invoke-CmdUninstall {
    param([switch]$AssumeYes, [switch]$DryRun)
    Initialize-ExakitLogging

    if (-not (Test-Path $script:ManifestPath) -and
        -not (Test-Path (Join-Path $script:BinDir "exakit.cmd")) -and
        -not (Test-Path $script:ExakitHome)) {
        Info "Nothing to uninstall - no manifest, kit home, or installed binaries were found."
        return
    }

    # -DryRun previews the FULL plan; -Yes is the scripted full uninstall.
    # Everything else goes through the selectable menu: pick what goes, see
    # what that means, type the word. Twin of cmd_uninstall in setup/exakit.
    if ($DryRun) {
        Write-Host ""
        Warn2 "exakit uninstall PERMANENTLY removes the Exasol Personal Local Starter Kit."
        Info "A full uninstall (the EVERYTHING row, or -Yes) removes:"
        Invoke-ExakitUninstallRun -DryRun
        Write-Host ""
        Info "Not touched: uv/uvx (shared tool), any PATH entry in your profile, and anything the kit did not install."
        Info "Dry run only - nothing was removed. Pick individual pieces interactively with: exakit uninstall"
        return
    }

    if ($AssumeYes) {
        Write-Host ""
        Warn2 "exakit uninstall -Yes removes the FULL kit (all local database data included)."
        Invoke-ExakitUninstallRun
        Write-Host ""
        Ok "Uninstall complete - the Exasol Personal Local Starter Kit has been removed."
        return
    }

    Show-ExakitUninstallMenu
}

# The interactive `exakit uninstall`: pick exactly what goes, see exactly what
# that means, then type the word. Registry-driven for add-ons - a new add-on
# ships its own UninstallFn and appears here with no edits. Twin of
# exakit_uninstall_menu in setup/lib/common.sh.
function Show-ExakitUninstallMenu {
    $tee = $script:UiTee; $corner = $script:UiCorner
    $labels = New-Object System.Collections.Generic.List[string]
    $keys = New-Object System.Collections.Generic.List[string]
    [void]$labels.Add("Skip - uninstall nothing")
    [void]$keys.Add("__skip__")

    # The BUILT-IN components are deliberately NOT rows here. Twin of the
    # comment in exakit_uninstall_menu: the database, its MCP configs, exapump's
    # profile and the pyexasol venv are one working installation, so removing
    # one of them leaves a kit that looks installed and does not work. The two
    # honest choices for the core are keep it (Skip) or remove it (EVERYTHING).
    # Add-ons are optional by construction and nothing depends on them, so they
    # are the only individually selectable rows. A single component can still be
    # removed by name -- exakit uninstall mcp_configs -- as the hint below says.

    # Kit-managed add-ons, each removable on its own (registry-driven).
    $addons = @(Get-ExakitMarketplaceInstalledAddons)
    if ($addons.Count -gt 0) {
        # The scope row, and the caption at the same time. A separate
        # "Add-ons (kit-managed)" caption said the word twice and left the sweep
        # floating above the tree it acts on. Both scope rows say what SURVIVES.
        # Mirrors exakit_uninstall_menu in common.sh.
        [void]$labels.Add("Add-ons only - keeps: database, data, exapump, MCP, pyexasol")
        [void]$keys.Add("__all_addons__")
        for ($i = 0; $i -lt $addons.Count; $i++) {
            $conn = if ($i -eq $addons.Count - 1) { $corner } else { $tee }
            # Indented a level further than the scope row above them.
            [void]$labels.Add("  $conn $($addons[$i])")
            [void]$keys.Add($addons[$i])
        }
    }

    [void]$labels.Add("EVERYTHING - keeps: nothing")
    [void]$keys.Add("everything")
    $everyIdx = $labels.Count

    Write-Host ""
    Write-Host "    One component on purpose: exakit uninstall <database|mcp_configs|skills|exapump|pyexasol>" -ForegroundColor DarkGray

    # EVERYTHING is a MASTER toggle over every row above it: picking it ticks
    # them all, and unticking any single row releases it - so the screen can
    # never claim "everything" while something sits unticked. Skip stays the
    # exclusive opt-out.
    if ($everyIdx -gt 2) {
        $selection = Read-ExakitCheckboxMenu -Title "Select what to uninstall" `
            -Options $labels.ToArray() -Defaults @(1) -ExclusiveIndex 1 `
            -GroupParent $everyIdx -GroupFirst 2 -GroupLast ($everyIdx - 1) -GroupMode "all"
    } else {
        $selection = Read-ExakitCheckboxMenu -Title "Select what to uninstall" `
            -Options $labels.ToArray() -Defaults @(1) -ExclusiveIndex 1
    }
    if ($selection -contains 1) { Info "Nothing was uninstalled."; return }

    $picked = @()
    $pickedLabels = @()
    foreach ($idx in $selection) {
        if ($idx -lt 2) { continue }
        $key = $keys[$idx - 1]
        # BEFORE the "__" skip: the sweep key is spelled like the placeholder
        # keys that skip exists to drop, so checking it afterwards silently
        # discarded the pick and the menu answered "Nothing selected" with the
        # row plainly ticked.
        if ($key -eq "__all_addons__") {
            foreach ($a in $addons) {
                if ($picked -contains $a) { continue }
                $picked += $a
                $pickedLabels += $a
            }
            continue
        }
        if ($key.StartsWith("__")) { continue }
        if ($key -eq "everything") {
            # EVERYTHING swallows any other pick - the full run covers it all.
            $picked = @("everything")
            $pickedLabels = @("EVERYTHING - the full kit (database + data, MCP configs, skills, exapump, pyexasol, add-ons, kit home, exakit)")
            break
        }
        $picked += $key
        $pickedLabels += ($labels[$idx - 1].TrimStart() -replace ("^" + [regex]::Escape($tee) + " "), "" -replace ("^" + [regex]::Escape($corner) + " "), "")
    }
    if ($picked.Count -eq 0) { Info "Nothing selected - nothing was uninstalled."; return }

    # The informed consent: exactly what was picked, then the typed gate.
    Write-Host ""
    Start-ExakitPanel "This will PERMANENTLY remove"
    foreach ($line in $pickedLabels) { Write-ExakitPanelLine $line }
    Complete-ExakitPanel
    Write-Host ""
    Warn2 "This is IRREVERSIBLE. Removed data cannot be recovered."
    if ($picked -contains "database" -or $picked -contains "everything") {
        Warn2 "The database selection deletes ALL local database data."
    }
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        Fail "uninstall needs an interactive terminal to confirm; use -Yes for the scripted full uninstall."
    }
    $answer = Read-Host "  ! Type UNINSTALL to remove the items above (anything else cancels)"
    if ($answer -cne "UNINSTALL") { Info "Uninstall cancelled - nothing was removed."; return }

    Write-Host ""
    foreach ($key in $picked) { Invoke-ExakitUninstallComponent -Key $key }
    Write-Host ""
    Ok "Done. See where you stand with: exakit status"
}

# One selectable piece of the kit, removed on its own. Twin of
# _exakit_uninstall_component in setup/lib/common.sh.
function Invoke-ExakitUninstallComponent {
    param([Parameter(Mandatory)][string]$Key)
    switch ($Key) {
        "database" {
            Info "Removing the local Exasol Nano deployment and all data"
            try { Remove-Nano -Data } catch { Warn2 "Database removal reported errors" }
            Remove-ExakitStepDone "runtime"
        }
        "mcp_configs" {
            Info "Removing the managed MCP configuration from the AI clients"
            try { [void](Invoke-McpOperation -Operation "uninstall" -InputArgs @()) }
            catch { Warn2 "Removing the managed MCP client config reported issues" }
        }
        "skills" {
            foreach ($root in (Get-ExakitSkillRoots)) {
                foreach ($name in (Get-ExakitKitSkillNames)) {
                    $p = Join-Path $root $name
                    if (Test-Path $p) {
                        Info "AI skill $p"
                        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $p
                    }
                }
            }
        }
        "exapump" {
            Info "Removing exapump and its profiles"
            Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $script:BinDir "exapump.exe")
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $HOME ".exapump")
            Remove-ExakitManifestValue "components.exapump"
            Remove-ExakitStepDone "exapump"
        }
        "pyexasol" {
            Info "Removing the pyexasol venv"
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $script:ExakitHome "pyexasol-venv")
            Remove-ExakitManifestValue "components.pyexasol"
            Remove-ExakitStepDone "pyexasol"
        }
        "everything" {
            Invoke-ExakitUninstallRun
            Info "If a PATH entry for $script:BinDir remains in your profile, remove it manually if you no longer need it."
        }
        default {
            # A marketplace add-on: its module owns the removal.
            $addonEntry = Get-ExakitMarketplaceAddon $Key
            if ($addonEntry -and $addonEntry.PSObject.Properties["UninstallFn"] -and
                (Get-Command $addonEntry.UninstallFn -ErrorAction SilentlyContinue)) {
                try { [void](& $addonEntry.UninstallFn) }
                catch { Warn2 "Removing the $Key add-on reported issues" }
            } else {
                Warn2 "The $Key module carries no uninstall - update the kit: exakit update exakit"
            }
        }
    }
}

# Get-ExakitVersionCell <component> <recorded> - what is on the machine now, and what
# the kit put there when they differ. A difference is not an error: it means the
# component was changed outside the kit (a pyexasol upgrade in its venv, an exapump
# build from GitHub, an AI client still pinned to an older MCP server), and saying so
# answers "why does this not match what I installed?" before it has to be asked.
# Twin of _version_cell in setup/exakit.
function Get-ExakitVersionCell {
    param([Parameter(Mandatory)][string]$Component, [string]$Recorded = "")
    # An empty answer means provably absent, and that verdict has to survive: falling
    # back to the record made `exakit version` print a version for a deleted component
    # while update-check and status both said "not installed".
    $live = Get-ExakitComponentCurrent $Component
    if (-not $live -or $live -eq "not installed") { return "not installed" }
    if ($Recorded -and $live -ne $Recorded) { return "$live  (kit installed $Recorded)" }
    return $live
}

# Invoke-CmdVersion - what is INSTALLED, nothing else. The comparison table
# belongs to `exakit update-check` alone; when something newer is waiting, this
# command says so in two lines instead of calling three APIs on every run.
function Invoke-CmdVersion {
    if (-not (Test-Path $script:ManifestPath)) { Write-Host "Not installed (no manifest at $script:ManifestPath)"; exit 4 }
    # runtime.image is a full reference (docker.io/exasol/nano:TAG) while the live
    # probe reports the tag alone. Compare tag with tag, or every Nano install would
    # claim a difference that is not there.
    $runtimeRecorded = Get-ExakitManifestValue "runtime.version"
    if (-not $runtimeRecorded) {
        $runtimeRecorded = Get-ExakitManifestValue "runtime.image"
        if ($runtimeRecorded -and $runtimeRecorded.Contains(":")) {
            $runtimeRecorded = ($runtimeRecorded -split ":")[-1]
        }
    }

    # Collected first, because the three panels are padded to ONE width. Sizing
    # each panel to its own longest line (what Complete-ExakitPanel does alone)
    # staggers them into a staircase, and three boxes of three widths read as
    # broken rather than as one screen. Mirrors cmd_version in setup/exakit.
    $rows = New-Object System.Collections.Generic.List[object]
    $rows.Add(@{ S = "Kit"; L = "Version";   V = "$(Get-ExakitComponentCurrent 'exakit')" })
    $rows.Add(@{ S = "Kit"; L = "Level";     V = "$(Get-ExakitManifestValue 'kit_level')" })
    $rows.Add(@{ S = "Kit"; L = "Source";    V = "$(Get-ExakitManifestValue 'kit.source')" })
    $rows.Add(@{ S = "Kit"; L = "Installed"; V = "$(Format-ExakitLocalTime (Get-ExakitManifestValue 'installed_at'))" })
    $rows.Add(@{ S = "Components"; L = "Runtime";    V = "$(Get-RuntimeType) $(Get-ExakitVersionCell 'runtime' $runtimeRecorded)" })
    $rows.Add(@{ S = "Components"; L = "exapump";    V = "$(Get-ExakitVersionCell 'exapump' (Get-ExakitManifestValue 'components.exapump.version'))" })
    $rows.Add(@{ S = "Components"; L = "MCP server"; V = "$(Get-ExakitManifestValue 'components.mcp_server.package') $(Get-ExakitVersionCell 'mcp' (Get-ExakitManifestValue 'components.mcp_server.version'))" })
    $rows.Add(@{ S = "Components"; L = "pyexasol";   V = "$(Get-ExakitVersionCell 'pyexasol' (Get-ExakitManifestValue 'components.pyexasol.version'))" })

    # Add-ons: every one that is installed OR installable here, so a row saying
    # "not installed" is always one `exakit marketplace` can actually fix. An
    # add-on this machine cannot run is left out entirely rather than dangling an
    # install that would be refused - the same filter, and so the same list, as
    # the marketplace screen itself.
    $addonPending = $false
    $addonCount = 0
    foreach ($addon in (Get-ExakitMarketplaceAddons)) {
        if (-not (Test-ExakitAddonOfferable $addon.Id)) { continue }
        $recordKey = "components." + ($addon.Id -replace "-", "_") + ".version"
        $cell = "$(Get-ExakitVersionCell $addon.Id (Get-ExakitManifestValue $recordKey))"
        # Only offer the marketplace when something is actually left to install.
        if ($cell -like "not installed*") { $addonPending = $true }
        $rows.Add(@{ S = "Add-ons"; L = $addon.Id; V = $cell })
        $addonCount += 1
    }

    # One width for every panel: the widest label+value on the whole screen.
    $w = 0
    foreach ($r in $rows) { $n = 15 + $r.V.Length; if ($n -gt $w) { $w = $n } }

    $first = $true
    foreach ($sec in @("Kit", "Components", "Add-ons")) {
        if ($sec -eq "Add-ons" -and $addonCount -eq 0) { continue }
        if (-not $first) { Write-Host "" }
        $first = $false
        Start-ExakitPanel $sec
        foreach ($r in $rows) {
            if ($r.S -ne $sec) { continue }
            Write-ExakitPanelLine ("{0,-14} {1}" -f $r.L, $r.V.PadRight($w - 15))
        }
        Complete-ExakitPanel
        if ($sec -eq "Add-ons" -and $addonPending) {
            Write-Host "  Install more with: exakit marketplace"
        }
    }
    if (Test-ExakitUpdatesPending) {
        # The same framed panel the connection details use, rather than three loose
        # lines that read like an error: this is good news, and it is the only thing
        # on this screen the reader might want to act on.
        Write-Host ""
        Start-ExakitPanel "Updates available"
        Write-ExakitPanelLine "See what's new   exakit update-check"
        Write-ExakitPanelLine "Apply them       exakit update"
        Complete-ExakitPanel
    }
}

function Get-ExakitUpdateTargets {
    param([string]$Target = "all")
    switch ($Target) {
        "all" {
            # Marketplace add-ons join the routine update set only once they
            # are installed: `exakit update all` must never install a tool the
            # user did not pick from `exakit marketplace`.
            return @(@("exakit", "runtime", "exapump", "mcp", "pyexasol") + (Get-ExakitMarketplaceInstalledAddons))
        }
        { $_ -in @("runtime", "database", "db") } { return @("runtime") }
        { $_ -in @("nano", "personal", "exakit", "exapump", "mcp", "pyexasol", "kit2") } { return @($Target) }
        default {
            # Any registered marketplace add-on is a valid explicit target.
            if (Get-ExakitMarketplaceAddon $Target) { return @($Target) }
            Fail "Unknown update target: $Target"
        }
    }
}

# The marketplace core (registry, menu, apply, offer) lives in
# setup/lib/exakit-common.ps1 so the installer's closing offer can use it too
# - mirroring the bash side, where it all lives in common.sh. This file only
# carries the command entry point.
function Invoke-CmdMarketplace {
    if (-not (Test-Path $script:ManifestPath)) { Fail "No installation found. Run the installer first." }
    Initialize-ExakitLogging
    Show-ExakitMarketplaceMenu
}

# exakit_update_actual_target equivalent: "runtime" names whichever runtime is
# actually installed.
function Get-ExakitActualTarget {
    param([string]$Component)
    if ($Component -eq "runtime") {
        $type = Get-RuntimeType
        if ($type) { return $type }
    }
    return $Component
}

# The upstream lookup helpers (Get-ExakitLatestGithubRelease,
# Get-ExakitLatestPypiVersion, Get-ExakitLatestDockerTag) deliberately live ONLY
# in setup/lib/exakit-common.ps1. This file used to redefine them, and because it
# is dot-sourced afterwards its copies won - including a docker-tag lookup that
# was not architecture-aware, so an x86_64 host could be told an arm64 tag was
# the newest one. One definition, in the library, for both entry points.

function Test-ExakitVersionNewer {
    param([string]$Latest, [string]$Current)
    if (-not $Latest -or -not $Current -or $Latest -eq $Current) { return $false }
    $lk = [regex]::Replace($Latest.TrimStart("v"), '\d+', { param($m) $m.Value.PadLeft(12, '0') })
    $ck = [regex]::Replace($Current.TrimStart("v"), '\d+', { param($m) $m.Value.PadLeft(12, '0') })
    return ([string]::CompareOrdinal($lk, $ck) -gt 0)
}

# Get-ExakitProbedVersion - run a command that reports its own version and return
# just the version. -Raw when the output IS the version (a python one-liner);
# otherwise the first version-shaped token is taken out of a line like
# "exapump 0.11.2". Empty on any failure, so the caller can fall back to the record.
function Get-ExakitProbedVersion {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @(),
        [switch]$Raw
    )
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $out = (& $Command @Arguments 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0 -and -not $out) { return "" }
        $out = ("" + $out).Trim()
        if (-not $out) { return "" }
        if ($Raw) {
            if ($out -match '^[A-Za-z0-9._+-]+$') { return $out }
            return ""
        }
        $match = [regex]::Match($out, '[0-9]+\.[0-9]+[0-9A-Za-z._+-]*')
        if ($match.Success) { return $match.Value }
        return ""
    } catch {
        return ""
    } finally {
        $ErrorActionPreference = $previous
    }
}

# Get-ExakitInstalledMcpVersion - the MCP server is never "installed": uvx
# materialises it per launch. What exists on the machine is the SPEC pinned into each
# AI client config, and that is what runs the next time a client connects. The
# adapters own where those configs live, so the paths come from the kit's own status
# operation rather than a second copy of that knowledge. When clients disagree the
# oldest pin is the answer here; the per-client picture belongs to mcp-doctor, which
# names each client whose managed entry is no longer the one the kit would write, and
# mcp-repair re-writes those entries from the current definition.
# Twin of exakit_installed_mcp_version in setup/lib/common.sh.
function Get-ExakitInstalledMcpVersion {
    if (-not (Get-Command Invoke-McpOperationCli -ErrorAction SilentlyContinue)) { return "" }
    try {
        $json = Invoke-McpOperationCli -Operation "status" -Clients @(
            "claude_desktop", "claude_code", "cursor", "codex",
            "vscode_copilot", "gemini_cli", "opencode", "continue")
        if (-not $json) { return "" }
        $doc = $json | ConvertFrom-Json
        $pins = @{}
        foreach ($artifact in @($doc.artifacts)) {
            if (-not $artifact.path -or -not (Test-Path $artifact.path)) { continue }
            $body = Get-Content $artifact.path -Raw -ErrorAction SilentlyContinue
            if (-not $body) { continue }
            foreach ($m in [regex]::Matches($body, 'exasol-mcp-server@([0-9][0-9A-Za-z._+-]*)')) {
                $pins[$m.Groups[1].Value] = $true
            }
        }
        if ($pins.Count -eq 0) { return "" }
        # The OLDEST pin, not the set: this value is compared against the advertised
        # version, and a comma-joined list is not a version. The oldest is the weakest
        # link - the client that would launch the most outdated server. Which client is
        # stale belongs to `exakit mcp-doctor`, which prints per-client state already.
        $sorted = $pins.Keys | Sort-Object { [regex]::Replace($_, '\d+', { param($m) $m.Value.PadLeft(12, '0') }) }
        return ($sorted | Select-Object -First 1)
    } catch {
        return ""
    }
}

function Get-ExakitComponentCurrent {
    param([string]$Component)
    switch ($Component) {
        "exakit" {
            # kit.version is written by the installer; the kit.source parse is the
            # fallback for installs made before that, and the kit copy's own
            # manifest is the last resort (kit.source is usually "<repo>@main",
            # which is a branch, not a version).
            $version = Get-ExakitManifestValue "kit.version"
            if ($version) { return $version }
            $src = Get-ExakitManifestValue "kit.source"
            if ($src -and $src.Contains("@") -and -not $src.EndsWith("@main")) { return ($src -split "@")[-1] }
            $bundled = Get-ExakitKitBundledVersion
            if ($bundled) { return $bundled }
            return "unknown"
        }
        "exapump" {
            # What is on disk wins over what was recorded: someone may have replaced
            # the binary by hand, and an update check must compare against the thing
            # that actually runs. Provably absent beats a stale record, so a missing
            # binary reports nothing and the table offers the reinstall.
            $bin = Get-ExakitManifestValue "components.exapump.path"
            if (-not $bin -or -not (Test-Path $bin)) {
                $found = Get-Command exapump -ErrorAction SilentlyContinue
                if ($found) { $bin = $found.Source } else { $bin = "" }
            }
            if (-not $bin -or -not (Test-Path $bin)) { return "" }
            $live = Get-ExakitProbedVersion -Command $bin -Arguments @("--version")
            if ($live) { return $live }
            return (Get-ExakitManifestValue "components.exapump.version")
        }
        "mcp" {
            # What the clients are pinned to is what will actually run; the record is
            # the fallback when no client is configured or the module is absent.
            $live = Get-ExakitInstalledMcpVersion
            if ($live) { return $live }
            return (Get-ExakitManifestValue "components.mcp_server.version")
        }
        "pyexasol" {
            $python = Get-ExakitManifestValue "components.pyexasol.python"
            if (-not $python -or -not (Test-Path $python)) {
                $python = Join-Path $script:ExakitHome "pyexasol-venv\Scripts\python.exe"
            }
            if (-not (Test-Path $python)) { return "" }
            $live = Get-ExakitProbedVersion -Command $python `
                -Arguments @("-c", "import pyexasol; print(pyexasol.__version__)") -Raw
            if ($live) { return $live }
            return (Get-ExakitManifestValue "components.pyexasol.version")
        }
        "nano" {
            # The tag on the container beats the record: someone may have recreated
            # it by hand, and an interrupted update can leave the record ahead of
            # what is really running.
            #
            # Unlike exapump and pyexasol, a probe that cannot answer NEVER reports
            # absence here. A closed Docker Desktop is an ordinary, temporary state,
            # and flipping the runtime row to "inspect" every time would be noise.
            # Whether the runtime exists at all is `exakit status`'s question, and it
            # asks the engine directly.
            $live = ""
            try {
                $engine = Get-NanoEngine
                if ($engine -and $engine -ne "none") {
                    Resolve-NanoNames
                    $out = Invoke-ExakitBounded -FilePath $engine `
                        -Arguments @("container", "inspect", "-f", "{{.Config.Image}}", $script:NanoContainer) `
                        -TimeoutSeconds $(if ($env:EXAKIT_ENGINE_PROBE_TIMEOUT) { [int]$env:EXAKIT_ENGINE_PROBE_TIMEOUT } else { 8 })
                    if ($out) { $out = ($out -split "`n" | Select-Object -First 1) }
                    if ($out -and ("" + $out).Contains(":")) { $live = (("" + $out).Trim() -split ":")[-1] }
                }
            } catch { }
            if ($live) { return $live }
            $image = Get-ExakitManifestValue "runtime.image"
            if ($image -and $image.Contains(":")) { return ($image -split ":")[-1] }
            return ""
        }
        "runtime" {
            if ((Get-RuntimeType) -eq "nano") { return (Get-ExakitComponentCurrent "nano") }
            if ((Get-RuntimeType) -eq "personal") { return (Get-ExakitComponentCurrent "personal") }
            return ""
        }
        # The launcher is a different axis from the runtime (see
        # exakit_installed_personal_version in common.sh): the record is the answer.
        "personal" {
            if ((Get-RuntimeType) -eq "personal") { return (Get-ExakitManifestValue "runtime.version") }
            return ""
        }
        default {
            # Marketplace add-ons: the module's own probe is the authority (it
            # asks the actual install and returns nothing for a provably absent
            # one, so a stale manifest record can never claim "installed").
            $addon = Get-ExakitMarketplaceAddon $Component
            if (-not $addon) { return "" }
            if (Get-Command $addon.VersionFn -ErrorAction SilentlyContinue) {
                $live = & $addon.VersionFn
                if ($live) { return $live }
                return ""
            }
            return (Get-ExakitManifestValue ("components." + ($Component -replace "-", "_") + ".version"))
        }
    }
}

# Get-ExakitComponentLatest - the newest version upstream publishes. The
# implementation behind EXAKIT_VERSION_POLICY=latest; under the default manifest
# policy nothing calls it, which keeps `exakit version` off the network.
function Get-ExakitComponentLatest {
    param([string]$Component)
    switch ($Component) {
        "exakit" { return (Get-ExakitLatestGithubRelease $script:KitRepo) }
        "exapump" { return (Get-ExakitLatestGithubRelease $script:ExapumpRepo) }
        "mcp" { return (Get-ExakitLatestPypiVersion $script:McpPackage) }
        "pyexasol" { return (Get-ExakitLatestPypiVersion $script:PyexasolPackage) }
        "nano" { return (Get-ExakitLatestDockerTag) }
        "personal" { return (Get-ExakitLatestGithubRelease "exasol/exasol-personal") }
        "runtime" {
            if ((Get-RuntimeType) -eq "nano") { return (Get-ExakitComponentLatest "nano") }
            if ((Get-RuntimeType) -eq "personal") { return (Get-ExakitComponentLatest "personal") }
            return ""
        }
        default {
            # Marketplace add-ons declare their upstream in versions.json:
            # repo -> a GitHub release, package -> PyPI. No per-add-on arm.
            if (-not (Get-ExakitMarketplaceAddon $Component)) { return "" }
            $repo = Get-ExakitVersionsValue -Path "components.$Component.repo"
            if ($repo) { return (Get-ExakitLatestGithubRelease $repo) }
            $package = Get-ExakitVersionsValue -Path "components.$Component.package"
            if ($package) { return (Get-ExakitLatestPypiVersion $package) }
            return ""
        }
    }
}

# Get-ExakitComponentBlock - where this Component lives in versions.json. One
# mapping serves version, severity, note and min_kit_version.
function Get-ExakitComponentBlock {
    param([string]$Component)
    switch ($Component) {
        "exakit" { return "kit" }
        "kit2" { return "kit2" }
        { $_ -in @("exapump", "mcp", "pyexasol", "nano", "personal") } { return "components.$Component" }
        "runtime" {
            if ((Get-RuntimeType) -eq "nano") { return "components.nano" }
            if ((Get-RuntimeType) -eq "personal") { return "components.personal" }
            return $null
        }
        default {
            # Every marketplace add-on lives at components.<id> by convention.
            if (Get-ExakitMarketplaceAddon $Component) { return "components.$Component" }
            return $null
        }
    }
    return $null
}

# Get-ExakitComponentEnvOverride - the version the user asked for by hand, if any.
# Same precedence as the install path: an explicit EXAKIT_*_VERSION /
# EXAKIT_NANO_TAG outranks the manifest and any upstream lookup, so
# `$env:EXAKIT_EXAPUMP_VERSION="0.11.2"; exakit update exapump` installs exactly
# that (still through the confirmation gate, and still verified - the digest chain
# falls back to the release API when the version is not the advertised one).
function Get-ExakitComponentEnvOverride {
    param([string]$Component)
    $component = $Component
    if ($component -eq "runtime") { $component = Get-RuntimeType }
    switch ($component) {
        "exapump" { return $env:EXAKIT_EXAPUMP_VERSION }
        "mcp" { return $env:EXAKIT_MCP_VERSION }
        "pyexasol" { return $env:EXAKIT_PYEXASOL_VERSION }
        "nano" { return $env:EXAKIT_NANO_TAG }
        "personal" { return $env:EXAKIT_PERSONAL_VERSION }
        default {
            # Marketplace add-ons name their override in the registry.
            $addon = Get-ExakitMarketplaceAddon $component
            if ($addon) { return [Environment]::GetEnvironmentVariable($addon.EnvVar) }
        }
    }
    return ""
}

# Get-ExakitComponentAvailable - the version this kit would install NOW, under the
# policy in force. That is the promise the Tagged column makes, so each policy
# answers from the same place its install path would:
#   env override  the version the user asked for
#   manifest      versions.json
#   latest        a live upstream lookup
#   anything else the compiled-in *Fallback variable
# $null/"" means "cannot tell", which the table reports as unknown.
function Get-ExakitComponentAvailable {
    param([string]$Component)
    $override = Get-ExakitComponentEnvOverride $Component
    if ($override) { return $override }
    if ($script:VersionPolicy -eq "latest") { return (Get-ExakitComponentLatest $Component) }
    if ($script:VersionPolicy -ne "manifest") { return (Get-ExakitComponentFallback $Component) }
    $block = Get-ExakitComponentBlock $Component
    if (-not $block) { return "" }
    $value = Get-ExakitVersionsValue -Path "$block.version"
    if ($value) { return $value }
    # A marketplace add-on can be newer than the published manifest (the kit
    # copy carrying it ships before the advertised set catches up): its
    # module's own fallback constant answers instead of "unknown" - the same
    # version the marketplace install would actually install.
    if (Get-ExakitMarketplaceAddon $Component) { return (Get-ExakitComponentFallback $Component) }
    return ""
}

# The last-known-good constant for a Component: what a no-network install picks.
function Get-ExakitComponentFallback {
    param([string]$Component)
    $component = $Component
    if ($component -eq "runtime") { $component = Get-RuntimeType }
    switch ($component) {
        "exapump" { return $script:ExapumpVersionFallback }
        "mcp" { return $script:McpVersionFallback }
        "pyexasol" { return $script:PyexasolVersionFallback }
        "nano" { return $script:NanoTagFallback }
        # The kit's own version is not one of the constants: it comes from the copy
        # on disk, which is exactly what is installed.
        "exakit" { return (Get-ExakitKitBundledVersion) }
        default {
            # Marketplace add-ons: the module defines the constant the registry
            # names (empty when the module is not loaded).
            $addon = Get-ExakitMarketplaceAddon $component
            if ($addon) {
                $var = Get-Variable -Scope Script -Name $addon.FallbackVar -ErrorAction SilentlyContinue
                if ($var) { return $var.Value }
            }
        }
    }
    return ""
}

# The severity, note and min_kit_version below describe the ADVERTISED set. Under
# `latest` policy the versions on offer come from upstream instead, so pairing
# them with the maintainers' commentary would be actively misleading ("0.12.0 is
# the tested build" next to an available 9.9.9). Report nothing there.
function Test-ExakitManifestMetadataApplies {
    param([string]$Component)
    if ($script:VersionPolicy -ne "manifest") { return $false }
    return (-not (Get-ExakitComponentEnvOverride $Component))
}

# normal | recommended | critical (absent means normal).
function Get-ExakitComponentSeverity {
    param([string]$Component)
    if (-not (Test-ExakitManifestMetadataApplies $Component)) { return "normal" }
    $block = Get-ExakitComponentBlock $Component
    if (-not $block) { return "normal" }
    $value = Get-ExakitVersionsValue -Path "$block.severity"
    if ($value -eq "recommended" -or $value -eq "critical") { return $value }
    return "normal"
}

function Get-ExakitComponentNote {
    param([string]$Component)
    if (-not (Test-ExakitManifestMetadataApplies $Component)) { return "" }
    $block = Get-ExakitComponentBlock $Component
    if (-not $block) { return "" }
    return (Get-ExakitVersionsValue -Path "$block.note")
}

function Get-ExakitComponentMinKit {
    param([string]$Component)
    if (-not (Test-ExakitManifestMetadataApplies $Component)) { return "" }
    $block = Get-ExakitComponentBlock $Component
    if (-not $block) { return "" }
    return (Get-ExakitVersionsValue -Path "$block.min_kit_version")
}

# Test-ExakitComponentSupported - false when no build of it exists for THIS machine.
# The kit must never offer an update for something that cannot be installed here:
# exapump publishes no Windows ARM64 binary (Get-ExapumpAssetName returns $null, and
# the installer skips the step through its own $exapumpSupported gate).
# Twin of exakit_component_supported in setup/lib/common.sh.
function Test-ExakitComponentSupported {
    param([string]$Component)
    # PROCESSOR_ARCHITECTURE is a Windows variable. It is empty when this file runs
    # under PowerShell on macOS or Linux (tests, cross-platform checks), and an empty
    # value must not be read as "some other architecture".
    if ($Component -eq "exapump" -and $env:PROCESSOR_ARCHITECTURE `
            -and $env:PROCESSOR_ARCHITECTURE -ne "AMD64") { return $false }
    return $true
}

# True for changes that stop the database. Intrinsic to the Component, so it
# lives in code rather than in the manifest.
function Test-ExakitComponentHeavy {
    param([string]$Component)
    return ($Component -in @("runtime", "nano", "personal"))
}

# Can this kit run the advertised Component? An unknown kit version never blocks.
function Test-ExakitMinKitSatisfied {
    param([string]$Required)
    $kit = Get-ExakitComponentCurrent "exakit"
    if (-not $kit -or $kit -eq "unknown") { return $true }
    if ($kit -eq $Required) { return $true }
    return (Test-ExakitVersionNewer -Latest $kit -Current $Required)
}

# Is the installed version newer than the one the manifest publishes?
#
# The kit never moves a component backwards: not on request, not with a
# confirmation, not behind an env override. A user who upgraded pyexasol or
# exapump themselves keeps what they chose, and a maintainer who lowers a version
# in versions.json does not drag anyone back with it - to withdraw a bad release,
# publish a higher version. Returns $true when installed is ahead, so the caller
# can leave the component alone.
function Test-ExakitComponentAhead {
    param([string]$Component)
    $current = Get-ExakitComponentCurrent $Component
    $available = Get-ExakitComponentAvailable $Component
    if (-not $current -or -not $available) { return $false }
    if ($current -eq "unknown" -or $current -eq "not installed") { return $false }
    return (Test-ExakitVersionNewer -Latest $current -Current $available)
}

# Where the Tagged column came from, so nobody has to guess whether a stale
# answer is being shown.
function Write-ExakitVersionsSourceLine {
    if ($script:VersionPolicy -eq "latest") {
        Info "Available versions come from live upstream lookups (EXAKIT_VERSION_POLICY=latest)"
        Write-ExakitOverrideLine
        return
    }
    if ($script:VersionPolicy -ne "manifest") {
        Info "Available versions come from this kit's built-in fallbacks (EXAKIT_VERSION_POLICY=$($script:VersionPolicy), no network)"
        Write-ExakitOverrideLine
        return
    }
    $source = Get-ExakitVersionsSource
    if ($source -ne "fetched" -and $source -ne "cache" -and $source -ne "baked") {
        # Nothing readable anywhere: the rows say "unknown" rather than inventing a
        # number, so say that plainly instead of crediting a source.
        Info "The versions manifest could not be read, so the available versions are unknown"
        Write-ExakitOverrideLine
        return
    }
    switch ($source) {
        "fetched" { $text = "the published versions manifest, fetched just now" }
        "cache"   { $text = "the cached copy of the versions manifest" }
        "baked"   { $text = "the versions manifest that shipped with this kit (no network)" }
    }
    $updated = Get-ExakitVersionsValue -Path "updated"
    if ($updated) { $text = "$text, updated $(Format-ExakitManifestDate $updated)" }
    Info "Available versions from $text"
    if (Test-ExakitVersionsSchemaAhead) {
        Info "This kit is older than the published manifest - update it first: exakit update exakit"
    }
    Write-ExakitOverrideLine
}

# An env override outranks every source above, so say so rather than letting the
# line above take credit for a version the user picked.
function Write-ExakitOverrideLine {
    foreach ($component in @("exapump", "mcp", "pyexasol", "nano", "personal")) {
        if (Get-ExakitComponentEnvOverride $component) {
            Info "Some versions come from EXAKIT_* environment overrides and not from the manifest"
            return
        }
    }
}

# The padded, coloured Severity cell. Only a severity that is NOT normal shows
# text, so a flagged row is the only thing that draws the eye. Padding happens
# before colouring so escapes cannot break the column alignment.
function Get-ExakitSeverityCell {
    param([string]$Severity)
    if ($Severity -eq "critical") {
        $cell = "critical".PadRight(11)
        if ($script:UiFancy) { return "$($script:UiWarn)$cell$($script:UiReset)" }
        return $cell
    }
    if ($Severity -eq "recommended") {
        $cell = "recommended".PadRight(11)
        if ($script:UiFancy) { return "$($script:UiOk)$cell$($script:UiReset)" }
        return $cell
    }
    return "-".PadRight(11)
}

# True when a NEWER version is advertised for anything (or a Component is missing
# entirely). Cache-only under the TTL: `exakit version` consults this and has to
# stay instant.
function Test-ExakitUpdatesPending {
    if ($script:VersionPolicy -ne "manifest") { return $false }
    Update-ExakitVersionsCache | Out-Null
    Resolve-ExakitVersionsDoc | Out-Null
    foreach ($component in (Get-ExakitUpdateTargets -Target "all")) {
        $actual = Get-ExakitActualTarget $component
        $available = Get-ExakitComponentAvailable $actual
        if (-not $available) { continue }
        $current = Get-ExakitComponentCurrent $actual
        # A component that is not installed at all is a repair, not a new version.
        # `exakit status` and update-check surface it; counting it here would make
        # `exakit version` claim "New versions are available" with nothing newer.
        if (-not $current -or $current -eq "not installed") { continue }
        if ($current -eq "unknown") { continue }
        if (Test-ExakitVersionNewer -Latest $available -Current $current) { return $true }
    }
    return $false
}

# Invoke-CmdUpdateCheck - THE comparison table. It is the only command that
# renders it: `exakit version` prints a short hint instead, and `exakit update`
# prints just the work it is about to do. Someone who asks explicitly gets fresh
# data: the TTL exists for readers that run behind other commands.
# Twin of exakit_print_update_check in setup/lib/common.sh.
function Invoke-CmdUpdateCheck {
    param([string]$Target = "all")
    if (-not (Test-Path $script:ManifestPath)) { Write-Host "Not installed (no manifest at $script:ManifestPath)"; exit 4 }
    if (-not $Target) { $Target = "all" }
    $targets = Get-ExakitUpdateTargets -Target $Target
    if ($script:VersionPolicy -eq "manifest") {
        Update-ExakitVersionsCache -Force | Out-Null
        Resolve-ExakitVersionsDoc | Out-Null
    }
    Write-Host ""
    Write-Host "  Component update check"
    Write-Host "  ----------------------"
    "{0,-10} {1,-17} {2,-17} {3,-11} {4}" -f "Component", "Installed", "Tagged", "Severity", "Action" | Write-Host
    $updates = 0
    $heavyPending = $false
    foreach ($component in $targets) {
        $actual = Get-ExakitActualTarget $component
        $current = Get-ExakitComponentCurrent $actual
        if (-not $current) { $current = "not installed" }
        $available = Get-ExakitComponentAvailable $actual
        if (-not $available) { $available = "unknown" }
        $taggedCell = $available
        $rowNote = ""
        $action = "current"
        if (-not (Test-ExakitComponentSupported $actual)) {
            # Nothing to offer and nothing wrong: there is simply no build for this
            # machine, and an update command that cannot succeed must not be printed.
            $current = "not available"
            $action = "-"
            $rowNote = "no $actual build exists for this platform"
        } elseif ($available -eq "unknown" -or $current -eq "unknown") {
            $action = "inspect"
        } elseif ($current -eq "not installed" -and (Test-ExakitComponentHeavy $actual)) {
            # A runtime that is not installed is not a runtime this machine wants:
            # offering to deploy Exasol Personal onto a Nano install would be
            # actively wrong. (A missing light component, by contrast, is exactly
            # the pyexasol repair case below.)
            $action = "inspect"
        } elseif ($current -ne "not installed" -and (Test-ExakitVersionNewer -Latest $current -Current $available)) {
            # Installed is ahead of the published set. The kit never moves a
            # component backwards, so there is nothing to offer: lowering a version
            # in versions.json is not a rollback lever, and a user who upgraded a
            # component themselves keeps what they chose. Counts toward neither the
            # "apply them in one go" hint nor the heavy deferral, because no command
            # belongs in this row at all.
            #
            # The row says only "none". The Tagged column already shows the lower
            # number next to the installed one, so the reader can see why; adding an
            # apology for it made the kit sound untested rather than current.
            $action = "none"
        } elseif ($current -ne $available) {
            $minKit = Get-ExakitComponentMinKit $actual
            if ($minKit -and -not (Test-ExakitMinKitSatisfied -Required $minKit)) {
                $action = "update exakit first (needs kit >= $minKit)"
            } else {
                $action = "exakit update $component"
                if (Test-ExakitComponentHeavy $actual) {
                    $action = "$action (heavy)"
                    $heavyPending = $true
                } else {
                    # Counts only what a plain `exakit update` would actually
                    # apply: a heavy row and a kit-blocked row must not inflate the
                    # "apply them in one go" hint below.
                    $updates += 1
                }
            }
        }
        "{0,-10} {1,-17} {2,-17} {3} {4}" -f $actual, $current, $taggedCell,
            (Get-ExakitSeverityCell (Get-ExakitComponentSeverity $actual)), $action | Write-Host
        if ($rowNote) { Write-Host ("    " + $rowNote) }
        $note = Get-ExakitComponentNote $actual
        if ($note) { Write-Host ("    " + $note) }
    }
    Write-Host ""
    # This command just worked out the truth the long way. Retire the cached plan so
    # the next notice cannot repeat something the table above has contradicted.
    if ($script:NoticePlanPath -and (Test-Path $script:NoticePlanPath)) {
        Remove-Item -Force $script:NoticePlanPath -ErrorAction SilentlyContinue
    }
    Write-ExakitVersionsSourceLine
    Write-ExakitMarketplaceDiscoveryLine
    if ($updates -gt 1) { Info "Apply the quick ones in one go with: exakit update" }
    if ($heavyPending) { Info "A runtime change stops the database - exakit update offers it on a console, or run it directly: exakit update runtime" }
}

# --- the heavy (runtime) update, offered inline instead of handed back --------
#
# `exakit update` used to refuse the heavy part outright: it printed "needs the
# database stopped, so it is not part of a routine update" and left the user to
# run `exakit update runtime` themselves, after stopping nothing and updating
# nothing. The work was never the problem - the second command was. On a console
# the offer is now made where the user already is, and one "y" runs the whole
# sequence: stop the database, update the runtime, bring it back up, say so.
#
# Both entry points run the SAME implementation:
# Invoke-ExakitRuntimeComponentUpdate below is what the update loop's runtime
# branch calls and what the inline offer calls.

# Invoke-ExakitRuntimeComponentUpdate - the runtime component updater itself, in
# one place. Twin of the runtime/nano/personal arms of exakit_update_component in
# setup/lib/common.sh.
function Invoke-ExakitRuntimeComponentUpdate {
    param([Parameter(Mandatory)][string]$Component, [string]$Advertised)
    # Defence in depth, mirroring exakit_update_component. The updaters below
    # install whatever version they are handed, so the refusal lives here too and
    # not only in the caller: there is no downgrade in this kit, by any route.
    if (Test-ExakitComponentAhead $Component) {
        Ok "$Component is newer than the tested version - keeping yours"
        return
    }
    switch ($Component) {
        "runtime" {
            if ((Get-RuntimeType) -eq "nano" -and $Advertised) { Update-Nano -LatestTag $Advertised }
        }
        "nano" {
            if ($Advertised) { Update-Nano -LatestTag $Advertised }
        }
        "personal" {
            Warn2 "Exasol Personal local deployments are macOS-only in this kit. On Windows this target is reported for catalog parity but cannot be applied."
        }
    }
}

# Get-ExakitRuntimeStatus / Start-ExakitRuntime - the runtime-agnostic pair the
# inline offer needs to keep its promise ("the database is running again
# afterwards"). Only Nano exists on this path; anything else answers "" for
# "cannot tell", which is not the same as "not running".
# Twins of exakit_runtime_status / exakit_runtime_start in setup/lib/common.sh.
function Get-ExakitRuntimeStatus {
    if ((Get-RuntimeType) -eq "nano") {
        try { return (Get-NanoStatus) } catch { return "" }
    }
    return ""
}

function Start-ExakitRuntime {
    if ((Get-RuntimeType) -eq "nano") { Start-Nano }
}

# Test-ExakitRuntimeUpdateStaged - true for an Exasol Personal MAJOR upgrade: a
# data migration with its own backup-gated three-step flow (--plan, --backup,
# --apply), which a single y/N is not informed consent for. Personal is macOS-only
# in this kit, so on Windows this is false in practice; it stays here so both
# sides of the mirror make the same decision from the same inputs.
# Twin of exakit_runtime_update_is_staged in setup/lib/common.sh.
function Test-ExakitRuntimeUpdateStaged {
    param([string]$Installed, [string]$Advertised)
    if ((Get-RuntimeType) -ne "personal") { return $false }
    $installedMajor = Get-ExakitMajorVersion $Installed
    $advertisedMajor = Get-ExakitMajorVersion $Advertised
    if (-not $installedMajor -or -not $advertisedMajor) { return $false }
    return ($installedMajor -ne $advertisedMajor)
}

# Get-ExakitMajorVersion - "2.1.0" -> "2", "v2026.2.0-nano.2" -> "2026". Empty
# when the string does not start with a number.
# Twin of exakit_major_version in setup/lib/common.sh.
function Get-ExakitMajorVersion {
    param([string]$Version)
    if (-not $Version) { return "" }
    $match = [regex]::Match($Version.TrimStart("v"), '^\d+')
    if ($match.Success) { return $match.Value }
    return ""
}

# Get-ExakitRuntimeUpdatePreanswer - "yes", "no", or "" when nobody has answered
# yet. Two ways to answer without a prompt, and they are the ways this kit already
# uses: `exakit update -Yes` (the uninstall flag spelling, and -y/--yes too) and
# EXAKIT_CONFIRM_RUNTIME_UPDATE, the variable that already pre-answers
# `exakit update runtime`. One opt-in, both entry points.
# Twin of exakit_runtime_update_preanswer in setup/lib/common.sh.
function Get-ExakitRuntimeUpdatePreanswer {
    param([bool]$AssumeYes = $false)
    if ($AssumeYes) { return "yes" }
    $preset = [Environment]::GetEnvironmentVariable("EXAKIT_CONFIRM_RUNTIME_UPDATE")
    if ($preset) {
        if ($preset -cmatch '^(1|y|Y|yes|YES|Yes)$') { return "yes" }
        if ($preset -cmatch '^(0|n|N|no|NO|No)$') { return "no" }
    }
    return ""
}

# Write-ExakitRuntimeUpdateExplanation - what the user is about to agree to,
# before they agree to it: that the database goes down, roughly for how long, that
# it comes back up, and what happens to the data. Stopping a database is
# disruptive and outward-facing; a bare "[y/N]" is not enough to consent to it.
# Twin of exakit_runtime_update_explain in setup/lib/common.sh.
function Write-ExakitRuntimeUpdateExplanation {
    param([string]$Actual, [string]$Installed, [string]$Advertised)
    Warn2 "$Actual $Installed -> $Advertised needs the database stopped."
    switch ($Actual) {
        "nano" {
            Info "The database goes down while the container is recreated, then it is started again and checked - usually a minute or two, longer if the new image still has to be pulled."
            Info "Your data is kept: the same data volume is reused, and the previous image is put back if the new container does not come up."
        }
        "personal" {
            Info "The launcher is replaced; the database is checked afterwards and started again if it ends up down - usually under a minute."
            Info "Your data is kept: this update neither deletes nor migrates the deployment's database content."
        }
        default {
            Info "The database goes down for the update and is started again afterwards."
            Info "Your data is kept."
        }
    }
}

# Invoke-ExakitRuntimeUpdateApply - stop, update, start, report. Update-Nano owns
# the sequence itself (it pulls the new image, stops the container, recreates it
# on the SAME data volume, waits for readiness and puts the previous image back if
# it never becomes ready), and it is called here exactly as
# `exakit update runtime` calls it. What this adds is the one thing the prompt
# promises: a database that was up before this command is up after it.
# Twin of exakit_apply_runtime_update in setup/lib/common.sh.
function Invoke-ExakitRuntimeUpdateApply {
    param([Parameter(Mandatory)][string]$Component, [string]$Advertised)
    $wasRunning = ((Get-ExakitRuntimeStatus) -eq "running")
    # The offer above IS the confirmation the runtime updater asks for. Asking one
    # question twice is not a safety feature, so the answer is passed down.
    $env:EXAKIT_CONFIRM_RUNTIME_UPDATE = "1"
    Invoke-ExakitRuntimeComponentUpdate -Component $Component -Advertised $Advertised
    $status = Get-ExakitRuntimeStatus
    if ($wasRunning -and $status -and $status -ne "running" -and $status -ne "starting") {
        Info "Bringing the database back up"
        Start-ExakitRuntime
        $status = Get-ExakitRuntimeStatus
    }
    if ($status -eq "running") {
        Ok "Runtime updated and the database is running again."
    } elseif ($status -eq "starting") {
        Ok "Runtime updated; the database is still coming up - check it with: exakit status"
    } elseif (-not $status) {
        Ok "Runtime updated."
    } else {
        Warn2 "Runtime updated, but the database reports '$status' - start it with: exakit start"
    }
}

# Invoke-ExakitRuntimeUpdateOffer - the heavy part of a routine `exakit update`,
# decided here instead of being handed to the user as homework. Returns $true when
# it was applied, $false when it was deferred (and then prints the exact command
# that applies it later).
#
# On backups: the kit has no data-export facility, and this path needs none.
# Update-Nano recreates the container over the persisted data volume, records a
# pre-update snapshot of the runtime metadata under
# ~\.exasol-starter-kit\backups\nano-update\, and restores the previous image if
# the new one will not start. The one runtime change that IS a data migration is
# the Exasol Personal major upgrade, which already has a real backup inside its
# own three-step flow - which is why this function refuses to start it from a y/N.
# Twin of exakit_offer_runtime_update in setup/lib/common.sh.
function Invoke-ExakitRuntimeUpdateOffer {
    param(
        [Parameter(Mandatory)][string]$Component,
        [string]$Actual,
        [string]$Installed,
        [string]$Advertised,
        [bool]$AssumeYes = $false
    )
    if (Test-ExakitRuntimeUpdateStaged -Installed $Installed -Advertised $Advertised) {
        Warn2 "$Actual $Installed -> $Advertised is a major upgrade: it needs a backup and a data migration, so a routine update does not start it."
        Info "See the steps first:  exakit update runtime --plan"
        return $false
    }
    $preanswer = Get-ExakitRuntimeUpdatePreanswer -AssumeYes $AssumeYes
    if ($preanswer -eq "no") {
        Warn2 "$Actual $Installed -> $Advertised was left alone: the runtime update is answered 'no' (EXAKIT_CONFIRM_RUNTIME_UPDATE)."
        Info "Apply it when convenient:  exakit update runtime"
        return $false
    }
    if ($preanswer -eq "yes") {
        Write-ExakitRuntimeUpdateExplanation -Actual $Actual -Installed $Installed -Advertised $Advertised
    } else {
        # No console, no answer: a prompt nobody can answer must never turn into a
        # stopped database, so a redirected run, a CI job and a scheduled task all
        # get exactly today's safe deferral.
        if (-not (Test-ExakitInteractive)) {
            Warn2 "$Actual $Installed -> $Advertised needs the database stopped, so it is not part of a routine update."
            Info "Apply it when convenient:  exakit update runtime"
            Info "Unattended runs can opt in:  exakit update -Yes  (or EXAKIT_CONFIRM_RUNTIME_UPDATE=1)"
            return $false
        }
        Write-ExakitRuntimeUpdateExplanation -Actual $Actual -Installed $Installed -Advertised $Advertised
        if (-not (Confirm-ExakitPrompt "Stop the database and update the runtime now?" $false)) {
            Info "Nothing was stopped. Apply it when convenient:  exakit update runtime"
            return $false
        }
    }
    Invoke-ExakitRuntimeUpdateApply -Component $Component -Advertised $Advertised
    return $true
}

# Invoke-CmdUpdate - apply the advertised versions. Prints its work plan, not the
# full table. A pending runtime change stops the database, so it is applied only
# for an answer this run was given: the console is asked, -AssumeYes and
# EXAKIT_CONFIRM_RUNTIME_UPDATE answer without asking, and an unattended run with
# neither defers it with the exact command that applies it later.
# Twin of exakit_update in setup/lib/common.sh.
function Invoke-CmdUpdate {
    param([string]$Target = "all", [bool]$AssumeYes = $false)
    Assert-ExakitInstalled
    Initialize-ExakitLogging
    if (-not $Target) { $Target = "all" }
    if ($AssumeYes) {
        # -Yes answers the only question this command asks: may it stop the
        # database. Update-Nano reads the same variable, so an explicit
        # `exakit update runtime -Yes` is unprompted for the same reason.
        $env:EXAKIT_CONFIRM_RUNTIME_UPDATE = "1"
    }
    # An explicit update applies what is advertised RIGHT NOW.
    if ($script:VersionPolicy -eq "manifest") {
        Update-ExakitVersionsCache -Force | Out-Null
        Resolve-ExakitVersionsDoc | Out-Null
    }
    Write-ExakitVersionsSourceLine
    $deferred = 0
    $acted = 0
    foreach ($component in (Get-ExakitUpdateTargets -Target $Target)) {
        $actual = Get-ExakitActualTarget $component
        $current = Get-ExakitComponentCurrent $actual
        $available = Get-ExakitComponentAvailable $actual
        # No build for this machine: a routine update stays quiet about it (there is
        # nothing the user can do), and an explicit target says why rather than
        # failing deep inside the installer.
        if (-not (Test-ExakitComponentSupported $actual)) {
            if ($Target -eq "all") { continue }
            Fail "$actual has no build for this platform, so there is nothing to update."
        }
        # Nothing advertised for this component (unreadable manifest, or a
        # component this kit knows nothing about): a routine update says so and
        # moves on. An explicit single target still runs, so its updater can
        # report the real reason.
        if ($Target -eq "all" -and -not $available) {
            Warn2 "No advertised version for $actual - skipping it. Details: exakit update-check"
            continue
        }
        # Never backwards, and this has to be settled BEFORE the heavy branch.
        # That branch gates on $current -ne $available and then continues, so it
        # used to reach the runtime offer with the installed version AHEAD of the
        # tested one and ask to stop the database for a downgrade - while
        # `exakit update-check` rendered the same row as "none" and every light
        # component said "keeping yours". Different is not behind. Asked once
        # here, for every component, so no later branch can reach an update path
        # by skipping the question.
        if (Test-ExakitComponentAhead $actual) {
            $shown = $current
            if (-not $shown) { $shown = "unknown" }
            Ok "$actual $shown is newer than the tested $available - keeping yours"
            continue
        }
        # A blanket update stops the database only for an answer it was given: on a
        # console it asks, with -AssumeYes or the env var it was already told, and
        # with neither it defers exactly as it always did. See
        # Invoke-ExakitRuntimeUpdateOffer.
        if ($Target -eq "all" -and (Test-ExakitComponentHeavy $actual)) {
            if ($current -and $available -and $current -ne "unknown" -and $current -ne $available) {
                # [-1]: the verdict is the LAST thing the offer returns. The
                # updaters it calls can put objects on the pipeline of their own,
                # and an array is truthy no matter what it holds.
                $applied = @(Invoke-ExakitRuntimeUpdateOffer -Component $component -Actual $actual `
                    -Installed $current -Advertised $available -AssumeYes $AssumeYes)[-1]
                if ($applied -eq $true) { $acted += 1 } else { $deferred += 1 }
            }
            continue
        }
        # Only the components this run will actually touch are reported: the work
        # plan, not a status table. `exakit update-check` is where everything is
        # listed, including what is already current.
        if ($current -and $available -and $current -eq $available) { continue }
        # The table's "update exakit first" verdict has to hold here too, or the
        # manifest's only hard compatibility lever would be advice nobody applies.
        $minKit = Get-ExakitComponentMinKit $actual
        if ($minKit -and -not (Test-ExakitMinKitSatisfied -Required $minKit)) {
            Warn2 "$actual $available needs kit >= $minKit - update the kit first: exakit update exakit"
            if ($Target -eq "all") { continue }
            Fail "Refusing to install $actual $available on kit $(Get-ExakitComponentCurrent 'exakit')."
        }
        if ($available) {
            $shown = $current
            if (-not $shown) { $shown = "not installed" }
            Info "$actual $shown -> $available"
        }
        switch ($component) {
            "exakit" {
                Update-ExakitSelf -Advertised $available -Installed $current
            }
            "runtime" { Invoke-ExakitRuntimeComponentUpdate -Component "runtime" -Advertised $available }
            "nano"    { Invoke-ExakitRuntimeComponentUpdate -Component "nano" -Advertised $available }
            "personal" { Invoke-ExakitRuntimeComponentUpdate -Component "personal" -Advertised $available }
            "exapump" {
                if ($available) {
                    $script:ExapumpVersion = $available
                    Remove-Item -Force (Get-ExapumpCli) -ErrorAction SilentlyContinue
                    Install-Exapump
                    New-ExapumpProfile
                    Set-ExakitManifestValue "desired.exapump" $script:ExapumpVersion
                    # $current above came from Get-ExakitComponentCurrent, i.e. the
                    # version the binary on disk reports - never the manifest record.
                    # Install-Exapump writes that record from the version this run
                    # asked for, so it can name a version that is not what ended up
                    # on disk. Confirm from the binary; exapump_update in
                    # setup/lib/exapump.sh keeps the same order.
                    Confirm-ExapumpInstalledVersion | Out-Null
                }
            }
            "mcp" {
                if ($available) {
                    New-McpUpdateSnapshot | Out-Null
                    $script:McpVersion = $available
                    Install-Mcp
                    # $current above came from Get-ExakitComponentCurrent, i.e. the pin
                    # in the AI client configs - never the manifest record. Install-Mcp
                    # writes that record before the configs are refreshed (the renderer
                    # reads it to build the pin), so the record can say the update
                    # landed while every client still launches the old version. The
                    # refresh below is what actually moves them; mcp_update in
                    # setup/lib/mcp.sh keeps the same order.
                    Update-McpClientPins | Out-Null
                    Test-McpServer
                    Set-ExakitManifestValue "desired.mcp" $script:McpVersion
                }
            }
            "pyexasol" {
                if ($available) { Update-Pyexasol | Out-Null }
            }
            "kit2" { Write-ExakitKit2NotAvailable -Command "exakit update kit2" }
            default {
                # Marketplace add-ons dispatch to their module's update function.
                $addon = Get-ExakitMarketplaceAddon $component
                if ($addon -and $available) {
                    if (Get-Command $addon.UpdateFn -ErrorAction SilentlyContinue) { & $addon.UpdateFn | Out-Null }
                    else { Fail "The $component module is not available in this version." }
                }
            }
        }
        $acted += 1
    }
    if ($acted -eq 0 -and $deferred -eq 0) {
        Ok "Everything is already current."
    }
    if ($deferred -gt 0) {
        Info "See everything, including the deferred runtime change: exakit update-check"
    }
}

# Kit 2 is delivered by the bash upgrade scripts (upgrade/upgrade-kit2.sh), which
# apply SQL through exapump and stage the semantic assets. That pipeline has no
# Windows counterpart yet, so the commands exist here only to answer clearly
# rather than to fail with "unknown command" - the same treatment the Windows path
# gave kit self-update until it was implemented.
function Write-ExakitKit2NotAvailable {
    param([string]$Command)
    Warn2 "Kit 2 is not available on the Windows path yet ($Command)."
    Info "The Kit 2 add-on ships with the macOS, Linux and WSL paths; it is planned for Windows."
}

# Defaults to the version actually installed rather than the newest section in the
# file: a user asking what is new wants their own release notes, not a preview of a
# release they do not have.
function Invoke-CmdWhatsNew {
    param([string]$Version = "")
    if (-not $Version) { $Version = Get-ExakitKitBundledVersion }
    if (-not $Version) { $Version = Get-ExakitManifestValue "kit.version" }
    if (-not $Version) {
        Fail "Could not tell which kit version this is. Name one: exakit whats-new 0.2.0"
    }
    if (-not (Write-ExakitWhatsNew -Version $Version -Heading "What's new in $Version")) {
        $root = Get-ExakitRepoRoot
        $file = Get-ExakitWhatsNewFile -KitRoot $root
        if ($file) {
            Info "No notes for $Version. Versions covered:"
            foreach ($v in (Get-ExakitWhatsNewVersions -KitRoot $root)) { Write-Host ("      " + $v) }
        } else {
            Info "This kit copy does not carry setup/whats-new.json."
        }
    }
}

# ---------------------------------------------------------------------------
# Logs (twin of the exakit_log_targets / exakit_logs_* set in common.sh)
# ---------------------------------------------------------------------------
# One command reaches every log the kit can show. Add-ons opt in with a LogFn
# in their registry entry, so a new one is viewable with no wiring here.
function Get-ExakitLogTargets {
    $targets = @()
    $setup = Get-ChildItem -Path $script:LogDir -Filter "install-*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($setup) {
        $targets += [pscustomobject]@{ Id = "setup"; Label = "Installer and setup runs"; Kind = "file"; Source = $setup.FullName }
    }
    if ((Get-RuntimeType) -eq "nano") {
        $engine = Get-NanoEngine
        if ($engine -and $engine -ne "none") {
            Resolve-NanoNames
            $targets += [pscustomobject]@{ Id = "database"; Label = "Database container"; Kind = "cmd"
                Source = $engine; Container = $script:NanoContainer }
        }
    }
    foreach ($addonId in (Get-ExakitMarketplaceInstalledAddons)) {
        $addon = Get-ExakitMarketplaceAddon $addonId
        if (-not ($addon -and $addon.PSObject.Properties["LogFn"] -and
                  (Get-Command $addon.LogFn -ErrorAction SilentlyContinue))) { continue }
        $path = & $addon.LogFn
        if ($path) {
            $targets += [pscustomobject]@{ Id = $addonId; Label = "$addonId service"; Kind = "file"; Source = $path }
        }
    }
    return $targets
}

# Show-ExakitLogsOverviewJson - the same listing, machine-readable, so an agent
# can pick a target and its path without parsing a column-aligned table. Always
# an object, including when there are no logs at all, so a parser never gets
# empty stdout (the rule every other -Json surface follows).
# twin: exakit_logs_overview_json in setup/lib/common.sh.
function Show-ExakitLogsOverviewJson {
    $targets = Get-ExakitLogTargets
    $rows = @()
    foreach ($target in $targets) {
        $size = "-"; $updated = "-"
        if ($target.Kind -eq "cmd") {
            $size = "live"; $updated = "kept by the engine"
        } elseif (Test-Path $target.Source) {
            $item = Get-Item $target.Source
            $size = if ($item.Length -ge 1MB) { "$([int]($item.Length / 1MB))M" }
                    elseif ($item.Length -ge 1KB) { "$([int]($item.Length / 1KB))K" }
                    else { "$($item.Length)B" }
            $updated = $item.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
        }
        $rows += [pscustomobject]@{
            target  = $target.Id
            what    = $target.Label
            kind    = $target.Kind
            # A command-backed target has no file; null is the honest answer and
            # is what tells a caller to use `exakit logs <target>` instead.
            path    = if ($target.Kind -eq "cmd") { $null } else { $target.Source }
            command = if ($target.Kind -eq "cmd") { $target.Source } else { $null }
            size    = $size
            updated = $updated
        }
    }
    [pscustomobject]@{ count = $rows.Count; targets = @($rows) } | ConvertTo-Json -Depth 6
}

function Show-ExakitLogsOverview {
    $targets = Get-ExakitLogTargets
    if ($targets.Count -eq 0) {
        Info "No logs yet. They appear here after an install or once a service has run."
        return
    }
    Write-Host ""
    Write-Host "  Component logs"
    Write-Host "  --------------"
    Write-Host ("{0,-22} {1,-26} {2,-8} {3}" -f "Target", "What", "Size", "Updated")
    foreach ($target in $targets) {
        if ($target.Kind -eq "cmd") {
            Write-Host ("{0,-22} {1,-26} {2,-8} {3}" -f $target.Id, $target.Label, "live", "kept by the engine")
            continue
        }
        $size = "-"; $updated = "-"
        if (Test-Path $target.Source) {
            $item = Get-Item $target.Source
            $size = if ($item.Length -ge 1MB) { "$([int]($item.Length / 1MB))M" }
                    elseif ($item.Length -ge 1KB) { "$([int]($item.Length / 1KB))K" }
                    else { "$($item.Length)B" }
            $updated = $item.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
        }
        Write-Host ("{0,-22} {1,-26} {2,-8} {3}" -f $target.Id, $target.Label, $size, $updated)
    }
    Write-Host ""
    Info "View one:  exakit logs <target>        (add -f to follow it live)"
    Info "Its path:  exakit logs <target> --path"
}

function Show-ExakitLog {
    param([Parameter(Mandatory)][string]$Target, [switch]$Follow, [int]$Lines = 200, [switch]$PathOnly)
    $entry = Get-ExakitLogTargets | Where-Object { $_.Id -eq $Target } | Select-Object -First 1
    if (-not $entry) {
        $known = ((Get-ExakitLogTargets | ForEach-Object { $_.Id }) -join " ")
        Fail ("No log called '$Target'." + $(if ($known) { " Available: $known" } else { "" }))
    }
    if ($entry.Kind -eq "cmd") {
        if ($PathOnly) { Write-Host "$($entry.Source) logs $($entry.Container)"; return }
        $engineArgs = @("logs", "--tail", $Lines, $entry.Container)
        if ($Follow) { $engineArgs += "-f" }
        & $entry.Source @engineArgs
        return
    }
    if ($PathOnly) { Write-Host $entry.Source; return }
    if (-not (Test-Path $entry.Source)) {
        Fail "The $Target log has not been written yet ($($entry.Source))."
    }
    if ($Follow) {
        Info "Following $($entry.Source) - Ctrl-C to stop"
        Get-Content -Path $entry.Source -Tail $Lines -Wait
    } else {
        Get-Content -Path $entry.Source -Tail $Lines
    }
}

# exakit logs [target] [-f] [--lines N] [--path] - every log the kit can show,
# in one place. No target lists what is available; a target tails it.
function Invoke-CmdLogs {
    param([string[]]$LogArgs = @())
    $target = ""
    $follow = $false
    $pathOnly = $false
    $json = $false
    $lines = 200
    for ($i = 0; $i -lt $LogArgs.Count; $i++) {
        switch ($LogArgs[$i]) {
            { $_ -in @("-f", "--follow", "-Follow") } { $follow = $true }
            { $_ -in @("--path", "-Path") }           { $pathOnly = $true }
            { $_ -in @("--json", "-j", "-Json") }     { $json = $true }
            { $_ -in @("--lines", "-n", "-Lines") }   { $i++; $lines = [int]$LogArgs[$i] }
            default {
                if ($LogArgs[$i].StartsWith("-")) {
                    Fail "Unknown option '$($LogArgs[$i])' for logs (supported: -f/--follow, --lines N, --path, --json)."
                }
                if ($target) { Fail "Only one log target at a time (got '$target' and '$($LogArgs[$i])')." }
                $target = $LogArgs[$i]
            }
        }
    }
    if (-not $target) {
        if ($json) { Show-ExakitLogsOverviewJson; return }
        Show-ExakitLogsOverview; return
    }
    if ($json) {
        Fail "--json lists the log targets; it does not apply to one target's contents. Use: exakit logs --json, then exakit logs $target --path"
    }
    Show-ExakitLog -Target $target -Follow:$follow -Lines $lines -PathOnly:$pathOnly
}

function Invoke-CmdDataLoad {
    param([string]$ForceFlag = "")
    Assert-ExakitInstalled
    if ($ForceFlag -and $ForceFlag -ne "-Force" -and $ForceFlag -ne "--force") {
        Fail "Unknown option '$ForceFlag' for data-load (only -Force/--force is supported)."
    }
    Initialize-ExakitLogging
    # Loading data needs a database that answers - a stopped one used to make
    # the dataset checks silently trust the manifest and the load itself fail.
    Confirm-ExakitRuntimeRunning -Deploy
    if ($ForceFlag) {
        $kitRoot = Get-ExakitRepoRoot
        if (-not $kitRoot) { Fail "Could not find the kit's sql/ and data/ files to load." }
        # EXAKIT_DATASETS names WHICH datasets; -Force says "reload them even
        # though they are already there". They compose. -Force used to ignore the
        # variable outright and reload the bundled sample alone, so an unattended
        # reload silently restored one of three datasets and reported success.
        if ($env:EXAKIT_DATASETS) {
            $known = @(Get-ExakitBundledDatasets | ForEach-Object { $_.Id })
            $any = $false
            foreach ($id in ($env:EXAKIT_DATASETS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                if ($known -contains $id) {
                    $any = $true
                    Info "Reloading dataset '$id' (EXAKIT_DATASETS, -Force)"
                    Invoke-ExakitDatasetLoad -KitRoot $kitRoot -Id $id -Force
                } else {
                    Warn2 "Unknown dataset id '$id' in EXAKIT_DATASETS (available: $($known -join ', '))."
                }
            }
            if (-not $any) {
                Fail "EXAKIT_DATASETS='$($env:EXAKIT_DATASETS)' matched no bundled dataset - nothing was reloaded."
            }
            return
        }
        Info "Reloading the bundled sample dataset (log: $script:LogFile)"
        Invoke-ExakitSampleDataLoad -KitRoot $kitRoot -Force
    } else {
        Show-ExakitDataLoadMenu
    }
}

function Invoke-CmdMcpSetup {
    Assert-ExakitInstalled
    Initialize-ExakitLogging
    if (-not (Invoke-McpSetup)) { Fail "Could not complete MCP client setup" }
}

function Invoke-CmdMcpOperation {
    param([Parameter(Mandatory)][string]$Operation, [string[]]$OpArgs = @())
    Assert-ExakitInstalled
    Initialize-ExakitLogging
    if (-not (Invoke-McpOperation -Operation $Operation -InputArgs $OpArgs)) {
        Fail "Could not complete MCP $Operation"
    }
}

function Invoke-CmdMcpRestore {
    param([string]$SnapshotId = "")
    Assert-ExakitInstalled
    Initialize-ExakitLogging
    if (-not (Invoke-McpRestore -SnapshotId $SnapshotId)) { Fail "Could not restore managed MCP configuration" }
}

function Invoke-CmdCatalog {
    param([string]$Search = "", [switch]$Json)
    $catalogPath = Join-Path $libDir "catalog.tsv"
    if (-not (Test-Path $catalogPath)) { Fail "Catalog data not found: $catalogPath" }

    # -Json: the command surface itself, machine-readable. Without it an agent
    # told to "discover every command with exakit catalog" had to pattern-match
    # a decorated screen - the one discovery surface with no structured form.
    if ($Json) {
        $q = $Search.ToLowerInvariant()
        $commands = @()
        foreach ($row in (Import-Csv -Path $catalogPath -Delimiter "`t")) {
            if (-not $row.command) { continue }
            $haystack = "$($row.tool) $($row.command) $($row.options) $($row.description)".ToLowerInvariant()
            if ($q -and $haystack -notlike "*$q*") { continue }
            $commands += [pscustomobject]@{
                tool        = $row.tool
                command     = $row.command
                options     = $row.options
                description = $row.description
                invocation  = "$($row.tool) $($row.command)".Trim()
            }
        }
        [pscustomobject]@{
            search   = if ($q) { $q } else { $null }
            count    = $commands.Count
            commands = @($commands)
        } | ConvertTo-Json -Depth 6
        return
    }

    # Let the box-drawing / bullet glyphs render on the Windows console, which
    # defaults to a non-UTF-8 code page; restore the previous encoding after.
    $prevEnc = [Console]::OutputEncoding
    try {
        try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

        $q = $Search.ToLowerInvariant()
        $rule = "$([char]0x2501)" * 49   # heavy horizontal line

        Write-Host ""
        Write-Host "  $rule" -ForegroundColor Cyan
        Write-Host "   $([char]0x25B8) EXASOL" -ForegroundColor Cyan -NoNewline
        Write-Host "  $([char]0x00B7)  starter kit"
        if ($q) {
            Write-Host "     command catalog - results for `"$q`"" -ForegroundColor DarkGray
        } else {
            Write-Host "     command catalog $([char]0x00B7) exakit $([char]0x00B7) exapump $([char]0x00B7) exasol" -ForegroundColor DarkGray
        }
        Write-Host "  $rule" -ForegroundColor Cyan
        Write-Host ""

        $rows = Import-Csv -Path $catalogPath -Delimiter "`t"
        $labels = [ordered]@{
            exakit  = "exakit   - kit lifecycle & MCP management"
            exapump = "exapump  - data loading CLI"
            exasol  = "exasol   - database & AI (MCP) bridge"
        }
        $found = $false
        foreach ($tool in $labels.Keys) {
            $entries = @($rows | Where-Object {
                $_.tool -eq $tool -and (
                    -not $q -or "$($_.tool) $($_.command) $($_.options) $($_.description)".ToLowerInvariant().Contains($q)
                )
            })
            if ($entries.Count -eq 0) { continue }
            $found = $true
            Write-Host "  $($labels[$tool])" -ForegroundColor Green
            foreach ($e in $entries) {
                $name = if ($tool -eq "exasol") { $e.command } else { "$tool $($e.command)" }
                if ($e.options) {
                    Write-Host "    $name " -ForegroundColor White -NoNewline
                    Write-Host $e.options -ForegroundColor DarkGray
                } else {
                    Write-Host "    $name" -ForegroundColor White
                }
                Write-Host "        $($e.description)"
            }
            Write-Host ""
        }

        if (-not $found) {
            Write-Host "  No commands match `"$q`".  Try: exakit catalog mcp" -ForegroundColor DarkGray
            Write-Host ""
            return
        }
        Write-Host "  Tip: " -ForegroundColor DarkGray -NoNewline
        Write-Host "exakit catalog <search>   e.g. exakit catalog data $([char]0x00B7) exakit catalog mcp"
    } finally {
        try { [Console]::OutputEncoding = $prevEnc } catch { }
    }
}

function Invoke-CmdSkillsInstall {
    Initialize-ExakitLogging
    if (-not (Install-ExakitSkills)) { Fail "Could not install the kit's AI skills" }
}

function Invoke-CmdSkills {
    param([switch]$Json)
    if ($Json) { [void](Show-ExakitSkills -Json) } else { [void](Show-ExakitSkills) }
}

# Invoke-CmdInfoJson - the install record, verbatim, on stdout. Mirrors cmd_info_json.
#
# manifest.json is what every other command reads: which runtime, which versions,
# which paths, what the last data load did. `exakit info --json` hands that to a
# script or a support thread without anyone having to know where the file lives.
#
# Printed as read rather than through ConvertFrom-Json/ConvertTo-Json: this is a
# copy of the file, and a round trip could only make it disagree with the file
# (PowerShell 5.1's converter also flattens deep nesting and reorders nothing
# predictably). Read as UTF-8 explicitly - 5.1 would otherwise decode the bytes
# as the system ANSI codepage and corrupt any non-ASCII path in there.
#
# Nothing else may reach stdout on this path - no banner, no update notice, no
# hint - or the output stops being JSON. The caller sets $script:JsonOutput so the
# notice gate at the bottom of the dispatcher skips it, and Fail writes to stderr.
#
# Secrets are not a concern here: the manifest stores password *file paths*
# (runtime.password_file, components.mcp_server.connection.password_file), never a
# password. Keep it that way.
function Invoke-CmdInfoJson {
    if (-not (Test-Path $script:ManifestPath)) {
        Write-ExakitNotInstalledAnswer -Json
    }
    $raw = Get-Content -Raw -Encoding UTF8 -Path $script:ManifestPath
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-ExakitNotInstalledAnswer -Json
    }
    Write-Output $raw.TrimEnd("`r", "`n")
    # THE SAME TRI-STATE AS `status`. AGENTS.md documents 0/3/4 for this command
    # and it only ever answered 0 or 4, so an agent that branched on the exit code
    # the way it was told read "healthy" off a stopped database. The record on
    # stdout is unchanged either way; only the code was lying.
    if ((Get-ExakitRuntimeStatus) -ne "running") { exit 3 }
    exit 0
}

# Invoke-CmdSql <statement> [-Write] - run one SQL statement and translate the
# error. Twin of cmd_sql in setup/exakit; see there for why it exists (the error
# translator was wired only into the kit's own internal SQL, never the path an
# agent actually runs) and why the statement gate is a seatbelt rather than a
# sandbox - the starter-kit profile is the ADMIN connection, and the real
# boundary is the read-only MCP user.
function Invoke-CmdSql {
    param([string]$Statement, [switch]$Write)
    Assert-ExakitInstalled
    if (-not $Statement) { Fail "Nothing to run. Usage: exakit sql 'SELECT ...' [--write]" }

    if (-not $Write) {
        $probe = ($Statement -replace '[\r\n\t]', ' ').TrimStart()
        if ($probe -notmatch '^(?i)\s*(SELECT|WITH|DESCRIBE|EXPLAIN|SHOW)\b') {
            Fail "That is not a read statement, and 'exakit sql' defaults to reads. Re-run with --write if you mean it - and note the profile it uses is the ADMIN connection, not the read-only MCP user."
        }
        # Reject a second statement outright. The MCP tool gate lets
        # "SELECT 1; DROP TABLE T" through because it only inspects the opening
        # keyword; refusing it here costs nothing and removes the same footgun.
        if (($probe -replace ';*\s*$', '') -match ';') {
            Fail "Only one statement at a time. A trailing ';' is fine; a second statement is not."
        }
    }

    $result = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, $Statement)
    if ($result.Output) { Write-Output $result.Output }
    if (-not $result.Success) {
        # The whole point: say what to do about it.
        Show-ExakitDbErrorRemedy $result.Output
        exit 1
    }
    exit 0
}

function Show-ExakitUsage {
    param([switch]$All)
    # `exakit help --all` prints the full command reference: every leading
    # comment line (from line 2 on) up to the first non-comment line - avoids
    # a hard-coded line count going stale whenever the header comment above is
    # edited. Plain `exakit help` (and a bare `exakit`) prints only the short
    # everyday list, so a first-time user sees a handful of commands, not the
    # whole surface. Mirrors the bash usage() tiering.
    #
    # Uses a real `foreach` statement (not ForEach-Object): `break` inside a
    # ForEach-Object script block with no enclosing loop terminates the whole
    # calling scope, not just the loop.
    if ($All) {
        foreach ($line in (Get-Content $PSCommandPath | Select-Object -Skip 1)) {
            if (-not $line.StartsWith("#")) { break }
            Write-Host ($line -replace '^# ?', '')
        }
        return
    }
    @(
        "exakit - Exasol Personal Local Starter Kit"
        ""
        "Get started:"
        "  exakit mcp-setup     connect your AI assistant (Claude, Cursor, Codex)"
        ""
        "Everyday commands:"
        "  status               is the database up and healthy?"
        "  info                 show your connection details"
        "  start | stop         run or pause the local database"
        "  data-load            load the sample data or your own CSV / Parquet"
        "  mcp-doctor           check the AI (MCP) connection"
        "  marketplace          optional add-ons (dashboards & more)"
        ""
        "Keeping up to date:"
        "  version              which versions you have, and which are tested"
        "  update-check         what would change, and what it involves"
        "  update               apply what is waiting, asking first before it"
        "                       stops the database"
    ) | ForEach-Object { Write-Host $_ }
}

# `exakit <command> --help` answers from the catalog - the same single source
# of truth `exakit catalog` renders. Twin of the bash pre-dispatch block.
if ($Command -and ($RestArgs -contains "--help" -or $RestArgs -contains "-h")) {
    $helpCatalog = Join-Path $libDir "catalog.tsv"
    $helpFound = $false
    if (Test-Path $helpCatalog) {
        foreach ($row in (Import-Csv -Path $helpCatalog -Delimiter "`t")) {
            if ($row.tool -eq "exakit" -and ($row.command -eq $Command -or $row.command.StartsWith("$Command "))) {
                Write-Host ("  exakit {0,-14} {1}" -f $row.command, $row.options)
                Write-Host ("      {0}" -f $row.description)
                $helpFound = $true
            }
        }
    }
    if ($helpFound) {
        Write-Host ""
        Write-Host "Full catalog: exakit catalog $Command"
    } else {
        Write-Host "No catalog entry for $Command - browse everything with: exakit catalog"
    }
    exit 0
}

try {
    switch ($Command) {
        "preflight"    { Test-NanoRequirements }
        "status"       {
            $statusJson = ($RestArgs -contains "--json" -or $RestArgs -contains "-j")
            $statusUnknown = @($RestArgs | Where-Object { $_ -notin @("--json", "-j") })
            if ($statusUnknown.Count -gt 0) { Fail "Unknown option '$($statusUnknown[0])' for status (supported: --json)." }
            Invoke-CmdStatus -Json:$statusJson
        }
        "version"      { Invoke-CmdVersion }
        "--version"    { Invoke-CmdVersion }
        "-v"           { Invoke-CmdVersion }
        "update-check"  { Invoke-CmdUpdateCheck -Target ($RestArgs | Select-Object -First 1) }
        "update"        {
            # -y/--yes/-Yes answers the runtime offer, so it must not be mistaken
            # for the target when it is the only argument given.
            $updateYes = ($RestArgs -contains "-Yes" -or $RestArgs -contains "--yes" -or $RestArgs -contains "-y")
            $updateArgs = @($RestArgs | Where-Object { $_ -notin @("-Yes", "--yes", "-y") })
            Invoke-CmdUpdate -Target ($updateArgs | Select-Object -First 1) -AssumeYes $updateYes
        }
        "info"         {
            if ($RestArgs -contains "--json" -or $RestArgs -contains "-j") {
                $script:JsonOutput = $true
                Invoke-CmdInfoJson
            } else {
                Show-ExakitConnectionPanel
                # The --json form was reachable only from `exakit help`. The hint
                # lives here rather than in Show-ExakitConnectionPanel because the
                # install ends with that same panel, and someone finishing an
                # install is not looking for a JSON dump.
                Write-Host "  Machine-readable: exakit info --json"
                Write-Host ""
            }
        }
        "guide"        { Show-ExakitGuide }
        "start"        { Invoke-CmdStart }
        "stop"         { Invoke-CmdStop }
        "sql" {
            $sqlWrite = ($RestArgs -contains "--write" -or $RestArgs -contains "-Write")
            $sqlText = @($RestArgs | Where-Object { $_ -notin @("--write", "-Write") }) | Select-Object -First 1
            Invoke-CmdSql -Statement $sqlText -Write:$sqlWrite
        }
        "repair-runtime" {
            Invoke-CmdRepairRuntime -Yes:([bool]($RestArgs -contains "--yes" -or $RestArgs -contains "-y" -or $RestArgs -contains "-Yes"))
        }
        "autostart"    { Invoke-CmdAutostart -Action (($RestArgs | Select-Object -First 1)) }
        "data-load"    { Invoke-CmdDataLoad -ForceFlag ($RestArgs | Select-Object -First 1) }
        "mcp-setup"    { Invoke-CmdMcpSetup }
        "mcp-repair"   { Invoke-CmdMcpOperation -Operation "repair" -OpArgs $RestArgs }
        "mcp-doctor"   {
            # Diagnosis order: a stopped database is diagnosed as exactly that
            # (exit 3, remedy named) before anything that needs it runs - the
            # first downstream failure used to headline as a broken MCP user.
            # Parse BEFORE asserting: the assertion's own answer has to honour
            # --json and exit 4 rather than 1. Reversing these two lines is what
            # made `mcp-doctor --json` print nothing on an uninstalled machine.
            $doctorJson = ($RestArgs -contains "--json" -or $RestArgs -contains "-j")
            if (-not (Test-Path $script:ManifestPath) -or -not (Get-RuntimeType)) {
                Write-ExakitNotInstalledAnswer -Json:$doctorJson
            }
            $doctorArgs = @($RestArgs | Where-Object { $_ -notin @("--json", "-j") })
            $doctorType = Get-RuntimeType
            $doctorUp = ($doctorType -eq "nano" -and "$(Get-NanoStatus)".StartsWith("running"))
            if (-not $doctorUp) {
                if ($doctorJson) {
                    @{ database = "not running"; remedy = "exakit start" } | ConvertTo-Json
                } else {
                    Warn2 "The database is not running - fix that first: exakit start"
                    Info "MCP diagnostics need a live database (the read-only user and its grants are checked against it)."
                }
                exit 3
            }
            if ($doctorJson) { $env:EXAKIT_MCP_RESULT_JSON = "1" }
            Invoke-CmdMcpOperation -Operation "doctor" -OpArgs $doctorArgs
        }
        "mcp-status"   { Invoke-CmdMcpOperation -Operation "status" -OpArgs $RestArgs }
        "mcp-validate" { Invoke-CmdMcpOperation -Operation "validate" -OpArgs $RestArgs }
        "mcp-remove"   { Invoke-CmdMcpOperation -Operation "uninstall" -OpArgs $RestArgs }
        "mcp-restore"  { Invoke-CmdMcpRestore -SnapshotId ($RestArgs | Select-Object -First 1) }
        "skills"       {
            if ($RestArgs -contains "--json" -or $RestArgs -contains "-j") {
                # Same reason as `info --json`: a trailing update notice would
                # stop the output being parseable JSON.
                $script:JsonOutput = $true
                Invoke-CmdSkills -Json
            } else {
                Invoke-CmdSkills
            }
        }
        "skills-install" { Invoke-CmdSkillsInstall }
        "marketplace"  { Invoke-CmdMarketplace }
        "upgrade-kit2"  { Write-ExakitKit2NotAvailable -Command "exakit upgrade-kit2" }
        "rollback-kit2" { Write-ExakitKit2NotAvailable -Command "exakit rollback-kit2" }
        "uninstall"    { Invoke-CmdUninstall -AssumeYes:($RestArgs -contains "-Yes" -or $RestArgs -contains "--yes" -or $RestArgs -contains "-y") -DryRun:($RestArgs -contains "-DryRun" -or $RestArgs -contains "--dry-run" -or $RestArgs -contains "-n") }
        "whats-new"    { Invoke-CmdWhatsNew -Version ($RestArgs | Select-Object -First 1) }
        "logs"         { Invoke-CmdLogs -LogArgs $RestArgs }
        "catalog"      {
            $catJson = ($RestArgs -contains "--json" -or $RestArgs -contains "-j" -or $RestArgs -contains "-Json")
            $catSearch = @($RestArgs | Where-Object { $_ -notin @("--json", "-j", "-Json") }) | Select-Object -First 1
            Invoke-CmdCatalog -Search $catSearch -Json:$catJson
        }
        { $_ -in @("help", "-h", "--help") } { Show-ExakitUsage -All:($RestArgs -contains "--all" -or $RestArgs -contains "-a") }
        default {
            Write-Host "exakit: unknown command '$Command'" -ForegroundColor Red
            Show-ExakitUsage
            exit 2
        }
    }
    # Only these commands carry the update notice. update-check and update render
    # version state themselves, `version` has its own always-on hint, uninstall is
    # a farewell, and help/catalog are reference screens that stay instant and
    # clean. A command that failed reaches the catch below instead, so the notice
    # never talks over an error - and $script:JsonOutput excludes `info --json`,
    # where a notice on stdout would stop the output being parseable JSON.
    if (-not $script:JsonOutput -and
        @("status", "info", "guide", "start", "stop", "data-load", "preflight",
          "skills", "skills-install", "marketplace", "autostart", "logs", "mcp-setup", "mcp-doctor", "mcp-status",
          "mcp-repair", "mcp-validate", "mcp-restore", "mcp-remove") -contains $Command) {
        Show-ExakitUpdateNotice
    }
} catch [ExakitFailException] {
    # Fail() already printed the error and the log path; just set the exit code.
    exit 1
} catch {
    Write-Host "  x Unexpected error: $_" -ForegroundColor Red
    exit 1
}
