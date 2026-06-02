<#
.SYNOPSIS
    Добавляет в ОС поддержку SNMP (нужно для Supermicro SuperDoctor и мониторинга).

    Ставит две Windows-capability:
      - SNMP.Client                  (сам SNMP-сервис/протокол)
      - WMI-SNMP-Provider.Client     (WMI-провайдер SNMP)

    Идемпотентно: если capability уже Installed - пропускает.
    Graceful: если установка не удалась (нет источника/интернета) - пишет
    предупреждение, но НЕ роняет сборку (exit 0).

.NOTES
    Add-WindowsCapability работает на ОНЛАЙН-системе (в FirstLogon - ок).
    Может требовать доступ к Windows Update / source, если capability не
    встроена в образ. На IoT Enterprise обычно доступна локально.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

# ===================== LOG =====================
$logDir  = Join-Path $env:ProgramData 'IPDROM\Logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir ("install_snmp_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function Write-Log {
    param([string]$Msg, [string]$Color = 'White')
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
    try { $line | Out-File -FilePath $logFile -Encoding utf8 -Append } catch {}
    Write-Host $Msg -ForegroundColor $Color
}

Write-Log "=== install_snmp started ===" 'Cyan'

$caps = @(
    'SNMP.Client~~~~0.0.1.0',
    'WMI-SNMP-Provider.Client~~~~0.0.1.0'
)

foreach ($cap in $caps) {
    try {
        $state = (Get-WindowsCapability -Online -Name $cap -ErrorAction Stop).State
    } catch {
        Write-Log "Cannot query capability '$cap': $_" 'Yellow'
        $state = 'Unknown'
    }

    if ($state -eq 'Installed') {
        Write-Log "Already installed: $cap" 'Green'
        continue
    }

    Write-Log "Installing capability: $cap (current state: $state)..." 'Yellow'
    try {
        $r = Add-WindowsCapability -Online -Name $cap -ErrorAction Stop
        Write-Log "  Added: $cap" 'Green'
        if ($r.RestartNeeded) { Write-Log "  (restart will be needed - handled by setup's reboot)" 'Gray' }
    } catch {
        Write-Log "  FAILED to add $cap`: $_" 'Red'
        Write-Log "  Non-fatal - continuing. SNMP may need manual install / source." 'Yellow'
    }
}

# Проверка итогового состояния (для лога).
Write-Log "Final SNMP capability state:" 'Gray'
foreach ($cap in $caps) {
    try {
        $st = (Get-WindowsCapability -Online -Name $cap -ErrorAction Stop).State
        Write-Log ("  {0} = {1}" -f $cap, $st) 'Gray'
    } catch {}
}

# Если SNMP-служба появилась - переключаем на автозапуск и стартуем,
# чтобы SuperDoctor сразу видел рабочий SNMP. Не критично если службы нет.
try {
    $svc = Get-Service -Name 'SNMP' -ErrorAction SilentlyContinue
    if ($svc) {
        Set-Service -Name 'SNMP' -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name 'SNMP' -ErrorAction SilentlyContinue
        Write-Log "SNMP service set to Automatic and started." 'Green'
    } else {
        Write-Log "SNMP service not present yet (may appear after reboot)." 'Gray'
    }
} catch {
    Write-Log "Could not configure SNMP service: $_" 'Yellow'
}

Write-Log "=== install_snmp finished ===" 'Cyan'
exit 0
