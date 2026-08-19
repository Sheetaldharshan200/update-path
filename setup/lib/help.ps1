# help.ps1 - Windows twin of help.sh: the kit's help system, rendered from the
# documents in setup/help/*.json rather than from hardcoded text.
#
# Same policy as the bash side. The data is read, in order, from:
#   1. the cached copy fetched from the kit repository, while it is fresh
#   2. the copy that shipped with this kit (setup/help/)
# The fetch is https-only, validated before it is trusted, written atomically,
# and never fatal - offline renders the copy on disk and says nothing.
#
# PowerShell parses JSON natively, so unlike the bash twin this side needs no
# Python. Keep it 5.1 compatible: no ternary, no null-coalescing.

$script:ExakitHelpRepo = if ($env:EXAKIT_HELP_REPO) { $env:EXAKIT_HELP_REPO } elseif ($script:KitRepo) { $script:KitRepo } else { "exasol-labs/exasol-personal-local-starterkit" }
$script:ExakitHelpUrl = if ($env:EXAKIT_HELP_URL) { $env:EXAKIT_HELP_URL } else { "https://raw.githubusercontent.com/$($script:ExakitHelpRepo)/main/setup/help" }
$script:ExakitHelpTtl = if ($env:EXAKIT_HELP_TTL) { [int]$env:EXAKIT_HELP_TTL } else { 86400 }
$script:ExakitHelpOffline = ($env:EXAKIT_HELP_OFFLINE -eq "1")

function Get-ExakitHelpKitDir {
    if ($script:LibDir) {
        $candidate = Join-Path (Split-Path $script:LibDir -Parent) "help"
        if (Test-Path $candidate) { return $candidate }
    }
    return (Join-Path (Join-Path $script:ExakitHome "kit") "setup\help")
}

function Get-ExakitHelpCacheDir {
    if ($env:EXAKIT_HELP_CACHE_DIR) { return $env:EXAKIT_HELP_CACHE_DIR }
    return (Join-Path $script:ExakitHome "cache\help")
}

function Get-ExakitHelpIds {
    $dir = Get-ExakitHelpKitDir
    if (-not (Test-Path $dir)) { return @() }
    $ids = @()
    foreach ($file in (Get-ChildItem -Path $dir -Filter "*.json" -ErrorAction SilentlyContinue)) {
        $ids += $file.BaseName
    }
    return ($ids | Sort-Object)
}

function Test-ExakitHelpId {
    param([string]$Id)
    return ((Get-ExakitHelpIds) -contains $Id)
}

# A document is trusted only if it parses and carries the id it claims to.
function Test-ExakitHelpDocument {
    param([string]$Path, [string]$Id)
    if (-not (Test-Path $Path)) { return $false }
    try {
        $doc = Get-Content -Raw -Path $Path -Encoding UTF8 | ConvertFrom-Json
    } catch { return $false }
    if (-not $doc) { return $false }
    if ($doc.id -ne $Id) { return $false }
    if (-not $doc.schema_version) { return $false }
    return $true
}

function Update-ExakitHelpCache {
    param([string]$Id)
    if ($script:ExakitHelpOffline) { return $false }
    if ($script:ExakitHelpUrl -notmatch '^https://') { return $false }
    $cacheDir = Get-ExakitHelpCacheDir
    $cache = Join-Path $cacheDir "$Id.json"
    if (Test-Path $cache) {
        $age = ((Get-Date) - (Get-Item $cache).LastWriteTime).TotalSeconds
        if ($script:ExakitHelpTtl -gt 0 -and $age -lt $script:ExakitHelpTtl) { return $false }
    }
    # The attempt marker is what keeps help instant: a repository that has not
    # published these documents yet, or a machine with no network, must not pay
    # a request timeout on every run. Touched before the request, so one attempt
    # per id per TTL is made whatever the outcome.
    $attempt = Join-Path $cacheDir ".attempt-$Id"
    if (Test-Path $attempt) {
        $attemptAge = ((Get-Date) - (Get-Item $attempt).LastWriteTime).TotalSeconds
        if ($script:ExakitHelpTtl -gt 0 -and $attemptAge -lt $script:ExakitHelpTtl) { return $false }
    }
    New-Item -ItemType Directory -Force -Path $cacheDir -ErrorAction SilentlyContinue | Out-Null
    New-Item -ItemType File -Force -Path $attempt -ErrorAction SilentlyContinue | Out-Null
    $tmp = "$cache.tmp"
    try {
        Invoke-WebRequest -Uri "$($script:ExakitHelpUrl)/$Id.json" -OutFile $tmp -UseBasicParsing -TimeoutSec 5
    } catch {
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
        return $false
    }
    if (-not (Test-ExakitHelpDocument $tmp $Id)) {
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
        return $false
    }
    Move-Item -Force $tmp $cache -ErrorAction SilentlyContinue
    return $true
}

function Get-ExakitHelpDocument {
    param([string]$Id, [switch]$NoFetch)
    if (-not $NoFetch) { Update-ExakitHelpCache -Id $Id | Out-Null }
    $cache = Join-Path (Get-ExakitHelpCacheDir) "$Id.json"
    if (Test-ExakitHelpDocument $cache $Id) {
        return (Get-Content -Raw -Path $cache -Encoding UTF8 | ConvertFrom-Json)
    }
    $shipped = Join-Path (Get-ExakitHelpKitDir) "$Id.json"
    if (Test-Path $shipped) {
        try { return (Get-Content -Raw -Path $shipped -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}

# Get-ExakitHelpDocuments [-Primary <id>] - every document, but only <Primary>
# (the one this screen is ABOUT) is refreshed from the repository. The others
# are read from disk: the overview and catalog only skim them for a tagline,
# and nine round trips to draw one screen is not a help system anyone waits for.
function Get-ExakitHelpDocuments {
    param([string]$Primary = "exakit")
    $map = @{}
    foreach ($id in (Get-ExakitHelpIds)) {
        if ($id -eq $Primary) {
            $doc = Get-ExakitHelpDocument -Id $id
        } else {
            $doc = Get-ExakitHelpDocument -Id $id -NoFetch
        }
        if ($doc) { $map[$id] = $doc }
    }
    return $map
}

# --- rendering --------------------------------------------------------------

# Every binary the kit documents. A command whose first word is one of these is
# already spelled out ("exakit start" on the runtime page); anything else is a
# bare subcommand and gets its document's prefix put in front. Twin of
# KNOWN_TOOLS / invocation() in help.sh.
$script:ExakitHelpKnownTools = @("exakit", "exapump", "exasol", "dash-server",
    "exasol-json-tables", "exasol-mcp-server", "exasol-mcp-server-http")

function Get-ExakitHelpInvocation {
    param([string]$DocId, $Entry, $Doc)
    $command = ""
    if ($Entry.command) { $command = ([string]$Entry.command).Trim() }
    $parts = $command -split '\s+'
    if ($parts.Count -gt 0 -and $script:ExakitHelpKnownTools -contains $parts[0]) {
        return $command
    }
    $prefix = $DocId
    if ($Doc -and $Doc.invocation_prefix) { $prefix = $Doc.invocation_prefix }
    return ("$prefix $command").Trim()
}

function Get-ExakitHelpInvocationWithOptions {
    param([string]$DocId, $Entry, $Doc)
    $label = Get-ExakitHelpInvocation -DocId $DocId -Entry $Entry -Doc $Doc
    if ($Entry.options) { $label = "$label $($Entry.options)" }
    return $label
}

function Write-ExakitHelpWrapped {
    param([string]$Text, [string]$Indent = "    ", [string]$First = $null)
    if (-not $Text) { return }
    $width = 100
    try { if ($Host.UI.RawUI.WindowSize.Width -gt 40) { $width = [Math]::Min(100, $Host.UI.RawUI.WindowSize.Width) } } catch { }
    $limit = $width - $Indent.Length
    if ($limit -lt 20) { $limit = 20 }
    $line = ""
    $prefix = $Indent
    if ($First) { $prefix = $First }
    foreach ($word in ($Text -split '\s+')) {
        if (-not $word) { continue }
        if (($line.Length + $word.Length + 1) -gt $limit -and $line) {
            Write-Host ($prefix + $line)
            $line = $word
            $prefix = $Indent
        } else {
            if ($line) { $line = "$line $word" } else { $line = $word }
        }
    }
    if ($line) { Write-Host ($prefix + $line) }
}

function Write-ExakitHelpHeader {
    param([string]$Title, [string]$Subtitle)
    Write-Host ""
    Write-Host ("  " + ("-" * 70)) -ForegroundColor Cyan
    if ($Subtitle) {
        Write-Host "   $Title  " -ForegroundColor Cyan -NoNewline
        Write-Host $Subtitle -ForegroundColor DarkGray
    } else {
        Write-Host "   $Title" -ForegroundColor Cyan
    }
    Write-Host ("  " + ("-" * 70)) -ForegroundColor Cyan
}

function Write-ExakitHelpSection {
    param([string]$Title)
    Write-Host ""
    Write-Host "  $Title"
    Write-Host ""
}

function Write-ExakitHelpCommand {
    param([string]$Label, [string]$Summary, [int]$Pad = 26, [string]$Indent = "    ")
    if ($Label.Length -le $Pad -and $Summary) {
        Write-Host ($Indent + $Label.PadRight($Pad)) -ForegroundColor Green -NoNewline
        Write-Host " $Summary"
    } else {
        Write-Host "$Indent$Label" -ForegroundColor Green
        if ($Summary) { Write-ExakitHelpWrapped -Text $Summary -Indent ($Indent + "  ") }
    }
}

function Write-ExakitHelpSteps {
    param($Steps)
    $number = 1
    foreach ($step in $Steps) {
        Write-Host "    $number. $($step.step)"
        if ($step.run) { Write-Host "       $($step.run)" -ForegroundColor Cyan }
        if ($step.note) { Write-ExakitHelpWrapped -Text $step.note -Indent "       " }
        $number++
    }
}

function Show-ExakitHelpOverview {
    $docs = Get-ExakitHelpDocuments
    $doc = $docs["exakit"]
    if (-not $doc) { Write-Host "No help data found. Re-run the installer."; return 1 }
    Write-ExakitHelpHeader $doc.title $doc.tagline
    # Both optional, and the blank line belongs to the prose rather than to the
    # header: Write-ExakitHelpSection opens with its own blank, so emitting one
    # here for a document that has no role leaves two.
    # Mirrors render_overview in setup/lib/help.sh.
    if ($doc.role) {
        Write-Host ""
        Write-ExakitHelpWrapped -Text $doc.role -Indent "   "
    }
    if ($doc.quickstart) {
        Write-ExakitHelpSection "Start here"
        Write-ExakitHelpSteps $doc.quickstart
    }
    $byName = @{}
    foreach ($entry in $doc.commands) { $byName[$entry.command] = $entry }
    foreach ($group in $doc.groups) {
        Write-ExakitHelpSection $group.title
        foreach ($name in $group.commands) {
            $entry = $byName[$name]
            if (-not $entry) { continue }
            $label = Get-ExakitHelpInvocation -DocId "exakit" -Entry $entry -Doc $doc
            Write-ExakitHelpCommand -Label $label -Summary $entry.summary -Pad 24
        }
    }
    $others = @()
    foreach ($key in ($docs.Keys | Sort-Object)) { if ($key -ne "exakit") { $others += $key } }
    if ($others.Count -gt 0) {
        # Each component names its own commands as a reader would type them. A
        # bare list of component names told nobody what they could actually run.
        Write-ExakitHelpSection "Components"
        foreach ($key in $others) {
            $sub = $docs[$key]
            Write-Host "    $key" -NoNewline
            Write-Host "  $($sub.tagline)" -ForegroundColor DarkGray
            foreach ($entry in $sub.commands) {
                $text = $entry.summary
                if (-not $text) { $text = $entry.description }
                Write-ExakitHelpCommand -Indent "      " -Pad 34 -Summary $text `
                    -Label (Get-ExakitHelpInvocationWithOptions -DocId $key -Entry $entry -Doc $sub)
            }
            Write-Host ""
        }
    }
    Write-Host ""
    Write-Host "  More detail on any command or component: exakit <component / command> --help" -ForegroundColor DarkGray
    Write-Host ""
    return 0
}

function Show-ExakitHelpAll {
    $docs = Get-ExakitHelpDocuments
    $doc = $docs["exakit"]
    if (-not $doc) { return 1 }
    Write-ExakitHelpHeader "exakit - every command" $doc.tagline
    $byName = @{}
    foreach ($entry in $doc.commands) { $byName[$entry.command] = $entry }
    $seen = @{}
    foreach ($group in $doc.groups) {
        Write-ExakitHelpSection $group.title
        foreach ($name in $group.commands) {
            $entry = $byName[$name]
            if (-not $entry -or $seen[$name]) { continue }
            $seen[$name] = $true
            Write-ExakitHelpCommand -Pad 30 -Summary $entry.summary `
                -Label (Get-ExakitHelpInvocationWithOptions -DocId "exakit" -Entry $entry -Doc $doc)
        }
    }
    Write-Host ""
    Write-Host "  Detail for one command: exakit <command> --help" -ForegroundColor DarkGray
    Write-Host ""
    return 0
}

function Show-ExakitHelpComponent {
    param([string]$Id)
    $docs = Get-ExakitHelpDocuments -Primary $Id
    $doc = $docs[$Id]
    if (-not $doc) {
        Write-Host "  No help document for '$Id'."
        Write-Host ("  Known: " + (($docs.Keys | Sort-Object) -join ", "))
        return 1
    }
    Write-ExakitHelpHeader $doc.title $doc.tagline
    Write-Host ""
    Write-ExakitHelpWrapped -Text $doc.role -Indent "   "

    $facts = [ordered]@{
        "Repository" = $doc.repo; "Package" = $doc.package; "Binary" = $doc.binary
        "Runs via" = $doc.runs_via; "Image" = $doc.image; "Config" = $doc.config
        "Profile" = $doc.profile; "Venv" = $doc.venv; "Python" = $doc.python
        "URL" = $doc.url; "Control plane" = $doc.control_plane; "DSN" = $doc.dsn
        "Admin user" = $doc.admin_user; "DB user" = $doc.db_user
        "Deployment" = $doc.deployment_dir; "Platforms" = $doc.platforms
        "Requires" = $doc.requires; "Installed by" = $doc.installed_by; "Docs" = $doc.docs
    }
    $any = $false
    foreach ($key in $facts.Keys) { if ($facts[$key]) { $any = $true } }
    if ($any) {
        Write-ExakitHelpSection "At a glance"
        foreach ($key in $facts.Keys) {
            if (-not $facts[$key]) { continue }
            Write-Host ("    " + $key.PadRight(16)) -ForegroundColor Green -NoNewline
            Write-Host $facts[$key]
        }
    }
    if ($doc.warning) {
        Write-ExakitHelpSection "Important"
        Write-ExakitHelpWrapped -Text $doc.warning -Indent "    "
    }
    if ($doc.boundary) {
        Write-ExakitHelpSection "The read-only boundary"
        Write-ExakitHelpWrapped -Text $doc.boundary -Indent "    "
    }
    if ($doc.clients) {
        Write-ExakitHelpSection "Supported clients"
        Write-ExakitHelpWrapped -Text ($doc.clients -join ", ") -Indent "    "
    }
    if ($doc.quickstart) {
        Write-ExakitHelpSection "How to start"
        Write-ExakitHelpSteps $doc.quickstart
    }
    if ($doc.commands) {
        Write-ExakitHelpSection "Commands"
        foreach ($entry in $doc.commands) {
            $text = $entry.summary
            if (-not $text) { $text = $entry.description }
            Write-ExakitHelpCommand -Pad 34 -Summary $text `
                -Label (Get-ExakitHelpInvocationWithOptions -DocId $Id -Entry $entry -Doc $doc)
        }
    }
    if ($doc.environment) {
        Write-ExakitHelpSection "Environment"
        foreach ($item in $doc.environment) {
            Write-Host ("    " + $item.name.PadRight(26)) -ForegroundColor Green -NoNewline
            Write-Host ""
            Write-ExakitHelpWrapped -Text $item.effect -Indent "      "
        }
    }
    if ($doc.notes) {
        Write-ExakitHelpSection "Good to know"
        foreach ($note in $doc.notes) { Write-ExakitHelpWrapped -Text ("- " + $note) -Indent "      " -First "    " }
    }
    if ($doc.troubleshooting) {
        Write-ExakitHelpSection "If something goes wrong"
        foreach ($item in $doc.troubleshooting) {
            Write-Host "    $($item.symptom)"
            Write-ExakitHelpWrapped -Text $item.remedy -Indent "      "
        }
    }
    if ($doc.see_also) {
        Write-ExakitHelpSection "See also"
        Write-ExakitHelpWrapped -Text ($doc.see_also -join ", ") -Indent "    "
    }
    Write-Host ""
    return 0
}

function Get-ExakitHelpRows {
    $docs = Get-ExakitHelpDocuments
    $rows = @()
    $seen = @{}
    foreach ($key in ($docs.Keys | Sort-Object)) {
        $doc = $docs[$key]
        foreach ($entry in $doc.commands) {
            $tool = $key
            $command = $entry.command
            $parts = $command -split '\s+'
            if ($parts.Count -gt 1 -and @("exakit", "exapump", "exasol") -contains $parts[0] -and $key -ne $parts[0]) {
                $tool = $parts[0]
                $command = ($parts[1..($parts.Count - 1)] -join " ")
            }
            $text = $entry.summary
            if (-not $text) { $text = $entry.description }
            $dedupe = "$tool|$command|$($entry.options)"
            if ($seen[$dedupe]) { continue }
            $seen[$dedupe] = $true
            $rows += [pscustomobject]@{
                tool = $tool; command = $command; options = $entry.options
                description = $text; invocation = ("$tool $command").Trim()
            }
        }
    }
    return $rows
}

function Show-ExakitHelpCatalog {
    param([string]$Search)
    $rows = Get-ExakitHelpRows
    if ($Search) {
        $needle = $Search.ToLowerInvariant()
        $rows = @($rows | Where-Object {
            ("$($_.tool) $($_.command) $($_.options) $($_.description)").ToLowerInvariant().Contains($needle)
        })
    }
    if ($Search) {
        Write-ExakitHelpHeader "command catalog" "results for `"$Search`""
    } else {
        Write-ExakitHelpHeader "command catalog" "exakit - exapump - exasol - components"
    }
    if ($rows.Count -eq 0) {
        Write-Host ""
        Write-Host "  No commands match `"$Search`".  Try: exakit catalog mcp" -ForegroundColor DarkGray
        Write-Host ""
        return 1
    }
    $current = ""
    foreach ($row in $rows) {
        if ($row.tool -ne $current) {
            $current = $row.tool
            Write-ExakitHelpSection $current
        }
        $label = $row.command
        if ($row.options) { $label = "$($row.command) $($row.options)" }
        Write-ExakitHelpCommand -Label $label -Summary $row.description
    }
    Write-Host ""
    Write-Host "  Tip: exakit catalog <search>, or exakit <component> --help for the full page." -ForegroundColor DarkGray
    Write-Host ""
    return 0
}

function Show-ExakitHelpCommand {
    param([string]$Name)
    $docs = Get-ExakitHelpDocuments
    $needle = $Name.ToLowerInvariant()
    foreach ($key in (@("exakit") + ($docs.Keys | Sort-Object))) {
        if (-not $docs.ContainsKey($key)) { continue }
        foreach ($entry in $docs[$key].commands) {
            $command = $entry.command.ToLowerInvariant()
            if ($command -ne $needle -and -not $command.StartsWith("$needle ")) { continue }
            $label = $entry.command
            if ($key -eq "exakit") { $label = "exakit $($entry.command)" }
            Write-Host ""
            if ($entry.options) {
                Write-Host "  $label $($entry.options)"
            } else {
                Write-Host "  $label"
            }
            Write-Host ""
            $text = $entry.description
            if (-not $text) { $text = $entry.summary }
            Write-ExakitHelpWrapped -Text $text -Indent "    "
            if ($entry.warning) {
                Write-Host ""
                Write-ExakitHelpWrapped -Text ("! " + $entry.warning) -Indent "    "
            }
            if ($entry.examples) {
                Write-Host ""
                Write-Host "    Examples" -ForegroundColor DarkGray
                foreach ($example in $entry.examples) { Write-Host "      $example" -ForegroundColor Cyan }
            }
            Write-Host ""
            return 0
        }
    }
    if (Test-ExakitHelpId $Name) { return (Show-ExakitHelpComponent -Id $Name) }
    Write-Host ""
    Write-Host "  No help entry for '$Name'."
    Write-Host "  Try: exakit catalog $Name   or   exakit help --all"
    Write-Host ""
    return 1
}

function Show-ExakitHelpJson {
    param([string]$Which)
    $docs = Get-ExakitHelpDocuments
    $rows = Get-ExakitHelpRows
    if (-not $Which -or $Which -eq "all") {
        $payload = [ordered]@{ schema_version = 1; search = $null; count = $rows.Count; commands = $rows; documents = $docs }
    } elseif ($docs.ContainsKey($Which)) {
        $payload = $docs[$Which]
    } else {
        $needle = $Which.ToLowerInvariant()
        $hit = @($rows | Where-Object {
            ("$($_.tool) $($_.command) $($_.options) $($_.description)").ToLowerInvariant().Contains($needle)
        })
        $payload = [ordered]@{ schema_version = 1; search = $Which; count = $hit.Count; commands = $hit }
    }
    $payload | ConvertTo-Json -Depth 12
    return 0
}
