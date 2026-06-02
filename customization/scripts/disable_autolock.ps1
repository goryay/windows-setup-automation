<#
.SYNOPSIS
    Отключает автоматическую блокировку экрана (lock screen) по бездействию.

    Причины «выкидывания на lock screen»:
      1. Machine inactivity limit (InactivityTimeoutSecs) - блокирует сессию
         после N секунд без ввода.
      2. Скринсейвер с "On resume, display logon screen" (ScreenSaverIsSecure).
      3. Lock screen как таковой.

    Для стенда/сервера всё это не нужно - машина должна оставаться залогиненной.

.NOTES
    HKCU-настройки применяются к текущему пользователю (под которым идёт
    FirstLogon - IPDROM). HKLM/Policies - машинные, на всех.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$logDir = Join-Path $env:ProgramData 'IPDROM\Logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir ("disable_autolock_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
function Write-Log {
    param([string]$Msg, [string]$Color = 'White')
    "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg | Out-File -FilePath $logFile -Encoding utf8 -Append
    Write-Host $Msg -ForegroundColor $Color
}

Write-Log "=== disable_autolock started ===" 'Cyan'

# 1. Машинный лимит бездействия = 0 (никогда не блокировать сессию по простою).
#    Это главная причина авто-выхода на lock screen.
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v InactivityTimeoutSecs /t REG_DWORD /d 0 /f | Out-Null
Write-Log "InactivityTimeoutSecs = 0 (no auto-lock on idle)" 'Green'

# 2. Не требовать пароль при пробуждении (на случай если сон всё же случится).
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v DisableLockWorkstation /t REG_DWORD /d 1 /f | Out-Null
Write-Log "DisableLockWorkstation = 1 (Win+L / auto-lock blocked)" 'Green'

# 3. Скринсейвер - выключить и снять "secure" (не требовать вход после него).
#    HKCU = текущий пользователь (IPDROM под которым идёт настройка).
reg.exe add "HKCU\Control Panel\Desktop" /v ScreenSaveActive   /t REG_SZ /d 0 /f | Out-Null
reg.exe add "HKCU\Control Panel\Desktop" /v ScreenSaverIsSecure /t REG_SZ /d 0 /f | Out-Null
reg.exe add "HKCU\Control Panel\Desktop" /v ScreenSaveTimeOut  /t REG_SZ /d 0 /f | Out-Null
Write-Log "Screensaver disabled (HKCU)" 'Green'

# 4. То же для профиля по умолчанию (.DEFAULT) - чтобы и до входа не блокировало.
reg.exe add "HKEY_USERS\.DEFAULT\Control Panel\Desktop" /v ScreenSaveActive /t REG_SZ /d 0 /f | Out-Null
reg.exe add "HKEY_USERS\.DEFAULT\Control Panel\Desktop" /v ScreenSaverIsSecure /t REG_SZ /d 0 /f | Out-Null
Write-Log "Screensaver disabled (.DEFAULT)" 'Green'

# 5. Консольный таймаут блокировки дисплея (на всякий случай) = 0.
try {
    powercfg.exe -attributes SUB_VIDEO VIDEOCONLOCK -ATTRIB_HIDE 2>$null
    powercfg.exe /SETACVALUEINDEX SCHEME_CURRENT SUB_VIDEO VIDEOCONLOCK 0 2>$null
    powercfg.exe /SETACTIVE SCHEME_CURRENT 2>$null
    Write-Log "Console lock display timeout = 0" 'Green'
} catch {
    Write-Log "Console lock timeout tweak skipped: $_" 'Yellow'
}

Write-Log "=== disable_autolock finished ===" 'Cyan'
exit 0
