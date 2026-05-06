<#
.SYNOPSIS
    Automatic stress test (AIDA64 + FurMark + FIO)
#>
param(
    [int]$DurationMinutes = 30
)

$ErrorActionPreference = 'Stop'

$afterRebootTask = 'IPDROM_AutoStressTest_AfterReboot'
Unregister-ScheduledTask -TaskName $afterRebootTask -Confirm:$false -ErrorAction SilentlyContinue

function Write-ColorOutput {
    param([string]$Message, [string]$Color = 'White')
    Write-Host $Message -ForegroundColor $Color
}

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function New-ZipArchiveRobust {
    param(
        [Parameter(Mandatory)] [string]$SourceDir,
        [Parameter(Mandatory)] [string]$ZipPath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    if (Test-Path $ZipPath) {
        Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
    }

    [System.IO.Compression.ZipFile]::CreateFromDirectory($SourceDir, $ZipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
    return (Test-Path $ZipPath)
}

function Send-ArchiveToServer {
    param(
        [Parameter(Mandatory)] [string]$ArchivePath,
        [Parameter(Mandatory)] [string]$ServerUrl
    )

    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        Write-ColorOutput '  Uploading via curl.exe...' 'Gray'
        & curl.exe -f -sS -F "file=@$ArchivePath" $ServerUrl
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
        Write-Warning "  curl upload failed (exit $LASTEXITCODE)"
    }

    try {
        $webClient = New-Object System.Net.WebClient
        $null = $webClient.UploadFile($ServerUrl, $ArchivePath)
        return $true
    } catch {
        Write-Warning "  Fallback upload failed: $_"
        return $false
    }
}

if (-not (Test-IsAdmin)) {
    Write-ColorOutput 'Run as administrator!' 'Red'
    exit 1
}

Write-ColorOutput "`n========================================" 'Cyan'
Write-ColorOutput '   AUTOMATIC STRESS TEST' 'Cyan'
Write-ColorOutput '========================================' 'Cyan'
Write-Host ''

Write-ColorOutput '[1/7] Disabling power saving...' 'Yellow'
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change monitor-timeout-ac 0

$flagFile = "$env:ProgramData\IPDROM_StressTest_Completed.flag"
if (Test-Path $flagFile) {
    Write-ColorOutput 'Stress test already completed. Exiting.' 'Green'
    exit 0
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$usbRoot = (Get-Item $scriptDir).PSDrive.Root
Write-ColorOutput "USB root (script drive): $usbRoot" 'Green'

$testFolder = Join-Path $usbRoot 'test'
$testScript = Join-Path $testFolder 'aida_fio_furmark.ps1'
if (-not (Test-Path $testScript)) {
    Write-ColorOutput "aida_fio_furmark.ps1 not found in $testFolder" 'Red'
    exit 1
}
Write-ColorOutput "Test folder: $testFolder" 'Green'

function Get-NvidiaSmiPath {
    $candidates = @(
        "$env:WINDIR\System32\nvidia-smi.exe",
        "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
    )

    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    $cmd = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        return $cmd.Source
    }

    return $null
}

function Get-NvidiaGpuLines {
    $smi = Get-NvidiaSmiPath
    if (-not $smi) {
        return @()
    }

    try {
        return @(& $smi --query-gpu=index,name --format=csv,noheader 2>$null | Where-Object {
            $_ -and $_.Trim()
        })
    } catch {
        return @()
    }
}

function Wait-NvidiaGpusReady {
    param(
        [int]$ExpectedCount = 1,
        [int]$TimeoutSeconds = 300
    )

    Write-ColorOutput "  Waiting for NVIDIA GPUs via nvidia-smi, expected: $ExpectedCount" 'Gray'

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $stableCount = 0
    $lastCount = -1
    $lastLines = @()

    while ((Get-Date) -lt $deadline) {
        $lines = @(Get-NvidiaGpuLines)
        $count = $lines.Count

        if ($count -eq $lastCount -and $count -ge $ExpectedCount) {
            $stableCount++
        } else {
            $stableCount = 0
        }

        $lastCount = $count
        $lastLines = $lines

        if ($stableCount -ge 3) {
            Write-ColorOutput "  NVIDIA GPUs ready: $($lines -join '; ')" 'Green'
            return $lines
        }

        Write-ColorOutput "  NVIDIA GPUs currently visible: $count. Waiting..." 'Gray'
        Start-Sleep -Seconds 10
    }

    Write-Warning "  NVIDIA GPUs were not fully ready within timeout. Last visible count: $($lastLines.Count)"
    return $lastLines
}

Write-ColorOutput '[2/7] Detecting configuration...' 'Yellow'

$allControllers = Get-CimInstance Win32_VideoController
Write-ColorOutput "  Found video controllers: $($allControllers.Name -join ', ')" 'Gray'

$pnpNvidia = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object {
    $_.FriendlyName -like '*NVIDIA*'
})

$expectedNvidiaCount = $pnpNvidia.Count

if ($expectedNvidiaCount -lt 1) {
    $expectedNvidiaCount = @($allControllers | Where-Object {
        $_.Name -like '*NVIDIA*'
    }).Count
}

if ($expectedNvidiaCount -lt 1) {
    $expectedNvidiaCount = 1
}

$gpuLines = @(Wait-NvidiaGpusReady -ExpectedCount $expectedNvidiaCount -TimeoutSeconds 300)

$discreteGpuCount = 0

if ($gpuLines.Count -gt 0) {
    $discreteGpuCount = $gpuLines.Count
    Write-ColorOutput "  NVIDIA GPUs via nvidia-smi: $($gpuLines -join '; ')" 'Gray'
}

if ($discreteGpuCount -eq 0) {
    $discreteControllers = @($allControllers | Where-Object {
        $_.Name -notlike '*Microsoft Basic Display Adapter*' -and
        $_.Name -notlike '*Microsoft Hyper-V Video*' -and
        $_.Name -notlike '*Remote Desktop Display*' -and
        $_.Name -notlike '*Intel(R) HD Graphics*' -and
        $_.Name -notlike '*Intel(R) UHD Graphics*' -and
        $_.Name -notlike '*Intel(R) Iris*' -and
        $_.Name -notlike '*AMD Radeon(TM) Graphics*' -and
        $_.Name -notlike '*AMD Radeon Graphics*'
    })

    $discreteGpuCount = $discreteControllers.Count
}

Write-ColorOutput "  Discrete GPUs: $discreteGpuCount" 'Gray'

$systemDrive = $env:SystemDrive[0]
$additionalDrives = Get-Disk | Where-Object {
    $_.IsBoot -eq $false -and
    $_.OperationalStatus -eq 'Online' -and
    $_.BusType -notin @('USB', 'File Backed Virtual')
} | Get-Partition | Where-Object { $_.DriveLetter -and $_.DriveLetter -ne $systemDrive }
$driveLetters = @($additionalDrives | ForEach-Object { $_.DriveLetter })
Write-ColorOutput "  Additional drives: $($driveLetters -join ', ')" 'Gray'

$testArgs = @('AIDA')
if ($discreteGpuCount -gt 0) {
    $testArgs += 'FURMARK'
    if ($discreteGpuCount -ge 2) { $testArgs += 'GPU2' }
}
if ($driveLetters.Count -gt 0) {
    $testArgs += 'FIO'
    $testArgs += $driveLetters
}
$testArgs += "$DurationMinutes"
Write-ColorOutput "  Arguments: $($testArgs -join ' ')" 'Green'

Write-ColorOutput '[3/7] Setting up watchdog...' 'Yellow'

$watchdogSeconds = ($DurationMinutes * 60) + 1800
$watchdogTaskName = 'IPDROM_Watchdog_Reboot'
$triggerAt = (Get-Date).AddSeconds($watchdogSeconds)

try {
    Unregister-ScheduledTask -TaskName $watchdogTaskName -Confirm:$false -ErrorAction SilentlyContinue

    $action = New-ScheduledTaskAction -Execute 'shutdown.exe' -Argument '/r /f /t 0'
    $trigger = New-ScheduledTaskTrigger -Once -At $triggerAt
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    Register-ScheduledTask -TaskName $watchdogTaskName `
                           -Action $action `
                           -Trigger $trigger `
                           -Settings $settings `
                           -RunLevel Highest `
                           -Force | Out-Null

    Write-ColorOutput "  Watchdog: reboot at $($triggerAt.ToString('dd.MM.yyyy HH:mm'))" 'Gray'
}
catch {
    Write-ColorOutput "  Watchdog setup failed: $_" 'Red'
    throw
}

Write-ColorOutput '[4/7] Starting stress test...' 'Yellow'
$psExe = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
$argumentList = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $testScript,
    '-UsbRoot', $usbRoot
) + $testArgs
$process = Start-Process -FilePath $psExe -ArgumentList $argumentList -Wait -NoNewWindow -PassThru

if ($process.ExitCode -ne 0) {
    Write-ColorOutput "  Test finished with exit code $($process.ExitCode)" 'Yellow'
} else {
    Write-ColorOutput '  Test completed successfully' 'Green'
}

Write-ColorOutput '[4.5/7] Generating software report...' 'Yellow'
$computerName = $env:COMPUTERNAME
$desktopPath = [Environment]::GetFolderPath('Desktop')
$baseDir = Join-Path $desktopPath $computerName
$reportsDir = Join-Path $baseDir 'Reports'
New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null

$softwareReportScript = Join-Path $testFolder 'Generate_SoftwareReport.ps1'
if (Test-Path $softwareReportScript) {
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $softwareReportScript -ComputerName $computerName -OutputFolder $reportsDir -IncludeSoftware
    Write-ColorOutput '  Software report generated.' 'Green'
} else {
    Write-Warning '  Generate_SoftwareReport.ps1 not found'
}

Write-ColorOutput '[5/7] Cancelling watchdog...' 'Yellow'
Unregister-ScheduledTask -TaskName $watchdogTaskName -Confirm:$false -ErrorAction SilentlyContinue

powercfg /change standby-timeout-ac 30
powercfg /change monitor-timeout-ac 15

Write-ColorOutput '[6/7] Archiving and sending to server...' 'Yellow'
if (Test-Path $baseDir) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $archivePath = Join-Path $desktopPath ("{0}_{1}.zip" -f $computerName, $timestamp)

    try {
        $created = New-ZipArchiveRobust -SourceDir $baseDir -ZipPath $archivePath
        if (-not $created) {
            throw 'Archive file was not created'
        }

        Write-ColorOutput "  Archive created: $archivePath" 'Green'
        $serverUrl = 'http://10.0.6.41:3000/ulrep'
        $uploaded = Send-ArchiveToServer -ArchivePath $archivePath -ServerUrl $serverUrl
        if ($uploaded) {
            Write-ColorOutput '  Upload successful!' 'Green'
        } else {
            Write-Warning '  Upload failed'
        }
    } catch {
        Write-Warning "  Archive or upload error: $_"
    }
} else {
    Write-Warning "  Results folder not found: $baseDir"
}



Write-ColorOutput '[6.5/7] Creating full system backup...' 'Yellow'
$backupScript = Join-Path $scriptDir 'Create-FullBackup.ps1'
if (Test-Path $backupScript) {
    try {
        & $backupScript -BackupLabel 'IPDROM_BACKUP'
        if ($LASTEXITCODE -eq 0) {
            Write-ColorOutput '  Full backup completed.' 'Green'
        } else {
            Write-Warning "  Full backup script exited with code $LASTEXITCODE"
        }
    } catch {
        Write-Warning "  Full backup failed: $_"
    }
} else {
    Write-Warning "  Create-FullBackup.ps1 not found next to auto_stress_test.ps1"
}

New-Item -Path $flagFile -ItemType File -Force | Out-Null
Write-ColorOutput "`n========================================" 'Green'
Write-ColorOutput '   STRESS TEST COMPLETED!' 'Green'
Write-ColorOutput '========================================' 'Green'
