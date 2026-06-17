# ===========================================================================
# ArcUI packaging script - builds a clean CurseForge-ready zip.
#
# Produces  <Downloads>\ArcUI-<version>.zip  with the addon folder ("ArcUI\")
# at the root and ALL dev files stripped (.git, .claude, CLAUDE.md, this script,
# .pkgmeta). No more hand-deleting files before you upload.
#
# Run (from anywhere):
#   powershell -ExecutionPolicy Bypass -File "package.ps1"
# or right-click the file -> Run with PowerShell.
# ===========================================================================

$ErrorActionPreference = 'Stop'

$AddonName = 'ArcUI'
$AddonRoot = $PSScriptRoot          # this script lives in the addon root

# Read the version from the .toc so the zip is named ArcUI-<version>.zip
$version = (Get-Content (Join-Path $AddonRoot 'ArcUI.toc') |
            Where-Object { $_ -match '^##\s*Version:\s*(.+?)\s*$' } |
            ForEach-Object { $Matches[1] } | Select-Object -First 1)
if (-not $version) { $version = 'dev' }

# Files / folders kept OUT of the package (keep in sync with .pkgmeta).
$exclude = @('.git', '.github', '.gitignore', '.gitattributes',
             '.claude', 'CLAUDE.md', '.pkgmeta', 'package.ps1')

# Stage into <temp>\ArcUIbuild\ArcUI\ so the zip root is the addon folder.
$build = Join-Path $env:TEMP 'ArcUIbuild'
if (Test-Path $build) { Remove-Item $build -Recurse -Force }
$stage = Join-Path $build $AddonName
New-Item -ItemType Directory -Path $stage -Force | Out-Null

Get-ChildItem -Path $AddonRoot -Force |
    Where-Object { ($exclude -notcontains $_.Name) -and ($_.Name -notlike 'CHANGELOG_*.md') } |
    ForEach-Object { Copy-Item $_.FullName -Destination (Join-Path $stage $_.Name) -Recurse -Force }

# Write the zip to a dedicated releases folder as ArcUI-<version>.zip. Only the
# FILE name carries the version — the FOLDER inside stays exactly "ArcUI" so WoW
# finds ArcUI\ArcUI.toc and SavedVariables (ArcUI.lua) keep matching across
# updates. Each release accumulates here as its own versioned zip.
$outDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'ArcUI Releases'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$zip = Join-Path $outDir ("{0}-{1}.zip" -f $AddonName, $version)
if (Test-Path $zip) { Remove-Item $zip -Force }

# Build the zip with FORWARD-SLASH entry names (the ZIP standard, matching a
# Windows right-click "Compress to ZIP"). Both Compress-Archive AND .NET
# Framework's CreateFromDirectory write BACKslashes on Windows PowerShell 5.1, so
# we add each file by hand and normalize the separators. Entries are rooted at
# "ArcUI/" (relative to the temp build dir, whose only child is the ArcUI folder).
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$fs = [System.IO.File]::Create($zip)
$archive = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
foreach ($f in (Get-ChildItem -Path $build -Recurse -File -Force)) {
    $entryName = $f.FullName.Substring($build.Length + 1) -replace '\\', '/'
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $archive, $f.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
}
$archive.Dispose()
$fs.Dispose()
Remove-Item $build -Recurse -Force

Write-Host ""
Write-Host "  Packaged $AddonName $version" -ForegroundColor Green
Write-Host "  -> $zip" -ForegroundColor Green
Write-Host "  (zip root is '$AddonName', dev files excluded - ready to upload)" -ForegroundColor DarkGray
Write-Host ""
