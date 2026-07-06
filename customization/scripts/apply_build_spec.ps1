<#
.SYNOPSIS
    Читает build_spec.txt с USB-флешки и применяет параметры к системе.

    Этап 1: только computer_name (Rename-Computer).
    Формат файла - INI-стиль "ключ=значение", строки с # игнорируются.

    Поведение при отсутствии файла/поля: НИЧЕГО не меняет, выходит с кодом 0.
    Это осознанный выбор - без конфига система ведёт себя как раньше
    (случайное имя из autounattend.xml).

.PARAMETER UsbRoot
    Корень USB-флешки (где лежит папка config). Обязательный.

.PARAMETER ConfigPath
    Явный путь к файлу конфигурации. Если задан - используется как есть.

.PARAMETER ConfigDir
    Папка где искать SL*.txt. По умолчанию <UsbRoot>\config.

.PARAMETER ConfigRelPath
    Legacy: относительный путь к build_spec.txt относительно UsbRoot.
    Если задан явно, имеет приоритет над auto-discovery.

.PARAMETER NoRename
    Распарсить и залогировать, но НЕ применять Rename-Computer (dry-run).

.NOTES
    Rename-Computer вызывается БЕЗ -Restart: имя ставится в очередь и
    применяется при следующей штатной перезагрузке (которую делает
    setup_apps_and_theme.ps1 в конце). Двойного ребута нет.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UsbRoot,
    [string]$ConfigPath,
    [string]$ConfigDir,
    [string]$ConfigRelPath,
    [switch]$NoRename
)

if (-not $ConfigDir) { $ConfigDir = Join-Path $UsbRoot 'config' }

$ErrorActionPreference = 'Stop'

# ===================== LOG =====================
$logDir  = Join-Path $env:ProgramData 'IPDROM\Logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir ("apply_build_spec_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function Write-Log {
    param([string]$Msg, [string]$Color = 'White')
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
    try { $line | Out-File -FilePath $logFile -Encoding utf8 -Append } catch {}
    Write-Host $Msg -ForegroundColor $Color
}

Write-Log "=== apply_build_spec started ===" 'Cyan'
Write-Log "UsbRoot: $UsbRoot"

# ===================== ПАРСЕР INI =====================
# Возвращает hashtable ключ->значение. Игнорирует пустые строки и комментарии (#).
function Read-BuildSpec {
    param([Parameter(Mandatory)][string]$Path)
    $result = @{}
    # build_spec может быть в UTF-8 (с/без BOM) или ANSI. Get-Content авто-определит BOM;
    # для строк с кириллицей в значениях это не критично (имя ПК - ASCII).
    # КРИТИЧНО: -Encoding UTF8. PS5.1 по дефолту читает как ANSI, кириллица в SL ломается.
    foreach ($raw in (Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop)) {
        $line = $raw.Trim()
        if ($line -eq '') { continue }
        if ($line.StartsWith('#')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $line.Substring(0, $eq).Trim()
        $val = $line.Substring($eq + 1).Trim()
        $result[$key] = $val
    }
    return $result
}

# ===================== ВАЛИДАЦИЯ ИМЕНИ ПК =====================
# Требования Windows к NetBIOS computer name:
#   1..15 символов, без пробелов, без символов \/:*?"<>|.
function Test-ComputerName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name.Length -gt 15) { return $false }
    if ($Name -match '[\\/:*?"<>|. ]') { return $false }
    # не только цифры (Windows не любит чисто числовые имена)
    if ($Name -match '^\d+$') { return $false }
    return $true
}

# ===================== ПОИСК ФАЙЛА КОНФИГА =====================
# Приоритет:
#   1. -ConfigPath <abs path>      (явный override для тестов)
#   2. -ConfigRelPath <rel path>   (legacy override относительно UsbRoot)
#   3. Auto-discovery в $ConfigDir:
#        a) SL<digits>-<digits>.txt (новый формат, имя совпадает с серийником;
#           допускаем " 1" суффикс от Windows-дубликатов)
#        b) build_spec.txt (legacy fallback)
function Resolve-ConfigPath {
    param([string]$Explicit, [string]$RelPath, [string]$Dir, [string]$RootDir)

    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit) { return $Explicit }
        Write-Log "Explicit -ConfigPath not found: $Explicit" 'Red'
        return $null
    }
    if ($RelPath) {
        $p = Join-Path $RootDir $RelPath
        if (Test-Path -LiteralPath $p) { return $p }
        Write-Log "Explicit -ConfigRelPath not found: $p" 'Red'
        return $null
    }
    if (-not (Test-Path -LiteralPath $Dir)) {
        Write-Log "Config dir does not exist: $Dir" 'Yellow'
        return $null
    }

    # Допускаем: SL111111-001.txt (production), SLTEST99-001.txt (тестовые),
    # SL111111-001.txt (Windows-дубликаты). \w = [A-Za-z0-9_].
    $slCandidates = @(Get-ChildItem -Path $Dir -Filter 'SL*.txt' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^SL\w+-\w+(\s+\d+)?\.txt$' } |
        Sort-Object LastWriteTime -Descending)
    if ($slCandidates.Count -ge 1) {
        if ($slCandidates.Count -gt 1) {
            Write-Log "Found $($slCandidates.Count) SL*-*.txt files in $Dir - taking newest:" 'Yellow'
            foreach ($c in $slCandidates) {
                Write-Log ("  - {0}  ({1})" -f $c.Name, $c.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')) 'Gray'
            }
        }
        return $slCandidates[0].FullName
    }

    $legacy = Join-Path $Dir 'build_spec.txt'
    if (Test-Path -LiteralPath $legacy) {
        Write-Log "No SL*-*.txt found in $Dir, using legacy build_spec.txt." 'Gray'
        return $legacy
    }
    return $null
}

$configPath = Resolve-ConfigPath -Explicit $ConfigPath -RelPath $ConfigRelPath -Dir $ConfigDir -RootDir $UsbRoot
if (-not $configPath) {
    Write-Log "No config file found - nothing to apply (using defaults)." 'Yellow'
    Write-Log "Tried: explicit=$ConfigPath, rel=$ConfigRelPath, dir=$ConfigDir (SL*-*.txt or build_spec.txt)" 'Gray'
    Write-Log "=== apply_build_spec finished (no config) ===" 'Gray'
    exit 0
}

Write-Log "Config: $configPath" 'Green'

try {
    $spec = Read-BuildSpec -Path $configPath
} catch {
    Write-Log "Failed to parse config: $_" 'Red'
    Write-Log "Continuing with defaults (config parse error is non-fatal)." 'Yellow'
    exit 0
}

Write-Log "Parsed $($spec.Count) key(s) from config." 'Gray'

# --- Имя компьютера ---
# Реальный build_spec (Linux-формат) НЕ содержит computer_name, но содержит sn.
# Источник имени по приоритету:
#   1. computer_name (если когда-нибудь добавят явное поле)
#   2. sn            (серийник, напр. SL833415-001 - уникален, влезает в 15 символов)
$cfgName    = $null
$nameSource = $null
if ($spec.ContainsKey('computer_name') -and -not [string]::IsNullOrWhiteSpace($spec['computer_name'])) {
    $cfgName    = $spec['computer_name'].Trim()
    $nameSource = 'computer_name'
} elseif ($spec.ContainsKey('sn') -and -not [string]::IsNullOrWhiteSpace($spec['sn'])) {
    $cfgName    = $spec['sn'].Trim()
    $nameSource = 'sn'
}

if ([string]::IsNullOrWhiteSpace($cfgName)) {
    Write-Log "Neither computer_name nor sn set in config - keeping random name." 'Yellow'
} elseif (-not (Test-ComputerName -Name $cfgName)) {
    Write-Log "Name '$cfgName' (from $nameSource) is INVALID (max 15 chars, no spaces/special, not all-digits)." 'Red'
    Write-Log "Keeping random name to avoid breaking the build." 'Yellow'
} else {
    $current = $env:COMPUTERNAME
    if ($current -ieq $cfgName) {
        Write-Log "Computer already named '$cfgName' - no rename needed." 'Green'
    } elseif ($NoRename) {
        Write-Log "[dry-run] Would rename '$current' -> '$cfgName' (from $nameSource, NoRename set)." 'Yellow'
    } else {
        try {
            # БЕЗ -Restart: имя применится при штатном Restart-Computer в setup.
            Rename-Computer -NewName $cfgName -Force -ErrorAction Stop
            Write-Log "Computer rename queued: '$current' -> '$cfgName' (from $nameSource, applies on next reboot)." 'Green'
        } catch {
            Write-Log "Rename-Computer failed: $_" 'Red'
            Write-Log "Keeping current name (rename failure is non-fatal)." 'Yellow'
        }
    }
}

# --- метка сборки (sn / model) для удобства: пишем в лог и реестр ---
# Не критично, но полезно видеть для какого заказа собрана машина.
foreach ($k in @('sn','model')) {
    if ($spec.ContainsKey($k) -and -not [string]::IsNullOrWhiteSpace($spec[$k])) {
        Write-Log "build_spec.$k = $($spec[$k])" 'Gray'
        try {
            $regPath = 'HKLM:\SOFTWARE\IPDROM\BuildSpec'
            if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
            Set-ItemProperty -Path $regPath -Name $k -Value $spec[$k] -ErrorAction Stop
        } catch {
            Write-Log "  (could not write $k to registry: $_)" 'DarkGray'
        }
    }
}

Write-Log "=== apply_build_spec finished ===" 'Cyan'
exit 0
