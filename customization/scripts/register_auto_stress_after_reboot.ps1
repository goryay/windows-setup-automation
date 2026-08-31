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

# Persist auto-logon across ALL pipeline reboots. The continuation task above is
# AtLogon and needs an interactive desktop, but the unattend arms auto-logon only
# once (LogonCount=1) and FirstLogon sets AutoLogonCount=0 - so every reboot after
# the first stopped at the sign-in screen and the operator had to log in by hand.
# Arm a perpetual auto-logon for the local IPDROM account (blank password; console
# logon is permitted even under the Server blank-password policy). This runs after
# FirstLogon's AutoLogonCount=0, so it wins. launch_auto_stress_after_reboot.ps1
# disarms it on stress-test success, so the delivered machine still boots to a
# normal sign-in screen.
try {
    $winlogon = 'Registry::HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -LiteralPath $winlogon -Name 'AutoAdminLogon'    -Value '1'               -Type String -Force
    Set-ItemProperty -LiteralPath $winlogon -Name 'DefaultUserName'   -Value 'Admin'           -Type String -Force
    Set-ItemProperty -LiteralPath $winlogon -Name 'DefaultDomainName' -Value $env:COMPUTERNAME -Type String -Force
    Set-ItemProperty -LiteralPath $winlogon -Name 'DefaultPassword'   -Value ''                -Type String -Force
    Remove-ItemProperty -LiteralPath $winlogon -Name 'AutoLogonCount' -Force -ErrorAction SilentlyContinue
    Write-Host "Perpetual auto-logon armed for IPDROM (disarmed on stress-test success)."
} catch {
    Write-Host "WARNING: failed to arm perpetual auto-logon: $($_.Exception.Message)"
}

Write-Host "Scheduled Task: $taskName"
Write-Host "Local launcher: $localLauncher"
Write-Host "Install root saved as: $installRootNormalized"
Write-Host "Registered boot time: $($currentBootTime.ToString('o'))"
