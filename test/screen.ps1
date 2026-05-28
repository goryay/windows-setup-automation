<#
.SYNOPSIS
    Screenshot helper for AIDA64, FurMark, FIO and final desktop.
    Modes: AidaAuto, AidaFinal, FurMarkFinal, FioFinal, DesktopFinal
#>
param(
    [ValidateSet('AidaAuto','AidaFinal','FurMarkFinal','FioFinal','DesktopFinal')]
    [string]$Mode = 'DesktopFinal'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WinApiCapture {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left, Top, Right, Bottom;
    }
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, int nFlags);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    public const int SW_SHOWMAXIMIZED = 3;
    public const int SW_RESTORE = 9;
    public const uint WM_CLOSE = 0x0010;
}
'@ -Language CSharp -ErrorAction Stop

function Get-ScreensDir {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $dir = Join-Path (Join-Path $desktop $env:COMPUTERNAME) 'Screens'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

function Save-BitmapToFile {
    param(
        [Parameter(Mandatory)] [System.Drawing.Bitmap]$Bitmap,
        [Parameter(Mandatory)] [string]$OutputFolder,
        [Parameter(Mandatory)] [string]$OutputName
    )
    $ts   = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $path = Join-Path $OutputFolder ("{0}_{1}.png" -f $OutputName, $ts)
    $Bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Host "Saved: $path" -ForegroundColor Green
    return $path
}

function Get-AidaWindowProcess {
    return Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowHandle -ne 0 -and (
            $_.ProcessName -in @('AIDA64Port','aida64','AIDA64BusinessPortable') -or
            $_.MainWindowTitle -like '*System Stability Test*' -or
            $_.MainWindowTitle -like '*AIDA64*'
        )
    } | Sort-Object MainWindowTitle | Select-Object -First 1
}

function Get-CmdWindowsByToken {
    param(
        [Parameter(Mandatory)] [string]$Token,
        [switch]$FinalOnly
    )
    $list = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -ieq 'cmd' -and
        $_.MainWindowHandle -ne 0 -and
        $_.MainWindowTitle -like "*$Token*"
    }
    if ($FinalOnly) { $list = $list | Where-Object { $_.MainWindowTitle -like '*_FINAL*' } }
    return @($list | Sort-Object MainWindowTitle)
}

function Activate-Window {
    param(
        [Parameter(Mandatory)] [System.Diagnostics.Process]$Process,
        [switch]$Maximize
    )
    if (-not $Process -or $Process.MainWindowHandle -eq 0) { return $false }
    $code = if ($Maximize) { [WinApiCapture]::SW_SHOWMAXIMIZED } else { [WinApiCapture]::SW_RESTORE }
    [WinApiCapture]::ShowWindow($Process.MainWindowHandle, $code)    | Out-Null
    Start-Sleep -Milliseconds 400
    [WinApiCapture]::BringWindowToTop($Process.MainWindowHandle)     | Out-Null
    Start-Sleep -Milliseconds 400
    [WinApiCapture]::SetForegroundWindow($Process.MainWindowHandle)  | Out-Null
    Start-Sleep -Milliseconds 1500
    return $true
}

function New-WindowScreenshot {
    param(
        [Parameter(Mandatory)] [System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)] [string]$OutputFolder,
        [Parameter(Mandatory)] [string]$OutputName,
        [switch]$MaximizeBeforeCapture
    )
    Activate-Window -Process $Process -Maximize:$MaximizeBeforeCapture | Out-Null

    $rect = New-Object WinApiCapture+RECT
    if (-not [WinApiCapture]::GetWindowRect($Process.MainWindowHandle, [ref]$rect)) {
        throw "GetWindowRect failed for '$($Process.MainWindowTitle)'"
    }
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top
    if ($w -le 0 -or $h -le 0) { throw "Invalid window size for '$($Process.MainWindowTitle)'" }

    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $hdc = $gfx.GetHdc()
        $ok  = $false
        try {
            $ok = [WinApiCapture]::PrintWindow($Process.MainWindowHandle, $hdc, 2)
            if (-not $ok) { $ok = [WinApiCapture]::PrintWindow($Process.MainWindowHandle, $hdc, 0) }
        } finally { $gfx.ReleaseHdc($hdc) }
        if (-not $ok) { $gfx.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bmp.Size) }
        return Save-BitmapToFile -Bitmap $bmp -OutputFolder $OutputFolder -OutputName $OutputName
    } finally {
        $gfx.Dispose()
        $bmp.Dispose()
    }
}

function New-DesktopScreenshot {
    param(
        [Parameter(Mandatory)] [string]$OutputFolder,
        [Parameter(Mandatory)] [string]$OutputName
    )
    $b   = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $gfx.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
        return Save-BitmapToFile -Bitmap $bmp -OutputFolder $OutputFolder -OutputName $OutputName
    } finally {
        $gfx.Dispose()
        $bmp.Dispose()
    }
}

function Close-WindowProcess {
    param([Parameter(Mandatory)] [System.Diagnostics.Process]$Process)
    try {
        if ($Process.MainWindowHandle -ne 0) {
            [WinApiCapture]::PostMessage($Process.MainWindowHandle, [WinApiCapture]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            Start-Sleep -Milliseconds 1000
        }
    } catch {}
    try {
        $Process.Refresh()
        if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue }
    } catch {}
}

function Minimize-AllWindows {
    # Двухуровневая защита от "висящих" окон на DesktopFinal:
    # 1) Win+D (Show Desktop) - агрессивно прячет всё, включая ghost-окна
    #    от только что закрытых процессов (AIDA/FurMark/FIO)
    # 2) Shell.Application.MinimizeAll() - страховка
    # 3) Пауза для DWM redraw
    try {
        if (-not ('IPDROM.WinD' -as [type])) {
            Add-Type -Namespace IPDROM -Name WinD -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, System.UIntPtr dwExtraInfo);
'@
        }
        # VK_LWIN = 0x5B, VK_D = 0x44, KEYEVENTF_KEYUP = 0x0002
        # Press LWin, press D, release D, release LWin -> Show Desktop
        [IPDROM.WinD]::keybd_event(0x5B, 0, 0, [System.UIntPtr]::Zero)
        [IPDROM.WinD]::keybd_event(0x44, 0, 0, [System.UIntPtr]::Zero)
        [IPDROM.WinD]::keybd_event(0x44, 0, 0x0002, [System.UIntPtr]::Zero)
        [IPDROM.WinD]::keybd_event(0x5B, 0, 0x0002, [System.UIntPtr]::Zero)
        Start-Sleep -Milliseconds 800
    } catch {
        Write-Warning "Win+D simulation failed: $_"
    }
    try {
        (New-Object -ComObject Shell.Application).MinimizeAll()
        Start-Sleep -Seconds 2
    } catch {
        Write-Warning "MinimizeAll failed: $_"
    }
}

function Invoke-CaptureAida {
    param([Parameter(Mandatory)] [string]$Prefix)
    Start-Sleep -Seconds 3
    $aida = Get-AidaWindowProcess
    if (-not $aida) {
        Write-Warning "AIDA64 window not found - taking full desktop as fallback"
        New-DesktopScreenshot -OutputFolder $screensDir -OutputName "${Prefix}_desktop_fallback" | Out-Null
        return
    }
    # Use CopyFromScreen (full desktop) instead of PrintWindow for AIDA.
    # PrintWindow sends WM_PRINT to the target window and blocks until the window
    # processes the message. When AIDA64 is running at 100% CPU load its UI thread
    # is starved and never processes WM_PRINT - causing an infinite hang.
    # Since AIDA64 is always maximized during the test, a full-screen CopyFromScreen
    # gives the same result without any risk of hanging.
    Activate-Window -Process $aida -Maximize | Out-Null
    Start-Sleep -Milliseconds 800
    New-DesktopScreenshot -OutputFolder $screensDir -OutputName $Prefix | Out-Null
}

function Write-DiagLog {
    param([string]$Msg)
    # Записываем в диагностический лог рядом со скриншотами - чтобы родитель
    # (aida_fio_furmark.ps1) и пользователь могли увидеть что именно случилось.
    try {
        $diagLog = Join-Path $screensDir ("screen_diag_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
        $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Mode, $Msg
        Add-Content -LiteralPath $diagLog -Value $line -Encoding utf8
    } catch {}
    Write-Host $Msg
}

function Invoke-CaptureConsoleGroup {
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$Prefix,
        [switch]$CloseAfterCapture
    )

    # === Диагностический дамп: ВСЕ cmd-окна в системе ===
    # Помогает понять что произошло: окно закрылось / title не сменился / token не совпал
    $allCmd = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -ieq 'cmd' -and $_.MainWindowHandle -ne 0
    }
    Write-DiagLog "===== Console group capture for token '$Token' ====="
    Write-DiagLog "All visible cmd.exe windows ($($allCmd.Count) total):"
    foreach ($p in $allCmd) {
        Write-DiagLog ("  PID={0,-6} hwnd={1,-8} title='{2}'" -f $p.Id, $p.MainWindowHandle, $p.MainWindowTitle)
    }

    # Попытка #1: ищем сразу окна с _FINAL в title
    $found = @(Get-CmdWindowsByToken -Token $Token -FinalOnly)
    Write-DiagLog "Pass 1: found $($found.Count) cmd window(s) matching token='$Token' AND title contains '_FINAL'."

    # Если 0 — возможно title не успел смениться от _RUNNING к _FINAL. Подождём и повторим.
    if ($found.Count -eq 0) {
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            Start-Sleep -Seconds 5
            $found = @(Get-CmdWindowsByToken -Token $Token -FinalOnly)
            Write-DiagLog "Pass 2 attempt $attempt (after +${attempt}0s wait): found $($found.Count) _FINAL window(s)."
            if ($found.Count -gt 0) { break }
        }
    }

    # Всё равно 0 - последняя попытка: берём окна без требования _FINAL,
    # чтобы хотя бы что-то сфоткать (вдруг fio.exe сбил title)
    if ($found.Count -eq 0) {
        $found = @(Get-CmdWindowsByToken -Token $Token)
        Write-DiagLog "Fallback: searching WITHOUT _FINAL filter. Found $($found.Count) cmd window(s) with token='$Token'."
    }

    if ($found.Count -eq 0) {
        Write-DiagLog "GIVING UP: no cmd windows matching token '$Token' found at all. Exit 2."
        Write-Warning "No cmd windows found for token '$Token' (even without _FINAL filter)"
        exit 2
    }

    $i = 1
    foreach ($proc in $found) {
        Start-Sleep -Seconds 2
        Write-DiagLog "Capturing window #${i}: PID=$($proc.Id) title='$($proc.MainWindowTitle)'"
        New-WindowScreenshot -Process $proc -OutputFolder $screensDir -OutputName ("{0}_{1}" -f $Prefix, $i) -MaximizeBeforeCapture | Out-Null
        if ($CloseAfterCapture) { Close-WindowProcess -Process $proc }
        $i++
        Start-Sleep -Seconds 1
    }
    Write-DiagLog "Done. Captured $($found.Count) window(s)."
}

# ===================== MAIN =====================
$screensDir = Get-ScreensDir
Write-Host "Mode: $Mode" -ForegroundColor Cyan
Write-Host "Output: $screensDir" -ForegroundColor DarkGray

switch ($Mode) {
    'AidaAuto'     { Invoke-CaptureAida -Prefix 'AIDA64_auto' }
    'AidaFinal'    { Invoke-CaptureAida -Prefix 'AIDA64_final' }
    'FurMarkFinal' { Invoke-CaptureConsoleGroup -Token 'IPDROM_FURMARK_' -Prefix 'FurMark_console' -CloseAfterCapture }
    'FioFinal'     { Invoke-CaptureConsoleGroup -Token 'IPDROM_FIO_' -Prefix 'FIO_console' -CloseAfterCapture }
    'DesktopFinal' {
        Minimize-AllWindows
        New-DesktopScreenshot -OutputFolder $screensDir -OutputName 'final_desktop' | Out-Null
    }
}
