# json-tables.ps1 - JSON Tables (ingest, query and reshape JSON-shaped data in
# Exasol): Windows counterpart of json-tables.sh.
#
# A MARKETPLACE ADD-ON: never installed by the setup scripts.
#
# WHY THIS FILE USED TO ONLY GATE, AND WHAT CHANGED
#
# The kit's whole point with this add-on is that nobody needs a Rust toolchain:
# .github/workflows/pkg-json-tables.yml builds the ingest engine for every
# platform (Windows included) and the wheel, and publishes both to the
# 'mirror-json-tables' release. On macOS and Linux the kit then puts a tiny
# 'cargo' shim in front of the CLI, because upstream runs the engine with
# exactly one call shape and no prebuilt-binary escape hatch:
#
#     subprocess.run(["cargo", "run", "--manifest-path", <crate>/Cargo.toml,
#                     "--", "--input", ...])          python/exasol_json_tables/cli.py
#
# A SHELL shim cannot work on Windows. subprocess.run with an argument list
# goes to CreateProcess, and CreateProcess resolves a bare name by appending
# .exe only - it never consults PATHEXT - so a cargo.cmd or cargo.bat placed on
# PATH is simply not found. That is why this add-on reported itself
# unavailable here.
#
# The answer is the one the old comment named: a compiled launcher. The shim is
# now a real Windows executable, built from setup/shim/json-tables-cargo by the
# same workflow that builds the engine and published beside it. The toolchain
# requirement moves to OUR build machine, which is exactly the trade this
# add-on exists to make - the user still installs nothing but prebuilt bytes.
#
#   - venv:     $EXAKIT_HOME\json-tables-venv
#   - engine:   $EXAKIT_HOME\json-tables\libexec\json_to_parquet.exe
#   - shim:     $EXAKIT_HOME\json-tables\shim\cargo.exe
#   - launcher: $BinDir\exasol-json-tables.cmd

$script:JsonTablesVersionFallback = if ($env:EXAKIT_JSON_TABLES_VERSION_FALLBACK) { $env:EXAKIT_JSON_TABLES_VERSION_FALLBACK } else { "v0.2" }
$script:JsonTablesVersion = if ($env:EXAKIT_JSON_TABLES_VERSION) { $env:EXAKIT_JSON_TABLES_VERSION } else { "" }
$script:JsonTablesMirrorTag = if ($env:EXAKIT_JSON_TABLES_MIRROR_TAG) { $env:EXAKIT_JSON_TABLES_MIRROR_TAG } else { "mirror-json-tables" }
$script:JsonTablesPackage = if ($env:EXAKIT_JSON_TABLES_PACKAGE) { $env:EXAKIT_JSON_TABLES_PACKAGE } else { "exasol-json-tables" }
$script:JsonTablesVenv = if ($env:EXAKIT_JSON_TABLES_VENV) { $env:EXAKIT_JSON_TABLES_VENV } else { Join-Path $script:ExakitHome "json-tables-venv" }
$script:JsonTablesHome = if ($env:EXAKIT_JSON_TABLES_HOME) { $env:EXAKIT_JSON_TABLES_HOME } else { Join-Path $script:ExakitHome "json-tables" }

function Get-JsonTablesLogPath {
    return (Join-Path $script:LogDir "json-tables.log")
}

function Get-JsonTablesVenvPython {
    return (Join-Path $script:JsonTablesVenv "Scripts\python.exe")
}

function Get-JsonTablesEnginePath {
    return (Join-Path $script:JsonTablesHome "libexec\json_to_parquet.exe")
}

function Get-JsonTablesShimDir {
    return (Join-Path $script:JsonTablesHome "shim")
}

function Get-JsonTablesBin {
    if ($env:EXAKIT_JSON_TABLES_BIN) { return $env:EXAKIT_JSON_TABLES_BIN }
    return (Join-Path $script:BinDir "exasol-json-tables.cmd")
}

# Twin of json_tables_mirror_repo: the prebuilt artifacts come from the
# repository THIS KIT WAS INSTALLED FROM, so a fork that runs the packaging
# workflow serves its own users with no configuration.
function Get-JsonTablesMirrorRepo {
    if ($env:EXAKIT_JSON_TABLES_MIRROR_REPO) { return $env:EXAKIT_JSON_TABLES_MIRROR_REPO }
    $src = Get-ExakitManifestValue "kit.source"
    if ($src -and $src -match '^([^@]+/[^@]+)@') { return $Matches[1] }
    return $script:KitRepo
}

# Twin of json_tables_engine_asset. The workflow builds a Windows engine, and
# x64 is the distribution it publishes.
function Get-JsonTablesEngineAsset {
    if (Get-ExakitHostArch) {
        if ((Get-ExakitHostArch) -eq "arm64") { return "" }
    }
    if (-not [System.Environment]::Is64BitOperatingSystem) { return "" }
    return "exasol-json-tables-ingest-windows-x86_64.exe"
}

# The compiled cargo stand-in, built from setup/shim/json-tables-cargo. Without
# it a prebuilt engine is unreachable on Windows, so it is as much a required
# artifact as the engine itself.
function Get-JsonTablesShimAsset {
    if ((Get-JsonTablesEngineAsset) -eq "") { return "" }
    return "exakit-json-tables-cargo-windows-x86_64.exe"
}

# Twin of json_tables_applicable. Windows x64 is supported now; anything else
# still says so rather than being silently omitted.
function Test-JsonTablesApplicable {
    return ((Get-JsonTablesEngineAsset) -ne "")
}

function Get-JsonTablesApplicableReason {
    return "no prebuilt ingest engine is published for this platform (windows/$(if ((Get-ExakitHostArch) -eq 'arm64') { 'arm64' } else { 'x86' })). Windows x86_64 is supported; ARM64 is not built yet."
}

# Twin of json_tables_system_present: a copy the user installed themselves
# (pip, pipx, uv tool) counts as "already on this machine". The kit does not
# offer a second one and never manages or removes theirs.
function Get-JsonTablesSystemPresent {
    $own = Get-JsonTablesBin
    $found = Get-Command "exasol-json-tables" -ErrorAction SilentlyContinue
    if ($found -and $found.Source) {
        if ($found.Source -ne $own) { return $true }
    }
    # Only the ambient interpreter, never the kit's own venv: importing it
    # there is a KIT install, which is a different thing entirely.
    $python = Get-Command "python" -ErrorAction SilentlyContinue
    if (-not $python -or -not $python.Source) { return $false }
    if ($python.Source.StartsWith($script:JsonTablesVenv, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ($python.Source.StartsWith($script:ExakitHome, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    & $python.Source -c "import exasol_json_tables" 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Twin of json_tables_installed_version: both halves must really be here. The
# manifest record alone is not evidence - it may have been written by another
# machine, or the files removed since.
function Get-JsonTablesInstalledVersion {
    $recorded = Get-ExakitManifestValue "components.json_tables.version"
    if (-not $recorded) { return "" }
    if (-not (Test-Path (Get-JsonTablesVenvPython))) { return "" }
    if (-not (Test-Path (Get-JsonTablesEnginePath))) { return "" }
    return $recorded
}

function Write-JsonTablesNotInstalled {
    param([Parameter(Mandatory)][string]$Reason)
    Warn2 "JSON Tables was not installed: $Reason"
    Warn2 "Everything else in the kit is unaffected. Retry with: exakit update json-tables"
    if (Get-Command Set-ExakitFailureReason -ErrorAction SilentlyContinue) {
        Set-ExakitFailureReason $Reason
    }
    Set-ExakitManifestValue "components.json_tables.validated" $false
    return $false
}

# ---------------------------------------------------------------------------
# The mirror release - twins of the _json_tables_mirror_* helpers
# ---------------------------------------------------------------------------
function Get-JsonTablesMirrorRelease {
    if ($script:JsonTablesMirrorCache) { return $script:JsonTablesMirrorCache }
    try {
        $uri = "https://api.github.com/repos/$(Get-JsonTablesMirrorRepo)/releases/tags/$($script:JsonTablesMirrorTag)"
        $script:JsonTablesMirrorCache = Invoke-RestMethod -Uri $uri -UseBasicParsing -TimeoutSec 20
        return $script:JsonTablesMirrorCache
    } catch {
        return $null
    }
}

function Get-JsonTablesMirrorAssetUrl {
    param([Parameter(Mandatory)][string]$Asset)
    return "https://github.com/$(Get-JsonTablesMirrorRepo)/releases/download/$($script:JsonTablesMirrorTag)/$Asset"
}

# The wheel's real filename: its version comes from upstream's pyproject, not
# from ours, so it is read off the release rather than constructed.
function Get-JsonTablesMirrorWheelName {
    $release = Get-JsonTablesMirrorRelease
    if (-not $release) { return "" }
    # NEWEST wheel, not the first one listed. The mirror release is rolling and
    # accumulates assets across runs, so it can hold several wheels at once -
    # taking the first would install an old one while recording the version of
    # the current build, a mismatch no update could ever close. The most
    # recently uploaded asset is the one this build published.
    $wheels = @($release.assets | Where-Object { $_.name -and $_.name.EndsWith(".whl") })
    if ($wheels.Count -eq 0) { return "" }
    $newest = $wheels | Sort-Object { [datetime]$_.created_at } -Descending | Select-Object -First 1
    return $newest.name
}

# The sha256 GitHub publishes for a release asset. The mirror tag is rolling
# (it moves whenever upstream does), so a digest pinned in versions.json would
# go stale by design: the release API is the right authority here.
function Get-JsonTablesMirrorDigest {
    param([Parameter(Mandatory)][string]$Asset)
    $release = Get-JsonTablesMirrorRelease
    if (-not $release) { return "" }
    # The loop variable must NOT be spelled $asset: PowerShell identifiers are
    # case-insensitive, so it would be the same variable as the $Asset
    # parameter and would overwrite the very name being searched for. Every
    # digest then came back empty, and an empty digest means the download is
    # refused as unverifiable - the add-on could never install.
    foreach ($candidate in @($release.assets)) {
        if ($candidate.name -eq $Asset -and $candidate.digest -and ("" + $candidate.digest).StartsWith("sha256:")) {
            return ("" + $candidate.digest).Substring(7)
        }
    }
    return ""
}

# The upstream build the mirror actually carries, from the `version=` line the
# packaging workflow writes into the release body. This is the ONLY version
# that can be installed: the artifacts for it are the ones on that release.
function Get-JsonTablesMirrorVersion {
    $release = Get-JsonTablesMirrorRelease
    if (-not $release) { return "" }
    if (("" + $release.body) -match 'version=([A-Za-z0-9._+-]+)') { return $Matches[1] }
    return ""
}

# The generic <id>_latest hook. "Latest" deliberately means whatever the kit's
# own packaging workflow has already BUILT, which can lag upstream by a run:
# advertising a version whose prebuilt engine does not exist yet would break
# the one promise this add-on makes.
function Get-JsonTablesLatest {
    return (Get-JsonTablesMirrorVersion)
}

# Download one mirror asset and verify it against the digest the release
# publishes. Same bar as exapump and the VS Code extension: an artifact that
# cannot be verified is not installed.
function Get-JsonTablesVerifiedAsset {
    param([Parameter(Mandatory)][string]$Asset, [Parameter(Mandatory)][string]$Destination)
    $url = Get-JsonTablesMirrorAssetUrl -Asset $Asset
    Info "Downloading $Asset"
    try {
        # Animated: the download is the longest silent stretch of this install.
        # Twin of fetch_quiet on the shell side.
        [void](Invoke-ExakitWithSpinner -Label "Downloading $Asset" -Body {
            Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 -Uri $url -OutFile $Destination
        })
    } catch {
        Warn2 "Download failed: $url ($_)"
        return $false
    }
    $expected = Get-JsonTablesMirrorDigest -Asset $Asset
    if ($expected) {
        $actual = (Get-FileHash -Algorithm SHA256 -Path $Destination).Hash.ToLower()
        if ($actual -ne $expected) {
            Remove-Item -Force -ErrorAction SilentlyContinue $Destination
            Warn2 "Checksum mismatch for $Asset (expected $expected, got $actual)"
            return $false
        }
        Ok "Checksum verified: $Asset"
        return $true
    }
    if ($env:EXAKIT_ALLOW_UNVERIFIED_JSON_TABLES -eq "1") {
        Warn2 "No digest available for $Asset - proceeding WITHOUT checksum verification (EXAKIT_ALLOW_UNVERIFIED_JSON_TABLES=1)."
        return $true
    }
    Remove-Item -Force -ErrorAction SilentlyContinue $Destination
    Warn2 "No checksum is available for $Asset; refusing an unverified artifact."
    return $false
}

# Test-JsonTablesAppControl - is this machine refusing to run unsigned
# executables?
#
# The kit's prebuilt engine and cargo shim are not code-signed, and a Windows
# box with Windows Defender Application Control in ENFORCED mode (or Smart App
# Control on) refuses to start them with a bare "Access is denied" - the same
# symptom a corrupt download or a wrong-architecture binary produces. Observed
# on a managed corporate machine: a signed executable copied into the very same
# directory ran fine while the engine did not, with the digest matching the
# published artifact byte for byte.
#
# Answering this before blaming the artifact is what turns a dead end into a
# next step the user can actually take.
function Test-JsonTablesAppControl {
    try {
        $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction Stop
        if ($dg.CodeIntegrityPolicyEnforcementStatus -ge 2) { return $true }
        if ($dg.UsermodeCodeIntegrityPolicyEnforcementStatus -ge 2) { return $true }
    } catch { }
    try {
        $ci = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy" -ErrorAction Stop
        # 1 = Smart App Control on, 2 = evaluation mode.
        if ($ci.VerifiedAndReputablePolicyState -eq 1) { return $true }
    } catch { }
    return $false
}

function Install-JsonTables {
    if (-not (Test-JsonTablesApplicable)) {
        return (Write-JsonTablesNotInstalled (Get-JsonTablesApplicableReason))
    }

    # What gets installed is what the mirror carries, so that is what gets
    # recorded - otherwise `exakit version` would show a difference no update
    # could ever close.
    if (-not $script:JsonTablesVersion) {
        $script:JsonTablesVersion = Get-JsonTablesMirrorVersion
        if (-not $script:JsonTablesVersion) {
            $script:JsonTablesVersion = Get-ExakitAddonAdvertisedVersion -Id "json-tables" -Fallback $script:JsonTablesVersionFallback
        }
    }

    $engineAsset = Get-JsonTablesEngineAsset
    $shimAsset = Get-JsonTablesShimAsset

    $wheelName = Get-JsonTablesMirrorWheelName
    if (-not $wheelName) {
        return (Write-JsonTablesNotInstalled "the prebuilt mirror release '$($script:JsonTablesMirrorTag)' was not found in $(Get-JsonTablesMirrorRepo). Run the 'pkg / json-tables' workflow once to publish it (it builds the engine and the cargo shim for every platform so nobody needs Rust).")
    }

    try {
        $uv = Install-ExakitUv
    } catch {
        return (Write-JsonTablesNotInstalled "uv (the Python tool runner) is not available - install it from https://docs.astral.sh/uv/ and re-run")
    }
    if (-not $uv) {
        return (Write-JsonTablesNotInstalled "uv (the Python tool runner) is not available - install it from https://docs.astral.sh/uv/ and re-run")
    }

    Info "Installing JSON Tables $($script:JsonTablesVersion) (prebuilt)"
    $python = Get-JsonTablesVenvPython
    if (-not (Test-Path $python)) {
        $code = Invoke-ExakitLogged $uv "venv" "--seed" "--python" $script:ManagedPythonVersion $script:JsonTablesVenv
        if ($code -ne 0) {
            return (Write-JsonTablesNotInstalled "the virtual environment at $($script:JsonTablesVenv) could not be created (see log)")
        }
    }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-json-tables-" + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        # 1. the Python package
        $wheelPath = Join-Path $tmp $wheelName
        if (-not (Get-JsonTablesVerifiedAsset -Asset $wheelName -Destination $wheelPath)) {
            return (Write-JsonTablesNotInstalled "the prebuilt wheel could not be downloaded or verified (see log)")
        }
        $code = Invoke-ExakitLogged $uv "pip" "install" "--python" $python $wheelPath
        if ($code -ne 0) {
            return (Write-JsonTablesNotInstalled "installing $wheelName failed (see log)")
        }
        Restore-JsonTablesPackageData

        # 2. the ingest engine, prebuilt for this platform
        $enginePath = Get-JsonTablesEnginePath
        $engineTmp = Join-Path $tmp "engine.exe"
        if (-not (Get-JsonTablesVerifiedAsset -Asset $engineAsset -Destination $engineTmp)) {
            return (Write-JsonTablesNotInstalled "the prebuilt ingest engine ($engineAsset) could not be downloaded or verified (see log)")
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $enginePath) | Out-Null
        Move-Item -Force -Path $engineTmp -Destination $enginePath

        # 3. the compiled cargo shim - the piece that makes a prebuilt engine
        #    reachable at all on Windows.
        $shimDir = Get-JsonTablesShimDir
        $shimPath = Join-Path $shimDir "cargo.exe"
        $shimTmp = Join-Path $tmp "cargo.exe"
        if (-not (Get-JsonTablesVerifiedAsset -Asset $shimAsset -Destination $shimTmp)) {
            return (Write-JsonTablesNotInstalled "the cargo shim ($shimAsset) could not be downloaded or verified. Without it the CLI cannot reach the prebuilt engine on Windows (see log)")
        }
        New-Item -ItemType Directory -Force -Path $shimDir | Out-Null
        Move-Item -Force -Path $shimTmp -Destination $shimPath
    } finally {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
    }

    # The engine must actually run HERE: a binary for the wrong arch would
    # otherwise surface much later, in the middle of someone's ingest.
    $code = Invoke-ExakitLogged (Get-JsonTablesEnginePath) "--help"
    if ($code -ne 0) {
        if (Test-JsonTablesAppControl) {
            return (Write-JsonTablesNotInstalled "the prebuilt ingest engine was downloaded and its checksum verified, but this machine refuses to run it: Windows application control (WDAC / Smart App Control) is enforcing, and the engine is not code-signed. This is a policy on the machine, not a fault in the download. Ask whoever manages this device to allow $(Get-JsonTablesEnginePath), or use WSL, where the same add-on installs and runs unrestricted.")
        }
        return (Write-JsonTablesNotInstalled "the prebuilt ingest engine does not run on this machine (see log)")
    }

    if (-not (Write-JsonTablesLauncher)) { return $false }

    Set-ExakitManifestValue "components.json_tables.version" $script:JsonTablesVersion
    Set-ExakitManifestValue "components.json_tables.venv" $script:JsonTablesVenv
    Set-ExakitManifestValue "components.json_tables.python" (Get-JsonTablesVenvPython)
    Set-ExakitManifestValue "components.json_tables.engine" (Get-JsonTablesEnginePath)
    Set-ExakitManifestValue "components.json_tables.shim" (Join-Path (Get-JsonTablesShimDir) "cargo.exe")
    Set-ExakitManifestValue "components.json_tables.command" (Get-JsonTablesBin)
    Ok "JSON Tables installed: $($script:JsonTablesVenv)"
    return $true
}

# Twin of _json_tables_restore_package_data.
#
# UPSTREAM PACKAGING GAP: pyproject covers the .py modules under
# python/exasol_json_tables but not preprocessor_assets/jvs_preprocessor_lib.lua,
# so every prebuilt wheel is missing it. `ingest` is unaffected;
# `ingest-and-wrap` and `wrap` fail with FILE-NOT-FOUND when they reach the
# step that installs the preprocessor into Exasol. Nothing is overwritten, so a
# fixed upstream release simply makes this a no-op.
function Restore-JsonTablesPackageData {
    $python = Get-JsonTablesVenvPython
    if (-not (Test-Path $python)) { return }
    $site = & $python -c "import exasol_json_tables, os; print(os.path.dirname(exasol_json_tables.__file__))" 2>$null
    if (-not $site -or -not (Test-Path $site)) { return }
    $asset = Join-Path $site "preprocessor_assets\jvs_preprocessor_lib.lua"
    if (Test-Path $asset) { return }
    $repo = if ($env:EXAKIT_JSON_TABLES_REPO) { $env:EXAKIT_JSON_TABLES_REPO } else { "exasol-labs/exasol-json-tables" }
    $url = "https://raw.githubusercontent.com/$repo/main/python/exasol_json_tables/preprocessor_assets/jvs_preprocessor_lib.lua"
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $asset) | Out-Null
        [void](Invoke-ExakitWithSpinner -Label "Restoring the JSON Tables preprocessor asset" -Body {
            Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri $url -OutFile $asset
        })
        Info "Restored 1 data file the release does not declare as package data (upstream packaging gap; ingest-and-wrap needs it)"
    } catch {
        # Not fatal: plain `ingest` works without it.
    }
}

# Write-JsonTablesLauncher - the command a user runs.
#
# It puts the shim dir at the FRONT of PATH for this process only, so the CLI's
# `cargo` call reaches our cargo.exe while the user's real cargo stays untouched
# everywhere else, and names the engine in the environment so the shim does not
# have to guess.
function Write-JsonTablesLauncher {
    New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
    $launcher = Get-JsonTablesBin
    $venvBin = Join-Path $script:JsonTablesVenv "Scripts\exasol-json-tables.exe"
    $lines = @(
        '@echo off',
        'rem exasol-json-tables launcher - generated by the Exasol Personal Local',
        'rem Starter Kit. Runs the CLI from its kit-managed venv with the prebuilt',
        'rem ingest engine reachable through the compiled cargo shim, so no Rust',
        'rem toolchain is needed. Regenerated by: exakit update json-tables',
        ('set "PATH=' + (Get-JsonTablesShimDir) + ';%PATH%"'),
        ('set "EXAKIT_JSON_TABLES_ENGINE=' + (Get-JsonTablesEnginePath) + '"'),
        ('"' + $venvBin + '" %*')
    )
    try {
        Set-Content -Path $launcher -Value $lines -Encoding ASCII
    } catch {
        return (Write-JsonTablesNotInstalled "could not write the launcher at $launcher")
    }
    Ok "JSON Tables launcher written: $launcher"
    if (Get-Command Confirm-ExakitOnPath -ErrorAction SilentlyContinue) {
        Confirm-ExakitOnPath $script:BinDir
    }
    return $true
}

# Prove the whole path, not just that files exist: the package imports, and a
# real JSON file goes through the prebuilt engine and comes out as Parquet.
# That round trip is the only evidence the no-Rust story holds on this machine.
function Test-JsonTables {
    $python = Get-JsonTablesVenvPython
    if (-not (Test-Path $python)) { return }

    & $python -c "import exasol_json_tables" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Warn2 "JSON Tables is installed but cannot be imported from $($script:JsonTablesVenv) (see log). Recorded validated=false."
        Set-ExakitManifestValue "components.json_tables.validated" $false
        return
    }

    Info "Validating JSON Tables (a real JSON file through the prebuilt engine)"
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-jt-check-" + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $sample = Join-Path $tmp "sample.json"
        Set-Content -Path $sample -Value '[{"id":1,"name":"alpha"},{"id":2,"name":"beta"}]' -Encoding ASCII
        $outDir = Join-Path $tmp "out"
        $code = Invoke-ExakitLogged (Get-JsonTablesEnginePath) "--input" $sample "--output-dir" $outDir
        $parquet = @()
        if (Test-Path $outDir) {
            $parquet = @(Get-ChildItem -Path $outDir -Filter *.parquet -Recurse -ErrorAction SilentlyContinue)
        }
        if ($code -eq 0 -and $parquet.Count -gt 0) {
            Ok "Ingest works: JSON in, Parquet out"
            Set-ExakitManifestValue "components.json_tables.validated" $true
            # See the note on Write-DashServerUsagePanel: a marketplace
            # install is not where a reference card belongs.
            if ($script:ExakitQuietDetail) {
                Write-ExakitLog "DATA" "json-tables: exasol-json-tables ingest --input <file.json>"
                return
            }
            Start-ExakitPanel "JSON Tables"
            Write-ExakitPanelLine "Run it          exasol-json-tables --help"
            Write-ExakitPanelLine "Ingest JSON     exasol-json-tables ingest --input <file.json>"
            Write-ExakitPanelLine "Engine          $(Get-JsonTablesEnginePath)"
            Write-ExakitPanelLine "Update          exakit update json-tables"
            Complete-ExakitPanel
            return
        }
    } finally {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
    }
    Warn2 "The ingest round trip did not produce Parquet (see: exakit logs json-tables). Recorded validated=false; retry with: exakit update json-tables"
    Set-ExakitManifestValue "components.json_tables.validated" $false
}

# The venv, the engine, the shim, the launcher and the manifest record.
# Get-JsonTablesSummary - the one fact worth a place on the result line.
# Optional registry hook (SummaryFn); twin of json_tables_summary.
function Get-JsonTablesSummary {
    # 31 characters: the finished cell truncates at 33 in the plain palette.
    return "ingest JSON: exasol-json-tables"
}

function Uninstall-JsonTables {
    param([switch]$DryRun)
    foreach ($path in @($script:JsonTablesVenv, $script:JsonTablesHome, (Get-JsonTablesBin))) {
        if (-not (Test-Path $path)) { continue }
        if ($DryRun) {
            Info "  will remove: $path"
        } else {
            Info "Removing $path"
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $path
        }
    }
    if (-not $DryRun) {
        Remove-ExakitManifestValue "components.json_tables"
        Remove-ExakitManifestValue "desired.json_tables"
        OkStep "JSON Tables removed - reinstall any time with: exakit marketplace"
    }
    return $true
}

# Install the advertised build. Doubles as the repair command (it re-downloads
# the engine and the shim and rewrites the launcher), so an explicit
# `exakit update json-tables` is always worth running.
function Update-JsonTables {
    if (-not (Test-JsonTablesApplicable)) {
        Warn2 "JSON Tables is not available on this machine: $(Get-JsonTablesApplicableReason)"
        return $false
    }
    $available = Get-JsonTablesMirrorVersion
    if (-not $available) {
        $available = Get-ExakitAddonAdvertisedVersion -Id "json-tables" -Fallback $script:JsonTablesVersionFallback
    }
    if (-not $available) { Fail "Could not resolve the advertised json-tables version." }
    $current = Get-JsonTablesInstalledVersion
    if ($current) { Info "Updating JSON Tables $current -> $available" }
    else { Info "Installing JSON Tables $available" }
    $script:JsonTablesVersion = $available
    if (-not (Install-JsonTables)) {
        Fail "JSON Tables could not be installed - see the warning above and the log."
    }
    Test-JsonTables
    Set-ExakitManifestValue "desired.json_tables" $script:JsonTablesVersion
    Ok "JSON Tables updated; database data was not changed"
    return $true
}
