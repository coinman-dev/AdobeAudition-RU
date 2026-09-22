<#
.SYNOPSIS
    Русификатор Adobe Audition 2026 и новее: установка, переключение языка, возврат.
    Russian language for Adobe Audition 2026 and later: install, switch language, restore.

.DESCRIPTION
    Добавляет в установленный Adobe Audition настоящий русский язык интерфейса (ru_RU),
    а не подмену другого языка.

    Что делает установка:
      * берёт файлы перевода из GitHub Releases (кэш в %TEMP%\AdobeAudition-RU) или
        из папки рядом со скриптом; каждый файл проверяется по SHA256 из manifest.json;
      * собирает словари dict\ru_RU под установленную версию Audition: строки,
        которых нет в переводе, остаются английскими;
      * создаёт HelpCfg\ru_RU (справка F1 на helpx.adobe.com/ru);
      * меняет 2 байта в AuApplication.dll: в Audition зашит список языков интерфейса,
        и без этого исправления ru_RU молча заменяется на en_US;
      * переключает язык в AMT\application.xml (installedLanguages).

    Ничего не удаляется: заменяемые файлы переносятся в папку
    <Audition>\AdobeAudition-RU\backup, исходный язык запоминается, а пункт
    «Удалить русификатор» возвращает всё как было.

    Запуск без параметров открывает меню и сам запрашивает права администратора.

.EXAMPLE
    .\Install-AuditionRU.ps1
    Меню: установить, переключить язык, состояние, удалить.

.EXAMPLE
    .\Install-AuditionRU.ps1 -Action Install -Yes
    Установить русский язык без вопросов.

.EXAMPLE
    .\Install-AuditionRU.ps1 -Action Switch -Language en_US
    Переключить интерфейс на английский (русификатор остаётся установленным).

.EXAMPLE
    .\Install-AuditionRU.ps1 -Action Restore
    Удалить русификатор и вернуть исходный язык и файлы.

.EXAMPLE
    irm https://github.com/coinman-dev/AdobeAudition-RU/releases/latest/download/Install-AuditionRU.ps1 | iex
    Запуск одной командой из PowerShell.

.NOTES
    Требуется Windows PowerShell 5.1 или PowerShell 7 и права администратора
    (запрашиваются автоматически). Перед изменениями Audition нужно закрыть.
    Язык сообщений выбирается по языку Windows, переопределяется ключом -UILang.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    # Что сделать. Без параметра открывается меню.
    [ValidateSet('Menu', 'Install', 'Switch', 'Restore', 'Status')]
    [string]$Action = 'Menu',

    # Язык для -Action Switch: ru_RU, en_US, de_DE и т.д.
    [string]$Language,

    # Папка Audition (где лежит «Adobe Audition.exe»). По умолчанию ищется сама.
    [string]$AuditionPath,

    # Папка с manifest.json и файлами перевода (клон репозитория). Без загрузки из сети.
    [string]$Source,

    # Тег релиза GitHub, например v1.0.0. По умолчанию — последний релиз.
    [string]$Release = 'latest',

    # Установить также перевод обучающей панели («Обучение Audition»). Включает PlayerDebugMode
    # (HKCU): без него Adobe CEP отвергает панель с добавленными файлами («Недопустимая сигнатура»).
    [switch]$LearnPanel,

    # Не задавать вопросов (для сценариев).
    [switch]$Yes,

    # Язык сообщений скрипта.
    [ValidateSet('auto', 'ru', 'en')]
    [string]$UILang = 'auto',

    # Не ждать нажатия клавиши перед выходом.
    [switch]$NoPause,

    # Служебный: скрипт перезапущен с правами администратора.
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'
$script:Repo        = 'coinman-dev/AdobeAudition-RU'
$script:ToolName    = 'AdobeAudition-RU'
$script:MinMajor    = 26
$script:StateFolder = 'AdobeAudition-RU'
$script:CacheRoot   = Join-Path ([IO.Path]::GetTempPath()) 'AdobeAudition-RU'
$script:ScriptPath  = $PSCommandPath
$script:ScriptRoot  = if ($PSScriptRoot) { $PSScriptRoot } else { $null }
$script:PatchExport = '?SetLocalePref@app@@'

#region Messages and console

# Язык сообщений: русский, если русский хоть что-то из языка интерфейса Windows,
# региональных форматов или языка системы (частый случай — английская Windows с русскими форматами).
$script:Lang = $UILang
if ($script:Lang -eq 'auto') {
    $names = @()
    try { $names += (Get-UICulture).Name } catch { }
    try { $names += (Get-Culture).Name } catch { }
    try { $names += [Globalization.CultureInfo]::InstalledUICulture.Name } catch { }
    $script:Lang = if (@($names | Where-Object { $_ -like 'ru*' }).Count) { 'ru' } else { 'en' }
}

# Возвращает сообщение на текущем языке. Обе строки уже интерполированы.
function T {
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Ru,
          [Parameter(Position = 1)][AllowEmptyString()][string]$En)
    if ($script:Lang -eq 'en' -and $PSBoundParameters.ContainsKey('En')) { return $En }
    $Ru
}

$script:WizardMode = ($Action -eq 'Menu')
$script:PauseOnExit = $script:WizardMode -or $Elevated

function Test-CanPrompt {
    try { -not [Console]::IsInputRedirected -and [Environment]::UserInteractive } catch { $false }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Wait-BeforeExit {
    if ($NoPause -or -not $script:PauseOnExit) { return }
    try { if ([Console]::IsInputRedirected) { return } } catch { return }
    Write-Host ''
    Write-Host (T '  Нажмите любую клавишу для выхода...' '  Press any key to exit...') -ForegroundColor DarkCyan
    try { $null = [Console]::ReadKey($true); return } catch { }
    try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown'); return } catch { }
    try { $null = Read-Host; return } catch { }
    Start-Sleep -Seconds 15
}

function Write-Title {
    param([string]$Title)
    Write-Host ''
    Write-Host ('─' * 72) -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ('─' * 72) -ForegroundColor DarkCyan
}
function Write-Step { param([string]$Message) Write-Host "  → $Message" -ForegroundColor Gray }
function Write-Ok   { param([string]$Message) Write-Host "  ✓ $Message" -ForegroundColor Green }
function Write-Note { param([string]$Message) Write-Host "  ! $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "  ✗ $Message" -ForegroundColor Red }

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1MB) { return ('{0:N1} ' -f ($Bytes / 1MB)) + (T 'МБ' 'MB') }
    ('{0:N0} ' -f ($Bytes / 1KB)) + (T 'КБ' 'KB')
}

function Read-YesNo {
    param([string]$Question, [bool]$Default = $false)
    if ($Yes -or -not (Test-CanPrompt)) { return $Default }
    $hint = if ($Default) { T '[Да/нет]' '[Yes/no]' } else { T '[да/Нет]' '[yes/No]' }
    while ($true) {
        $answer = (Read-Host "  $Question $hint").Trim().ToLower()
        if (-not $answer) { return $Default }
        if ($answer -in @('д', 'да', 'y', 'yes', '1', '+')) { return $true }
        if ($answer -in @('н', 'нет', 'n', 'no', '0', '-')) { return $false }
        Write-Host (T '  Ответьте «да» или «нет» (Enter — значение по умолчанию).' '  Answer yes or no (Enter keeps the default).') -ForegroundColor Yellow
    }
}

function Read-Option {
    param([string]$Question, [string[]]$Items, [object[]]$Values, [int]$Default = 1, [switch]$AllowZero, [string]$ZeroText)
    if (-not $Values) { $Values = $Items }
    Write-Host ''
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $mark = if ($i + 1 -eq $Default) { '*' } else { ' ' }
        Write-Host ("   {0}{1,2}. {2}" -f $mark, ($i + 1), $Items[$i])
    }
    if ($AllowZero) { Write-Host ("    {0,2}. {1}" -f 0, $ZeroText) }
    Write-Host ''
    while ($true) {
        $answer = (Read-Host "  $Question (Enter — $Default)").Trim()
        if (-not $answer) { return $Values[$Default - 1] }
        if ($answer -match '^\d+$') {
            $n = [int]$answer
            if ($AllowZero -and $n -eq 0) { return $null }
            if ($n -ge 1 -and $n -le $Items.Count) { return $Values[$n - 1] }
        }
        Write-Host (T "  Введите число от $(if ($AllowZero) { 0 } else { 1 }) до $($Items.Count)." "  Enter a number between $(if ($AllowZero) { 0 } else { 1 }) and $($Items.Count).") -ForegroundColor Yellow
    }
}

#endregion

#region Elevation

function Get-ElevationCommand {
    param([string]$ScriptPath, [Collections.IDictionary]$Parameters)
    $forward = @{}
    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        if ($value -is [switch]) { $value = [bool]$value }
        $forward[$key] = $value
    }
    $forward['Elevated'] = $true
    $serialized = [Management.Automation.PSSerializer]::Serialize($forward)
    $payload = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($serialized))
    $quotedPath = $ScriptPath.Replace("'", "''")
    $command = "`$forward = [Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$payload'))); & '$quotedPath' @forward"
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
}

function Restart-Elevated {
    param([Collections.IDictionary]$Parameters)
    $path = $script:ScriptPath
    if (-not $path) {
        # Запуск через «irm ... | iex»: у скрипта нет файла, скачиваем его копию.
        $null = New-Item -ItemType Directory -Force -Path $script:CacheRoot
        $path = Join-Path $script:CacheRoot 'Install-AuditionRU.ps1'
        $url = if ($Release -eq 'latest') { "https://github.com/$($script:Repo)/releases/latest/download/Install-AuditionRU.ps1" }
               else { "https://github.com/$($script:Repo)/releases/download/$Release/Install-AuditionRU.ps1" }
        Save-Url -Url $url -Destination $path
    }
    $hostExe = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path
    if (-not $hostExe -or $hostExe -notmatch '(pwsh|powershell)\.exe$') {
        $hostExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    }
    $encoded = Get-ElevationCommand -ScriptPath $path -Parameters $Parameters
    Write-Host ''
    Write-Host (T '  Для изменения файлов Adobe Audition нужны права администратора.' '  Administrator rights are required to change Adobe Audition files.') -ForegroundColor Yellow
    Write-Host (T '  Перезапускаю скрипт — подтвердите запрос системы.' '  Restarting the script - please confirm the system prompt.') -ForegroundColor Yellow
    try {
        Start-Process -FilePath $hostExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -Verb RunAs -ErrorAction Stop
    } catch {
        throw (T 'Запуск от имени администратора отменён. Откройте PowerShell от имени администратора и запустите скрипт оттуда.' 'Elevation was cancelled. Open PowerShell as administrator and run the script from there.')
    }
    # Дальше работает окно администратора; это окно можно закрыть без паузы.
    $script:PauseOnExit = $false
}

#endregion

#region Files and downloads

function Read-TextFile {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3) }
    [Text.Encoding]::UTF8.GetString($bytes)
}

# Кладёт файл на место. Если прежний файл занят (DLL, загруженная процессом — даже
# зависшим завершённым), его нельзя перезаписать или удалить, но можно переименовать:
# прежний уходит в <имя>.ru-old-<guid> и удаляется, когда освободится (Remove-StaleFiles).
function Move-IntoPlace {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    try {
        Move-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
        return
    } catch {
        if (-not (Test-Path -LiteralPath $Destination)) { throw }
    }
    $old = "$Destination.ru-old-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
    [IO.File]::Move($Destination, $old)
    try { [IO.File]::Move($Source, $Destination) } catch { [IO.File]::Move($old, $Destination); throw }
    try { Remove-Item -LiteralPath $old -Force -ErrorAction Stop }
    catch { Write-Note (T "Прежний $(Split-Path $Destination -Leaf) ещё занят процессом — удалю при следующем запуске" "The previous $(Split-Path $Destination -Leaf) is still in use - it will be removed on the next run") }
}

function Remove-StaleFiles {
    param([string]$Dir)
    foreach ($sub in '', 'AMT', 'dict\ru_RU', 'HelpCfg\ru_RU') {
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $Dir $sub) -File -Filter '*.ru-old-*' -ErrorAction SilentlyContinue)) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch { }
        }
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-BytesSha256 {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') } finally { $sha.Dispose() }
}

# Загрузка в .part: недокачанный файл никогда не выглядит готовым.
function Save-Url {
    param([string]$Url, [string]$Destination)
    $partial = "$Destination.part"
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    try {
        if (Test-Path -LiteralPath $curl) {
            & $curl -L --fail --silent --show-error --connect-timeout 20 --retry 2 --retry-delay 3 -o $partial $Url
            if ($LASTEXITCODE -ne 0) { throw (T "не удалось скачать $Url (curl, код $LASTEXITCODE)" "failed to download $Url (curl exit code $LASTEXITCODE)") }
        } else {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing
        }
        if (-not (Test-Path -LiteralPath $partial) -or (Get-Item -LiteralPath $partial).Length -le 0) {
            throw (T "получен пустой файл: $Url" "empty download: $Url")
        }
        Move-Item -LiteralPath $partial -Destination $Destination -Force
    } finally {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    }
}

function Read-Manifest {
    param([string]$Path)
    $m = Read-TextFile $Path | ConvertFrom-Json
    if ($m.schema -ne 1 -or $m.name -ne $script:ToolName -or -not @($m.files).Count) {
        throw (T "Неверный manifest.json: $Path" "Invalid manifest.json: $Path")
    }
    foreach ($f in @($m.files)) {
        foreach ($p in @($f.path, $f.target)) {
            if (-not $p -or $p -match '(^|[\\/])\.\.([\\/]|$)' -or $p -match '^[\\/]|:') {
                throw (T "Недопустимый путь в manifest.json: $p" "Unsafe path in manifest.json: $p")
            }
        }
        if ([string]$f.sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw (T "Нет SHA256 для $($f.path)" "Missing SHA256 for $($f.path)") }
    }
    $m
}

function Test-Payload {
    param([string]$Dir, $Manifest)
    foreach ($f in @($Manifest.files)) {
        $path = Join-Path $Dir ($f.path -replace '/', '\')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        if ((Get-Item -LiteralPath $path).Length -ne [int64]$f.size) { return $false }
        if ((Get-Sha256 $path) -ne ([string]$f.sha256).ToUpperInvariant()) { return $false }
    }
    $true
}

# Ключ сортировки SemVer: 0.1.0-beta < 0.1.0 < 0.2.0.
function Get-VersionKey {
    param([string]$Version)
    $m = [regex]::Match([string]$Version, '^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$')
    if (-not $m.Success) { return $null }
    $pre = if ($m.Groups[4].Success) { '0' + $m.Groups[4].Value } else { '1' }
    '{0:D6}.{1:D6}.{2:D6}.{3}' -f [int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value, $pre
}

function Find-CachedPayload {
    if (-not (Test-Path -LiteralPath $script:CacheRoot)) { return }
    $best = $null
    foreach ($d in @(Get-ChildItem -LiteralPath $script:CacheRoot -Directory -ErrorAction SilentlyContinue)) {
        $mp = Join-Path $d.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $mp)) { continue }
        try {
            $m = Read-Manifest $mp
            $key = Get-VersionKey $m.version
            if (-not $key -or -not (Test-Payload $d.FullName $m)) { continue }
            if (-not $best -or [string]::CompareOrdinal($key, $best.Key) -gt 0) { $best = [pscustomobject]@{ Dir = $d.FullName; Manifest = $m; Key = $key } }
        } catch { }
    }
    if ($best) { [pscustomobject]@{ Dir = $best.Dir; Manifest = $best.Manifest } }
}

# Файлы перевода: -Source → папка рядом со скриптом → проверенный кэш → GitHub Releases.
function Get-Payload {
    $local = $null
    if ($Source) { $local = $Source }
    elseif ($script:ScriptRoot -and (Test-Path -LiteralPath (Join-Path $script:ScriptRoot 'manifest.json')) -and
            (Test-Path -LiteralPath (Join-Path $script:ScriptRoot 'ru_RU'))) { $local = $script:ScriptRoot }
    if ($local) {
        $m = Read-Manifest (Join-Path $local 'manifest.json')
        if (-not (Test-Payload $local $m)) {
            throw (T "Файлы в «$local» не совпадают с manifest.json (размер или SHA256)." "Files in '$local' do not match manifest.json (size or SHA256).")
        }
        Write-Ok (T "Перевод $($m.version) взят из папки $local — файлы проверены" "Translation $($m.version) taken from $local - files verified")
        return [pscustomobject]@{ Dir = $local; Manifest = $m }
    }

    $null = New-Item -ItemType Directory -Force -Path $script:CacheRoot
    $base = if ($Release -eq 'latest') { "https://github.com/$($script:Repo)/releases/latest/download" }
            else { "https://github.com/$($script:Repo)/releases/download/$Release" }
    $manifestPath = Join-Path $script:CacheRoot ('manifest-' + ($Release -replace '[^\w\.\-]', '_') + '.json')
    Write-Step (T 'Проверка последней версии перевода на GitHub...' 'Checking the latest translation release on GitHub...')
    try {
        Save-Url -Url "$base/manifest.json" -Destination $manifestPath
    } catch {
        $cached = Find-CachedPayload
        if ($cached) {
            Write-Note (T "GitHub недоступен ($($_.Exception.Message)). Использую проверенный кэш версии $($cached.Manifest.version)." "GitHub is unreachable ($($_.Exception.Message)). Using the verified cache of version $($cached.Manifest.version).")
            return $cached
        }
        throw (T "Не удалось получить перевод с GitHub: $($_.Exception.Message)" "Could not get the translation from GitHub: $($_.Exception.Message)")
    }
    $m = Read-Manifest $manifestPath
    if (-not $m.package -or -not $m.package.name -or [string]$m.package.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw (T 'В manifest.json релиза нет описания архива.' 'The release manifest.json has no package description.')
    }
    $dir = Join-Path $script:CacheRoot ([string]$m.version)
    if ((Test-Path -LiteralPath (Join-Path $dir 'manifest.json')) -and (Test-Payload $dir $m)) {
        Write-Ok (T "Перевод $($m.version) уже скачан — файлы проверены, загрузка не нужна" "Translation $($m.version) is already downloaded - files verified, no download needed")
        return [pscustomobject]@{ Dir = $dir; Manifest = $m }
    }

    $zip = Join-Path $script:CacheRoot ([IO.Path]::GetFileName([string]$m.package.name))
    $zipOk = (Test-Path -LiteralPath $zip) -and (Get-Item -LiteralPath $zip).Length -eq [int64]$m.package.size -and (Get-Sha256 $zip) -eq ([string]$m.package.sha256).ToUpperInvariant()
    if (-not $zipOk) {
        Write-Step (T "Загрузка $($m.package.name) ($(Format-Size $m.package.size))..." "Downloading $($m.package.name) ($(Format-Size $m.package.size))...")
        $tag = if ($m.tag) { [string]$m.tag } else { $Release }
        Save-Url -Url "https://github.com/$($script:Repo)/releases/download/$tag/$($m.package.name)" -Destination $zip
        if ((Get-Item -LiteralPath $zip).Length -ne [int64]$m.package.size -or (Get-Sha256 $zip) -ne ([string]$m.package.sha256).ToUpperInvariant()) {
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            throw (T 'Скачанный архив повреждён: размер или SHA256 не совпадает с manifest.json.' 'The downloaded package is corrupt: size or SHA256 does not match manifest.json.')
        }
    }
    Write-Ok (T "Архив проверен (SHA256 совпадает)" "Package verified (SHA256 matches)")

    $tmp = "$dir.tmp"
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
    if (-not (Test-Payload $tmp $m)) {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        throw (T 'Файлы в архиве не совпадают с manifest.json.' 'Files in the package do not match manifest.json.')
    }
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $tmp 'manifest.json') -Force
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $tmp -Destination $dir
    Write-Ok (T "Перевод $($m.version) скачан и проверен" "Translation $($m.version) downloaded and verified")
    [pscustomobject]@{ Dir = $dir; Manifest = $m }
}

#endregion

#region Adobe Audition installations

$script:LocaleNames = @{
    'ru_RU' = 'Русский'; 'en_US' = 'English'; 'de_DE' = 'Deutsch'; 'fr_FR' = 'Français'; 'es_ES' = 'Español'
    'it_IT' = 'Italiano'; 'ja_JP' = '日本語 (Japanese)'; 'ko_KR' = '한국어 (Korean)'; 'pt_BR' = 'Português (Brasil)'
    'zh_CN' = '简体中文 (Chinese)'
}
function Get-LocaleName {
    param([string]$Locale)
    if ($script:LocaleNames.ContainsKey($Locale)) { return "$($script:LocaleNames[$Locale]) ($Locale)" }
    $Locale
}

function Get-AuditionInfo {
    param([string]$Dir)
    $exe = Join-Path $Dir 'Adobe Audition.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return }
    $version = $null
    try { $version = [version](((Get-Item -LiteralPath $exe).VersionInfo.FileVersion) -replace '[^\d\.].*$', '') } catch { }
    $missing = @(foreach ($rel in 'AuApplication.dll', 'AMT\application.xml', 'dict\en_US\zdictionary_AUDT_en_US.dat') {
        if (-not (Test-Path -LiteralPath (Join-Path $Dir $rel))) { $rel }
    })
    $reason = $null
    if (-not $version) { $reason = T 'не удалось определить версию' 'cannot read the version' }
    elseif ($version.Major -lt $script:MinMajor) { $reason = T "версия $version — нужна 2026 (26.0) или новее" "version $version - 2026 (26.0) or later is required" }
    elseif ($missing.Count) { $reason = (T 'нет файлов: ' 'missing files: ') + ($missing -join ', ') }
    [pscustomobject]@{
        Path      = $Dir
        Name      = Split-Path $Dir -Leaf
        Version   = $version
        Supported = -not $reason
        Reason    = $reason
    }
}

function Find-Auditions {
    $dirs = New-Object System.Collections.Generic.List[string]
    foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'AUDT*' })) {
            $p = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.InstallLocation -and $p.DisplayName) { $dirs.Add((Join-Path $p.InstallLocation $p.DisplayName)) }
        }
    }
    foreach ($base in @($env:ProgramW6432, $env:ProgramFiles) | Where-Object { $_ } | Select-Object -Unique) {
        $adobe = Join-Path $base 'Adobe'
        foreach ($d in @(Get-ChildItem -LiteralPath $adobe -Directory -Filter 'Adobe Audition*' -ErrorAction SilentlyContinue)) { $dirs.Add($d.FullName) }
    }
    $seen = @{}
    foreach ($d in $dirs) {
        $full = $null
        try { $full = [IO.Path]::GetFullPath($d).TrimEnd('\') } catch { }
        if (-not $full -or $seen.ContainsKey($full.ToLowerInvariant())) { continue }
        $seen[$full.ToLowerInvariant()] = $true
        $info = Get-AuditionInfo -Dir $full
        if ($info) { $info }
    }
}

function Select-Audition {
    if ($AuditionPath) {
        $info = Get-AuditionInfo -Dir ([IO.Path]::GetFullPath($AuditionPath).TrimEnd('\'))
        if (-not $info) { throw (T "В папке «$AuditionPath» нет Adobe Audition.exe." "'$AuditionPath' does not contain Adobe Audition.exe.") }
        if (-not $info.Supported) { throw (T "Эта копия Audition не поддерживается: $($info.Reason)." "This Audition copy is not supported: $($info.Reason).") }
        return $info
    }
    $all = @(Find-Auditions)
    foreach ($i in @($all | Where-Object { -not $_.Supported })) {
        Write-Note (T "Пропускаю $($i.Path): $($i.Reason)" "Skipping $($i.Path): $($i.Reason)")
    }
    $ok = @($all | Where-Object { $_.Supported } | Sort-Object Version -Descending)
    if (-not $ok.Count) {
        throw (T 'Не найден установленный Adobe Audition 2026 или новее. Укажите папку ключом -AuditionPath.' 'No installed Adobe Audition 2026 or later was found. Specify the folder with -AuditionPath.')
    }
    if ($ok.Count -eq 1 -or $Yes -or -not (Test-CanPrompt)) { return $ok[0] }
    $items = @($ok | ForEach-Object { "$($_.Name)  $($_.Version)  —  $($_.Path)" })
    Read-Option -Question (T 'Какой Audition настроить?' 'Which Audition to configure?') -Items $items -Values $ok
}

function Get-AuditionProcess {
    param([string]$Dir)
    @(Get-Process -Name 'Adobe Audition' -ErrorAction SilentlyContinue | Where-Object {
        # Завершённый процесс может ещё числиться в списке, пока кто-то держит его дескриптор.
        $exited = $false
        try { $exited = $_.HasExited } catch { }
        if ($exited) { return $false }
        $p = $null
        try { $p = $_.Path } catch { }
        -not $p -or $p.StartsWith($Dir + '\', [StringComparison]::OrdinalIgnoreCase)
    })
}

function Wait-AuditionClosed {
    param($Install)
    while (@(Get-AuditionProcess $Install.Path).Count) {
        Write-Note (T 'Adobe Audition запущен: пока он работает, его файлы менять нельзя.' 'Adobe Audition is running: its files cannot be changed while it runs.')
        if ($Yes -or -not (Test-CanPrompt)) { throw (T 'Закройте Adobe Audition и повторите.' 'Close Adobe Audition and try again.') }
        $answer = Read-Host (T '  Закройте Audition и нажмите Enter (0 — отмена)' '  Close Audition and press Enter (0 - cancel)')
        if ($answer.Trim() -eq '0') { throw (T 'Отменено.' 'Cancelled.') }
    }
}

#endregion

#region Dictionaries

$script:ZLine = [regex]'^"(\$\$\$/[^=]*)=(.*)"$'

# Словарь Adobe ZString: строки вида "$$$/ключ=значение". Возвращает ключи в порядке файла.
function Read-ZDictionary {
    param([string]$Path)
    $map = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $order = New-Object System.Collections.Generic.List[string]
    foreach ($line in ((Read-TextFile $Path) -split "\r?\n")) {
        $m = $script:ZLine.Match($line.Trim())
        if (-not $m.Success) { continue }
        $key = $m.Groups[1].Value
        if (-not $map.ContainsKey($key)) { $order.Add($key) }
        $map[$key] = $m.Groups[2].Value
    }
    [pscustomobject]@{ Map = $map; Order = $order }
}

# Русский словарь под конкретную версию: ключи и порядок — из английского словаря
# установленного Audition, значения — из перевода; чего нет в переводе, остаётся английским.
# Ключи перевода, которых нет в английском словаре (текст по умолчанию зашит в DLL,
# например «Sign In...»), дописываются в конец: загрузчик берёт их из словаря.
function Merge-ZDictionary {
    param([string]$EnglishPath, [string]$RussianPath, [string]$OutPath)
    $en = Read-ZDictionary $EnglishPath
    $ru = Read-ZDictionary $RussianPath
    $sb = New-Object Text.StringBuilder (($en.Order.Count + 1) * 96)
    $translated = 0
    foreach ($key in $en.Order) {
        $value = $null
        if ($ru.Map.TryGetValue($key, [ref]$value)) { $translated++ } else { $value = $en.Map[$key] }
        [void]$sb.Append('"').Append($key).Append('=').Append($value).Append("`"`r`n")
    }
    $extra = 0
    foreach ($key in $ru.Order) {
        if ($en.Map.ContainsKey($key)) { continue }
        [void]$sb.Append('"').Append($key).Append('=').Append($ru.Map[$key]).Append("`"`r`n")
        $extra++
    }
    [IO.File]::WriteAllText($OutPath, $sb.ToString(), (New-Object Text.UTF8Encoding $true))
    [pscustomobject]@{ Total = $en.Order.Count; Translated = $translated; Extra = $extra }
}

#endregion

#region AuApplication.dll patch

# Минимальный разбор PE32+: секции, экспорт, таблица .pdata.
function Get-PeLayout {
    param([byte[]]$Bytes)
    if ($Bytes.Length -lt 0x200 -or $Bytes[0] -ne 0x4D -or $Bytes[1] -ne 0x5A) { throw (T 'Файл не является DLL Windows.' 'Not a Windows DLL.') }
    $pe = [BitConverter]::ToInt32($Bytes, 0x3C)
    if ($pe -le 0 -or $pe + 24 -gt $Bytes.Length -or [BitConverter]::ToUInt32($Bytes, $pe) -ne 0x4550) { throw (T 'Повреждён заголовок PE.' 'Corrupt PE header.') }
    $sectionCount = [BitConverter]::ToUInt16($Bytes, $pe + 6)
    $optSize = [BitConverter]::ToUInt16($Bytes, $pe + 20)
    $opt = $pe + 24
    if ([BitConverter]::ToUInt16($Bytes, $opt) -ne 0x20B) { throw (T 'Ожидалась 64-битная DLL.' 'A 64-bit DLL was expected.') }
    $dirs = $opt + 112
    $sections = @()
    $table = $opt + $optSize
    for ($i = 0; $i -lt $sectionCount; $i++) {
        $s = $table + $i * 40
        $sections += [pscustomobject]@{
            Name   = [Text.Encoding]::ASCII.GetString($Bytes, $s, 8).TrimEnd([char]0)
            VSize  = [BitConverter]::ToUInt32($Bytes, $s + 8)
            VA     = [BitConverter]::ToUInt32($Bytes, $s + 12)
            RawLen = [BitConverter]::ToUInt32($Bytes, $s + 16)
            RawPtr = [BitConverter]::ToUInt32($Bytes, $s + 20)
        }
    }
    [pscustomobject]@{
        Sections   = $sections
        ExportRva  = [BitConverter]::ToUInt32($Bytes, $dirs)
        PdataRva   = [BitConverter]::ToUInt32($Bytes, $dirs + 24)
        PdataSize  = [BitConverter]::ToUInt32($Bytes, $dirs + 28)
    }
}

function ConvertTo-PeOffset {
    param($Layout, [int64]$Rva)
    foreach ($s in $Layout.Sections) {
        if ($Rva -ge $s.VA -and $Rva -lt $s.VA + [Math]::Max($s.VSize, $s.RawLen)) {
            if ($Rva - $s.VA -ge $s.RawLen) { return -1 }
            return [int64]($Rva - $s.VA + $s.RawPtr)
        }
    }
    -1
}

function ConvertTo-PeRva {
    param($Layout, [int64]$Offset)
    foreach ($s in $Layout.Sections) {
        if ($Offset -ge $s.RawPtr -and $Offset -lt $s.RawPtr + $s.RawLen) { return [int64]($Offset - $s.RawPtr + $s.VA) }
    }
    -1
}

# Имя экспорта ищется в тексте файла (Latin-1 = байт в символ), затем — указатель на него
# в таблице имён: так быстрее, чем читать тысячи имён по байту.
function Get-PeExportRva {
    param([byte[]]$Bytes, $Layout, [string]$Prefix)
    $exp = ConvertTo-PeOffset $Layout $Layout.ExportRva
    if ($Layout.ExportRva -eq 0 -or $exp -lt 0) { return $null }
    $text = [Text.Encoding]::GetEncoding(28591).GetString($Bytes)
    $nameRvas = @{}
    $at = $text.IndexOf("`0$Prefix", [StringComparison]::Ordinal)
    while ($at -ge 0) {
        $rva = ConvertTo-PeRva $Layout ($at + 1)
        if ($rva -ge 0) { $nameRvas[[int64]$rva] = $true }
        $at = $text.IndexOf("`0$Prefix", $at + 1, [StringComparison]::Ordinal)
    }
    if (-not $nameRvas.Count) { return $null }
    $count = [BitConverter]::ToUInt32($Bytes, $exp + 24)
    $functions = ConvertTo-PeOffset $Layout ([BitConverter]::ToUInt32($Bytes, $exp + 28))
    $names = ConvertTo-PeOffset $Layout ([BitConverter]::ToUInt32($Bytes, $exp + 32))
    $ordinals = ConvertTo-PeOffset $Layout ([BitConverter]::ToUInt32($Bytes, $exp + 36))
    for ($i = 0; $i -lt $count; $i++) {
        if ($nameRvas.ContainsKey([int64][BitConverter]::ToUInt32($Bytes, $names + 4 * $i))) {
            $ordinal = [BitConverter]::ToUInt16($Bytes, $ordinals + 2 * $i)
            return [int64][BitConverter]::ToUInt32($Bytes, $functions + 4 * $ordinal)
        }
    }
    $null
}

# Конец функции — из таблицы исключений .pdata (отсортирована по адресу начала).
function Get-PeFunctionEnd {
    param([byte[]]$Bytes, $Layout, [int64]$Rva)
    $p = ConvertTo-PeOffset $Layout $Layout.PdataRva
    if ($Layout.PdataRva -eq 0 -or $p -lt 0) { return $null }
    $lo = 0; $hi = [int]($Layout.PdataSize / 12) - 1
    while ($lo -le $hi) {
        $mid = [int][Math]::Floor(($lo + $hi) / 2)
        $begin = [BitConverter]::ToUInt32($Bytes, $p + 12 * $mid)
        $end = [BitConverter]::ToUInt32($Bytes, $p + 12 * $mid + 4)
        if ($Rva -lt $begin) { $hi = $mid - 1 }
        elseif ($Rva -ge $end) { $lo = $mid + 1 }
        else { return [int64]$end }
    }
    $null
}

# Внутри app::SetLocalePref Audition ищет язык в зашитом списке
# (de, en, es, fr, it, ja, ko, pt_BR, zh_CN); если не нашёл — подставляет "en_US":
#     75 xx            jne <сохранить язык>
#     48 8D 15 d32     lea rdx, "en_US"      <- замена на EB (xx-2): jmp <сохранить язык>
# Шаблон ищется по смыслу, а не по адресу, поэтому переживает пересборку DLL.
function Find-LocalePatch {
    param([byte[]]$Bytes)
    $layout = Get-PeLayout $Bytes
    $fn = Get-PeExportRva -Bytes $Bytes -Layout $layout -Prefix $script:PatchExport
    if ($null -eq $fn) { return [pscustomobject]@{ State = 'NotFound'; Reason = T 'нет функции SetLocalePref' 'SetLocalePref export not found' } }
    $end = Get-PeFunctionEnd -Bytes $Bytes -Layout $layout -Rva $fn
    if ($null -eq $end) { $end = $fn + 0x800 }
    $start = ConvertTo-PeOffset $layout $fn
    $stop = ConvertTo-PeOffset $layout ($end - 1)
    if ($start -lt 0 -or $stop -lt $start) { return [pscustomobject]@{ State = 'NotFound'; Reason = T 'функция вне секций' 'function outside sections' } }
    $hits = @()
    for ($i = $start; $i -le $stop - 8; $i++) {
        if ($Bytes[$i] -ne 0x75 -or $Bytes[$i + 4] -ne 0x15) { continue }
        $jump = [int]$Bytes[$i + 1]
        if ($jump -le 7 -or $jump -ge 0x80) { continue }
        $original = $Bytes[$i + 2] -eq 0x48 -and $Bytes[$i + 3] -eq 0x8D
        $patched = $Bytes[$i + 2] -eq 0xEB -and [int]$Bytes[$i + 3] -eq ($jump - 2)
        if (-not ($original -or $patched)) { continue }
        $leaRva = ConvertTo-PeRva $layout ($i + 2)
        $target = ConvertTo-PeOffset $layout ($leaRva + 7 + [BitConverter]::ToInt32($Bytes, $i + 5))
        if ($target -lt 0 -or $target + 6 -gt $Bytes.Length) { continue }
        if ([Text.Encoding]::ASCII.GetString($Bytes, $target, 6) -ne "en_US`0") { continue }
        $hits += [pscustomobject]@{ State = $(if ($original) { 'Original' } else { 'Patched' }); Offset = [int64]($i + 2); Jump = $jump; Reason = $null }
    }
    if ($hits.Count -ne 1) {
        return [pscustomobject]@{ State = 'NotFound'; Reason = T "найдено совпадений: $($hits.Count), ожидалось 1" "matches found: $($hits.Count), expected 1" }
    }
    $hits[0]
}

function Set-LocalePatch {
    param([byte[]]$Bytes, $Hit, [switch]$Undo)
    if ($Undo) { $Bytes[$Hit.Offset] = 0x48; $Bytes[$Hit.Offset + 1] = 0x8D }
    else { $Bytes[$Hit.Offset] = 0xEB; $Bytes[$Hit.Offset + 1] = [byte]($Hit.Jump - 2) }
}

function Get-PatchState {
    param($Install)
    $bytes = [IO.File]::ReadAllBytes((Join-Path $Install.Path 'AuApplication.dll'))
    Find-LocalePatch $bytes
}

#endregion

#region AMT language

function Get-AmtLanguage {
    param([string]$Dir)
    $text = Read-TextFile (Join-Path $Dir 'AMT\application.xml')
    $m = [regex]::Match($text, '<Data key="installedLanguages">([^<]*)</Data>')
    if ($m.Success) { $m.Groups[1].Value.Trim() } else { $null }
}

# Меняется только значение installedLanguages; кодировка и переводы строк файла сохраняются.
function Set-AmtLanguage {
    param([string]$Dir, [string]$Locale)
    if ($Locale -notmatch '^[a-z]{2}_[A-Z]{2}$') { throw (T "Неверный код языка: $Locale" "Invalid language code: $Locale") }
    $path = Join-Path $Dir 'AMT\application.xml'
    $bytes = [IO.File]::ReadAllBytes($path)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = Read-TextFile $path
    $rx = [regex]'(<Data key="installedLanguages">)[^<]*(</Data>)'
    if ($rx.IsMatch($text)) {
        $text = $rx.Replace($text, ('${1}' + $Locale + '${2}'), 1)
    } else {
        $i = $text.IndexOf('</Payload>')
        if ($i -lt 0) { throw (T 'В AMT\application.xml нет раздела Payload.' 'AMT\application.xml has no Payload section.') }
        $text = $text.Insert($i, "<Data key=`"installedLanguages`">$Locale</Data>")
    }
    $tmp = "$path.ru-tmp"
    [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding $bom))
    Move-IntoPlace -Source $tmp -Destination $path
}

#endregion

#region State and file bookkeeping

function Get-StateDir { param($Install) Join-Path $Install.Path $script:StateFolder }

function Read-State {
    param($Install)
    $path = Join-Path (Get-StateDir $Install) 'state.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { Read-TextFile $path | ConvertFrom-Json } catch { $null }
}

function Write-State {
    param($Install, $State)
    $dir = Get-StateDir $Install
    $null = New-Item -ItemType Directory -Force -Path $dir
    $path = Join-Path $dir 'state.json'
    [IO.File]::WriteAllText("$path.tmp", ($State | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath "$path.tmp" -Destination $path -Force
}

function New-State {
    param($Install, $Previous)
    $files = New-Object System.Collections.ArrayList
    if ($Previous -and $Previous.files) { foreach ($f in @($Previous.files)) { [void]$files.Add([pscustomobject]@{ target = $f.target; sha256 = $f.sha256; backup = $f.backup; group = $f.group }) } }
    [pscustomobject]@{
        schema           = 1
        tool             = $script:ToolName
        packVersion      = if ($Previous) { $Previous.packVersion } else { $null }
        auditionVersion  = [string]$Install.Version
        originalLanguage = if ($Previous -and $Previous.originalLanguage) { $Previous.originalLanguage } else { Get-AmtLanguage $Install.Path }
        files            = $files
        dll              = if ($Previous) { $Previous.dll } else { $null }
        coverage         = if ($Previous) { $Previous.coverage } else { $null }
        playerDebugMode  = if ($Previous) { $Previous.playerDebugMode } else { $null }
    }
}

function Find-StateFile {
    param($State, [string]$Target)
    foreach ($f in @($State.files)) { if ($f.target -eq $Target) { return $f } }
    $null
}

# Кладёт готовый файл на место. Чужой файл, который был там раньше, не удаляется,
# а переносится в <Audition>\AdobeAudition-RU\backup (и возвращается при удалении).
function Publish-File {
    param($Install, $State, [string]$Target, [string]$TempPath, [string]$Group)
    $dest = Join-Path $Install.Path $Target
    $entry = Find-StateFile $State $Target
    if (Test-Path -LiteralPath $dest) {
        $ours = $entry -and (Get-Sha256 $dest) -eq $entry.sha256
        if (-not $ours -and -not ($entry -and $entry.backup)) {
            $backupRel = Join-Path 'backup' $Target
            $backup = Join-Path (Get-StateDir $Install) $backupRel
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $backup)
            Move-Item -LiteralPath $dest -Destination $backup -Force
            if ($entry) { $entry.backup = $backupRel }
            else { $entry = [pscustomobject]@{ target = $Target; sha256 = $null; backup = $backupRel; group = $Group }; [void]$State.files.Add($entry) }
            Write-Note (T "Прежний файл $Target сохранён в $($script:StateFolder)\$backupRel" "Previous $Target saved to $($script:StateFolder)\$backupRel")
        }
    }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $dest)
    Move-IntoPlace -Source $TempPath -Destination $dest
    $hash = Get-Sha256 $dest
    if ($entry) { $entry.sha256 = $hash; $entry.group = $Group }
    else { [void]$State.files.Add([pscustomobject]@{ target = $Target; sha256 = $hash; backup = $null; group = $Group }) }
}

function Remove-PublishedFiles {
    param($Install, $State, [string]$Group)
    $keep = New-Object System.Collections.ArrayList
    foreach ($f in @($State.files)) {
        if ($Group -and $f.group -ne $Group) { [void]$keep.Add($f); continue }
        $dest = Join-Path $Install.Path $f.target
        if (Test-Path -LiteralPath $dest) {
            if ($f.sha256 -and (Get-Sha256 $dest) -eq $f.sha256) { Remove-Item -LiteralPath $dest -Force }
            else { Write-Note (T "$($f.target) изменён после установки — оставляю как есть" "$($f.target) was changed after installation - leaving it") }
        }
        if ($f.backup) {
            $backup = Join-Path (Get-StateDir $Install) $f.backup
            if (Test-Path -LiteralPath $backup) {
                if (-not (Test-Path -LiteralPath $dest)) {
                    $null = New-Item -ItemType Directory -Force -Path (Split-Path $dest)
                    Move-Item -LiteralPath $backup -Destination $dest
                    Write-Ok (T "Возвращён прежний файл $($f.target)" "Restored previous $($f.target)")
                }
            }
        }
        # Пустые папки, созданные установкой (dict\ru_RU, HelpCfg\ru_RU, ru_ru).
        $parent = Split-Path $dest
        while ($parent.Length -gt $Install.Path.Length -and (Test-Path -LiteralPath $parent) -and -not @(Get-ChildItem -LiteralPath $parent -Force).Count) {
            Remove-Item -LiteralPath $parent -Force
            $parent = Split-Path $parent
        }
    }
    $State.files = $keep
}

#endregion

#region Learn panel (CEP)

function Get-CsxsVersion {
    param($Install)
    $dll = Join-Path $Install.Path 'PlugPlug.dll'
    if (-not (Test-Path -LiteralPath $dll)) { return $null }
    $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($dll))
    $best = $null
    foreach ($m in [regex]::Matches($text, 'CSXS\.(\d{1,2})(?!\d)')) {
        $v = [int]$m.Groups[1].Value
        if (-not $best -or $v -gt $best) { $best = $v }
    }
    $best
}

function Set-PlayerDebugMode {
    param($Install, $State, [switch]$Undo)
    if ($Undo) {
        $p = $State.playerDebugMode
        if (-not $p) { return }
        $key = "HKCU:\Software\Adobe\$($p.key)"
        if ($null -eq $p.previous) { Remove-ItemProperty -LiteralPath $key -Name PlayerDebugMode -ErrorAction SilentlyContinue }
        else { Set-ItemProperty -LiteralPath $key -Name PlayerDebugMode -Value $p.previous }
        $State.playerDebugMode = $null
        return
    }
    $csxs = Get-CsxsVersion $Install
    if (-not $csxs) { Write-Note (T 'Не удалось определить версию CEP — PlayerDebugMode не включён' 'Cannot detect the CEP version - PlayerDebugMode not enabled'); return }
    $name = "CSXS.$csxs"
    $key = "HKCU:\Software\Adobe\$name"
    $null = New-Item -Path $key -Force
    $previous = (Get-ItemProperty -LiteralPath $key -Name PlayerDebugMode -ErrorAction SilentlyContinue).PlayerDebugMode
    if (-not $State.playerDebugMode) { $State.playerDebugMode = [pscustomobject]@{ key = $name; previous = $previous } }
    Set-ItemProperty -LiteralPath $key -Name PlayerDebugMode -Value '1' -Type String
    Write-Ok (T "Включён PlayerDebugMode для $name (HKCU)" "PlayerDebugMode enabled for $name (HKCU)")
}

function Install-LearnPanel {
    param($Install, $Payload, $State)
    $ext = Join-Path $Install.Path 'CEP\extensions\com.adobe.audition.Onboarding'
    if (-not (Test-Path -LiteralPath $ext)) { Write-Note (T 'Обучающей панели в этой версии нет — пропускаю' 'This version has no Learn panel - skipping'); return $false }
    $count = 0
    foreach ($f in @($Payload.Manifest.files | Where-Object { $_.type -like 'learn*' })) {
        $target = $f.target -replace '/', '\'
        $ruDir = Split-Path (Join-Path $Install.Path $target)
        $enDir = Join-Path (Split-Path $ruDir) 'en_us'
        if (-not (Test-Path -LiteralPath $enDir)) {
            Write-Note (T "Нет папки $enDir — пропускаю $($f.path)" "No $enDir - skipping $($f.path)")
            continue
        }
        $tmp = Join-Path $script:WorkTemp ([guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath (Join-Path $Payload.Dir ($f.path -replace '/', '\')) -Destination $tmp
        Publish-File -Install $Install -State $State -Target $target -TempPath $tmp -Group 'learn'
        $count++
        # Картинки-«штампы» нарисованы с английским текстом: берём их из en_us этой же версии.
        foreach ($svg in @(Get-ChildItem -LiteralPath $enDir -Filter *.svg -File -ErrorAction SilentlyContinue)) {
            $svgTarget = Join-Path (Split-Path $target) $svg.Name
            $tmp = Join-Path $script:WorkTemp ([guid]::NewGuid().ToString('N'))
            Copy-Item -LiteralPath $svg.FullName -Destination $tmp
            Publish-File -Install $Install -State $State -Target $svgTarget -TempPath $tmp -Group 'learn'
        }
    }
    if ($count) { Write-Ok (T "Обучающая панель: установлено файлов перевода — $count" "Learn panel: translation files installed - $count") }
    $count -gt 0
}

#endregion

#region Actions

function Install-DllPatch {
    param($Install, $State)
    $dll = Join-Path $Install.Path 'AuApplication.dll'
    $bytes = [IO.File]::ReadAllBytes($dll)
    $hit = Find-LocalePatch $bytes
    if ($hit.State -eq 'Patched') {
        if (-not $State.dll) {
            $orig = [byte[]]$bytes.Clone(); Set-LocalePatch $orig $hit -Undo
            $State.dll = [pscustomobject]@{ originalSha256 = Get-BytesSha256 $orig; patchedSha256 = Get-BytesSha256 $bytes; backup = $null }
        }
        Write-Ok (T 'AuApplication.dll уже исправлена' 'AuApplication.dll is already patched')
        return
    }
    if ($hit.State -ne 'Original') {
        throw (T "В этой версии AuApplication.dll не найдено место исправления ($($hit.Reason)). Эта версия Audition пока не поддерживается — сообщите о ней: https://github.com/$($script:Repo)/issues" "The patch location was not found in this AuApplication.dll ($($hit.Reason)). This Audition version is not supported yet - please report it: https://github.com/$($script:Repo)/issues")
    }
    $originalHash = Get-BytesSha256 $bytes
    $backupRel = 'backup\AuApplication.dll'
    $backup = Join-Path (Get-StateDir $Install) $backupRel
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $backup)
    if (-not (Test-Path -LiteralPath $backup) -or (Get-Sha256 $backup) -ne $originalHash) {
        [IO.File]::WriteAllBytes($backup, $bytes)
    }
    Set-LocalePatch $bytes $hit
    if ((Find-LocalePatch $bytes).State -ne 'Patched') { throw (T 'Проверка исправления не прошла.' 'Patch verification failed.') }
    $tmp = "$dll.ru-tmp"
    [IO.File]::WriteAllBytes($tmp, $bytes)
    Move-IntoPlace -Source $tmp -Destination $dll
    $State.dll = [pscustomobject]@{ originalSha256 = $originalHash; patchedSha256 = Get-BytesSha256 $bytes; backup = $backupRel }
    Write-Ok (T "AuApplication.dll исправлена (2 байта), оригинал сохранён в $($script:StateFolder)\$backupRel" "AuApplication.dll patched (2 bytes), original saved to $($script:StateFolder)\$backupRel")
}

function Restore-DllPatch {
    param($Install, $State)
    $dll = Join-Path $Install.Path 'AuApplication.dll'
    $bytes = [IO.File]::ReadAllBytes($dll)
    $hit = Find-LocalePatch $bytes
    if ($hit.State -eq 'Patched') {
        $current = Get-BytesSha256 $bytes
        $backup = if ($State -and $State.dll -and $State.dll.backup) { Join-Path (Get-StateDir $Install) $State.dll.backup } else { $null }
        if ($backup -and (Test-Path -LiteralPath $backup) -and $current -eq $State.dll.patchedSha256 -and (Get-Sha256 $backup) -eq $State.dll.originalSha256) {
            Copy-Item -LiteralPath $backup -Destination "$dll.ru-tmp" -Force
        } else {
            Set-LocalePatch $bytes $hit -Undo
            [IO.File]::WriteAllBytes("$dll.ru-tmp", $bytes)
        }
        Move-IntoPlace -Source "$dll.ru-tmp" -Destination $dll
        Write-Ok (T 'AuApplication.dll возвращена в исходное состояние' 'AuApplication.dll restored to its original state')
    } else {
        Write-Ok (T 'AuApplication.dll не исправлена — возвращать нечего' 'AuApplication.dll is not patched - nothing to restore')
    }
    if ($State -and $State.dll -and $State.dll.backup) {
        Remove-Item -LiteralPath (Join-Path (Get-StateDir $Install) $State.dll.backup) -Force -ErrorAction SilentlyContinue
    }
    if ($State) { $State.dll = $null }
}

function Test-RussianInstalled {
    param($Install)
    $dict = Join-Path $Install.Path 'dict\ru_RU\zdictionary_AUDT_ru_RU.dat'
    Test-Path -LiteralPath $dict
}

function Invoke-Install {
    param($Install)
    Write-Title (T "Установка русского языка — $($Install.Name) $($Install.Version)" "Installing Russian - $($Install.Name) $($Install.Version)")
    Wait-AuditionClosed $Install
    Remove-StaleFiles $Install.Path
    $payload = Get-Payload
    $m = $payload.Manifest
    if ($m.minAudition -and $Install.Version -lt [version]$m.minAudition) {
        throw (T "Перевод $($m.version) рассчитан на Audition $($m.minAudition) и новее." "Translation $($m.version) requires Audition $($m.minAudition) or later.")
    }
    $prev = Read-State $Install
    $state = New-State -Install $Install -Previous $prev
    $script:WorkTemp = Join-Path $script:CacheRoot ('work-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $script:WorkTemp
    try {
        # 1. Словари: собираются под установленную версию.
        $coverage = @()
        foreach ($f in @($m.files | Where-Object { $_.type -eq 'dictionary' })) {
            $english = Join-Path $Install.Path ($f.baseline -replace '/', '\')
            if (-not (Test-Path -LiteralPath $english)) { Write-Note (T "Нет $($f.baseline) — пропускаю" "Missing $($f.baseline) - skipping"); continue }
            $tmp = Join-Path $script:WorkTemp ([IO.Path]::GetFileName($f.target))
            $stat = Merge-ZDictionary -EnglishPath $english -RussianPath (Join-Path $payload.Dir ($f.path -replace '/', '\')) -OutPath $tmp
            Publish-File -Install $Install -State $state -Target ($f.target -replace '/', '\') -TempPath $tmp -Group 'core'
            $pct = if ($stat.Total) { [Math]::Floor(1000 * $stat.Translated / $stat.Total) / 10 } else { 0 }
            Write-Ok (T "$([IO.Path]::GetFileName($f.target)): переведено $($stat.Translated) из $($stat.Total) строк ($pct %)" "$([IO.Path]::GetFileName($f.target)): $($stat.Translated) of $($stat.Total) strings translated ($pct %)")
            $coverage += [pscustomobject]@{ file = [IO.Path]::GetFileName($f.target); total = $stat.Total; translated = $stat.Translated }
        }
        if (-not $coverage.Count) { throw (T 'Не установлен ни один словарь.' 'No dictionary was installed.') }
        $state.coverage = $coverage

        # 2. Справка F1: из английского файла этой версии.
        $helpDir = Join-Path $Install.Path 'HelpCfg\en_US'
        foreach ($h in @(Get-ChildItem -LiteralPath $helpDir -Filter *.helpcfg -File -ErrorAction SilentlyContinue)) {
            $text = Read-TextFile $h.FullName
            $text = $text.Replace('en_US', 'ru_RU')
            $text = [regex]::Replace($text, 'label="[^"]*Reference"', 'label="Справка по Audition"')
            $text = [regex]::Replace($text, '(helpmapPath|downloadPdf)="(?!ru/)', '$1="ru/')
            $tmp = Join-Path $script:WorkTemp $h.Name
            [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding $false))
            Publish-File -Install $Install -State $state -Target (Join-Path 'HelpCfg\ru_RU' $h.Name) -TempPath $tmp -Group 'core'
        }
        Write-Ok (T 'Справка (F1) настроена на helpx.adobe.com/ru' 'Help (F1) set to helpx.adobe.com/ru')

        # 3. AuApplication.dll: разрешить язык ru_RU.
        Install-DllPatch -Install $Install -State $state

        # 4. Обучающая панель (по желанию). Панель — подписанное расширение CEP: с добавленными
        #    файлами она открывается только при PlayerDebugMode=1, иначе «Недопустимая сигнатура».
        $learnInstalled = @($state.files | Where-Object { $_.group -eq 'learn' }).Count -gt 0
        $wantLearn = $LearnPanel -or $learnInstalled
        if (-not $wantLearn -and -not $Yes -and (Test-CanPrompt)) {
            Write-Host ''
            Write-Host (T '  Обучающая панель «Обучение Audition» — подписанное расширение Adobe. Чтобы она открывалась' '  The Audition Learn panel is a signed Adobe extension. To open it with the translation added,') -ForegroundColor Gray
            Write-Host (T '  с переводом, нужно включить PlayerDebugMode (HKCU\Software\Adobe\CSXS.*): Adobe CEP начнёт' '  PlayerDebugMode (HKCU\Software\Adobe\CSXS.*) must be enabled: Adobe CEP will then load') -ForegroundColor Gray
            Write-Host (T '  загружать изменённые и неподписанные панели. При удалении русификатора значение вернётся.' '  modified and unsigned panels. The value is restored when the Russian language is removed.') -ForegroundColor Gray
            $wantLearn = Read-YesNo -Question (T 'Установить перевод обучающей панели и включить PlayerDebugMode?' 'Install the Learn panel translation and enable PlayerDebugMode?') -Default $false
        }
        if ($wantLearn) {
            if (Install-LearnPanel -Install $Install -Payload $payload -State $state) {
                Set-PlayerDebugMode -Install $Install -State $state
            }
        }

        # 5. Язык интерфейса.
        Set-AmtLanguage -Dir $Install.Path -Locale 'ru_RU'
        $state.packVersion = [string]$m.version
        $state.auditionVersion = [string]$Install.Version
        Write-State -Install $Install -State $state
        Write-Ok (T 'Язык интерфейса: Русский (ru_RU)' 'Interface language: Russian (ru_RU)')
    } finally {
        Remove-Item -LiteralPath $script:WorkTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host ''
    Write-Ok (T "Готово. Запустите Adobe Audition — интерфейс будет на русском." "Done. Start Adobe Audition - the interface will be in Russian.")
    Write-Note (T 'Первый запуск после смены языка дольше обычного: Audition заново проверяет плагины.' 'The first start after a language change is slower: Audition rescans plug-ins.')
}

function Get-AvailableLocales {
    param($Install)
    $list = @(foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $Install.Path 'dict') -Directory -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath (Join-Path $d.FullName "zdictionary_AUDT_$($d.Name).dat")) { $d.Name }
    })
    if ('ru_RU' -notin $list) { $list += 'ru_RU' }
    @($list | Sort-Object { if ($_ -eq 'ru_RU') { 0 } elseif ($_ -eq 'en_US') { 1 } else { 2 } }, { $_ })
}

function Invoke-Switch {
    param($Install, [string]$Locale)
    $current = Get-AmtLanguage $Install.Path
    if (-not $Locale) {
        Write-Title (T 'Переключение языка интерфейса' 'Switching the interface language')
        Write-Host ((T '  Сейчас: ' '  Current: ') + (Get-LocaleName $current))
        $locales = Get-AvailableLocales $Install
        $items = @(foreach ($l in $locales) {
            $name = Get-LocaleName $l
            if ($l -eq 'ru_RU' -and -not (Test-RussianInstalled $Install)) { $name += (T '  — будет установлен' '  - will be installed') }
            $name
        })
        $default = [Math]::Max(1, [array]::IndexOf($locales, $(if ($current -eq 'ru_RU') { 'en_US' } else { 'ru_RU' })) + 1)
        $Locale = Read-Option -Question (T 'Выберите язык' 'Choose a language') -Items $items -Values $locales -Default $default -AllowZero -ZeroText (T 'Назад' 'Back')
        if (-not $Locale) { return }
    }
    if ($Locale -notmatch '^[a-z]{2}_[A-Z]{2}$') { throw (T "Неверный код языка: $Locale" "Invalid language code: $Locale") }
    if ($Locale -eq 'ru_RU' -and -not (Test-RussianInstalled $Install)) { Invoke-Install $Install; return }
    if ($Locale -ne 'ru_RU' -and $Locale -ne 'en_US' -and -not (Test-Path -LiteralPath (Join-Path $Install.Path "dict\$Locale\zdictionary_AUDT_$Locale.dat"))) {
        throw (T "Язык $Locale не установлен в этой копии Audition." "Language $Locale is not installed in this Audition copy.")
    }
    Wait-AuditionClosed $Install
    Remove-StaleFiles $Install.Path
    if ($Locale -eq 'ru_RU') {
        $state = New-State -Install $Install -Previous (Read-State $Install)
        Install-DllPatch -Install $Install -State $state
        Write-State -Install $Install -State $state
    }
    Set-AmtLanguage -Dir $Install.Path -Locale $Locale
    Write-Ok (T "Язык интерфейса: $(Get-LocaleName $Locale). Перезапустите Adobe Audition." "Interface language: $(Get-LocaleName $Locale). Restart Adobe Audition.")
    Write-Note (T 'Первый запуск после смены языка дольше обычного: Audition заново проверяет плагины.' 'The first start after a language change is slower: Audition rescans plug-ins.')
}

function Invoke-Restore {
    param($Install)
    Write-Title (T "Удаление русификатора — $($Install.Name) $($Install.Version)" "Removing the Russian language - $($Install.Name) $($Install.Version)")
    $state = Read-State $Install
    if (-not $state -and -not (Test-RussianInstalled $Install) -and (Get-PatchState $Install).State -ne 'Patched') {
        Write-Ok (T 'Русификатор не установлен — возвращать нечего.' 'The Russian language is not installed - nothing to restore.')
        return
    }
    if (-not (Read-YesNo -Question (T 'Удалить русский язык и вернуть всё как было?' 'Remove the Russian language and restore everything?') -Default $true)) { return }
    Wait-AuditionClosed $Install
    Remove-StaleFiles $Install.Path
    if (-not $state) {
        Write-Note (T 'Нет файла состояния: русский язык ставился не этим скриптом. Верну язык и DLL, файлы dict\ru_RU оставлю.' 'No state file: Russian was not installed by this script. Restoring the language and DLL, keeping dict\ru_RU files.')
    }
    # Сначала DLL и файлы, язык — последним: если что-то не удастся, язык и файлы не разойдутся.
    Restore-DllPatch -Install $Install -State $state
    if ($state) {
        Write-State -Install $Install -State $state
        Remove-PublishedFiles -Install $Install -State $state
        Write-State -Install $Install -State $state
        Set-PlayerDebugMode -Install $Install -State $state -Undo
    }
    $lang = if ($state -and $state.originalLanguage -and $state.originalLanguage -ne 'ru_RU') { $state.originalLanguage } else { 'en_US' }
    Set-AmtLanguage -Dir $Install.Path -Locale $lang
    Write-Ok (T "Язык интерфейса: $(Get-LocaleName $lang)" "Interface language: $(Get-LocaleName $lang)")
    if ($state) {
        $dir = Get-StateDir $Install
        Remove-Item -LiteralPath (Join-Path $dir 'state.json') -Force -ErrorAction SilentlyContinue
        $backupDir = Join-Path $dir 'backup'
        if ((Test-Path -LiteralPath $backupDir) -and -not @(Get-ChildItem -LiteralPath $backupDir -Recurse -File -Force).Count) { Remove-Item -LiteralPath $backupDir -Recurse -Force }
        if ((Test-Path -LiteralPath $dir) -and -not @(Get-ChildItem -LiteralPath $dir -Force).Count) { Remove-Item -LiteralPath $dir -Force }
        Write-Ok (T 'Файлы русификатора удалены, прежние файлы возвращены' 'Russian files removed, previous files restored')
    }
    Write-Host ''
    Write-Ok (T 'Готово. Adobe Audition возвращён в исходное состояние.' 'Done. Adobe Audition is back to its original state.')
}

function Show-Status {
    param($Install)
    $state = Read-State $Install
    $lang = Get-AmtLanguage $Install.Path
    $patch = Get-PatchState $Install
    $running = @(Get-AuditionProcess $Install.Path).Count -gt 0
    Write-Title "$($Install.Name) $($Install.Version)"
    Write-Host ((T '  Папка:              ' '  Folder:             ') + $Install.Path)
    Write-Host ((T '  Язык интерфейса:    ' '  Interface language: ') + $(if ($lang) { Get-LocaleName $lang } else { T 'не задан' 'not set' }))
    $ru = if ($state -and $state.packVersion) {
        $cov = @($state.coverage | ForEach-Object { if ($_.total) { '{0} {1:N1} %' -f $_.file, (100.0 * $_.translated / $_.total) } }) -join ', '
        (T "установлен, версия $($state.packVersion) ($cov)" "installed, version $($state.packVersion) ($cov)")
    } elseif (Test-RussianInstalled $Install) { T 'файлы есть, но установлены не этим скриптом' 'files present, but not installed by this script' }
    else { T 'не установлен' 'not installed' }
    Write-Host ((T '  Русификатор:        ' '  Russian language:   ') + $ru)
    $patchText = switch ($patch.State) {
        'Patched'  { T 'применено' 'applied' }
        'Original' { T 'не применено (исходная DLL)' 'not applied (original DLL)' }
        default    { T "место не найдено: $($patch.Reason)" "location not found: $($patch.Reason)" }
    }
    Write-Host ((T '  Исправление DLL:    ' '  DLL patch:          ') + $patchText)
    $learn = if ($state -and @($state.files | Where-Object { $_.group -eq 'learn' }).Count) { T 'установлена' 'installed' } else { T 'не установлена' 'not installed' }
    Write-Host ((T '  Обучающая панель:   ' '  Learn panel:        ') + $learn)
    Write-Host ((T '  Audition запущен:   ' '  Audition running:   ') + $(if ($running) { T 'да' 'yes' } else { T 'нет' 'no' }))
    if ($lang -eq 'ru_RU' -and $patch.State -eq 'Original') {
        Write-Note (T 'Язык ru_RU выбран, но DLL не исправлена (обычно после обновления Audition) — выполните установку ещё раз.' 'ru_RU is selected but the DLL is not patched (usually after an Audition update) - run the installation again.')
    }
    if ($state -and $state.auditionVersion -and $state.auditionVersion -ne [string]$Install.Version) {
        Write-Note (T "Русификатор ставился на версию $($state.auditionVersion), сейчас $($Install.Version) — выполните установку ещё раз." "The Russian language was installed for $($state.auditionVersion), now $($Install.Version) - run the installation again.")
    }
}

function Show-Menu {
    param($Install)
    while ($true) {
        Show-Status $Install
        $items = @(
            (T 'Установить / обновить русский язык' 'Install / update Russian'),
            (T 'Переключить язык интерфейса' 'Switch the interface language'),
            (T 'Удалить русификатор (вернуть как было)' 'Remove the Russian language (restore original)')
        )
        $choice = Read-Option -Question (T 'Что сделать' 'What to do') -Items $items -Values @('Install', 'Switch', 'Restore') -Default 1 -AllowZero -ZeroText (T 'Выход' 'Exit')
        if (-not $choice) { return }
        try {
            switch ($choice) {
                'Install' { Invoke-Install $Install }
                'Switch'  { Invoke-Switch $Install }
                'Restore' { Invoke-Restore $Install }
            }
        } catch {
            Write-Fail $_.Exception.Message
        }
        $Install = Get-AuditionInfo -Dir $Install.Path
    }
}

#endregion

#region Main

$exitCode = 0
try {
    Write-Host ''
    Write-Host (T '  AdobeAudition-RU — русский язык для Adobe Audition 2026+' '  AdobeAudition-RU - Russian language for Adobe Audition 2026+') -ForegroundColor Cyan
    if ($Action -ne 'Status' -and -not (Test-Admin)) {
        Restart-Elevated -Parameters $PSBoundParameters
    } else {
        $install = Select-Audition
        switch ($Action) {
            'Menu'    { Show-Menu $install }
            'Install' { Invoke-Install $install }
            'Switch'  { Invoke-Switch -Install $install -Locale $Language }
            'Restore' { Invoke-Restore $install }
            'Status'  { Show-Status $install }
        }
    }
} catch {
    Write-Fail $_.Exception.Message
    $exitCode = 1
    $script:PauseOnExit = $script:PauseOnExit -or (Test-CanPrompt)
} finally {
    Wait-BeforeExit
}
# При запуске через «irm | iex» exit закрыл бы окно пользователя.
if ($script:ScriptPath) { exit $exitCode }

#endregion
