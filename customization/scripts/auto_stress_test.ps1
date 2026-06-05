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

# Remove orphaned watchdog from previous crash (BSOD does not run finally block)
Unregister-ScheduledTask -TaskName 'IPDROM_Watchdog_Reboot' -Confirm:$false -ErrorAction SilentlyContinue

# ===================== LOGGING =====================
$script:StressLogDir  = Join-Path $env:ProgramData 'IPDROM\Logs'
$script:StressLogFile = Join-Path $script:StressLogDir ("auto_stress_test_{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $script:StressLogDir | Out-Null

function Write-ColorOutput {
    param([string]$Message, [string]$Color = 'White')
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { $line | Out-File -FilePath $script:StressLogFile -Encoding UTF8 -Append } catch {}
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

    # Логируем для отладки
    $sizeMB = [math]::Round((Get-Item $ArchivePath).Length / 1MB, 1)
    Write-ColorOutput "  Archive: $ArchivePath ($sizeMB MB)" 'Gray'
    Write-ColorOutput "  Server:  $ServerUrl" 'Gray'

    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        Write-ColorOutput '  Uploading via curl.exe (matches Python upload_last_archive)...' 'Yellow'

        # Совпадает с Python: 'file=@"path"' (внутренние кавычки для путей с пробелами).
        # БЕЗ флага -f, чтобы получить тело ответа сервера на 4xx/5xx (не молчаливый exit 22).
        # -w "\nHTTPSTATUS=%{http_code}\n" печатает HTTP-код в конце для проверки.
        $formArg = 'file=@"' + $ArchivePath + '"'

        # Используем cmd /c чтобы curl корректно проинтерпретировал кавычки внутри -F аргумента
        $curlOutput = & curl.exe -sS -F $formArg -w "`nHTTPSTATUS=%{http_code}`n" $ServerUrl 2>&1
        $curlExit   = $LASTEXITCODE

        Write-ColorOutput '  --- curl output ---' 'DarkGray'
        foreach ($l in ($curlOutput -split "`r?`n")) {
            if ($l.Trim()) { Write-ColorOutput "  | $l" 'DarkGray' }
        }
        Write-ColorOutput "  --- exit=$curlExit ---" 'DarkGray'

        # Извлекаем HTTP-код из вывода
        $httpStatus = $null
        foreach ($l in ($curlOutput -split "`r?`n")) {
            if ($l -match 'HTTPSTATUS=(\d+)') { $httpStatus = [int]$matches[1]; break }
        }

        if ($curlExit -eq 0 -and $httpStatus -ge 200 -and $httpStatus -lt 300) {
            Write-ColorOutput "  curl upload OK (HTTP $httpStatus)." 'Green'
            return $true
        }

        if ($httpStatus) {
            Write-Warning "  curl upload returned HTTP $httpStatus (exit $curlExit). See body above for server error."
        } else {
            Write-Warning "  curl upload failed (exit $curlExit, no HTTP status - connection problem?)."
        }
    }

    Write-ColorOutput '  Trying PowerShell WebClient fallback...' 'Yellow'
    try {
        $webClient = New-Object System.Net.WebClient
        $resp = $webClient.UploadFile($ServerUrl, $ArchivePath)
        $respText = [System.Text.Encoding]::UTF8.GetString($resp)
        Write-ColorOutput "  Fallback upload OK. Server response: $respText" 'Green'
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

function Get-RaidConfig {
    # Reads optional G:\customization\raid_config.json. Returns $null if file
    # missing/invalid. Schema:
    # {
    #   "raid": {
    #     "create_if_missing": true,
    #     "controller": 0,
    #     "level": "r0",
    #     "drives": "all",
    #     "strip_size_kb": 256,
    #     "init_if_present_but_raw": true
    #   },
    #   "raw_disks": {
    #     "init_all": true
    #   }
    # }
    param([Parameter(Mandatory)][string]$UsbRoot)
    $cfgPath = Join-Path $UsbRoot 'customization\raid_config.json'
    if (-not (Test-Path $cfgPath)) {
        Write-RaidLog "No raid_config.json at $cfgPath. Using defaults (no auto-RAID, no auto-init of plain raw disks)."
        return $null
    }
    try {
        $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-RaidLog "Loaded raid_config.json from $cfgPath."
        return $cfg
    } catch {
        Write-ColorOutput "  raid_config.json found but failed to parse: $_" 'Yellow'
        Write-RaidLog "raid_config.json parse error: $_"
        return $null
    }
}

function New-MegaRaidVirtualDriveFromConfig {
    # Creates a MegaRAID VD via StorCLI when no VD exists and config asks for it.
    # Returns $true if a new VD was created, $false otherwise.
    param(
        [Parameter(Mandatory)][string]$StorCliPath,
        [Parameter(Mandatory)]$RaidConfig
    )
    if (-not $RaidConfig -or -not $RaidConfig.raid) { return $false }
    if (-not $RaidConfig.raid.create_if_missing) { return $false }

    $ctrl  = if ($null -ne $RaidConfig.raid.controller) { [int]$RaidConfig.raid.controller } else { 0 }
    $level = "$($RaidConfig.raid.level)".ToLower()
    if ($level -notmatch '^r(0|1|5|6|10)$') {
        Write-ColorOutput "  raid_config: invalid level '$level'. Skipping RAID creation." 'Yellow'
        return $false
    }
    $drives = if ($RaidConfig.raid.drives) { "$($RaidConfig.raid.drives)" } else { 'all' }
    $strip  = if ($RaidConfig.raid.strip_size_kb) { [int]$RaidConfig.raid.strip_size_kb } else { 256 }

    if ($drives -ieq 'all') {
        $pdQuery = Invoke-StorCliCommand -StorCliPath $StorCliPath -Arguments @("/c$ctrl/eall/sall", 'show') -TimeoutSeconds 30
        if (-not $pdQuery.Success) {
            Write-ColorOutput '  Cannot enumerate physical drives for RAID creation. Skipping.' 'Yellow'
            return $false
        }
        $eidSlots = @()
        foreach ($line in ($pdQuery.Output -split "`r?`n")) {
            if ($line -match '^\s*(\d+):(\d+)\s') { $eidSlots += "$($Matches[1]):$($Matches[2])" }
        }
        if ($eidSlots.Count -eq 0) {
            Write-ColorOutput '  StorCLI found no physical drives to build RAID. Skipping.' 'Yellow'
            return $false
        }
        $drivesArg = $eidSlots -join ','
    } else {
        $drivesArg = $drives
    }

    Write-ColorOutput "  Creating MegaRAID VD: level=$level drives=$drivesArg strip=$strip..." 'Yellow'
    Write-RaidLog "Creating MegaRAID VD: /c$ctrl add vd type=$level drives=$drivesArg strip=$strip"

    $result = Invoke-StorCliCommand -StorCliPath $StorCliPath -Arguments @("/c$ctrl", 'add', 'vd', "type=$level", "drives=$drivesArg", "strip=$strip") -TimeoutSeconds 90
    if ($result.Success -and ($result.Output -match 'Success|Operation\s+\:\s*Success')) {
        Write-ColorOutput '  MegaRAID VD created.' 'Green'
        Write-RaidLog 'MegaRAID VD created successfully.'
        Start-Sleep -Seconds 10   # wait for VD to come up
        return $true
    } else {
        Write-ColorOutput "  StorCLI VD creation reported failure. Output: $($result.Output)" 'Yellow'
        Write-RaidLog "StorCLI VD creation failed. Output: $($result.Output)"
        return $false
    }
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
    param(
        [bool]$SkipDiskpart = $false
    )

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

    if (-not $SkipDiskpart) {
        $hasMegaRaid = Get-PnpDevice -Class SCSIAdapter -ErrorAction SilentlyContinue |
                       Where-Object { $_.InstanceId -match 'VEN_1000' }

        if ($hasMegaRaid) {
            Write-RaidLog 'MegaRAID controller detected (VEN_1000). Skipping diskpart rescan to prevent bus reset.'
            Write-ColorOutput '  MegaRAID detected - skipping diskpart rescan (prevents bus reset).' 'Yellow'
        } else {
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
        }
    } else {
        Write-RaidLog 'diskpart rescan explicitly skipped (SkipDiskpart=$true).'
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

    $msmService = Get-Service -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match 'vivaldiMSMService|MSMService|MegaRAID' -and $_.Status -eq 'Running' }

    if ($msmService) {
        Write-RaidLog "MSM service is running ($($msmService.Name)). StorCLI would conflict with exclusive access. Using Windows disk detection only."
        Write-ColorOutput "  MSM running ($($msmService.Name)) - skipping StorCLI, using Windows disk detection." 'Yellow'
        return $true
    }

    Write-ColorOutput "  StorCLI found: $StorCliPath" 'Gray'
    Write-RaidLog "StorCLI found: $StorCliPath"

    Write-RaidLog 'Waiting 5s before StorCLI query to let controller settle.'
    Start-Sleep -Seconds 5

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

    # Сначала проверяем все ли существующие партиции > 1GB.
    # ErrorAction=SilentlyContinue вместо Stop - чтобы пустой результат не уходил
    # в catch как "MSFT_Partition not found", а трактовался как "0 партиций".
    $allPartitions = @(
        Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue
    )
    $partitions = @(
        $allPartitions |
        Where-Object {
            $_.Type -notmatch 'Reserved|Recovery|System' -and
            $_.Size -gt 1GB
        } |
        Sort-Object Size -Descending
    )

    # Случай: диск инициализирован (GPT/MBR), но партиций нет вообще
    # (например диск 0 - RAID 6TB Не распределена; диски 2/3 - чистые NVMe).
    # Используем ту же логику что и для RAW: создаём партицию + форматируем NTFS.
    if ($allPartitions.Count -eq 0) {
        if (-not $AllowCreatePartition) {
            Write-RaidLog "Disk $($Disk.Number) has no partitions but auto-create is not allowed. Skipped."
            return @()
        }
        try {
            $letter = Get-FreeDriveLetter
            Write-ColorOutput "  Disk $($Disk.Number) initialized but empty. Creating NTFS partition, letter $letter`: ..." 'Yellow'
            Write-RaidLog "Disk $($Disk.Number) has $($Disk.PartitionStyle) but 0 partitions - creating NTFS volume $letter`:"

            $partition = New-Partition -DiskNumber $Disk.Number -UseMaximumSize -DriveLetter $letter -ErrorAction Stop
            Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel 'IPDROM_RAID_TEST' -Confirm:$false -Force -ErrorAction Stop | Out-Null

            Write-RaidLog "Disk $($Disk.Number) prepared as $letter`:"
            return @($letter)
        } catch {
            Write-RaidLog "Failed to create partition on disk $($Disk.Number): $_"
            return @()
        }
    }

    try {
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

    $megaRaidPnp = Get-PnpDevice -Class SCSIAdapter -ErrorAction SilentlyContinue |
                   Where-Object { $_.InstanceId -match 'VEN_1000' }

    if ($megaRaidPnp) {
        Write-RaidLog "MegaRAID controller detected on PCI bus (VEN_1000). Waiting 20s before rescan to let controller settle."
        Write-ColorOutput '  MegaRAID controller detected. Waiting 20s for controller to settle before rescan...' 'Yellow'
        Start-Sleep -Seconds 20
    }

    $storCli = Find-StorCliPath -UsbRoot $UsbRoot
    $raidCfg = Get-RaidConfig -UsbRoot $UsbRoot
    $megaRaidVdExists = Get-MegaRaidVirtualDriveState -StorCliPath $storCli

    # If config says "create_if_missing" and no VD detected - create it via StorCLI
    if ($storCli -and -not $megaRaidVdExists -and $raidCfg -and $raidCfg.raid -and $raidCfg.raid.create_if_missing) {
        $created = New-MegaRaidVirtualDriveFromConfig -StorCliPath $storCli -RaidConfig $raidCfg
        if ($created) {
            $megaRaidVdExists = $true
        }
    }

    $skipDiskpart = [bool]$megaRaidPnp
    Invoke-StorageRescan -SkipDiskpart $skipDiskpart

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

    # Extra safety: only fixed buses can be auto-initialised.
    # Plain raw disks initialised only if config explicitly opts in via raw_disks.init_all.
    $safeFixedBuses   = @('SATA','NVMe','SAS','RAID','ATA','SCSI','iSCSI','Fibre Channel','SD')
    $initRawDisksAuto = [bool]($raidCfg -and $raidCfg.raw_disks -and $raidCfg.raw_disks.init_all)
    $initRaidVdIfRaw  = [bool]($raidCfg -and $raidCfg.raid -and $raidCfg.raid.init_if_present_but_raw)

    foreach ($disk in $candidateDisks) {
        $isMegaRaidLike = Test-IsMegaRaidLikeDisk -Disk $disk
        $busType        = $disk.BusType.ToString()
        $isSafeBus      = ($safeFixedBuses -contains $busType)

        $allowCreate = $false
        if ($isMegaRaidLike -and $initRaidVdIfRaw) {
            $allowCreate = $true
        } elseif ($megaRaidVdExists -and $candidateDisks.Count -eq 1 -and $initRaidVdIfRaw) {
            $allowCreate = $true
        } elseif ($initRawDisksAuto -and $isSafeBus -and -not $isMegaRaidLike) {
            # Plain (non-RAID) disk on a fixed bus - init only if config explicitly says so
            $allowCreate = $true
        }

        Write-RaidLog "Disk $($disk.Number): bus=$busType, megaRaidLike=$isMegaRaidLike, safeBus=$isSafeBus, allowCreate=$allowCreate"

        $preparedLetters += Ensure-DataDiskHasDriveLetter -Disk $disk -AllowCreatePartition:$allowCreate
    }

    Invoke-StorageRescan -SkipDiskpart $skipDiskpart

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
Write-ColorOutput "   DurationMinutes: $DurationMinutes" 'Cyan'
Write-ColorOutput '========================================' 'Cyan'
Write-ColorOutput "Log file: $script:StressLogFile" 'DarkGray'
Write-Host ''

Write-ColorOutput '[1/7] Disabling power saving...' 'Yellow'
# Standard timeouts
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /change disk-timeout-ac 0

# CRITICAL: "System unattended sleep timeout". Default = 2 min on AC.
# When PowerShell sits in Start-Sleep with no user input, Windows treats
# the session as "unattended" and suspends to S3/S0ix anyway, even with
# standby-timeout-ac=0. Caused 8-minute schedule drift in stress runs.
# This setting is hidden by default - first unmask it via -attributes.
powercfg -attributes SUB_SLEEP 7bc4a2f9-d8fc-4469-b07b-33eb785aaca0 -ATTRIB_HIDE
powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_SLEEP 7bc4a2f9-d8fc-4469-b07b-33eb785aaca0 0
powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_SLEEP 7bc4a2f9-d8fc-4469-b07b-33eb785aaca0 0
# USB selective suspend off (мы пишем на флешку IpdromREC/Ventoy + FIO target диски)
powercfg /SETACVALUEINDEX SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
powercfg /SETDCVALUEINDEX SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
# PCIe ASPM off (мы стрессим PCIe-устройства: GPU, MegaRAID)
powercfg /SETACVALUEINDEX SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0
powercfg /SETDCVALUEINDEX SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0
# Apply changes
powercfg /SETACTIVE SCHEME_CURRENT

# Disable Automatic Maintenance & Modern Standby during stress.
# Automatic Maintenance triggers TiWorker.exe, DirectX updater, etc. — these
# can suspend our PowerShell process mid-Start-Sleep, breaking screenshot timing.
# Modern Standby (S0ix) on capable hardware throttles user processes despite
# our powercfg settings; PlatformAoAcOverride forces classic S3 sleep.
try {
    reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance" /v MaintenanceDisabled /t REG_DWORD /d 1 /f 2>&1 | Out-Null
    reg add "HKLM\System\CurrentControlSet\Control\Power" /v PlatformAoAcOverride /t REG_DWORD /d 0 /f 2>&1 | Out-Null
    schtasks /Change /TN "\Microsoft\Windows\TaskScheduler\Idle Maintenance" /DISABLE 2>&1 | Out-Null
    schtasks /Change /TN "\Microsoft\Windows\TaskScheduler\Regular Maintenance" /DISABLE 2>&1 | Out-Null
    schtasks /Change /TN "\Microsoft\Windows\Maintenance\WinSAT" /DISABLE 2>&1 | Out-Null
    Write-ColorOutput '  Automatic Maintenance and Modern Standby override disabled.' 'Green'
} catch {
    Write-ColorOutput "  Failed to disable maintenance/standby: $_" 'Yellow'
}

# Pagefile sanity check. Основной фикс размера pagefile живёт в setup_apps_and_theme.ps1
# (этап FirstLogon, ставит 16-32 GB ДО того, как стресс-тест запускается; ребут после
# FirstLogon применяет настройку).
# Здесь - только информационная проверка: если pagefile внезапно мал, печатаем
# чёткое предупреждение и идём дальше. Никаких автоматических ребутов - чтобы
# случайный ручной запуск не перезагрузил систему оператора.
try {
    $currentPagefile = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | Select-Object -First 1
    $pfMB = if ($currentPagefile) { [int]$currentPagefile.AllocatedBaseSize } else { 0 }

    if ($pfMB -lt 8192) {
        Write-ColorOutput "  WARNING: pagefile is only ${pfMB} MB. AIDA64 + 2x FurMark needs ≥16 GB." 'Red'
        Write-ColorOutput "  Stress test will likely fail with Out-of-virtual-memory (Event 2004)." 'Red'
        Write-ColorOutput "  To fix: run setup_apps_and_theme.ps1 (sets fixed 16-32 GB pagefile, requires reboot)." 'Yellow'
        Write-ColorOutput "  Continuing anyway, but expect AIDA/FurMark to die mid-test." 'Yellow'
    } else {
        Write-ColorOutput "  Pagefile OK ($pfMB MB)." 'Green'
    }
} catch {
    Write-ColorOutput "  Pagefile size check failed: $_" 'Yellow'
}

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

# Pipeline health tracking — если что-то критичное завалится, FFU не делается.
# Это защита от отгрузки клиенту машины с неуспешными тестами.
$script:PipelineHealthy = $true
$script:PipelineFailures = New-Object System.Collections.ArrayList

function Mark-PipelineFailure {
    param([string]$Reason)
    $script:PipelineHealthy = $false
    [void]$script:PipelineFailures.Add($Reason)
    Write-ColorOutput "  [PIPELINE-FAIL] $Reason" 'Red'
}

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

# Vendor-ID detection is language-independent. The previous Name-based filter
# missed localized "Microsoft Basic Display Adapter" (RU: "Базовый видеоадаптер
# (Майкрософт)"), so the basic VGA driver was counted as discrete -> FurMark
# was launched and instantly failed with "OpenGL 2.1 required".
# PCI vendor IDs: NVIDIA=10DE, AMD=1002, Intel=8086. Microsoft Basic has no VEN_.
$displayPnp = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue)
$nvidiaPnp  = @($displayPnp | Where-Object { $_.InstanceId -match 'VEN_10DE' })
$amdPnp     = @($displayPnp | Where-Object { $_.InstanceId -match 'VEN_1002' })
$intelPnp   = @($displayPnp | Where-Object { $_.InstanceId -match 'VEN_8086' })

Write-ColorOutput "  PnP display vendors: NVIDIA=$($nvidiaPnp.Count), AMD=$($amdPnp.Count), Intel=$($intelPnp.Count)" 'Gray'

# Only wait for nvidia-smi if NVIDIA is actually on the PCI bus. Previously
# $expectedNvidiaCount was forced to 1 even with no NVIDIA hardware, wasting
# 5 minutes on every iGPU-only machine.
$gpuLines = @()
if ($nvidiaPnp.Count -gt 0) {
    $gpuLines = @(Wait-NvidiaGpusReady -ExpectedCount $nvidiaPnp.Count -TimeoutSeconds 300)
} else {
    Write-ColorOutput '  No NVIDIA on PCI bus - skipping nvidia-smi wait.' 'Gray'
}

$discreteGpuCount = 0
if ($gpuLines.Count -gt 0) {
    $discreteGpuCount = $gpuLines.Count
    Write-ColorOutput "  NVIDIA GPUs via nvidia-smi: $($gpuLines -join '; ')" 'Gray'
} elseif ($nvidiaPnp.Count -gt 0) {
    $discreteGpuCount = $nvidiaPnp.Count
    Write-ColorOutput "  nvidia-smi silent but PnP reports $($nvidiaPnp.Count) NVIDIA device(s) - counting as discrete." 'Yellow'
}

# AMD: discrete only if FriendlyName matches a known discrete family. Driver
# INF names are usually English even on localized Windows, so this is safe.
# Plain "AMD Radeon Graphics" / "AMD Radeon(TM) Graphics" is the iGPU and is excluded.
$amdDiscrete = @($amdPnp | Where-Object {
    $_.FriendlyName -match '(?i)Radeon\s+(RX|PRO|R9|R7|VII|Vega|HD\s*[5-9]\d{3})|FirePro|Instinct|W[57]\d{3}'
})
if ($amdDiscrete.Count -gt 0) {
    Write-ColorOutput "  AMD discrete GPUs: $($amdDiscrete.Count) ($($amdDiscrete.FriendlyName -join '; '))" 'Gray'
    $discreteGpuCount += $amdDiscrete.Count
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
Write-ColorOutput "  Full aida_fio_furmark call: $testScript $($testArgs -join ' ')" 'DarkGray'

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

Write-ColorOutput "  Launching: $psExe $($argumentList -join ' ')" 'DarkGray'
$testStartTime = Get-Date
try {
    & $psExe @argumentList
    $testExitCode = $LASTEXITCODE
}
finally {
    $testDuration = [math]::Round(((Get-Date) - $testStartTime).TotalMinutes, 1)
    Write-ColorOutput "  aida_fio_furmark.ps1 returned after ${testDuration} min, exit code: $testExitCode" 'Gray'
    Unregister-ScheduledTask -TaskName $watchdogTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

if ($testExitCode -ne 0) {
    Write-ColorOutput "  Test finished with exit code $testExitCode (non-zero) - continuing to reports and archive." 'Red'
    Mark-PipelineFailure "Stress test (aida_fio_furmark.ps1) exited with code $testExitCode"
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

Write-ColorOutput '[4.6/7] Generating SMART report...' 'Yellow'
$smartScript = Join-Path $testFolder 'smart.ps1'
if (Test-Path $smartScript) {
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $smartScript `
        -ComputerName $computerName -OutputFolder $reportsDir -NoPause
    Write-ColorOutput '  SMART report generated.' 'Green'
} else {
    Write-Warning '  smart.ps1 not found in test folder'
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
            # Upload failure НЕ блокирует FFU — это серверная проблема.
            # Только warning, пайплайн продолжается.
            Write-Warning '  Upload failed (server-side issue, not a pipeline failure)'
        }
    } catch {
        Write-Warning "  Archive or upload error: $_"
        Mark-PipelineFailure "Archive creation failed: $_"
    }
} else {
    Write-Warning "  Results folder not found: $baseDir"
    Mark-PipelineFailure "Results folder $baseDir not found - no reports were generated"
}

# ===================== [6.5/7] CLEANUP TEST ARTIFACTS =====================
# Удаляем всё, что относится к процессу тестирования, перед FFU-захватом.
# Цель: чтобы образ восстановления содержал чистую ОС без тестового мусора.
Write-ColorOutput '[6.5/7] Cleaning up test artifacts before FFU capture...' 'Yellow'

# 1. Деинсталляция тестовых утилит (fio, smartmontools)
$uninstallScript = Join-Path $testFolder 'AllUnin.ps1'
if (Test-Path $uninstallScript) {
    try {
        Write-ColorOutput "  Uninstalling test tools (fio, smartmontools)..." 'Gray'
        & $psExe -NoProfile -ExecutionPolicy Bypass -File $uninstallScript
        Write-ColorOutput '  Test tools uninstalled.' 'Green'
    } catch {
        Write-Warning "  AllUnin.ps1 failed: $_"
    }
} else {
    Write-Warning "  AllUnin.ps1 not found at $uninstallScript - test tools not removed."
}

# 2. Удаляем архив с рабочего стола
$desktopPath = [Environment]::GetFolderPath('Desktop')
$archivePattern = "$env:COMPUTERNAME`_*.zip"
$archives = Get-ChildItem -LiteralPath $desktopPath -Filter $archivePattern -File -ErrorAction SilentlyContinue
foreach ($a in $archives) {
    try {
        Remove-Item -LiteralPath $a.FullName -Force -ErrorAction Stop
        Write-ColorOutput "  Removed archive: $($a.Name)" 'Gray'
    } catch {
        Write-Warning "  Could not remove $($a.Name): $_"
    }
}

# 3. Удаляем папку с отчётами и скринами
$resultsFolder = Join-Path $desktopPath $env:COMPUTERNAME
if (Test-Path $resultsFolder) {
    try {
        Remove-Item -LiteralPath $resultsFolder -Recurse -Force -ErrorAction Stop
        Write-ColorOutput "  Removed reports folder: $resultsFolder" 'Gray'
    } catch {
        Write-Warning "  Could not remove $resultsFolder`: $_"
    }
}

# 4. Очистка корзины (всех буков, на случай если что-то туда упало)
try {
    Clear-RecycleBin -Force -ErrorAction Stop
    Write-ColorOutput "  Recycle Bin emptied." 'Gray'
} catch {
    # PS 5.1 без Clear-RecycleBin - используем COM
    try {
        $shell = New-Object -ComObject Shell.Application
        $recycleBin = $shell.NameSpace(10)  # 0xA = Recycle Bin
        $recycleBin.Items() | ForEach-Object { Remove-Item $_.Path -Recurse -Force -ErrorAction SilentlyContinue }
        Write-ColorOutput "  Recycle Bin emptied (via COM)." 'Gray'
    } catch {
        Write-Warning "  Recycle Bin cleanup failed: $_"
    }
}

# 5. Очистка временных файлов от стресса
foreach ($tempPath in @(
    "$env:TEMP",
    "$env:WinDir\Temp"
)) {
    if (Test-Path $tempPath) {
        Get-ChildItem -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(ipdrom_|fio_job_|fio_test_)' } |
            ForEach-Object {
                try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch {}
            }
    }
}
Write-ColorOutput "  Temp files cleaned." 'Gray'

Write-ColorOutput "[6.5/7] Cleanup completed. OS is clean for FFU capture." 'Green'

# ===================== PIPELINE HEALTH GATE =====================
# Не запускаем FFU-захват если что-то критичное завалилось.
# Машину с битыми тестами или незавершёнными артефактами клиенту отгружать нельзя.
if (-not $script:PipelineHealthy) {
    Write-ColorOutput "`n========================================" 'Red'
    Write-ColorOutput '   FFU CAPTURE BLOCKED' 'Red'
    Write-ColorOutput '========================================' 'Red'
    Write-ColorOutput 'Pipeline had failures - FFU recovery image will NOT be created:' 'Red'
    foreach ($f in $script:PipelineFailures) {
        Write-ColorOutput "  - $f" 'Red'
    }
    Write-ColorOutput "`nFix the issues above and either:" 'Yellow'
    Write-ColorOutput '  1) Re-run the full pipeline from a clean install, OR' 'Yellow'
    Write-ColorOutput '  2) Capture FFU manually after fixing (Prepare + Trigger).' 'Yellow'

    # Записываем подробный маркер для оператора/диагностики
    $failureMarker = Join-Path $env:ProgramData 'IPDROM_PipelineFailed.flag'
    $marker = "Pipeline failure at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n"
    $marker += "Failures:`r`n"
    foreach ($f in $script:PipelineFailures) { $marker += "  - $f`r`n" }
    Set-Content -LiteralPath $failureMarker -Value $marker -Encoding utf8 -Force
    Write-ColorOutput "`nFailure details saved: $failureMarker" 'Gray'

    # ВАЖНО: ставим Completed.flag чтобы launcher не зациклился на повторных стрессах.
    # Если оператор хочет переделать - руками удаляет оба флага.
    if (-not (Test-Path $flagFile)) {
        New-Item -Path $flagFile -ItemType File -Force | Out-Null
    }
    Write-ColorOutput "`n========================================" 'Red'
    Write-ColorOutput '   PIPELINE COMPLETED WITH FAILURES' 'Red'
    Write-ColorOutput '========================================' 'Red'
    exit 1
}

Write-ColorOutput '  Pipeline healthy - proceeding to FFU capture.' 'Green'

# ===================== [6.7/7] FFU CAPTURE =====================
Write-ColorOutput '[6.7/7] Creating FFU recovery image (reboot into WinPE)...' 'Yellow'
$prepareScript = Join-Path $scriptDir 'Prepare-IpdromRecFlash.ps1'
$triggerScript = Join-Path $scriptDir 'Invoke-FfuCaptureReboot.ps1'
$patchScript   = Join-Path $scriptDir 'Patch-BootWim.ps1'
$winpeFolder   = Join-Path (Split-Path $scriptDir -Parent) 'winpe'
$patchedWim    = Join-Path $winpeFolder 'boot_patched.wim'

# Step 0: auto-patch boot.wim if not yet patched on this Test ISO
# (typical for first-ever run of a fresh Test ISO that ships with source boot.wim only)
if (-not (Test-Path $patchedWim)) {
    if (Test-Path $patchScript) {
        Write-ColorOutput "  boot_patched.wim missing - running Patch-BootWim.ps1 first..." 'Yellow'
        try {
            & $patchScript
            if ($LASTEXITCODE -eq 0 -and (Test-Path $patchedWim)) {
                Write-ColorOutput '  boot_patched.wim created.' 'Green'
            } else {
                Write-Warning "  Patch-BootWim failed (exit $LASTEXITCODE). FFU capture will be skipped."
            }
        } catch {
            Write-Warning "  Patch-BootWim threw: $_"
        }
    } else {
        Write-Warning "  Patch-BootWim.ps1 not found at $patchScript"
    }
}

# Step 1: prepare the IpdromREC flash (FRESH or REFRESH)
$flashReady = $false
if ((Test-Path $prepareScript) -and (Test-Path $patchedWim)) {
    try {
        & $prepareScript
        if ($LASTEXITCODE -eq 0) {
            Write-ColorOutput '  IpdromREC flash prepared.' 'Green'
            $flashReady = $true
        } else {
            Write-Warning "  Prepare-IpdromRecFlash.ps1 exited with code $LASTEXITCODE - skipping capture."
        }
    } catch {
        Write-Warning "  Prepare-IpdromRecFlash failed: $_"
    }
} elseif (-not (Test-Path $patchedWim)) {
    Write-Warning "  boot_patched.wim still missing after auto-patch attempt - skipping capture."
} else {
    Write-Warning "  Prepare-IpdromRecFlash.ps1 not found - falling back to legacy Create-FullBackup.ps1"
    $backupScript = Join-Path $scriptDir 'Create-FullBackup.ps1'
    if (Test-Path $backupScript) {
        try { & $backupScript -BackupLabel 'IpdromREC' } catch { Write-Warning $_ }
    }
}

# Step 2: arm BootNext and reboot into WinPE (only if flash is ready)
if ($flashReady -and (Test-Path $triggerScript)) {
    Write-ColorOutput '  Arming BootNext and rebooting into WinPE for FFU capture...' 'Yellow'
    # Trigger writes the IPDROM_StressTest_Completed.flag itself before reboot,
    # so we don't need to write it here.
    & $triggerScript
    # If trigger returned (didn't reboot), something went wrong - log and continue
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "  Invoke-FfuCaptureReboot returned exit code $LASTEXITCODE (no reboot)."
    }
}

# Fallback: if we got here without rebooting (no flash / trigger failed), mark the
# test as complete so the launcher won't loop. The trigger script writes this flag
# itself when it rebooots, but on a no-reboot path we need to do it ourselves.
if (-not (Test-Path $flagFile)) {
    New-Item -Path $flagFile -ItemType File -Force | Out-Null
}
Write-ColorOutput "`n========================================" 'Green'
Write-ColorOutput '   STRESS TEST COMPLETED!' 'Green'
Write-ColorOutput '========================================' 'Green'