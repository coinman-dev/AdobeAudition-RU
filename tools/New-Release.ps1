#Requires -Version 5.1
<#
.SYNOPSIS
    Готовит релиз: проверяет файлы перевода, пишет manifest.json и собирает
    out\release\<тег>\ — архив, manifest.json с описанием архива и Install-AuditionRU.ps1
    (ASCII-копия исходника: так она работает через «irm | iex» и в Windows PowerShell 5.1).
    Prepares a release: validates the translation files, writes manifest.json and builds
    out\release\<tag>\ - the package, a manifest.json describing it and Install-AuditionRU.ps1
    (an ASCII copy of the source, so that "irm | iex" works in Windows PowerShell 5.1 too).

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

# Копия установщика для релиза — только ASCII. Windows PowerShell 5.1 читает ответ «irm» без
# charset (так отдаёт GitHub Releases) как Latin-1, а PowerShell 7.4 — как UTF-8, и BOM ни тот,
# ни другой не пропускает: «<#» после него уже не комментарий, param() не первый. Файл без BOM
# с кириллицей тоже нельзя: при запуске файлом Windows PowerShell читает его в кодировке ANSI.
# Поэтому текст вне ASCII в строках пишется кодами символов, русские комментарии не попадают.
function Get-CharCodes {
    param([string]$Run)
    '$(-join [char[]](' + ((@($Run.ToCharArray()) | ForEach-Object { '0x{0:X4}' -f [int]$_ }) -join ',') + '))'
}

function ConvertTo-AsciiScript {
    param([string]$Text)
    $nonAscii = [regex]'[^\x00-\x7F]+'
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Install-AuditionRU.ps1, line $($errors[0].Extent.StartLineNumber): $($errors[0].Message)" }
    $sb = New-Object Text.StringBuilder $Text
    # С конца файла: смещения ещё не обработанных токенов не сдвигаются.
    $todo = @($tokens | Where-Object { $nonAscii.IsMatch($_.Text) } | Sort-Object { $_.Extent.StartOffset } -Descending)
    foreach ($t in $todo) {
        $start = $t.Extent.StartOffset; $end = $t.Extent.EndOffset; $at = "line $($t.Extent.StartLineNumber)"
        if ($t.Kind -eq 'Comment' -and $t.Text.StartsWith('<#')) {
            $lines = $t.Text -split "`r?`n"
            if ($nonAscii.IsMatch($lines[0]) -or $nonAscii.IsMatch($lines[-1])) { throw "${at}: non-ASCII text on the first or last line of a block comment" }
            $kept = (@($lines | Where-Object { -not $nonAscii.IsMatch($_) }) -join "`r`n") -replace '\r\n(?:[ \t]*\r\n){2,}', "`r`n`r`n"
            $kept = $kept -replace '(?m)^(\.[A-Z]+\b[^\r\n]*)\r\n(?:[ \t]*\r\n)+', "`$1`r`n"
            [void]$sb.Remove($start, $end - $start).Insert($start, $kept)
        } elseif ($t.Kind -eq 'Comment') {
            $text = $sb.ToString()
            $lineStart = if ($start -gt 0) { $text.LastIndexOf([char]10, $start - 1) + 1 } else { 0 }
            if ($text.Substring($lineStart, $start - $lineStart).Trim()) {
                # Комментарий после кода: убираем его и пробелы перед ним.
                $from = $start
                while ($from -gt $lineStart -and ' ', "`t" -contains $text[$from - 1]) { $from-- }
                [void]$sb.Remove($from, $end - $from)
            } else {
                $nl = $text.IndexOf([char]10, $end)
                $to = if ($nl -ge 0) { $nl + 1 } else { $end }
                [void]$sb.Remove($lineStart, $to - $lineStart)
            }
        } elseif ($t.Kind -eq 'StringLiteral') {
            # 'текст' → "текст" с экранированием и кодами символов.
            $body = $t.Value -replace '([`"$])', '`$1'
            $body = $nonAscii.Replace($body, { param($m) Get-CharCodes $m.Value })
            [void]$sb.Remove($start, $end - $start).Insert($start, '"' + $body + '"')
        } elseif ($t.Kind -eq 'StringExpandable') {
            if ($nonAscii.IsMatch($t.Text.Substring(0, 1)) -or $nonAscii.IsMatch($t.Text.Substring($t.Text.Length - 1))) { throw "${at}: typographic quotes delimit a string" }
            if (@($t.NestedTokens | Where-Object { $nonAscii.IsMatch($_.Text) }).Count) { throw "${at}: non-ASCII text inside `$(...) or a variable of an expandable string" }
            if ($t.Text -match '`[^\x00-\x7F]') { throw "${at}: an escaped non-ASCII character" }
            $body = $nonAscii.Replace($t.Text, { param($m) Get-CharCodes $m.Value })
            [void]$sb.Remove($start, $end - $start).Insert($start, $body)
        } else {
            throw "${at}: non-ASCII text in a $($t.Kind) token is not supported"
        }
    }
    $result = $sb.ToString()

    # Проверка: только ASCII, разбирается, и код тот же — кроме комментариев и записи строк.
    if ($nonAscii.IsMatch($result)) { throw 'The ASCII copy still contains non-ASCII characters' }
    $newTokens = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($result, [ref]$newTokens, [ref]$errors)
    if ($errors.Count) { throw "The ASCII copy does not parse, line $($errors[0].Extent.StartLineNumber): $($errors[0].Message)" }
    $code = {
        param($List)
        $prev = $null
        foreach ($x in $List) {
            if ($x.Kind -eq 'Comment' -or ($x.Kind -eq 'NewLine' -and $prev -eq 'NewLine')) { continue }
            $prev = $x.Kind; $x
        }
    }
    $a = @(& $code $tokens); $b = @(& $code $newTokens)
    if ($a.Count -ne $b.Count) { throw "The ASCII copy has $($b.Count) code tokens instead of $($a.Count)" }
    $decode = [regex]'\$\(-join \[char\[\]\]\(((?:0x[0-9A-F]{4},?)+)\)\)'
    for ($i = 0; $i -lt $a.Count; $i++) {
        $x = $a[$i]; $y = $b[$i]
        if ($x.Text -ceq $y.Text -and $x.Kind -eq $y.Kind) { continue }
        $same = if ($x.Kind -eq 'StringLiteral' -and $y.Kind -eq 'StringExpandable') {
            # Кроме кодов символов, в строке нет «$»: её значение можно вычислить.
            ($decode.Replace($y.Text, '') -replace '`.', '') -notmatch '\$' -and
                ([scriptblock]::Create($y.Text).InvokeReturnAsIs() -ceq $x.Value)
        } elseif ($x.Kind -eq 'StringExpandable' -and $y.Kind -eq 'StringExpandable') {
            $decode.Replace($y.Text, { param($m) -join @($m.Groups[1].Value -split ',' | ForEach-Object { [char][Convert]::ToInt32($_, 16) }) }) -ceq $x.Text
        } else { $false }
        if (-not $same) { throw "The ASCII copy differs from the source at line $($x.Extent.StartLineNumber): $($x.Text)" }
    }
    $result
}

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

# Установщик: ASCII-копия с пометкой, из какого исходника собрана (тесты сверяют хеш).
$installer = Join-Path $repo 'Install-AuditionRU.ps1'
$ib = [IO.File]::ReadAllBytes($installer)
if ($ib[0] -ne 0xEF -or $ib[1] -ne 0xBB -or $ib[2] -ne 0xBF) { throw 'Install-AuditionRU.ps1: UTF-8 BOM expected' }
$source = [Text.Encoding]::UTF8.GetString($ib, 3, $ib.Length - 3)
if ($source -notmatch "\`$script:Repo\s*=\s*'([^']+)'") { throw 'Install-AuditionRU.ps1: $script:Repo not found' }
$note = @(
    "# Release copy of Install-AuditionRU.ps1 (source SHA256 $((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash))."
    '# Plain ASCII, so that "irm ... | iex" also works in Windows PowerShell 5.1: text in other'
    '# alphabets is written as character codes, Russian comments are left out. Readable source:'
    "# https://github.com/$($Matches[1])/blob/$tag/Install-AuditionRU.ps1"
    ''
) -join "`r`n"
$ascii = ConvertTo-AsciiScript $source
$requires = [regex]::Match($ascii, '(?m)^#Requires ')
if (-not $requires.Success) { throw 'Install-AuditionRU.ps1: #Requires line not found' }
[IO.File]::WriteAllText((Join-Path $out 'Install-AuditionRU.ps1'), $ascii.Insert($requires.Index, $note + "`r`n"), [Text.Encoding]::ASCII)

Write-Host ''
Write-Host "  Release files: $out"
Get-ChildItem -LiteralPath $out | ForEach-Object { Write-Host ("    {0,-32} {1,10:N0} bytes" -f $_.Name, $_.Length) }
Write-Host ''
Write-Host "  Publish:  gh release create $tag `"$out\*`" --title `"$tag`" --notes-file CHANGELOG.md"
