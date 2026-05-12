<#
.SYNOPSIS
    Stable async launch with robust GPU detection.
    Screenshots via screen.ps1, reports unchanged.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$UsbRoot,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$TestArgs
)

$ErrorActionPreference = 'Stop'

# ===================== ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ =====================
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

function Test-FurMarkGpuAvailable {
    param([Parameter(Mandatory)] [int]$GpuIndex)

    if (-not (Test-Path $script:FurMarkFullPath)) { return $false }

    Write-Host "  Checking GPU $GpuIndex (8 sec FurMark probe)..." -ForegroundColor DarkGray
    $probeArgs = @(
        '--demo', 'furmark-vk',
        '--width', '1920',
        '--height', '1080',
        '--max-time', '8',
        '--no-score-box',
        '--disable-demo-options',
        "--gpu-index=$GpuIndex"
    )

    # Перехватываем stdout+stderr в файл, чтобы поймать "not supported" даже при exit 0
    $logFile = Join-Path $env:TEMP "furmark_probe_gpu${GpuIndex}_$(New-Guid).txt"
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $script:FurMarkFullPath
        $psi.Arguments = $probeArgs -join ' '
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute = $false

        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo = $psi

        $outBuf = [System.Text.StringBuilder]::new()
        $errBuf = [System.Text.StringBuilder]::new()
        $proc.OutputDataReceived += { param($s,$e) if ($e.Data) { $null = $outBuf.AppendLine($e.Data) } }
        $proc.ErrorDataReceived  += { param($s,$e) if ($e.Data) { $null = $errBuf.AppendLine($e.Data) } }

        $null = $proc.Start()
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()
        $proc.WaitForExit()

        $combined = $outBuf.ToString() + $errBuf.ToString()

        # FurMark выдаёт "is not supported" или "not supported" при недопустимом gpu-index
        if ($combined -match 'not supported') {
            Write-Warning "  GPU $GpuIndex probe output contains 'not supported' — skipping GPU $GpuIndex."
            Write-Host    "  Probe output: $($combined.Trim())" -ForegroundColor DarkGray
            return $false
        }

        if ($proc.ExitCode -eq 0) {
            Write-Host "  GPU $GpuIndex available (exit 0)" -ForegroundColor Green
            return $true
        } else {
            Write-Warning "  GPU $GpuIndex NOT available (exit $($proc.ExitCode)). Will be skipped."
            Write-Host    "  Probe output: $($combined.Trim())" -ForegroundColor DarkGray
            return $false
        }
    } catch {
        Write-Warning "  GPU $GpuIndex probe error: $_"
        return $false
    } finally {
        Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
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

# ===================== ПУТИ =====================
if (-not $UsbRoot) { $UsbRoot = [System.IO.Path]::GetPathRoot($PSScriptRoot) }
$script:Aida64FullPath  = Join-Path $UsbRoot 'SoftForTest\AIDA64\AIDA64Port.exe'
$script:FurMarkFullPath = Join-Path $UsbRoot 'SoftForTest\FurMark\furmark.exe'
$script:FioFullPath     = 'C:\Program Files\fio\fio.exe'

$screenScript = Join-Path $PSScriptRoot 'screen.ps1'   # <-- ваш screen.ps1

# ===================== РАЗБОР АРГУМЕНТОВ =====================
if (-not $TestArgs -or $TestArgs.Count -lt 2) {
    Write-Host 'Not enough arguments. Example: .\aida_fio_furmark.ps1 AIDA FURMARK GPU2 FIO D 10'
    exit 1
}

$tests = @($TestArgs[0..($TestArgs.Count - 2)])
$durationMin = [int]([double]$TestArgs[-1])
if ($durationMin -le 0) { throw "Invalid duration: $durationMin min" }

$hours = $durationMin / 60
$totalSeconds = [int][Math]::Round($hours * 3600)

$requestedGpuCount = 1
if ($tests -contains 'GPU2') { $requestedGpuCount = 2 }

$fioDrives = @($tests | Where-Object { $_ -match '^[A-Za-z]$' } | ForEach-Object { $_.ToUpper() })

# ===================== ПРОВЕРКА GPU =====================
$usableGpus = @()
if ($tests -contains 'FURMARK') {
    Write-Host "Probing GPUs for FurMark..." -ForegroundColor Yellow
    for ($gpu = 0; $gpu -lt $requestedGpuCount; $gpu++) {
        if (Test-FurMarkGpuAvailable -GpuIndex $gpu) {
            $usableGpus += $gpu
        }
    }
    if ($usableGpus.Count -eq 0) {
        Write-Warning "No working GPUs found. FurMark will be skipped."
    } else {
        Write-Host "Usable GPUs: $($usableGpus -join ', ')" -ForegroundColor Green
    }
}

# ===================== ФУНКЦИИ ЗАПУСКА (как в старой версии, с токенами _FINAL для screen.ps1) =====================
function Start-AidaTest {
    param([double]$hours, [bool]$includeGPU)
    if (-not (Test-Path $script:Aida64FullPath)) { throw "AIDA64 not found: $script:Aida64FullPath" }

    $minutes = [Math]::Round($hours * 60)
    $gpu = if ($includeGPU) { ",GPU" } else { "" }
    $params = @("/SST CPU,FPU,Cache,RAM,Disk$gpu", "/SSTDUR $minutes")
    $cmdLine = "`"$script:Aida64FullPath`" $($params -join ' ')"

    Write-Host "Starting AIDA64..."
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList @("/k", "$cmdLine") -PassThru
    return $proc
}

function Start-FurMarkConsole {
    param([int]$DurationSeconds, [int]$GpuIndex)
    if (-not (Test-Path $script:FurMarkFullPath)) { return $null }

    $baseTitle = "IPDROM_FURMARK_GPU${GpuIndex}"
    $cmdLine = @(
        "title ${baseTitle}_RUNNING",
        "echo Starting FurMark GPU $GpuIndex...",
        "`"$script:FurMarkFullPath`" --demo furmark-vk --width 1920 --height 1080 --max-time $DurationSeconds --no-score-box --disable-demo-options --gpu-index=$GpuIndex",
        'set IPDROM_RC=!ERRORLEVEL!',
        "echo.",
        "echo ========================================",
        "echo FurMark GPU $GpuIndex completed (exit !IPDROM_RC!)",
        "echo ========================================",
        "title ${baseTitle}_FINAL",
        "pause > nul"
    ) -join ' & '

    Write-Host "Launching FurMark GPU $GpuIndex"
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/v:on', '/k', $cmdLine) -WindowStyle Normal -PassThru
    return [pscustomobject]@{ Process = $proc; TitleToken = $baseTitle; GpuIndex = $GpuIndex }
}

function Start-FioConsole {
    param([string]$DriveLetter, [int]$DurationSeconds)
    if (-not $script:FioFullPath) { return $null }

    $DriveLetter = $DriveLetter.Trim().TrimEnd(':').ToUpper()
    $testDir = "${DriveLetter}:\fio_tests"
    New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    $testFile = Join-Path $testDir "fio_test_$(New-Guid).dat"
    $jobFile = Join-Path $env:TEMP "fio_job_$(New-Guid).fio"

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

    $baseTitle = "IPDROM_FIO_${DriveLetter}"
    $cmdLine = @(
        "title ${baseTitle}_RUNNING",
        "echo Starting FIO on drive $DriveLetter...",
        "`"$script:FioFullPath`" `"$jobFile`"",
        'set IPDROM_RC=!ERRORLEVEL!',
        "echo.",
        "echo ========================================",
        "echo FIO $DriveLetter completed (exit !IPDROM_RC!)",
        "echo ========================================",
        "title ${baseTitle}_FINAL",
        "pause > nul"
    ) -join ' & '

    Write-Host "Launching FIO on $DriveLetter"
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/v:on', '/k', $cmdLine) -WindowStyle Normal -PassThru
    return [pscustomobject]@{ Process = $proc; TitleToken = $baseTitle; Drive = $DriveLetter; JobFile = $jobFile }
}

# ===================== ЗАПУСК ТЕСТОВ =====================
$aidaProcess = $null
$furmarkStarted = @()
$fioStarted = @()

if ($tests -contains 'AIDA') {
    $aidaStartTime = Get-Date
    $includeGPU = -not ($tests -contains 'FURMARK')
    $aidaProcess = Start-AidaTest -hours $hours -includeGPU $includeGPU
    Write-Host "AIDA64 started (PID: $($aidaProcess.Id))"
    Start-Sleep -Seconds 20
}

if ($tests -contains 'FURMARK' -and $usableGpus.Count -gt 0) {
    Write-Host "Starting FurMark for GPUs: $($usableGpus -join ', ')"
    foreach ($gpu in $usableGpus) {
        $launch = Start-FurMarkConsole -DurationSeconds $totalSeconds -GpuIndex $gpu
        if ($launch) {
            $furmarkStarted += $launch
            Start-Sleep -Seconds 3
        }
    }
}

if ($tests -contains 'FIO') {
    if ($fioDrives.Count -eq 0) {
        Write-Warning "FIO requested but no drives specified."
    } else {
        Write-Host "Starting FIO for drives: $($fioDrives -join ', ')"
        foreach ($drive in $fioDrives) {
            $launch = Start-FioConsole -DriveLetter $drive -DurationSeconds $totalSeconds
            if ($launch) {
                $fioStarted += $launch
                Start-Sleep -Seconds 3
            }
        }
    }
}

# ===================== СКРИНШОТЫ ЧЕРЕЗ SCREEN.PS1 =====================
$invokeScreen = {
    param([string]$Mode)

    if (Test-Path $screenScript) {
        try {
            $engine = Get-Command pwsh.exe -ErrorAction SilentlyContinue
            if (-not $engine) { $engine = Get-Command powershell.exe -ErrorAction SilentlyContinue }
            $psExePath = $engine.Source

            $proc = Start-Process -FilePath $psExePath `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $screenScript, '-Mode', $Mode) `
                -WindowStyle Hidden -Wait -PassThru

            if ($proc.ExitCode -eq 0) {
                Write-Host "Screenshot $Mode completed." -ForegroundColor Green
            } else {
                Write-Warning "Screenshot $Mode exited with code $($proc.ExitCode) — continuing."
            }
        } catch {
            Write-Warning "Screenshot $Mode failed: $_ — continuing."
        }
    } else {
        Write-Warning "screen.ps1 not found at $screenScript — skipping screenshot."
    }
}

# ===================== ОЖИДАНИЕ ОКОНЧАНИЯ ТЕСТОВ =====================
Write-Host "Waiting for tests to finish (~${durationMin} min)..."

if ($tests -contains 'AIDA' -and $totalSeconds -gt 300) {
    $autoShotDelay = $totalSeconds - 300

    Write-Host "Waiting $autoShotDelay sec before AidaAuto screenshot..."
    Start-Sleep -Seconds $autoShotDelay

    & $invokeScreen 'AidaAuto'

    Write-Host "Waiting remaining 300 sec..."
    Start-Sleep -Seconds 300
} else {
    Start-Sleep -Seconds $totalSeconds
}

# Даём окнам время переключиться в _FINAL
if ($furmarkStarted.Count -gt 0 -or $fioStarted.Count -gt 0) {
    Write-Host "Giving console windows a few seconds to finalize..."
    Start-Sleep -Seconds 10
}

# Финальные скриншоты
if ($tests -contains 'AIDA') {
    & $invokeScreen 'AidaFinal'
}

if ($furmarkStarted.Count -gt 0) {
    foreach ($launch in $furmarkStarted) {
        try { $launch.Process.Refresh() } catch {}
        if ($launch.Process.HasExited) {
            Write-Warning "FurMark GPU $($launch.GpuIndex) exited early (cmd exit: $($launch.Process.ExitCode)). Crash or driver failure suspected."
        }
    }
    & $invokeScreen 'FurMarkFinal'
    Get-Process -Name 'furmark' -ErrorAction SilentlyContinue | Stop-Process -Force
}

if ($fioStarted.Count -gt 0) {
    & $invokeScreen 'FioFinal'
    foreach ($launch in $fioStarted) {
        Remove-Item -LiteralPath $launch.JobFile -Force -ErrorAction SilentlyContinue
    }
}

& $invokeScreen 'DesktopFinal'

# ===================== ОТЧЁТ AIDA64 =====================
Write-Host "Generating AIDA64 report..."
Close-ProcessByName -name "AIDA64Port" -waitSeconds 20
Close-ProcessByName -name "aida64" -waitSeconds 5

if (Test-Path $script:Aida64FullPath) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $computerName = $env:COMPUTERNAME
    $reportsDir = Join-Path (Join-Path $desktop $computerName) 'Reports'
    New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null
    $reportPath = Join-Path $reportsDir 'SystemReport.html'

    Start-Process -FilePath $script:Aida64FullPath -ArgumentList @(
        '/R', $reportPath,
        '/ALL', '/SUM', '/HW', '/SW', '/AUDIT', '/HTML'
    ) -Wait -NoNewWindow

    if (Test-Path $reportPath) {
        Write-Host "Report saved to $reportPath" -ForegroundColor Green
    } else {
        Write-Warning "Failed to generate AIDA64 report."
    }
} else {
    Write-Warning "AIDA64 not found, report skipped."
}

Write-Host "Testing completed." -ForegroundColor Green