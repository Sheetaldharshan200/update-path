# nano.ps1 - Exasol Nano container runtime module (Windows / PowerShell path,
# Docker Desktop only).
#
# Dot-sourced by setup-windows-docker.ps1 and setup/exakit.ps1 after
# exakit-common.ps1. Mirrors setup/lib/runtime-nano.sh function-for-function.
#
# Container contract (from the image documentation):
#   - readiness: logs print "Database is now up and running!"
#   - connection: 127.0.0.1:8563, user sys, TLS (self-signed certificate)
#   - recommended limits: --shm-size=512mb --pids-limit=-1

$script:NanoContainer = if ($env:EXAKIT_NANO_CONTAINER) { $env:EXAKIT_NANO_CONTAINER } else { "exasol-nano" }
$script:NanoVolume    = if ($env:EXAKIT_NANO_VOLUME) { $env:EXAKIT_NANO_VOLUME } else { "exasol-nano-data" }
$script:NanoMinRamGb  = if ($env:EXAKIT_NANO_MIN_RAM_GB) { [int]$env:EXAKIT_NANO_MIN_RAM_GB } else { 4 }
# Hard floor and comfortable floor for free disk, checked on every volume this
# install writes to (see Test-NanoDiskSpace): the Nano image alone unpacks to
# several GB, and the container's /exa volume grows with the data loaded into it.
$script:NanoMinDiskGb   = if ($env:EXAKIT_NANO_MIN_DISK_GB) { [int]$env:EXAKIT_NANO_MIN_DISK_GB } else { 10 }
$script:NanoRoomyDiskGb = if ($env:EXAKIT_NANO_ROOMY_DISK_GB) { [int]$env:EXAKIT_NANO_ROOMY_DISK_GB } else { 20 }
# What the system drive needs when it is NOT where Docker keeps its data: Windows
# headroom, Docker Desktop's per-user state and WSL kernel, and %TEMP% for
# unpacking the image download. Checked on every install even so - a full C:
# breaks the machine, not just this kit.
$script:NanoMinSystemDiskGb = if ($env:EXAKIT_NANO_MIN_SYSTEM_DISK_GB) { [int]$env:EXAKIT_NANO_MIN_SYSTEM_DISK_GB } else { 5 }
# The kit home: credentials, logs, and the pyexasol virtual environment.
$script:NanoMinKitDiskGb = if ($env:EXAKIT_NANO_MIN_KIT_DISK_GB) { [int]$env:EXAKIT_NANO_MIN_KIT_DISK_GB } else { 3 }
$script:NanoReadyTimeout = if ($env:EXAKIT_NANO_READY_TIMEOUT) { [int]$env:EXAKIT_NANO_READY_TIMEOUT } else { 600 }

# --- finding Docker Desktop -------------------------------------------------
# `Get-Command docker` alone is not enough to answer "is Docker installed?" on
# Windows, and treating it as the answer produced the kit's most confusing
# report: Docker Desktop plainly installed and working - `docker` runs inside
# WSL, `wsl -l` lists the docker-desktop distro - while the Windows installer
# said "No container runtime found. Install Docker Desktop".
#
# The cause is PATH, not Docker. Docker Desktop adds its bin directory to the
# MACHINE PATH at install time, and an already-open PowerShell (or the parent
# that spawned it, or a terminal restored by Windows Terminal at logon) keeps
# the environment block it started with. Until that shell is restarted,
# docker.exe exists on disk and is simply not on $env:PATH. The WSL side never
# sees this because its docker comes from Docker Desktop's WSL integration,
# which injects the CLI into the distro independently.
#
# So: look for the real docker.exe in the places Docker Desktop installs it
# (and where the registry says it went), and use the full path when found.

# Get-DockerCliCandidates - every location a Docker Desktop CLI is known to
# live, most likely first. Missing environment variables collapse to paths
# that simply do not exist, which Test-Path rejects harmlessly.
function Get-DockerCliCandidates {
    $candidates = @()
    foreach ($root in @($env:ProgramFiles, $env:ProgramW6432, ${env:ProgramFiles(x86)})) {
        if ($root) { $candidates += (Join-Path $root "Docker\Docker\resources\bin\docker.exe") }
    }
    # Per-user ("install for me only") layout, and the user-level bin Docker
    # Desktop 4.x maintains for CLI plugins.
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\Docker\Docker\resources\bin\docker.exe")
    }
    if ($env:USERPROFILE) {
        $candidates += (Join-Path $env:USERPROFILE ".docker\bin\docker.exe")
    }
    # The shim directory Docker Desktop keeps on the machine PATH.
    if ($env:ProgramData) {
        $candidates += (Join-Path $env:ProgramData "DockerDesktop\version-bin\docker.exe")
    }
    # Wherever the installer actually put it, if it recorded that.
    foreach ($key in @("HKLM:\SOFTWARE\Docker Inc.\Docker\1.0",
                       "HKCU:\SOFTWARE\Docker Inc.\Docker\1.0")) {
        try {
            $appPath = (Get-ItemProperty -Path $key -Name "AppPath" -ErrorAction Stop).AppPath
            if ($appPath) { $candidates += (Join-Path $appPath "resources\bin\docker.exe") }
        } catch { }
    }
    return $candidates
}

# Find-DockerCli - the docker.exe this machine actually has, on PATH or not.
# Returns the command name "docker" when PATH already resolves it (so logs and
# error messages stay readable) and a full path otherwise. $null when Docker
# Desktop is genuinely not installed.
function Find-DockerCli {
    if ($null -ne $script:DockerCliCache) {
        if ($script:DockerCliCache -eq "") { return $null }
        return $script:DockerCliCache
    }
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $script:DockerCliCache = "docker"
        return "docker"
    }
    foreach ($candidate in (Get-DockerCliCandidates)) {
        if ($candidate -and (Test-Path $candidate)) {
            $script:DockerCliCache = $candidate
            # Put it on PATH for the rest of THIS process: `docker compose`,
            # credential helpers and anything else the kit shells out to look
            # the CLI up by name, and would miss it otherwise.
            $binDir = Split-Path -Parent $candidate
            if ($binDir -and ($env:PATH -notlike "*$binDir*")) {
                $env:PATH = "$binDir;$env:PATH"
            }
            Write-ExakitLog "INFO" "docker.exe found off-PATH at $candidate"
            return $candidate
        }
    }
    $script:DockerCliCache = ""
    return $null
}

# Test-DockerFoundOffPath - true when the CLI was only found by searching, i.e.
# this shell's PATH is older than the Docker Desktop install. Drives the "open a
# new terminal" advice, which is the actual fix for the user's environment.
function Test-DockerFoundOffPath {
    $cli = Find-DockerCli
    return ($cli -and $cli -ne "docker")
}

# Test-DockerDesktopWslBackend - true when Docker Desktop's WSL2 backend distro
# is registered. This is the signal that made the original report so puzzling:
# `wsl -l` shows docker-desktop, so Docker Desktop is unmistakably installed,
# whatever this PowerShell session's PATH says.
#
# wsl.exe writes UTF-16LE, which PowerShell decodes as text sprinkled with NULs;
# stripping them is more reliable across PS 5.1 and 7 than switching the console
# encoding, and this only ever looks for a substring.
function Test-DockerDesktopWslBackend {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
    $previousEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $out = Invoke-ExakitBounded -FilePath "wsl.exe" -Arguments @("--list", "--quiet") -TimeoutSeconds 10
        if (-not $out) { return $false }
        $text = (("" + $out) -replace "`0", "")
        return ($text -match "docker-desktop")
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $previousEAP
    }
}

# Test-DockerDesktopRunning - is the Docker Desktop application up? A true here
# with a dead engine means "still starting", which is a wait, not a fix.
function Test-DockerDesktopRunning {
    try {
        $processes = @(Get-Process -Name "Docker Desktop", "com.docker.backend" -ErrorAction SilentlyContinue)
        return ($processes.Count -gt 0)
    } catch {
        return $false
    }
}

# Test-DockerDesktopInstalled - installed on this machine by any evidence: a CLI
# on disk, the WSL backend distro, or the desktop application running.
function Test-DockerDesktopInstalled {
    if (Find-DockerCli) { return $true }
    if (Test-DockerDesktopRunning) { return $true }
    if (Test-DockerDesktopWslBackend) { return $true }
    return $false
}

# Get-NanoEngine - the usable container engine (Docker only on Windows),
# cached after first call. Returns the CLI to invoke: "docker" when PATH
# resolves it, otherwise the full path Find-DockerCli discovered.
#
# `docker info` fails loudly (writes to stderr) when Docker Desktop is
# installed but not running - exactly the case Test-NanoRequirements exists
# to give a friendly message for. Under $ErrorActionPreference = 'Stop'
# (set globally by every entry point) a native command's stderr write can
# surface as an uncaught exception instead of a plain non-zero exit code, so
# this is wrapped: a thrown error here means "docker isn't usable", not "the
# whole script should die with a raw stack trace".
function Get-NanoEngine {
    if ($script:NanoEngineCache) { return $script:NanoEngineCache }
    $cli = Find-DockerCli
    if ($cli) {
        $previousEAP = $ErrorActionPreference
        try {
            # Docker Desktop writes harmless warnings to stderr on 'docker info'.
            # Under the global ErrorActionPreference='Stop', Windows PowerShell
            # 5.1 turns that stderr write into a TERMINATING error before we can
            # read the exit code - so a perfectly healthy Docker was reported as
            # "not running". Switch to Continue (exactly what Invoke-ExakitLogged
            # does) so the exit code, not incidental stderr, decides.
            $ErrorActionPreference = "Continue"
            # Bounded: a starting Docker Desktop answers `docker info` only when it
            # is ready, and a version lookup must not wait that out. $null covers
            # both "failed" and "took too long", and both mean the same here.
            if ($null -ne (Invoke-ExakitBounded -FilePath $cli -Arguments @("info") `
                    -TimeoutSeconds $(if ($env:EXAKIT_ENGINE_PROBE_TIMEOUT) { [int]$env:EXAKIT_ENGINE_PROBE_TIMEOUT } else { 8 }))) {
                $script:NanoEngineCache = $cli
                return $cli
            }
        } catch {
            Write-ExakitLog "WARN" "docker info failed: $_"
        } finally {
            $ErrorActionPreference = $previousEAP
        }
    }
    return $null
}

# Resolve-NanoNames - lifecycle commands must act on the names the install
# actually used (recorded in the manifest), not this shell's defaults. An
# explicit environment override still wins.
function Resolve-NanoNames {
    if ($script:NanoContainer -eq "exasol-nano") {
        $mc = Get-ExakitManifestValue "runtime.container"
        if ($mc) { $script:NanoContainer = $mc }
    }
    if ($script:NanoVolume -eq "exasol-nano-data") {
        $mv = Get-ExakitManifestValue "runtime.volume"
        if ($mv) { $script:NanoVolume = $mv }
    }
}

# Get-DockerDataRoot - the Windows directory where Docker actually stores its
# images, containers and volumes.
#
# This is NOT the system drive by default reasoning: with the WSL2 backend
# (the default on Windows) everything Docker writes goes into a virtual disk
# under %LOCALAPPDATA%\Docker\wsl, and Docker Desktop lets users relocate that
# to another drive from Settings > Resources > Advanced > Disk image location.
# Checking only C: therefore both passes installs that will run out of room on
# D:, and blocks installs whose C: is full while Docker has 400 GB elsewhere.
#
# `docker info` is asked first, but under WSL2 it answers with a path inside
# the Linux VM (/var/lib/docker), which says nothing about Windows free space -
# so only a rooted Windows path is taken from it.
function Get-DockerDataRoot {
    $engine = Get-NanoEngine
    if ($engine) {
        try {
            $reported = Invoke-ExakitBounded -FilePath $engine `
                -Arguments @("info", "--format", "{{.DockerRootDir}}") -TimeoutSeconds 10
            if ($reported) {
                $reported = (("" + $reported) -split "`n" | Select-Object -First 1).Trim()
                # A Linux path from the WSL2 VM tells us nothing about Windows disks.
                if ($reported -match '^[A-Za-z]:[\\/]' -and (Test-Path $reported)) { return $reported }
            }
        } catch { }
    }
    # WSL2 backend: the images and volumes live in a vhdx under the user profile.
    if ($env:LOCALAPPDATA) {
        $wslData = Join-Path $env:LOCALAPPDATA "Docker\wsl"
        if (Test-Path $wslData) { return $wslData }
    }
    # Hyper-V / Windows-containers backend.
    if ($env:ProgramData) {
        $programData = Join-Path $env:ProgramData "Docker"
        if (Test-Path $programData) { return $programData }
    }
    return $null
}

# Get-ExakitFreeDiskGb <path> - free whole GB on the volume holding <path>.
# Returns -1 when it cannot be read, so callers fail closed rather than
# silently skipping the guard (the contract bash's detect_free_disk_gb keeps).
function Get-ExakitFreeDiskGb {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $root = [System.IO.Path]::GetPathRoot($Path)
        if (-not $root) { return -1 }
        $deviceId = $root.TrimEnd('\', '/')
        # A UNC path has no drive letter and no Win32_LogicalDisk row.
        if ($deviceId -notmatch '^[A-Za-z]:$') { return -1 }
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$deviceId'" -ErrorAction Stop
        if (-not $disk -or $null -eq $disk.FreeSpace) { return -1 }
        return [math]::Floor($disk.FreeSpace / 1GB)
    } catch {
        return -1
    }
}

# Write-DockerReclaimableHint - when space is tight, say how much of it Docker
# is already sitting on. `docker system df` is only asked once, only when it
# matters, and never blocks: an unavailable answer just means no hint.
function Write-DockerReclaimableHint {
    $engine = Get-NanoEngine
    if (-not $engine) { return }
    try {
        $out = Invoke-ExakitBounded -FilePath $engine -Arguments @("system", "df") -TimeoutSeconds 15
        if (-not $out) { return }
        Info "Docker's current disk usage (reclaim with: docker system prune -a):"
        foreach ($line in (("" + $out) -split "`n")) {
            $line = $line.TrimEnd()
            if ($line) { Write-Host ("        " + $line) }
        }
    } catch { }
}

# Test-NanoDiskSpace - the disk guard, run against every volume this install
# writes to, each with the amount IT needs.
#
# "The machine has space" is not the question. A laptop can hold terabytes across
# D: and E: and still be unable to run this, because the volume that matters is
# the one being written to - and there are up to three of them:
#
#   the system drive   Windows headroom, Docker Desktop's own per-user state and
#                      WSL kernel, and %TEMP%, through which the image download
#                      is unpacked. Checked ALWAYS, on every install, because a
#                      C: at zero bytes stalls the machine and not just the pull.
#   Docker's data root where the image and the container's /exa volume actually
#                      land. The same volume as C: on a default install; a
#                      different one whenever the disk image has been relocated
#                      (Settings > Resources > Advanced > Disk image location).
#   the kit home       credentials, logs, and the pyexasol virtual environment.
#
# Docker's data root goes first so that on the ordinary single-drive machine its
# full requirement is the one that applies and the other two collapse into it.
# When the volumes really are different, each is judged on its own need instead
# of demanding the database's full 10 GB from a C: that only holds temp files.
function Test-NanoDiskSpace {
    $checked = @{}
    $locations = @()

    $dockerRoot = Get-DockerDataRoot
    if ($dockerRoot) {
        $locations += [pscustomobject]@{
            Path = $dockerRoot
            Min  = $script:NanoMinDiskGb
            What = "the database image and container data (Docker stores them here)"
        }
    }
    $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "C:" }
    $locations += [pscustomobject]@{
        Path = "$sysDrive\"
        # With Docker's own location unresolved, the system drive is where the
        # default WSL2 disk image lives, so it carries the full requirement
        # rather than the headroom-only one.
        Min  = $(if ($dockerRoot) { $script:NanoMinSystemDiskGb } else { $script:NanoMinDiskGb })
        What = "Windows itself, Docker Desktop's own state and the unpacking of the image download"
    }
    $locations += [pscustomobject]@{
        Path = $script:ExakitHome
        Min  = $script:NanoMinKitDiskGb
        What = "the kit's own files (credentials, logs, Python environment)"
    }

    $reported = @()
    $tight = $false
    foreach ($location in $locations) {
        $root = [System.IO.Path]::GetPathRoot($location.Path)
        if (-not $root) { $root = $location.Path }
        # One volume, one verdict: the kit home almost always sits on the same
        # drive as Docker, and saying it twice reads like two problems. The first
        # entry to claim a volume is the one with the largest requirement.
        if ($checked.Contains($root)) { continue }
        $checked[$root] = $true

        $freeGb = Get-ExakitFreeDiskGb -Path $location.Path
        if ($env:EXAKIT_FORCE -ne "1") {
            if ($freeGb -lt 0) {
                Fail "Could not determine free disk space on $root (needed for $($location.What)). Free up space or set EXAKIT_FORCE=1 to install anyway."
            } elseif ($freeGb -lt $location.Min) {
                # On-grid outcome line (6-space cross), mirroring bash's error() + die() pair.
                Write-Host ("      {0}{1}{2} This machine is not compatible right now: {3} needs at least {4} GB free on {5} and it has {6} GB." -f $script:UiErr, $script:UiCross, $script:UiReset, $location.What, $location.Min, $root, $freeGb)
                Info "Nothing was installed. Free up disk space on $root and re-run (or force at your own risk with EXAKIT_FORCE=1)."
                Write-DockerReclaimableHint
                Fail "Insufficient free disk space on ${root}: $freeGb GB."
            }
        }
        if ($freeGb -ge 0) {
            $reported += "$($freeGb) GB free on $root"
            if ($freeGb -lt $script:NanoRoomyDiskGb) { $tight = $true }
        }
    }

    if ($tight) {
        Warn2 "Free disk is tight ($($reported -join ', ')) - fine for the bundled datasets, but watch space before loading large files."
        Write-DockerReclaimableHint
    }
    if ($dockerRoot -and $reported.Count -gt 0) {
        Info "Docker stores its images and volumes in $dockerRoot"
    }
    return ($reported -join ', ')
}

# Assert-NanoEngine - resolve the container engine, or explain precisely which
# of the three Windows failure modes this machine is in.
#
# The old message ("No container runtime found. Install Docker Desktop") was
# wrong for two of them, and told a user with Docker Desktop plainly installed
# to go and install it again.
function Assert-NanoEngine {
    $engine = Get-NanoEngine
    if ($engine) { return $engine }

    $cli = Find-DockerCli
    $wslBackend = Test-DockerDesktopWslBackend

    if (-not $cli -and -not $wslBackend -and -not (Test-DockerDesktopRunning)) {
        Fail "No container runtime found. Install Docker Desktop (https://docs.docker.com/desktop/), then re-run."
    }

    # Docker Desktop IS here. The engine simply did not answer.
    if ($wslBackend) {
        Warn2 "Docker Desktop is installed (its WSL backend distro 'docker-desktop' is registered) but its engine did not answer in this Windows session."
    } else {
        Warn2 "Docker Desktop is installed but its engine did not answer."
    }
    if (Test-DockerDesktopRunning) {
        Info "Docker Desktop is running - it may still be starting up. Wait for its whale icon to stop animating, then re-run."
    } else {
        Info "Start Docker Desktop, wait until it reports 'Engine running', then re-run."
    }
    if (-not $cli) {
        # The exact case the WSL side never sees: the CLI exists in the WSL
        # distro but this shell has no docker.exe at all, on PATH or on disk.
        Info "No docker.exe was found on this machine, even off PATH. If Docker works inside WSL but not here, enable Docker Desktop > Settings > General > 'Expose daemon' / reinstall Docker Desktop's Windows CLI, or run the kit's WSL install from your Linux distro instead (quickstarts/windows-wsl.md)."
    } elseif ($cli -ne "docker") {
        Info "The Docker CLI is at $cli but is not on this shell's PATH - close this terminal and open a new one so the PATH update from the Docker Desktop install takes effect."
    }
    Fail "Docker is installed but not running. Start Docker Desktop and re-run."
}

function Test-NanoRequirements {
    $engine = Assert-NanoEngine
    if (Test-DockerFoundOffPath) {
        # Found and used, so the install proceeds - but this shell's PATH is
        # stale, and every later `docker ...` the user types by hand will fail
        # with "not recognized" until they open a new terminal.
        Warn2 "docker is not on this shell's PATH; using $engine directly."
        Info "Close this terminal and open a new one so the PATH entry Docker Desktop added is picked up."
        Ok "Container runtime: docker (Docker Desktop, found off PATH)"
    } else {
        Ok "Container runtime: docker"
    }

    # Memory - fail closed if it cannot be read (mirrors the bash detect_ram_gb
    # contract: never let an unreadable value silently skip the guard).
    $ramGb = -1
    try { $ramGb = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB) } catch { $ramGb = -1 }
    if ($env:EXAKIT_FORCE -ne "1") {
        if ($ramGb -lt 0) {
            Fail "Could not determine this machine's memory. Set EXAKIT_FORCE=1 to install anyway."
        } elseif ($ramGb -lt $script:NanoMinRamGb) {
            # On-grid outcome line (6-space cross), mirroring bash's error() + die() pair.
            Write-Host ("      {0}{1}{2} This machine is not compatible: Exasol Nano needs at least {3} GB RAM and this machine has {4} GB." -f $script:UiErr, $script:UiCross, $script:UiReset, $script:NanoMinRamGb, $ramGb)
            Info "Nothing was installed. Re-run on a machine with $($script:NanoMinRamGb)+ GB RAM (or force at your own risk with EXAKIT_FORCE=1)."
            Fail "Insufficient memory: $ramGb GB."
        }
    }

    $diskSummary = Test-NanoDiskSpace

    # Bare minimum: run, but say what to expect.
    if ($ramGb -ge 0 -and $ramGb -lt ($script:NanoMinRamGb + 2)) {
        Warn2 "Memory is at the bare minimum ($ramGb GB) - the database will run, but expect slower queries and keep other heavy apps closed."
    }
    Ok "Compatibility check passed ($ramGb GB RAM, $diskSummary)"
}

function Get-NanoImageRef { return "docker.io/$($script:NanoImage):$($script:NanoTag)" }

function Test-NanoContainerExists {
    try {
        & (Get-NanoEngine) container inspect $script:NanoContainer *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Test-NanoContainerRunning {
    try {
        $state = & (Get-NanoEngine) container inspect -f "{{.State.Running}}" $script:NanoContainer 2>$null
        return ($state -eq "true")
    } catch {
        return $false
    }
}

# Test-NanoReadyInLogs - ready marker from the CURRENT boot only. Container
# logs survive stop/start, so scanning the full history would match a stale
# line from a previous boot; scoping to StartedAt also keeps each poll cheap.
function Test-NanoReadyInLogs {
    $engine = Get-NanoEngine
    try {
        $started = & $engine container inspect -f "{{.State.StartedAt}}" $script:NanoContainer 2>$null
        if (-not $started) { $started = "1970-01-01T00:00:00Z" }
        $logs = & $engine logs --since $started $script:NanoContainer 2>&1
        return (($logs -join "`n") -match "Database is now up and running!")
    } catch {
        return $false
    }
}

# The container was created with the first-deploy-only
# 'init sys_password_file=...' arguments. Nano refuses to boot with them
# once /exa is initialized, so such a container cannot simply be restarted.
function Test-NanoFirstDeployArgs {
    # Use '{{.Config.Cmd}}' (Go renders the []string as "[a b c]") rather than
    # '{{join .Config.Cmd " "}}': the embedded double-quotes in the join
    # template get mangled when PowerShell builds the native command line for
    # docker.exe on Windows, breaking the template. We only test for a token's
    # presence, so the bracketed form works and needs no embedded quotes.
    $cmd = & (Get-NanoEngine) container inspect -f '{{.Config.Cmd}}' $script:NanoContainer 2>$null
    return ("$cmd" -match "sys_password_file")
}

# Bring a stopped container back up, recreating it first when it still
# carries the single-use first-deploy arguments (the data volume carries
# the database and its password forward).
function Start-NanoExisting {
    $engine = Get-NanoEngine
    if (Test-NanoFirstDeployArgs) {
        $image = & $engine container inspect -f "{{.Config.Image}}" $script:NanoContainer 2>$null
        if (-not $image) { $image = Get-NanoImageRef }
        Info "Recreating the Nano container (first-deploy options are single-use; the data volume is kept)"
        $code = Invoke-ExakitLogged $engine "rm" "-f" $script:NanoContainer
        if ($code -ne 0) { Fail "Could not replace the old container (see log)" }
        $code = Invoke-ExakitLogged $engine "run" "-d" "--name" $script:NanoContainer `
            "--shm-size=512mb" "--pids-limit=-1" `
            "-p" "127.0.0.1:$($script:DbPort):8563" `
            "-v" "$($script:NanoVolume):/exa" `
            $image
        if ($code -ne 0) { Fail "Container failed to start (see log)" }
    } else {
        $code = Invoke-ExakitLogged $engine "start" $script:NanoContainer
        if ($code -ne 0) { Fail "Could not start existing container $($script:NanoContainer) (see log)" }
    }
    Wait-NanoReady
}

# Install-Nano - pull the pinned image and start the container (first run
# deploys the database with a generated SYS password). Idempotent.
function Install-Nano {
    $engine = Get-NanoEngine
    $image = Get-NanoImageRef

    if ((Test-NanoContainerRunning) -and (Test-NanoReadyInLogs)) {
        Ok "Nano container already running and healthy"
        Set-NanoManifest
        return
    }

    if ((Test-NanoContainerExists) -and -not (Test-NanoContainerRunning)) {
        Info "Found existing Nano container - starting it"
        Start-NanoExisting
        Set-NanoManifest
        return
    }

    if (-not (Test-NanoContainerExists)) {
        $portBusy = Test-ExakitPortInUse -Port ([int]$script:DbPort)
        if ($portBusy) {
            Fail "Port $($script:DbPort) is already in use by another application. Stop it or set EXAKIT_DB_PORT, then re-run."
        }
        Info "Pulling image $image"
        $pulled = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $code = Invoke-ExakitLogged $engine "pull" $image
            if ($code -eq 0) { $pulled = $true; break }
            if ($attempt -lt 3) { Warn2 "Pull attempt $attempt failed - retrying in $($attempt * 10)s"; Start-Sleep -Seconds ($attempt * 10) }
        }
        if (-not $pulled) { Fail "Image pull failed after 3 attempts: $image (network/Docker Hub issue - see log)" }
        Ok "Image pulled"

        $password = Get-ExakitCredential "nano_sys_password"
        if (-not $password) {
            $password = New-ExakitPassword
            Set-ExakitCredential "nano_sys_password" $password
        }
        $pwFile = Join-Path $script:CredsDir "nano_sys_password"
        # Docker's bind-mount source parsing on Windows is picky about
        # backslashes (Join-Path produces "C:\Users\...\nano_sys_password",
        # and mixing that with the ":/run/secrets/...:ro" suffix can mis-parse
        # or silently mount the wrong thing) - forward slashes are the
        # documented, reliable form for a -v source path on Windows.
        $pwFileMount = $pwFile -replace '\\', '/'

        Info "Starting Nano container ($($script:NanoContainer))"
        $code = Invoke-ExakitLogged $engine "run" "-d" "--name" $script:NanoContainer `
            "--shm-size=512mb" "--pids-limit=-1" `
            "-p" "127.0.0.1:$($script:DbPort):8563" `
            "-v" "$($script:NanoVolume):/exa" `
            "-v" "${pwFileMount}:/run/secrets/sys_password:ro" `
            $image "init" "sys_password_file=/run/secrets/sys_password"
        if ($code -ne 0) { Fail "Container failed to start (see log)" }

        # THE SECRET-MOUNT CHECK THAT USED TO LIVE HERE IS GONE, because it
        # could never pass. It ran
        #
        #     docker exec <container> sh -c "wc -c < /run/secrets/sys_password"
        #
        # and the nano image HAS NO SHELL. That exec fails outright with
        # `exec: "sh": executable file not found in $PATH`, so the size never
        # came back and the comparison never matched. Every Windows install
        # therefore printed two alarming warnings about a Docker Desktop
        # bind-mount problem it did not have.
        #
        # Measured on an affected install: `docker inspect` shows the bind in
        # place (nano_sys_password -> /run/secrets/sys_password), and the
        # connection check moments later reports success. The password was
        # always fine; only the verification was broken.
        #
        # A check that cannot succeed but always warns is worse than no check:
        # it teaches people to read past warnings, and this one made a healthy
        # install look broken.
        #
        # The intent behind it is still covered, and covered better, one step
        # later: "Validating the database connection (SELECT 1)" tries the
        # recorded password against the running database. A password that did
        # not reach the container fails THERE, with a real error rather than a
        # guess, and Show-ExakitDbErrorRemedy already turns it into a remedy.
    }

    Wait-NanoReady
    Set-NanoManifest
}

# Wait-NanoReady - poll container logs until the database reports ready.
function Wait-NanoReady {
    Info "Waiting for the database to come up (timeout: $($script:NanoReadyTimeout)s)"
    $engine = Get-NanoEngine
    $waited = 0
    while ($waited -lt $script:NanoReadyTimeout) {
        if (-not (Test-NanoContainerRunning)) {
            try {
                $tail = & $engine logs --tail 30 $script:NanoContainer 2>&1
                if ($script:LogFile) { $tail | Add-Content -Path $script:LogFile }
            } catch {
                if ($script:LogFile) { "Could not read container logs: $_" | Add-Content -Path $script:LogFile }
            }
            Fail "Nano container stopped unexpectedly (see log)"
        }
        if (Test-NanoReadyInLogs) { Ok "Database is up (took ~${waited}s)"; return }
        Start-Sleep -Seconds 5
        $waited += 5
        if ($waited % 30 -eq 0) { Info "Still starting... (${waited}s)" }
    }
    Write-Host "  x Database did not become ready within $($script:NanoReadyTimeout)s." -ForegroundColor Red
    Write-Host "    Inspect the logs:   $engine logs $($script:NanoContainer)"
    Write-Host "    If a first install was interrupted, the data volume may be half-initialized."
    Write-Host "    Reset and retry:    $engine rm -f $($script:NanoContainer) && $engine volume rm $($script:NanoVolume)"
    Fail "Nano startup timed out"
}

function Set-NanoManifest {
    Set-ExakitManifestValue "runtime.type" "nano"
    # The engine NAME, not the path Get-NanoEngine may have resolved to: this is
    # a record of which runtime is in use, and a stale absolute path would age
    # badly across Docker Desktop upgrades.
    Set-ExakitManifestValue "runtime.engine" "docker"
    Set-ExakitManifestValue "runtime.image" (Get-NanoImageRef)
    Set-ExakitManifestValue "runtime.container" $script:NanoContainer
    Set-ExakitManifestValue "runtime.volume" $script:NanoVolume
    Set-ExakitManifestValue "runtime.dsn" "127.0.0.1:$($script:DbPort)"
    Set-ExakitManifestValue "runtime.user" "sys"
    Set-ExakitManifestValue "runtime.password_file" (Join-Path $script:CredsDir "nano_sys_password")
    Set-ExakitManifestValue "runtime.tls" "self-signed"
    Set-ExakitManifestValue "runtime.status" "healthy"
}

# --- lifecycle (used by exakit) ---------------------------------------------
# Set-NanoRestartPolicy / Test-NanoRestartPolicySet - the container's own
# restart policy is what brings the database back after a reboot, and Docker
# applies it to the EXISTING container: no recreation, no data risk. Twins of
# _exakit_nano_restart_policy in common.sh.
function Set-NanoRestartPolicy {
    param([Parameter(Mandatory)][string]$Policy)
    $engine = Get-NanoEngine
    if (-not $engine -or $engine -eq "none") { return $false }
    Resolve-NanoNames
    try {
        $null = & $engine update --restart=$Policy $script:NanoContainer 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Test-NanoRestartPolicySet {
    $engine = Get-NanoEngine
    if (-not $engine -or $engine -eq "none") { return $false }
    Resolve-NanoNames
    try {
        $policy = & $engine inspect -f "{{.HostConfig.RestartPolicy.Name}}" $script:NanoContainer 2>$null
        $policy = ("" + $policy).Trim()
        return ($policy -and $policy -ne "no")
    } catch {
        return $false
    }
}

function Get-NanoStatus {
    Resolve-NanoNames
    if (-not (Test-NanoContainerExists)) { return "not installed" }
    if (-not (Test-NanoContainerRunning)) { return "stopped" }
    if (Test-NanoReadyInLogs) { return "running" }
    return "starting"
}

function Start-Nano {
    Resolve-NanoNames
    if (-not (Test-NanoContainerExists)) { Fail "No Nano container found. Run the installer first." }
    if (Test-NanoContainerRunning) { Ok "Nano container is already running"; return }
    Start-NanoExisting
    Ok "Nano started"
}

function Stop-Nano {
    Resolve-NanoNames
    if (-not (Test-NanoContainerRunning)) { Ok "Nano container is not running"; return }
    Info "Stopping Nano container (waiting up to 60s for a clean shutdown)"
    $code = Invoke-ExakitLogged (Get-NanoEngine) "stop" "-t" "60" $script:NanoContainer
    if ($code -ne 0) { Fail "Failed to stop container" }
    Set-ExakitManifestValue "runtime.status" "stopped"
    # exapump.ps1 caches a reachable database for the run; this run just ended
    # that. Guarded: the runtime modules load without exapump.ps1.
    if (Get-Command Clear-ExakitDbReachable -ErrorAction SilentlyContinue) {
        Clear-ExakitDbReachable
    }
    Ok "Nano stopped"
}

# Remove-Nano [-Data] - remove the container; -Data also removes the
# persistent volume (all database content).
function Remove-Nano {
    param([switch]$Data)
    Resolve-NanoNames
    $engine = Get-NanoEngine
    if (Test-NanoContainerExists) {
        Info "Removing Nano container"
        $code = Invoke-ExakitLogged $engine "rm" "-f" $script:NanoContainer
        if ($code -ne 0) { Warn2 "Container removal failed" }
    } else {
        Warn2 "No container named '$($script:NanoContainer)' found - nothing to remove (was it created under a different name?)"
    }
    if ($Data) {
        $volumeExists = $false
        try {
            & $engine volume inspect $script:NanoVolume *> $null
            $volumeExists = ($LASTEXITCODE -eq 0)
        } catch { }
        if ($volumeExists) {
            Info "Removing data volume $($script:NanoVolume)"
            $code = Invoke-ExakitLogged $engine "volume" "rm" $script:NanoVolume
            if ($code -ne 0) { Warn2 "Volume removal failed" }
        }
    } else {
        Info "Data volume $($script:NanoVolume) kept (pass -Data to remove it)"
    }
    Set-ExakitManifestValue "runtime.status" "removed"
}

function Update-Nano {
    param([Parameter(Mandatory)][string]$LatestTag)
    Resolve-NanoNames
    $currentImage = Get-ExakitManifestValue "runtime.image"
    $currentTag = if ($currentImage -and $currentImage.Contains(":")) { ($currentImage -split ":")[-1] } else { "" }
    if ($currentTag -eq $LatestTag) { Ok "Exasol Nano is already current ($currentTag)"; return }

    # The container is recreated, so the database goes down for the duration.
    # Even an explicit `exakit update runtime` asks first; a script pre-answers
    # with EXAKIT_CONFIRM_RUNTIME_UPDATE=1 (an unattended run takes the default,
    # which is yes - the command was asked for explicitly).
    $tagShown = $currentTag
    if (-not $tagShown) { $tagShown = "unknown" }
    if (-not (Confirm-ExakitEnvPrompt -EnvName "EXAKIT_CONFIRM_RUNTIME_UPDATE" `
            -Question "Update Exasol Nano $tagShown -> ${LatestTag}? The database stops while the container is recreated; the data volume is kept." `
            -DefaultYes $true)) {
        Info "Runtime update cancelled - nothing was changed."
        return
    }

    $engine = Get-NanoEngine
    $image = "docker.io/$($script:NanoImage):$LatestTag"
    $oldImage = if ($currentTag) { "docker.io/$($script:NanoImage):$currentTag" } else { "" }
    $snapshot = New-NanoUpdateSnapshot -CurrentTag $currentTag -LatestTag $LatestTag
    Info "Updating Exasol Nano $currentTag -> $LatestTag"
    Info "The container will be recreated; the data volume '$($script:NanoVolume)' is kept."
    Info "Pre-update runtime snapshot: $snapshot"
    $code = Invoke-ExakitLogged $engine "pull" $image
    if ($code -ne 0) { Fail "Could not pull $image" }

    if (Test-NanoContainerExists) {
        if (Test-NanoContainerRunning) {
            $code = Invoke-ExakitLogged $engine "stop" "-t" "60" $script:NanoContainer
            if ($code -ne 0) { Fail "Could not stop $($script:NanoContainer)" }
        }
        $code = Invoke-ExakitLogged $engine "rm" "-f" $script:NanoContainer
        if ($code -ne 0) { Fail "Could not remove old Nano container" }
    }

    $code = Invoke-ExakitLogged $engine "run" "-d" "--name" $script:NanoContainer `
        "--shm-size=512mb" "--pids-limit=-1" `
        "-p" "127.0.0.1:$($script:DbPort):8563" `
        "-v" "$($script:NanoVolume):/exa" `
        $image
    if ($code -ne 0) {
        Restore-PreviousNanoContainer -Image $oldImage
        Fail "Could not start updated Nano container; attempted to restore the previous image."
    }
    $script:NanoTag = $LatestTag
    try {
        Wait-NanoReady
    } catch [ExakitFailException] {
        Restore-PreviousNanoContainer -Image $oldImage
        Fail "Updated Nano container did not become ready; attempted to restore the previous image."
    }
    Set-NanoManifest
    Set-ExakitManifestValue "desired.runtime.nano" $script:NanoTag
    Set-ExakitManifestValue "backups.nano_update.latest" $snapshot
    Ok "Nano updated; data volume kept: $($script:NanoVolume)"
}

function New-NanoUpdateSnapshot {
    param([string]$CurrentTag, [Parameter(Mandatory)][string]$LatestTag)
    $backupDir = Join-Path $script:ExakitHome "backups\nano-update"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $safeCurrent = if ($CurrentTag) { $CurrentTag } else { "unknown" }
    $snapshot = Join-Path $backupDir "$stamp-$safeCurrent-to-$LatestTag.json"
    $record = [pscustomobject]@{
        created_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        operation = "nano_update"
        from = $safeCurrent
        to = $LatestTag
        container = $script:NanoContainer
        volume = $script:NanoVolume
        image = Get-ExakitManifestValue "runtime.image"
    }
    $record | ConvertTo-Json -Depth 6 | Set-Content -Path $snapshot
    try { Protect-ExakitFile $snapshot } catch { }
    return $snapshot
}

function Restore-PreviousNanoContainer {
    param([string]$Image)
    if (-not $Image) { return }
    Warn2 "Restoring the previous Nano container image ($Image)"
    $engine = Get-NanoEngine
    Invoke-ExakitLogged $engine "rm" "-f" $script:NanoContainer | Out-Null
    $code = Invoke-ExakitLogged $engine "run" "-d" "--name" $script:NanoContainer `
        "--shm-size=512mb" "--pids-limit=-1" `
        "-p" "127.0.0.1:$($script:DbPort):8563" `
        "-v" "$($script:NanoVolume):/exa" `
        $Image
    if ($code -ne 0) { Warn2 "Could not restore the previous Nano container automatically." }
}
