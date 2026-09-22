#Requires -Version 5.1
# Проверки Install-AuditionRU.ps1 без прав администратора и без изменений в системе:
# функции берутся из скрипта через AST, установка/переключение/удаление выполняются
# на копии папки Audition во временном каталоге (tmp\), реестр и сеть заменены заглушками.
# Для проверок с DLL нужен установленный Adobe Audition 2026 (иначе они пропускаются).
[CmdletBinding()]
param([string]$AuditionPath = 'C:\Program Files\Adobe\Adobe Audition 2026')
$ErrorActionPreference = 'Stop'
$auditionDir = $AuditionPath
$root = Split-Path $PSScriptRoot -Parent
$script:checks = 0
$script:skipped = 0
function Assert([bool]$Value, [string]$Message) { if (-not $Value) { throw "FAIL: $Message" }; $script:checks++ }
function Assert-Throws([scriptblock]$Action, [string]$Message) { $failed = $false; try { & $Action | Out-Null } catch { $failed = $true }; Assert $failed $Message }
function Skip([string]$Message) { Write-Host "  SKIP: $Message" -ForegroundColor Yellow; $script:skipped++ }

$scriptPath = Join-Path $root 'Install-AuditionRU.ps1'
$bytes = [IO.File]::ReadAllBytes($scriptPath)
Assert ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'Install-AuditionRU.ps1 has a UTF-8 BOM (Windows PowerShell 5.1 reads Cyrillic correctly)'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
Assert (-not $errors.Count) 'Install-AuditionRU.ps1 parses without errors'
# GitHub raw/Release отдаёт файл с LF — скрипт должен разбираться и так.
$lf = [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3).Replace("`r`n", "`n")
$null = [Management.Automation.Language.Parser]::ParseInput($lf, [ref]$tokens, [ref]$errors)
Assert (-not $errors.Count) 'The script also parses with LF line endings (GitHub download)'
Assert (-not ($lf -match '(?m)^\s*exit\s+\d')) 'No unconditional exit: "irm | iex" must not close the user window'

# Функции и переменные $script:* — в текущую область.
foreach ($node in $ast.EndBlock.Statements) {
    if ($node -is [Management.Automation.Language.FunctionDefinitionAst]) { . ([scriptblock]::Create($node.Extent.Text)) }
    elseif ($node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -like '$script:*') { . ([scriptblock]::Create($node.Extent.Text)) }
}
$script:Lang = 'en'
$tmp = Join-Path $root ('tmp\test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $tmp
$script:CacheRoot = Join-Path $tmp 'cache'
$Yes = $true; $Source = $null; $Release = 'latest'; $LearnPanel = $false; $NoPause = $true; $AuditionPath = $null
function Set-PlayerDebugMode { param($Install, $State, [switch]$Undo) $script:pdm += @(if ($Undo) { 'undo' } else { 'set' }) }
$script:pdm = @()

try {
    # --- Словари -------------------------------------------------------------------------
    $en = Join-Path $tmp 'en.dat'; $ru = Join-Path $tmp 'ru.dat'; $out = Join-Path $tmp 'out.dat'
    [IO.File]::WriteAllText($en, "`"`$`$`$/A/One=One`"`r`n`"`$`$`$/A/Case=Lower`"`r`n`"`$`$`$/A/CASE=Upper`"`r`n`"`$`$`$/A/New=New string`"`r`n", (New-Object Text.UTF8Encoding $true))
    [IO.File]::WriteAllText($ru, "`"`$`$`$/A/CASE=Верхний`"`r`n`"`$`$`$/A/One=Один \`"кавычки\`"`"`r`n`"`$`$`$/A/Old=Старая`"`r`n`"`$`$`$/A/Case=Нижний`"`r`n", (New-Object Text.UTF8Encoding $true))
    $stat = Merge-ZDictionary -EnglishPath $en -RussianPath $ru -OutPath $out
    $merged = [IO.File]::ReadAllBytes($out)
    $mergedText = [Text.Encoding]::UTF8.GetString($merged, 3, $merged.Length - 3)
    Assert ($merged[0] -eq 0xEF -and $merged[1] -eq 0xBB -and $merged[2] -eq 0xBF) 'Merged dictionary has a UTF-8 BOM'
    Assert ($mergedText -eq "`"`$`$`$/A/One=Один \`"кавычки\`"`"`r`n`"`$`$`$/A/Case=Нижний`"`r`n`"`$`$`$/A/CASE=Верхний`"`r`n`"`$`$`$/A/New=New string`"`r`n`"`$`$`$/A/Old=Старая`"`r`n") 'Merge keeps the English key order, case-sensitive keys, escaped quotes, English fallback and appends translation-only keys'
    Assert ($stat.Total -eq 4 -and $stat.Translated -eq 3 -and $stat.Extra -eq 1) 'Merge statistics: 3 of 4 translated, 1 translation-only key'
    $repoDict = Read-ZDictionary (Join-Path $root 'ru_RU\zdictionary_AUDT_ru_RU.dat')
    Assert ($repoDict.Order.Count -eq 14991 -and $repoDict.Map.ContainsKey('$$$/ngl/mainmenu/help/sign_in')) 'The Audition dictionary has 14988 strings plus 3 licensing menu strings'
    $repoDva = Read-ZDictionary (Join-Path $root 'ru_RU\dva_ru_RU.dict')
    Assert ($repoDva.Order.Count -eq 7686) 'The DVA dictionary in the repository has 7686 strings'

    # --- AMT\application.xml ---------------------------------------------------------------
    $amtDir = Join-Path $tmp 'amt'; $null = New-Item -ItemType Directory -Force -Path (Join-Path $amtDir 'AMT')
    $xml = "<?xml version=`"1.0`" encoding=`"utf-8`"?>`n<Configuration>`n`t<Payload>`n`t`t<Data key=`"SAPCode`">AUDT</Data><Data key=`"installedLanguages`">en_US</Data></Payload>`n</Configuration>"
    $xmlPath = Join-Path $amtDir 'AMT\application.xml'
    [IO.File]::WriteAllText($xmlPath, $xml, (New-Object Text.UTF8Encoding $false))
    Assert ((Get-AmtLanguage $amtDir) -eq 'en_US') 'installedLanguages is read'
    Set-AmtLanguage -Dir $amtDir -Locale 'ru_RU'
    $after = [IO.File]::ReadAllBytes($xmlPath)
    Assert ($after[0] -eq 0x3C) 'application.xml stays without a BOM'
    Assert ([Text.Encoding]::UTF8.GetString($after) -eq $xml.Replace('>en_US<', '>ru_RU<')) 'Only the installedLanguages value changes (LF and layout preserved)'
    [IO.File]::WriteAllText($xmlPath, $xml.Replace('<Data key="installedLanguages">en_US</Data>', ''), (New-Object Text.UTF8Encoding $false))
    Set-AmtLanguage -Dir $amtDir -Locale 'de_DE'
    Assert ((Get-AmtLanguage $amtDir) -eq 'de_DE') 'A missing installedLanguages entry is added to Payload'
    Assert-Throws { Set-AmtLanguage -Dir $amtDir -Locale 'ru-RU; x' } 'Invalid language codes are rejected'

    # --- manifest.json и проверка файлов ---------------------------------------------------
    $m = Read-Manifest (Join-Path $root 'manifest.json')
    Assert ($m.version -and @($m.files).Count -eq 4) 'The repository manifest lists 4 files'
    Assert (Test-Payload $root $m) 'Repository files match manifest.json (size and SHA256)'
    $bad = Join-Path $tmp 'badpayload'; Copy-Item -LiteralPath (Join-Path $root 'ru_RU') -Destination (Join-Path $bad 'ru_RU') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $root 'learn-panel') -Destination (Join-Path $bad 'learn-panel') -Recurse -Force
    Assert (Test-Payload $bad $m) 'A full copy verifies'
    $f = Join-Path $bad 'ru_RU\dva_ru_RU.dict'; $b = [IO.File]::ReadAllBytes($f); $b[100] = $b[100] -bxor 1; [IO.File]::WriteAllBytes($f, $b)
    Assert (-not (Test-Payload $bad $m)) 'One changed byte is detected by SHA256'
    $keys = @('0.1.0-beta', '0.1.0', '0.1.1-beta', '1.0.0', '0.10.0') | ForEach-Object { [pscustomobject]@{ V = $_; K = Get-VersionKey $_ } }
    Assert ((@($keys | Sort-Object K | ForEach-Object V) -join ' ') -eq '0.1.0-beta 0.1.0 0.1.1-beta 0.10.0 1.0.0') 'SemVer order: a beta is older than its release, 0.10 is newer than 0.1'
    Assert ($null -eq (Get-VersionKey 'v1')) 'Invalid version strings are not accepted'
    $evil = Join-Path $tmp 'evil.json'
    [IO.File]::WriteAllText($evil, ((Get-Content -Raw (Join-Path $root 'manifest.json')) -replace '"dict/ru_RU/dva_ru_RU.dict"', '"../../Windows/evil.dll"'))
    Assert-Throws { Read-Manifest $evil } 'Manifest paths that leave the Audition folder are rejected'

    # --- Загрузка релиза: сеть заменена копированием из out\release -------------------------
    $release = Join-Path $root "out\release\v$($m.version)"
    if (Test-Path -LiteralPath (Join-Path $release 'manifest.json')) {
        $script:downloads = @()
        function Save-Url { param([string]$Url, [string]$Destination) $script:downloads += $Url; Copy-Item -LiteralPath (Join-Path $release ($Url -replace '^.*/', '')) -Destination $Destination -Force }
        $p1 = Get-Payload
        Assert ($script:downloads.Count -eq 2 -and $script:downloads[1] -match "/releases/download/v$([regex]::Escape($m.version))/AdobeAudition-RU-") 'First run downloads manifest.json and the package from the release tag'
        Assert (Test-Payload $p1.Dir $p1.Manifest) 'The downloaded package is unpacked and verified'
        $script:downloads = @()
        $p2 = Get-Payload
        Assert ($script:downloads.Count -eq 1 -and $p2.Dir -eq $p1.Dir) 'Second run only checks manifest.json and installs from the verified cache'
        $cf = Join-Path $p1.Dir 'ru_RU\dva_ru_RU.dict'; $b = [IO.File]::ReadAllBytes($cf); $b[10] = $b[10] -bxor 1; [IO.File]::WriteAllBytes($cf, $b)
        $script:downloads = @()
        $p3 = Get-Payload
        Assert ($script:downloads.Count -eq 1 -and (Test-Payload $p3.Dir $p3.Manifest)) 'A damaged cache is rebuilt from the verified package without downloading it again'
        function Save-Url { param([string]$Url, [string]$Destination) throw 'offline' }
        $p4 = Get-Payload
        Assert ($p4 -and (Test-Payload $p4.Dir $p4.Manifest)) 'Without network the newest verified cache is used'
        $zipPath = Join-Path $script:CacheRoot "AdobeAudition-RU-$($m.version).zip"
        $zb = [IO.File]::ReadAllBytes($zipPath); $zb[200] = $zb[200] -bxor 1; [IO.File]::WriteAllBytes($zipPath, $zb)
        Remove-Item -LiteralPath $p1.Dir -Recurse -Force
        function Save-Url { param([string]$Url, [string]$Destination) if ($Url -like '*manifest.json') { Copy-Item -LiteralPath (Join-Path $release 'manifest.json') -Destination $Destination -Force } else { $b = [IO.File]::ReadAllBytes((Join-Path $release ($Url -replace '^.*/', ''))); $b[200] = $b[200] -bxor 1; [IO.File]::WriteAllBytes($Destination, $b) } }
        Assert-Throws { Get-Payload } 'A corrupt downloaded package is rejected'
        Remove-Item Function:\Save-Url
    } else { Skip 'out\release is missing - run tools\New-Release.ps1 first' }

    # --- Исправление AuApplication.dll и полный цикл на копии Audition ----------------------
    $original = @((Join-Path $auditionDir 'AdobeAudition-RU\backup\AuApplication.dll'), (Join-Path $auditionDir 'AuApplication.dll.orig_ru'), (Join-Path $auditionDir 'AuApplication.dll')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($original) {
        $dll = [IO.File]::ReadAllBytes($original)
        $hit = Find-LocalePatch $dll
        if ($hit.State -eq 'Patched') { Set-LocalePatch $dll $hit -Undo; $hit = Find-LocalePatch $dll }
        Assert ($hit.State -eq 'Original') 'The patch location is found in the original AuApplication.dll'
        $origHash = Get-BytesSha256 $dll
        Set-LocalePatch $dll $hit
        Assert ((Find-LocalePatch $dll).State -eq 'Patched') 'After patching the location is recognised as patched'
        $diff = 0; $o = [IO.File]::ReadAllBytes($original); if ((Get-BytesSha256 $o) -ne $origHash) { $o = [byte[]]$dll.Clone(); Set-LocalePatch $o $hit -Undo }
        for ($i = 0; $i -lt $dll.Length; $i++) { if ($dll[$i] -ne $o[$i]) { $diff++ } }
        Assert ($diff -eq 2) 'Exactly 2 bytes differ between the original and patched DLL'
        $info = Get-AuditionInfo -Dir $auditionDir
        if ($info -and [string]$info.Version -eq '26.5.0.82') {
            Assert ($origHash -eq 'F79EA12D49A3C2D744BDD8ED7F0D7D2AF844A2C3A2D134DE73EC06769F0EEA33') 'Known original AuApplication.dll 26.5.0.82'
            Assert ((Get-BytesSha256 $dll) -eq '445663D683A6A7BEBF6E37ECE5A2D61AA75B776C81068FFBB16576F8A32557F0') 'Patched DLL equals the manually verified 26.5.0.82 patch'
        }
        Set-LocalePatch $dll (Find-LocalePatch $dll) -Undo
        Assert ((Get-BytesSha256 $dll) -eq $origHash) 'Undo restores the original bytes exactly'

        # Копия Audition: exe, исходная DLL, AMT, английские словари, справка, обучающая панель.
        $fake = Join-Path $tmp 'Adobe Audition 2026'
        foreach ($rel in 'Adobe Audition.exe', 'PlugPlug.dll', 'AMT\application.xml', 'dict\en_US\zdictionary_AUDT_en_US.dat', 'dict\en_US\dva_en_US.dict') {
            $dest = Join-Path $fake $rel; $null = New-Item -ItemType Directory -Force -Path (Split-Path $dest)
            Copy-Item -LiteralPath (Join-Path $auditionDir $rel) -Destination $dest
        }
        Copy-Item -LiteralPath $original -Destination (Join-Path $fake 'AuApplication.dll')
        $fd = [IO.File]::ReadAllBytes((Join-Path $fake 'AuApplication.dll')); $fh = Find-LocalePatch $fd
        if ($fh.State -eq 'Patched') { Set-LocalePatch $fd $fh -Undo; [IO.File]::WriteAllBytes((Join-Path $fake 'AuApplication.dll'), $fd) }
        Copy-Item -LiteralPath (Join-Path $auditionDir 'HelpCfg\en_US') -Destination (Join-Path $fake 'HelpCfg\en_US') -Recurse
        $onb = 'CEP\extensions\com.adobe.audition.Onboarding'
        foreach ($rel in "$onb\content\Content\C8C75B3C-05EF-4A2B-8FA9-DB1E1E7271CF\en_us", "$onb\surfaces\en_us") {
            if (Test-Path -LiteralPath (Join-Path $auditionDir $rel)) { Copy-Item -LiteralPath (Join-Path $auditionDir $rel) -Destination (Join-Path $fake $rel) -Recurse }
        }
        Set-AmtLanguage -Dir $fake -Locale 'en_US'
        # Чужой русский словарь (например, из изменённого установщика) должен сохраниться.
        $foreign = Join-Path $fake 'dict\ru_RU\zdictionary_AUDT_ru_RU.dat'
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $foreign)
        [IO.File]::WriteAllText($foreign, 'foreign', [Text.Encoding]::ASCII)
        $amtBefore = Get-Sha256 (Join-Path $fake 'AMT\application.xml')
        $dllBefore = Get-Sha256 (Join-Path $fake 'AuApplication.dll')

        $install = Get-AuditionInfo -Dir $fake
        Assert ($install.Supported) 'The copied Audition folder is recognised as supported'
        $Source = $root; $LearnPanel = $true
        Invoke-Install $install
        $state = Read-State $install
        Assert ((Get-AmtLanguage $fake) -eq 'ru_RU') 'Install switches installedLanguages to ru_RU'
        Assert ((Get-PatchState $install).State -eq 'Patched') 'Install patches AuApplication.dll'
        Assert ((Get-Sha256 (Join-Path $fake 'AdobeAudition-RU\backup\AuApplication.dll')) -eq $dllBefore) 'The original DLL is kept in AdobeAudition-RU\backup'
        Assert ((Get-Content -Raw -LiteralPath (Join-Path $fake 'AdobeAudition-RU\backup\dict\ru_RU\zdictionary_AUDT_ru_RU.dat')) -eq 'foreign') 'A previous ru_RU dictionary is moved to backup, not deleted'
        $enKeys = (Read-ZDictionary (Join-Path $fake 'dict\en_US\zdictionary_AUDT_en_US.dat')).Order; $ruInst = Read-ZDictionary $foreign
        Assert (@($enKeys | Where-Object { -not $ruInst.Map.ContainsKey($_) }).Count -eq 0 -and $ruInst.Order.Count -eq $enKeys.Count + 3) 'The installed dictionary has every key of this Audition version plus the licensing menu strings'
        Assert ((Get-ChildItem -LiteralPath (Join-Path $fake 'HelpCfg\ru_RU') -Filter *.helpcfg).Count -ge 1 -and (Get-Content -Raw -LiteralPath (Get-ChildItem (Join-Path $fake 'HelpCfg\ru_RU\*.helpcfg'))[0].FullName) -match 'helpmapPath="ru/') 'HelpCfg\ru_RU points to the Russian help'
        Assert ($state.originalLanguage -eq 'en_US' -and $state.packVersion -eq $m.version) 'The state remembers the original language and the translation version'
        if (Test-Path -LiteralPath (Join-Path $fake "$onb\surfaces\en_us")) {
            Assert (Test-Path -LiteralPath (Join-Path $fake "$onb\surfaces\ru_ru\stringtable.txt")) 'The Learn panel translation is installed on request'
            Assert ($script:pdm -contains 'set') 'Installing the Learn panel enables PlayerDebugMode (CEP rejects the modified signed panel otherwise)'
        }
        # Повторная установка идемпотентна.
        Invoke-Install $install
        Assert ((Get-Content -Raw -LiteralPath (Join-Path $fake 'AdobeAudition-RU\backup\dict\ru_RU\zdictionary_AUDT_ru_RU.dat')) -eq 'foreign') 'Reinstalling keeps the first backup'
        Assert ((Get-Sha256 (Join-Path $fake 'AdobeAudition-RU\backup\AuApplication.dll')) -eq $dllBefore) 'Reinstalling keeps the original DLL backup'

        Invoke-Switch -Install $install -Locale 'en_US'
        Assert ((Get-AmtLanguage $fake) -eq 'en_US') 'Switch to English'
        Invoke-Switch -Install $install -Locale 'ru_RU'
        Assert ((Get-AmtLanguage $fake) -eq 'ru_RU') 'Switch back to Russian'
        Assert-Throws { Invoke-Switch -Install $install -Locale 'xx_XX' } 'Switching to a language that is not installed fails'

        # Обновление Audition заменило DLL — повторная установка снова её исправляет.
        Copy-Item -LiteralPath (Join-Path $fake 'AdobeAudition-RU\backup\AuApplication.dll') -Destination (Join-Path $fake 'AuApplication.dll') -Force
        Assert ((Get-PatchState $install).State -eq 'Original') 'Simulated Audition update: the DLL is original again'
        Invoke-Switch -Install $install -Locale 'ru_RU'
        Assert ((Get-PatchState $install).State -eq 'Patched') 'Switching to Russian re-applies the patch after an update'

        # DLL занята процессом (как у зависшего Audition): отображаем её как образ в этот процесс.
        Add-Type -Namespace T -Name Native -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern IntPtr LoadLibraryEx(string p, IntPtr h, uint f); [DllImport("kernel32.dll")] public static extern bool FreeLibrary(IntPtr h);'
        $lock = [T.Native]::LoadLibraryEx((Join-Path $fake 'AuApplication.dll'), [IntPtr]::Zero, 0x20)
        Assert ($lock -ne [IntPtr]::Zero) 'Test setup: the DLL is mapped as an image (locked like in a running process)'
        Assert-Throws { Remove-Item -LiteralPath (Join-Path $fake 'AuApplication.dll') -Force -ErrorAction Stop } 'Test setup: a mapped DLL cannot be deleted'
        Invoke-Restore $install
        Assert ((Get-Sha256 (Join-Path $fake 'AuApplication.dll')) -eq $dllBefore) 'Restore replaces a DLL that is in use (rename, then put the original in place)'
        [void][T.Native]::FreeLibrary($lock)
        Remove-StaleFiles $fake
        Assert (-not @(Get-ChildItem -LiteralPath $fake -Filter '*.ru-old-*').Count) 'The renamed in-use DLL is removed once it is released'
        Assert ((Get-Sha256 (Join-Path $fake 'AuApplication.dll')) -eq $dllBefore) 'Restore returns the original DLL byte for byte'
        Assert ((Get-Sha256 (Join-Path $fake 'AMT\application.xml')) -eq $amtBefore) 'Restore returns application.xml byte for byte'
        Assert ((Get-Content -Raw -LiteralPath $foreign) -eq 'foreign') 'Restore puts the previous ru_RU dictionary back'
        Assert (-not (Test-Path -LiteralPath (Join-Path $fake 'HelpCfg\ru_RU'))) 'Restore removes created folders'
        Assert (-not (Test-Path -LiteralPath (Join-Path $fake "$onb\surfaces\ru_ru"))) 'Restore removes the Learn panel translation'
        Assert (-not (Test-Path -LiteralPath (Join-Path $fake 'AdobeAudition-RU'))) 'Restore removes the state and backup folder'
        Assert ($script:pdm -contains 'undo') 'Restore reverts PlayerDebugMode'
    } else { Skip "Adobe Audition not found at $auditionDir - DLL and end-to-end checks skipped" }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ("  {0} checks passed{1}" -f $script:checks, $(if ($script:skipped) { ", $($script:skipped) skipped" } else { '' })) -ForegroundColor Green
