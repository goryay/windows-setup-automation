<#
.SYNOPSIS
    Stress test launcher: AIDA64 + FurMark + FIO.
    All tools receive the same N-minute duration from their own start time.
    Staggered launch prevents simultaneous load spike.

    Case 1 - no GPU, no FIO  : AIDA64 (with GPU stress)
    Case 2 - 1 GPU, no FIO   : AIDA64 -> 120s -> FurMark GPU0
    Case 3 - 2 GPU, no FIO   : AIDA64 -> 120s -> FurMark GPU0 -> 15s -> FurMark GPU1
    Case 4 - no GPU, has FIO  : AIDA64 (with GPU stress) -> 120s -> FIO
    Case 5 - 1 GPU, has FIO   : AIDA64 -> 120s -> FurMark GPU0 -> 30s -> FIO
    Case 6 - 2 GPU, has FIO   : AIDA64 -> 120s -> FurMark GPU0 -> 15s -> GPU1 -> 30s -> FIO

    After AIDA finishes, wait for FurMark/FIO to also finish (they started later),
    then 80s for console windows to print final status, then screenshots.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$UsbRoot,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$TestArgs
)

$ErrorActionPreference = 'Stop'

# ===================== LOGGING =====================
$script:TestLogDir  = Join-Path $env:ProgramData 'IPDROM\Logs'
$script:TestLogFile = Join-Path $script:TestLogDir ("aida_fio_furmark_{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $script:TestLogDir | Out-Null

function Write-Log {
    param([string]$Message, [string]$Color = 'White')
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { $line | Out-File -FilePath $script:TestLogFile -Encoding UTF8 -Append } catch {}
    Write-Host $Message -ForegroundColor $Color
}

# ===================== KEEP SYSTEM AWAKE =====================
# SetThreadExecutionState - официальный Windows API «не засыпай, я работаю».
# Это страховка на случай, если powercfg-настройки в [1/7] не сработали
# (BIOS override, Modern Standby policies и т.п.). Действует на время жизни
# текущего потока PowerShell. При завершении скрипта Windows автоматически
# снимет блокировку (флаг ES_CONTINUOUS).
try {
    if (-not ('IPDROM.Power' -as [type])) {
        Add-Type -Namespace IPDROM -Name Power -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
public const uint ES_CONTINUOUS       = 0x80000000;
public const uint ES_SYSTEM_REQUIRED  = 0x00000001;
public const uint ES_DISPLAY_REQUIRED = 0x00000002;
'@
    }
    $flags = [IPDROM.Power]::ES_CONTINUOUS -bor `
             [IPDROM.Power]::ES_SYSTEM_REQUIRED -bor `
             [IPDROM.Power]::ES_DISPLAY_REQUIRED
    [IPDROM.Power]::SetThreadExecutionState($flags) | Out-Null
    Write-Log "Power keep-alive engaged (SetThreadExecutionState SYSTEM+DISPLAY)." 'DarkGray'
} catch {
    Write-Log "Power keep-alive failed: $_" 'Yellow'
}

# ===================== SCHEDULING PRIORITY =====================
# FIO across several RAID volumes plus AIDA64 and FurMark saturate the machine.
# This script itself mostly sleeps, but it has to wake up on time to take the
# timed screenshots - and under that load the wake-ups drift by minutes.
# Nudging OUR OWN priority up fixes the punctuality without touching the load.
# Deliberately NOT lowering the stress tools' priority: throttling them would
# weaken the very test we are running.
try {
    (Get-Process -Id $PID).PriorityClass = [System.Diagnostics.ProcessPriorityClass]::AboveNormal
    Write-Log "Orchestrator priority raised to AboveNormal (stress tools untouched)." 'DarkGray'
} catch {
    Write-Log "Could not raise orchestrator priority: $_" 'Yellow'
}

# ===================== WIN32 TYPES (PRE-COMPILED) =====================
# Add-Type compiles C# at runtime: it writes temporary assemblies to disk and
# spins up the compiler. That costs a fraction of a second on an idle machine,
# but becomes brutal once four FIO jobs saturate the disks - the first
# Bring-AidaToFront call under load spent TEN MINUTES right here, which ate the
# whole screenshot schedule and cost us the AidaAuto and AidaFinal shots.
# The AidaCap type never showed the problem only because AidaEarly compiles it
# BEFORE FIO starts. So: compile everything up front, while the machine is idle.
# The functions below keep their own guards and simply short-circuit afterwards.
function Initialize-Win32Types {
    if (-not ('IPDROM.WinFG' -as [type])) {
        Add-Type -Namespace IPDROM -Name WinFG -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpfn, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)] public static extern int GetWindowText(System.IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetWindowTextLength(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint lpdwProcessId);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindowAsync(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool BringWindowToTop(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr hWndAfter, int X, int Y, int cx, int cy, uint uFlags);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, System.UIntPtr dwExtraInfo);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
'@
    }
    if (-not ('IPDROM.AidaCap' -as [type])) {
        Add-Type -Namespace IPDROM -Name AidaCap -MemberDefinition @'
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT rect);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool PrintWindow(System.IntPtr hWnd, System.IntPtr hdcBlt, int nFlags);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr hWnd);
'@
    }
}

try {
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $swTypes = [System.Diagnostics.Stopwatch]::StartNew()
    Initialize-Win32Types
    $swTypes.Stop()
    Write-Log ("Win32 types pre-compiled in {0:N1}s (done while machine is still idle)." -f $swTypes.Elapsed.TotalSeconds) 'DarkGray'
} catch {
    Write-Log "Win32 type pre-compile failed: $_ (will retry lazily)" 'Yellow'
}

# ===================== PATHS =====================
if (-not $UsbRoot) { $UsbRoot = [System.IO.Path]::GetPathRoot($PSScriptRoot) }
$script:Aida64FullPath  = Join-Path $UsbRoot 'SoftForTest\AIDA64\AIDA64Port.exe'
$script:FurMarkFullPath = Join-Path $UsbRoot 'SoftForTest\FurMark\furmark.exe'
$script:FioFullPath     = 'C:\Program Files\fio\fio.exe'
$screenScript           = Join-Path $PSScriptRoot 'screen.ps1'

# ===================== PARSE ARGS =====================
Write-Log "========== aida_fio_furmark.ps1 started ==========" 'Cyan'
Write-Log "Log: $script:TestLogFile" 'DarkGray'
Write-Log "UsbRoot: $UsbRoot"
Write-Log "TestArgs: $($TestArgs -join ' ')"

if (-not $TestArgs -or $TestArgs.Count -lt 2) {
    Write-Log 'Not enough arguments. Example: AIDA FURMARK GPU2 FIO D 30' 'Red'
    exit 1
}

$tests       = @($TestArgs[0..($TestArgs.Count - 2)])
$durationMin = [int]([double]$TestArgs[-1])
if ($durationMin -le 0) { throw "Invalid duration: $durationMin min" }

$totalSeconds = $durationMin * 60
$hasFurMark   = $tests -contains 'FURMARK'
$gpuCount     = if ($tests -contains 'GPU2') { 2 } elseif ($hasFurMark) { 1 } else { 0 }
$fioDrives    = @($tests | Where-Object { $_ -match '^[A-Za-z]$' } | ForEach-Object { $_.ToUpper() })
$hasFio       = ($tests -contains 'FIO') -and ($fioDrives.Count -gt 0)

# AIDA64 gets GPU stress only when FurMark is NOT running
$includeGpuInAida = (-not $hasFurMark)

Write-Log "Duration: ${durationMin} min (${totalSeconds} sec) | GPUs: $gpuCount | FIO drives: $($fioDrives -join ',') | AIDA GPU stress: $includeGpuInAida"

# ===================== LAUNCH FUNCTIONS =====================

function Start-Aida {
    param([bool]$IncludeGPU)
    if (-not (Test-Path $script:Aida64FullPath)) {
        Write-Log "AIDA64 not found: $script:Aida64FullPath" 'Red'
        return $null
    }
    $gpuPart = if ($IncludeGPU) { ',GPU' } else { '' }
    $argStr  = "/SST CPU,FPU,Cache,RAM,Disk$gpuPart /SSTDUR $durationMin"
    Write-Log "Starting AIDA64 (IncludeGPU=$IncludeGPU) duration=${durationMin}min" 'Yellow'
    $proc = Start-Process -FilePath $script:Aida64FullPath -ArgumentList $argStr -PassThru
    Write-Log "AIDA64 started (PID: $($proc.Id))" 'Green'
    return $proc
}

function Start-FurMark {
    param([int]$GpuIndex)
    if (-not (Test-Path $script:FurMarkFullPath)) {
        Write-Log "FurMark not found: $script:FurMarkFullPath" 'Red'
        return $null
    }

    $baseTitle  = "IPDROM_FURMARK_GPU${GpuIndex}"
    $batFile    = Join-Path $env:TEMP "ipdrom_furmark_gpu${GpuIndex}_$(New-Guid).bat"
    # Each tool gets the full $totalSeconds from its own launch moment.
    # --gpu-index (space, not '=') reliably routes Vulkan demo to chosen GPU in FurMark 2.10.
    $batContent = @"
@echo off
title ${baseTitle}_RUNNING
echo Starting FurMark GPU $GpuIndex ($totalSeconds sec)...
"$($script:FurMarkFullPath)" --demo furmark-vk --gpu-index $GpuIndex --width 1920 --height 1080 --max-time $totalSeconds --no-score-box --disable-demo-options
set IPDROM_RC=%ERRORLEVEL%
echo.
echo ========================================
echo FurMark GPU $GpuIndex completed (exit %IPDROM_RC%)
echo ========================================
title ${baseTitle}_FINAL
pause > nul
"@
    Set-Content -Path $batFile -Value $batContent -Encoding ASCII
    Write-Log "Starting FurMark GPU $GpuIndex (duration=${totalSeconds}s from now)..." 'Yellow'
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/k', "`"$batFile`"") -WindowStyle Normal -PassThru
    Write-Log "FurMark GPU $GpuIndex started (cmd PID: $($proc.Id))" 'Green'
    return [pscustomobject]@{ Process = $proc; TitleToken = $baseTitle; GpuIndex = $GpuIndex; BatFile = $batFile }
}

function Start-Fio {
    param([string]$DriveLetter)
    if (-not (Test-Path $script:FioFullPath)) {
        Write-Log "fio.exe not found: $script:FioFullPath" 'Red'
        return $null
    }

    $DriveLetter = $DriveLetter.Trim().TrimEnd(':').ToUpper()
    $testDir  = "${DriveLetter}:\fio_tests"
    New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    $testFile = Join-Path $testDir "fio_test_$(New-Guid).dat"
    $jobFile  = Join-Path $env:TEMP "fio_job_${DriveLetter}_$(New-Guid).fio"

    $jobContent = @"
[global]
ioengine=windowsaio
filename=$testFile
size=1g
direct=1
time_based
runtime=$totalSeconds
loops=1
thread
stonewall

[Read-Write-test]
startdelay=0
iodepth=28
numjobs=14
bs=896k
rw=rw
"@
    Set-Content -Path $jobFile -Value $jobContent -Encoding ASCII

    $baseTitle  = "IPDROM_FIO_${DriveLetter}"
    $batFile    = Join-Path $env:TEMP "ipdrom_fio_${DriveLetter}_$(New-Guid).bat"
    $batContent = @"
@echo off
title ${baseTitle}_RUNNING
echo Starting FIO on drive $DriveLetter ($totalSeconds sec)...
"$($script:FioFullPath)" "$jobFile"
set IPDROM_RC=%ERRORLEVEL%
echo.
echo ========================================
echo FIO $DriveLetter completed (exit %IPDROM_RC%)
echo ========================================
title ${baseTitle}_FINAL
pause > nul
"@
    Set-Content -Path $batFile -Value $batContent -Encoding ASCII
    Write-Log "Starting FIO drive $DriveLetter (duration=${totalSeconds}s from now)..." 'Yellow'
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/k', "`"$batFile`"") -WindowStyle Normal -PassThru
    Write-Log "FIO $DriveLetter started (cmd PID: $($proc.Id))" 'Green'
    return [pscustomobject]@{ Process = $proc; TitleToken = $baseTitle; Drive = $DriveLetter; JobFile = $jobFile; BatFile = $batFile }
}

function Bring-AidaToFront {
    # Поднимает окно AIDA64 на передний план перед скриншотом.
    # Win32 SetForegroundWindow имеет foreground-lock, который обходится
    # эмуляцией нажатия Alt (keybd_event) - стандартный хак.
    # Окно ищем по заголовку, потому что в трее MainWindowHandle ненадёжен.

    # Поднятие окна - это косметика: Save-AidaScreenshotInline снимает через
    # PrintWindow, которому foreground не нужен. Поэтому если до конца AIDA
    # осталось меньше минуты, лучше пропустить этот шаг и успеть снять кадр,
    # чем застрять здесь и потерять скриншот целиком.
    if ($script:AidaDeadline) {
        $left = ($script:AidaDeadline - (Get-Date)).TotalSeconds
        if ($left -lt 45) {
            Write-Log ("Bring-AidaToFront skipped: only {0:N0}s left before AIDA ends - going straight to capture." -f $left) 'Yellow'
            return
        }
    }

    try {
        # Типы уже скомпилированы на старте скрипта (машина была без нагрузки).
        # Этот вызов - страховка: если пре-компиляция упала, он сделает работу здесь.
        Initialize-Win32Types

        # AIDA-процессы для фильтрации (по PID)
        $aidaProcs = @()
        foreach ($n in @('AIDA64Port','aida64','AIDA64BusinessPortable')) {
            $aidaProcs += Get-Process -Name $n -ErrorAction SilentlyContinue
        }
        if ($aidaProcs.Count -eq 0) { Write-Log "Bring-AidaToFront: AIDA process not running." 'Yellow'; return }
        $aidaPids = $aidaProcs.Id

        # === ПРИОРИТЕТ 1: MainWindowHandle процесса (надёжно, независимо от title) ===
        $h = [System.IntPtr]::Zero
        $foundDesc = ''
        foreach ($p in $aidaProcs) {
            if ($p.MainWindowHandle -ne [System.IntPtr]::Zero) {
                $h = $p.MainWindowHandle
                $foundDesc = "process $($p.ProcessName) (PID=$($p.Id)) MainWindow"
                Write-Log "Bring-AidaToFront: $foundDesc, hwnd=$h" 'DarkGray'
                break
            }
        }

        # === ПРИОРИТЕТ 2: EnumWindows по заголовку (fallback) ===
        if ($h -eq [System.IntPtr]::Zero) {
            $found = [System.Collections.Generic.List[object]]::new()
            $cb = [IPDROM.WinFG+EnumWindowsProc]{
                param($hWnd, $lParam)
                $pid2 = 0
                [void][IPDROM.WinFG]::GetWindowThreadProcessId($hWnd, [ref]$pid2)
                if ($aidaPids -contains [int]$pid2) {
                    $len = [IPDROM.WinFG]::GetWindowTextLength($hWnd)
                    if ($len -gt 0) {
                        $sb = New-Object System.Text.StringBuilder ($len + 2)
                        [void][IPDROM.WinFG]::GetWindowText($hWnd, $sb, $sb.Capacity)
                        $title = $sb.ToString()
                        if ($title -match 'AIDA64|System Stability') {
                            $found.Add([pscustomobject]@{ HWnd = $hWnd; Title = $title; Visible = [IPDROM.WinFG]::IsWindowVisible($hWnd) }) | Out-Null
                        }
                    }
                }
                return $true
            }
            [void][IPDROM.WinFG]::EnumWindows($cb, [System.IntPtr]::Zero)

            if ($found.Count -gt 0) {
                $target = $found | Where-Object { $_.Title -match 'System Stability' } | Select-Object -First 1
                if (-not $target) { $target = $found[0] }
                $h = $target.HWnd
                $foundDesc = "EnumWindows title='$($target.Title)'"
                Write-Log "Bring-AidaToFront: $foundDesc, hwnd=$h" 'DarkGray'
            }
        }

        # === ПРИОРИТЕТ 3: EnumWindows ЛЮБОЕ top-level окно от AIDA процесса (последний шанс) ===
        if ($h -eq [System.IntPtr]::Zero) {
            $any = [System.Collections.Generic.List[System.IntPtr]]::new()
            $cb2 = [IPDROM.WinFG+EnumWindowsProc]{
                param($hWnd, $lParam)
                $pid2 = 0
                [void][IPDROM.WinFG]::GetWindowThreadProcessId($hWnd, [ref]$pid2)
                if ($aidaPids -contains [int]$pid2) {
                    if ([IPDROM.WinFG]::IsWindowVisible($hWnd)) { $any.Add($hWnd) | Out-Null }
                }
                return $true
            }
            [void][IPDROM.WinFG]::EnumWindows($cb2, [System.IntPtr]::Zero)
            if ($any.Count -gt 0) {
                $h = $any[0]
                $foundDesc = 'first visible window of AIDA process'
                Write-Log "Bring-AidaToFront: $foundDesc, hwnd=$h" 'DarkGray'
            }
        }

        if ($h -eq [System.IntPtr]::Zero) {
            Write-Log "Bring-AidaToFront: no usable AIDA window found (process exists but window invisible/closed)." 'Yellow'
            return
        }
        Write-Log "Bring-AidaToFront: found '$($target.Title)' (visible=$($target.Visible))" 'DarkGray'

        # SW_RESTORE = 9 - для свёрнутого; SW_SHOW = 5 - для скрытого
        [IPDROM.WinFG]::ShowWindowAsync($h, 9) | Out-Null
        [IPDROM.WinFG]::ShowWindowAsync($h, 5) | Out-Null

        # Foreground-lock bypass: имитируем нажатие Alt в текущем потоке
        # VK_MENU=0x12, KEYEVENTF_KEYUP=0x0002
        [IPDROM.WinFG]::keybd_event(0x12, 0, 0, [System.UIntPtr]::Zero)
        [IPDROM.WinFG]::keybd_event(0x12, 0, 0x0002, [System.UIntPtr]::Zero)
        Start-Sleep -Milliseconds 50

        # Дополнительно - AttachThreadInput trick
        $fgHwnd  = [IPDROM.WinFG]::GetForegroundWindow()
        $fgPid   = 0
        $fgTid   = [IPDROM.WinFG]::GetWindowThreadProcessId($fgHwnd, [ref]$fgPid)
        $selfTid = [IPDROM.WinFG]::GetCurrentThreadId()
        $attached = $false
        if ($fgTid -ne 0 -and $fgTid -ne $selfTid) {
            $attached = [IPDROM.WinFG]::AttachThreadInput($selfTid, $fgTid, $true)
        }
        # HWND_TOPMOST = -1, SWP_NOMOVE|SWP_NOSIZE|SWP_SHOWWINDOW = 0x0043
        [IPDROM.WinFG]::SetWindowPos($h, [System.IntPtr]::new(-1), 0, 0, 0, 0, 0x0043) | Out-Null
        [IPDROM.WinFG]::BringWindowToTop($h)    | Out-Null
        [IPDROM.WinFG]::SetForegroundWindow($h) | Out-Null
        if ($attached) { [void][IPDROM.WinFG]::AttachThreadInput($selfTid, $fgTid, $false) }

        Start-Sleep -Milliseconds 500
        # Снимаем topmost (HWND_NOTOPMOST = -2), окно остаётся поверх остальных
        [IPDROM.WinFG]::SetWindowPos($h, [System.IntPtr]::new(-2), 0, 0, 0, 0, 0x0043) | Out-Null
        Start-Sleep -Seconds 1   # дать DWM перерисовать

        $nowFg = [IPDROM.WinFG]::GetForegroundWindow()
        if ($nowFg -eq $h) {
            Write-Log "AIDA brought to foreground OK (hwnd=$h)." 'DarkGray'
        } else {
            Write-Log "AIDA SetForegroundWindow returned, but foreground hwnd=$nowFg (expected $h). Screenshot may still capture wrong window." 'Yellow'
        }
    } catch {
        Write-Log "Bring-AidaToFront error: $_" 'Yellow'
    }
}

function Save-AidaScreenshotInline {
    # Снимает AIDA через PrintWindow - как в старом рабочем screen.ps1.
    # PrintWindow рендерит окно ПРЯМО в наш bitmap, не глядя на foreground/visibility.
    # Bring-AidaToFront уже отработал (на всякий случай AIDA активировано), но
    # PrintWindow работает и без этого.
    # Алгоритм:
    #   1) Найти AIDA-окно по MainWindowHandle или EnumWindows
    #   2) GetWindowRect → размеры окна
    #   3) PrintWindow с flag=2 (PW_RENDERFULLCONTENT), fallback flag=0
    #   4) Если PrintWindow не сработал - CopyFromScreen по rect окна
    #   5) Если окна нет совсем - CopyFromScreen primary screen (последний fallback)
    param([Parameter(Mandatory)][string]$Prefix)
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

        # Win32-типы для PrintWindow / GetWindowRect (скомпилированы на старте скрипта)
        Initialize-Win32Types

        $screensDir = Join-Path (Join-Path ([Environment]::GetFolderPath('Desktop')) $env:COMPUTERNAME) 'Screens'
        New-Item -ItemType Directory -Force -Path $screensDir | Out-Null

        # Найти AIDA-окно - сначала MainWindowHandle, потом fallback
        $aidaHwnd = [System.IntPtr]::Zero
        $aidaSource = ''
        foreach ($n in @('AIDA64Port','aida64','AIDA64BusinessPortable')) {
            $p = Get-Process -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [System.IntPtr]::Zero } | Select-Object -First 1
            if ($p) {
                $aidaHwnd   = $p.MainWindowHandle
                $aidaSource = "$($p.ProcessName) (PID=$($p.Id)) MainWindowHandle"
                break
            }
        }

        $ts   = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
        $path = Join-Path $screensDir ("{0}_{1}.png" -f $Prefix, $ts)

        if ($aidaHwnd -eq [System.IntPtr]::Zero) {
            # Совсем нет окна AIDA → fallback: весь экран
            Write-Log "Save-AidaScreenshotInline: AIDA window not found, capturing whole desktop as fallback." 'Yellow'
            $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
            $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
            $gfx = [System.Drawing.Graphics]::FromImage($bmp)
            try {
                $gfx.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $bmp.Size)
                $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
                Write-Log "Inline screenshot saved (desktop fallback): $path" 'Yellow'
            } finally { $gfx.Dispose(); $bmp.Dispose() }
            return
        }

        Write-Log "Save-AidaScreenshotInline: capturing via $aidaSource (hwnd=$aidaHwnd)" 'DarkGray'

        # GetWindowRect → размеры
        $rect = New-Object IPDROM.AidaCap+RECT
        if (-not [IPDROM.AidaCap]::GetWindowRect($aidaHwnd, [ref]$rect)) {
            Write-Log "GetWindowRect failed, fallback to full desktop." 'Yellow'
            $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
            $w = $bounds.Width; $h = $bounds.Height
            $rect.Left = $bounds.X; $rect.Top = $bounds.Y
        } else {
            $w = $rect.Right - $rect.Left
            $h = $rect.Bottom - $rect.Top
        }
        if ($w -le 0 -or $h -le 0) {
            Write-Log "Invalid window size (${w}x${h}), fallback to full desktop." 'Yellow'
            $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
            $w = $bounds.Width; $h = $bounds.Height
            $rect.Left = $bounds.X; $rect.Top = $bounds.Y
        }

        $bmp = New-Object System.Drawing.Bitmap($w, $h)
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $hdc = $gfx.GetHdc()
            $printed = $false
            try {
                # PW_RENDERFULLCONTENT (flag=2) - предпочтительный режим
                $printed = [IPDROM.AidaCap]::PrintWindow($aidaHwnd, $hdc, 2)
                if (-not $printed) {
                    # Старый flag=0 fallback
                    $printed = [IPDROM.AidaCap]::PrintWindow($aidaHwnd, $hdc, 0)
                }
            } finally { $gfx.ReleaseHdc($hdc) }

            if (-not $printed) {
                Write-Log "PrintWindow failed, CopyFromScreen by window rect." 'Yellow'
                $gfx.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bmp.Size)
            }

            $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
            $method = if ($printed) { 'PrintWindow' } else { 'CopyFromScreen-rect' }
            Write-Log "Inline screenshot saved ($method, ${w}x${h}): $path" 'Green'
        } finally {
            $gfx.Dispose()
            $bmp.Dispose()
        }
    } catch {
        Write-Log "Save-AidaScreenshotInline error: $_" 'Red'
    }
}

function Save-DesktopScreenshot {
    # Снимок ВСЕГО экрана, без привязки к какому-либо окну.
    # Нужен для диагностики: когда AIDA64 молча висит и не пишет отчёт, ни в
    # stdout, ни в stderr ничего нет - единственный способ понять, что
    # происходит, это посмотреть на экран. Модальное окно с вопросом
    # ("была закрыта некорректно", запрос лицензии и т.п.) видно только так.
    param([Parameter(Mandatory)][string]$Path)
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $gfx.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $bmp.Size)
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
            $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
            Write-Log ("  diagnostic desktop screenshot ({0}x{1}): {2}" -f $bounds.Width, $bounds.Height, $Path) 'Yellow'
        } finally { $gfx.Dispose(); $bmp.Dispose() }
    } catch {
        Write-Log "  diagnostic desktop screenshot failed: $_" 'DarkGray'
    }
}

function Close-ProcessByName {
    param([string]$name, [int]$waitSeconds = 10)
    $p = Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) { return }
    try { if ($p.MainWindowHandle -ne 0) { $null = $p.CloseMainWindow() } } catch {}
    try { $p | Wait-Process -Timeout $waitSeconds -ErrorAction SilentlyContinue } catch {}
    if (Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1) {
        Stop-Process -Name $name -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
}

# ===================== AIDA WARMUP + EARLY SCREENSHOT =====================
# AIDA-у нужно ~120s чтобы войти в полноценный System Stability Test.
# Делим этот warmup на две фазы:
#   60s : AIDA одна работает, UI отвечает - снимаем AIDA_early скрин
#   60s : дожидаемся пока AIDA точно стабилизировалась, потом возврат
#         в основной поток (запустит FurMark/FIO).
# Гарантирует что хотя бы ОДИН чистый скрин AIDA у нас будет, независимо от
# того что произойдёт с UI под пиковой нагрузкой ближе к концу теста.
function Wait-AidaWarmupWithEarlyScreenshot {
    Write-Log "Waiting 60s for AIDA64 to fully start (phase 1/2)..."
    Start-Sleep -Seconds 60
    Write-Log "Taking AidaEarly screenshot (AIDA alone, FurMark/FIO not yet started)..." 'Yellow'
    try {
        Save-AidaScreenshotInline -Prefix 'AIDA64_early'
    } catch {
        Write-Log "AidaEarly screenshot failed: $_" 'Yellow'
    }
    Write-Log "Waiting another 60s before FurMark/FIO (phase 2/2)..."
    Start-Sleep -Seconds 60
}

# ===================== SCREENSHOT HELPER =====================
$invokeScreen = {
    param([string]$Mode)
    if (-not (Test-Path $screenScript)) {
        Write-Log "screen.ps1 not found at $screenScript" 'Red'
        return
    }
    try {
        $engine   = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        if (-not $engine) { $engine = Get-Command powershell.exe -ErrorAction SilentlyContinue }
        $proc     = Start-Process -FilePath $engine.Source `
                        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $screenScript, '-Mode', $Mode) `
                        -WindowStyle Minimized -PassThru
        $finished = $proc.WaitForExit(90000)
        if (-not $finished) {
            Write-Log "Screenshot $Mode timed out after 90s - killing." 'Red'
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        } elseif ($proc.ExitCode -eq 0) {
            Write-Log "Screenshot $Mode OK." 'Green'
        } else {
            Write-Log "Screenshot $Mode exit code $($proc.ExitCode)." 'Yellow'
        }
    } catch {
        Write-Log "Screenshot $Mode error: $_" 'Red'
    }
}

# ===================== LAUNCH SEQUENCE =====================
$aidaProc       = $null
$furmarkStarted = @()
$fioStarted     = @()
$testStartTime  = Get-Date

# Tracks offset (seconds from testStartTime) at which the LAST tool was launched.
# Used after AIDA finishes to know how long to wait for the last tool to also finish.
$lastLaunchOffsetSec = 0

function Get-ElapsedSec { return [int]((Get-Date) - $testStartTime).TotalSeconds }

if ($gpuCount -eq 0 -and -not $hasFio) {
    # ---- CASE 1: AIDA only (with GPU stress) ----
    Write-Log "=== Case 1: AIDA64 only (GPU stress ON) ===" 'Cyan'
    $aidaProc = Start-Aida -IncludeGPU $true
    $lastLaunchOffsetSec = Get-ElapsedSec
}
elseif ($gpuCount -eq 1 -and -not $hasFio) {
    # ---- CASE 2: AIDA + FurMark GPU0 ----
    Write-Log "=== Case 2: AIDA64 + FurMark GPU0 ===" 'Cyan'
    $aidaProc = Start-Aida -IncludeGPU $false
    Wait-AidaWarmupWithEarlyScreenshot
    $fm = Start-FurMark -GpuIndex 0
    if ($fm) { $furmarkStarted += $fm }
    $lastLaunchOffsetSec = Get-ElapsedSec
}
elseif ($gpuCount -ge 2 -and -not $hasFio) {
    # ---- CASE 3: AIDA + FurMark GPU0 + FurMark GPU1 ----
    Write-Log "=== Case 3: AIDA64 + FurMark GPU0 + FurMark GPU1 ===" 'Cyan'
    $aidaProc = Start-Aida -IncludeGPU $false
    Wait-AidaWarmupWithEarlyScreenshot
    $fm = Start-FurMark -GpuIndex 0
    if ($fm) { $furmarkStarted += $fm }
    Write-Log "Waiting 15s before FurMark GPU1..."
    Start-Sleep -Seconds 15
    $fm = Start-FurMark -GpuIndex 1
    if ($fm) { $furmarkStarted += $fm }
    $lastLaunchOffsetSec = Get-ElapsedSec
}
elseif ($gpuCount -eq 0 -and $hasFio) {
    # ---- CASE 4: AIDA (GPU stress) + FIO ----
    Write-Log "=== Case 4: AIDA64 (GPU stress ON) + FIO $($fioDrives -join ',') ===" 'Cyan'
    $aidaProc = Start-Aida -IncludeGPU $true
    Wait-AidaWarmupWithEarlyScreenshot
    foreach ($drive in $fioDrives) {
        $fio = Start-Fio -DriveLetter $drive
        if ($fio) { $fioStarted += $fio }
    }
    $lastLaunchOffsetSec = Get-ElapsedSec
}
elseif ($gpuCount -eq 1 -and $hasFio) {
    # ---- CASE 5: AIDA + FurMark GPU0 + FIO ----
    Write-Log "=== Case 5: AIDA64 + FurMark GPU0 + FIO $($fioDrives -join ',') ===" 'Cyan'
    $aidaProc = Start-Aida -IncludeGPU $false
    Wait-AidaWarmupWithEarlyScreenshot
    $fm = Start-FurMark -GpuIndex 0
    if ($fm) { $furmarkStarted += $fm }
    Write-Log "Waiting 30s before FIO..."
    Start-Sleep -Seconds 30
    foreach ($drive in $fioDrives) {
        $fio = Start-Fio -DriveLetter $drive
        if ($fio) { $fioStarted += $fio }
    }
    $lastLaunchOffsetSec = Get-ElapsedSec
}
else {
    # ---- CASE 6: AIDA + FurMark GPU0 + FurMark GPU1 + FIO ----
    Write-Log "=== Case 6: AIDA64 + FurMark GPU0 + FurMark GPU1 + FIO $($fioDrives -join ',') ===" 'Cyan'
    $aidaProc = Start-Aida -IncludeGPU $false
    Wait-AidaWarmupWithEarlyScreenshot
    $fm = Start-FurMark -GpuIndex 0
    if ($fm) { $furmarkStarted += $fm }
    Write-Log "Waiting 15s before FurMark GPU1..."
    Start-Sleep -Seconds 15
    $fm = Start-FurMark -GpuIndex 1
    if ($fm) { $furmarkStarted += $fm }
    Write-Log "Waiting 30s before FIO..."
    Start-Sleep -Seconds 30
    foreach ($drive in $fioDrives) {
        $fio = Start-Fio -DriveLetter $drive
        if ($fio) { $fioStarted += $fio }
    }
    $lastLaunchOffsetSec = Get-ElapsedSec
}

Write-Log "All tests launched. Last tool started at offset +${lastLaunchOffsetSec}s." 'Cyan'
Write-Log "AIDA64 will finish at $(($testStartTime.AddSeconds($totalSeconds)).ToString('HH:mm:ss'))" 'Cyan'
Write-Log "Last tool  will finish at $(($testStartTime.AddSeconds($totalSeconds + $lastLaunchOffsetSec)).ToString('HH:mm:ss'))" 'Cyan'

# ===================== WAIT FOR AIDA (ABSOLUTE TIMING) =====================
# Используем абсолютные моменты времени, а не накопительные Start-Sleep.
# Иначе зависший на 90с screen.ps1 сдвинет все последующие шаги и AidaFinal
# попадёт уже после конца стресс-таймера AIDA - окно закроется и скриншот
# поймает то, что под AIDA-окном (FurMark/FIO).
$aidaEndTime   = $testStartTime.AddSeconds($totalSeconds)
$midShotTime   = $testStartTime.AddSeconds([int]($totalSeconds / 2))  # T/2 : AidaMid (середина теста, UI ещё может отвечать)
$autoShotTime  = $aidaEndTime.AddSeconds(-300)   # T - 5 min : AidaAuto
$finalShotTime = $aidaEndTime.AddSeconds(-30)    # T - 30 s  : AidaFinal (AIDA ТОЧНО ещё открыта)

# Дедлайн для Bring-AidaToFront: у неё нет своего представления о расписании,
# поэтому отдаём его сюда - см. проверку в начале функции.
$script:AidaDeadline = $aidaEndTime

function Wait-Until {
    # Resilient wait until $Target wall-clock time.
    # Uses small (max 30s) Start-Sleep chunks in a loop so that if Windows
    # suspends/throttles our process for any duration, we re-check the clock
    # after wake-up and exit promptly (instead of sleeping past target).
    param([datetime]$Target, [string]$Label)
    $now = Get-Date
    if ($Target -le $now) {
        Write-Log "  ${Label}: target $($Target.ToString('HH:mm:ss')) already passed (now $($now.ToString('HH:mm:ss'))), skipping wait." 'DarkGray'
        return
    }
    $totalSec = [int]($Target - $now).TotalSeconds
    Write-Log "  Waiting ${totalSec}s until $($Target.ToString('HH:mm:ss')) for ${Label}..." 'DarkGray'

    $lastLog = Get-Date
    while ($true) {
        $remaining = ($Target - (Get-Date)).TotalSeconds
        if ($remaining -le 0) { break }
        $chunk = [int][Math]::Min(30, $remaining)
        if ($chunk -lt 1) { $chunk = 1 }

        # Re-arm the "do not sleep" request on every iteration. The flag set at
        # script start is bound to whichever thread set it and only lasts for
        # that thread's life - if PowerShell moves the pipeline to another
        # thread, or anything clears the flag, the machine silently becomes
        # sleepable again mid-test. Re-arming here is cheap and keeps it alive.
        try {
            if ('IPDROM.Power' -as [type]) {
                [IPDROM.Power]::SetThreadExecutionState([IPDROM.Power]::ES_CONTINUOUS -bor [IPDROM.Power]::ES_SYSTEM_REQUIRED -bor [IPDROM.Power]::ES_DISPLAY_REQUIRED) | Out-Null
            }
        } catch {}

        $sleepStart = Get-Date
        Start-Sleep -Seconds $chunk
        # A chunk that takes far longer than asked means the machine really was
        # suspended (or badly starved). Log it at the moment it happens, with
        # exact times - otherwise this only surfaces as a late wake-up at the
        # end and there is no way to tell suspend from slow screenshots.
        $slept = ((Get-Date) - $sleepStart).TotalSeconds
        if ($slept -gt ($chunk + 10)) {
            Write-Log ("    STALL: Start-Sleep {0}s actually took {1:N0}s ({2} -> {3})" -f $chunk, $slept, $sleepStart.ToString('HH:mm:ss'), (Get-Date).ToString('HH:mm:ss')) 'Yellow'
        }

        # Heartbeat every 2 minutes so it's visible in log that we're alive
        if (((Get-Date) - $lastLog).TotalSeconds -ge 120) {
            $remNow = [int](($Target - (Get-Date)).TotalSeconds)
            if ($remNow -gt 0) { Write-Log "    ...still waiting for ${Label}: ${remNow}s remaining (now $((Get-Date).ToString('HH:mm:ss')))" 'DarkGray' }
            $lastLog = Get-Date
        }
    }
    # After loop: log actual completion time vs target
    $now = Get-Date
    $skew = [int](($now - $Target).TotalSeconds)
    if ($skew -gt 5) {
        Write-Log "  ${Label}: woke up ${skew}s LATE (target $($Target.ToString('HH:mm:ss')), actual $($now.ToString('HH:mm:ss'))). System was suspended/throttled." 'Yellow'
    }
}

# --- AidaMid (T/2) - середина теста: FurMark/FIO уже под нагрузкой минут 12-13,
# AIDA-графики показывают реальные данные, но UI ещё имеет шанс ответить
# (буферы сообщений Windows не успели переполниться, как ближе к концу).
# Это страховка на случай если AidaAuto/AidaFinal упадут в desktop fallback из-за
# зависшего UI AIDA-ы под пиковой нагрузкой.
if ((Get-Date) -lt $midShotTime) {
    Wait-Until -Target $midShotTime -Label 'AidaMid'
    Write-Log "Taking AidaMid screenshot (half of test duration, FIO+FurMark under full load)..." 'Yellow'
    Bring-AidaToFront
    Save-AidaScreenshotInline -Prefix 'AIDA64_mid'
} else {
    Write-Log "AidaMid window missed (we are already past T/2). Skipping AidaMid." 'Yellow'
}

# --- AidaAuto (T-300s) - только если до него ещё есть запас
if ((Get-Date) -lt $autoShotTime) {
    Wait-Until -Target $autoShotTime -Label 'AidaAuto'
    Write-Log "Taking AidaAuto screenshot (5 min before AIDA end)..." 'Yellow'
    Bring-AidaToFront
    Save-AidaScreenshotInline -Prefix 'AIDA64_auto'
} elseif ((Get-Date) -lt $aidaEndTime) {
    # A stall pushed us past the exact T-300s mark, but AIDA is still running.
    # A late shot carries the same information and is far better than none,
    # so take it immediately instead of skipping the step outright.
    Write-Log "AidaAuto target already passed, but AIDA is still running - taking the shot late." 'Yellow'
    Bring-AidaToFront
    Save-AidaScreenshotInline -Prefix 'AIDA64_auto'
} else {
    Write-Log "AidaAuto window missed (already past AIDA end). Skipping AidaAuto." 'Yellow'
}

# --- AidaFinal (T-30s) - ЭТОТ скриншот критичен, делаем всегда, пока AIDA жива
if ((Get-Date) -lt $finalShotTime) {
    Wait-Until -Target $finalShotTime -Label 'AidaFinal'
}
# Если уже после T-30, всё равно пытаемся: AIDA, скорее всего, ещё открыта
# (она закрывается через несколько секунд ПОСЛЕ конца таймера).
if ((Get-Date) -lt $aidaEndTime.AddSeconds(10)) {
    Write-Log "Taking AidaFinal screenshot..." 'Yellow'
    Bring-AidaToFront
    Save-AidaScreenshotInline -Prefix 'AIDA64_final'
} else {
    Write-Log "AidaFinal window missed (we are already past AIDA end). Skipping AidaFinal." 'Red'
}

# Досыпаем до фактического конца AIDA
Wait-Until -Target $aidaEndTime -Label 'AIDA end'

# ===================== WAIT FOR FURMARK / FIO TO ALSO FINISH =====================
# AidaFinal уже сделан выше (за 30s до конца AIDA).
# FurMark/FIO стартовали $lastLaunchOffsetSec секунд после AIDA - столько же и финишируют после неё.
if ($lastLaunchOffsetSec -gt 0) {
    $waitForLast = $lastLaunchOffsetSec + 10   # +10s буфер
    Write-Log "AIDA finished. Waiting ${waitForLast}s for FurMark/FIO to also finish..." 'Cyan'
    Start-Sleep -Seconds $waitForLast
}

# ===================== 80 SEC FOR CONSOLE FINAL STATUS =====================
Write-Log "Waiting 80s for console windows to print final status (_FINAL title)..."
Start-Sleep -Seconds 80

# ===================== TOOL-SPECIFIC FINAL SCREENSHOTS =====================
# FurMark/FIO консоли нужны открытыми с _FINAL заголовком, иначе их не найти.
Write-Log "Taking final screenshots..." 'Yellow'

if ($furmarkStarted.Count -gt 0) {
    Write-Log "  -> FurMarkFinal..."
    & $invokeScreen 'FurMarkFinal'
}

if ($fioStarted.Count -gt 0) {
    Write-Log "  -> FioFinal..."
    & $invokeScreen 'FioFinal'
}

# ===================== CLOSE WINDOWS =====================
# Закрываем ДО DesktopFinal, чтобы скриншот рабочего стола был чистым.
Write-Log "Closing FurMark windows..." 'Yellow'
Get-Process -Name 'furmark' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
foreach ($launch in $furmarkStarted) {
    try { $launch.Process.Refresh() } catch {}
    if (-not $launch.Process.HasExited) {
        Stop-Process -Id $launch.Process.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $launch.BatFile -Force -ErrorAction SilentlyContinue
}

Write-Log "Closing FIO windows..." 'Yellow'
foreach ($launch in $fioStarted) {
    try { $launch.Process.Refresh() } catch {}
    if (-not $launch.Process.HasExited) {
        try { $launch.Process.CloseMainWindow() | Out-Null } catch {}
        Start-Sleep -Milliseconds 800
        if (-not $launch.Process.HasExited) {
            Stop-Process -Id $launch.Process.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $launch.JobFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $launch.BatFile -Force -ErrorAction SilentlyContinue
}

Write-Log "Closing AIDA64..." 'Yellow'
Close-ProcessByName -name 'AIDA64Port'             -waitSeconds 15
Close-ProcessByName -name 'aida64'                 -waitSeconds 5
Close-ProcessByName -name 'AIDA64BusinessPortable' -waitSeconds 5

# ===================== CLEAN DESKTOP SCREENSHOT =====================
# Все окна стресс-теста закрыты. Минимизируем остатки (PowerShell-консоль скрипта,
# проводник и т.п.) и снимаем чистый рабочий стол.
Write-Log "Waiting 3s for DWM to redraw after window close..." 'DarkGray'
Start-Sleep -Seconds 3
try {
    (New-Object -ComObject Shell.Application).MinimizeAll()
    Start-Sleep -Seconds 2
} catch {
    Write-Log "MinimizeAll failed: $_" 'Yellow'
}
# Shell.MinimizeAll() НЕ сворачивает консоль собственного процесса - её надо
# свернуть отдельно. На Win11 консолью владеет conhost.exe, поэтому
# (Get-Process -Id $PID).MainWindowHandle возвращает 0 или handle от conhost,
# и ShowWindow на нём не работает. Канонический способ - kernel32!GetConsoleWindow.
try {
    $selfHwnd = [IPDROM.WinFG]::GetConsoleWindow()
    if ($selfHwnd -ne [IntPtr]::Zero) {
        [IPDROM.WinFG]::ShowWindow($selfHwnd, 6) | Out-Null  # SW_MINIMIZE
        Start-Sleep -Seconds 1
        Write-Log "Self console minimized (hwnd=$selfHwnd)." 'DarkGray'
    } else {
        Write-Log "GetConsoleWindow returned NULL - cannot minimize self." 'Yellow'
    }
} catch {
    Write-Log "Minimize self console failed: $_" 'Yellow'
}
Write-Log "  -> DesktopFinal..."
& $invokeScreen 'DesktopFinal'

# ===================== AIDA64 HTML REPORT =====================
Write-Log "Generating AIDA64 HTML report..." 'Yellow'
if (Test-Path $script:Aida64FullPath) {
    $reportsDir = Join-Path (Join-Path ([Environment]::GetFolderPath('Desktop')) $env:COMPUTERNAME) 'Reports'
    New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null
    # AIDA64 пишет HTML-отчёт с расширением .htm даже если в /R передать .html,
    # поэтому сразу указываем .htm. Проверка ниже также ищет по маске SystemReport.htm*,
    # чтобы оставаться корректной если в другой версии AIDA снова сменит расширение.
    $reportPath = Join-Path $reportsDir 'SystemReport.htm'

    # AIDA64 was TerminateProcess'd after the stress phase, so it left state
    # files that trigger a "did not close properly" modal on next launch. The
    # modal blocks report generation for 17+ minutes until we time out. Clear
    # residual process + state files BEFORE the second launch, and hard-cap
    # the report step so even a stray modal costs 5 min max, not 17.
    try {
        Get-Process -Name 'AIDA64Port','aida64' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        $aidaHome    = Split-Path -Parent $script:Aida64FullPath
        $stalePaths  = @(
            (Join-Path $aidaHome '*.tmp'),
            (Join-Path $aidaHome '*.pid'),
            (Join-Path $aidaHome '*.lock'),
            (Join-Path $aidaHome '_running*'),
            (Join-Path $aidaHome 'Data\*.tmp'),
            (Join-Path $aidaHome 'Data\*.pid'),
            (Join-Path $aidaHome 'Data\*.lock'),
            (Join-Path $aidaHome 'Data\_running*'),
            "$env:LOCALAPPDATA\FinalWire\AIDA64\*.tmp",
            "$env:LOCALAPPDATA\FinalWire\AIDA64\*.pid",
            "$env:LOCALAPPDATA\FinalWire\AIDA64\*.lock",
            "$env:APPDATA\FinalWire\AIDA64\*.tmp",
            "$env:APPDATA\FinalWire\AIDA64\*.pid",
            "$env:APPDATA\FinalWire\AIDA64\*.lock",
            "$env:TEMP\aida64*"
        )
        foreach ($p in $stalePaths) {
            Remove-Item -Path $p -Force -Recurse -ErrorAction SilentlyContinue
        }
        Write-Log "AIDA64 state cleared for clean report launch." 'Gray'
    } catch {
        Write-Log "AIDA64 pre-launch cleanup partially failed: $_" 'Yellow'
    }

    # This step kept timing out on the bench: AIDA64 never exits within the cap
    # and the old code only looked for the file AFTER the wait, so a report that
    # was written but followed by a hung process counted as "not created".
    # Reworked to be both more forgiving and self-diagnosing:
    #   * poll for the output file while waiting instead of only checking at the end
    #   * once the file stops growing, take it and kill the stuck process
    #   * capture stdout/stderr so a future failure leaves evidence behind
    #   * fall back to a summary-only report so the uploaded archive always has one
    function Invoke-AidaReport {
        param(
            [Parameter(Mandatory)][string]$Exe,
            [Parameter(Mandatory)][string]$OutFile,
            [Parameter(Mandatory)][string[]]$PageArgs,
            [Parameter(Mandatory)][int]$TimeoutSec,
            [Parameter(Mandatory)][string]$Label
        )

        $outDir = Split-Path -Parent $OutFile

        # Kill leftovers and drop previous output, so a stale file from an
        # earlier attempt cannot be mistaken for a fresh report.
        Get-Process -Name 'AIDA64*' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue

        # 2 s was not enough: after Stop-Process the killed AIDA64 still holds
        # its lock/tmp files for a while, and the next instance can come up with
        # a modal "previous session ended unexpectedly" dialog - which would
        # explain a process that hangs forever while writing nothing at all.
        # Give the OS real time to tear it down before relaunching.
        Start-Sleep -Seconds 20
        Get-ChildItem -Path $outDir -Filter 'SystemReport.htm*' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue

        $soPath  = Join-Path $script:TestLogDir ("aida_report_{0}_stdout.txt" -f $Label)
        $sePath  = Join-Path $script:TestLogDir ("aida_report_{0}_stderr.txt" -f $Label)
        $cliArgs = @('/R', $OutFile) + $PageArgs + @('/HTML')

        Write-Log ("  [{0}] launching: {1} {2}" -f $Label, (Split-Path $Exe -Leaf), ($cliArgs -join ' ')) 'DarkGray'

        $proc = $null
        try {
            $proc = Start-Process -FilePath $Exe -ArgumentList $cliArgs -PassThru -NoNewWindow `
                        -RedirectStandardOutput $soPath -RedirectStandardError $sePath -ErrorAction Stop
        } catch {
            Write-Log ("  [{0}] output redirection refused ({1}); launching without it." -f $Label, $_.Exception.Message) 'DarkGray'
            $proc = Start-Process -FilePath $Exe -ArgumentList $cliArgs -PassThru -NoNewWindow
        }

        $deadline  = (Get-Date).AddSeconds($TimeoutSec)
        $lastSize  = -1
        $stableFor = 0
        $found     = $null

        while ((Get-Date) -lt $deadline) {
            if ($proc.HasExited) {
                Write-Log ("  [{0}] process exited with code {1}." -f $Label, $proc.ExitCode) 'Gray'
                break
            }

            $f = Get-ChildItem -Path $outDir -Filter 'SystemReport.htm*' -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($f) {
                if ($f.Length -eq $lastSize -and $f.Length -gt 4KB) {
                    $stableFor += 5
                    # 20 s without growth means AIDA finished writing and is now
                    # just hanging around - take the file and move on.
                    if ($stableFor -ge 20) {
                        Write-Log ("  [{0}] report stopped growing at {1:N1} KB while the process is still alive - taking it." -f $Label, ($f.Length / 1KB)) 'Yellow'
                        $found = $f
                        break
                    }
                } else {
                    $stableFor = 0
                    $lastSize  = $f.Length
                }
            }
            Start-Sleep -Seconds 5
        }

        # Диагностика ДО убийства процесса: если отчёта нет, а AIDA всё ещё
        # жива, снимаем экран. Логи в прошлый раз ничего не дали (stdout и
        # stderr оказались пустыми), так что единственная оставшаяся версия -
        # модальное окно, ждущее клика. Скриншот её подтвердит или опровергнет.
        if (-not $found -and -not $proc.HasExited) {
            $shot = Join-Path $script:TestLogDir ("aida_report_{0}_stuck.png" -f $Label)
            Write-Log ("  [{0}] no report after {1}s and AIDA still alive - capturing screen before kill." -f $Label, $TimeoutSec) 'Yellow'
            Save-DesktopScreenshot -Path $shot
            # Скриншот 22.07 показал кнопку AIDA в панели задач без видимого окна.
            # Логируем состояние процессов: Responding=False значит UI-поток
            # действительно завис (стартовое сканирование), Responding=True -
            # процесс чего-то ждёт; заголовок окна подскажет, чего именно.
            foreach ($ap in @(Get-Process -Name 'AIDA64*' -ErrorAction SilentlyContinue)) {
                Write-Log ("  [{0}]   process {1} PID={2} responding={3} window='{4}'" -f $Label, $ap.ProcessName, $ap.Id, $ap.Responding, $ap.MainWindowTitle) 'DarkGray'
            }
        }

        if (-not $proc.HasExited) {
            Write-Log ("  [{0}] killing AIDA64 (cap {1}s reached or report already taken)." -f $Label, $TimeoutSec) 'DarkGray'
            try { $proc | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
        }
        Get-Process -Name 'AIDA64*' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2

        if (-not $found) {
            $found = Get-ChildItem -Path $outDir -Filter 'SystemReport.htm*' -ErrorAction SilentlyContinue |
                     Sort-Object LastWriteTime -Descending | Select-Object -First 1
        }
        if ($found -and $found.Length -le 4KB) {
            Write-Log ("  [{0}] report is only {1} bytes - too small to be real, treating as failure." -f $Label, $found.Length) 'Yellow'
            $found = $null
        }
        if (-not $found) {
            foreach ($diag in @($sePath, $soPath)) {
                if ((Test-Path $diag) -and ((Get-Item $diag).Length -gt 0)) {
                    $head = (Get-Content -LiteralPath $diag -TotalCount 5 -ErrorAction SilentlyContinue) -join ' | '
                    Write-Log ("  [{0}] {1}: {2}" -f $Label, (Split-Path $diag -Leaf), $head) 'DarkGray'
                }
            }
        }
        return $found
    }

    $actualReport = Invoke-AidaReport -Exe $script:Aida64FullPath -OutFile $reportPath `
        -PageArgs @('/ALL', '/SUM', '/HW', '/SW', '/AUDIT') -TimeoutSec 300 -Label 'full'

    # Диагностика 22.07 (aida_report_*_stuck.png): на экране НЕТ ни модального
    # окна, ни окна прогресса - только кнопка AIDA в панели задач. Значит AIDA
    # висит ДО показа окна генерации, то есть на стартовом сканировании железа
    # (PCI/SMBus/датчики/диски). Совпадает по времени с поломкой: отчёт работал
    # 13.07 при одном VD на MegaRAID и перестал с 19.07, когда массивов стало 3.
    # Поэтому повторные попытки идут с обрезанным сканированием:
    #   /SAFE   - без низкоуровневого PCI/SMBus/sensor-скана
    #   /SAFEST - вообще без загрузки kernel-драйверов (последний шанс)
    if (-not $actualReport) {
        Write-Log "Full AIDA64 report did not complete - retrying summary in Safe Mode (/SAFE, no low-level scan)." 'Yellow'
        $actualReport = Invoke-AidaReport -Exe $script:Aida64FullPath -OutFile $reportPath `
            -PageArgs @('/SUM', '/SAFE') -TimeoutSec 120 -Label 'summary_safe'
    }
    if (-not $actualReport) {
        Write-Log "Safe Mode also failed - last resort: /SAFEST (no kernel drivers at all)." 'Yellow'
        $actualReport = Invoke-AidaReport -Exe $script:Aida64FullPath -OutFile $reportPath `
            -PageArgs @('/SUM', '/SAFEST') -TimeoutSec 120 -Label 'summary_safest'
    }

    if ($actualReport) {
        $sizeKb = [math]::Round($actualReport.Length / 1KB, 1)
        Write-Log "AIDA64 report saved: $($actualReport.FullName) ($sizeKb KB)" 'Green'
    } else {
        Write-Log "AIDA64 report was NOT created (full and summary attempts both failed)." 'Red'
    }
} else {
    Write-Log "AIDA64 not found at $script:Aida64FullPath, report skipped." 'Yellow'
}

# Release power keep-alive - system can resume normal sleep behavior now
try {
    if ('IPDROM.Power' -as [type]) {
        [IPDROM.Power]::SetThreadExecutionState([IPDROM.Power]::ES_CONTINUOUS) | Out-Null
        Write-Log "Power keep-alive released." 'DarkGray'
    }
} catch {}

Write-Log "========== aida_fio_furmark.ps1 completed ==========" 'Green'
