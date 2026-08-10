# dash-server.ps1 - dash-server (AI dashboard host): managed install + validation.
#
# Windows counterpart of dash-server.sh. A MARKETPLACE ADD-ON: never installed
# by the setup scripts. The user picks it from `exakit marketplace`; once
# installed it joins `exakit update` like every other component.
#
# dash-server facts:
#   - Agent-operated Dash hosting server for Exasol-backed dashboards
#     (github.com/exasol-labs/dash-server): agents build and deploy dashboards
#     through its MCP control plane (Streamable HTTP at /mcp).
#   - Pure-Python package with a dash-server console script; releases carry no
#     prebuilt binaries, so the install is `uv pip install` of the tag's source
#     tarball into a dedicated venv under the kit home - the same tag-pinned,
#     package-manager-verified posture as the mcp and pyexasol components.
#   - Control plane: 127.0.0.1:5100 by default (env DASH_SERVER_HOST/PORT).
#   - Exasol profile bootstrap at startup via DASH_SERVER_EXASOL_* env vars;
#     the launcher below feeds it the kit's local database.
#
#   - venv:     ~\.exasol-starter-kit\dash-server-venv
#   - state:    ~\.exasol-starter-kit\dash-server\instance
#   - launcher: ~\.local\bin\dash-server.cmd
#
# Requires exakit-common.ps1 dot-sourced first. Safe to re-run: an existing
# venv with the desired version installed is kept as-is.

# The add-on's version constants live here, next to the code that uses them -
# the generic registry arms in exakit.ps1 find them through the marketplace
# registry entry, and the versions-bump workflow keeps the fallback in
# lockstep with versions.json (COUPLED table).
$script:DashServerRepo = "exasol-labs/dash-server"
$script:DashServerVersionFallback = if ($env:EXAKIT_DASH_SERVER_VERSION_FALLBACK) { $env:EXAKIT_DASH_SERVER_VERSION_FALLBACK } else { "0.1.0" }
$script:DashServerVersion = if ($env:EXAKIT_DASH_SERVER_VERSION) { $env:EXAKIT_DASH_SERVER_VERSION } else { "" }
$script:DashServerVenv = if ($env:EXAKIT_DASH_SERVER_VENV) { $env:EXAKIT_DASH_SERVER_VENV } else { Join-Path $script:ExakitHome "dash-server-venv" }
$script:DashServerHome = if ($env:EXAKIT_DASH_SERVER_HOME) { $env:EXAKIT_DASH_SERVER_HOME } else { Join-Path $script:ExakitHome "dash-server" }
$script:DashServerPort = if ($env:EXAKIT_DASH_SERVER_PORT) { $env:EXAKIT_DASH_SERVER_PORT } else { "5100" }
$script:DashServerProfile = if ($env:EXAKIT_DASH_SERVER_PROFILE) { $env:EXAKIT_DASH_SERVER_PROFILE } else { "starter-kit" }

function Get-DashServerVenvPython {
    return (Join-Path $script:DashServerVenv "Scripts\python.exe")
}

function Get-DashServerLauncherPath {
    return (Join-Path $script:BinDir "dash-server.cmd")
}

# dash-server exposes no __version__; the distribution metadata written by the
# install is the authority. Twin of dash_server_installed_version.
function Get-DashServerInstalledVersion {
    $python = Get-DashServerVenvPython
    if (-not (Test-Path $python)) { return $null }
    $version = & $python -c "from importlib.metadata import version; print(version('dash-server'))" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($version | Out-String).Trim()
}

# The source tarball of the tagged release. Twin of dash_server_release_url.
function Get-DashServerReleaseUrl {
    param([Parameter(Mandatory)][string]$Version)
    return "https://github.com/$($script:DashServerRepo)/archive/refs/tags/v$Version.tar.gz"
}

# Write-DashServerNotInstalled <reason> - report a soft failure and return
# $false. Marketplace add-ons follow the pyexasol contract: nothing here may
# end the caller's run. Mirrors _dash_server_not_installed in dash-server.sh.
function Write-DashServerNotInstalled {
    param([Parameter(Mandatory)][string]$Reason)
    Warn2 "dash-server was not installed: $Reason"
    Warn2 "Everything else in the kit is unaffected. Retry with: exakit update dash-server"
    if (Get-Command Set-ExakitFailureReason -ErrorAction SilentlyContinue) {
        Set-ExakitFailureReason $Reason
    }
    Set-ExakitManifestValue "components.dash_server.validated" $false
    return $false
}

function Install-DashServer {
    # The marketplace path runs from the exakit CLI, where the installer's
    # Resolve-ExakitInstallVersions has not run - resolve the advertised
    # version here (env override -> policy -> versions.json -> fallback).
    if (-not $script:DashServerVersion) {
        $script:DashServerVersion = Get-ExakitComponentAvailable "dash-server"
        if (-not $script:DashServerVersion) { $script:DashServerVersion = $script:DashServerVersionFallback }
    }

    try {
        $uv = Install-ExakitUv
    } catch {
        return (Write-DashServerNotInstalled "uv (the Python tool runner) is not available - install it from https://docs.astral.sh/uv/ and re-run")
    }
    $python = Get-DashServerVenvPython

    $current = Get-DashServerInstalledVersion
    if ($current -and $current -eq $script:DashServerVersion -and $env:EXAKIT_FORCE_COMPONENT_INSTALL -ne "1") {
        Ok "dash-server $current already installed: $script:DashServerVenv"
        # An up-to-date venv can still be missing pip (created by a kit copy
        # from before the venv was seeded) - repair it in place.
        if (-not (Confirm-DashServerPip -Uv $uv)) { return $false }
    } else {
        Info "Installing dash-server $($script:DashServerVersion) (AI dashboard host)"
        if (-not (Test-Path $python)) {
            # --seed matters: dash-server installs each app's dependencies by
            # shelling out to `python -m pip`, and a bare uv venv has no pip -
            # every app build (including the built-in demo) would fail.
            $code = Invoke-ExakitLogged $uv "venv" "--seed" "--python" $script:ManagedPythonVersion $script:DashServerVenv
            if ($code -ne 0) {
                return (Write-DashServerNotInstalled "the virtual environment at $script:DashServerVenv could not be created (see log)")
            }
        }
        # The release's source tarball, pinned by tag. uv resolves and installs
        # it plus dependencies from PyPI over TLS.
        $code = Invoke-ExakitLogged $uv "pip" "install" "--python" $python (Get-DashServerReleaseUrl -Version $script:DashServerVersion)
        if ($code -ne 0) {
            return (Write-DashServerNotInstalled "installing dash-server v$($script:DashServerVersion) from its GitHub release failed (see log)")
        }
        # The install is not done until the venv can answer for the version: a
        # tarball that unpacked but failed to build would otherwise be reported
        # as installed and only fail at first launch.
        if (-not (Get-DashServerInstalledVersion)) {
            return (Write-DashServerNotInstalled "the venv cannot report a dash-server version after the install (see log)")
        }
        # Belt and braces even on a fresh venv: --seed above should have put
        # pip in place, but a pre-existing venv may lack it.
        if (-not (Confirm-DashServerPip -Uv $uv)) { return $false }
        Ok "dash-server installed: $script:DashServerVenv"
    }

    $instance = Join-Path $script:DashServerHome "instance"
    New-Item -ItemType Directory -Force -Path $instance | Out-Null
    if (-not (Write-DashServerLauncher)) { return $false }

    Set-ExakitManifestValue "components.dash_server.version" $script:DashServerVersion
    Set-ExakitManifestValue "components.dash_server.venv" $script:DashServerVenv
    Set-ExakitManifestValue "components.dash_server.python" $python
    Set-ExakitManifestValue "components.dash_server.command" (Get-DashServerLauncherPath)
    Set-ExakitManifestValue "components.dash_server.port" $script:DashServerPort
    Set-ExakitManifestValue "components.dash_server.instance" $instance
    return $true
}

# Confirm-DashServerPip - make sure the venv can run `python -m pip`.
# dash-server installs each app's dependencies (including the built-in demo's)
# by shelling out to exactly that, and a bare uv venv has no pip - without
# this, every app build fails with "Dependency install failed before import
# smoke check". New venvs are created with --seed; this is the self-repair for
# venvs that predate the seed or were provided by the user.
# Twin of _dash_server_ensure_pip in dash-server.sh.
function Confirm-DashServerPip {
    param([Parameter(Mandatory)][string]$Uv)
    $python = Get-DashServerVenvPython
    if (-not (Test-Path $python)) { return $true }
    $code = Invoke-ExakitLogged $python "-m" "pip" "--version"
    if ($code -eq 0) { return $true }
    Info "Adding pip to the dash-server venv (app builds install their dependencies with it)"
    $code = Invoke-ExakitLogged $Uv "pip" "install" "--python" $python "pip"
    if ($code -ne 0) {
        return (Write-DashServerNotInstalled "pip could not be added to $script:DashServerVenv (dash-server app builds need it; see log)")
    }
    $code = Invoke-ExakitLogged $python "-m" "pip" "--version"
    if ($code -ne 0) {
        return (Write-DashServerNotInstalled "pip was installed into $script:DashServerVenv but python -m pip still does not run (see log)")
    }
    Ok "pip added to the dash-server venv"
    return $true
}

# Write-DashServerLauncher - generate ~\.local\bin\dash-server.cmd. The wrapper
# starts the venv's console script with the kit's Exasol profile bootstrapped
# from the environment (DASH_SERVER_EXASOL_*, read fresh at RUN time - the
# password never lands in the wrapper, only the path of the credential file).
# Every variable yields to one the user set. Twin of dash_server_write_launcher.
function Write-DashServerLauncher {
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    $user = Get-ExakitManifestValue "components.mcp_server.connection.user"
    $pwfile = Get-ExakitManifestValue "components.mcp_server.connection.password_file"
    if (-not $user -or -not $pwfile) {
        # Dashboards read, they do not write: prefer the dedicated read-only
        # user (same posture as the MCP server); the runtime admin user is the
        # fallback for installs made before the read-only user existed.
        $user = Get-ExakitManifestValue "runtime.user"
        $pwfile = Get-ExakitManifestValue "runtime.password_file"
    }
    $instance = Join-Path $script:DashServerHome "instance"
    $exe = Join-Path $script:DashServerVenv "Scripts\dash-server.exe"

    New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
    $lines = @(
        "@echo off"
        "rem dash-server launcher - generated by the Exasol Personal Local Starter Kit."
        "rem Starts dash-server from its kit-managed venv with the kit's local Exasol"
        "rem database bootstrapped as a connection profile (DASH_SERVER_EXASOL_*)."
        "rem Variables you set yourself take precedence. Regenerated by:"
        "rem   exakit update dash-server"
        "if not defined DASH_SERVER_INSTANCE_PATH set `"DASH_SERVER_INSTANCE_PATH=$instance`""
    )
    if ($dsn -and $user -and $pwfile) {
        $lines += @(
            "if defined DASH_SERVER_EXASOL_DSN goto run"
            "if not defined EXA_PASSWORD if exist `"$pwfile`" set /p EXA_PASSWORD=<`"$pwfile`""
            "if not defined EXA_PASSWORD goto run"
            "set `"DASH_SERVER_EXASOL_PROFILE_NAME=$($script:DashServerProfile)`""
            "set `"DASH_SERVER_EXASOL_DSN=$dsn`""
            "set `"DASH_SERVER_EXASOL_USER=$user`""
            "set `"DASH_SERVER_EXASOL_SECRET_ENV_VAR=EXA_PASSWORD`""
            "rem The kit's local runtime speaks TLS with a self-signed certificate."
            "if not defined DASH_SERVER_EXASOL_TLS_VERIFY set `"DASH_SERVER_EXASOL_TLS_VERIFY=false`""
        )
    } else {
        Warn2 "No database connection is recorded yet - dash-server starts without a bootstrapped Exasol profile until the kit install completes."
    }
    $lines += @(
        ":run"
        "`"$exe`" %*"
    )
    try {
        Set-Content -Path (Get-DashServerLauncherPath) -Value ($lines -join "`r`n") -Encoding Ascii
    } catch {
        return (Write-DashServerNotInstalled "could not write the launcher at $(Get-DashServerLauncherPath)")
    }
    Ok "dash-server launcher written: $(Get-DashServerLauncherPath)"
    return $true
}

# Test-DashServer - prove the package imports, then start the server briefly
# and check the MCP control plane answers over HTTP. Both halves are soft: a
# failed live check records validated=false and warns rather than failing the
# marketplace install. Twin of dash_server_validate.
function Test-DashServer {
    $python = Get-DashServerVenvPython
    # Nothing to validate when the install did not get far enough: it is
    # soft-fail by design and has already explained itself.
    if (-not (Test-Path $python)) { return }
    $code = Invoke-ExakitLogged $python "-c" "import dash_server"
    if ($code -ne 0) {
        Warn2 "dash-server is installed but cannot be imported from $script:DashServerVenv (see log). Recorded validated=false; retry with: exakit update dash-server"
        Set-ExakitManifestValue "components.dash_server.validated" $false
        return
    }

    Info "Validating dash-server (MCP control plane on port $($script:DashServerPort))"
    # Something already answering on the port IS a running dash-server as far
    # as this check can tell; starting a second instance would fail on the bind.
    if (Test-DashServerHttpAnswers) {
        Ok "dash-server control plane answers on port $($script:DashServerPort)"
        Set-ExakitManifestValue "components.dash_server.validated" $true
        Write-DashServerUsagePanel
        return
    }

    $proc = $null
    try {
        $proc = Start-Process -FilePath (Get-DashServerLauncherPath) `
            -ArgumentList @("--host", "127.0.0.1", "--port", $script:DashServerPort) `
            -WindowStyle Hidden -PassThru
    } catch {
        Warn2 "dash-server could not be started for validation (see log). Recorded validated=false; retry with: exakit update dash-server"
        Set-ExakitManifestValue "components.dash_server.validated" $false
        return
    }
    $answered = $false
    $waited = 0
    while ($waited -lt 60) {
        if (Test-DashServerHttpAnswers) { $answered = $true; break }
        if ($proc.HasExited) { break }
        Start-Sleep -Seconds 2
        $waited += 2
    }
    # The launcher is a cmd wrapper: stop the whole tree, or the python server
    # it spawned keeps the port. Bounded and best-effort.
    try {
        & taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null
    } catch { }

    if ($answered) {
        Ok "dash-server control plane answers on port $($script:DashServerPort)"
        Set-ExakitManifestValue "components.dash_server.validated" $true
        Write-DashServerUsagePanel
    } else {
        Warn2 "dash-server did not answer on port $($script:DashServerPort) (see log). Recorded validated=false; retry with: exakit update dash-server"
        Set-ExakitManifestValue "components.dash_server.validated" $false
    }
}

# One bounded probe of the control plane. Any HTTP status counts: /mcp
# answering 4xx to a bare GET still proves the server is up.
function Test-DashServerHttpAnswers {
    try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:$($script:DashServerPort)/mcp" `
            -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        return ($null -ne $response)
    } catch [System.Net.WebException] {
        # A 4xx/3xx reply still proves a listener; only a connect failure
        # (no response object) means nothing answered.
        return ($null -ne $_.Exception.Response)
    } catch {
        return $false
    }
}

function Write-DashServerUsagePanel {
    Start-ExakitPanel "dash-server"
    Write-ExakitPanelLine "Start it        dash-server"
    Write-ExakitPanelLine "Dashboards      http://127.0.0.1:$($script:DashServerPort)"
    Write-ExakitPanelLine "MCP endpoint    http://127.0.0.1:$($script:DashServerPort)/mcp"
    Write-ExakitPanelLine "Update          exakit update dash-server"
    Complete-ExakitPanel
}

# ---------------------------------------------------------------------------
# Service lifecycle (twin of the dash_server_start/_stop/_status set)
# ---------------------------------------------------------------------------
$script:DashServerPidFile = Join-Path $script:DashServerHome "dash-server.pid"
$script:DashServerLog = Join-Path $script:LogDir "dash-server.log"

# What `exakit logs dash-server` shows. Twin of dash_server_log_path.
function Get-DashServerLogPath {
    return $script:DashServerLog
}

# running | stopped | not installed. The HTTP probe is the truth: the process
# may have been started by the Startup entry, by the user, or by exakit.
function Get-DashServerStatus {
    if (-not (Test-Path (Get-DashServerLauncherPath))) { return "not installed" }
    if (Test-DashServerHttpAnswers) { return "running" }
    return "stopped"
}

# The kit-managed dash-server processes: anything running out of this venv,
# which covers a Startup-started copy whose pid the kit never recorded.
function Get-DashServerProcessIds {
    $ids = @()
    if (Test-Path $script:DashServerPidFile) {
        $recorded = (Get-Content $script:DashServerPidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($recorded -match '^\d+$' -and (Get-Process -Id ([int]$recorded) -ErrorAction SilentlyContinue)) {
            $ids += [int]$recorded
        }
    }
    try {
        foreach ($proc in (Get-CimInstance Win32_Process -ErrorAction Stop |
                           Where-Object { $_.CommandLine -and $_.CommandLine.Contains($script:DashServerVenv) })) {
            if ($ids -notcontains [int]$proc.ProcessId) { $ids += [int]$proc.ProcessId }
        }
    } catch { }
    return $ids
}

# Bring it up in the background and wait until the control plane answers.
# Idempotent: an already-running server is reported, not duplicated.
function Start-DashServer {
    if (-not (Test-Path (Get-DashServerLauncherPath))) {
        Warn2 "dash-server is not installed - add it with: exakit marketplace"
        return $false
    }
    if (Test-DashServerHttpAnswers) {
        Ok "dash-server is already running (http://127.0.0.1:$($script:DashServerPort))"
        return $true
    }
    New-Item -ItemType Directory -Force -Path $script:DashServerHome, $script:LogDir | Out-Null
    Info "Starting dash-server on port $($script:DashServerPort)"
    try {
        $proc = Start-Process -FilePath (Get-DashServerLauncherPath) `
            -ArgumentList @("--host", "127.0.0.1", "--port", $script:DashServerPort) `
            -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $script:DashServerLog -RedirectStandardError "$($script:DashServerLog).err"
    } catch {
        Warn2 "dash-server could not be started: $_"
        return $false
    }
    Set-Content -Path $script:DashServerPidFile -Value $proc.Id -Encoding Ascii
    $waited = 0
    while ($waited -lt 60) {
        if (Test-DashServerHttpAnswers) {
            Ok "dash-server is running: http://127.0.0.1:$($script:DashServerPort) (MCP: /mcp)"
            return $true
        }
        if ($proc.HasExited) { break }
        Start-Sleep -Seconds 2
        $waited += 2
    }
    Warn2 "dash-server did not answer on port $($script:DashServerPort) - see $($script:DashServerLog)"
    return $false
}

# Stop every kit-managed dash-server process, bounded.
function Stop-DashServer {
    $ids = Get-DashServerProcessIds
    if ($ids.Count -eq 0 -and -not (Test-DashServerHttpAnswers)) {
        Ok "dash-server is already stopped"
        Remove-Item -Force -ErrorAction SilentlyContinue $script:DashServerPidFile
        return $true
    }
    Info "Stopping dash-server"
    foreach ($id in $ids) {
        try { & taskkill.exe /PID $id /T /F 2>$null | Out-Null } catch { }
    }
    Remove-Item -Force -ErrorAction SilentlyContinue $script:DashServerPidFile
    if (Test-DashServerHttpAnswers) {
        Warn2 "Something is still answering on port $($script:DashServerPort) (a dash-server the kit did not start?)"
        return $false
    }
    Ok "dash-server stopped"
    return $true
}

# What the boot entry runs. The launcher already bootstraps the database
# profile, so this is simply it.
function Get-DashServerAutostartCommand {
    return ('"{0}" --host 127.0.0.1 --port {1}' -f (Get-DashServerLauncherPath), $script:DashServerPort)
}

# Remove everything the dash-server install put on this machine: the venv,
# the instance state, the launcher, and the manifest record. -DryRun only
# narrates the plan. Best-effort and idempotent. Twin of dash_server_uninstall.
function Uninstall-DashServer {
    param([switch]$DryRun)
    # A running server holds its port and would outlive its own files.
    if (-not $DryRun) { [void](Stop-DashServer) }
    foreach ($path in @($script:DashServerVenv, $script:DashServerHome, (Get-DashServerLauncherPath))) {
        if (-not ($path -and (Test-Path $path))) { continue }
        if ($DryRun) { Info "  will remove: $path" }
        else {
            Info "Removing $path"
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $path
        }
    }
    if (-not $DryRun) {
        Remove-ExakitManifestValue "components.dash_server"
        Remove-ExakitManifestValue "desired.dash_server"
        Ok "dash-server removed - reinstall any time with: exakit marketplace"
    }
    return $true
}

# Update-DashServer - install the advertised version into the venv. Doubles as
# the repair command after a failed marketplace install. Asked for explicitly,
# so a failure here IS a failure. Twin of dash_server_update.
function Update-DashServer {
    $available = Get-ExakitComponentAvailable "dash-server"
    if (-not $available) { Fail "Could not resolve the advertised dash-server version." }
    $current = Get-DashServerInstalledVersion
    if ($current -and $current -eq $available) {
        # Same version can still need repair: regenerate the launcher so a
        # DSN/credential change since the install is picked up.
        [void](Write-DashServerLauncher)
        Ok "dash-server is already current ($current)"
        return
    }
    if ($current) { Info "Updating dash-server $current -> $available" }
    else { Info "Installing dash-server $available" }
    $script:DashServerVersion = $available
    $env:EXAKIT_FORCE_COMPONENT_INSTALL = "1"
    try {
        if (-not (Install-DashServer)) {
            Fail "dash-server could not be installed - see the warning above and the log."
        }
    } finally {
        Remove-Item Env:EXAKIT_FORCE_COMPONENT_INSTALL -ErrorAction SilentlyContinue
    }
    Test-DashServer
    Set-ExakitManifestValue "desired.dash_server" $script:DashServerVersion
    Ok "dash-server updated; database data was not changed"
}
