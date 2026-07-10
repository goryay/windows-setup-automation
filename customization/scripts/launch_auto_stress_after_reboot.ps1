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
$oldDoneFlag   = Join-Path $env:ProgramData 'IPDROM_StressTest_Completed.flag'

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

if (Test-Path -LiteralPath $lockFile -ErrorAction SilentlyContinue) {
    $ageHours = ((Get-Date) - (Get-Item -LiteralPath $lockFile).LastWriteTime).TotalHours
    if ($ageHours -lt 36) {
        Write-LauncherLog "StressStarted.lock exists and is not stale ($([math]::Round($ageHours, 2)) h). Exiting."
        Exit-Cleanly 0
    }
    Write-LauncherLog 'Removing stale StressStarted.lock.'
    Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
}

(Get-Date).ToString('o') | Out-File -FilePath $lockFile -Encoding ascii -Force

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

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $pendingFile -Force -ErrorAction SilentlyContinue

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
        (Get-Date).ToString('o') | Out-File -FilePath $finishedFile -Encoding ascii -Force
        Exit-Cleanly 0
    }
    "Stress test failed with exit code $exitCode at $(Get-Date -Format 's')" | Out-File -FilePath $failedFile -Encoding utf8 -Force
    Write-LauncherLog "ERROR: Stress test failed with exit code $exitCode"
    Exit-Cleanly $exitCode
}
catch {
    Write-LauncherLog "FATAL ERROR: $($_.Exception.Message)"
    Write-LauncherLog "$($_.ScriptStackTrace)"
    "Launcher fatal error at $(Get-Date -Format 's'): $($_.Exception.Message)" | Out-File -FilePath $failedFile -Encoding utf8 -Force
    Exit-Cleanly 1
}
finally {
    Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
}
