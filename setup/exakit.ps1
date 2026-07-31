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
#   update [what]         apply the advertised versions without deleting database
#                         data; a runtime change is announced, not applied, by
#                         `update all`
#   info                  print the connection details panel
#   guide                 friendly walkthrough: connect AI clients (MCP), SQL
#                         clients (DBeaver), and Python (pyexasol)
#   start                 start the local database
#   stop                  stop the local database
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
#   upgrade-kit2          add the Kit 2 trust assets (bash paths only for now)
#   rollback-kit2         remove what upgrade-kit2 added (bash paths only for now)
#   uninstall [-Yes] [-DryRun]
#                         remove EVERYTHING the kit installed: database + all
#                         data, MCP client configs, skills, exapump, the kit
#                         home and the CLI binaries. -DryRun previews; -Yes
#                         skips the typed confirmation
#   whats-new [version]   what changed in this kit version
#   logs                  print the path of the latest setup log
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

function Get-RuntimeType { return (Get-ExakitManifestValue "runtime.type") }

function Assert-ExakitInstalled {
    if (-not (Test-Path $script:ManifestPath)) { Fail "No installation found. Run the installer first." }
    if (-not (Get-RuntimeType)) { Fail "No runtime recorded in the manifest yet." }
}

function Invoke-CmdStatus {
    if (-not (Test-Path $script:ManifestPath)) {
        Write-Host "Not installed (no manifest at $script:ManifestPath)"
        return
    }
    $type = Get-RuntimeType
    Write-Host "Kit level:  $(Get-ExakitManifestValue 'kit_level')"
    Write-Host "Runtime:    $(if ($type) { $type } else { 'none' })"
    $status = switch ($type) { "nano" { Get-NanoStatus } default { "unknown" } }
    Write-Host "Status:     $status"
    $steps = @(Get-ExakitManifestValue "steps_completed")
    Write-Host "Steps done: $($steps -join ', ')"
    # pyexasol installs soft: when it is missing, say so here with the one command
    # that fixes it, instead of leaving a silent gap in the install.
    $pyexasol = Get-ExakitComponentCurrent "pyexasol"
    if ($pyexasol) {
        Write-Host "pyexasol:   $pyexasol"
    } elseif ($null -ne (Get-ExakitManifestValue "components.pyexasol.validated")) {
        Write-Host "pyexasol:   not installed - repair: exakit update pyexasol"
    }
    Write-Host "Manifest:   $script:ManifestPath"
}

function Invoke-CmdStart {
    Assert-ExakitInstalled
    switch (Get-RuntimeType) { "nano" { Start-Nano } }
}

function Invoke-CmdStop {
    Assert-ExakitInstalled
    switch (Get-RuntimeType) { "nano" { Stop-Nano } }
}

# Invoke-ExakitUninstallRun -DryRun - remove every artifact the kit installs, in
# dependency order: the local database and ALL its data, the managed MCP client
# configs, the installed AI skills, the exapump profile, the kit home, and the
# CLI binaries. With -DryRun it prints the plan and changes nothing. Mirrors
# exakit_uninstall_run in setup/lib/common.sh. uv/uvx (a shared tool) and the
# PATH entry are intentionally left in place and only reported.
function Invoke-ExakitUninstallRun {
    param([switch]$DryRun)

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

    # 3) Installed AI skills. Prefer the live list from the kit's skills dir;
    #    fall back to the known names when the checkout is already gone.
    $skillNames = @()
    try {
        $repoRoot = Get-ExakitRepoRoot
        if ($repoRoot -and (Test-Path (Join-Path $repoRoot "skills"))) {
            $skillNames = Get-ChildItem -Directory (Join-Path $repoRoot "skills") -ErrorAction SilentlyContinue |
                Where-Object { Test-Path (Join-Path $_.FullName "SKILL.md") } |
                ForEach-Object { $_.Name }
        }
    } catch { $skillNames = @() }
    if (-not $skillNames -or $skillNames.Count -eq 0) {
        $skillNames = @("local-agent-ready-starter", "trusted-ai-workflow")
    }
    foreach ($root in @((Join-Path $HOME ".claude\skills"), (Join-Path $HOME ".agents\skills"))) {
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
    foreach ($bin in @("exakit.cmd", "exapump.exe", "exasol.exe", "exakit.ps1")) {
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

    Write-Host ""
    Warn2 "exakit uninstall PERMANENTLY removes the Exasol Personal Local Starter Kit."
    Info "The following will be removed:"
    Invoke-ExakitUninstallRun -DryRun
    Write-Host ""
    Warn2 "This is IRREVERSIBLE - all local database data will be lost."
    Info "Not touched: uv/uvx (shared tool) and any PATH entry in your profile."

    if ($DryRun) { Write-Host ""; Info "Dry run only - nothing was removed."; return }

    if (-not $AssumeYes) {
        if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
            Fail "uninstall needs an interactive terminal to confirm; re-run with -Yes to proceed non-interactively."
        }
        Write-Host "  ! Type " -ForegroundColor Red -NoNewline
        Write-Host "UNINSTALL" -ForegroundColor White -NoNewline
        Write-Host " to confirm (anything else cancels): " -ForegroundColor Red -NoNewline
        $answer = Read-Host
        if ($answer -cne "UNINSTALL") { Info "Uninstall cancelled."; return }
    }

    Write-Host ""
    Invoke-ExakitUninstallRun
    Write-Host ""
    Ok "Uninstall complete - the Exasol Personal Local Starter Kit has been removed."
    Info "If a PATH entry for $script:BinDir remains in your profile, remove it manually if you no longer need it."
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
    if (-not (Test-Path $script:ManifestPath)) { Write-Host "Not installed (no manifest at $script:ManifestPath)"; return }
    Write-Host "Kit version:    $(Get-ExakitComponentCurrent 'exakit')"
    Write-Host "Kit level:      $(Get-ExakitManifestValue 'kit_level')"
    Write-Host "Kit source:     $(Get-ExakitManifestValue 'kit.source')"
    Write-Host "Installed at:   $(Format-ExakitLocalTime (Get-ExakitManifestValue 'installed_at'))"
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
    Write-Host "Runtime:        $(Get-RuntimeType) $(Get-ExakitVersionCell 'runtime' $runtimeRecorded)"
    Write-Host "exapump:        $(Get-ExakitVersionCell 'exapump' (Get-ExakitManifestValue 'components.exapump.version'))"
    Write-Host "MCP server:     $(Get-ExakitManifestValue 'components.mcp_server.package') $(Get-ExakitVersionCell 'mcp' (Get-ExakitManifestValue 'components.mcp_server.version'))"
    Write-Host "pyexasol:       $(Get-ExakitVersionCell 'pyexasol' (Get-ExakitManifestValue 'components.pyexasol.version'))"
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
        "all" { return @("exakit", "runtime", "exapump", "mcp", "pyexasol") }
        { $_ -in @("runtime", "database", "db") } { return @("runtime") }
        { $_ -in @("nano", "personal", "exakit", "exapump", "mcp", "pyexasol", "kit2") } { return @($Target) }
        default { Fail "Unknown update target: $Target" }
    }
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
# operation rather than a second copy of that knowledge. Clients that disagree are all
# reported: "which client is stale" is the useful part, and mcp-doctor/mcp-repair fix
# it. Twin of exakit_installed_mcp_version in setup/lib/common.sh.
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
    }
    return ""
}

# Get-ExakitComponentAvailable - the version this kit would install NOW, under the
# policy in force. That is the promise the Available column makes, so each policy
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
    return (Get-ExakitVersionsValue -Path "$block.version")
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

# Where the Available column came from, so nobody has to guess whether a stale
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
    if (-not (Test-Path $script:ManifestPath)) { Write-Host "Not installed (no manifest at $script:ManifestPath)"; return }
    if (-not $Target) { $Target = "all" }
    $targets = Get-ExakitUpdateTargets -Target $Target
    if ($script:VersionPolicy -eq "manifest") {
        Update-ExakitVersionsCache -Force | Out-Null
        Resolve-ExakitVersionsDoc | Out-Null
    }
    Write-Host ""
    Write-Host "  Component update check"
    Write-Host "  ----------------------"
    "{0,-10} {1,-17} {2,-17} {3,-11} {4}" -f "Component", "Installed", "Available", "Severity", "Action" | Write-Host
    $updates = 0
    $heavyPending = $false
    foreach ($component in $targets) {
        $actual = Get-ExakitActualTarget $component
        $current = Get-ExakitComponentCurrent $actual
        if (-not $current) { $current = "not installed" }
        $available = Get-ExakitComponentAvailable $actual
        if (-not $available) { $available = "unknown" }
        $availableCell = $available
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
            $availableCell = "$available (older)"
            $action = "none - yours is newer than tested"
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
        "{0,-10} {1,-17} {2,-17} {3} {4}" -f $actual, $current, $availableCell,
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
    if ($updates -gt 1) { Info "Apply the quick ones in one go with: exakit update" }
    if ($heavyPending) { Info "A runtime change stops the database - run it when convenient: exakit update runtime" }
}

# Invoke-CmdUpdate - apply the advertised versions. Prints its work plan, not the
# full table, and never stops the database on its own: a pending runtime change is
# announced with the exact command and left for the user to run when it suits
# them. Twin of exakit_update in setup/lib/common.sh.
function Invoke-CmdUpdate {
    param([string]$Target = "all")
    Assert-ExakitInstalled
    Initialize-ExakitLogging
    if (-not $Target) { $Target = "all" }
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
        if ($Target -eq "all" -and (Test-ExakitComponentHeavy $actual)) {
            if ($current -and $available -and $current -ne "unknown" -and $current -ne $available) {
                Warn2 "$actual $current -> $available needs the database stopped, so it is not part of a routine update."
                Info "Apply it when convenient:  exakit update runtime"
                $deferred += 1
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
        # Never backwards. Skipping is the whole behaviour: no prompt, no override,
        # and an explicit `exakit update exapump` says so and exits clean rather
        # than failing, because there is nothing wrong with being ahead.
        if (Test-ExakitComponentAhead $actual) {
            $shown = $current
            if (-not $shown) { $shown = "unknown" }
            Ok "$actual $shown is newer than the tested $available - keeping yours"
            continue
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
            "runtime" {
                if ((Get-RuntimeType) -eq "nano" -and $available) { Update-Nano -LatestTag $available }
            }
            "nano" {
                if ($available) { Update-Nano -LatestTag $available }
            }
            "personal" {
                Warn2 "Exasol Personal local deployments are macOS-only in this kit. On Windows this target is reported for catalog parity but cannot be applied."
            }
            "exapump" {
                if ($available) {
                    $script:ExapumpVersion = $available
                    Remove-Item -Force (Get-ExapumpCli) -ErrorAction SilentlyContinue
                    Install-Exapump
                    New-ExapumpProfile
                    Set-ExakitManifestValue "desired.exapump" $script:ExapumpVersion
                }
            }
            "mcp" {
                if ($available) {
                    New-McpUpdateSnapshot | Out-Null
                    $script:McpVersion = $available
                    Install-Mcp
                    Test-McpServer
                    Warn2 "Run exakit mcp-setup to refresh AI client configs with the new MCP version."
                    Set-ExakitManifestValue "desired.mcp" $script:McpVersion
                }
            }
            "pyexasol" {
                if ($available) { Update-Pyexasol | Out-Null }
            }
            "kit2" { Write-ExakitKit2NotAvailable -Command "exakit update kit2" }
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
        $file = if ($root) { Join-Path $root "WHATS-NEW.md" } else { $null }
        if ($file -and (Test-Path $file)) {
            Info "No notes for $Version. Versions covered:"
            foreach ($line in (Get-Content -Path $file)) {
                if ($line.StartsWith("## ")) { Write-Host ("      " + $line.Substring(3)) }
            }
        } else {
            Info "This kit copy does not carry WHATS-NEW.md."
        }
    }
}

function Invoke-CmdLogs {
    $latest = Get-ChildItem -Path $script:LogDir -Filter "*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { Write-Host $latest.FullName } else { Write-Host "No logs found in $script:LogDir" -ForegroundColor Red; exit 1 }
}

function Invoke-CmdDataLoad {
    param([string]$ForceFlag = "")
    Assert-ExakitInstalled
    if ($ForceFlag -and $ForceFlag -ne "-Force" -and $ForceFlag -ne "--force") {
        Fail "Unknown option '$ForceFlag' for data-load (only -Force/--force is supported)."
    }
    Initialize-ExakitLogging
    if ($ForceFlag) {
        $kitRoot = Get-ExakitRepoRoot
        if (-not $kitRoot) { Fail "Could not find the kit's sql/ and data/ files to load." }
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
    param([string]$Search = "")
    $catalogPath = Join-Path $libDir "catalog.tsv"
    if (-not (Test-Path $catalogPath)) { Fail "Catalog data not found: $catalogPath" }

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
    ) | ForEach-Object { Write-Host $_ }
}

try {
    switch ($Command) {
        "preflight"    { Test-NanoRequirements }
        "status"       { Invoke-CmdStatus }
        "version"      { Invoke-CmdVersion }
        "--version"    { Invoke-CmdVersion }
        "-v"           { Invoke-CmdVersion }
        "update-check"  { Invoke-CmdUpdateCheck -Target ($RestArgs | Select-Object -First 1) }
        "update"        { Invoke-CmdUpdate -Target ($RestArgs | Select-Object -First 1) }
        "info"         { Show-ExakitConnectionPanel }
        "guide"        { Show-ExakitGuide }
        "start"        { Invoke-CmdStart }
        "stop"         { Invoke-CmdStop }
        "data-load"    { Invoke-CmdDataLoad -ForceFlag ($RestArgs | Select-Object -First 1) }
        "mcp-setup"    { Invoke-CmdMcpSetup }
        "mcp-repair"   { Invoke-CmdMcpOperation -Operation "repair" -OpArgs $RestArgs }
        "mcp-doctor"   { Invoke-CmdMcpOperation -Operation "doctor" -OpArgs $RestArgs }
        "mcp-status"   { Invoke-CmdMcpOperation -Operation "status" -OpArgs $RestArgs }
        "mcp-validate" { Invoke-CmdMcpOperation -Operation "validate" -OpArgs $RestArgs }
        "mcp-remove"   { Invoke-CmdMcpOperation -Operation "uninstall" -OpArgs $RestArgs }
        "mcp-restore"  { Invoke-CmdMcpRestore -SnapshotId ($RestArgs | Select-Object -First 1) }
        "skills-install" { Invoke-CmdSkillsInstall }
        "upgrade-kit2"  { Write-ExakitKit2NotAvailable -Command "exakit upgrade-kit2" }
        "rollback-kit2" { Write-ExakitKit2NotAvailable -Command "exakit rollback-kit2" }
        "uninstall"    { Invoke-CmdUninstall -AssumeYes:($RestArgs -contains "-Yes" -or $RestArgs -contains "--yes" -or $RestArgs -contains "-y") -DryRun:($RestArgs -contains "-DryRun" -or $RestArgs -contains "--dry-run" -or $RestArgs -contains "-n") }
        "whats-new"    { Invoke-CmdWhatsNew -Version ($RestArgs | Select-Object -First 1) }
        "logs"         { Invoke-CmdLogs }
        "catalog"      { Invoke-CmdCatalog -Search ($RestArgs | Select-Object -First 1) }
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
    # never talks over an error.
    if (@("status", "info", "guide", "start", "stop", "data-load", "preflight",
          "skills-install", "logs", "mcp-setup", "mcp-doctor", "mcp-status",
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
