<#
.SYNOPSIS
    Router: читает build_spec.txt и устанавливает Axxon-софт по флагам.

    Маппинг флагов build_spec:
        axxonsoft = i | x | a    (Intellect classic / IntellectX / Axxon Next)
        axxonsoft_install = s | c | f | cs | cf
            s  = server
            c  = client
            f  = raft-server (failover)
            cs = server + client
            cf = raft-server + client
        axxon_LS  = TRUE | FALSE  (License Server - отдельная тулза)

    Реальный installer вызывается готовый:
        D:\intellect\install_intellect.ps1   -ConfigFile <json>
        D:\intellectx\install_intellectx.ps1 -ConfigFile <json>

    Этот скрипт - только роутер: парсит build_spec, выбирает нужный
    JSON-конфиг и вызывает соответствующий install_*.ps1.

    При отсутствии build_spec / секции axxonsoft - ничего не делает (exit 0).
    При отсутствии нужного JSON-конфига - логирует понятную ошибку и
    продолжает (exit 0), не валит весь pipeline.

.PARAMETER UsbRoot
    Корень USB-флешки (Ventoy/TestISO). Обязательный.

.PARAMETER ConfigPath
    Явный путь к файлу конфигурации. Если задан - используется как есть,
    auto-discovery пропускается. Удобно для тестов.

.PARAMETER ConfigDir
    Папка где искать SL*.txt. По умолчанию <UsbRoot>\config.

.PARAMETER ConfigRelPath
    Legacy: относительный путь к build_spec.txt. Если задан явно, имеет
    приоритет над auto-discovery. По умолчанию пусто (= auto-discovery).

.PARAMETER IntellectRoot
    Папка с install_intellect.ps1 + configs\. По умолчанию <UsbRoot>\intellect.

.PARAMETER IntellectXRoot
    Папка с install_intellectx.ps1 + configs\. По умолчанию <UsbRoot>\intellectx.

.PARAMETER DryRun
    Распарсить + показать что бы вызвал, но НЕ вызывать install_*.ps1.

.PARAMETER LogPath
    Куда писать лог. По умолчанию C:\ProgramData\IPDROM\Logs\install_axxon_<timestamp>.log.

.EXAMPLE
    # Авто-discovery: ищет SL*-*.txt в D:\config\, fallback на build_spec.txt
    .\Install-AxxonByBuildSpec.ps1 -UsbRoot D:\
    .\Install-AxxonByBuildSpec.ps1 -UsbRoot D:\ -DryRun

.EXAMPLE
    # Явный путь к файлу (для тестов)
    .\Install-AxxonByBuildSpec.ps1 -UsbRoot D:\ -ConfigPath C:\temp\SL111111-001.txt -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UsbRoot,
    [string]$ConfigPath,
    [string]$ConfigDir,
    [string]$ConfigRelPath,
    [string]$IntellectRoot,
    [string]$IntellectXRoot,
    [switch]$DryRun,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

# ===================== DEFAULTS =====================
if (-not $IntellectRoot)  { $IntellectRoot  = Join-Path $UsbRoot 'intellect'  }
if (-not $IntellectXRoot) { $IntellectXRoot = Join-Path $UsbRoot 'intellectx' }
if (-not $ConfigDir)      { $ConfigDir      = Join-Path $UsbRoot 'config'    }
if (-not $LogPath) {
    $logDir = Join-Path $env:ProgramData 'IPDROM\Logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $LogPath = Join-Path $logDir ("install_axxon_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}

function Write-Log {
    param([string]$Msg, [string]$Color = 'White')
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
    Write-Host $Msg -ForegroundColor $Color
    try { $line | Out-File -FilePath $LogPath -Encoding utf8 -Append } catch {}
}

Write-Log "=== Install-AxxonByBuildSpec started ===" 'Cyan'
Write-Log "UsbRoot:        $UsbRoot"
Write-Log "ConfigRelPath:  $ConfigRelPath"
Write-Log "IntellectRoot:  $IntellectRoot"
Write-Log "IntellectXRoot: $IntellectXRoot"
Write-Log "DryRun:         $DryRun"
Write-Log "LogPath:        $LogPath" 'Gray'

# ===================== INI PARSER =====================
# Тот же подход что в apply_build_spec.ps1: key=value, # - комментарий.
function Read-BuildSpec {
    param([Parameter(Mandatory)][string]$Path)
    $result = @{}
    foreach ($raw in (Get-Content -LiteralPath $Path -ErrorAction Stop)) {
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

# ===================== FIND CONFIG FILE =====================
# Приоритет:
#   1. -ConfigPath <full path>            (явно указанный файл)
#   2. -ConfigRelPath <rel to UsbRoot>    (legacy override)
#   3. Auto-discovery в $ConfigDir:
#        a) SL*-*.txt (новый формат, имя совпадает с серийником)
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

    # a) SL*.txt с проверкой regex.
    # Допускаем: SL111111-001.txt (production), SLTEST99-001.txt (тестовые),
    # SL111111-001 1.txt (Windows-дубликаты). \w = [A-Za-z0-9_].
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

    # b) Legacy: build_spec.txt
    $legacy = Join-Path $Dir 'build_spec.txt'
    if (Test-Path -LiteralPath $legacy) {
        Write-Log "No SL*-*.txt found in $Dir, using legacy build_spec.txt." 'Gray'
        return $legacy
    }

    return $null
}

$configPath = Resolve-ConfigPath -Explicit $ConfigPath -RelPath $ConfigRelPath -Dir $ConfigDir -RootDir $UsbRoot
if (-not $configPath) {
    Write-Log "No config file found - nothing to install." 'Yellow'
    Write-Log "Tried: explicit=$ConfigPath, rel=$ConfigRelPath, dir=$ConfigDir (SL*-*.txt or build_spec.txt)" 'Gray'
    Write-Log "=== Install-AxxonByBuildSpec finished (no config) ===" 'Gray'
    exit 0
}

Write-Log "Config: $configPath" 'Green'

try {
    $spec = Read-BuildSpec -Path $configPath
} catch {
    Write-Log "Failed to parse $configPath - $_" 'Red'
    Write-Log "Continuing without Axxon install (non-fatal)." 'Yellow'
    exit 0
}
Write-Log "Parsed $($spec.Count) key(s) from config." 'Gray'

# Извлекаем нужные ключи. Все необязательны - если их нет, просто выходим.
$axxonsoft   = if ($spec.ContainsKey('axxonsoft'))         { $spec['axxonsoft'].ToLower().Trim() }       else { $null }
$axxonInst   = if ($spec.ContainsKey('axxonsoft_install')) { $spec['axxonsoft_install'].ToLower().Trim() } else { $null }
$axxonLS     = if ($spec.ContainsKey('axxon_LS'))          { $spec['axxon_LS'].ToUpper().Trim() }         else { $null }

Write-Log "axxonsoft         = $axxonsoft"
Write-Log "axxonsoft_install = $axxonInst"
Write-Log "axxon_LS          = $axxonLS"

# ===================== MAPPING TABLE =====================
# Возвращает массив hashtable: каждый элемент - один installer call.
# Один build_spec может потребовать 1 или 2 прогона (например, cs = server + client).
function Resolve-InstallPlan {
    param(
        [string]$Software,   # i | x | a
        [string]$InstallVar  # s | c | f | cs | cf
    )

    $plan = @()

    if ([string]::IsNullOrWhiteSpace($Software)) {
        return $plan   # axxonsoft не задан - ничего не ставим
    }

    if ($Software -eq 'a') {
        # Axxon Next пока нет инсталлятора - пропускаем со стандартным сообщением.
        $plan += @{
            Action  = 'SKIP'
            Reason  = 'Axxon Next installer not implemented yet (axxonsoft=a)'
        }
        return $plan
    }

    if ($Software -notin @('i','x')) {
        $plan += @{
            Action = 'SKIP'
            Reason = "Unknown axxonsoft value: '$Software' (expected i|x|a)"
        }
        return $plan
    }

    if ([string]::IsNullOrWhiteSpace($InstallVar)) {
        $plan += @{
            Action = 'SKIP'
            Reason = "axxonsoft=$Software set but axxonsoft_install missing"
        }
        return $plan
    }

    # ----- Маппинг ниже. Файлы указаны относительно <IntellectRoot>/<IntellectXRoot>. -----
    if ($Software -eq 'i') {
        # Intellect classic
        switch ($InstallVar) {
            's'  { $plan += @{ Action='RUN'; Script='install_intellect.ps1'; Config='configs\server.json';   Family='intellect' }; break }
            'c'  { $plan += @{ Action='RUN'; Script='install_intellect.ps1'; Config='configs\client.json';   Family='intellect' }; break }
            'cs' {
                # Нет single combined config для classic. Two-pass: server потом client.
                # ВАЖНО: server.json у classic уже ставит и серверную и клиентскую часть,
                # поэтому второй прогон с client.json может ругнуться "уже установлено".
                # На усмотрение оператора - пока делаем только server.json и логируем.
                $plan += @{ Action='RUN'; Script='install_intellect.ps1'; Config='configs\server.json';   Family='intellect'; Note='classic CS: server.json covers both Server+Client per product behavior' }
            }
            'f'  {
                $plan += @{ Action='SKIP'; Reason='No raftserver config for classic Intellect. Add intellect\configs\raftserver.json or fix build_spec.' }
            }
            'cf' {
                $plan += @{ Action='SKIP'; Reason='No raftserver+client config for classic Intellect. Add intellect\configs\raftclient.json.' }
            }
            default {
                $plan += @{ Action='SKIP'; Reason="Unknown axxonsoft_install '$InstallVar' for Intellect classic (expected s|c|cs|f|cf)" }
            }
        }
    } elseif ($Software -eq 'x') {
        # IntellectX
        switch ($InstallVar) {
            's'  {
                # Нет pure server config для X - есть только raftserver и serverclient.
                $plan += @{ Action='SKIP'; Reason='No pure-server config for IntellectX. Use s=cs (serverclient) or s=f (raftserver), or add intellectx\configs\server.json.' }
            }
            'c'  { $plan += @{ Action='RUN'; Script='install_intellectx.ps1'; Config='configs\client.json';       Family='intellectx' }; break }
            'cs' { $plan += @{ Action='RUN'; Script='install_intellectx.ps1'; Config='configs\serverclient.json'; Family='intellectx' }; break }
            'f'  { $plan += @{ Action='RUN'; Script='install_intellectx.ps1'; Config='configs\raftserver.json';   Family='intellectx' }; break }
            'cf' {
                # Two-pass для IntellectX: raftserver затем client.
                $plan += @{ Action='RUN'; Script='install_intellectx.ps1'; Config='configs\raftserver.json'; Family='intellectx' }
                $plan += @{ Action='RUN'; Script='install_intellectx.ps1'; Config='configs\client.json';     Family='intellectx' }
            }
            default {
                $plan += @{ Action='SKIP'; Reason="Unknown axxonsoft_install '$InstallVar' for IntellectX (expected s|c|cs|f|cf)" }
            }
        }
    }

    return $plan
}

# ===================== BUILD PLAN =====================
Write-Log "Building install plan..." 'Yellow'
# @(...) ОБЯЗАТЕЛЕН: PowerShell разворачивает функцию-возвращающую-массив-из-одного-элемента
# обратно в этот элемент. Если plan содержит 1 hashtable, без @() $plan станет hashtable,
# и $plan.Count вернёт число ключей (4), а $plan[$i] вернёт null - получим N SKIP без причин.
$plan = @(Resolve-InstallPlan -Software $axxonsoft -InstallVar $axxonInst)

if ($plan.Count -eq 0) {
    Write-Log "No Axxon software requested (axxonsoft not set). Skipping." 'Gray'
} else {
    Write-Log "Install plan: $($plan.Count) step(s)." 'Cyan'
    for ($i = 0; $i -lt $plan.Count; $i++) {
        $step = $plan[$i]
        if ($step.Action -eq 'RUN') {
            $rootDir = if ($step.Family -eq 'intellect') { $IntellectRoot } else { $IntellectXRoot }
            $scriptPath = Join-Path $rootDir $step.Script
            $cfgPath    = Join-Path $rootDir $step.Config
            Write-Log ("  [{0}] RUN  {1} -ConfigFile {2}" -f ($i+1), $scriptPath, $cfgPath) 'Gray'
            if ($step.ContainsKey('Note')) { Write-Log ("       note: $($step.Note)") 'DarkGray' }
        } else {
            Write-Log ("  [{0}] SKIP {1}" -f ($i+1), $step.Reason) 'Yellow'
        }
    }
}

# License Server отдельно.
$lsPlan = @()
if ($axxonLS -eq 'TRUE') {
    # ЗАГЛУШКА: пока нет инсталлятора License Server.
    # Когда появится: положить D:\axxonls\install_axxonls.ps1 (или подобное)
    # и добавить сюда вызов аналогичный intellect/intellectx.
    $lsPlan += @{
        Action = 'SKIP'
        Reason = 'axxon_LS=TRUE: License Server installer not implemented yet. Add <UsbRoot>\axxonls\install_axxonls.ps1 and update this router.'
    }
}
foreach ($step in $lsPlan) {
    Write-Log ("  [LS]  SKIP {0}" -f $step.Reason) 'Yellow'
}

# ===================== EXECUTE =====================
if ($DryRun) {
    Write-Log "DryRun: plan shown above, NOT executing." 'Yellow'
    Write-Log "=== Install-AxxonByBuildSpec finished (dry-run) ===" 'Cyan'
    exit 0
}

$execSteps = @($plan | Where-Object { $_.Action -eq 'RUN' })
if ($execSteps.Count -eq 0) {
    Write-Log "Nothing to execute (all steps skipped or no plan)." 'Gray'
    Write-Log "=== Install-AxxonByBuildSpec finished (nothing to do) ===" 'Cyan'
    exit 0
}

$stepIdx = 0
$failures = 0
foreach ($step in $execSteps) {
    $stepIdx++
    $rootDir   = if ($step.Family -eq 'intellect') { $IntellectRoot } else { $IntellectXRoot }
    $scriptPath = Join-Path $rootDir $step.Script
    $cfgPath    = Join-Path $rootDir $step.Config

    Write-Log "" 'White'
    Write-Log "===== Step $stepIdx/$($execSteps.Count): $($step.Family) =====" 'Cyan'
    Write-Log "Script: $scriptPath" 'Gray'
    Write-Log "Config: $cfgPath" 'Gray'

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-Log "Install script NOT FOUND: $scriptPath - skipping step." 'Red'
        $failures++
        continue
    }
    if (-not (Test-Path -LiteralPath $cfgPath)) {
        Write-Log "Config file NOT FOUND: $cfgPath - skipping step." 'Red'
        $failures++
        continue
    }

    try {
        # Не используем '& $scriptPath', чтобы избежать особенностей dot-sourcing.
        # PowerShell.exe в отдельном процессе - чище, и exit code ловится через $LASTEXITCODE.
        $pwshArgs = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', $scriptPath,
            '-ConfigFile', $cfgPath
        )
        Write-Log "Invoking: powershell.exe $($pwshArgs -join ' ')" 'DarkGray'
        & powershell.exe @pwshArgs
        $rc = $LASTEXITCODE
        if ($rc -ne 0) {
            Write-Log "Step exited with code $rc (non-zero)." 'Red'
            $failures++
        } else {
            Write-Log "Step completed OK." 'Green'
        }
    } catch {
        Write-Log "Step threw exception: $_" 'Red'
        $failures++
    }
}

Write-Log "" 'White'
if ($failures -gt 0) {
    Write-Log "=== Install-AxxonByBuildSpec finished with $failures failure(s) out of $($execSteps.Count) step(s) ===" 'Red'
    exit 1
} else {
    Write-Log "=== Install-AxxonByBuildSpec finished OK ($($execSteps.Count) step(s) executed) ===" 'Green'
    exit 0
}
