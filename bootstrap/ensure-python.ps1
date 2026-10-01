# ensure-python.ps1 - the ONLY PowerShell that knows how a Python gets onto this machine.
# Twin of bootstrap/ensure-python.sh; read that header for the contract.
# Windows PowerShell 5.1, ASCII only. Dot-source it, then call Confirm-ExakitPython.

$script:ExakitPythonVersion = if ($env:EXAKIT_PYTHON_VERSION) { $env:EXAKIT_PYTHON_VERSION } else { "3.12" }

function Test-ExakitPythonRuns {
    param([string]$Interpreter)
    if (-not $Interpreter -or -not (Test-Path $Interpreter)) { return $false }
    try {
        & $Interpreter -c "import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)" 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Get-ExakitVersionsValue {
    # One scalar from the kit's versions.json (dot path), PowerShell-native JSON.
    param([string]$Path, [string]$File)
    try { $doc = Get-Content -Raw -Encoding UTF8 $File | ConvertFrom-Json } catch { return $null }
    $node = $doc
    foreach ($part in $Path.Split(".")) {
        if ($null -eq $node) { return $null }
        $node = $node.$part
    }
    return $node
}

function Install-ExakitUv {
    param([string]$KitHome, [string]$KitDir)
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -ne "AMD64") { Write-Host "  [x] The kit's Python bootstrap supports x86_64 Windows only (found $arch)."; return $false }
    $version = Get-ExakitVersionsValue "tools.uv.version" (Join-Path $KitDir "versions.json")
    $want = Get-ExakitVersionsValue "tools.uv.sha256.windows-x86_64" (Join-Path $KitDir "versions.json")
    if (-not $version) { Write-Host "  [x] The kit's versions.json names no uv version (tools.uv.version)."; return $false }
    $url = "https://github.com/astral-sh/uv/releases/download/$version/uv-x86_64-pc-windows-msvc.zip"
    $dir = Join-Path $KitHome "tools\uv"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $zip = Join-Path $env:TEMP ("exakit-uv-" + [guid]::NewGuid().ToString("N") + ".zip")
    if ($env:EXAKIT_VERBOSE_BOOTSTRAP -eq "1") { Write-Host "  - Downloading uv $version" }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
    } catch { Write-Host "  [x] Could not download $url"; return $false }
    $got = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
    if ($want) {
        if ($got -ne ("" + $want).ToLower() -and $env:EXAKIT_ALLOW_UNVERIFIED_UV -ne "1") {
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            Write-Host "  [x] The uv download did not match its published checksum (expected $want, got $got)."
            return $false
        }
    } elseif ($env:EXAKIT_ALLOW_UNVERIFIED_UV -ne "1") {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Write-Host "  [x] versions.json carries no uv digest for windows-x86_64; refusing an unverified download."
        return $false
    }
    try { Expand-Archive -Path $zip -DestinationPath $dir -Force } catch { Write-Host "  [x] Could not unpack uv."; return $false }
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    return (Test-Path (Join-Path $dir "uv.exe"))
}

function Find-ExakitUv {
    param([string]$KitHome)
    if ($env:EXAKIT_UV_BIN -and (Test-Path $env:EXAKIT_UV_BIN)) { return $env:EXAKIT_UV_BIN }
    $own = Join-Path $KitHome "tools\uv\uv.exe"
    if (Test-Path $own) { return $own }
    $cmd = Get-Command uv.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# Confirm-ExakitPython - leaves $env:EXAKIT_PYTHON set. Returns 0, 3 (read-only, no download) or 1.
function Confirm-ExakitPython {
    $home_ = if ($env:EXAKIT_HOME) { $env:EXAKIT_HOME } else { Join-Path $HOME ".exasol-starter-kit" }
    $kitDir = if ($env:EXAKIT_KIT_DIR) { $env:EXAKIT_KIT_DIR } else { Join-Path $home_ "kit" }
    $record = Join-Path $home_ "python\interpreter"
    if (Test-ExakitPythonRuns $env:EXAKIT_PYTHON) { return 0 }
    if (Test-Path $record) {
        $recorded = (Get-Content $record -First 1).Trim()
        if (Test-ExakitPythonRuns $recorded) { $env:EXAKIT_PYTHON = $recorded; return 0 }
    }
    if ($env:EXAKIT_READONLY_QUERY -eq "1") { return 3 }
    $uv = Find-ExakitUv $home_
    if (-not $uv) {
        if (-not (Install-ExakitUv -KitHome $home_ -KitDir $kitDir)) { return 1 }
        $uv = Join-Path $home_ "tools\uv\uv.exe"
    }
    if ($env:EXAKIT_VERBOSE_BOOTSTRAP -eq "1") { Write-Host "  - Setting up the kit's Python $script:ExakitPythonVersion (managed by uv, never the system one)" }
    New-Item -ItemType Directory -Force -Path (Join-Path $home_ "python") | Out-Null
    $env:UV_PYTHON_INSTALL_DIR = Join-Path $home_ "python"
    & $uv python install $script:ExakitPythonVersion --quiet
    if ($LASTEXITCODE -ne 0) { Write-Host "  [x] uv could not install Python $script:ExakitPythonVersion."; return 1 }
    # A native call with redirected stderr runs inside a Continue window: 5.1
    # otherwise turns the redirect into a terminating error before it is read.
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { $interpreter = (& $uv python find $script:ExakitPythonVersion 2>$null | Select-Object -First 1) }
    finally { $ErrorActionPreference = $previousEap }
    if (-not (Test-ExakitPythonRuns $interpreter)) { Write-Host "  [x] The Python uv installed does not run."; return 1 }
    [System.IO.File]::WriteAllText($record, $interpreter + "`n")
    $env:EXAKIT_PYTHON = $interpreter
    return 0
}
