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

function Write-RaidLog {
    param([string]$Message)

    $logDir = Join-Path $env:ProgramData 'IPDROM\Logs'
    New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null

    $logFile = Join-Path $logDir 'mega_raid_prepare.log'
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    $line | Out-File -FilePath $logFile -Encoding UTF8 -Append
}

function Get-FreeDriveLetter {
    $used = @(
        Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter } |
        ForEach-Object { $_.DriveLetter.ToString().ToUpper() }
    )

    $preferred = @('R','S','T','U','V','W','Y','Z','D','E','F','G','H','I','J','K','L','M','N','O','P','Q')

    foreach ($letter in $preferred) {
        if ($used -notcontains $letter) {
            return $letter
        }
    }

    throw 'No free drive letters available.'
}

function Find-StorCliPath {
    param([Parameter(Mandatory)][string]$UsbRoot)

    $programFilesX86 = ${env:ProgramFiles(x86)}

    $candidates = @(
        (Join-Path $UsbRoot 'SoftForTest\StorCLI\storcli64.exe'),
        (Join-Path $UsbRoot 'SoftForTest\storcli\storcli64.exe'),
        (Join-Path $UsbRoot 'software\AvagoMegaRaid\StorCLI\storcli64.exe'),
        (Join-Path $UsbRoot 'software\AvagoMegaRaid\storcli64.exe'),
        (Join-Path $env:ProgramFiles 'Broadcom\StorCLI\storcli64.exe'),
        (Join-Path $env:ProgramFiles 'MegaRAID Storage Manager\StorCLI\storcli64.exe')
    )

    if ($programFilesX86) {
        $candidates += (Join-Path $programFilesX86 'MegaRAID Storage Manager\StorCLI\storcli64.exe')
        $candidates += (Join-Path $programFilesX86 'MegaRAID Storage Manager\StorCLI\storcli.exe')
    }

    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }

    return $null
}

function Install-MegaRaidDriverIfPresent {
    param([Parameter(Mandatory)][string]$UsbRoot)

    $driverDirs = @(
        (Join-Path $UsbRoot 'software\DriverAvagoMegaRaid'),
        (Join-Path $UsbRoot 'drivers\common\megaraid'),
        (Join-Path $UsbRoot 'drivers\common\lsi'),
        (Join-Path $UsbRoot 'drivers\common\avago'),
        (Join-Path $UsbRoot 'drivers\common\broadcom')
    )

    foreach ($dir in $driverDirs) {
        if (-not (Test-Path -LiteralPath $dir)) {
            continue
        }

        $infFiles = @(Get-ChildItem -Path $dir -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue)
        if ($infFiles.Count -eq 0) {
            Write-RaidLog "Driver folder exists, but INF not found: $dir"
            continue
        }

        Write-ColorOutput "  Installing MegaRAID driver from: $dir" 'Gray'
        Write-RaidLog "Installing MegaRAID driver from: $dir"

        & pnputil.exe /add-driver "$dir\*.inf" /subdirs /install 2>&1 | ForEach-Object {
            Write-RaidLog $_
        }

        Write-RaidLog "pnputil exit code: $LASTEXITCODE"
    }
}

function Invoke-StorageRescan {
    Write-ColorOutput '  Rescanning storage...' 'Gray'
    Write-RaidLog 'Storage rescan started.'

    try {
        & pnputil.exe /scan-devices 2>&1 | ForEach-Object {
            Write-RaidLog $_
        }
    } catch {
        Write-RaidLog "pnputil /scan-devices failed: $_"
    }

    try {
        Update-HostStorageCache -ErrorAction SilentlyContinue
    } catch {
        Write-RaidLog "Update-HostStorageCache failed: $_"
    }

    try {
        $diskpartScript = Join-Path $env:TEMP 'ipdrom_diskpart_rescan.txt'
        Set-Content -Path $diskpartScript -Value 'rescan' -Encoding ASCII
        & diskpart.exe /s $diskpartScript 2>&1 | ForEach-Object {
            Write-RaidLog $_
        }
        Remove-Item $diskpartScript -Force -ErrorAction SilentlyContinue
    } catch {
        Write-RaidLog "diskpart rescan failed: $_"
    }

    Start-Sleep -Seconds 5
}

function Test-IsMegaRaidLikeDisk {
    param([Parameter(Mandatory)]$Disk)

    $text = @(
        $Disk.FriendlyName,
        $Disk.Manufacturer,
        $Disk.Model,
        $Disk.Location,
        $Disk.SerialNumber,
        $Disk.BusType
    ) -join ' '

    if ($text -match '(?i)avago|lsi|broadcom|megaraid|mega raid|raid|virtual|sas') {
        return $true
    }

    if ($Disk.BusType.ToString() -in @('RAID', 'SAS', 'SCSI')) {
        return $true
    }

    return $false
}

function Invoke-StorCliSafe {
    param(
        [Parameter(Mandatory)] [string]$StorCliPath,
        [Parameter(Mandatory)] [string[]]$Arguments,
        [int]$TimeoutSeconds = 20
    )

    $outFile = Join-Path $env:TEMP ("storcli_out_{0}.txt" -f ([guid]::NewGuid().ToString('N')))
    $errFile = Join-Path $env:TEMP ("storcli_err_{0}.txt" -f ([guid]::NewGuid().ToString('N')))

    try {
        Write-RaidLog ("Running StorCLI with timeout {0}s: {1} {2}" -f $TimeoutSeconds, $StorCliPath, ($Arguments -join ' '))
        Write-ColorOutput ("  Running StorCLI: {0}" -f ($Arguments -join ' ')) 'Gray'

        $proc = Start-Process -FilePath $StorCliPath `
            -ArgumentList $Arguments `
            -PassThru `
            -NoNewWindow `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError $errFile

        $finished = $proc.WaitForExit($TimeoutSeconds * 1000)

        if (-not $finished) {
            Write-ColorOutput "  StorCLI timeout after $TimeoutSeconds sec. Skipping StorCLI check." 'Yellow'
            Write-RaidLog "StorCLI timeout. Killing process PID=$($proc.Id)"

            try {
                $proc.Kill()
            } catch {
                Write-RaidLog "Failed to kill StorCLI process: $_"
            }

            return [pscustomobject]@{
                Success  = $false
                TimedOut = $true
                ExitCode = 9999
                Output   = ''
                Error    = "StorCLI timeout after $TimeoutSeconds sec"
            }
        }

        $stdout = ''
        $stderr = ''

        if (Test-Path -LiteralPath $outFile) {
            $stdout = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
        }

        if (Test-Path -LiteralPath $errFile) {
            $stderr = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
        }

        Write-RaidLog "StorCLI exit code: $($proc.ExitCode)"
        if ($stdout) { Write-RaidLog $stdout }
        if ($stderr) { Write-RaidLog "STDERR: $stderr" }

        return [pscustomobject]@{
            Success  = ($proc.ExitCode -eq 0)
            TimedOut = $false
            ExitCode = $proc.ExitCode
            Output   = $stdout
            Error    = $stderr
        }
    }
    catch {
        Write-RaidLog "StorCLI failed: $_"

        return [pscustomobject]@{
            Success  = $false
            TimedOut = $false
            ExitCode = 1
            Output   = ''
            Error    = "$_"
        }
    }
    finally {
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-MegaRaidVirtualDriveState {
    param([string]$StorCliPath)

    if (-not $StorCliPath) {
        Write-RaidLog 'StorCLI not found. Skipping controller-level check.'
        return $false
    }

    Write-ColorOutput "  StorCLI found: $StorCliPath" 'Gray'
    Write-RaidLog "StorCLI found: $StorCliPath"

    $controllerResult = Invoke-StorCliSafe `
        -StorCliPath $StorCliPath `
        -Arguments @('/c0', 'show') `
        -TimeoutSeconds 20

    if ($controllerResult.TimedOut) {
        Write-RaidLog 'StorCLI /c0 show timed out. Continuing without controller-level RAID check.'
        return $false
    }

    $vdResult = Invoke-StorCliSafe `
        -StorCliPath $StorCliPath `
        -Arguments @('/c0/vall', 'show', 'all') `
        -TimeoutSeconds 20

    if ($vdResult.TimedOut) {
        Write-RaidLog 'StorCLI /c0/vall show all timed out. Continuing without controller-level RAID check.'
        return $false
    }

    $allText = @(
        $controllerResult.Output
        $controllerResult.Error
        $vdResult.Output
        $vdResult.Error
    ) -join "`n"

    if ($allText -match '(?i)RAID|Virtual Drive|VD LIST|Optimal|Optl|Dgrd|Degraded') {
        Write-ColorOutput '  MegaRAID virtual drive detected by StorCLI.' 'Green'
        Write-RaidLog 'MegaRAID virtual drive detected by StorCLI.'
        return $true
    }

    Write-ColorOutput '  StorCLI did not report virtual drives. Continuing with Windows disk detection.' 'Yellow'
    Write-RaidLog 'StorCLI did not report virtual drives.'
    return $false
}

function Ensure-DataDiskHasDriveLetter {
    param(
        [Parameter(Mandatory)]$Disk,
        [bool]$AllowCreatePartition
    )

    Write-RaidLog "Preparing disk Number=$($Disk.Number), FriendlyName=$($Disk.FriendlyName), Size=$($Disk.Size), BusType=$($Disk.BusType), PartitionStyle=$($Disk.PartitionStyle), Offline=$($Disk.IsOffline), ReadOnly=$($Disk.IsReadOnly)"

    try {
        if ($Disk.IsOffline) {
            Write-ColorOutput "  Disk $($Disk.Number) is Offline. Bringing Online..." 'Yellow'
            Set-Disk -Number $Disk.Number -IsOffline $false -ErrorAction Stop
        }

        if ($Disk.IsReadOnly) {
            Write-ColorOutput "  Disk $($Disk.Number) is ReadOnly. Clearing ReadOnly..." 'Yellow'
            Set-Disk -Number $Disk.Number -IsReadOnly $false -ErrorAction Stop
        }

        $Disk = Get-Disk -Number $Disk.Number -ErrorAction Stop
    } catch {
        Write-RaidLog "Failed to bring disk online/writable: $_"
        return @()
    }

    if ($Disk.PartitionStyle -eq 'RAW') {
        if (-not $AllowCreatePartition) {
            Write-RaidLog "Disk $($Disk.Number) is RAW, but auto-create is not allowed. Skipped."
            return @()
        }

        try {
            $letter = Get-FreeDriveLetter

            Write-ColorOutput "  RAW RAID disk found. Initializing disk $($Disk.Number) as GPT, letter $letter`: ..." 'Yellow'
            Write-RaidLog "Initializing RAW disk $($Disk.Number) as GPT, creating NTFS volume $letter`:"

            Initialize-Disk -Number $Disk.Number -PartitionStyle GPT -ErrorAction Stop
            $partition = New-Partition -DiskNumber $Disk.Number -UseMaximumSize -DriveLetter $letter -ErrorAction Stop
            Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel 'IPDROM_RAID_TEST' -Confirm:$false -Force -ErrorAction Stop | Out-Null

            Write-RaidLog "Disk $($Disk.Number) prepared as $letter`:"
            return @($letter)
        } catch {
            Write-RaidLog "Failed to initialize/format disk $($Disk.Number): $_"
            return @()
        }
    }

    $letters = @()

    try {
        $partitions = @(
            Get-Partition -DiskNumber $Disk.Number -ErrorAction Stop |
            Where-Object {
                $_.Type -notmatch 'Reserved|Recovery|System' -and
                $_.Size -gt 1GB
            } |
            Sort-Object Size -Descending
        )

        foreach ($partition in $partitions) {
            if ($partition.DriveLetter) {
                $letters += $partition.DriveLetter.ToString().ToUpper()
                continue
            }

            $letter = Get-FreeDriveLetter
            Write-ColorOutput "  Assigning drive letter $letter`: to disk $($Disk.Number), partition $($partition.PartitionNumber)..." 'Yellow'
            Write-RaidLog "Assigning drive letter $letter`: to disk $($Disk.Number), partition $($partition.PartitionNumber)"

            Add-PartitionAccessPath -DiskNumber $Disk.Number -PartitionNumber $partition.PartitionNumber -DriveLetter $letter -ErrorAction Stop
            $letters += $letter
        }
    } catch {
        Write-RaidLog "Failed to process partitions on disk $($Disk.Number): $_"
    }

    return @($letters | Sort-Object -Unique)
}

function Get-FioTargetDriveLetters {
    param(
        [Parameter(Mandatory)][string]$UsbRoot,
        [Parameter(Mandatory)][string]$SystemDriveLetter
    )

    Write-ColorOutput '  Preparing storage for FIO...' 'Yellow'
    Write-RaidLog '========== Preparing storage for FIO =========='
    Write-RaidLog "UsbRoot: $UsbRoot"
    Write-RaidLog "SystemDriveLetter: $SystemDriveLetter"

    Install-MegaRaidDriverIfPresent -UsbRoot $UsbRoot

    $storCli = Find-StorCliPath -UsbRoot $UsbRoot
    $megaRaidVdExists = Get-MegaRaidVirtualDriveState -StorCliPath $storCli

    Invoke-StorageRescan

    $candidateDisks = @(
        Get-Disk -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IsBoot -eq $false -and
            $_.IsSystem -eq $false -and
            $_.BusType.ToString() -notin @('USB', 'File Backed Virtual')
        } |
        Sort-Object Number
    )

    if ($candidateDisks.Count -eq 0) {
        Write-ColorOutput '  No non-system disks found for FIO.' 'Yellow'
        Write-RaidLog 'No non-system disks found for FIO.'
        return @()
    }

    $preparedLetters = @()

    foreach ($disk in $candidateDisks) {
        $isMegaRaidLike = Test-IsMegaRaidLikeDisk -Disk $disk

        $allowCreate = $false
        if ($isMegaRaidLike) {
            $allowCreate = $true
        } elseif ($megaRaidVdExists -and $candidateDisks.Count -eq 1) {
            $allowCreate = $true
        }

        $preparedLetters += Ensure-DataDiskHasDriveLetter -Disk $disk -AllowCreatePartition:$allowCreate
    }

    Invoke-StorageRescan

    $finalLetters = @(
        Get-Disk -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IsBoot -eq $false -and
            $_.IsSystem -eq $false -and
            $_.OperationalStatus -eq 'Online' -and
            $_.BusType.ToString() -notin @('USB', 'File Backed Virtual')
        } |
        Get-Partition -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DriveLetter -and
            $_.DriveLetter.ToString().ToUpper() -ne $SystemDriveLetter.ToUpper()
        } |
        ForEach-Object {
            $_.DriveLetter.ToString().ToUpper()
        } |
        Sort-Object -Unique
    )

    Write-RaidLog "Final FIO drive letters: $($finalLetters -join ', ')"
    return @($finalLetters)
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

$driveLetters = @(
    Get-FioTargetDriveLetters -UsbRoot $usbRoot -SystemDriveLetter $systemDrive
)

if ($driveLetters.Count -gt 0) {
    Write-ColorOutput "  FIO target drives: $($driveLetters -join ', ')" 'Green'
} else {
    Write-ColorOutput "  FIO target drives not found. RAID may be visible in BIOS/StorCLI but not exposed to Windows." 'Yellow'
}
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

$psCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($psCmd -and $psCmd.Source) {
    $psExe = $psCmd.Source
} else {
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
}

$argumentList = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $testScript,
    '-UsbRoot', $usbRoot
) + $testArgs

Write-ColorOutput "  PowerShell engine: $psExe" 'Gray'
Write-ColorOutput "  Test script: $testScript" 'Gray'
Write-ColorOutput "  Full command: `"$psExe`" $($argumentList -join ' ')" 'Gray'

try {
    & $psExe @argumentList
    $testExitCode = $LASTEXITCODE
}
finally {
    Unregister-ScheduledTask -TaskName $watchdogTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

if ($testExitCode -ne 0) {
    Write-ColorOutput "  Test finished with exit code $testExitCode" 'Red'
    throw "Stress test child script failed with exit code $testExitCode"
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
