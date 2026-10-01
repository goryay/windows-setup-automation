param(
    [int]$DurationMinutes = 30
)

$ErrorActionPreference = 'Stop'

# Disable console Quick Edit Mode. When enabled (Windows default), clicking
# inside the console starts a text selection which BLOCKS every subsequent
# WriteFile to stdout from child processes (msiexec, installers, etc.) until
# the user presses Enter/Escape. Symptom: pipeline appears frozen mid-install
# but resumes the instant user presses Enter. Also add ENABLE_EXTENDED_FLAGS
# (0x80) so the SetConsoleMode change actually sticks.
try {
    $sig = @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
    $t = Add-Type -MemberDefinition $sig -Name 'IpdromConsole' -Namespace 'Win32' -PassThru -ErrorAction Stop
    $STD_INPUT_HANDLE       = -10
    $ENABLE_QUICK_EDIT_MODE = 0x40
    $ENABLE_EXTENDED_FLAGS  = 0x80
    $h = $t::GetStdHandle($STD_INPUT_HANDLE)
    $m = 0
    if ($t::GetConsoleMode($h, [ref]$m)) {
        $m = ($m -band (-bnot $ENABLE_QUICK_EDIT_MODE)) -bor $ENABLE_EXTENDED_FLAGS
        [void]$t::SetConsoleMode($h, $m)
    }
} catch {
    # Non-fatal - the pipeline still runs, just susceptible to accidental clicks.
}

$programDataRoot = Join-Path $env:ProgramData 'IPDROM'
$logDir           = Join-Path $programDataRoot 'Logs'
$stateDir         = Join-Path $programDataRoot 'State'
$scriptsDir       = Join-Path $programDataRoot 'Scripts'
$taskName         = 'IPDROM_AutoStressTest_AfterReboot'

New-Item -ItemType Directory -Path $logDir   -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path $stateDir -Force -ErrorAction SilentlyContinue | Out-Null

$logFile       = Join-Path $logDir 'auto_stress_after_reboot.log'
$pendingFile   = Join-Path $stateDir 'PendingAfterReboot.txt'
$bootFile      = Join-Path $stateDir 'RegisteredBootTime.txt'
$lockFile      = Join-Path $stateDir 'StressStarted.lock'
$failedFile    = Join-Path $stateDir 'StressFailed.txt'
$finishedFile  = Join-Path $stateDir 'StressFinished.txt'
$attemptsFile  = Join-Path $stateDir 'StressAttempts.txt'
$oldDoneFlag   = Join-Path $env:ProgramData 'IPDROM_StressTest_Completed.flag'

# Сколько раз подряд поднимаем тест заново, если машина перезагрузилась ПОСРЕДИ
# прогона. Больше трёх попыток смысла не имеет: если машина валится каждый раз,
# это дефект стенда, а не случайный сбой, и её надо смотреть руками.
$maxResumeAttempts = 3

function Write-LauncherLog {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $logFile -Value $line -Encoding utf8
    Write-Host $line
}

function Exit-Cleanly {
    param([int]$Code = 0)
    Write-LauncherLog "Launcher exit code: $Code"
    exit $Code
}

# Закрывает цепочку автоподъёма: снимает задачу и маркеры незавершённой работы.
# Вызывается на любом исходе, когда auto_stress_test.ps1 ВЕРНУЛ код - хоть ноль,
# хоть ошибку. Вернул код - значит отработал, а не оборвался, и поднимать его
# заново нельзя: упавший тест упадёт снова, а успешный уже всё сделал.
function Close-ResumeChain {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $pendingFile  -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $attemptsFile -Force -ErrorAction SilentlyContinue
    Write-LauncherLog 'Resume chain closed (task unregistered, pending/attempt markers removed).'
}

# Снимает вечный автовход, взведённый register_auto_stress_after_reboot.ps1, чтобы
# машина уезжала к заказчику на обычный экран входа, а не логинилась сама
# беспарольным администратором.
# Идемпотентна и вызывается из ДВУХ мест - это принципиально: auto_stress_test.ps1
# в конце сам инициирует перезагрузку через 10 с, и вызов после его возврата
# выигрывает гонку не всегда (SL111111-010, 30.08.2026: ребут успел первым, автовход
# остался взведён). Второй вызов - на раннем выходе по флагу завершения - закрывает
# этот случай на следующей загрузке.
function Disable-PerpetualAutoLogon {
    try {
        $winlogon = 'Registry::HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty    -LiteralPath $winlogon -Name 'AutoAdminLogon'  -Value '0' -Type String -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -LiteralPath $winlogon -Name 'DefaultPassword' -Force -ErrorAction SilentlyContinue
        Write-LauncherLog 'Perpetual auto-logon disarmed (delivery-ready).'
    } catch {
        Write-LauncherLog "WARNING: failed to disarm auto-logon: $($_.Exception.Message)"
    }
}

# Recreate F: alias if InstallRoot is local (subst is per-session and can be lost on reboot)
function Ensure-SubstF {
    param([string]$Target)
    if (-not $Target) { return }
    $targetFull = [System.IO.Path]::GetFullPath($Target).TrimEnd('\')
    # If hint points to F: itself, never delete it — we'd lose the source and target in one go.
    if ($targetFull -ieq 'F:') {
        Write-LauncherLog "Ensure-SubstF: target is F: itself, skipping (would self-destruct)."
        return
    }
    if (-not (Test-Path $Target)) { return }
    # If F: already maps to the right local target, do nothing (ignore trailing \).
    foreach ($line in (& subst 2>$null)) {
        if ($line -match ('^F:\\: => ' + [Regex]::Escape($targetFull) + '\\?$')) { return }
    }
    & subst F: /D 2>$null | Out-Null
    & subst F: $targetFull 2>&1 | ForEach-Object { Write-LauncherLog "subst: $_" }
}

function Test-InstallRoot {
    param([string]$Root)
    if (-not $Root) { return $false }
    # Guard against Join-Path throwing "drive does not exist" when the hint
    # points to a drive letter that was dropped after reboot (e.g. F:\ from
    # a net use /persistent:no or a subst alias that wasn't restored).
    if (-not (Test-Path -LiteralPath $Root -ErrorAction SilentlyContinue)) {
        Write-LauncherLog "Test-InstallRoot: root not accessible: $Root"
        return $false
    }
    $needed = @(
        'customization\scripts\auto_stress_test.ps1',
        'test\aida_fio_furmark.ps1',
        'SoftForTest'
    )
    foreach ($rel in $needed) {
        try {
            $full = Join-Path $Root $rel -ErrorAction Stop
        } catch {
            Write-LauncherLog "Test-InstallRoot: Join-Path failed for '$Root' + '$rel': $($_.Exception.Message)"
            return $false
        }
        if (-not (Test-Path -LiteralPath $full -ErrorAction SilentlyContinue)) {
            Write-LauncherLog "Test-InstallRoot: missing $full"
            return $false
        }
    }
    Write-LauncherLog "Test-InstallRoot: $Root is valid"
    return $true
}

function Get-InstallRoot {
    # 1. Hint file (written by unattend-02 -> usually C:\IPDROM)
    $hintFile = Join-Path $stateDir 'InstallRoot.txt'
    if (Test-Path -LiteralPath $hintFile -ErrorAction SilentlyContinue) {
        $hint = (Get-Content -LiteralPath $hintFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
        if ($hint -and (Test-InstallRoot -Root $hint)) {
            Write-LauncherLog "Using install root from hint: $hint"
            Ensure-SubstF -Target $hint
            return $hint
        }
        Write-LauncherLog "Hint install root invalid: $hint"
    }

    # 2. Known local fallback (C:\IPDROM was the standard target of unattend-02 copy)
    if (Test-InstallRoot -Root 'C:\IPDROM') {
        Write-LauncherLog 'Using install root: C:\IPDROM'
        Ensure-SubstF -Target 'C:\IPDROM'
        return 'C:\IPDROM'
    }

    # 3. Scan all drive letters (USB / other local mounts)
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        Write-LauncherLog "Scanning drives for install root (attempt $attempt/4)..."
        $roots = @(
            Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
            Where-Object { $_.Root -match '^[A-Z]:\\$' } |
            ForEach-Object { $_.Root } |
            Sort-Object -Unique
        )
        foreach ($root in $roots) {
            if (Test-InstallRoot -Root $root) {
                $root | Out-File -FilePath $hintFile -Encoding ascii -Force
                Write-LauncherLog "Detected install root by scan: $root"
                return $root
            }
        }
        Start-Sleep -Seconds 15
    }

    throw 'Unable to locate installation media root with auto_stress_test.ps1/test/SoftForTest.'
}

Write-LauncherLog '========== Launcher started =========='
Write-LauncherLog "User: $env:USERNAME"

# === PXE: pick up SL chosen at install time, propagate to children via env var ===
try {
    $regSL = (Get-ItemProperty -Path 'HKLM:\Software\IPDROM' -Name 'SL' -ErrorAction SilentlyContinue).SL
    if ($regSL) {
        $env:IPDROM_FORCE_SL = $regSL
        Write-LauncherLog "PXE preselection: IPDROM_FORCE_SL=$regSL (from HKLM\Software\IPDROM\SL)"
    } else {
        Write-LauncherLog 'No SL preselection (HKLM\Software\IPDROM\SL not set). Pickers fall back to auto-discovery.'
    }
} catch {
    Write-LauncherLog "Failed to read SL from registry: $($_.Exception.Message)"
}

if ((Test-Path -LiteralPath $finishedFile -ErrorAction SilentlyContinue) -or
    (Test-Path -LiteralPath $oldDoneFlag  -ErrorAction SilentlyContinue)) {
    Write-LauncherLog 'Stress test already completed. Unregistering task and exiting.'
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    # Оба флага ставятся только при успешно завершённом конвейере (флаг пишет
    # ffu_trigger уже после 'Pipeline healthy'), поэтому машина здесь заведомо
    # delivery-ready и автовход обязан быть снят.
    Disable-PerpetualAutoLogon
    Exit-Cleanly 0
}

if (-not (Test-Path -LiteralPath $pendingFile -ErrorAction SilentlyContinue)) {
    Write-LauncherLog 'PendingAfterReboot.txt not found. Nothing to do.'
    Exit-Cleanly 0
}

if (Test-Path -LiteralPath $bootFile -ErrorAction SilentlyContinue) {
    $registeredBoot = [datetime]::Parse((Get-Content -LiteralPath $bootFile | Select-Object -First 1).Trim())
    $currentBoot    = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    Write-LauncherLog "Registered boot time: $($registeredBoot.ToString('o'))"
    Write-LauncherLog "Current boot time:    $($currentBoot.ToString('o'))"
    if ($currentBoot -le $registeredBoot.AddSeconds(5)) {
        Write-LauncherLog 'Same boot session detected. Exiting without starting stress test.'
        Exit-Cleanly 0
    }
}

# === ВОЗОБНОВЛЕНИЕ ПОСЛЕ ОБРЫВА (01.10.2026, претензия производства) ===
# Раньше замок проверялся ТОЛЬКО по возрасту: моложе 36 часов - выходим. Из-за
# этого перезагрузка посреди прогона убивала тест насовсем: задача к тому моменту
# уже снята с расписания (см. ниже), PendingAfterReboot.txt удалён, а замок ещё
# свежий. Машина поднималась, автоматически входила и просто стояла.
#
# Теперь в замок пишется ВРЕМЯ ЗАГРУЗКИ, в которой он поставлен:
#   та же загрузка  -> рядом действительно работает тест, уходим молча;
#   прошлая загрузка -> прогон оборвался вместе с машиной (BSOD, сторож, сброс
#                       по питанию, ручная перезагрузка) - блок finally в том
#                       процессе не отработал, поэтому замок и остался.
# Во втором случае поднимаем тест заново, считая попытки.
#
# ВАЖНО и честно: AIDA64/FurMark/FIO не умеют продолжаться с середины. "Возобновление"
# здесь означает ПОЛНЫЙ ПЕРЕЗАПУСК теста, а не досчёт остатка.
$currentBootIso = ((Get-CimInstance Win32_OperatingSystem).LastBootUpTime).ToString('o')

if (Test-Path -LiteralPath $lockFile -ErrorAction SilentlyContinue) {
    $lockLines = @(Get-Content -LiteralPath $lockFile -ErrorAction SilentlyContinue)
    $lockBoot  = if ($lockLines.Count -ge 2) { "$($lockLines[1])".Trim() } else { '' }

    if ($lockBoot -and $lockBoot -eq $currentBootIso) {
        Write-LauncherLog 'StressStarted.lock belongs to the CURRENT boot session - test is already running. Exiting.'
        Exit-Cleanly 0
    }

    # Замок без строки с временем загрузки - это замок, оставленный прежней
    # версией лончера. Возраст - единственное, чем его можно оценить.
    if (-not $lockBoot) {
        $ageHours = ((Get-Date) - (Get-Item -LiteralPath $lockFile).LastWriteTime).TotalHours
        if ($ageHours -lt 36) {
            Write-LauncherLog "Legacy StressStarted.lock without boot stamp, age $([math]::Round($ageHours, 2)) h - treating as running. Exiting."
            Exit-Cleanly 0
        }
        Write-LauncherLog 'Legacy StressStarted.lock is stale (>36 h) - treating the run as interrupted.'
    }

    $attempts = 0
    if (Test-Path -LiteralPath $attemptsFile -ErrorAction SilentlyContinue) {
        $raw = (Get-Content -LiteralPath $attemptsFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        [void][int]::TryParse("$raw".Trim(), [ref]$attempts)
    }
    $attempts++

    if ($attempts -gt $maxResumeAttempts) {
        Write-LauncherLog "Stress test was interrupted $($attempts - 1) time(s); resume limit $maxResumeAttempts reached. NOT restarting."
        "Stress test interrupted $($attempts - 1) time(s), resume limit $maxResumeAttempts reached - giving up at $(Get-Date -Format 's')" |
            Out-File -FilePath $failedFile -Encoding utf8 -Force
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $pendingFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $lockFile    -Force -ErrorAction SilentlyContinue
        Exit-Cleanly 1
    }

    "$attempts" | Out-File -FilePath $attemptsFile -Encoding ascii -Force
    Write-LauncherLog "Stress test was INTERRUPTED by a restart (lock stamped with boot '$lockBoot', current boot '$currentBootIso')."
    Write-LauncherLog "Restarting the stress test from the beginning - attempt $attempts of $maxResumeAttempts (AIDA64/FurMark/FIO cannot continue mid-run)."
    Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
}

@((Get-Date).ToString('o'), $currentBootIso) | Out-File -FilePath $lockFile -Encoding ascii -Force

try {
    Write-LauncherLog 'Waiting for shell readiness...'
    $ready = $false
    for ($i = 0; $i -lt 180; $i++) {
        if (Get-Process explorer -ErrorAction SilentlyContinue) { $ready = $true; break }
        Start-Sleep -Seconds 1
    }
    if ($ready) {
        Write-LauncherLog 'Explorer detected. Waiting extra 20 seconds before stress test.'
        Start-Sleep -Seconds 20
    } else {
        Write-LauncherLog 'Explorer not detected within timeout. Waiting fallback 30 seconds.'
        Start-Sleep -Seconds 30
    }

    $installRoot = Get-InstallRoot
    $autoTestScript = Join-Path $installRoot 'customization\scripts\auto_stress_test.ps1'

    Write-LauncherLog "Install root: $installRoot"
    Write-LauncherLog "Running: $autoTestScript -DurationMinutes $DurationMinutes (IPDROM_FORCE_SL=$env:IPDROM_FORCE_SL)"

    # ЗАДАЧУ И PendingAfterReboot.txt ЗДЕСЬ БОЛЬШЕ НЕ СНИМАЕМ (01.10.2026).
    # Именно эти две строки и лишали нас возобновления: к моменту старта теста
    # обоих маркеров уже не было, и обрыв посреди прогона было нечем подхватить.
    # Теперь они живут до самого конца и снимаются по факту исхода:
    #   успех   - флаг IPDROM_StressTest_Completed.flag (его пишет ffu_trigger
    #             ПЕРЕД перезагрузкой в WinPE, и лежит он вне State\, поэтому
    #             переживает его очистку) -> ранний выход в начале этого скрипта;
    #   отказ   - ветки ниже по $exitCode и catch;
    #   обрыв   - блок возобновления выше.
    # Зацикливания не будет: все три терминальных пути auto_stress_test.ps1
    # (провал health-gate, ffu_trigger, откат без перезагрузки) ставят этот флаг.

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $childArgs = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $autoTestScript,
        '-DurationMinutes', $DurationMinutes
    )

    Write-LauncherLog "Starting auto_stress_test.ps1 in current console..."
    & $psExe @childArgs
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) { $exitCode = 0 }

    Write-LauncherLog "auto_stress_test.ps1 finished with exit code $exitCode"
    if ($exitCode -eq 0) {
        # Test passed -> delivery-ready. Disarm the perpetual auto-logon armed by
        # register_auto_stress_after_reboot.ps1 so the delivered machine boots to a
        # normal sign-in screen (no blank-password auto-logon left enabled). On
        # failure we deliberately leave it on so the operator keeps a desktop across
        # reboots while investigating.
        Disable-PerpetualAutoLogon
        (Get-Date).ToString('o') | Out-File -FilePath $finishedFile -Encoding ascii -Force
        Close-ResumeChain
        Exit-Cleanly 0
    }
    "Stress test failed with exit code $exitCode at $(Get-Date -Format 's')" | Out-File -FilePath $failedFile -Encoding utf8 -Force
    Write-LauncherLog "ERROR: Stress test failed with exit code $exitCode"
    Close-ResumeChain
    Exit-Cleanly $exitCode
}
catch {
    Write-LauncherLog "FATAL ERROR: $($_.Exception.Message)"
    Write-LauncherLog "$($_.ScriptStackTrace)"
    "Launcher fatal error at $(Get-Date -Format 's'): $($_.Exception.Message)" | Out-File -FilePath $failedFile -Encoding utf8 -Force
    Close-ResumeChain
    Exit-Cleanly 1
}
finally {
    Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
}
