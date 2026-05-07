param(
    [int]$DurationMinutes = 30
)

$ErrorActionPreference = 'Continue'   # Не останавливаться при ошибках, чтобы успеть записать лог
$VerbosePreference = 'Continue'

# Сразу создаём папки и начинаем лог
$programDataRoot = Join-Path $env:ProgramData 'IPDROM'
$logDir = Join-Path $programDataRoot 'Logs'
$stateDir = Join-Path $programDataRoot 'State'
New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path $stateDir -Force -ErrorAction SilentlyContinue | Out-Null
$logFile = Join-Path $logDir 'auto_stress_after_reboot.log'

function Write-LauncherLog {
    param([string]$Message)
    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    Add-Content -Path $logFile -Value $line -Encoding utf8
    Write-Host $line
}

# Начинаем лог как можно раньше
Write-LauncherLog '========== Launcher started =========='
Write-LauncherLog ("User: {0}" -f $env:USERNAME)
Write-LauncherLog ("PSScriptRoot: {0}" -f $PSScriptRoot)
Write-LauncherLog ("Script path: {0}" -f $MyInvocation.MyCommand.Path)

# Проверяем, что скрипт запущен из правильного места (на случай ручного запуска)
$localLauncherDir = Join-Path $programDataRoot 'Scripts'
if ($PSScriptRoot -ne $localLauncherDir) {
    Write-LauncherLog "WARNING: Script not running from expected location. PSScriptRoot=$PSScriptRoot, expected=$localLauncherDir"
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
        if (-not (Test-Path $full -ErrorAction SilentlyContinue)) {
            Write-LauncherLog "Test-InstallRoot: missing $full"
            return $false
        }
    }
    Write-LauncherLog "Test-InstallRoot: $Root is valid"
    return $true
}

function Get-InstallRoot {
    # Сначала проверяем сохранённый путь
    $hintFile = Join-Path $stateDir 'InstallRoot.txt'
    if (Test-Path $hintFile -ErrorAction SilentlyContinue) {
        $hint = (Get-Content $hintFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
        if ($hint -and (Test-InstallRoot -Root $hint)) {
            Write-LauncherLog "Using saved install root: $hint"
            return $hint
        }
        Write-LauncherLog "Saved install root is invalid: $hint"
    } else {
        Write-LauncherLog "No saved InstallRoot.txt found"
    }

    # Сканируем все буквы дисков с повторными попытками
    $maxAttempts = 6
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Write-LauncherLog "Scanning for install root (attempt $attempt/$maxAttempts)..."
        $roots = @()
        foreach ($drive in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
            if ($drive.Root -match '^[A-Z]:\\$') {
                $roots += $drive.Root
            }
        }
        $roots = $roots | Sort-Object -Unique
        foreach ($root in $roots) {
            if (Test-InstallRoot -Root $root) {
                Write-LauncherLog "Detected install root by scan: $root"
                $root | Out-File -FilePath $hintFile -Encoding ascii -Force
                return $root
            }
        }
        if ($attempt -lt $maxAttempts) {
            Write-LauncherLog "Root not found, waiting 30 seconds..."
            Start-Sleep -Seconds 30
        }
    }

    Write-LauncherLog "ERROR: Unable to locate installation media root after $maxAttempts attempts."
    throw 'Unable to locate installation media root with auto_stress_test.ps1/test/SoftForTest.'
}

Write-LauncherLog 'Waiting for shell readiness...'
$maxWaitSeconds = 180
$ready = $false
for ($i = 0; $i -lt $maxWaitSeconds; $i++) {
    if (Get-Process explorer -ErrorAction SilentlyContinue) {
        $ready = $true
        break
    }
    Start-Sleep -Seconds 1
}
if ($ready) {
    Write-LauncherLog 'Explorer detected. Waiting extra 120 seconds before stress test.'
    Start-Sleep -Seconds 120
} else {
    Write-LauncherLog 'Explorer not detected within timeout. Waiting fallback 130 seconds.'
    Start-Sleep -Seconds 130
}

$installRoot = Get-InstallRoot
$autoTestScript = Join-Path $installRoot 'customization\scripts\auto_stress_test.ps1'
Write-LauncherLog ("Install root: {0}" -f $installRoot)
Write-LauncherLog ("Running: {0} -DurationMinutes {1}" -f $autoTestScript, $DurationMinutes)

try {
    # Запускаем с передачей stdout/stderr в лог
    $process = Start-Process -FilePath "powershell.exe" `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$autoTestScript`" -DurationMinutes $DurationMinutes" `
        -Wait -NoNewWindow -RedirectStandardOutput "$logDir\stress_stdout.log" -RedirectStandardError "$logDir\stress_stderr.log"

    $exitCode = $process.ExitCode
    Write-LauncherLog ("auto_stress_test.ps1 finished with exit code {0}" -f $exitCode)
    if ($exitCode -ne 0) {
        Write-LauncherLog "ERROR: Stress test script returned non-zero exit code."
    }
} catch {
    Write-LauncherLog ("FATAL ERROR: {0}" -f $_)
    Write-LauncherLog ($_.Exception.StackTrace)
    throw
}