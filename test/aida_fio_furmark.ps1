<#
.SYNOPSIS
    Stress test launcher: AIDA64 + FurMark + FIO.
    Exact launch order per hardware case, no GPU probing.

    Case 1 - no GPU, no FIO  : AIDA64 (with GPU stress)
    Case 2 - 1 GPU, no FIO   : AIDA64 -> 120s -> FurMark GPU0
    Case 3 - 2 GPU, no FIO   : AIDA64 -> 120s -> FurMark GPU0 -> 15s -> FurMark GPU1
    Case 4 - no GPU, has FIO  : AIDA64 (with GPU stress) -> 120s -> FIO
    Case 5 - 1 GPU, has FIO   : AIDA64 -> 120s -> FurMark GPU0 -> 30s -> FIO
    Case 6 - 2 GPU, has FIO   : AIDA64 -> 120s -> FurMark GPU0 -> 15s -> GPU1 -> 30s -> FIO
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
    Write-Log "Starting AIDA64 (IncludeGPU=$IncludeGPU): $script:Aida64FullPath $argStr" 'Yellow'
    $proc = Start-Process -FilePath $script:Aida64FullPath -ArgumentList $argStr -PassThru
    Write-Log "AIDA64 started (PID: $($proc.Id))" 'Green'
    return $proc
}

function Start-FurMark {
    param([int]$GpuIndex, [int]$DurationSeconds)
    if (-not (Test-Path $script:FurMarkFullPath)) {
        Write-Log "FurMark not found: $script:FurMarkFullPath" 'Red'
        return $null
    }
    if ($DurationSeconds -lt 10) {
        Write-Log "FurMark GPU $GpuIndex: remaining time too short (${DurationSeconds}s), skipping." 'Yellow'
        return $null
    }

    $baseTitle  = "IPDROM_FURMARK_GPU${GpuIndex}"
    $batFile    = Join-Path $env:TEMP "ipdrom_furmark_gpu${GpuIndex}_$(New-Guid).bat"
    $batContent = @"
@echo off
title ${baseTitle}_RUNNING
echo Starting FurMark GPU $GpuIndex (max-time $DurationSeconds s)...
"$($script:FurMarkFullPath)" --demo furmark-vk --width 1920 --height 1080 --max-time $DurationSeconds --no-score-box --disable-demo-options --gpu-index=$GpuIndex
set IPDROM_RC=%ERRORLEVEL%
echo.
echo ========================================
echo FurMark GPU $GpuIndex completed (exit %IPDROM_RC%)
echo ========================================
title ${baseTitle}_FINAL
pause > nul
"@
    Set-Content -Path $batFile -Value $batContent -Encoding ASCII
    Write-Log "Starting FurMark GPU $GpuIndex (${DurationSeconds}s)..." 'Yellow'
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/k', "`"$batFile`"") -WindowStyle Normal -PassThru
    Write-Log "FurMark GPU $GpuIndex started (cmd PID: $($proc.Id))" 'Green'
    return [pscustomobject]@{ Process = $proc; TitleToken = $baseTitle; GpuIndex = $GpuIndex; BatFile = $batFile }
}

function Start-Fio {
    param([string]$DriveLetter, [int]$DurationSeconds)
    if (-not (Test-Path $script:FioFullPath)) {
        Write-Log "fio.exe not found: $script:FioFullPath" 'Red'
        return $null
    }
    if ($DurationSeconds -lt 10) {
        Write-Log "FIO ${DriveLetter}: remaining time too short (${DurationSeconds}s), skipping." 'Yellow'
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
runtime=$DurationSeconds
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
echo Starting FIO on drive $DriveLetter (runtime $DurationSeconds s)...
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
    Write-Log "Starting FIO drive $DriveLetter (${DurationSeconds}s)..." 'Yellow'
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/k', "`"$batFile`"") -WindowStyle Normal -PassThru
    Write-Log "FIO $DriveLetter started (cmd PID: $($proc.Id))" 'Green'
    return [pscustomobject]@{ Process = $proc; TitleToken = $baseTitle; Drive = $DriveLetter; JobFile = $jobFile; BatFile = $batFile }
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
        $engine = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        if (-not $engine) { $engine = Get-Command powershell.exe -ErrorAction SilentlyContinue }
        $proc      = Start-Process -FilePath $engine.Source `
                         -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $screenScript, '-Mode', $Mode) `
                         -WindowStyle Minimized -PassThru
        $finished  = $proc.WaitForExit(90000)
        if (-not $finished) {
            Write-Log "Screenshot $Mode timed out after 90s — killing." 'Red'
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

# ===================== LAUNCH SEQUENCE (by case) =====================
$aidaProc      = $null
$furmarkStarted = @()
$fioStarted     = @()
$testStartTime  = Get-Date

function Get-RemainingSeconds {
    return [int]($totalSeconds - ((Get-Date) - $testStartTime).TotalSeconds)
}

if ($gpuCount -eq 0 -and -not $hasFio) {
    # ---- CASE 1: AIDA only (with GPU stress) ----
    Write-Log "=== Case 1: AIDA64 only (GPU stress ON) ===" 'Cyan'
    $aidaProc = Start-Aida -IncludeGPU $true
}
elseif ($gpuCount -eq 1 -and -not $hasFio) {
    # ---- CASE 2: AIDA + FurMark GPU0 ----
    Write-Log "=== Case 2: AIDA64 + FurMark GPU0 ===" 'Cyan'
    $aidaProc = Start-Aida -IncludeGPU $false
    Write-Log "Waiting 120s for AIDA64 to fully start..."
    Start-Sleep -Seconds 120
    $fm = Start-FurMark -GpuIndex 0 -DurationSeconds (Get-RemainingSeconds)
    if ($fm) { $furmarkStarted += $fm }
}
elseif ($gpuCount -ge 2 -and -not $hasFio) {
    # ---- CASE 3: AIDA + FurMark GPU0 + FurMark GPU1 ----
    Write-Log "=== Case 3: AIDA64 + FurMark GPU0 + FurMark GPU1 ===" 'Cyan'
    $aidaProc = Start-Aida -IncludeGPU $false
    Write-Log "Waiting 120s for AIDA64 to fully start..."
    Start-Sleep -Seconds 120
    $fm = Start-FurMark -GpuIndex 0 -DurationSeconds (Get-RemainingSeconds)
    if ($fm) { $furmarkStarted += $fm }
    Write-Log "Waiting 15s before FurMark GPU1..."
    Start-Sleep -Seconds 15
    $fm = Start-FurMark -GpuIndex 1 -DurationSeconds (Get-RemainingSeconds)
    if ($fm) { $furmarkStarted += $fm }
}
elseif ($gpuCount -eq 0 -and $hasFio) {
    # ---- CASE 4: AIDA (GPU stress) + FIO ----
    Write-Log "=== Case 4: AIDA64 (GPU stress ON) + FIO $($fioDrives -join ',') ===" 'Cyan'
    $aidaProc = Start-Aida -IncludeGPU $true
    Write-Log "Waiting 120s for AIDA64 to fully start..."
    Start-Sleep -Seconds 120
    foreach ($drive in $fioDrives) {
        $fio = Start-Fio -DriveLetter $drive -DurationSeconds (Get-RemainingSeconds)
        if ($fio) { $fioStarted += $fio }
    }
}
elseif ($gpuCount -eq 1 -and $hasFio) {
    # ---- CASE 5: AIDA + FurMark GPU0 + FIO ----
    Write-Log "=== Case 5: AIDA64 + FurMark GPU0 + FIO $($fioDrives -join ',') ===" 'Cyan'
    $aidaProc = Start-Aida -IncludeGPU $false
    Write-Log "Waiting 120s for AIDA64 to fully start..."
    Start-Sleep -Seconds 120
    $fm = Start-FurMark -GpuIndex 0 -DurationSeconds (Get-RemainingSeconds)
    if ($fm) { $furmarkStarted += $fm }
    Write-Log "Waiting 30s before FIO..."
    Start-Sleep -Seconds 30
    foreach ($drive in $fioDrives) {
        $fio = Start-Fio -DriveLetter $drive -DurationSeconds (Get-RemainingSeconds)
        if ($fio) { $fioStarted += $fio }
    }
}
else {
    # ---- CASE 6: AIDA + FurMark GPU0 + FurMark GPU1 + FIO ----
    Write-Log "=== Case 6: AIDA64 + FurMark GPU0 + FurMark GPU1 + FIO $($fioDrives -join ',') ===" 'Cyan'
    $aidaProc = Start-Aida -IncludeGPU $false
    Write-Log "Waiting 120s for AIDA64 to fully start..."
    Start-Sleep -Seconds 120
    $fm = Start-FurMark -GpuIndex 0 -DurationSeconds (Get-RemainingSeconds)
    if ($fm) { $furmarkStarted += $fm }
    Write-Log "Waiting 15s before FurMark GPU1..."
    Start-Sleep -Seconds 15
    $fm = Start-FurMark -GpuIndex 1 -DurationSeconds (Get-RemainingSeconds)
    if ($fm) { $furmarkStarted += $fm }
    Write-Log "Waiting 30s before FIO..."
    Start-Sleep -Seconds 30
    foreach ($drive in $fioDrives) {
        $fio = Start-Fio -DriveLetter $drive -DurationSeconds (Get-RemainingSeconds)
        if ($fio) { $fioStarted += $fio }
    }
}

# ===================== WAIT FOR TESTS =====================
$remaining = Get-RemainingSeconds
Write-Log "All tests running. ~$([math]::Round($remaining/60,1)) min remaining until AIDA64 finishes..." 'Cyan'

if ($remaining -gt 300) {
    $autoShotDelay = $remaining - 300
    Write-Log "Waiting ${autoShotDelay}s then AidaAuto screenshot (at $(((Get-Date).AddSeconds($autoShotDelay)).ToString('HH:mm:ss')))..."
    Start-Sleep -Seconds $autoShotDelay
    Write-Log "Taking AidaAuto screenshot (5 min before end)..." 'Yellow'
    & $invokeScreen 'AidaAuto'
    Write-Log "Waiting final 300s..."
    Start-Sleep -Seconds 300
} elseif ($remaining -gt 0) {
    Write-Log "Less than 5 min remaining, skipping AidaAuto. Waiting ${remaining}s..."
    Start-Sleep -Seconds $remaining
}

# ===================== POST-TEST SEQUENCE =====================

# Step 3: 80 sec pause for console windows to print final status
Write-Log "Waiting 80s for console windows to show final status..."
Start-Sleep -Seconds 80

# Step 4: Screenshot AIDA64 final
Write-Log "Taking final screenshots..." 'Yellow'
Write-Log "  -> AidaFinal..."
& $invokeScreen 'AidaFinal'

# Step 5: Screenshot FurMark final
if ($furmarkStarted.Count -gt 0) {
    Write-Log "  -> FurMarkFinal..."
    & $invokeScreen 'FurMarkFinal'
}

# Step 6: Screenshot FIO final
if ($fioStarted.Count -gt 0) {
    Write-Log "  -> FioFinal..."
    & $invokeScreen 'FioFinal'
}

# Step 7: Screenshot desktop
Write-Log "  -> DesktopFinal..."
& $invokeScreen 'DesktopFinal'

# Step 8: Close FurMark and FIO windows
Write-Log "Closing FurMark and FIO windows..." 'Yellow'
Get-Process -Name 'furmark' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
foreach ($launch in $furmarkStarted) {
    try { $launch.Process.Refresh() } catch {}
    if (-not $launch.Process.HasExited) {
        Stop-Process -Id $launch.Process.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $launch.BatFile -Force -ErrorAction SilentlyContinue
}
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

# Step 9: Close AIDA64 stress instance
Write-Log "Closing AIDA64..." 'Yellow'
Close-ProcessByName -name 'AIDA64Port'            -waitSeconds 15
Close-ProcessByName -name 'aida64'                -waitSeconds 5
Close-ProcessByName -name 'AIDA64BusinessPortable' -waitSeconds 5

# Step 10: Generate AIDA64 HTML report
Write-Log "Generating AIDA64 HTML report..." 'Yellow'
if (Test-Path $script:Aida64FullPath) {
    $desktop     = [Environment]::GetFolderPath('Desktop')
    $reportsDir  = Join-Path (Join-Path $desktop $env:COMPUTERNAME) 'Reports'
    New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null
    $reportPath  = Join-Path $reportsDir 'SystemReport.html'

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

Write-Log "========== aida_fio_furmark.ps1 completed ==========" 'Green'
