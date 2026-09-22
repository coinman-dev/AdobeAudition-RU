#Requires -Version 5.1
<#
.SYNOPSIS
    Готовит релиз: проверяет файлы перевода, пишет manifest.json и собирает
    out\release\<тег>\ — архив, manifest.json с описанием архива и Install-AuditionRU.ps1.
    Prepares a release: validates the translation files, writes manifest.json and builds
    out\release\<tag>\ - the package, a manifest.json describing it and Install-AuditionRU.ps1.

.EXAMPLE
    .\tools\New-Release.ps1 -Version 1.0.0
    gh release create v1.0.0 out\release\v1.0.0\* --title "v1.0.0" --notes-file CHANGELOG.md
#>
[CmdletBinding()]
param(
    # SemVer: 1.0.0 или предварительная версия 0.1.0-beta.
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+(-[0-9A-Za-z][0-9A-Za-z\.]*)?$')][string]$Version,
    # Сборка Audition, для которой сделан перевод (информационно).
    [string]$TranslatedFor = '26.5.0.82',
    # Минимальная версия Audition.
    [string]$MinAudition = '26.0'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$tag = "v$Version"

# Что входит в перевод и куда ставится (пути относительно папки Audition).
$files = @(
    @{ path = 'ru_RU/zdictionary_AUDT_ru_RU.dat'; type = 'dictionary'; target = 'dict/ru_RU/zdictionary_AUDT_ru_RU.dat'; baseline = 'dict/en_US/zdictionary_AUDT_en_US.dat' }
    @{ path = 'ru_RU/dva_ru_RU.dict';             type = 'dictionary'; target = 'dict/ru_RU/dva_ru_RU.dict';             baseline = 'dict/en_US/dva_en_US.dict' }
    @{ path = 'learn-panel/content/ru_ru/stringtable.txt';  type = 'learn-content';  target = 'CEP/extensions/com.adobe.audition.Onboarding/content/Content/C8C75B3C-05EF-4A2B-8FA9-DB1E1E7271CF/ru_ru/stringtable.txt' }
    @{ path = 'learn-panel/surfaces/ru_ru/stringtable.txt'; type = 'learn-surfaces'; target = 'CEP/extensions/com.adobe.audition.Onboarding/surfaces/ru_ru/stringtable.txt' }
)

$line = [regex]'^"(\$\$\$/[^=]*)=(.*)"$'
$entries = foreach ($f in $files) {
    $full = Join-Path $repo ($f.path -replace '/', '\')
    if (-not (Test-Path -LiteralPath $full)) { throw "Missing $($f.path)" }
    $bytes = [IO.File]::ReadAllBytes($full)
    if ($f.type -eq 'dictionary') {
        if ($bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) { throw "$($f.path): UTF-8 BOM expected" }
        $text = [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
        if ($text -match "[^\r]\n") { throw "$($f.path): CRLF line endings expected" }
        # Ключи Adobe различаются регистром (…NotSupported и …NotSUpported), поэтому Ordinal.
        $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $n = 0
        foreach ($l in ($text -split "`r`n")) {
            if (-not $l) { continue }
            $m = $line.Match($l)
            if (-not $m.Success) { throw "$($f.path): bad line $($n + 1): $l" }
            if (-not $keys.Add($m.Groups[1].Value)) { throw "$($f.path): duplicate key $($m.Groups[1].Value)" }
            $n++
        }
        Write-Host ("  {0,-45} {1,6} strings" -f $f.path, $n)
    }
    [ordered]@{
        path     = $f.path
        type     = $f.type
        target   = $f.target
        baseline = $f.baseline
        size     = $bytes.Length
        sha256   = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
    }
}

$manifest = [ordered]@{
    schema        = 1
    name          = 'AdobeAudition-RU'
    version       = $Version
    tag           = $tag
    language      = 'ru_RU'
    translatedFor = $TranslatedFor
    minAudition   = $MinAudition
    files         = @($entries)
}
$utf8 = New-Object Text.UTF8Encoding $false
[IO.File]::WriteAllText((Join-Path $repo 'manifest.json'), (($manifest | ConvertTo-Json -Depth 5) -replace "`r`n", "`n") + "`n", $utf8)
Write-Host "  manifest.json updated ($tag)"

# Архив: manifest.json + файлы перевода.
$out = Join-Path $repo "out\release\$tag"
Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
$null = New-Item -ItemType Directory -Force -Path $out
$stage = Join-Path $repo "out\stage-$tag"
Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
$null = New-Item -ItemType Directory -Force -Path $stage
Copy-Item -LiteralPath (Join-Path $repo 'manifest.json') -Destination $stage
foreach ($f in $files) {
    $dest = Join-Path $stage ($f.path -replace '/', '\')
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $dest)
    Copy-Item -LiteralPath (Join-Path $repo ($f.path -replace '/', '\')) -Destination $dest
}
$zipName = "AdobeAudition-RU-$Version.zip"
$zip = Join-Path $out $zipName
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
Remove-Item -LiteralPath $stage -Recurse -Force

# manifest.json релиза дополнительно описывает архив.
$manifest['package'] = [ordered]@{
    name   = $zipName
    size   = (Get-Item -LiteralPath $zip).Length
    sha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
}
[IO.File]::WriteAllText((Join-Path $out 'manifest.json'), (($manifest | ConvertTo-Json -Depth 5) -replace "`r`n", "`n") + "`n", $utf8)
Copy-Item -LiteralPath (Join-Path $repo 'Install-AuditionRU.ps1') -Destination $out

Write-Host ''
Write-Host "  Release files: $out"
Get-ChildItem -LiteralPath $out | ForEach-Object { Write-Host ("    {0,-32} {1,10:N0} bytes" -f $_.Name, $_.Length) }
Write-Host ''
Write-Host "  Publish:  gh release create $tag `"$out\*`" --title `"$tag`" --notes-file CHANGELOG.md"
