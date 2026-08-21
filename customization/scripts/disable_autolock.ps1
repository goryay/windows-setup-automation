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

# 0. САМОЕ ПЕРВОЕ: отключить QuickEdit на ТЕКУЩЕЙ консоли через API.
#    Реестровая правка (шаг 8 ниже) действует только на консоли, созданные ПОЗЖЕ.
#    Но консоль, в которой идёт FirstLogon -> setup_apps_and_theme, создана РАНЬШЕ и
#    осталась с QuickEdit ВКЛ -> клик мышью в ней морозит весь конвейер (именно это
#    повесило Pro-прогон на 14 часов, как и protect_ipdromrec на 005). SetConsoleMode
#    чинит именно эту, живую консоль - сразу, не дожидаясь пересоздания.
try {
    $qeSig = @'
[DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
    $qe = Add-Type -MemberDefinition $qeSig -Name 'QuickEditOff' -Namespace 'IpdromConsole' -PassThru
    $h = $qe::GetStdHandle(-10)   # STD_INPUT_HANDLE
    $mode = [uint32]0
    if ($qe::GetConsoleMode($h, [ref]$mode)) {
        # +ENABLE_EXTENDED_FLAGS(0x80), -ENABLE_QUICK_EDIT_MODE(0x40), -ENABLE_MOUSE_INPUT(0x10)
        $new = [uint32]((($mode -bor 0x80) -band (-bnot 0x40)) -band (-bnot 0x10))
        [void]$qe::SetConsoleMode($h, $new)
        Write-Log ("QuickEdit OFF on CURRENT console via API (0x{0:X}->0x{1:X})" -f $mode, $new) 'Green'
    } else {
        Write-Log "GetConsoleMode failed (redirected / no console) - current console unchanged" 'Yellow'
    }
} catch {
    Write-Log "QuickEdit API toggle skipped: $_" 'Yellow'
}

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

# 6. Отключаем сам lock screen как экран (NoLockScreen). Без этого Windows
#    всё равно может показывать lock screen при wake/session switch, даже если
#    idle-таймаут = 0. Policy применяется на всех пользователей.
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization" /v NoLockScreen /t REG_DWORD /d 1 /f | Out-Null
Write-Log "NoLockScreen = 1 (lock screen disabled entirely)" 'Green'

# 7. Не требовать пароль при пробуждении из сна (на случай если сон случится).
try {
    powercfg.exe /SETACVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 0 2>$null
    powercfg.exe /SETDCVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 0 2>$null
    powercfg.exe /SETACTIVE SCHEME_CURRENT 2>$null
    Write-Log "Password on wake = disabled (both AC/DC)" 'Green'
} catch {
    Write-Log "Password-on-wake tweak skipped: $_" 'Yellow'
}

# 8. Отключаем QuickEdit Mode консоли. С включённым QuickEdit любой клик или
#    выделение мышью в окне консоли ПРИОСТАНАВЛИВАЕТ выполняющийся процесс до
#    нажатия Enter/Esc (в заголовке окна появляется "Выделение"/"Выбрать").
#    На прогоне 005 из-за этого protect_ipdromrec завис на 12 часов на самом
#    последнем шаге - консоль замерла на Write-Host, пока утром не нажали клавишу.
#    Настройка читается при СОЗДАНИИ консоли, поэтому ставим её здесь, в начале
#    конвейера: все последующие консоли (стресс-тест, aida, protect) её
#    унаследуют, и она же попадёт в FFU-образ заказчика.
reg.exe add "HKCU\Console" /v QuickEdit /t REG_DWORD /d 0 /f | Out-Null
reg.exe add "HKEY_USERS\.DEFAULT\Console" /v QuickEdit /t REG_DWORD /d 0 /f | Out-Null
Write-Log "QuickEdit console mode disabled (HKCU + .DEFAULT) - consoles no longer freeze on click" 'Green'

Write-Log "=== disable_autolock finished ===" 'Cyan'
exit 0
