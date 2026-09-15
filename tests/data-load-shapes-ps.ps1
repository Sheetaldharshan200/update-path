#!/usr/bin/env pwsh
# data-load-shapes-ps.ps1 - behavioural tests for the Windows twin of the local
# data loader on the files people actually have: Windows line endings, a
# byte-order mark, ';'-separated German exports, a GTFS feed of .txt files, a
# header with no rows, a .geojson. Twin of the "real-world CSV shapes" section
# of tests/bulk-folder-load.sh.
#
# THE KIT IS A BRIDGE. It hands files to exapump and says what exapump says
# back; it does not rewrite them. That is measured at the binary's argv and at
# the bytes it receives: the ORIGINAL path, the ORIGINAL bytes (CR and BOM
# included), exapump's own --delimiter when the header calls for it, no upload
# at all for a file with nothing in it or a name exapump refuses by extension,
# and a failure reason that names the cause the inspector saw.
#
#   pwsh -NoProfile -File tests/data-load-shapes-ps.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/data-load-shapes-ps.ps1

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label = $actual" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected $expected, got $actual" }
}
function Has($label, $needle, $haystack) {
    if (("" + $haystack).Contains("" + $needle)) { $script:PASS++; Write-Host "  ok   $label = present" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected '$needle' in:`n$haystack" }
}
function Lacks($label, $needle, $haystack) {
    if (-not ("" + $haystack).Contains("" + $needle)) { $script:PASS++; Write-Host "  ok   $label = absent" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): did not expect '$needle' in:`n$haystack" }
}

# --- sandbox ----------------------------------------------------------------
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-shapes-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path (Join-Path $work "home") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $work "got") | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
$env:EXAKIT_LOG_FILE = Join-Path $work "test.log"
$got = Join-Path $work "got"
$env:SHAPES_GOT = $got

# A stub exapump that records argv and keeps a copy of the file it was handed,
# so the suite can prove it received the user's bytes and not a copy.
# $env:OS, not $IsWindows: the automatic variable does not exist on 5.1.
$onWindows = ($env:OS -like "*Windows*")
if ($onWindows) {
    $stub = Join-Path $work "exapump.cmd"
    Set-Content -Path $stub -Encoding Ascii -Value @(
        "@echo off",
        "echo %*>> `"%SHAPES_GOT%\argv`"",
        "if `"%~1`"==`"upload`" copy /y `"%~2`" `"%SHAPES_GOT%\received`" >nul",
        "exit /b 0"
    )
} else {
    $stub = Join-Path $work "exapump"
    Set-Content -Path $stub -Value @(
        "#!/bin/sh",
        "printf '%s\n' `"`$*`" >> `"`$SHAPES_GOT/argv`"",
        "[ `"`$1`" = upload ] && cp `"`$2`" `"`$SHAPES_GOT/received`"",
        "exit 0"
    )
    & chmod +x $stub
}
$env:EXAKIT_EXAPUMP_BIN = $stub

. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/exapump.ps1")
$script:ExakitUploadQuiet = $true

# --- fixtures: the shapes, byte for byte ------------------------------------
$shapes = Join-Path $work "shapes"; New-Item -ItemType Directory -Force -Path $shapes | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Put([string]$Name, [byte[]]$Bytes) { [System.IO.File]::WriteAllBytes((Join-Path $shapes $Name), $Bytes) }
Put "windows.csv" ([byte[]](0xEF, 0xBB, 0xBF) + $utf8.GetBytes("datum,gesamt`r`n2026.01.01,7`r`n"))   # BOM + CRLF
Put "german.csv"  ($utf8.GetBytes("Row;LAT;NAME`n1;48,17;Zentrale`n"))                               # ';' with decimal commas
Put "tabs.tsv"    ($utf8.GetBytes("a`tb`n1`t2`n"))                                                    # .tsv - exapump refuses the name
Put "stops.txt"   ($utf8.GetBytes("stop_id,stop_name`n1,Ostbahnhof`n"))                               # GTFS - same
Put "shapes.csv"  ($utf8.GetBytes("shape_id,shape_pt_lat`n"))                                         # a header with nothing under it
Put "plain.csv"   ($utf8.GetBytes("a,b`n1,2`n"))
Put "README.txt"  ($utf8.GetBytes("just some notes`nabout the exports`n"))
Put "areas.geojson" ($utf8.GetBytes('{"type":"FeatureCollection","features":[]}' + "`n"))

Write-Host ""
Write-Host "== the inspector looks, and does not touch =="
$look = Get-ExakitCsvInspection -Path (Join-Path $shapes "plain.csv")
Check "a plain file: comma, no flags" ",|" ("{0}|{1}" -f $look.Delimiter, $look.Flags)
$look = Get-ExakitCsvInspection -Path (Join-Path $shapes "windows.csv")
Check "a BOM+CRLF file is seen for what it is" ",|bom,crlf" ("{0}|{1}" -f $look.Delimiter, $look.Flags)
Check "...and is not header-only" $false $look.HeaderOnly
$look = Get-ExakitCsvInspection -Path (Join-Path $shapes "german.csv")
Check "a ';' header selects the semicolon" ";" $look.Delimiter
$look = Get-ExakitCsvInspection -Path (Join-Path $shapes "tabs.tsv")
Check "a tab header selects the tab" "`t" $look.Delimiter
$look = Get-ExakitCsvInspection -Path (Join-Path $shapes "shapes.csv")
Check "a header with no rows is named as such" $true $look.HeaderOnly
$before = [System.IO.File]::ReadAllBytes((Join-Path $shapes "windows.csv"))
Check "...and the file is byte-for-byte what it was" 3 ($before.Length - $utf8.GetBytes("datum,gesamt`r`n2026.01.01,7`r`n").Length)

Write-Host ""
Write-Host "== through the real uploader, into the stub binary =="
Set-Content -Path (Join-Path $got "argv") -Value "" -NoNewline
$said = & { Invoke-ExapumpUpload -Path (Join-Path $shapes "windows.csv") -Target "T.WINDOWS" } 6>&1
$rc = @($said | Where-Object { $_ -is [bool] })[0]
Check "the upload is reported as it went" $true $rc
Has "a CRLF file that loads is told what its last column now holds" "every value in the last column of T.WINDOWS ends in a carriage return" ($said -join "`n")
$argv = Get-Content (Join-Path $got "argv") -Raw
Has "exapump is handed the ORIGINAL path" ("upload " + (Join-Path $shapes "windows.csv")) $argv
Lacks "...with no delimiter flag for a comma file" "--delimiter" $argv
$received = [System.IO.File]::ReadAllBytes((Join-Path $got "received"))
Check "...and the original bytes, CR and BOM included - no copy" ([Convert]::ToBase64String($before)) ([Convert]::ToBase64String($received))
$saidPlain = & { Invoke-ExapumpUpload -Path (Join-Path $shapes "plain.csv") -Target "T.PLAIN" } 6>&1
Lacks "...and a clean file is not" "carriage return" ($saidPlain -join "`n")
$rc = Invoke-ExapumpUpload -Path (Join-Path $shapes "german.csv") -Target "T.GERMAN" 6>$null
$argv = Get-Content (Join-Path $got "argv") -Raw
Has "a ';' file is uploaded with exapump's own --delimiter ;" "--delimiter ;" $argv
Set-Content -Path (Join-Path $got "argv") -Value "" -NoNewline
$said = & { Invoke-ExapumpUpload -Path (Join-Path $shapes "shapes.csv") -Target "T.SHAPES" -Soft } 6>&1
$rc = @($said | Where-Object { $_ -is [bool] })[0]
Has "a header-only file is named, not sent to the engine" "has a header and no rows" ($said -join "`n")
Check "...as a failure" $false $rc
Lacks "...that never reached exapump" "shapes.csv" (Get-Content (Join-Path $got "argv") -Raw)
Check "no temporary copy of anything exists" 0 @(Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter "exakit-csv*" -ErrorAction SilentlyContinue).Count

Write-Host ""
Write-Host "== the folder scan sees the same things, and says them =="
$plan = @(Get-ExakitBulkFolderPlan -Path $shapes)
$planText = $plan -join "`n"
Has "a tabular .txt is recognised as data" ("skip|extension||" + (Join-Path $shapes "stops.txt")) $planText
Has "...and so is a .tsv" ("skip|extension||" + (Join-Path $shapes "tabs.tsv")) $planText
Has "a README.txt is not" ("skip|unsupported||" + (Join-Path $shapes "README.txt")) $planText
Has "a header-only file is skipped by name" ("skip|header-only||" + (Join-Path $shapes "shapes.csv")) $planText
Lacks "nothing exapump refuses by name is queued for it" "load|csv|STOPS|" $planText
# The Windows scan lists a folder's JSON files as skipped (help text says so);
# what matters here is that .geojson lands among THEM, not among "other kinds".
Has ".geojson is JSON in a folder scan" ("skip|json-unsupported||" + (Join-Path $shapes "areas.geojson")) $planText
Lacks "...and not a file of another kind" ("skip|unsupported||" + (Join-Path $shapes "areas.geojson")) $planText
Check ".geojson is JSON" "json" (Get-ExakitDataFileKind (Join-Path $shapes "areas.geojson"))
$chosen = @($plan | Where-Object { $_.StartsWith("load|") } | ForEach-Object { $_.Substring(5) })
$shown = (& { Show-ExakitBulkPlan -Plan $plan -Chosen $chosen -Schema "S" -Path $shapes } 6>&1) -join "`n"
Has "the plan tells the user the one thing that loads them" "rename to .csv to load" $shown
Has "...and counts the header-only file in words" "with a header and no rows" $shown

Write-Host ""
Write-Host "== the engine's reason survives to the screen, whole, with the cause the kit saw =="
$cr = @("Error: SQL execution failed: Protocol error: ETL-3051: [Column=11 Row=0] [Transformation of value='7.4<CR>' failed - invalid character value for cast; Value: '7.4'] (Session: 1876)")
Has "a <CR> in the engine's message is translated" "Windows line endings (CRLF)" (Get-ExakitUploadFailureReason -Output $cr)
$etl = @("Error: SQL execution failed: Protocol error: ETL-3050: [Column=6 Row=0] [Transformation of value='x' failed - invalid character value for cast; Value: 'x'] (Session: 1876)")
$script:ExakitCsvFlags = ""
$reason = Get-ExakitUploadFailureReason -Output $etl
Has "an ETL detail in brackets is kept, not cut at the bracket" "ETL-3050: [Column=6 Row=0] [Transformation of value='x' failed" $reason
Lacks "...and the session id is dropped" "Session" $reason
Lacks "...and a clean file gets no invented cause" "Windows line endings" $reason
$script:ExakitCsvFlags = "bom,crlf"
Has "...but a file the inspector flagged as CRLF gets the cause appended" "Windows line endings (CRLF)" (Get-ExakitUploadFailureReason -Output $etl)
$script:ExakitCsvFlags = ""
$long = @("Error: SQL execution failed: Protocol error: ETL-2105: Error while parsing row=0 (starting from 0) [CSV Parser found at byte 5385 (starting with 0 at the beginning of the row) of 5385 a single field delimiter or a row terminator directly after a quoted field] (Session: 1)")
$cut = Get-ExakitUploadFailureReason -Output $long
Has "a long detail is cut at a word, with an ellipsis" "field..." $cut
Lacks "...never mid-word" "delimi" $cut

Write-Host ""
Write-Host "== a folder holding only what exapump refuses by name: a GTFS feed, as shipped =="
$gtfs = Join-Path $work "gtfs"; New-Item -ItemType Directory -Force -Path $gtfs | Out-Null
[System.IO.File]::WriteAllBytes((Join-Path $gtfs "stops.txt"), $utf8.GetBytes("stop_id,stop_name`n1,Ostbahnhof`n"))
[System.IO.File]::WriteAllBytes((Join-Path $gtfs "routes.txt"), $utf8.GetBytes("route_id,route_short_name`n1,U1`n"))
$gt = & { Import-ExakitLocalFolder -Path $gtfs } 6>&1
$gtText = ($gt | ForEach-Object { "$_" }) -join "`n"
Has "a folder of .txt tables is not 'no files'" "2 files in" $gtText
Has "...it names the rename that loads them" "Rename them to .csv" $gtText
Lacks "...and does not call it empty" "No CSV or Parquet files" $gtText
Has "...and fails, as before" "failed" $gtText

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "data-load-shapes-ps.ps1: $($script:PASS) passed, $($script:FAIL) failed"
if ($script:FAIL -gt 0) { exit 1 }
