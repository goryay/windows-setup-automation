param(
    [Parameter(Mandatory = $true)]
    [string]$InstallRoot,
    [int]$DurationMinutes = 30
)

$ErrorActionPreference = 'Stop'

$programDataRoot = Join-Path $env:ProgramData 'IPDROM'
$scriptsDir = Join-Path $programDataRoot 'Scripts'
$stateDir = Join-Path $programDataRoot 'State'
$logDir = Join-Path $programDataRoot 'Logs'
$rebootMarker = Join-Path $programDataRoot 'BeforeStressTestReboot.done'
$taskName = 'IPDROM_AutoStressTest_AfterReboot'

New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

$sourceLauncher = Join-Path $InstallRoot 'customization\scripts\launch_auto_stress_after_reboot.ps1'
if (-not (Test-Path $sourceLauncher)) {
    throw "Launcher not found on installation media: $sourceLauncher"
}

$localLauncher = Join-Path $scriptsDir 'launch_auto_stress_after_reboot.ps1'
Copy-Item -LiteralPath $sourceLauncher -Destination $localLauncher -Force

$installRootNormalized = [System.IO.Path]::GetFullPath($InstallRoot)
$installRootNormalized | Out-File -FilePath (Join-Path $stateDir 'InstallRoot.txt') -Encoding ascii -Force
Set-Content -Path $rebootMarker -Value (Get-Date -Format 's') -Force

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arg = "-NoProfile -ExecutionPolicy Bypass -File `"$localLauncher`" -DurationMinutes $DurationMinutes"
$action = New-ScheduledTaskAction -Execute $psExe -Argument $arg
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Compatibility Win8

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Force | Out-Null

Write-Host "Scheduled Task: $taskName"
Write-Host "Local launcher: $localLauncher"
Write-Host "Install root saved as: $installRootNormalized"
