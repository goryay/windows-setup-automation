<#
.SYNOPSIS
    Automatic stress test (AIDA64 + FurMark + FIO)
#>
param(
    [int]$DurationMinutes = 30
)

$ErrorActionPreference = 'Stop'

# Задачу автоподъёма IPDROM_AutoStressTest_AfterReboot здесь НЕ СНИМАЕМ (01.10.2026).
# Раньше снимали первой же строкой - и этим лишали конвейер возможности подхватить
# прогон, оборванный перезагрузкой: задачи уже нет, поднимать нечем, машина просто
# стоит с автовходом. Теперь задачу снимает ровно тот, кто знает исход:
# launch_auto_stress_after_reboot.ps1 (Close-ResumeChain по возврату этого скрипта,
# либо ранний выход по флагу завершения после захвата FFU).
# Повторного запуска в одной загрузке не будет: у задачи MultipleInstances=IgnoreNew,
# а лончер держит замок StressStarted.lock с отметкой текущей загрузки.

# Remove orphaned watchdog from previous crash (BSOD does not run finally block)
Unregister-ScheduledTask -TaskName 'IPDROM_Watchdog_Reboot' -Confirm:$false -ErrorAction SilentlyContinue

# ===================== LOGGING =====================
$script:StressLogDir  = Join-Path $env:ProgramData 'IPDROM\Logs'
$script:StressLogFile = Join-Path $script:StressLogDir ("auto_stress_test_{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $script:StressLogDir | Out-Null

# ============ pwsh 7 / Intel CET crash guard (probe-then-fix, non-invasive) ============
# On CPUs with Intel CET user-mode shadow stacks (e.g. Xeon Silver 4510 / Sapphire
# Rapids), PowerShell 7 (.NET 9 coreclr) fail-fasts at process init with exit code
# -1073740286 (0xC0000602 STATUS_FAIL_FAST_EXCEPTION) and the assert
# "!AreShadowStacksEnabled() || UseSpecialUserModeApc()", when the OS lacks Special
# User Mode APC support (un-updated Server 2022 20348). Every pwsh child (Axxon
# installer + the stress test, both launched via pwsh) then dies instantly.
# We PROBE pwsh first and disable its user shadow stack ONLY if it actually crashes,
# so machines where pwsh already works (Pro/IoT / updated OS) are left fully untouched.
# (DOTNET_CETCompat=0 does NOT help - the OS creates the shadow stack at process
# launch, before the runtime reads the var.) Confirmed on SL111111-008.
try {
    $pwshExe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if ($pwshExe) {
        $probe = Start-Process -FilePath $pwshExe -ArgumentList '-NoProfile','-NoLogo','-Command','exit 0' -PassThru -WindowStyle Hidden -ErrorAction Stop
        if ($probe.WaitForExit(20000)) { $probeCode = $probe.ExitCode } else { try { $probe.Kill() } catch {}; $probeCode = 'timeout' }
        if ($probeCode -eq -1073740286) {
            Write-Host 'pwsh 7 crashes at init (Intel CET) - disabling its user shadow stack...' -ForegroundColor Yellow
            Set-ProcessMitigation -Name 'pwsh.exe' -Disable UserShadowStack -ErrorAction Stop
            Add-Content -Path $script:StressLogFile -Value ("[{0}] pwsh CET crash detected (0xC0000602) -> UserShadowStack disabled for pwsh.exe." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8 -ErrorAction SilentlyContinue
        } else {
            Add-Content -Path $script:StressLogFile -Value ("[{0}] pwsh probe exit={1} - no CET mitigation needed (system untouched)." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $probeCode) -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    }
} catch {
    Add-Content -Path $script:StressLogFile -Value ("[{0}] WARNING: pwsh CET check failed: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message) -Encoding UTF8 -ErrorAction SilentlyContinue
}

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
        #
        # EAP='Continue' на время вызова ОБЯЗАТЕЛЕН. curl с -sS пишет ошибку связи в
        # stderr, а '2>&1' превращает её в ErrorRecord; при общескриптовом
        # $ErrorActionPreference='Stop' это становится терминирующей ошибкой, функция
        # не успевает вернуть $false, и вызывающий код улетает в catch с
        # Mark-PipelineFailure. Из-за этого недоступность сервера отчётов роняла весь
        # конвейер и блокировала FFU (SL111111-009, 31.08.2026: curl (7) Timed out).
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $curlOutput = & curl.exe -sS -F $formArg -w "`nHTTPSTATUS=%{http_code}`n" $ServerUrl 2>&1
            $curlExit   = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
        }

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

function Get-FilesystemSignatureFromBytes {
    <#
      Чистый разбор буфера: ни ввода-вывода, ни состояния. Вынесено из
      Get-VolumeSignature отдельно именно для проверяемости - смещения и
      магические числа можно прогнать на синтетических буферах, не имея под
      рукой диска с ext4 и прав администратора.
      Возвращает имя найденной ФС или $null.
    #>
    param(
        [Parameter(Mandatory)][byte[]]$Buffer,
        [Parameter(Mandatory)][int]$Length
    )

    $txt = {
        param([int]$Off, [int]$Len)
        if (($Off + $Len) -gt $Length) { return '' }
        -join ($Buffer[$Off..($Off + $Len - 1)] | ForEach-Object { [char]$_ })
    }

    # Сначала то, что Windows обязан был опознать сам. Если сигнатура есть, а
    # смонтировать не удалось - файловая система повреждена, а не отсутствует,
    # и форматировать её тем более нельзя.
    if ((& $txt 3 8) -eq 'NTFS    ') { return 'NTFS (present but not mounted - damaged?)' }
    if ((& $txt 3 8) -eq 'EXFAT   ') { return 'exFAT (present but not mounted - damaged?)' }
    if ((& $txt 54 5) -eq 'FAT16' -or (& $txt 54 5) -eq 'FAT12' -or (& $txt 82 5) -eq 'FAT32') { return 'FAT' }

    # Чужие для Windows файловые системы: их он не читает и показывает 'Unknown'
    # ровно так же, как раздел, который никогда не форматировали.
    if ((& $txt 0 4) -eq 'XFSB')                                                  { return 'XFS' }
    if ($Length -ge 0x43A -and $Buffer[0x438] -eq 0x53 -and $Buffer[0x439] -eq 0xEF) { return 'ext2/3/4' }
    if ((& $txt 0x10040 8) -eq '_BHRfS_M')                                        { return 'btrfs' }
    if ((& $txt 0x200 8)   -eq 'LABELONE')                                        { return 'LVM2' }

    return $null
}

function Get-VolumeSignature {
    <#
      Читает НАЧАЛО тома сырыми байтами и ищет сигнатуры известных файловых систем.
      Возвращает имя найденной ФС, строку 'unreadable: ...' или $null, если ничего
      не нашлось.

      Зачем (07.10.2026). Windows показывает FileSystemType='Unknown' в ДВУХ разных
      случаях: раздел никогда не форматировали И на разделе чужая ФС (ext4/XFS/
      btrfs/LVM), которую Windows читать не умеет. В обоих случаях он не видит там
      ни одного файла - читать нечем. Поэтому проверка "файлов нет, значит пусто"
      уверенно разрешает формат ровно тогда, когда на диске лежат чужие данные.
      Сигнатура в суперблоке такой двусмысленности не имеет.

      Любой неожиданный исход (том не читается, прочитали меньше сектора) трактуем
      как "там что-то есть" и форматировать запрещаем: безопасный отказ лучше.
    #>
    param([Parameter(Mandatory)][string]$DriveLetter)

    $buf  = New-Object byte[] 131072     # 128 КБ: хватает до суперблока btrfs (0x10040)
    $read = 0
    try {
        $fs = New-Object System.IO.FileStream(("\\.\{0}:" -f $DriveLetter), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { $read = $fs.Read($buf, 0, $buf.Length) } finally { $fs.Dispose() }
    } catch {
        return ("unreadable: {0}" -f $_.Exception.Message)
    }
    if ($read -lt 512) { return ("unreadable: only {0} byte(s) read" -f $read) }

    return (Get-FilesystemSignatureFromBytes -Buffer $buf -Length $read)
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
        $pdQuery = Invoke-StorCliSafe -StorCliPath $StorCliPath -Arguments @("/c$ctrl/eall/sall", 'show') -TimeoutSeconds 30
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

    $result = Invoke-StorCliSafe -StorCliPath $StorCliPath -Arguments @("/c$ctrl", 'add', 'vd', "type=$level", "drives=$drivesArg", "strip=$strip") -TimeoutSeconds 90
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
            Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel 'Archive' -Confirm:$false -Force -ErrorAction Stop | Out-Null

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

    # Случай: диск инициализирован (GPT/MBR), но usable data-партиций нет
    # (например диск 0 - RAID 6TB Не распределена; диски 2/3 - чистые NVMe;
    # свежесозданный MegaRAID VD с одним только MSR/Reserved — тоже сюда).
    # Проверяем именно $partitions.Count (после фильтра), не $allPartitions.Count:
    # если единственная партиция — Reserved/MSR (16 MB), пользовательских данных нет,
    # надо создать data-партицию поверх свободного места (New-Partition -UseMaximumSize
    # аллокирует оставшееся пространство после MSR).
    if ($partitions.Count -eq 0) {
        if (-not $AllowCreatePartition) {
            Write-RaidLog "Disk $($Disk.Number) has no usable partitions but auto-create is not allowed. Skipped."
            return @()
        }
        try {
            $letter = Get-FreeDriveLetter
            Write-ColorOutput "  Disk $($Disk.Number) initialized but empty. Creating NTFS partition, letter $letter`: ..." 'Yellow'
            Write-RaidLog "Disk $($Disk.Number) has $($Disk.PartitionStyle) with $($allPartitions.Count) non-data partition(s) - creating NTFS volume $letter`:"

            $partition = New-Partition -DiskNumber $Disk.Number -UseMaximumSize -DriveLetter $letter -ErrorAction Stop
            Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel 'Archive' -Confirm:$false -Force -ErrorAction Stop | Out-Null

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
                $letter = $partition.DriveLetter.ToString().ToUpper()
            } else {
                $letter = Get-FreeDriveLetter
                Write-ColorOutput "  Assigning drive letter $letter`: to disk $($Disk.Number), partition $($partition.PartitionNumber)..." 'Yellow'
                Write-RaidLog "Assigning drive letter $letter`: to disk $($Disk.Number), partition $($partition.PartitionNumber)"

                Add-PartitionAccessPath -DiskNumber $Disk.Number -PartitionNumber $partition.PartitionNumber -DriveLetter $letter -ErrorAction Stop
            }

            # --- ДЫРА, ЗАКРЫТАЯ 07.10.2026 ---
            # Раньше здесь всё и заканчивалось: букву забрали и пошли дальше. Файловую
            # систему не смотрели НИКОГДА. Из-за этого раздел, который существует, но
            # не отформатирован, проходил весь путь молча, а потом отбраковывался
            # фильтром NTFS ниже - и стресс-тест час шёл без дисковой нагрузки, при
            # этом рапортуя об успехе (SL111111-026 и -027, 06-07.10.2026).
            # Замкнутый круг: не форматируем, потому что раздел есть; отбраковываем,
            # потому что он не отформатирован.
            #
            # Форматируем ТОЛЬКО когда совпало всё:
            #   - разрешено создание ($AllowCreatePartition: диск на MegaRAID, не
            #     загрузочный, не системный, не USB, и в raid_config.json включено
            #     init_if_present_but_raw);
            #   - Windows не опознал файловую систему;
            #   - и сырое чтение начала тома не нашло ни одной известной сигнатуры.
            # Последнее условие - главное: оно отличает "никогда не форматировали"
            # от "чужая ФС, которую Windows не читает". См. Get-VolumeSignature.
            $vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
            $fsType = if ($vol) { "$($vol.FileSystemType)" } else { '<no volume>' }

            if ($vol -and $vol.FileSystemType -eq 'NTFS') {
                $letters += $letter
                continue
            }

            if (-not $AllowCreatePartition) {
                Write-RaidLog "Drive $letter`: FileSystemType='$fsType' but auto-create is not allowed - left untouched."
                $letters += $letter
                continue
            }
            if (-not $vol) {
                Write-RaidLog "Drive $letter`: no volume object - cannot inspect or format, left untouched."
                $letters += $letter
                continue
            }

            $sig = Get-VolumeSignature -DriveLetter $letter
            if ($sig) {
                Write-RaidLog "REFUSING to format $letter`: - raw scan found '$sig'. Partition is NOT empty; leaving it alone."
                Write-ColorOutput "  Drive $letter`: not NTFS but carries a '$sig' signature - NOT formatting." 'Yellow'
                $letters += $letter
                continue
            }

            Write-ColorOutput "  Drive $letter`: FileSystemType='$fsType', no filesystem signature found - formatting as NTFS..." 'Yellow'
            Write-RaidLog "Formatting $letter`: (disk $($Disk.Number), partition $($partition.PartitionNumber), size $([math]::Round($partition.Size/1GB,1)) GB): FileSystemType='$fsType', raw scan found nothing."
            try {
                Format-Volume -DriveLetter $letter -FileSystem NTFS -NewFileSystemLabel 'Archive' -Confirm:$false -Force -ErrorAction Stop | Out-Null
                $after = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
                Write-RaidLog "Formatted $letter`: -> FileSystemType='$(if ($after) { $after.FileSystemType } else { '<unknown>' })'"
            } catch {
                Write-RaidLog "Format of $letter`: FAILED: $_"
            }
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

    # SL-driven RAID: apply_raid_groups читает group_* из SL-файла и создаёт VD по каждой
    # data-группе через StorCLI. Запускаем ДО legacy raid_config.json проверки.
    # Скрипт сам skip'ает system-группы и группы без подходящих дисков.
    # Если SL нет или в нём нет group_* - apply_raid_groups просто выйдет 0.
    $raidGroupsScript = Join-Path $UsbRoot 'customization\scripts\apply_raid_groups.ps1'
    if (Test-Path $raidGroupsScript) {
        Write-ColorOutput '  Running apply_raid_groups (SL-driven RAID creation)...' 'Yellow'
        Write-RaidLog '========== apply_raid_groups =========='
        try {
            & $raidGroupsScript -UsbRoot $UsbRoot -Execute
            if ($LASTEXITCODE -ne 0) {
                Write-RaidLog "apply_raid_groups exited with $LASTEXITCODE (continuing with legacy fallback)"
            }
        } catch {
            Write-RaidLog "apply_raid_groups failed: $_  (continuing with legacy fallback)"
        }
    } else {
        Write-RaidLog "apply_raid_groups.ps1 not found at $raidGroupsScript - using legacy raid_config.json only."
    }

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

    # Финальная выборка букв для FIO. К прежним фильтрам (не boot/system, не USB,
    # диск Online, буква не совпадает с системной) добавлен фильтр по файловой
    # системе — берём только NTFS. Причина: недоинициализированные MegaRAID VD
    # могут получить букву от Windows на RAW/MSR-партицию (Explorer покажет её как
    # "Локальный диск (X:)" без размера); FIO при попытке открыть файл на RAW-томе
    # падает с exit 1 и рушит весь стресс-тест. NTFS-фильтр гарантирует что каждая
    # буква в списке — реально пригодный для записи том.
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
        Where-Object {
            $letter = $_.DriveLetter.ToString()
            $vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
            if (-not $vol) {
                Write-RaidLog "Skipping drive $letter`: no Get-Volume result (partition without accessible volume)."
                return $false
            }
            if ($vol.FileSystemType -ne 'NTFS') {
                Write-RaidLog "Skipping drive $letter`: FileSystemType='$($vol.FileSystemType)', want NTFS (RAW/FAT partitions are not FIO-safe)."
                return $false
            }
            return $true
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

function Get-NvidiaDriverVersion {
    # Версия ФАКТИЧЕСКИ установленного драйвера, например '596.86'.
    # Пустая строка = драйвера нет либо nvidia-smi недоступен.
    $smi = Get-NvidiaSmiPath
    if (-not $smi) { return '' }
    try {
        $v = @(& $smi --query-gpu=driver_version --format=csv,noheader 2>$null |
               Where-Object { $_ -and $_.Trim() } | Select-Object -First 1)
        if ($v.Count -gt 0) { return $v[0].Trim() }
    } catch {}
    return ''
}

function Get-NvidiaVersionFromInstallerName {
    # Пакеты NVIDIA называются '<версия>-quadro-...exe' / '<версия>-desktop-...exe',
    # то есть версия - это первое, что стоит в имени файла: '596.86-quadro-...'.
    param([string]$Name)
    if ($Name -match '^\s*(\d{3,4}\.\d{1,3})') { return $Matches[1] }
    return ''
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

function Select-NvidiaDriverForModel {
    # Picks the correct NVIDIA driver .exe for the declared GPU model - fully
    # automatic from gpu_discrete_model, the operator never chooses. Different
    # cards need different NVIDIA branches and one payload can hold several, so
    # picking "the largest file" is wrong. Rules (confirmed with the lineup):
    #   Quadro / NVS (pro)                 -> the quadro/rtx-enterprise driver
    #   legacy Kepler (GT 730/710, GT 6xx) -> R470 branch (47x.xx) - last Kepler
    #   anything else (modern GeForce)     -> newest desktop (non-quadro) driver
    param([string]$DriversDir, [string]$GpuModel)

    $exes = @(Get-ChildItem -LiteralPath $DriversDir -Filter '*.exe' -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -match '(?i)quadro|geforce|nvidia|desktop|-dch-|rtx|^\d+\.\d{2,}-' })
    if ($exes.Count -eq 0) { return $null }
    if ($exes.Count -eq 1) { return $exes[0] }

    $m = "$GpuModel"

    # Professional cards -> quadro/rtx-enterprise driver. NVIDIA dropped the
    # "Quadro" name: modern pro cards are "RTX A<nnn>" (Ampere: A400/A2000/A4000..),
    # "RTX <nnnn> Ada Generation" (Ada), and "T<nnn>" (Turing). Match all of them,
    # not just legacy Quadro/NVS, or an RTX A400 falls through to the GeForce driver.
    if ($m -match '(?i)\bquadro\b|\bnvs\b|\bRTX\s*A\d|\bT\d{3,4}\b|Ada\s+Generation') {
        $pick = $exes | Where-Object { $_.Name -match '(?i)quadro|rtx' } |
                Sort-Object Length -Descending | Select-Object -First 1
        if ($pick) { return $pick }
    }
    # Legacy low-end Kepler (GT 710/730, GT 6xx/7xx) -> R470 (47x.xx), the last
    # branch that still supports Kepler. Newer drivers refuse these cards.
    elseif ($m -match '(?i)\bGT[-\s]*7\d0\b|\bGT[-\s]*6\d0\b|\bGT[-\s]*710\b') {
        $pick = $exes | Where-Object { $_.Name -match '^47\d\.' } |
                Sort-Object Length -Descending | Select-Object -First 1
        if ($pick) { return $pick }
    }
    # Modern GeForce -> newest desktop (non-quadro) driver (biggest = newest set).
    $pick = $exes | Where-Object { $_.Name -match '(?i)desktop' -and $_.Name -notmatch '(?i)quadro' } |
            Sort-Object Length -Descending | Select-Object -First 1
    if ($pick) { return $pick }

    # Fallback: largest NVIDIA installer.
    return ($exes | Sort-Object Length -Descending | Select-Object -First 1)
}

function Install-NvidiaDriverIfNeeded {
    # Устанавливает драйвер NVIDIA ДО стресс-теста. Без него дискретные карты
    # висят на "Базовом видеоадаптере (Майкрософт)", nvidia-smi молчит, а FurMark
    # не может нагрузить GPU (нужен реальный OpenGL/Vulkan-драйвер). deploy_extras
    # кладёт драйвер на флешку, но это ПОСЛЕ теста - поэтому ставим здесь.
    # Пакет NVIDIA - самораспаковывающийся; '-s -noreboot' ставит молча без
    # перезагрузки посреди конвейера (на машине без прежнего драйвера карта
    # переключается с Basic на NVIDIA без ребута).
    param([string]$UsbRoot)

    # Приёмка 28.08.2026: в системе должна быть не только рабочая карта, но и
    # Панель управления NVIDIA, причём нашей версии. Голый INF (из образа или из
    # Windows Update) даёт драйвер БЕЗ панели и обычно старее нашего пакета -
    # поэтому "драйвер уже активен" больше не повод пропускать установку.
    # Признак того, что отработал именно НАШ полный инсталлятор - наличие панели:
    # MSIX-приложение для DCH-драйверов либо классический nvcplui.exe.
    #
    # Прогон 010 (10.09.2026): на Win11 IoT драйвер И панель оказались на месте
    # СРАЗУ после установки ОС - шаг пропустился, и какая версия уехала в FFU,
    # по логу установить было нельзя. Проверки "панель есть" недостаточно: она
    # ничего не говорит о версии. Поэтому решение о пропуске принимается ниже,
    # ПОСЛЕ выбора нашего пакета, и только при совпадении версий.
    $panelPresent = $false
    try {
        if (Get-AppxPackage -AllUsers -Name 'NVIDIACorp.NVIDIAControlPanel' -ErrorAction SilentlyContinue) { $panelPresent = $true }
    } catch {}
    if (-not $panelPresent) {
        $nvcplui = Join-Path $env:ProgramFiles 'NVIDIA Corporation\Control Panel Client\nvcplui.exe'
        if (Test-Path -LiteralPath $nvcplui) { $panelPresent = $true }
    }

    $driverActive     = ((Get-NvidiaGpuLines).Count -gt 0)
    $installedVersion = Get-NvidiaDriverVersion
    Write-ColorOutput ("  NVIDIA state: driver={0} version='{1}' controlPanel={2}" -f `
        $(if ($driverActive) { 'active' } else { 'absent' }),
        $(if ($installedVersion) { $installedVersion } else { '<none>' }),
        $(if ($panelPresent) { 'present' } else { 'missing' })) 'Gray'
    Write-RaidLog ("NVIDIA state before install: active={0} version='{1}' panel={2}" -f $driverActive, $installedVersion, $panelPresent)

    # Read the declared GPU model from the SL config so the RIGHT driver branch
    # is chosen automatically (no operator choice).
    $gpuModel = ''
    try {
        $slName = (Get-ItemProperty -Path 'HKLM:\Software\IPDROM' -Name 'SL' -ErrorAction SilentlyContinue).SL
        if ($slName) {
            $cfg = Join-Path $UsbRoot "config\$slName.txt"
            if (-not (Test-Path -LiteralPath $cfg)) { $cfg = "C:\IPDROM\config\$slName.txt" }
            if (Test-Path -LiteralPath $cfg) {
                $ln = Get-Content -LiteralPath $cfg -ErrorAction SilentlyContinue |
                      Where-Object { $_ -match '^gpu_discrete_model\s*=' } | Select-Object -First 1
                if ($ln) { $gpuModel = ($ln -replace '^gpu_discrete_model\s*=','').Trim() }
            }
        }
    } catch {}
    Write-ColorOutput "  GPU model from SL: '$gpuModel'" 'Gray'

    $drvDirs = @(
        (Join-Path $UsbRoot 'software\docs\drivers'),
        'C:\IPDROM\software\docs\drivers'
    )
    $nvExe = $null
    foreach ($d in $drvDirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $nvExe = Select-NvidiaDriverForModel -DriversDir $d -GpuModel $gpuModel
        if ($nvExe) { break }
    }
    if ($nvExe) { Write-ColorOutput "  Selected NVIDIA driver for '$gpuModel': $($nvExe.Name)" 'Gray' }
    if (-not $nvExe) {
        if ($driverActive) {
            Write-ColorOutput "  NVIDIA installer not found in payload - keeping the driver already in the OS (version '$installedVersion')." 'Yellow'
            Write-RaidLog "NVIDIA installer not found; leaving pre-existing driver version '$installedVersion'."
        } else {
            Write-ColorOutput '  NVIDIA installer not found in payload - GPU stress may run without driver.' 'Yellow'
            Write-RaidLog 'NVIDIA installer .exe not found under software\docs\drivers.'
        }
        return
    }

    # === Решение: ставить или пропустить ===
    # Пропускаем ТОЛЬКО когда в системе стоит ровно наша версия и панель на месте.
    # Иначе ставим: заказчику должен уезжать аттестованный нами драйвер, а не тот,
    # что подобрала установка Windows.
    $targetVersion = Get-NvidiaVersionFromInstallerName -Name $nvExe.Name
    if (-not $targetVersion) {
        Write-ColorOutput "  Could not read version from installer name '$($nvExe.Name)' - installing unconditionally." 'Yellow'
        Write-RaidLog "NVIDIA: version not parsable from '$($nvExe.Name)'; forcing install."
    } elseif ($driverActive -and $panelPresent -and $installedVersion -eq $targetVersion) {
        Write-ColorOutput "  NVIDIA $targetVersion + Control Panel already present - install skipped." 'Gray'
        Write-RaidLog "NVIDIA install skipped: installed version '$installedVersion' matches payload '$targetVersion'."
        return
    } elseif ($driverActive -and $installedVersion -and $installedVersion -ne $targetVersion) {
        Write-ColorOutput "  NVIDIA version mismatch: installed '$installedVersion', payload '$targetVersion' - reinstalling to the qualified version." 'Yellow'
        Write-RaidLog "NVIDIA version mismatch: installed '$installedVersion' != payload '$targetVersion'; reinstalling."
    } elseif ($driverActive -and -not $panelPresent) {
        Write-ColorOutput '  NVIDIA driver active but Control Panel missing (INF-only driver) - installing full package.' 'Yellow'
        Write-RaidLog 'NVIDIA: driver present without Control Panel - forcing full package install.'
    }

    Write-ColorOutput "  Installing NVIDIA driver before stress test: $($nvExe.Name)" 'Yellow'
    Write-ColorOutput '  (silent install, several minutes - required so FurMark can load the GPUs)...' 'Gray'
    Write-RaidLog "Installing NVIDIA driver: $($nvExe.FullName) -s -noreboot -clean"
    try {
        $p = Start-Process -FilePath $nvExe.FullName -ArgumentList '-s','-noreboot','-clean' -Wait -PassThru -ErrorAction Stop
        Write-ColorOutput "  NVIDIA installer finished (exit=$($p.ExitCode))." 'Gray'
        Write-RaidLog "NVIDIA installer exit=$($p.ExitCode)"
    } catch {
        Write-ColorOutput "  NVIDIA driver install failed (non-fatal): $_" 'Yellow'
        Write-RaidLog "NVIDIA driver install threw: $_"
    }

    # Панель управления NVIDIA для DCH-драйверов - ОТДЕЛЬНОЕ MSIX-приложение, а не
    # часть драйвера. Установщик с -s регистрирует его не всегда, а Microsoft Store
    # на изолированной сети 10.0.6.x недоступен - отсюда тост "Не найдена Панель
    # управления NVIDIA" при exit=0 у драйвера (приёмка 30.08.2026).
    # Комплект для ОФЛАЙН-развёртывания лежит ВНУТРИ пакета, в Display.Driver\NVCPL:
    # <hash>.appx + <hash>_License1.xml. Берём его оттуда, куда распаковался
    # установщик (C:\NVIDIA), а если он прибрался - из заранее извлечённой копии
    # рядом с драйвером (software\docs\drivers\NVCPL).
    if (-not (Get-AppxPackage -AllUsers -Name 'NVIDIACorp.NVIDIAControlPanel' -ErrorAction SilentlyContinue)) {
        $nvcplAppx = $null
        if (Test-Path -LiteralPath 'C:\NVIDIA') {
            $nvcplAppx = Get-ChildItem -LiteralPath 'C:\NVIDIA' -Recurse -Filter '*.appx' -ErrorAction SilentlyContinue |
                         Where-Object { $_.DirectoryName -match '(?i)NVCPL' } | Select-Object -First 1
        }
        if (-not $nvcplAppx) {
            $preExtracted = Join-Path (Split-Path $nvExe.FullName -Parent) 'NVCPL'
            if (Test-Path -LiteralPath $preExtracted) {
                $nvcplAppx = Get-ChildItem -LiteralPath $preExtracted -Filter '*.appx' -ErrorAction SilentlyContinue | Select-Object -First 1
            }
        }

        if ($nvcplAppx) {
            $nvcplLic = Get-ChildItem -LiteralPath $nvcplAppx.DirectoryName -Filter '*_License*.xml' -ErrorAction SilentlyContinue | Select-Object -First 1
            Write-ColorOutput "  Registering NVIDIA Control Panel offline: $($nvcplAppx.Name)" 'Yellow'
            Write-RaidLog ("NVCPL appx: {0} ; license: {1}" -f $nvcplAppx.FullName, $(if ($nvcplLic) { $nvcplLic.Name } else { '<none>' }))
            try {
                if ($nvcplLic) {
                    Add-AppxProvisionedPackage -Online -PackagePath $nvcplAppx.FullName -LicensePath $nvcplLic.FullName -ErrorAction Stop | Out-Null
                } else {
                    Add-AppxProvisionedPackage -Online -PackagePath $nvcplAppx.FullName -SkipLicense -ErrorAction Stop | Out-Null
                }
                Write-ColorOutput '  NVIDIA Control Panel provisioned (all users).' 'Green'
                Write-RaidLog 'NVCPL provisioned OK.'
            } catch {
                Write-ColorOutput "  NVCPL provisioning failed (non-fatal): $_" 'Yellow'
                Write-RaidLog "NVCPL provisioning failed: $_"
            }
            # Provisioning действует на профили, создаваемые ПОСЛЕ него, а профиль
            # текущего пользователя уже существует - регистрируем и в нём.
            try {
                Add-AppxPackage -Path $nvcplAppx.FullName -ErrorAction Stop
                Write-ColorOutput '  NVIDIA Control Panel registered for current user.' 'Green'
                Write-RaidLog 'NVCPL registered for current user.'
            } catch {
                Write-RaidLog "NVCPL per-user register failed (provisioning still applies): $_"
            }
        } else {
            Write-ColorOutput '  NVCPL appx not found - Control Panel will stay missing.' 'Yellow'
            Write-RaidLog 'NVCPL appx not found under C:\NVIDIA nor next to the installer.'
        }
    }

    Start-Sleep -Seconds 10   # дать драйверу подхватиться перед nvidia-smi ниже

    # Контроль результата: в лог должна попасть версия, которая реально уедет в FFU.
    $afterVersion = Get-NvidiaDriverVersion
    if ($targetVersion -and $afterVersion -and $afterVersion -ne $targetVersion) {
        Write-ColorOutput "  WARN: after install nvidia-smi reports '$afterVersion', expected '$targetVersion'." 'Yellow'
        Write-RaidLog "NVIDIA post-install mismatch: got '$afterVersion', expected '$targetVersion'."
    } else {
        Write-ColorOutput "  NVIDIA driver version now: '$(if ($afterVersion) { $afterVersion } else { '<nvidia-smi silent>' })'" 'Gray'
        Write-RaidLog "NVIDIA post-install version: '$afterVersion'"
    }
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
    # Вариант А: ставим драйвер NVIDIA ДО теста, чтобы FurMark реально нагрузил
    # карты. Если драйвер уже активен - функция сама себя пропустит.
    Install-NvidiaDriverIfNeeded -UsbRoot $usbRoot
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

# Детект хранилища НЕ должен ронять всю сборку. На машинах без контроллера
# MegaRAID и без data-дисков (например, рабочая станция с одним NVMe) хелперы
# подготовки хранилища могут словить некритичную ошибку, которая при
# script-wide $ErrorActionPreference='Stop' становится фатальной и убивает весь
# стресс-тест - а вместе с ним не выполняются deploy_extras (драйверы на флешку)
# и FFU. Оборачиваем: сбой детекта = "нет дисков под FIO", GPU/CPU-стресс всё
# равно идёт, и конвейер доходит до раскладки драйверов и FFU-захвата.
$driveLetters = @()
try {
    $driveLetters = @(
        Get-FioTargetDriveLetters -UsbRoot $usbRoot -SystemDriveLetter $systemDrive
    )
} catch {
    Write-ColorOutput "  Storage detection for FIO failed (non-fatal): $_" 'Yellow'
    Write-ColorOutput "  Continuing without FIO - GPU/CPU stress still run, pipeline not aborted." 'Yellow'
    Write-RaidLog "Get-FioTargetDriveLetters threw: $_ - continuing with empty FIO drive list."
    $driveLetters = @()
}

if ($driveLetters.Count -gt 0) {
    Write-ColorOutput "  FIO target drives: $($driveLetters -join ', ')" 'Green'
} else {
    Write-ColorOutput "  FIO target drives not found. RAID may be visible in BIOS/StorCLI but not exposed to Windows." 'Yellow'

    # --- ЗАСЛОН (07.10.2026) ---
    # Раньше здесь было только это жёлтое предупреждение. Тест молча собирался без
    # FIO, час крутил процессор, рапортовал Pipeline healthy, снимался FFU - и
    # машина уезжала, НЕ протестированная по дискам (SL111111-026 и -027).
    # Дефект не в том, что диск не поднялся, а в том, что конвейер не замечает,
    # что не проверил то, что обещал. Причина в следующий раз будет другая -
    # контроллер, вылетевший диск, не назначенная буква - а исход тот же.
    #
    # Сверяем ОБЕЩАНИЕ с ФАКТОМ: если SL объявил массив данных, а пригодного тома
    # в Windows нет - это провал сборки, захват FFU блокируется.
    # Машин без массива данных это не касается: там таких групп в конфиге нет.
    # Горячий резерв тоже идёт с disk_system=FALSE, поэтому по Type отсеиваем всё,
    # что не RAID (HotSpare и прочее) - иначе конфиг с одним резервом дал бы
    # ложное срабатывание.
    $slDeclaresDataArray = $false
    try {
        $slForRaid = (Get-ItemProperty -Path 'HKLM:\Software\IPDROM' -Name 'SL' -ErrorAction SilentlyContinue).SL
        if ($slForRaid) {
            $cfgForRaid = Join-Path $usbRoot "config\$slForRaid.txt"
            if (-not (Test-Path -LiteralPath $cfgForRaid)) { $cfgForRaid = "C:\IPDROM\config\$slForRaid.txt" }
            if (Test-Path -LiteralPath $cfgForRaid) {
                $grp = @{}
                foreach ($line in (Get-Content -LiteralPath $cfgForRaid -ErrorAction SilentlyContinue)) {
                    if ($line -match '^\s*group_(\d+)_(.+?)\s*=\s*(.*)$') {
                        $gn = $matches[1]; $gf = $matches[2].Trim().ToLower(); $gv = $matches[3].Trim()
                        if (-not $grp.ContainsKey($gn)) { $grp[$gn] = @{} }
                        $grp[$gn][$gf] = $gv
                    }
                }
                foreach ($gn in $grp.Keys) {
                    $isSys = "$($grp[$gn]['disk_system'])".Trim().ToUpper()
                    $gType = "$($grp[$gn]['type'])"
                    if ($isSys -eq 'FALSE' -and $gType -match '(?i)raid') {
                        $slDeclaresDataArray = $true
                        Write-RaidLog "SL group $gn declares a DATA array (Type='$gType', disk_system=FALSE)."
                        break
                    }
                }
            } else {
                Write-RaidLog "SL config not found for the data-array check: $cfgForRaid"
            }
        }
    } catch {
        Write-RaidLog "Data-array declaration check failed: $_"
    }

    if ($slDeclaresDataArray) {
        Write-ColorOutput '  *** SL declares a DATA RAID array, but no writable volume reached Windows. ***' 'Red'
        Write-ColorOutput '  *** The stress test would run with NO disk load at all. Blocking FFU capture. ***' 'Red'
        Mark-PipelineFailure 'SL declares a data RAID array, but no writable data volume was found - the stress test would have run without any disk load'
    } else {
        Write-ColorOutput '  SL declares no data array - running without FIO is expected here.' 'Gray'
    }
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

# ===================== [2.35/7] MOTHERBOARD/PLATFORM DRIVERS INTO OS =====================
# Install the matched platform driver-store pack (chipset, LAN, Management Engine, VROC,
# Guardant, ...) into the running OS BEFORE the stress test, so (a) the test exercises the
# machine in its final driver configuration, (b) all NICs are up during the run, and (c) the
# captured FFU has a clean Device Manager. GATED on unknown-device presence: fully-covered
# machines (Pro/IoT on inbox drivers) have no yellow-bang devices -> no-op there, nothing
# changes and the driver store isn't bloated. pnputil /install only binds drivers that match
# present hardware. The compact matcher mirrors deploy_extras' Find-MbDriverAsset (vendor+model
# tokens, >=2 must hit the <Vendor>_<Model> folder). deploy_extras still SHIPS the pack to the
# delivery flash later. Whole block is try/catch'd (non-fatal) so it can never kill the pipeline.
Write-ColorOutput '[2.35/7] Installing motherboard/platform drivers into OS...' 'Yellow'
try {
    $problemDevs = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
                     Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 })
    if ($problemDevs.Count -eq 0) {
        Write-ColorOutput '  No devices with a missing driver - skipping (system already covered).' 'Gray'
    } else {
        $mbSearch = ''
        $slName = (Get-ItemProperty -Path 'HKLM:\Software\IPDROM' -Name 'SL' -ErrorAction SilentlyContinue).SL
        if ($slName) {
            $cfg = Join-Path $usbRoot "config\$slName.txt"
            if (-not (Test-Path -LiteralPath $cfg)) { $cfg = "C:\IPDROM\config\$slName.txt" }
            if (Test-Path -LiteralPath $cfg) {
                $lines = Get-Content -LiteralPath $cfg -ErrorAction SilentlyContinue
                $mv = (($lines | Where-Object { $_ -match '^mb_vendor\s*=' } | Select-Object -First 1) -replace '^mb_vendor\s*=','').Trim()
                $mm = (($lines | Where-Object { $_ -match '^mb_model\s*='  } | Select-Object -First 1) -replace '^mb_model\s*=','').Trim()
                $mbSearch = ("$mv $mm").Trim()
            }
        }
        if (-not $mbSearch) {
            Write-ColorOutput '  Could not read mb_vendor/mb_model from SL config - skipping platform driver install.' 'Yellow'
        } else {
            Write-ColorOutput "  mb search string: '$mbSearch' ; $($problemDevs.Count) device(s) without a driver." 'Gray'
            $toTokens = { param($t) @((($t -replace '[^A-Za-z0-9]+',' ').ToUpper() -split '\s+') | Where-Object { $_ -and $_.Length -ge 2 }) }
            # Dedupe: several configs repeat the vendor inside mb_model ('ASUS' + 'Asus PRIME
            # Z790-P'), and a duplicated token would otherwise satisfy the >=2 rule on the
            # vendor name alone.
            $wantTokens = @((& $toTokens $mbSearch) | Select-Object -Unique)
            $platformsDir = $null
            foreach ($pd in @((Join-Path $usbRoot 'drivers\platforms'), 'C:\IPDROM\drivers\platforms')) {
                if (Test-Path -LiteralPath $pd) { $platformsDir = $pd; break }
            }
            $bestDir = $null; $bestScore = 0
            if ($platformsDir) {
                foreach ($folder in (Get-ChildItem -LiteralPath $platformsDir -Directory -ErrorAction SilentlyContinue)) {
                    $ft = & $toTokens $folder.Name
                    $hit = @($wantTokens | Where-Object { $ft -contains $_ })
                    # At least one matched token must carry a digit (i.e. a model number), not
                    # just vendor/family words. Without this an unknown board like
                    # 'ASUS PRIME Z890-QWE' matches ASUS_PRIME_Z690M-PLUS_D4 on ASUS+PRIME
                    # alone - harmless when packs were only copied to the flash, but this step
                    # INSTALLS them into the OS, so a wrong-generation chipset pack must not win.
                    $hasNum = @($hit | Where-Object { $_ -match '\d' }).Count
                    if ($hit.Count -ge 2 -and $hasNum -ge 1 -and $hit.Count -gt $bestScore) { $bestScore = $hit.Count; $bestDir = $folder.FullName }
                }
            }
            if (-not $bestDir) {
                Write-ColorOutput "  No platform pack matched '$mbSearch' in $platformsDir - skipping." 'Gray'
            } else {
                Write-ColorOutput "  Installing platform pack: $(Split-Path $bestDir -Leaf)" 'Yellow'
                # Pre-trust the pack's driver signers. pnputil raises a modal "Would you like to
                # install this device software?" for any publisher missing from Trusted Publishers,
                # and that modal HALTS the unattended run - it did exactly that on SL111111-012,
                # whose pack (SuperMicro_X13SAE-F) is a stub holding one C-MEDIA/ASUS sound driver.
                # Importing the .cat signers first makes every pack install non-interactively.
                # NOTE: do NOT gate on pack layout/size - SL111111-001 proved the legacy ASUS pack
                # is genuinely useful (44 INFs, cleaned 6 unknown devices), so packs must not be
                # skipped just for looking different.
                try {
                    $seenThumb = @{}
                    $tpStore = New-Object System.Security.Cryptography.X509Certificates.X509Store 'TrustedPublisher','LocalMachine'
                    $tpStore.Open('ReadWrite')
                    foreach ($cat in (Get-ChildItem -LiteralPath $bestDir -Recurse -Filter *.cat -ErrorAction SilentlyContinue)) {
                        $signer = (Get-AuthenticodeSignature -LiteralPath $cat.FullName -ErrorAction SilentlyContinue).SignerCertificate
                        if ($signer -and -not $seenThumb.ContainsKey($signer.Thumbprint)) {
                            $seenThumb[$signer.Thumbprint] = $true
                            try { $tpStore.Add($signer) } catch {}
                        }
                    }
                    $tpStore.Close()
                    Write-ColorOutput "  Pre-trusted $($seenThumb.Count) driver signer(s) - pnputil will not prompt." 'Gray'
                } catch {
                    Write-ColorOutput "  WARNING: could not pre-trust driver signers: $($_.Exception.Message)" 'Yellow'
                }
                $infArg = Join-Path $bestDir '*.inf'
                $out = & pnputil.exe /add-driver "$infArg" /subdirs /install 2>&1
                $pnpExit = $LASTEXITCODE
                Write-ColorOutput "  pnputil /add-driver exit=$pnpExit ($(@($out).Count) line(s) of output)." 'Gray'

                # Вывод pnputil СОХРАНЯЕМ (01.10.2026). Полтысячи строк собирались в
                # переменную и выбрасывались - в лог шло только их количество. Если
                # отдельный драйвер из пака не вставал, следа не оставалось никакого.
                # Производство как раз сообщило про Guardant: устройства в диспетчере
                # с ошибкой после нашей настройки. Без этого файла причину не увидеть.
                try {
                    $pnpLog = Join-Path $script:StressLogDir ("pnputil_{0}_{1}.log" -f (Split-Path $bestDir -Leaf), (Get-Date -Format 'yyyyMMdd-HHmmss'))
                    $header = @(
                        "=== pnputil /add-driver $infArg /subdirs /install ===",
                        "Pack      : $bestDir",
                        "Exit code : $pnpExit",
                        "Lines     : $(@($out).Count)",
                        ""
                    )
                    ($header + @($out | ForEach-Object { "$_" })) | Set-Content -LiteralPath $pnpLog -Encoding utf8
                    Write-ColorOutput "  pnputil output saved: $pnpLog" 'Gray'
                } catch {
                    Write-ColorOutput "  WARN: could not save pnputil output: $($_.Exception.Message)" 'Yellow'
                }

                & pnputil.exe /scan-devices 2>&1 | Out-Null
                $afterDevs = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
                               Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 })
                Write-ColorOutput "  Device Manager: $($afterDevs.Count) device(s) still without a driver (was $($problemDevs.Count)); some finalize on next boot." 'Green'

                # ПЕРЕЧИСЛЯЕМ оставшиеся проблемные устройства поимённо (01.10.2026).
                # Объекты уже собраны строкой выше - раньше из них печаталось только
                # количество. Это и скрывало проблему: во ВСЕХ прогонах стабильно
                # оставалось ровно 2 устройства, и мы читали это как безобидный
                # остаток. По словам производства, Guardant как раз даёт 2 устройства.
                # Имя и Hardware ID превращают "2 устройства" в проверяемый факт.
                foreach ($d in $afterDevs) {
                    Write-ColorOutput ("    ! {0} | {1} | CM_error={2}" -f `
                        $(if ($d.Name) { $d.Name } else { '<без имени>' }),
                        $(if ($d.PNPDeviceID) { $d.PNPDeviceID } else { '<без ID>' }),
                        $d.ConfigManagerErrorCode) 'Yellow'
                }
            }
        }
    }
} catch {
    Write-ColorOutput "  Platform driver install failed (non-fatal): $($_.Exception.Message)" 'Yellow'
}

# ===================== [2.36/7] GUARDANT USB KEY DRIVER =====================
# Guardant ставим ОТДЕЛЬНО и ДЛЯ ВСЕХ машин, независимо от модели платы.
#
# Причина (02.10.2026, разбор претензии производства). Шаг выше ставит драйверы
# ТОЛЬКО из пака платформы, подобранного по mb_vendor/mb_model. Guardant лежит в
# паках 5 плат из 58, а grdwinusb.inf - РОВНО В ОДНОМ (NewTech_SER-4251). На любой
# другой плате этот INF до хранилища драйверов не доезжал вообще, и ключ оставался
# в "Других устройствах". На скриншоте SL841326-002 ровно это: "Guardant Sign" без
# драйвера, и он там ОДИН, а не два.
#
# grdwinusb.inf обслуживает именно ключи нового поколения:
#     Guardant Sign = USB\VID_0A89&PID_00C2
#     Guardant Code = USB\VID_0A89&PID_00C3
# Старый grdusb.inf их не покрывает. Отсюда и "раньше проблем не было" - прежние
# ключи закрывались grdusb.inf, который разложен шире.
#
# Каталог drivers\common\drivers\ до сих пор не ставил НИКТО: pnputil вызывался
# только для пака платформы и для MegaRAID. Берём оттуда АДРЕСНО Guardant, а не
# весь каталог - рядом лежат GT730, nvidia, Moschip и PE, и раздавать их всем
# машинам без разбора это отдельное решение с отдельными рисками.
#
# Блок намеренно НЕ выставляет Mark-PipelineFailure: часть устройств до-привязывается
# только после перезагрузки, и блокировать захват FFU по такому признаку - значит
# ловить ложные срабатывания. Пока громко пишем в лог; если производству нужен
# жёсткий стоп - включается одной строкой.
Write-ColorOutput '[2.36/7] Installing Guardant USB key driver (board-independent)...' 'Yellow'
try {
    $grdDir = $null
    foreach ($cand in @((Join-Path $usbRoot 'drivers\common\drivers\Guardant'), 'C:\IPDROM\drivers\common\drivers\Guardant')) {
        if (Test-Path -LiteralPath $cand) { $grdDir = $cand; break }
    }
    if (-not $grdDir) {
        Write-ColorOutput '  Guardant driver folder not found - skipping.' 'Gray'
    } else {
        # -File обязателен: без него под маску *.inf попадают ещё и ИМЕНА ПАПОК
        # вида grdusb.inf_amd64_5dc335baad6f68ab, и строка ниже рапортует 4 INF
        # там, где файлов ровно два. На работу это не влияло (маску разворачивает
        # сам pnputil), но в логе выглядело как лишние пакеты.
        $grdInfs = @(Get-ChildItem -LiteralPath $grdDir -Recurse -File -Filter *.inf -ErrorAction SilentlyContinue)
        Write-ColorOutput ("  Source: {0} ({1} INF: {2})" -f $grdDir, $grdInfs.Count, (($grdInfs | ForEach-Object { $_.Name }) -join ', ')) 'Gray'

        # Издателя доверяем заранее - иначе pnputil поднимет модальное окно и повесит
        # автоматический прогон. Та же защита, что и у пака платформы выше.
        try {
            $grdSeen  = @{}
            $grdStore = New-Object System.Security.Cryptography.X509Certificates.X509Store 'TrustedPublisher','LocalMachine'
            $grdStore.Open('ReadWrite')
            foreach ($cat in (Get-ChildItem -LiteralPath $grdDir -Recurse -Filter *.cat -ErrorAction SilentlyContinue)) {
                $signer = (Get-AuthenticodeSignature -LiteralPath $cat.FullName -ErrorAction SilentlyContinue).SignerCertificate
                if ($signer -and -not $grdSeen.ContainsKey($signer.Thumbprint)) {
                    $grdSeen[$signer.Thumbprint] = $true
                    try { $grdStore.Add($signer) } catch {}
                }
            }
            $grdStore.Close()
            Write-ColorOutput "  Pre-trusted $($grdSeen.Count) Guardant signer(s)." 'Gray'
        } catch {
            Write-ColorOutput "  WARNING: could not pre-trust Guardant signers: $($_.Exception.Message)" 'Yellow'
        }

        $grdInfArg = Join-Path $grdDir '*.inf'
        $grdOut    = & pnputil.exe /add-driver "$grdInfArg" /subdirs /install 2>&1
        $grdExit   = $LASTEXITCODE
        Write-ColorOutput "  pnputil /add-driver exit=$grdExit ($(@($grdOut).Count) line(s))." 'Gray'

        try {
            $grdLog = Join-Path $script:StressLogDir ("pnputil_guardant_{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            (@("=== pnputil /add-driver $grdInfArg /subdirs /install ===",
               "Source    : $grdDir",
               "Exit code : $grdExit",
               "Lines     : $(@($grdOut).Count)",
               "") + @($grdOut | ForEach-Object { "$_" })) | Set-Content -LiteralPath $grdLog -Encoding utf8
            Write-ColorOutput "  pnputil output saved: $grdLog" 'Gray'
        } catch {
            Write-ColorOutput "  WARN: could not save Guardant pnputil output: $($_.Exception.Message)" 'Yellow'
        }

        & pnputil.exe /scan-devices 2>&1 | Out-Null

        # Результат проверяем адресно: по VID из grdwinusb.inf и по имени устройства.
        $grdDevs = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
                     Where-Object { "$($_.PNPDeviceID)" -match 'VID_0A89' -or "$($_.Name)" -match 'Guardant' })
        if ($grdDevs.Count -eq 0) {
            Write-ColorOutput '  No Guardant device present - driver staged in the store for later hot-plug.' 'Gray'
        } else {
            foreach ($d in $grdDevs) {
                $code = $d.ConfigManagerErrorCode
                $bad  = ($code -and $code -ne 0)
                Write-ColorOutput ("    {0}: {1} | {2} | CM_error={3}" -f `
                    $(if ($bad) { 'STILL FAILING' } else { 'OK' }),
                    $(if ($d.Name) { $d.Name } else { '<no name>' }),
                    $(if ($d.PNPDeviceID) { $d.PNPDeviceID } else { '<no id>' }),
                    $code) $(if ($bad) { 'Red' } else { 'Green' })
            }
            $grdBad = @($grdDevs | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 })
            if ($grdBad.Count -gt 0) {
                Write-ColorOutput "  *** Guardant: $($grdBad.Count) of $($grdDevs.Count) device(s) STILL without a driver after install. ***" 'Red'
            } else {
                Write-ColorOutput "  Guardant: all $($grdDevs.Count) device(s) bound successfully." 'Green'
            }
        }
    }
} catch {
    Write-ColorOutput "  Guardant driver install failed (non-fatal): $($_.Exception.Message)" 'Yellow'
}

# ===================== [2.37/7] SATA HBA DRIVER (PCIe 4xSATA3) =====================
# Плата расширения PCIe 4xSATA3 (software\PCIe4SATA3ASM). Конвейер её драйвер не
# ставил НИКОГДА - папка просто лежала, ни один скрипт на неё не ссылался.
# Производство сообщило, что ставить надо.
#
# В обороте ДВА варианта платы, и обслуживаются они по-разному:
#   Marvell 9215 (PCI\VEN_1B4B) - в комплекте 62 INF под разные чипы и ОС.
#       mv91xx.inf  - SCSI miniport под XP/2003, современной Windows не подходит;
#       mvs91xx.inf - storport, он и нужен. Фильтр по ИМЕНИ файла сам отсекает
#       неподходящий тип, плюс требуем путь с amd64. Для 9215 подходит ровно
#       один: 92XX\Windows Vista_2008_7_8\amd64, версия 1.2.0.1038.
#   ASMedia ASM106x (PCI\VEN_1B21) - в комплекте был только InstallShield
#       setup.exe, без единого INF. Файлы драйвера извлечены из него один раз,
#       вручную, и лежат в "ASM1061R Driver\amd64_extracted" (происхождение
#       расписано там же в ORIGIN.txt). Установщик в конвейере НЕ запускается:
#       любое непредусмотренное окно останавливает автоматический прогон
#       намертво и без следов в логе - на этом конвейер уже горел трижды
#       (модалка AIDA64, запрос доверия pnputil, QuickEdit в консоли).
#
# Пути не хардкодим: в именах папок комплекта есть опечатки ("MarveIl" через
# заглавную I, "Widows"), и переименование сломало бы жёсткую ссылку.
#
# ГЕЙТ ПО ЖЕЛЕЗУ ДВОЙНОЙ, и второе условие важнее первого:
#   1) на машине есть устройство с нужным VEN;
#   2) какой-то INF из комплекта объявляет РЕАЛЬНЫЙ DEV этого устройства.
# Второе обязательно: под VEN_1B21 идут не только SATA-контроллеры, но и очень
# распространённые USB 3.0-контроллеры ASMedia, к нашей плате отношения не
# имеющие. Без проверки DEV мы бы лезли ставить SATA-драйвер на USB.
#
# ЧЕСТНО ПРО РИСК. Оба драйвера старые, подписаны sha1RSA, сертификаты издателей
# истекли (подписи держатся метками времени, статус Valid):
#   ASMedia, 2011 - подпись "Microsoft Windows Hardware Compatibility Publisher",
#       то есть WHQL; такую политика подписи ядра принимает надёжнее;
#   Marvell, 2013 - кросс-подпись вендора, путь слабее.
# Примет ли их Win11/Server 2022 - заранее не известно. Поэтому вывод pnputil
# сохраняется целиком: при отказе в нём будет точная причина.
Write-ColorOutput '[2.37/7] Installing SATA HBA driver (only for a card actually present)...' 'Yellow'
try {
    $hbaRoot = $null
    foreach ($cand in @((Join-Path $usbRoot 'software\PCIe4SATA3ASM'), 'C:\IPDROM\software\PCIe4SATA3ASM')) {
        if (Test-Path -LiteralPath $cand) { $hbaRoot = $cand; break }
    }

    # Таблица правил вместо двух копий одного блока: карты отличаются только
    # вендором, именем нужного INF и именем службы после привязки.
    $hbaRules = @(
        [pscustomobject]@{ Vendor = 'Marvell'; Vid = '1B4B'; InfName = 'mvs91xx.inf';  PathMustMatch = '(?i)\\amd64\\'; Service = 'mvs91xx'  },
        [pscustomobject]@{ Vendor = 'ASMedia'; Vid = '1B21'; InfName = 'asahci64.inf'; PathMustMatch = $null;           Service = 'asahci64' }
    )

    $hbaHandled = 0
    foreach ($rule in $hbaRules) {
        $devs = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
                  Where-Object { "$($_.PNPDeviceID)" -match ("PCI\\VEN_{0}" -f $rule.Vid) })
        if ($devs.Count -eq 0) { continue }

        $wanted = @{}
        foreach ($d in $devs) {
            Write-ColorOutput ("  [{0}] found: {1} | {2} | service={3} | CM_error={4}" -f `
                $rule.Vendor,
                $(if ($d.Name) { $d.Name } else { '<no name>' }),
                $d.PNPDeviceID,
                $(if ($d.Service) { $d.Service } else { '<none>' }),
                $d.ConfigManagerErrorCode) 'Gray'
            if ("$($d.PNPDeviceID)" -match 'DEV_([0-9A-Fa-f]{4})') { $wanted[$matches[1].ToUpper()] = $true }
        }

        if (-not $hbaRoot) {
            Write-ColorOutput ("  [{0}] driver folder software\PCIe4SATA3ASM not found - cannot install." -f $rule.Vendor) 'Yellow'
            continue
        }

        $best    = $null
        $bestVer = [version]'0.0.0.0'
        foreach ($inf in (Get-ChildItem -LiteralPath $hbaRoot -Recurse -Filter $rule.InfName -ErrorAction SilentlyContinue)) {
            if ($rule.PathMustMatch -and ($inf.FullName -notmatch $rule.PathMustMatch)) { continue }
            $text = ''
            try { $text = Get-Content -LiteralPath $inf.FullName -Raw -ErrorAction Stop } catch { continue }
            if (-not $text) { continue }

            $covers = $false
            foreach ($id in $wanted.Keys) {
                if ($text -match ("(?i)VEN_{0}&DEV_{1}" -f $rule.Vid, $id)) { $covers = $true; break }
            }
            if (-not $covers) { continue }

            $ver = [version]'0.0.0.0'
            if ($text -match '(?im)^\s*DriverVer\s*=\s*[^,]*,\s*([0-9]+(?:\.[0-9]+){1,3})') {
                try { $ver = [version]$matches[1] } catch {}
            }
            Write-ColorOutput ("    candidate: {0} (DriverVer {1})" -f $inf.FullName.Substring($hbaRoot.Length).TrimStart('\'), $ver) 'DarkGray'
            if ($ver -gt $bestVer) { $bestVer = $ver; $best = $inf.FullName }
        }

        if (-not $best) {
            # Штатный случай для USB-контроллеров ASMedia: вендор совпал, а SATA
            # к ним отношения не имеет. Это не ошибка.
            Write-ColorOutput ("  [{0}] no INF in the package covers the present device(s) - not this card, skipping." -f $rule.Vendor) 'Gray'
            continue
        }

        $hbaHandled++
        Write-ColorOutput ("  [{0}] selected: {1} (DriverVer {2})" -f $rule.Vendor, $best, $bestVer) 'Yellow'

        # Издателя доверяем заранее, иначе pnputil поднимет модальное окно и
        # повесит автоматический прогон.
        try {
            $hbaStore = New-Object System.Security.Cryptography.X509Certificates.X509Store 'TrustedPublisher','LocalMachine'
            $hbaStore.Open('ReadWrite')
            $hbaSeen = 0
            foreach ($cat in (Get-ChildItem -LiteralPath (Split-Path $best -Parent) -Filter *.cat -ErrorAction SilentlyContinue)) {
                $signer = (Get-AuthenticodeSignature -LiteralPath $cat.FullName -ErrorAction SilentlyContinue).SignerCertificate
                if ($signer) { try { $hbaStore.Add($signer); $hbaSeen++ } catch {} }
            }
            $hbaStore.Close()
            Write-ColorOutput ("  [{0}] pre-trusted {1} signer(s)." -f $rule.Vendor, $hbaSeen) 'Gray'
        } catch {
            Write-ColorOutput ("  [{0}] WARNING: could not pre-trust signers: {1}" -f $rule.Vendor, $_.Exception.Message) 'Yellow'
        }

        $hbaOut  = & pnputil.exe /add-driver "$best" /install 2>&1
        $hbaExit = $LASTEXITCODE
        Write-ColorOutput ("  [{0}] pnputil /add-driver exit={1} ({2} line(s))." -f $rule.Vendor, $hbaExit, @($hbaOut).Count) 'Gray'

        try {
            $hbaLog = Join-Path $script:StressLogDir ("pnputil_hba_{0}_{1}.log" -f $rule.Vendor.ToLower(), (Get-Date -Format 'yyyyMMdd-HHmmss'))
            (@("=== pnputil /add-driver /install ===",
               "Vendor    : $($rule.Vendor) (PCI\VEN_$($rule.Vid))",
               "INF       : $best",
               "DriverVer : $bestVer",
               "Exit code : $hbaExit",
               "") + @($hbaOut | ForEach-Object { "$_" })) | Set-Content -LiteralPath $hbaLog -Encoding utf8
            Write-ColorOutput ("  [{0}] pnputil output saved: {1}" -f $rule.Vendor, $hbaLog) 'Gray'
        } catch {
            Write-ColorOutput ("  [{0}] WARN: could not save pnputil output: {1}" -f $rule.Vendor, $_.Exception.Message) 'Yellow'
        }

        & pnputil.exe /scan-devices 2>&1 | Out-Null

        $after = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
                   Where-Object { "$($_.PNPDeviceID)" -match ("PCI\\VEN_{0}" -f $rule.Vid) })
        $bound = 0
        foreach ($d in $after) {
            # Интересует только то устройство, ради которого всё затевалось.
            $isTarget = $false
            if ("$($d.PNPDeviceID)" -match 'DEV_([0-9A-Fa-f]{4})') { $isTarget = $wanted.ContainsKey($matches[1].ToUpper()) }
            if (-not $isTarget) { continue }

            $code = $d.ConfigManagerErrorCode
            $bad  = ($code -and $code -ne 0)
            if ("$($d.Service)" -match ("(?i)^{0}$" -f [regex]::Escape($rule.Service))) { $bound++ }
            Write-ColorOutput ("    {0}: {1} | service={2} | CM_error={3}" -f `
                $(if ($bad) { 'STILL FAILING' } else { 'OK' }),
                $(if ($d.Name) { $d.Name } else { '<no name>' }),
                $(if ($d.Service) { $d.Service } else { '<none>' }),
                $code) $(if ($bad) { 'Red' } else { 'Green' })
        }

        if ($bound -gt 0) {
            Write-ColorOutput ("  [{0}] driver bound to {1} device(s) - card is on its native driver." -f $rule.Vendor, $bound) 'Green'
        } else {
            Write-ColorOutput ("  [{0}] driver did NOT bind - card is still on the inbox driver. See the pnputil log for the reason." -f $rule.Vendor) 'Red'
        }
    }

    if ($hbaHandled -eq 0) {
        Write-ColorOutput '  No supported SATA HBA present (checked Marvell VEN_1B4B and ASMedia VEN_1B21) - skipping.' 'Gray'
    }
} catch {
    Write-ColorOutput "  SATA HBA driver install failed (non-fatal): $($_.Exception.Message)" 'Yellow'
}

# ===================== [2.4/7] .NET FRAMEWORK 3.5 =====================
# Intellect Classic MSI custom actions reference .NET 3.5. Without it,
# WSInstaller shows a modal "Download .NET 3.5?" dialog that blocks the
# unattended install forever. Enable NetFx3 offline from the Windows sxs
# source (copied into common\sources\sxs on the PXE server) so no Windows
# Update access is needed. /LimitAccess forbids WU fallback outright.
# Failure only warns — Intellect X installs don't need this and will proceed.
Write-ColorOutput '[2.4/7] Ensuring .NET Framework 3.5 is enabled...' 'Yellow'
try {
    $netfx = Get-WindowsOptionalFeature -Online -FeatureName NetFx3 -ErrorAction Stop
    if ($netfx.State -eq 'Enabled') {
        Write-ColorOutput '  NetFx3 already enabled.' 'Gray'
    } else {
        # Источник sxs ОБЯЗАН быть от той же ОС: DISM отказывается ставить компонент
        # из чужого дистрибутива. common\sources\sxs - это sxs от Win11, поэтому на
        # Server 2019/2022 включение молча проваливалось (SL111111-009, 31.08.2026:
        # NetFx3 остался DisabledWithPayloadRemoved). Сначала ищем sxs под свою ОС,
        # и только потом падаем на общий.
        $osCaption = "$((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption)"
        # IoT проверяется ПЕРВЫМ и с break: у "Windows 10 IoT Enterprise LTSC 2019"
        # совпали бы сразу две ветки, а без break switch-выражение вернуло бы массив.
        # IoT LTSC - отдельная редакция со своим хранилищем компонентов: общий sxs от
        # Win11 Pro ей не подходит (SL839492-001 и SL111111-010, 04.09.2026: DISM
        # вернул 0x800F081F CBS_E_SOURCE_MISSING).
        $osTag = switch -Regex ($osCaption) {
            'IoT'   { 'iot';         break }
            '2019'  { 'server2019';  break }
            '2022'  { 'server2022';  break }
            default { '' }
        }
        $sxsCandidates = @()
        if ($osTag) {
            $sxsCandidates += (Join-Path $usbRoot "sources\sxs_$osTag")
            $sxsCandidates += "C:\IPDROM\sources\sxs_$osTag"
        }
        $sxsCandidates += (Join-Path $usbRoot 'sources\sxs')
        $sxsCandidates += 'C:\IPDROM\sources\sxs'
        Write-ColorOutput "  OS: '$osCaption' -> sxs tag '$osTag'" 'Gray'

        $sxs = $sxsCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($sxs) {
            Write-ColorOutput "  Enabling NetFx3 offline from $sxs..." 'Yellow'
            & dism.exe /online /enable-feature /featurename:NetFx3 /all /quiet /norestart /source:"$sxs" /LimitAccess | Out-Null
            $dismExit = $LASTEXITCODE
            if ($dismExit -eq 0) {
                Write-ColorOutput '  NetFx3 enabled.' 'Green'
            } else {
                # Через Write-ColorOutput, а не Write-Warning: предупреждения в файл
                # лога не попадают, и эта ошибка дважды терялась при разборе.
                Write-ColorOutput "  WARN: DISM enable-feature exit=$dismExit (source '$sxs'). Intellect installer may block on a '.NET 3.5?' modal." 'Yellow'
                Write-RaidLog "NetFx3 enable failed: dism exit=$dismExit, source='$sxs', OS='$osCaption'."
            }
        } else {
            Write-ColorOutput ("  WARN: no sxs found ({0}). Put the matching OS sources\sxs into common\sources\ on the PXE server." -f ($sxsCandidates -join ', ')) 'Yellow'
            Write-RaidLog "NetFx3: no sxs source found. Tried: $($sxsCandidates -join ', ')"
        }
    }
} catch {
    Write-Warning "  NetFx3 check failed: $_"
}

# ===================== [2.45/7] DOCUMENTATION TO DESKTOP =====================
# Parse doc= from SL config, copy per-SL PDFs to Desktop\Documentation so the
# operator sees them right after autologin. Flash copy happens later in [6.6/7].
Write-ColorOutput '[2.45/7] Deploying documentation to Desktop...' 'Yellow'
try {
    $sl = (Get-ItemProperty -Path 'HKLM:\Software\IPDROM' -Name 'SL' -ErrorAction SilentlyContinue).SL
    $deployDocs = Join-Path $scriptDir 'deploy_docs.ps1'
    if ($sl -and (Test-Path $deployDocs)) {
        $slCfg = Join-Path $usbRoot "config\$sl.txt"
        $docsSrc = Join-Path $usbRoot 'documentation'
        # PDFs go directly on Desktop root (per SL doc= list). No subfolder.
        $desktopDst = [Environment]::GetFolderPath('Desktop')
        if ((Test-Path $slCfg) -and (Test-Path $docsSrc)) {
            & $deployDocs -SLConfigPath $slCfg -DocsSource $docsSrc -DesktopDest $desktopDst
            Write-ColorOutput '  Docs deployed to Desktop.' 'Green'
        } else {
            Write-ColorOutput "  Skipping: config or docs folder missing (SL=$sl)." 'Yellow'
        }
    } else {
        Write-ColorOutput '  Skipping: no SL in registry or deploy_docs.ps1 not found.' 'Gray'
    }
} catch {
    Write-Warning "  deploy_docs threw: $_"
}

# ===================== [2.5/7] AXXON SOFTWARE INSTALL =====================
# Router читает build_spec (SL*-*.txt в config\) и зовёт install_intellect[x].ps1
# по флагам axxonsoft / axxonsoft_install / axxon_LS. Никаких pre/post ребутов
# - всё в quiet режиме внутри одного процесса. Failed - warning, не валит цикл.
# ВСЕ сообщения через Write-ColorOutput чтобы они попадали в лог (Write-Warning
# уходит только в warning stream и в файл лога не пишется).
Write-ColorOutput '[2.5/7] Installing Axxon software per build_spec...' 'Yellow'
$axxonRouter = Join-Path $scriptDir 'Install-AxxonByBuildSpec.ps1'
Write-ColorOutput ("  Router path: {0} (exists={1})" -f $axxonRouter, (Test-Path $axxonRouter)) 'Gray'
if (Test-Path $axxonRouter) {
    Write-ColorOutput "  Invoking router (UsbRoot=$UsbRoot)..." 'Gray'
    $stamp = Get-Date
    try {
        & $axxonRouter -UsbRoot $UsbRoot
        $rc = $LASTEXITCODE
        $elapsed = [int]((Get-Date) - $stamp).TotalSeconds
        Write-ColorOutput "  Router returned exit=$rc after ${elapsed}s" 'Gray'
        if ($rc -ne 0) {
            Write-ColorOutput "  Install-AxxonByBuildSpec exited with code $rc - continuing pipeline." 'Yellow'
        } else {
            Write-ColorOutput '  Axxon install OK.' 'Green'
        }
    } catch {
        Write-ColorOutput "  Install-AxxonByBuildSpec THREW: $($_.Exception.Message) - continuing pipeline." 'Red'
        Write-ColorOutput "  Stack: $($_.ScriptStackTrace)" 'DarkGray'
    }
} else {
    Write-ColorOutput "  Install-AxxonByBuildSpec.ps1 not found - skipping Axxon install." 'Gray'
}

Write-ColorOutput '[3/7] Setting up watchdog...' 'Yellow'

# Запас над длительностью теста: 30 мин -> 40 мин (10.09.2026).
# Сторож нужен на случай реально зависшей машины, но он НЕ должен срабатывать на
# штатном хвосте прогона. Замер на 010: тест 60 мин, а aida_fio_furmark вернулся
# через 71,5 мин - фиксированный хвост (раскачка тестов, финальные скриншоты,
# генерация отчёта) ~11,5 мин, до сторожа оставалось 17,5 мин. Подняв лимит
# полного отчёта AIDA с 300 до 900 с, в худшем случае съедаем ещё 10 мин - запас
# упал бы до ~7 мин. Ребут посреди конвейера, ДО захвата FFU, стоит дороже, чем
# лишние 10 минут ожидания на действительно мёртвой машине.
$watchdogSeconds = ($DurationMinutes * 60) + 2400
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

        # Три попытки с паузой: сервер отчётов периодически недоступен, а из-за одной
        # неудачной отправки терять полуторачасовой прогон нельзя.
        $uploaded = $false
        for ($try = 1; $try -le 3 -and -not $uploaded; $try++) {
            if ($try -gt 1) {
                Write-ColorOutput "  Upload attempt $try/3 (previous failed, waiting 20s)..." 'Yellow'
                Start-Sleep -Seconds 20
            }
            $uploaded = Send-ArchiveToServer -ArchivePath $archivePath -ServerUrl $serverUrl
        }

        if ($uploaded) {
            Write-ColorOutput '  Upload successful!' 'Green'
        } else {
            # Недоступность сервера отчётов - НЕ повод считать машину бракованной:
            # железо протестировано, отчёт просто не доехал. FFU и флешки создаём.
            # Но архив ОБЯЗАТЕЛЬНО сохраняем: раньше его удаляла очистка [6.5/7],
            # и переотправить было нечего (SL111111-009, 31.08.2026).
            # Уносим его с рабочего стола в ProgramData: и от очистки спасли, и
            # заказчику на столе zip не показываем.
            $pendingDir = Join-Path $env:ProgramData 'IPDROM\PendingReports'
            try {
                New-Item -ItemType Directory -Path $pendingDir -Force -ErrorAction SilentlyContinue | Out-Null
                $keptPath = Join-Path $pendingDir (Split-Path $archivePath -Leaf)
                Move-Item -LiteralPath $archivePath -Destination $keptPath -Force -ErrorAction Stop
                Write-ColorOutput "  WARN: report NOT uploaded after 3 attempts. Archive kept: $keptPath" 'Yellow'
                Write-ColorOutput '  WARN: re-send it manually once the report server is back.' 'Yellow'
                Write-RaidLog "Report upload failed after 3 attempts; archive preserved at $keptPath"
            } catch {
                Write-ColorOutput "  WARN: report not uploaded AND archive could not be preserved: $_" 'Yellow'
                Write-RaidLog "Report upload failed and archive preservation failed: $_"
            }
        }
    } catch {
        # Сюда попадаем только при реальной проблеме с созданием архива - отправка
        # свои ошибки обрабатывает сама и конвейер не роняет.
        Write-Warning "  Archive creation error: $_"
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

# ===================== FINALIZE VOLUME LABELS =====================
# Метки томов для отгрузки заказчику:
#   C: (системный)   -> SYSTEM
#   data-массивы     -> Archive  (уже задано при форматировании выше в этом
#                                 скрипте, метка 'Archive')
# Флешки (IPDROM / IpdromREC / WINRE) НЕ трогаем: у них метки-маркеры, по
# которым их находят другие скрипты (protect_ipdromrec, deploy_extras и т.д.).
# Системный том переименовываем здесь, ДО FFU-захвата, чтобы метка 'SYSTEM'
# попала в образ восстановления.
try {
    $sysLetter = ($env:SystemDrive).TrimEnd(':')
    Set-Volume -DriveLetter $sysLetter -NewFileSystemLabel 'SYSTEM' -ErrorAction Stop
    Write-ColorOutput "  System volume ${sysLetter}: relabeled to 'SYSTEM'." 'Gray'
} catch {
    # Fallback через label.exe, если Set-Volume недоступен.
    try {
        & label.exe "$env:SystemDrive" SYSTEM
        Write-ColorOutput "  System volume relabeled to 'SYSTEM' (via label.exe)." 'Gray'
    } catch {
        Write-ColorOutput "  WARN: could not relabel system volume to 'SYSTEM': $_" 'Yellow'
    }
}

# Встроенный Administrator: на Server autounattend его ВКЛЮЧАЕТ (задаёт пароль,
# иначе OOBE останавливается на экране ввода пароля). В поставке он не нужен -
# конвейер и готовая машина работают под IPDROM, поэтому отключаем встроенного
# Administrator ДО FFU-захвата, чтобы в образе он не был активен. На IoT/Pro он
# и так отключён по умолчанию - там команда просто ничего не меняет (no-op).
#
# 09-10.09.2026: шаг МОЛЧА не срабатывал на обеих ОС - 'Не найдено имя
# пользователя'. Причина в имени: на русской Windows встроенная учётка
# называется 'Администратор', а искали строку 'Administrator'. Ищем по
# well-known RID 500 - он одинаков на любой локализации и переживает
# переименование учётки.
#
# ВАЖНО: если конвейер работает ПОД этой же учёткой (а на 009/010 он шёл под
# 'Admin'), отключать её нельзя - образ уедет без единой рабочей учётной записи.
# Поэтому сверяемся с SID текущего пользователя и в этом случае оставляем как есть.
try {
    $curSid  = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $builtin = Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True" -ErrorAction Stop |
               Where-Object { $_.SID -match '-500$' } | Select-Object -First 1

    if (-not $builtin) {
        Write-ColorOutput "  Built-in Administrator (RID 500) not present - nothing to disable." 'Gray'
    } elseif ($builtin.SID -eq $curSid) {
        Write-ColorOutput "  Built-in Administrator is the CURRENT account ('$($builtin.Name)') - left ENABLED on purpose (image must keep a usable account)." 'Yellow'
    } elseif ($builtin.Disabled) {
        Write-ColorOutput "  Built-in Administrator ('$($builtin.Name)') already disabled - nothing to do." 'Gray'
    } else {
        & net.exe user $builtin.Name /active:no 2>&1 | Out-Null
        Write-ColorOutput "  Built-in Administrator ('$($builtin.Name)') disabled (delivery hardening)." 'Gray'
    }
} catch {
    Write-ColorOutput "  WARN: could not disable built-in Administrator: $_" 'Yellow'
}

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

# ===================== [6.6/7] DEPLOY EXTRAS TO IPDROM =====================
# Copy drivers/, software/, per-SL PDFs to the flash operator picked in WinPE
# (identified by volume label "IPDROM"). Must run BEFORE C:\IPDROM cleanup
# in [6.7/7] step 1.5. If no IPDROM flash was labeled, script skips silently.
Write-ColorOutput '[6.6/7] Deploying drivers/software/docs to IPDROM flash...' 'Yellow'
$deployExtras = Join-Path $scriptDir 'deploy_extras.ps1'
if (Test-Path $deployExtras) {
    Write-ColorOutput ("  deploy_extras.ps1 found at: $deployExtras") 'Gray'
    try {
        $sl = (Get-ItemProperty -Path 'HKLM:\Software\IPDROM' -Name 'SL' -ErrorAction SilentlyContinue).SL
        $slCfgPath = if ($sl) { Join-Path $usbRoot "config\$sl.txt" } else { '' }
        Write-ColorOutput ("  Invoking with UsbRoot=$usbRoot SLConfigPath=$slCfgPath") 'Gray'
        & $deployExtras -UsbRoot $usbRoot -SLConfigPath $slCfgPath 2>&1 | ForEach-Object {
            Write-ColorOutput ("    | $_") 'DarkGray'
        }
        Write-ColorOutput ("  deploy_extras exit code: $LASTEXITCODE") 'Green'
    } catch {
        Write-ColorOutput ("  deploy_extras threw: $($_.Exception.Message)") 'Red'
        Write-ColorOutput ("  stack: $($_.ScriptStackTrace)") 'DarkRed'
    }
} else {
    Write-ColorOutput '  deploy_extras.ps1 not found - skipping.' 'Gray'
}

# ===================== [6.65/7] REGISTER PROTECT-IPDROMREC TASK =====================
# After FFU capture completes in WinPE and machine returns to Windows,
# a one-shot scheduled task will verify restore.ffu and set the IpdromREC
# flash disk to readonly. We register it here, BEFORE the reboot, so the
# task exists on the freshly captured image.
Write-ColorOutput '[6.65/7] Registering IpdromREC protect task (fires on next Windows boot)...' 'Yellow'
$protectSrc = Join-Path $scriptDir 'protect_ipdromrec.ps1'
if (Test-Path $protectSrc) {
    try {
        $safeScriptsDir = 'C:\ProgramData\IPDROM\Scripts'
        New-Item -ItemType Directory -Path $safeScriptsDir -Force -ErrorAction SilentlyContinue | Out-Null
        $localProtect = Join-Path $safeScriptsDir 'protect_ipdromrec.ps1'
        Copy-Item -LiteralPath $protectSrc -Destination $localProtect -Force -ErrorAction Stop
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action = New-ScheduledTaskAction -Execute $psExe `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$localProtect`""
        # ДВА триггера намеренно (правка 30.08.2026). Автовход теперь снимается ДО
        # захвата FFU, чтобы образ уезжал к заказчику без беспарольного автовхода -
        # а значит после возврата из WinPE логиниться некому, и триггер "при входе"
        # сам по себе больше не сработает. Поэтому основной путь - AtStartup от
        # SYSTEM, а AtLogOn оставлен запасным. Задержка 60 с - время на перечисление
        # USB. protect_ipdromrec.ps1 под SYSTEM безопасен: единственный консольный
        # вызов (SetConsoleMode) там обёрнут в try/catch и без консоли просто no-op.
        $trgStartup = New-ScheduledTaskTrigger -AtStartup
        $trgStartup.Delay = 'PT60S'
        $trgLogon = New-ScheduledTaskTrigger -AtLogOn
        $trgLogon.Delay = 'PT60S'
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName 'IPDROM_ProtectRec' -Action $action -Trigger @($trgStartup, $trgLogon) `
            -Settings $settings -Principal $principal -Force | Out-Null
        Write-ColorOutput '  Task IPDROM_ProtectRec registered (SYSTEM; at startup + at logon, 60s delay).' 'Green'

        # СТРАХОВКА: автовход снимаем ТОЛЬКО убедившись, что задача защиты реально
        # зарегистрирована и включена. Иначе машина осталась бы разом и без автовхода,
        # и без защиты флешки. Не подтвердилось - оставляем автовход взведённым, то
        # есть ровно сегодняшнее поведение (хуже не станет), а launcher снимет его
        # позже сам.
        $protectTask = Get-ScheduledTask -TaskName 'IPDROM_ProtectRec' -ErrorAction SilentlyContinue
        if ($protectTask -and $protectTask.State -ne 'Disabled') {
            try {
                $winlogon = 'Registry::HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
                Set-ItemProperty    -LiteralPath $winlogon -Name 'AutoAdminLogon'  -Value '0' -Type String -Force -ErrorAction Stop
                Remove-ItemProperty -LiteralPath $winlogon -Name 'DefaultPassword' -Force -ErrorAction SilentlyContinue
                $check = (Get-ItemProperty -LiteralPath $winlogon -Name 'AutoAdminLogon' -ErrorAction SilentlyContinue).AutoAdminLogon
                Write-ColorOutput "  Auto-logon disarmed BEFORE FFU capture (AutoAdminLogon='$check') - image ships clean." 'Green'
                Write-RaidLog "Auto-logon disarmed before FFU capture; readback AutoAdminLogon='$check'."
            } catch {
                Write-ColorOutput "  WARN: could not disarm auto-logon before capture (left armed): $_" 'Yellow'
                Write-RaidLog "Pre-capture auto-logon disarm failed, left armed: $_"
            }
        } else {
            Write-ColorOutput '  WARN: IPDROM_ProtectRec not verified - auto-logon left ARMED so the flash still gets protected.' 'Yellow'
            Write-RaidLog 'Protect task verification failed - auto-logon intentionally left armed.'
        }
    } catch {
        Write-Warning "  Failed to register protect task: $_"
    }
} else {
    Write-ColorOutput '  protect_ipdromrec.ps1 not found - protect step skipped.' 'Gray'
}

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

# Step 1.5: PXE staging cleanup. On PXE installs unattend-02 copies ~108 GB of
# installers/scripts to C:\IPDROM so pipeline can run from local FS. Those bytes
# inflate the FFU beyond what fits on a 57 GB IpdromREC flash. Nuke the staging
# tree BEFORE reboot into WinPE so DISM captures a lean disk. USB installs never
# create C:\IPDROM, so this whole block is a no-op there.
if ($flashReady -and (Test-Path -LiteralPath 'C:\IPDROM')) {
    Write-ColorOutput '  PXE staging detected - purging C:\IPDROM to shrink FFU image...' 'Yellow'
    $freeBefore = (Get-PSDrive -Name C).Free

    # Stage trigger script locally so we can still call it after C:\IPDROM is gone.
    $safeScriptsDir = 'C:\ProgramData\IPDROM\Scripts'
    New-Item -ItemType Directory -Path $safeScriptsDir -Force -ErrorAction SilentlyContinue | Out-Null
    $localTrigger = Join-Path $safeScriptsDir 'Invoke-FfuCaptureReboot.ps1'
    try {
        Copy-Item -LiteralPath $triggerScript -Destination $localTrigger -Force -ErrorAction Stop
        $triggerScript = $localTrigger
        Write-ColorOutput "  Staged trigger script -> $localTrigger" 'Gray'
    } catch {
        Write-Warning "  Failed to stage trigger script locally: $_ (aborting PXE cleanup)"
        $flashReady = $false
    }

    if ($flashReady) {
        # Drop Run-key first so the restored image doesn't try to resurrect subst F:.
        try {
            Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' `
                -Name 'IPDROM_SubstF' -Force -ErrorAction SilentlyContinue
            Write-ColorOutput "  Removed HKLM Run key 'IPDROM_SubstF'." 'Gray'
        } catch {}

        # Drop the F: alias. Script itself is already loaded into memory so this is safe.
        try { & subst F: /D 2>$null | Out-Null } catch {}

        # Blow away staging. SilentlyContinue tolerates any file still in use.
        Remove-Item -LiteralPath 'C:\IPDROM' -Recurse -Force -ErrorAction SilentlyContinue

        # Launcher state (completion flag lives at C:\ProgramData\IPDROM_StressTest_Completed.flag,
        # NOT inside this subtree, and stays intact).
        Remove-Item -LiteralPath 'C:\ProgramData\IPDROM\State' -Recurse -Force -ErrorAction SilentlyContinue

        $freeAfter = (Get-PSDrive -Name C).Free
        $freedGB   = [math]::Round(($freeAfter - $freeBefore) / 1GB, 2)
        if (Test-Path -LiteralPath 'C:\IPDROM') {
            Write-ColorOutput "  Freed ${freedGB} GB on C: (some locked files remain in C:\IPDROM)." 'Yellow'
        } else {
            Write-ColorOutput "  Freed ${freedGB} GB on C:. Staging fully removed." 'Green'
        }
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