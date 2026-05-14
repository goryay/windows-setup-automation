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
        Write-Warning "AIDA64 window not found — taking full desktop as fallback"
        New-DesktopScreenshot -OutputFolder $screensDir -OutputName "${Prefix}_desktop_fallback" | Out-Null
        return
    }
    # Use CopyFromScreen (full desktop) instead of PrintWindow for AIDA.
    # PrintWindow sends WM_PRINT to the target window and blocks until the window
    # processes the message. When AIDA64 is running at 100% CPU load its UI thread
    # is starved and never processes WM_PRINT — causing an infinite hang.
    # Since AIDA64 is always maximized during the test, a full-screen CopyFromScreen
    # gives the same result without any risk of hanging.
    Activate-Window -Process $aida -Maximize | Out-Null
    Start-Sleep -Milliseconds 800
    New-DesktopScreenshot -OutputFolder $screensDir -OutputName $Prefix | Out-Null
}

function Invoke-CaptureConsoleGroup {
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string]$Prefix,
        [switch]$CloseAfterCapture
    )
    $found = @(Get-CmdWindowsByToken -Token $Token -FinalOnly)
    if (-not $found) {
        Write-Warning "No _FINAL cmd windows found for token '$Token'"
        return
    }
    $i = 1
    foreach ($proc in $found) {
        Start-Sleep -Seconds 2
        New-WindowScreenshot -Process $proc -OutputFolder $screensDir -OutputName ("{0}_{1}" -f $Prefix, $i) -MaximizeBeforeCapture | Out-Null
        if ($CloseAfterCapture) { Close-WindowProcess -Process $proc }
        $i++
        Start-Sleep -Seconds 1
    }
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
