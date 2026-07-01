param(
    [Parameter(Mandatory = $true)]
    [string]$InstallRoot,
    [int]$DurationMinutes = 30
)

$ErrorActionPreference = 'Stop'

$programDataRoot = Join-Path $env:ProgramData 'IPDROM'
$scriptsDir       = Join-Path $programDataRoot 'Scripts'
$stateDir         = Join-Path $programDataRoot 'State'
$logDir           = Join-Path $programDataRoot 'Logs'
$taskName         = 'IPDROM_AutoStressTest_AfterReboot'

New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
New-Item -ItemType Directory -Path $stateDir   -Force | Out-Null
New-Item -ItemType Directory -Path $logDir     -Force | Out-Null

$sourceLauncher = Join-Path $InstallRoot 'customization\scripts\launch_auto_stress_after_reboot.ps1'
if (-not (Test-Path -LiteralPath $sourceLauncher)) {
    throw "Launcher not found on installation media: $sourceLauncher"
}

$localLauncher = Join-Path $scriptsDir 'launch_auto_stress_after_reboot.ps1'
Copy-Item -LiteralPath $sourceLauncher -Destination $localLauncher -Force

function Resolve-SubstAlias {
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.Length -lt 2 -or $full.Substring(1,1) -ne ':') { return $full }
    $letter = $full.Substring(0,2)
    $rest   = $full.Substring(2).TrimStart('\')
    foreach ($line in (& subst 2>$null)) {
        if ($line -match ('^' + [Regex]::Escape($letter) + '\\?: => (.+)$')) {
            $target = $matches[1].TrimEnd('\')
            if ($rest) { return (Join-Path $target $rest) } else { return ($target + '\') }
        }
    }
    return $full
}

$installRootNormalized = Resolve-SubstAlias -Path $InstallRoot
$installRootNormalized | Out-File -FilePath (Join-Path $stateDir 'InstallRoot.txt') -Encoding ascii -Force

$currentBootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$currentBootTime.ToString('o') | Out-File -FilePath (Join-Path $stateDir 'RegisteredBootTime.txt') -Encoding ascii -Force
(Get-Date).ToString('o')      | Out-File -FilePath (Join-Path $stateDir 'PendingAfterReboot.txt') -Encoding ascii -Force
(Get-Date).ToString('o')      | Out-File -FilePath (Join-Path $programDataRoot 'BeforeStressTestReboot.done') -Encoding ascii -Force

Remove-Item -LiteralPath (Join-Path $stateDir 'StressStarted.lock') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $stateDir 'StressFailed.txt')   -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $stateDir 'StressFinished.txt') -Force -ErrorAction SilentlyContinue

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arg = "-NoProfile -ExecutionPolicy Bypass -File `"$localLauncher`" -DurationMinutes $DurationMinutes"
$action = New-ScheduledTaskAction -Execute $psExe -Argument $arg
$trigger = New-ScheduledTaskTrigger -AtLogOn

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -Compatibility Win8 `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -RunLevel Highest `
    -Force | Out-Null

Write-Host "Scheduled Task: $taskName"
Write-Host "Local launcher: $localLauncher"
Write-Host "Install root saved as: $installRootNormalized"
Write-Host "Registered boot time: $($currentBootTime.ToString('o'))"
