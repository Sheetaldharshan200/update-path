# install.ps1 - Exasol Personal Local Starter Kit, one-command installer (Windows).
#
#   irm https://raw.githubusercontent.com/krishna-exasol/update-path/main/install.ps1 | iex
#
# IMPORTANT: this file must NOT have a UTF-8 BOM. It is only ever executed
# via `irm | iex` (as a fetched string, never read from disk with -File), and
# a BOM that survives into that string as a literal U+FEFF character breaks
# PowerShell's '#' comment-line detection - the parser then tries to execute
# the comment text itself as commands. (setup\setup-windows-docker.ps1 and
# setup\exakit.ps1 are the opposite case: always read from disk via -File,
# where a BOM is the correct fix for a different, real encoding bug - do not
# "fix" those to match this file.)
#
# What it does, in order:
#   1. checks this machine can run the kit (container runtime, memory, free
#      disk) - before anything at all is written
#   2. downloads the starter kit to ~\.exasol-starter-kit\kit (so you can
#      read every script before or after it runs)
#   3. shows the installation plan
#   4. hands off to setup\setup-windows-docker.ps1, which installs the
#      Exasol Nano database container, exapump (data loading CLI), and the
#      MCP server - the same components the macOS/Linux/WSL path installs
#
# Options (environment variables):
#   $env:EXAKIT_DRY_RUN = "1"   show the plan, install nothing
#   $env:EXAKIT_PREFLIGHT = "1" check this machine's requirements, install nothing
#   $env:EXAKIT_REPO    = "..." override the source repo (owner/name)
#   $env:EXAKIT_REF     = "..." override the git ref to install from
#
# Versions (the kit installs the tested set the maintainers publish in
# versions.json; see MAINTAINERS.md and README "Staying up to date"):
#   $env:EXAKIT_VERSION_POLICY = "manifest" | "latest" | "pinned"
#                               manifest (default) = the published tested set,
#                               latest = each component's own upstream,
#                               anything else = built-in fallbacks, no network
#   $env:EXAKIT_VERSIONS_URL = "..."  where that document is fetched from
#                               (https only)
#   $env:EXAKIT_VERSIONS_TTL = "86400"  seconds before the cached copy is
#                               refreshed
#   $env:EXAKIT_NO_UPDATE_NOTICE = "1"  never print the once-a-day update
#                               notice that other exakit commands can show

$ErrorActionPreference = "Stop"
# Silence the progress stream: it hides the noisy download/extract progress
# banners, and on Windows PowerShell 5.1 it makes Invoke-WebRequest below far
# faster (a visible progress bar throttles it by an order of magnitude).
$ProgressPreference = "SilentlyContinue"

# Which part of the install is running. The trap below is the last thing a
# failed install prints, and its advice has to match the failure: "check your
# network or proxy" is only ever true while something is being fetched. It used
# to be printed unconditionally, so a stopped Docker Desktop or a machine under
# the memory minimum - failures the line above had already named exactly - sent
# the reader off to debug a proxy that was never involved.
$InstallPhase = "requirements"

# Any unhandled terminating error below should end with a clean message, not a
# raw PowerShell stack trace. install.ps1 runs as an `irm | iex` string, so a
# script-scope trap is the simplest top-level guard.
trap {
    Write-Host ""
    Write-Host "  Installation failed: $($_.Exception.Message)" -ForegroundColor Red
    if ($InstallPhase -eq "download") {
        Write-Host "  Fix the issue above and re-run. If it keeps happening, check your network or proxy." -ForegroundColor Red
    } else {
        Write-Host "  Fix the issue above and re-run." -ForegroundColor Red
    }
    # Record the reason before exiting, the way install.sh does. This runs before
    # the kit's own logging exists, so a failure here used to leave NOTHING
    # behind on Windows: no log, no note. An agent whose install died at the
    # download step had no artifact to read in its next session and no way to
    # tell "never ran" from "ran and refused". Two lines - reason, then when -
    # because `exakit status --json` reads the date off line 2, and an undated
    # note that outlived its cause is how a healthy machine looks broken.
    # Best-effort: a note is a nicety and must not mask the real error.
    try {
        $failHome = if ($env:EXAKIT_HOME) { $env:EXAKIT_HOME } else { Join-Path $HOME ".exasol-starter-kit" }
        New-Item -ItemType Directory -Force -Path $failHome -ErrorAction SilentlyContinue | Out-Null
        $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Set-Content -Path (Join-Path $failHome ".last-failure") `
            -Value @($_.Exception.Message, $stamp) -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
    exit 1
}

$ExakitHome = if ($env:EXAKIT_HOME) { $env:EXAKIT_HOME } else { Join-Path $HOME ".exasol-starter-kit" }
$Repo       = if ($env:EXAKIT_REPO) { $env:EXAKIT_REPO } else { "krishna-exasol/update-path" }
$Ref        = if ($env:EXAKIT_REF)  { $env:EXAKIT_REF }  else { "main" }
$KitDir     = Join-Path $ExakitHome "kit"

# --- 1. requirements ---------------------------------------------------------
if ($env:OS -notlike "*Windows*") {
    throw "This installer is for Windows. On macOS/Linux/WSL use install.sh."
}

# Everything past this section writes to the machine: the download replaces
# ~\.exasol-starter-kit\kit, and the setup script it hands off to opens a
# logfile and writes the install manifest before it checks a single
# requirement. So the cheap half of the compatibility check happens HERE, while
# the machine is still untouched - a laptop that was never going to pass was
# still left with a rewritten kit directory and an install log to explain.
#
# install.sh cannot do this: its check lives in setup\lib\detect.sh, inside the
# kit it has to download first. Nothing these checks need is in the kit.
#
# This is a gate, not the check. Test-NanoRequirements still runs the real one
# once setup starts (is the engine actually answering, every volume the install
# writes to, the tight-disk advice) and it owns every message this gate
# borrows: the wording is copied word for word so nobody meets two spellings of
# the same refusal. Deliberately permissive - anything that cannot be
# determined passes, because a gate working from less information than the real
# check must never be the thing that overrules it.

# Get-ExakitDockerEvidence - is Docker Desktop on this machine at all? Cheap
# evidence only, in the order Find-DockerCli (setup\lib\nano.ps1) looks: the
# PATH lookup, then the two locations Docker Desktop's own installer uses - the
# machine-wide one and the per-user "install for me only" one. The path probes
# matter because Docker Desktop adds its bin directory to the MACHINE PATH at
# install time, so an already-open terminal can have Docker installed and
# simply not on $env:PATH. Whether the ENGINE answers is a different question
# and belongs to Assert-NanoEngine, which asks it with the kit's library loaded.
function Get-ExakitDockerEvidence {
    if (Get-Command docker -ErrorAction SilentlyContinue) { return "docker on PATH" }
    $candidates = @()
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles "Docker\Docker\resources\bin\docker.exe") }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA "Programs\Docker\Docker\resources\bin\docker.exe") }
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return "docker.exe at $candidate" }
    }
    # Docker Desktop's WSL2 backend distro, read from the registry rather than
    # by running wsl.exe: this shell can have no docker.exe anywhere while
    # Docker Desktop is unmistakably installed, and Assert-NanoEngine has a
    # precise message for exactly that machine. This gate must not overrule it
    # with "install Docker Desktop".
    try {
        $lxssKey = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss"
        if (Test-Path $lxssKey) {
            foreach ($distro in (Get-ChildItem $lxssKey -ErrorAction SilentlyContinue)) {
                $distroName = (Get-ItemProperty -Path $distro.PSPath -Name "DistributionName" -ErrorAction SilentlyContinue).DistributionName
                if ($distroName -eq "docker-desktop" -or $distroName -eq "docker-desktop-data") {
                    return "the Docker Desktop WSL backend distro is registered"
                }
            }
        }
    } catch { }
    # A running Docker Desktop whose CLI this gate could not find is unusual,
    # but it is not a machine to send off to install Docker Desktop.
    try {
        if (@(Get-Process -Name "Docker Desktop", "com.docker.backend" -ErrorAction SilentlyContinue).Count -gt 0) {
            return "Docker Desktop is running"
        }
    } catch { }
    return $null
}

# Get-ExakitTotalRamGb, Get-ExakitFreeGb - whole GB, or -1 when the answer
# cannot be read at all. -1 means "unknown", and unknown always passes.
#
# Free disk goes through DriveInfo rather than the Win32_LogicalDisk query
# nano.ps1 uses: this runs before anything else does, and it must not turn a
# stopped WMI service on a locked-down machine into a failed install.
function Get-ExakitTotalRamGb {
    try { return [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB) } catch { return -1 }
}

function Get-ExakitFreeGb {
    param([string]$Path)
    try {
        $root = [System.IO.Path]::GetPathRoot($Path)
        if (-not $root) { $root = $Path }
        $drive = New-Object System.IO.DriveInfo $root
        if (-not $drive.IsReady) { return -1 }
        return [math]::Floor($drive.AvailableFreeSpace / 1GB)
    } catch { return -1 }
}

# New-ExakitCheckResult - one item of the requirements report. State is "ok",
# "note" or "bad"; Detail and Reason are read only for a "bad" one - Detail is
# what the kit prints before it gives up, Reason is the one-line diagnosis the
# trap above turns into "Installation failed: ...".
function New-ExakitCheckResult {
    param(
        [string]$State,
        [string]$Text,
        [string[]]$Detail = @(),
        [string]$Reason = ""
    )
    return [pscustomobject]@{ State = $State; Text = $Text; Detail = $Detail; Reason = $Reason }
}

# Get-ExakitRequirementChecks - the three things worth knowing before anything
# is written, plus the two that are never more than a note.
function Get-ExakitRequirementChecks {
    # EXAKIT_FORCE is the kit's own escape hatch, and it covers exactly what it
    # covers there: memory and free disk, never the container runtime, because
    # there is nothing to force when the thing the database runs in is absent.
    $forced = ($env:EXAKIT_FORCE -eq "1")
    $minRamGb = if ($env:EXAKIT_NANO_MIN_RAM_GB) { [int]$env:EXAKIT_NANO_MIN_RAM_GB } else { 4 }
    $minSystemDiskGb = if ($env:EXAKIT_NANO_MIN_SYSTEM_DISK_GB) { [int]$env:EXAKIT_NANO_MIN_SYSTEM_DISK_GB } else { 5 }
    $checks = @()

    $checks += New-ExakitCheckResult -State "ok" -Text "Operating system: Windows"

    # Architecture is reported, never a failure: exapump publishes Windows
    # binaries for x86_64 only, and on Windows-on-ARM the database container
    # itself is fully supported - the setup script names each step it skips.
    if ($env:PROCESSOR_ARCHITECTURE -eq "AMD64") {
        $checks += New-ExakitCheckResult -State "ok" -Text "CPU architecture: $env:PROCESSOR_ARCHITECTURE"
    } else {
        $checks += New-ExakitCheckResult -State "note" `
            -Text "CPU architecture: $env:PROCESSOR_ARCHITECTURE - the database installs and runs, but exapump, the sample data and the AI bridge are skipped (exapump ships Windows builds for x86_64 only)"
    }

    $dockerEvidence = Get-ExakitDockerEvidence
    if ($dockerEvidence) {
        $checks += New-ExakitCheckResult -State "ok" -Text "Container runtime: Docker Desktop found ($dockerEvidence)"
    } else {
        # Word for word what Assert-NanoEngine says for the same machine.
        $checks += New-ExakitCheckResult -State "bad" `
            -Text "No container runtime found. Install Docker Desktop (https://docs.docker.com/desktop/), then re-run." `
            -Reason "No container runtime found. Install Docker Desktop (https://docs.docker.com/desktop/), then re-run."
    }

    $ramGb = Get-ExakitTotalRamGb
    if ($ramGb -lt 0) {
        $checks += New-ExakitCheckResult -State "note" `
            -Text "Memory: could not be read here - the installer checks it again with the kit's own tools"
    } elseif ($ramGb -ge $minRamGb) {
        $checks += New-ExakitCheckResult -State "ok" -Text "Memory: $ramGb GB (Exasol Nano needs $minRamGb+)"
    } elseif ($forced) {
        $checks += New-ExakitCheckResult -State "note" `
            -Text "Memory: $ramGb GB - below the $minRamGb GB minimum, continuing because EXAKIT_FORCE=1"
    } else {
        $checks += New-ExakitCheckResult -State "bad" `
            -Text "Memory: $ramGb GB - Exasol Nano needs at least $minRamGb GB" `
            -Detail @(
                "This machine is not compatible: Exasol Nano needs at least $minRamGb GB RAM and this machine has $ramGb GB.",
                "Nothing was installed. Re-run on a machine with $minRamGb+ GB RAM (or force at your own risk with EXAKIT_FORCE=1)."
            ) `
            -Reason "Insufficient memory: $ramGb GB."
    }

    # The system drive, always: Windows headroom, Docker Desktop's own state,
    # and %TEMP%, through which the image download is unpacked. Where Docker
    # actually keeps its images can be another volume entirely, and finding
    # that out means asking a running engine - so this gate holds the system
    # drive to the smaller headroom-only requirement and lets
    # Test-NanoDiskSpace judge every volume properly once setup starts.
    $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "C:" }
    $sysRoot = "$sysDrive\"
    $whatFor = "Windows itself, Docker Desktop's own state and the unpacking of the image download"
    $freeGb = Get-ExakitFreeGb $sysRoot
    if ($freeGb -lt 0) {
        $checks += New-ExakitCheckResult -State "note" `
            -Text "Free disk on ${sysRoot}: could not be read here - the installer checks it again with the kit's own tools"
    } elseif ($freeGb -ge $minSystemDiskGb) {
        $checks += New-ExakitCheckResult -State "ok" -Text "Free disk on ${sysRoot}: $freeGb GB ($minSystemDiskGb+ needed for $whatFor)"
    } elseif ($forced) {
        $checks += New-ExakitCheckResult -State "note" `
            -Text "Free disk on ${sysRoot}: $freeGb GB - below the $minSystemDiskGb GB minimum, continuing because EXAKIT_FORCE=1"
    } else {
        $checks += New-ExakitCheckResult -State "bad" `
            -Text "Free disk on ${sysRoot}: $freeGb GB - at least $minSystemDiskGb GB is needed for $whatFor" `
            -Detail @(
                "This machine is not compatible right now: $whatFor needs at least $minSystemDiskGb GB free on $sysRoot and it has $freeGb GB.",
                "Nothing was installed. Free up disk space on $sysRoot and re-run (or force at your own risk with EXAKIT_FORCE=1)."
            ) `
            -Reason "Insufficient free disk space on ${sysRoot}: $freeGb GB."
    }

    return $checks
}

# Write-ExakitRequirementReport - $env:EXAKIT_PREFLIGHT: say what this machine
# can and cannot do, install nothing, and return the number of genuine
# failures as the exit code. The twin is preflight_report (setup\lib\detect.sh),
# which install.sh runs at this same point in its own flow. That one can report
# more because it runs after the download and has the kit to read; the items it
# adds (network reachability, the database port, python) are all things this
# install reports on the way past anyway.
function Write-ExakitRequirementReport {
    param($Checks)
    $failures = 0
    Write-Host ""
    Write-Host "  Preflight check - nothing will be installed"
    Write-Host ""
    foreach ($check in $Checks) {
        if ($check.State -eq "bad") {
            $failures = $failures + 1
            Write-Host "  x $($check.Text)" -ForegroundColor Red
        } elseif ($check.State -eq "note") {
            Write-Host "  - $($check.Text)" -ForegroundColor Yellow
        } else {
            Write-Host "  + $($check.Text)" -ForegroundColor Green
        }
    }
    Write-Host ""
    if ($failures -eq 0) {
        Write-Host "  All checks passed - this machine can run the starter kit." -ForegroundColor Green
        Write-Host "  Re-run without `$env:EXAKIT_PREFLIGHT to install it."
    } else {
        Write-Host "  $failures requirement(s) missing - fix the items marked x above and re-run." -ForegroundColor Red
    }
    Write-Host ""
    return $failures
}

$RequirementChecks = Get-ExakitRequirementChecks

if ($env:EXAKIT_PREFLIGHT -eq "1") {
    # The exit code is the number of failures, exactly as install.sh's
    # preflight_report returns it, so a script can branch on it - and zero when
    # the only findings were notes, because a note is not a failure.
    exit (Write-ExakitRequirementReport -Checks $RequirementChecks)
}

foreach ($check in $RequirementChecks) {
    if ($check.State -ne "bad") { continue }
    if ($env:EXAKIT_DRY_RUN -eq "1") {
        # A dry run's whole job is to show what WOULD happen and to leave the
        # scripts on disk to read. Refusing it would take away the one way to
        # inspect the kit on a machine that cannot run it, so the finding is
        # reported and the run carries on to the plan.
        Write-Host "  ! $($check.Text)" -ForegroundColor Yellow
        continue
    }
    Write-Host ""
    $firstDetail = $true
    foreach ($line in $check.Detail) {
        if ($firstDetail) {
            Write-Host "  x $line" -ForegroundColor Red
            $firstDetail = $false
        } else {
            Write-Host "    $line"
        }
    }
    throw $check.Reason
}

# --- 2. fetch the kit ----------------------------------------------------------
$InstallPhase = "download"
Write-Host "  * Downloading the starter kit ($Repo@$Ref)" -ForegroundColor Blue
$tmpZip = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-src-$([System.Guid]::NewGuid().ToString('N')).zip"
$urls = @(
    "https://github.com/$Repo/archive/refs/heads/$Ref.zip",
    "https://github.com/$Repo/archive/refs/tags/$Ref.zip"
)
$fetched = $false
foreach ($url in $urls) {
    try {
        Invoke-WebRequest -Uri $url -OutFile $tmpZip -UseBasicParsing -TimeoutSec 300
        $fetched = $true
        break
    } catch { }
}
if (-not $fetched) {
    throw "Could not download the kit from github.com/$Repo ($Ref). Check your internet connection or proxy; if the repository is private, set `$env:GITHUB_TOKEN and re-run."
}

# The replacement kit is assembled beside the old one and swapped in only once
# it is complete. The old code deleted ~\.exasol-starter-kit\kit first and then
# moved the archive's entries into it one at a time, so a corrupt archive, a
# full disk, or antivirus holding a single file open left an empty or
# half-populated kit directory behind - and the installed exakit.cmd shim
# points into that directory by absolute path, so the user's working `exakit`
# command died with it, from a re-install they had only run to get a newer
# version.
#
# The staging directory is a SIBLING of the kit, not a directory under %TEMP%:
# Move-Item cannot rename a directory across volumes, and a redirected TEMP or
# a small system SSD puts %TEMP% on another drive often enough that staging
# there would have traded one failure mode for another.
New-Item -ItemType Directory -Force -Path $ExakitHome | Out-Null
$incoming  = Join-Path $ExakitHome "kit.incoming-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
$kitBackup = Join-Path $ExakitHome "kit.previous-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
try {
    try {
        Expand-Archive -Path $tmpZip -DestinationPath $incoming
    } catch {
        throw "The downloaded kit archive could not be extracted (a partial or corrupt download). Re-run to download it again."
    }
    $inner = Get-ChildItem $incoming | Select-Object -First 1
    if (-not $inner) { throw "The downloaded kit archive was empty or malformed. Re-run to download it again." }

    # Sentinels: three files every later step reads - the exakit command itself,
    # the shared library every script dot-sources, and the versions manifest
    # that is the kit's offline version tier. Checked BEFORE the working copy is
    # touched, so an archive that unpacked into something unusable is a no-op
    # instead of a broken install.
    foreach ($sentinel in @("setup\exakit.ps1", "setup\lib\exakit-common.ps1", "versions.json")) {
        if (-not (Test-Path (Join-Path $inner.FullName $sentinel))) {
            throw "The downloaded kit is incomplete ($sentinel is missing), so it was not installed and your existing kit is untouched. Re-run to download it again."
        }
    }

    $InstallPhase = "install"
    $movedAside = $false
    if (Test-Path $KitDir) {
        Move-Item -LiteralPath $KitDir -Destination $kitBackup
        $movedAside = $true
    }
    try {
        Move-Item -LiteralPath $inner.FullName -Destination $KitDir
    } catch {
        # Put the working kit back before saying anything: the message the user
        # reads has to be true about the state of their machine, and the one
        # thing they will try next is the `exakit` command.
        $swapError = $_.Exception.Message
        $restoreNote = "there was no previous kit to put back"
        if ($movedAside) {
            $restoreNote = "your previous kit could NOT be put back and is now in $kitBackup - rename that directory to $KitDir by hand to get the exakit command working again"
            try {
                if (Test-Path $KitDir) { Remove-Item -Recurse -Force $KitDir -ErrorAction SilentlyContinue }
                Move-Item -LiteralPath $kitBackup -Destination $KitDir
                $restoreNote = "your previous kit was put back, so the exakit command still works"
            } catch { }
        }
        throw "The new kit could not be moved into place ($swapError); $restoreNote. Re-run to try again."
    }
    if ($movedAside) { Remove-Item -Recurse -Force $kitBackup -ErrorAction SilentlyContinue }
} finally {
    # Best-effort tidy-up of this run's scratch space. A failure above has
    # already said what went wrong; a leftover temp file must not add to it.
    Remove-Item -Force $tmpZip -ErrorAction SilentlyContinue
    if (Test-Path $incoming) { Remove-Item -Recurse -Force $incoming -ErrorAction SilentlyContinue }
}

# --- 3. show the plan -----------------------------------------------------------
$InstallPhase = "plan"
$ramGb = Get-ExakitTotalRamGb
# "RAM unknown" rather than a crash or a bare "-1 GB": the requirements gate
# above already decided an unreadable value is not a reason to stop.
$ramText = if ($ramGb -ge 0) { "$ramGb GB RAM" } else { "RAM unknown" }
# Banner + plan via the kit's shared visual layer (setup\lib\ui.ps1) so the
# EXASOL wordmark and palette match the rest of the install exactly. Available
# now that the kit is downloaded; plain fallback if the lib is missing.
$uiLib = Join-Path $KitDir "setup\lib\ui.ps1"
$uiLoaded = $false
if (Test-Path $uiLib) {
    # Load the visual layer WITHOUT dot-sourcing the file. A .ps1 file is
    # subject to the execution policy (Restricted - the Windows default -
    # blocks it), but a scriptblock built from the file's text is not: the
    # same exemption install.ps1 itself runs under via `irm | iex`. Guarded so
    # any failure just falls back to the plain plan below.
    #
    # Read as explicit UTF-8, NOT Get-Content -Raw: ui.ps1 carries the EXASOL
    # wordmark as multi-byte block glyphs, and on Windows PowerShell 5.1
    # Get-Content -Raw decodes a BOM-less copy (as a download/extract can leave
    # it) using the ANSI codepage, corrupting those bytes into a scriptblock
    # that fails to parse - the silent plain-text fallback seen in the field.
    # ReadAllText with a UTF-8 encoding decodes correctly with or without a BOM.
    # The plan render lives inside the try too, so a render-time failure also
    # falls back cleanly instead of surfacing a raw error before install.
    try {
        $uiText = [System.IO.File]::ReadAllText($uiLib, [System.Text.Encoding]::UTF8)
        . ([scriptblock]::Create($uiText))
        Write-ExakitInstallPlan `
            -Platform "windows ($env:PROCESSOR_ARCHITECTURE, $ramText)" `
            -Database "Exasol Nano (container via Docker Desktop)" `
            -KitDir $KitDir -StateDir $ExakitHome
        $uiLoaded = $true
    } catch { $uiLoaded = $false }
}
if (-not $uiLoaded) {
    Write-Host ""
    Write-Host "  Personal Local Starter Kit"
    Write-Host ""
}

if ($env:EXAKIT_DRY_RUN -eq "1") {
    Write-Host "  * Dry run requested (EXAKIT_DRY_RUN=1) - nothing was installed." -ForegroundColor Blue
    Write-Host "    Inspect the scripts under $KitDir, then run:"
    Write-Host "      powershell -File `"$KitDir\setup\setup-windows-docker.ps1`""
    Write-Host ""
    return
}

# --- 4. hand off -----------------------------------------------------------------
$InstallPhase = "setup"
Write-Host "  * Starting setup: setup\setup-windows-docker.ps1" -ForegroundColor Blue
Write-Host ""
# We already showed the banner above; tell the setup script to skip its own so
# the wordmark appears exactly once through the installer. A direct
# `-File setup\setup-windows-docker.ps1` run (no installer) still shows it.
$env:EXAKIT_BANNER_SHOWN = "1"
& powershell -ExecutionPolicy Bypass -File (Join-Path $KitDir "setup\setup-windows-docker.ps1")
$setupExitCode = $LASTEXITCODE
# Pass the code through; do NOT re-wrap it. Re-throwing it as "Setup failed
# with exit code 1" made the trap above print that number as THE reason and
# then append its network hypothesis, so the last two lines of every failed
# Windows install talked over the named cause and remedy the setup script had
# just printed one line earlier ("Docker is installed but not running. Start
# Docker Desktop and re-run."). install.sh never had this problem: it execs its
# setup script, so on macOS/Linux/WSL the real message IS the last line. This
# is that same contract on Windows.
if ($setupExitCode -ne 0) { exit $setupExitCode }
