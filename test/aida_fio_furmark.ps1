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
    try {
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
'@
        }

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

        # Inject Win32 types для PrintWindow / GetWindowRect (один раз на сессию)
        if (-not ('IPDROM.AidaCap' -as [type])) {
            Add-Type -Namespace IPDROM -Name AidaCap -MemberDefinition @'
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT rect);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool PrintWindow(System.IntPtr hWnd, System.IntPtr hdcBlt, int nFlags);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr hWnd);
'@
        }

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
    Write-Log "Waiting 120s for AIDA64 to fully start..."
    Start-Sleep -Seconds 120
    $fm = Start-FurMark -GpuIndex 0
    if ($fm) { $furmarkStarted += $fm }
    $lastLaunchOffsetSec = Get-ElapsedSec
}
elseif ($gpuCount -ge 2 -and -not $hasFio) {
    # ---- CASE 3: AIDA + FurMark GPU0 + FurMark GPU1 ----
    Write-Log "=== Case 3: AIDA64 + FurMark GPU0 + FurMark GPU1 ===" 'Cyan'
    $aidaProc = Start-Aida -IncludeGPU $false
    Write-Log "Waiting 120s for AIDA64 to fully start..."
    Start-Sleep -Seconds 120
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
    Write-Log "Waiting 120s for AIDA64 to fully start..."
    Start-Sleep -Seconds 120
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
    Write-Log "Waiting 120s for AIDA64 to fully start..."
    Start-Sleep -Seconds 120
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
    Write-Log "Waiting 120s for AIDA64 to fully start..."
    Start-Sleep -Seconds 120
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
$autoShotTime  = $aidaEndTime.AddSeconds(-300)   # T - 5 min : AidaAuto
$finalShotTime = $aidaEndTime.AddSeconds(-30)    # T - 30 s  : AidaFinal (AIDA ТОЧНО ещё открыта)

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
        Start-Sleep -Seconds $chunk
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

# --- AidaAuto (T-300s) - только если до него ещё есть запас
if ((Get-Date) -lt $autoShotTime) {
    Wait-Until -Target $autoShotTime -Label 'AidaAuto'
    Write-Log "Taking AidaAuto screenshot (5 min before AIDA end)..." 'Yellow'
    Bring-AidaToFront
    Save-AidaScreenshotInline -Prefix 'AIDA64_auto'
} else {
    Write-Log "AidaAuto window missed (we are already past T-300s). Skipping AidaAuto." 'Yellow'
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
Write-Log "  -> DesktopFinal..."
& $invokeScreen 'DesktopFinal'

# ===================== AIDA64 HTML REPORT =====================
Write-Log "Generating AIDA64 HTML report..." 'Yellow'
if (Test-Path $script:Aida64FullPath) {
    $reportsDir = Join-Path (Join-Path ([Environment]::GetFolderPath('Desktop')) $env:COMPUTERNAME) 'Reports'
    New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null
    $reportPath = Join-Path $reportsDir 'SystemReport.html'

    Start-Process -FilePath $script:Aida64FullPath `
        -ArgumentList @('/R', $reportPath, '/ALL', '/SUM', '/HW', '/SW', '/AUDIT', '/HTML') `
        -Wait -NoNewWindow

    if (Test-Path $reportPath) {
        Write-Log "AIDA64 report saved: $reportPath" 'Green'
    } else {
        Write-Log "AIDA64 report was NOT created." 'Red'
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
