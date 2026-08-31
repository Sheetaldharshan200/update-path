# setup-windows-docker.ps1 - Exasol Personal Local Starter Kit, Windows path.
#
# Installs and connects: Exasol Nano (container via Docker Desktop), exapump,
# the Exasol MCP server, and pyexasol. Prints connection details when done.
#
# Usually launched by install.ps1, but runs standalone from a checkout too:
#   powershell -ExecutionPolicy Bypass -File setup\setup-windows-docker.ps1
#
# Safe to re-run: completed steps are skipped, failed steps are retried.

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $PSCommandPath
$LibDir = Join-Path $ScriptDir "lib"
$KitRoot = Split-Path -Parent $ScriptDir

. (Join-Path $LibDir "exakit-common.ps1")
. (Join-Path $LibDir "nano.ps1")
. (Join-Path $LibDir "exapump.ps1")
. (Join-Path $LibDir "mcp.ps1")
. (Join-Path $LibDir "pyexasol.ps1")
# Marketplace add-on modules: sourcing installs NOTHING - the modules are
# needed only so the closing marketplace offer can install what the user says
# yes to. A module missing from an older kit copy just skips its row.
foreach ($addonEntry in (Get-ExakitMarketplaceAddons)) {
    $addonModule = Join-Path $LibDir "$($addonEntry.Id).ps1"
    if (Test-Path $addonModule) { . $addonModule }
}

Initialize-ExakitLogging
Initialize-ExakitManifest
Resolve-ExakitInstallVersions

if ($env:EXAKIT_BANNER_SHOWN -ne "1") { Write-ExakitBanner "Personal Local Starter Kit" }

Set-ExakitManifestValue "os" "windows"
Set-ExakitManifestValue "arch" $env:PROCESSOR_ARCHITECTURE
$kitSource = if ($env:EXAKIT_KIT_SOURCE) { $env:EXAKIT_KIT_SOURCE } else { "checkout:$KitRoot" }
Set-ExakitManifestValue "kit.source" $kitSource
# The kit's own version comes from the versions manifest shipping with THIS
# tree, not from whatever copy an earlier install left under the kit home.
# Record the move BEFORE kit.version is overwritten: the "What's new" box at the
# end of the run reads that record, and it survives a run that dies partway.
Set-ExakitKitUpgradeNote -KitRoot $KitRoot
$kitVersion = Get-ExakitKitVersionAt -KitRoot $KitRoot
if ($kitVersion) { Set-ExakitManifestValue "kit.version" $kitVersion }

try {
    # --- step 1: requirements ------------------------------------------------
    Test-NanoRequirements

    # --- step 2: Nano container -----------------------------------------------
    if (Begin-ExakitStep "runtime" "Step 1/5  Exasol Nano container") {
        Install-Nano
        Set-ExakitStepDone "runtime"
    } elseif ((Get-NanoStatus) -ne "running") {
        Info "Runtime marked done but not running - starting it"
        Install-Nano
    }

    # exapump publishes Windows binaries for x86_64 only. On other
    # architectures (e.g. Windows-on-ARM) the exapump/data/MCP steps are
    # skipped gracefully instead of aborting an install whose database
    # container is already up and fully usable.
    $exapumpSupported = ($env:PROCESSOR_ARCHITECTURE -eq "AMD64")
    if (-not $exapumpSupported) {
        Warn2 "exapump publishes Windows builds for x86_64 only (detected: $($env:PROCESSOR_ARCHITECTURE))."
        Info "Skipping exapump, sample-data loading and MCP client setup - the database container itself is fully supported. Details: quickstarts/windows-docker.md"
    }

    # --- step 3: exapump (data loading CLI) ------------------------------------
    if ($exapumpSupported -and (Begin-ExakitStep "exapump" "Step 2/5  exapump (data loading CLI)")) {
        # Three lines for this step, not nine. Invoke-ExakitLogged animates the
        # label Begin-ExakitStep set, so the Info bullets under it were the
        # second telling. What survives goes through OkStep: what was installed
        # and where, the profile name someone types again, and the one fact the
        # next steps depend on - that the database can persist a schema, not
        # merely answer SELECT 1. Twin of _exakit_install_exapump (common.sh).
        if (Invoke-ExakitSoftStep -Component "exapump" -Repair "exakit update exapump" -Body {
                $prevQuiet = $script:ExakitQuietDetail
                if ($script:UiFancy) { $script:ExakitQuietDetail = $true }
                try {
                    Install-Exapump
                    New-ExapumpProfile
                    Test-ExapumpConnection
                } finally {
                    $script:ExakitQuietDetail = $prevQuiet
                }
            }) {
            Set-ExakitStepDone "exapump"
        }
    }

    # Load the sample data before any MCP configuration. exapump is now up
    # (its only dependency), and doing this first means the read-only MCP
    # user is provisioned, granted, and posture-checked against a schema
    # that already holds the sample tables - and the AI client has data to
    # query the moment it connects. Wrapped so a failed/declined load never
    # aborts the rest of setup (mirrors kit_shared_steps' `|| true` in bash).
    if ($exapumpSupported -and (Test-ExakitSoftFailed "exapump")) {
        Info "Skipping the sample data - it is loaded with exapump, which is not installed"
    } elseif ($exapumpSupported) {
        [void](Invoke-ExakitBestEffort -Component "sample_data" -Repair "exakit data-load" `
            -Label "sample data" `
            -Warning "Sample data load did not finish cleanly." `
            -Body { Request-ExakitDataLoadOffer -KitRoot $KitRoot })
    }

    # --- step 3: AI bridge (server, clients, skills) ----------------------------
    if ($exapumpSupported -and (Begin-ExakitStep "mcp" "Step 3/5  AI bridge (MCP server, clients and skills)")) {
        if (Invoke-ExakitSoftStep -Component "mcp" -Repair "exakit update mcp" -Body {
                # One line for this step's server work: the spinner narrates
                # the prime and the handshake, so the Info/Ok pairs beneath
                # were the second telling. try/finally because the body can
                # throw and this is a soft step - a leaked quiet flag would
                # silence every step after it.
                # Twin of _exakit_install_mcp (common.sh).
                $prevQuiet = $script:ExakitQuietDetail
                if ($script:UiFancy) { $script:ExakitQuietDetail = $true }
                try {
                    Install-Mcp
                    Test-McpServer
                } finally {
                    $script:ExakitQuietDetail = $prevQuiet
                }
            }) {
            Set-ExakitStepDone "mcp"
        }
    }

    # The AI bridge is finished HERE, in the step that says it is being built:
    # the server, the clients that talk to it, the skills those clients load, and
    # the "restart your client" line that makes all three take effect. These two
    # offers used to run at the very end of the run instead - so a reader watched
    # this step announce the AI bridge, sat through pyexasol and the exakit
    # helper, and was then asked which AI clients to connect, under no step at
    # all. The step numbering said one thing and the screen did another.
    #
    # Nothing here needs a later step. The client configs point at `uvx
    # <mcp-server>`, never at the exakit command, and the repo-root lookup falls
    # back to the checkout for skills\ when the helper step has not staged its
    # copy yet. What they DO need is the database and exapump, two steps back.
    # Twin of the same block in kit_shared_steps (common.sh).
    [void](Invoke-ExakitBestEffort -Component "mcp_clients" -Repair "exakit mcp-setup" `
        -Label "AI client (MCP) setup" `
        -Warning "Your local runtime is installed, but MCP client setup did not finish cleanly." `
        -Body { Request-ExakitMcpSetupOffer })

    [void](Invoke-ExakitBestEffort -Component "skills" -Repair "exakit skills-install" `
        -Label "AI skills" `
        -Warning "Skills install did not finish cleanly." `
        -Body { Request-ExakitSkillsInstallOffer })

    # --- step 5: pyexasol (Exasol Python driver) --------------------------------
    # Not gated on $exapumpSupported: pyexasol is pure Python via uv, so it
    # works on Windows-on-ARM too, where only exapump's binary is missing.
    # A failed pyexasol install must not end the run: the exakit helper step
    # below still has to happen, or the user is left without the command that
    # manages everything else. The step stays unmarked so a re-run retries it.
    #
    # Test-PyexasolConnection runs INSIDE the soft step. Outside it, the step was
    # soft in name only: the driver could install fine and any Fail() raised while
    # validating (an unwritable manifest, say) still ended the run before the
    # exakit helper below existed. Install and validate are one isolated unit.
    if (Begin-ExakitStep "pyexasol" "Step 4/5  pyexasol (Exasol Python driver)") {
        # Two lines for this step, not five: the outcome, and the interpreter to
        # run it with. Everything between is in the logfile, and the spinner
        # covered it live. Twin of _exakit_install_pyexasol (common.sh).
        if (Invoke-ExakitSoftStep -Component "pyexasol" -Repair "exakit update pyexasol" -Body {
                $prevQuiet = $script:ExakitQuietDetail
                if ($script:UiFancy) { $script:ExakitQuietDetail = $true }
                try {
                    if (-not (Install-Pyexasol)) { return $false }
                    Test-PyexasolConnection
                    return $true
                } finally {
                    $script:ExakitQuietDetail = $prevQuiet
                }
            }) {
            Set-ExakitStepDone "pyexasol"
        }
    }

    # --- step 6: exakit helper command ------------------------------------------
    # The step flag alone is not trusted: if the shim was removed (cleanup,
    # testing, older builds), a re-run must reinstall it rather than skip -
    # and the PATH check must run either way, since the PATH entry can be
    # missing even when the step is marked done.
    $helperNeeded = Begin-ExakitStep "exakit_helper" "Step 5/5  exakit helper command"
    if (-not $helperNeeded -and -not (Test-Path (Join-Path $script:BinDir "exakit.cmd"))) {
        Info "exakit command is missing - reinstalling it"
        $helperNeeded = $true
    }
    # A re-run over an older install arrives with the flag set and a shim already
    # on disk, so "installed" is not the same as "current". Rewrite one an older
    # kit left behind, or one aimed at a path this kit no longer uses.
    if (-not $helperNeeded -and
        -not (Test-ExakitCmdShimCurrent -PsTarget (Join-Path $script:ExakitHome "kit\setup\exakit.ps1"))) {
        Info "exakit command is out of date - refreshing it"
        $helperNeeded = $true
    }
    if (-not $helperNeeded) {
        Confirm-ExakitOnPath $script:BinDir
    }
    if ($helperNeeded) {
        New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null

        # Keep a copy of the kit library (and the mcp/, sql/, data/ packages
        # Get-ExakitRepoRoot depends on) next to the state so exakit finds
        # them even when this checkout disappears. Copy-ExakitAsset skips any
        # copy whose source already IS the destination - which is the case
        # when install.ps1 downloaded the kit straight into
        # ~\.exasol-starter-kit\kit and ran setup from there.
        $kitSetupDir = Join-Path $script:ExakitHome "kit\setup"
        New-Item -ItemType Directory -Force -Path $kitSetupDir | Out-Null
        Copy-ExakitAsset -Source $LibDir -Destination (Join-Path $kitSetupDir "lib")
        Copy-ExakitAsset -Source (Join-Path $ScriptDir "exakit.ps1") -Destination (Join-Path $kitSetupDir "exakit.ps1")
        # skills/ is not optional decoration: exakit skills, exakit
        # skills-install and the post-install skills step all resolve through
        # the repo-root lookup, which PREFERS this staged copy. Omitting it does
        # not fall back to the checkout - it shadows it, so every one of those
        # commands reports "no skills/ directory in this kit build".
        foreach ($dir in @("mcp", "sql", "data", "skills")) {
            Copy-ExakitAsset -Source (Join-Path $KitRoot $dir) -Destination (Join-Path $script:ExakitHome "kit\$dir")
        }
        # The versions manifest travels with the copy: it is the offline tier of
        # version resolution and the record of which kit version this is.
        Copy-ExakitAsset -Source (Join-Path $KitRoot "versions.json") -Destination (Join-Path $script:ExakitHome "kit\versions.json")
        Copy-ExakitAsset -Source (Join-Path $KitRoot "setup\whats-new.json") -Destination (Join-Path $script:ExakitHome "kit\setup\whats-new.json")

        # Set-ExakitCmdShim owns the shim's content (the kit self-update writes the
        # same file, so it must not drift): the bare `exakit` command is ONLY the
        # .cmd, pointing at the kit's copy by absolute path.
        $shimPath = Set-ExakitCmdShim -PsTarget (Join-Path $kitSetupDir "exakit.ps1")

        Confirm-ExakitOnPath $script:BinDir
        Set-ExakitStepDone "exakit_helper"
        OkStep "exakit installed ($(Get-ExakitTilde (Join-Path $script:BinDir 'exakit.cmd')))"
    }

    # The upgrade news (Write-ExakitWhatsNewBox) and the closing summary
    # (Write-ExakitSoftFailures) are printed after the connection panel at the
    # very end of the run - not here, in the middle of the step output where
    # the connection details would push them off the screen.

    Show-ExakitConnectionSummary
    # Only when the kit version moved during this run, and never able to fail it:
    # every reader inside degrades to silence.
    Write-ExakitWhatsNewBox -KitRoot $KitRoot
    # Last on screen, after the payoff panel: anything that did not complete, with
    # the one command that installs it. A step that failed mid-run scrolls away;
    # this is what the user is still looking at when the installer exits.
    Write-ExakitSoftFailures
    # The install's one closing line, after the panel and after anything that
    # did not finish. Silent when a soft failure was recorded.
    Write-ExakitReadyLine
    # The closing offer: optional marketplace add-ons, asked exactly once, only
    # on an interactive run whose steps all completed, and only while something
    # is actually on offer (an add-on already on this machine is never
    # advertised). Best-effort: nothing in it may end an install that already
    # succeeded.
    # Automatic start defaults to ON for a fresh install: the kit's promise is a
    # database that is simply there, and leaving it off meant a reboot quietly
    # took it away. Only applied when the manifest has no opinion yet, so
    # `exakit autostart off` survives a re-run. Before the offer, so an add-on
    # installed from it joins the boot set.
    [void](Invoke-ExakitBestEffort -Component "autostart" -Repair "exakit autostart on" `
        -Label "automatic start" `
        -Warning "Automatic start could not be turned on." `
        -Body { Enable-ExakitAutostartDefault })
    [void](Invoke-ExakitBestEffort -Component "marketplace" -Repair "exakit marketplace" `
        -Label "marketplace add-ons" `
        -Warning "The marketplace offer did not finish cleanly." `
        -Body { Request-ExakitMarketplaceOffer })
    # A rule, then a heading: the last line on screen is where the reader is
    # left, and run together with whatever the marketplace printed it read as
    # one more of its bullets. The rule gives it air; the green arrow says it
    # is not a step.
    Write-ExakitRule
    Write-ExakitHeading "Run ""exakit help"" for support"
} catch [ExakitFailException] {
    # A hard stop (no container runtime, no database) still owes the user the
    # account of what had already been skipped before it.
    Write-ExakitSoftFailures
    exit 1
} catch {
    # Same "card" shape as Fail(): prominent x header + dim gutter line to the log.
    Write-Host ""
    Write-Host ("  {0}{1} {2}Unexpected error: $_{3}" -f $script:UiErr, $script:UiCross, $script:UiBold, $script:UiReset)
    if ($script:LogFile) { Write-Host ("    {0}{1} Log: {2}{3}" -f $script:UiDim, $script:UiVB, $script:LogFile, $script:UiReset) }
    Write-ExakitSoftFailures
    exit 1
}
