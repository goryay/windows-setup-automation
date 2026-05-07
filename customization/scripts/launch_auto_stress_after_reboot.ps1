param(
    [int]$DurationMinutes = 30
)

$ErrorActionPreference = 'Stop'

$programDataRoot = Join-Path $env:ProgramData 'IPDROM'
$logDir           = Join-Path $programDataRoot 'Logs'
$stateDir         = Join-Path $programDataRoot 'State'
$scriptsDir       = Join-Path $programDataRoot 'Scripts'
$taskName         = 'IPDROM_AutoStressTest_AfterReboot'

New-Item -ItemType Directory -Path $logDir   -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path $stateDir -Force -ErrorAction SilentlyContinue | Out-Null

$logFile       = Join-Path $logDir 'auto_stress_after_reboot.log'
$stdoutLog     = Join-Path $logDir 'stress_stdout.log'
$stderrLog     = Join-Path $logDir 'stress_stderr.log'
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

function Test-InstallRoot {
    param([string]$Root)
    if (-not $Root) { return $false }

    $needed = @(
        'customization\scripts\auto_stress_test.ps1',
        'test\aida_fio_furmark.ps1',
        'SoftForTest'
    )

    foreach ($rel in $needed) {
        $full = Join-Path $Root $rel
        if (-not (Test-Path -LiteralPath $full -ErrorAction SilentlyContinue)) {
            Write-LauncherLog "Test-InstallRoot: missing $full"
            return $false
        }
    }

    Write-LauncherLog "Test-InstallRoot: $Root is valid"
    return $true
}

function Get-InstallRoot {
    $hintFile = Join-Path $stateDir 'InstallRoot.txt'

    if (Test-Path -LiteralPath $hintFile -ErrorAction SilentlyContinue) {
        $hint = (Get-Content -LiteralPath $hintFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
        if ($hint -and (Test-InstallRoot -Root $hint)) {
            Write-LauncherLog "Using saved install root: $hint"
            return $hint
        }
        Write-LauncherLog "Saved install root is invalid: $hint"
    } else {
        Write-LauncherLog 'No saved InstallRoot.txt found'
    }

    for ($attempt = 1; $attempt -le 8; $attempt++) {
        Write-LauncherLog "Scanning for install root (attempt $attempt/8)..."

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

        Start-Sleep -Seconds 30
    }

    throw 'Unable to locate installation media root with auto_stress_test.ps1/test/SoftForTest.'
}

Write-LauncherLog '========== Launcher started =========='
Write-LauncherLog "User: $env:USERNAME"
Write-LauncherLog "PSScriptRoot: $PSScriptRoot"
Write-LauncherLog "Script path: $($MyInvocation.MyCommand.Path)"

$expectedLauncherDir = $scriptsDir
if ($PSScriptRoot -ne $expectedLauncherDir) {
    Write-LauncherLog "WARNING: launcher path differs. PSScriptRoot=$PSScriptRoot, expected=$expectedLauncherDir"
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
    $registeredBootRaw = (Get-Content -LiteralPath $bootFile | Select-Object -First 1).Trim()
    $registeredBoot = [datetime]::Parse($registeredBootRaw)
    $currentBoot    = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime

    Write-LauncherLog "Registered boot time: $($registeredBoot.ToString('o'))"
    Write-LauncherLog "Current boot time:    $($currentBoot.ToString('o'))"

    if ($currentBoot -le $registeredBoot.AddSeconds(5)) {
        Write-LauncherLog 'Same boot session detected. This is before the planned reboot. Exiting without starting stress test.'
        Exit-Cleanly 0
    }
} else {
    Write-LauncherLog 'RegisteredBootTime.txt not found. Continuing with caution.'
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
        if (Get-Process explorer -ErrorAction SilentlyContinue) {
            $ready = $true
            break
        }
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
    Write-LauncherLog "Running: $autoTestScript -DurationMinutes $DurationMinutes"

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    Remove-Item -LiteralPath $pendingFile -Force -ErrorAction SilentlyContinue

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$autoTestScript`" -DurationMinutes $DurationMinutes"

    $proc = Start-Process -FilePath $psExe `
        -ArgumentList $args `
        -Wait `
        -PassThru `
        -NoNewWindow `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog

    Write-LauncherLog "auto_stress_test.ps1 finished with exit code $($proc.ExitCode)"

    if ($proc.ExitCode -eq 0) {
        (Get-Date).ToString('o') | Out-File -FilePath $finishedFile -Encoding ascii -Force
        Exit-Cleanly 0
    }

    "Stress test failed with exit code $($proc.ExitCode) at $(Get-Date -Format 's')" | Out-File -FilePath $failedFile -Encoding utf8 -Force
    Write-LauncherLog "ERROR: Stress test failed. See $stdoutLog and $stderrLog"
    Exit-Cleanly $proc.ExitCode
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
