[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$UsbRoot,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$TestArgs
)

Push-Location -LiteralPath $PSScriptRoot
$script:__popOnExit = $true
$ErrorActionPreference = 'Stop'

function Get-PowerShellEngine {
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($pwsh -and $pwsh.Source) { return $pwsh.Source }

    $powershell = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($powershell -and $powershell.Source) { return $powershell.Source }

    throw 'PowerShell engine not found.'
}

function Invoke-PowerShellFile {
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [string[]]$ExtraArguments = @(),
        [switch]$Hidden
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "Helper script not found: $FilePath"
    }

    $engine = Get-PowerShellEngine
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FilePath) + $ExtraArguments

    $style = if ($Hidden) { 'Hidden' } else { 'Normal' }
    $proc = Start-Process -FilePath $engine -ArgumentList $argList -WindowStyle $style -Wait -PassThru

    if ($proc.ExitCode -ne 0) {
        throw "Helper failed: $FilePath (exit $($proc.ExitCode))"
    }
}

function Start-ScreenCapture {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('AidaAuto','AidaFinal','FurMarkFinal','FioFinal','DesktopFinal')]
        [string]$Mode
    )

    $screenScript = Join-Path $PSScriptRoot 'screen.ps1'
    if (-not (Test-Path -LiteralPath $screenScript)) {
        Write-Warning "screen.ps1 not found: $screenScript. Screenshot skipped: $Mode"
        return
    }

    try {
        Invoke-PowerShellFile -FilePath $screenScript -ExtraArguments @('-Mode', $Mode) -Hidden
        Write-Host "Screenshot done: $Mode" -ForegroundColor Green
    }
    catch {
        Write-Warning "Screenshot failed: $Mode. Error: $_"
    }
}

function Sleep-UntilMoment {
    param(
        [Parameter(Mandatory)] [datetime]$Moment,
        [string]$Label = 'wait'
    )

    $remain = [int][Math]::Ceiling(($Moment - (Get-Date)).TotalSeconds)
    if ($remain -gt 0) {
        Write-Host "Waiting $remain sec for $Label..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $remain
    }
}

function Wait-ForProcessNamesToExit {
    param(
        [Parameter(Mandatory)] [string[]]$ProcessNames,
        [int]$TimeoutSec = 180,
        [string]$Label = 'processes'
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $alive = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $ProcessNames -contains $_.ProcessName })
        if ($alive.Count -eq 0) {
            Write-Host "$Label finished." -ForegroundColor Green
            return $true
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    Write-Warning "$Label still running after $TimeoutSec sec"
    return $false
}

function Wait-ForFinalCmdWindows {
    param(
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [int]$ExpectedCount,
        [int]$TimeoutSec = 180,
        [string]$Label = 'console final state'
    )

    if ($ExpectedCount -le 0) { return $true }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $found = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -ieq 'cmd' -and
            $_.MainWindowHandle -ne 0 -and
            $_.MainWindowTitle -and
            $_.MainWindowTitle -like "*$Token*" -and
            $_.MainWindowTitle -like '*_FINAL*'
        })

        if ($found.Count -ge $ExpectedCount) {
            Write-Host "$Label ready ($($found.Count)/$ExpectedCount)." -ForegroundColor Green
            Start-Sleep -Seconds 3
            return $true
        }

        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    Write-Warning "$Label not ready after $TimeoutSec sec"
    return $false
}

function Find-FioExecutable {
    param([Parameter(Mandatory)] [string]$Root)

    $candidates = @(
        'C:\Program Files\fio\fio.exe',
        'C:\Program Files (x86)\fio\fio.exe',
        (Join-Path $Root 'SoftForTest\fio\fio.exe'),
        (Join-Path $Root 'SoftForTest\FIO\fio.exe'),
        (Join-Path $Root 'SoftForTest\fio\x64\fio.exe'),
        (Join-Path $Root 'SoftForTest\FIO\x64\fio.exe')
    )

    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    }

    $softRoot = Join-Path $Root 'SoftForTest'
    if (Test-Path -LiteralPath $softRoot) {
        $found = Get-ChildItem -Path $softRoot -Filter 'fio.exe' -Recurse -File -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
        if ($found) { return $found }
    }

    return $null
}

function Start-AidaTest {
    param(
        [Parameter(Mandatory)] [int]$DurationMinutes,
        [bool]$IncludeGPU
    )

    if (-not (Test-Path -LiteralPath $script:Aida64FullPath)) {
        throw "AIDA64 not found: $script:Aida64FullPath"
    }

    $targets = @('CPU','FPU','Cache','RAM','Disk')
    if ($IncludeGPU) { $targets += 'GPU' }

    $argList = @('/SST', ($targets -join ','), '/SSTDUR', "$DurationMinutes")
    return Start-Process -FilePath $script:Aida64FullPath -ArgumentList $argList -PassThru
}

function Test-FurMarkGpuAvailable {
    <#
    .SYNOPSIS
        Быстрая проверка: может ли FurMark запустить рендеринг на указанном GPU.
        Запускает FurMark с --max-time 8, ждёт завершения и проверяет exit code.
        Exit 0 = GPU доступен. Любой другой код (особ. -1073741819 = 0xC0000005) = недоступен.
    #>
    param(
        [Parameter(Mandatory)] [int]$GpuIndex
    )

    Write-Host "  Probing GPU $GpuIndex availability (8-sec FurMark test)..." -ForegroundColor DarkGray

    $probeArgs = @(
        '--demo', 'furmark-vk',
        '--width', '1920',
        '--height', '1080',
        '--max-time', '8',
        '--no-score-box',
        '--disable-demo-options',
        "--gpu-index=$GpuIndex"
    )

    try {
        $proc = Start-Process -FilePath $script:FurMarkFullPath `
                              -ArgumentList $probeArgs `
                              -WindowStyle Hidden `
                              -Wait -PassThru `
                              -ErrorAction Stop

        if ($proc.ExitCode -eq 0) {
            Write-Host "  GPU $GpuIndex probe: OK (exit 0)" -ForegroundColor Green
            return $true
        } else {
            Write-Warning "  GPU $GpuIndex probe FAILED (exit $($proc.ExitCode)). This GPU will be skipped."
            Write-Warning "  Exit -1073741819 (0xC0000005) = Access Violation: GPU likely has no display output or Vulkan surface unavailable."
            return $false
        }
    } catch {
        Write-Warning "  GPU $GpuIndex probe error: $_"
        return $false
    }
}

function Get-NvidiaSmiPath {
    $candidates = @(
        "$env:WINDIR\System32\nvidia-smi.exe",
        "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
        "${env:ProgramFiles(x86)}\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
    )

    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) {
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
        $lines = @(
            & $smi --query-gpu=index,name --format=csv,noheader 2>$null |
            Where-Object { $_ -and $_.Trim() }
        )

        return $lines
    }
    catch {
        return @()
    }
}

function Get-ExpectedNvidiaDisplayCount {
    $count = 0

    try {
        $pnpDevices = @(
            Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FriendlyName -like '*NVIDIA*' -and
                $_.Status -ne 'Error'
            }
        )

        if ($pnpDevices.Count -gt 0) {
            $count = $pnpDevices.Count
        }
    }
    catch {
        $count = 0
    }

    if ($count -le 0) {
        try {
            $controllers = @(
                Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name -like '*NVIDIA*'
                }
            )

            if ($controllers.Count -gt 0) {
                $count = $controllers.Count
            }
        }
        catch {
            $count = 0
        }
    }

    return $count
}

function Wait-NvidiaGpusReady {
    param(
        [int]$ExpectedCount = 1,
        [int]$TimeoutSeconds = 300
    )

    if ($ExpectedCount -lt 1) {
        $ExpectedCount = 1
    }

    Write-Host "Waiting for NVIDIA GPUs. Expected count: $ExpectedCount" -ForegroundColor DarkGray

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $stableHits = 0
    $lastCount = -1
    $lastLines = @()

    while ((Get-Date) -lt $deadline) {
        $lines = @(Get-NvidiaGpuLines)
        $count = $lines.Count

        if ($count -eq $lastCount -and $count -ge $ExpectedCount) {
            $stableHits++
        }
        else {
            $stableHits = 0
        }

        $lastCount = $count
        $lastLines = $lines

        if ($stableHits -ge 3) {
            Write-Host "NVIDIA GPUs ready: $($lines -join '; ')" -ForegroundColor Green
            return $lines
        }

        Write-Host "NVIDIA GPUs visible now: $count. Waiting..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 10
    }

    Write-Warning "NVIDIA GPUs were not fully ready within timeout. Last visible count: $($lastLines.Count)"
    if ($lastLines.Count -gt 0) {
        Write-Warning "Last NVIDIA list: $($lastLines -join '; ')"
    }

    return $lastLines
}

function Start-FurMarkConsole {
    param(
        [Parameter(Mandatory)] [int]$DurationSeconds,
        [Parameter(Mandatory)] [int]$GpuIndex
    )

    if (-not (Test-Path -LiteralPath $script:FurMarkFullPath)) {
        Write-Warning "FurMark not found: $script:FurMarkFullPath. FurMark skipped."
        return $null
    }

    $number = $GpuIndex + 1
    $baseTitle = "IPDROM_FURMARK_$number"

    $params = @(
        '--demo furmark-vk',
        '--width 1920',
        '--height 1080',
        "--max-time $DurationSeconds",
        '--no-score-box',
        '--disable-demo-options',
        "--gpu-index $GpuIndex"
    )

    $cmdLine = @(
        "title ${baseTitle}_RUNNING",
        "echo Starting FurMark for GPU $GpuIndex...",
        "`"$script:FurMarkFullPath`" $($params -join ' ')",
        'set "IPDROM_RC=!ERRORLEVEL!"',
        'echo.',
        'echo ========================================',
        'echo FurMark test completed!',
        'echo Exit code: !IPDROM_RC!',
        'echo ========================================',
        "title ${baseTitle}_FINAL",
        'pause > nul'
    ) -join ' & '

    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/v:on', '/k', $cmdLine) -WindowStyle Normal -PassThru

    return [pscustomobject]@{
        Process    = $proc
        TitleToken = $baseTitle
        GpuIndex   = $GpuIndex
    }
}

function Start-FioConsole {
    param(
        [Parameter(Mandatory)] [string]$DriveLetter,
        [Parameter(Mandatory)] [int]$DurationSeconds
    )

    if (-not $script:FioFullPath) {
        Write-Warning 'FIO executable not found. FIO skipped.'
        return $null
    }

    $DriveLetter = $DriveLetter.Trim().TrimEnd(':').ToUpper()
    if ($DriveLetter -notmatch '^[A-Z]$') {
        Write-Warning "Invalid FIO drive letter: $DriveLetter"
        return $null
    }

    $driveRoot = "${DriveLetter}:\"
    if (-not (Test-Path -LiteralPath $driveRoot)) {
        Write-Warning "Drive does not exist: $driveRoot"
        return $null
    }

    $testDir = "${DriveLetter}:\fio_tests"
    if (-not (Test-Path -LiteralPath $testDir)) {
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    }

    $testFile = Join-Path $testDir ("ipdrom_fio_test_{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
    $jobFile = Join-Path $env:TEMP ("ipdrom_fio_{0}_{1}.fio" -f $DriveLetter, ([guid]::NewGuid().ToString('N')))

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

    $baseTitle = "IPDROM_FIO_$DriveLetter"
    $cmdLine = @(
        "title ${baseTitle}_RUNNING",
        "echo Starting FIO test for drive $DriveLetter...",
        'echo Please wait...',
        "`"$script:FioFullPath`" `"$jobFile`"",
        'set "IPDROM_RC=!ERRORLEVEL!"',
        'echo.',
        'echo ========================================',
        'echo FIO test completed!',
        'echo Exit code: !IPDROM_RC!',
        'echo ========================================',
        "title ${baseTitle}_FINAL",
        'pause > nul'
    ) -join ' & '

    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/v:on', '/k', $cmdLine) -WindowStyle Normal -PassThru

    return [pscustomobject]@{
        Process    = $proc
        TitleToken = $baseTitle
        Drive      = $DriveLetter
        JobFile    = $jobFile
    }
}

try {
    if (-not $UsbRoot) {
        $UsbRoot = [System.IO.Path]::GetPathRoot($PSScriptRoot)
    }
    if (-not $UsbRoot) { $UsbRoot = 'D:\' }

    $script:Aida64FullPath  = Join-Path $UsbRoot 'SoftForTest\AIDA64\AIDA64Port.exe'
    $script:FurMarkFullPath = Join-Path $UsbRoot 'SoftForTest\FurMark\furmark.exe'
    $script:FioFullPath     = Find-FioExecutable -Root $UsbRoot

    if (-not $TestArgs -or $TestArgs.Count -lt 2) {
        Write-Host 'No test arguments provided.' -ForegroundColor Yellow
        Write-Host 'Example: .\aida_fio_furmark6.ps1 AIDA FURMARK GPU2 FIO D 10' -ForegroundColor Yellow
        exit 1
    }

    $tests = @($TestArgs[0..($TestArgs.Count - 2)])
    $durationMin = [int]([double]$TestArgs[-1])
    if ($durationMin -le 0) { throw "Invalid duration: $durationMin" }

    $totalSeconds = $durationMin * 60
    $requestedGpuCount = 1

    if ($tests -contains 'GPU2') {
        $requestedGpuCount = 2
    }

    $expectedGpuCount = Get-ExpectedNvidiaDisplayCount

    if ($expectedGpuCount -lt $requestedGpuCount) {
        $expectedGpuCount = $requestedGpuCount
    }

    Write-Host "Requested GPU count: $requestedGpuCount" -ForegroundColor DarkGray
    Write-Host "Expected NVIDIA GPU count from system: $expectedGpuCount" -ForegroundColor DarkGray

    $nvidiaGpuLines = @(Wait-NvidiaGpusReady -ExpectedCount $expectedGpuCount -TimeoutSeconds 300)
    $detectedGpuCount = $nvidiaGpuLines.Count

    if ($detectedGpuCount -ge 2) {
        $gpuCount = $detectedGpuCount
    }
    elseif ($expectedGpuCount -ge 2) {
        $gpuCount = 2
    }
    elseif ($requestedGpuCount -ge 2) {
        $gpuCount = 2
    }
    elseif ($detectedGpuCount -ge 1) {
        $gpuCount = $detectedGpuCount
    }
    else {
        $gpuCount = 1
    }

    Write-Host "Final FurMark GPU count: $gpuCount" -ForegroundColor Green

    if ($nvidiaGpuLines.Count -gt 0) {
        Write-Host "NVIDIA GPUs for FurMark: $($nvidiaGpuLines -join '; ')" -ForegroundColor Gray
    }

    $fioDrives = @($tests | Where-Object { $_ -match '^[A-Za-z]$' } | ForEach-Object { $_.ToUpper() })

    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host 'STARTING TESTS' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host "USB root:   $UsbRoot" -ForegroundColor DarkGray
    Write-Host "AIDA64:     $script:Aida64FullPath" -ForegroundColor DarkGray
    Write-Host "FurMark:    $script:FurMarkFullPath" -ForegroundColor DarkGray
    Write-Host "FIO:        $(if ($script:FioFullPath) { $script:FioFullPath } else { 'NOT FOUND' })" -ForegroundColor DarkGray
    Write-Host "Tests:      $($tests -join ', ')" -ForegroundColor Gray
    Write-Host "Duration:   $durationMin min" -ForegroundColor Gray

    $latestEnd = Get-Date
    $aidaStartedAt = $null
    $aidaEndsAt = $null
    $aidaProcess = $null
    $furMarkLaunches = @()
    $fioLaunches = @()

    $furMarkRequested = $tests -contains 'FURMARK'
    $furMarkAvailable = $furMarkRequested -and (Test-Path -LiteralPath $script:FurMarkFullPath)

    if ($furMarkRequested -and -not $furMarkAvailable) {
        Write-Warning "FurMark requested but executable not found: $script:FurMarkFullPath"
        Write-Host 'AIDA64 will keep GPU stress enabled because FurMark is unavailable.' -ForegroundColor Yellow
    }

    if ($tests -contains 'AIDA') {
        Write-Host 'Starting AIDA64...' -ForegroundColor Yellow
        $aidaStartedAt = Get-Date
        $includeGPU = -not $furMarkAvailable
        $aidaProcess = Start-AidaTest -DurationMinutes $durationMin -IncludeGPU $includeGPU
        $aidaEndsAt = $aidaStartedAt.AddSeconds($totalSeconds)
        if ($aidaEndsAt -gt $latestEnd) { $latestEnd = $aidaEndsAt }
        Write-Host "AIDA64 started (PID: $($aidaProcess.Id))" -ForegroundColor Green

        # Дать AIDA64 нормально открыть окно перед запуском FurMark
        if ($totalSeconds -gt 180) {
            Start-Sleep -Seconds 120
        } else {
            Start-Sleep -Seconds 20
        }
    }

    if ($furMarkAvailable) {
        Write-Host 'Starting FurMark...' -ForegroundColor Yellow
        $furStartedAt = Get-Date

        for ($gpu = 0; $gpu -lt $gpuCount; $gpu++) {
            $launch = Start-FurMarkConsole -DurationSeconds $totalSeconds -GpuIndex $gpu
            if ($launch) {
                $furMarkLaunches += $launch
                Write-Host "FurMark console started (PID: $($launch.Process.Id), GPU: $gpu, Token: $($launch.TitleToken))" -ForegroundColor Green
            }
            # Пауза 30 сек между инстанциями FurMark.
            # Подтверждено тестом: --gpu-index 1 работает (GPU 1: 100%), но если запускать
            # вторую инстанцию слишком быстро — краш exit -1073741819 (0xC0000005) из-за
            # конфликта Vulkan-инициализации пока первая инстанция ещё захватывает ресурсы.
            # Проб-тест (8 сек) частично прогревает контекст, 30 сек паузы гарантируют стабильность.
            if ($gpu -lt ($gpuCount - 1)) {
                Write-Host "Waiting 30 sec before starting next FurMark instance (Vulkan init buffer)..." -ForegroundColor DarkGray
                Start-Sleep -Seconds 30
            }
        }

        if ($furMarkLaunches.Count -gt 0) {
            $furEndsAt = $furStartedAt.AddSeconds($totalSeconds + 20)
            if ($furEndsAt -gt $latestEnd) { $latestEnd = $furEndsAt }
        }
    }

    if ($tests -contains 'FIO') {
        if ($fioDrives.Count -eq 0) {
            Write-Warning 'FIO requested, but no drive letters were provided. Example: FIO D 10'
        } else {
            Write-Host "Starting FIO for drives: $($fioDrives -join ', ')" -ForegroundColor Yellow
            $fioStartedAt = Get-Date

            foreach ($drive in $fioDrives) {
                $launch = Start-FioConsole -DriveLetter $drive -DurationSeconds $totalSeconds
                if ($launch) {
                    $fioLaunches += $launch
                    Write-Host "FIO console started (PID: $($launch.Process.Id), Drive: $drive, Token: $($launch.TitleToken))" -ForegroundColor Green
                }
                Start-Sleep -Seconds 3
            }

            if ($fioLaunches.Count -gt 0) {
                $fioEndsAt = $fioStartedAt.AddSeconds($totalSeconds + 20)
                if ($fioEndsAt -gt $latestEnd) { $latestEnd = $fioEndsAt }
            }
        }
    }

    if ($aidaStartedAt) {
        $autoShotAt = if ($totalSeconds -gt 300) {
            $aidaEndsAt.AddSeconds(-300)
        } else {
            $aidaStartedAt.AddSeconds([Math]::Max($totalSeconds - 30, 15))
        }

        if ($autoShotAt -lt $aidaEndsAt) {
            Sleep-UntilMoment -Moment $autoShotAt -Label 'AIDA64 auto screenshot'
            Write-Host 'Taking AIDA64 auto screenshot...' -ForegroundColor Yellow
            Start-ScreenCapture -Mode 'AidaAuto'
        }
    }

    Sleep-UntilMoment -Moment $latestEnd -Label 'expected test completion'

    if ($furMarkLaunches.Count -gt 0) {
        Write-Host 'Waiting for FurMark renderer to finish...' -ForegroundColor Yellow
        Wait-ForProcessNamesToExit -ProcessNames @('furmark','furmark_gui') -TimeoutSec 180 -Label 'FurMark renderer' | Out-Null

        Write-Host 'Waiting for FurMark final console text...' -ForegroundColor Yellow
        Wait-ForFinalCmdWindows -Token 'IPDROM_FURMARK_' -ExpectedCount $furMarkLaunches.Count -TimeoutSec 180 -Label 'FurMark final console' | Out-Null

        Write-Host 'Capturing FurMark final console(s)...' -ForegroundColor Yellow
        Start-ScreenCapture -Mode 'FurMarkFinal'
    } elseif ($furMarkRequested) {
        Write-Host 'FurMark was skipped. No FurMark final screenshots will be taken.' -ForegroundColor Yellow
    }

    if (($tests -contains 'FIO') -and $fioLaunches.Count -gt 0) {
        Write-Host 'Waiting for FIO worker(s) to finish...' -ForegroundColor Yellow
        Wait-ForProcessNamesToExit -ProcessNames @('fio') -TimeoutSec 180 -Label 'FIO workers' | Out-Null

        Write-Host 'Waiting for FIO final console text...' -ForegroundColor Yellow
        Wait-ForFinalCmdWindows -Token 'IPDROM_FIO_' -ExpectedCount $fioLaunches.Count -TimeoutSec 180 -Label 'FIO final console' | Out-Null

        Write-Host 'Capturing FIO final console(s)...' -ForegroundColor Yellow
        Start-ScreenCapture -Mode 'FioFinal'
    }

    if ($aidaStartedAt) {
        Write-Host 'Capturing final AIDA64 window...' -ForegroundColor Yellow
        Start-ScreenCapture -Mode 'AidaFinal'
    }

    Write-Host 'Taking final desktop screenshot...' -ForegroundColor Yellow
    Start-ScreenCapture -Mode 'DesktopFinal'

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host 'GENERATING REPORTS' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan

    $computerName = $env:COMPUTERNAME
    $desktop = [Environment]::GetFolderPath('Desktop')
    $baseDir = Join-Path $desktop $computerName
    $reportsDir = Join-Path $baseDir 'Reports'
    New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null

    Get-Process -Name 'AIDA64Port','aida64','AIDA64BusinessPortable' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5

    if (Test-Path -LiteralPath $script:Aida64FullPath) {
        $reportPath = Join-Path $reportsDir 'SystemReport.html'
        Write-Host 'Generating AIDA64 report...' -ForegroundColor Yellow
        Start-Process -FilePath $script:Aida64FullPath -ArgumentList @('/R', $reportPath, '/ALL', '/SUM', '/HW', '/SW', '/AUDIT', '/HTML') -Wait -NoNewWindow

        if (Test-Path -LiteralPath $reportPath) {
            Write-Host "AIDA64 report: $reportPath" -ForegroundColor Green
        } else {
            Write-Warning "AIDA64 report was not created: $reportPath"
        }
    } else {
        Write-Warning "AIDA64 report skipped. AIDA64 not found: $script:Aida64FullPath"
    }

    $smartScript = Join-Path $PSScriptRoot 'smart.ps1'
    if (Test-Path -LiteralPath $smartScript) {
        Write-Host 'Generating SMART disk report...' -ForegroundColor Yellow
        try {
            Invoke-PowerShellFile -FilePath $smartScript -ExtraArguments @('-ComputerName', $computerName, '-OutputFolder', $reportsDir, '-NoPause')
            Write-Host 'SMART disk report generated.' -ForegroundColor Green
        } catch {
            Write-Warning "SMART disk report failed: $_"
        }
    } else {
        Write-Warning "smart.ps1 not found: $smartScript"
    }

    Write-Host 'Testing completed' -ForegroundColor Green
    exit 0
}
catch {
    Write-Host ''
    Write-Host '========================================' -ForegroundColor Red
    Write-Host 'TEST SCRIPT FAILED' -ForegroundColor Red
    Write-Host '========================================' -ForegroundColor Red
    Write-Host $_ -ForegroundColor Red
    exit 1
}
finally {
    if ($script:__popOnExit) { Pop-Location }
}