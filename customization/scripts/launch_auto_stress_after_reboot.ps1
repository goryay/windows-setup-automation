param(
    [int]$DurationMinutes = 720
)

$ErrorActionPreference = 'Stop'

$logDir = Join-Path $env:ProgramData 'IPDROM\Logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir 'auto_stress_after_reboot.log'

function Write-LauncherLog {
    param([string]$Message)
    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    $line | Out-File -FilePath $logFile -Encoding utf8 -Append
}

Write-LauncherLog 'Launcher started.'
Write-LauncherLog ("User: {0}" -f $env:USERNAME)
Write-LauncherLog ("PSScriptRoot: {0}" -f $PSScriptRoot)

$autoTestScript = Join-Path $PSScriptRoot 'auto_stress_test.ps1'
if (-not (Test-Path $autoTestScript)) {
    $autoTestScript = 'D:\customization\scripts\auto_stress_test.ps1'
}

if (-not (Test-Path $autoTestScript)) {
    Write-LauncherLog 'auto_stress_test.ps1 not found.'
    throw 'auto_stress_test.ps1 not found'
}

Write-LauncherLog 'Waiting for shell readiness...'

$maxWaitSeconds = 120
$ready = $false

for ($i = 0; $i -lt $maxWaitSeconds; $i++) {
    $explorer = Get-Process explorer -ErrorAction SilentlyContinue
    if ($explorer) {
        $ready = $true
        break
    }
    Start-Sleep -Seconds 1
}

if ($ready) {
    Write-LauncherLog 'Explorer detected. Waiting extra 20 seconds before stress test.'
    Start-Sleep -Seconds 20
}
else {
    Write-LauncherLog 'Explorer was not detected within timeout. Waiting fallback 30 seconds.'
    Start-Sleep -Seconds 30
}

Write-LauncherLog ("Running: {0} -DurationMinutes {1}" -f $autoTestScript, $DurationMinutes)

try {
    & $autoTestScript -DurationMinutes $DurationMinutes *>> $logFile
    Write-LauncherLog ("Completed. LASTEXITCODE={0}" -f $LASTEXITCODE)
}
catch {
    Write-LauncherLog ("ERROR: {0}" -f $_)
    throw
}
