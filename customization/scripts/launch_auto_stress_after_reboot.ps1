param(
    [int]$DurationMinutes = 720
)

$ErrorActionPreference = 'Stop'

$programDataRoot = Join-Path $env:ProgramData 'IPDROM'
$logDir = Join-Path $programDataRoot 'Logs'
$stateDir = Join-Path $programDataRoot 'State'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$logFile = Join-Path $logDir 'auto_stress_after_reboot.log'

function Write-LauncherLog {
    param([string]$Message)
    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    $line | Out-File -FilePath $logFile -Encoding utf8 -Append
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
        if (-not (Test-Path (Join-Path $Root $rel))) { return $false }
    }
    return $true
}

function Get-InstallRoot {
    $hintFile = Join-Path $stateDir 'InstallRoot.txt'
    if (Test-Path $hintFile) {
        $hint = (Get-Content $hintFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
        if ($hint -and (Test-InstallRoot -Root $hint)) {
            Write-LauncherLog ("Using saved install root: {0}" -f $hint)
            return $hint
        }
        Write-LauncherLog ("Saved install root is invalid: {0}" -f $hint)
    }

    $roots = @()
    foreach ($drive in Get-PSDrive -PSProvider FileSystem) {
        if ($drive.Root -match '^[A-Z]:\\$') {
            $roots += $drive.Root
        }
    }
    $roots = $roots | Sort-Object -Unique
    foreach ($root in $roots) {
        if (Test-InstallRoot -Root $root) {
            Write-LauncherLog ("Detected install root by scan: {0}" -f $root)
            $root | Out-File -FilePath $hintFile -Encoding ascii -Force
            return $root
        }
    }

    throw 'Unable to locate installation media root with auto_stress_test.ps1/test/SoftForTest.'
}

Write-LauncherLog 'Launcher started.'
Write-LauncherLog ("User: {0}" -f $env:USERNAME)
Write-LauncherLog ("PSScriptRoot: {0}" -f $PSScriptRoot)

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
    Write-LauncherLog 'Explorer detected. Waiting extra 20 seconds before stress test.'
    Start-Sleep -Seconds 20
} else {
    Write-LauncherLog 'Explorer not detected within timeout. Waiting fallback 30 seconds.'
    Start-Sleep -Seconds 30
}

$installRoot = Get-InstallRoot
$autoTestScript = Join-Path $installRoot 'customization\scripts\auto_stress_test.ps1'
Write-LauncherLog ("Install root: {0}" -f $installRoot)
Write-LauncherLog ("Running: {0} -DurationMinutes {1}" -f $autoTestScript, $DurationMinutes)

try {
    & $autoTestScript -DurationMinutes $DurationMinutes *>> $logFile
    Write-LauncherLog ("Completed. LASTEXITCODE={0}" -f $LASTEXITCODE)
} catch {
    Write-LauncherLog ("ERROR: {0}" -f $_)
    throw
}
