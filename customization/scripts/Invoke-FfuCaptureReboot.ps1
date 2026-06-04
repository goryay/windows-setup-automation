<#
.SYNOPSIS
    Triggers FFU capture by rebooting into the IpdromREC WinPE flash.

    Workflow:
      1. Validate IpdromREC partition is ready (boot.wim + EFI bootloader present)
      2. Write .capture_pending marker on IpdromREC
      3. Write stress-test-completed flag so launcher doesn't re-run after return
      4. Find UEFI firmware boot entry pointing at the IpdromREC USB
      5. Set one-time BootNext via bcdedit
      6. Restart-Computer

    After capture, WinPE startnet removes .capture_pending and reboots. Default
    boot order returns the system to Windows. Launcher sees the completed flag
    and exits cleanly.

.PARAMETER FlashLabel
    Volume label of the recovery flash data partition. Default 'IpdromREC'.

.PARAMETER WinreLabel
    Volume label of the recovery flash bootable partition. Default 'WINRE'.

.PARAMETER NoReboot
    Do all preparation but DON'T trigger reboot. For dry-run / testing.

.PARAMETER LogPath
    Where to write the operation log.
#>
[CmdletBinding()]
param(
    [string]$FlashLabel = 'IpdromREC',
    [string]$WinreLabel = 'WINRE',
    [switch]$NoReboot,
    [switch]$Force,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

# ===================== LOG =====================
if (-not $LogPath) {
    $logDir  = Join-Path $env:ProgramData 'IPDROM\Logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $LogPath = Join-Path $logDir ("ffu_trigger_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}

function Write-Log {
    param([string]$Msg, [string]$Color = 'White')
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
    Write-Host $Msg -ForegroundColor $Color
    try { $line | Out-File -FilePath $LogPath -Encoding utf8 -Append } catch {}
}

Write-Log "=== Invoke-FfuCaptureReboot started ===" 'Cyan'
Write-Log "FlashLabel:  $FlashLabel"
Write-Log "WinreLabel:  $WinreLabel"
Write-Log "NoReboot:    $NoReboot"
Write-Log "Log:         $LogPath" 'Gray'

# ===================== UEFI / ADMIN CHECKS =====================
if ($env:firmware_type -ne 'Uefi') {
    Write-Log "System is NOT booted in UEFI mode (firmware_type='$env:firmware_type')." 'Red'
    Write-Log "BootNext-driven auto-capture requires UEFI. Aborting." 'Red'
    exit 2
}

$me = [Security.Principal.WindowsIdentity]::GetCurrent()
$wp = [Security.Principal.WindowsPrincipal]::new($me)
if (-not $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "Not running as administrator. bcdedit will fail. Aborting." 'Red'
    exit 3
}

# ===================== FIND IpdromREC / WINRE PARTITIONS =====================
$ipdromVol = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.FileSystemLabel -ieq $FlashLabel -and $_.DriveLetter } | Select-Object -First 1
$winreVol  = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.FileSystemLabel -ieq $WinreLabel -and $_.DriveLetter } | Select-Object -First 1

if (-not $ipdromVol) {
    Write-Log "Volume '$FlashLabel' not found. Run Prepare-IpdromRecFlash.ps1 first." 'Red'
    exit 4
}
if (-not $winreVol) {
    Write-Log "Volume '$WinreLabel' not found. Run Prepare-IpdromRecFlash.ps1 first." 'Red'
    exit 5
}

$ipdromRoot = "$($ipdromVol.DriveLetter):"
$winreRoot  = "$($winreVol.DriveLetter):"
Write-Log "IpdromREC: $ipdromRoot" 'Green'
Write-Log "WINRE:     $winreRoot"  'Green'

# Both partitions should be on the SAME physical disk (same flash)
$ipdromDiskNum = (Get-Partition -DriveLetter $ipdromVol.DriveLetter -ErrorAction SilentlyContinue).DiskNumber
$winreDiskNum  = (Get-Partition -DriveLetter $winreVol.DriveLetter  -ErrorAction SilentlyContinue).DiskNumber
if ($ipdromDiskNum -ne $winreDiskNum) {
    Write-Log "WINRE and IpdromREC are on different physical disks ($winreDiskNum vs $ipdromDiskNum). Aborting." 'Red'
    exit 6
}
$flashDisk = Get-Disk -Number $ipdromDiskNum
Write-Log "Flash disk: '$($flashDisk.FriendlyName)' (Disk $($flashDisk.Number))" 'Gray'

# ===================== VALIDATE BOOT.WIM AND EFI BOOTLOADER =====================
$bootWim    = Join-Path $winreRoot 'sources\boot.wim'
$efiLoader  = Join-Path $winreRoot 'EFI\Boot\bootx64.efi'

if (-not (Test-Path $bootWim)) {
    Write-Log "boot.wim missing at $bootWim. Flash not ready." 'Red'
    exit 7
}
if (-not (Test-Path $efiLoader)) {
    Write-Log "EFI bootloader missing at $efiLoader. Flash not ready." 'Red'
    exit 8
}
Write-Log "Flash validation OK: boot.wim and EFI bootloader present." 'Green'

# ===================== WRITE MARKERS =====================
$markerPending = Join-Path $ipdromRoot '.capture_pending'
$markerDone    = Join-Path $ipdromRoot '.capture_done'
$markerFailed  = Join-Path $ipdromRoot '.capture_failed'

# Clear stale completion markers from prior runs
foreach ($m in @($markerDone, $markerFailed)) {
    if (Test-Path $m) { Remove-Item -LiteralPath $m -Force; Write-Log "Removed stale marker: $(Split-Path $m -Leaf)" 'Gray' }
}

# Compose pending marker content (WinPE startnet reads these env-style vars)
$sysDriveLetter = $env:SystemDrive.TrimEnd(':')
$sysDiskNumber  = (Get-Partition -DriveLetter $sysDriveLetter -ErrorAction SilentlyContinue).DiskNumber
$markerContent = @"
SystemDisk=$sysDiskNumber
ComputerName=$env:COMPUTERNAME
TriggeredAt=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@
Set-Content -LiteralPath $markerPending -Value $markerContent -Encoding ASCII
Write-Log "Wrote $markerPending" 'Green'
Write-Log "  SystemDisk=$sysDiskNumber, ComputerName=$env:COMPUTERNAME" 'Gray'

# ===================== WRITE STRESS-COMPLETED FLAG =====================
# This prevents the launcher (launch_auto_stress_after_reboot.ps1) from
# re-running the entire stress test after the WinPE capture reboots back.
$stressFlag = Join-Path $env:ProgramData 'IPDROM_StressTest_Completed.flag'
if (-not (Test-Path $stressFlag)) {
    Set-Content -LiteralPath $stressFlag -Value "Completed at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`nFFU capture triggered." -Encoding utf8
    Write-Log "Wrote $stressFlag (launcher will exit cleanly on next boot)." 'Green'
} else {
    Write-Log "Stress flag already present - launcher will exit on next boot." 'Gray'
}

# ===================== FIND UEFI BOOT ENTRY FOR THIS USB =====================
Write-Log "Enumerating UEFI firmware boot entries..." 'Yellow'

$bcdRaw = bcdedit /enum firmware 2>&1
$bcdText = ($bcdRaw -join "`r`n")

# bcdedit output is block-separated by blank lines. Parse each block.
# We match by `device partition=<letter>:` where <letter> is OUR WINRE drive letter -
# this is a direct physical mapping, robust regardless of what BIOS put in description.
# Prepare-IpdromRecFlash.ps1 guarantees that a firmware entry for this partition exists
# (creates one via bcdedit /create if bcdboot didn't).
$blocks       = $bcdText -split "(?ms)\r?\n\r?\n"
$candidates   = @()
$winreLetter  = $winreVol.DriveLetter.ToString().ToUpper()
$ipdromLetter = $ipdromVol.DriveLetter.ToString().ToUpper()

foreach ($block in $blocks) {
    # Locale-independent: first GUID in the block IS the identifier
    # (bcdedit always puts identifier as the first field, regardless of language)
    if ($block -notmatch '(\{[a-f0-9-]+\})') { continue }
    $id = $matches[1]
    if ($id -ieq '{bootmgr}' -or $id -ieq '{fwbootmgr}') { continue }

    # "description" remains English in all locales (informational only - not used for matching)
    $desc = ''
    if ($block -match '(?im)^\s*description\s+(.+?)\s*$') { $desc = $matches[1].Trim() }

    # Extract partition letter from "device partition=<letter>:"
    $partLetter = $null
    if ($block -match '(?im)^\s*device\s+partition=([A-Z]):') {
        $partLetter = $matches[1].ToUpper()
    }
    if (-not $partLetter) { continue }

    # Accept entries pointing at our WINRE partition (where bootmgr lives)
    # OR at IpdromREC (some BIOSes register entries on the data partition too).
    if ($partLetter -eq $winreLetter -or $partLetter -eq $ipdromLetter) {
        # Prefer WINRE letter (= partition with actual bootloader)
        $priority = if ($partLetter -eq $winreLetter) { 1 } else { 2 }
        $candidates += [pscustomobject]@{
            Id              = $id
            Description     = $desc
            PartitionLetter = $partLetter
            Priority        = $priority
        }
        Write-Log "  candidate: $id  '$desc'  (partition=${partLetter}:, priority=$priority)" 'Gray'
    }
}

# Prefer WINRE partition (priority=1) over IpdromREC data partition (priority=2)
$candidates = @($candidates | Sort-Object Priority)

if ($candidates.Count -eq 0) {
    Write-Log "No UEFI entry matching IpdromREC by partition letter." 'Yellow'

    # SAFETY: generic "UEFI:Removable Device" грузит ПЕРВОЕ попавшееся USB.
    # В проде (одна флешка - IpdromREC) это OK. На стенде с Ventoy/чужой флешкой
    # BIOS может выбрать НЕ нашу и BootNext улетит мимо -> auto-capture не запустится,
    # винда вернётся, лаунчер увидит StressTest_Completed.flag и тихо выйдет.
    # Поэтому если есть другие removable USB - отказываемся (или -Force).
    $otherUsbDisks = @(Get-Disk -ErrorAction SilentlyContinue | Where-Object {
        $_.BusType -eq 'USB' -and $_.Number -ne $flashDisk.Number -and -not $_.IsBoot -and -not $_.IsSystem
    })
    if ($otherUsbDisks.Count -gt 0 -and -not $Force) {
        Write-Log "Other USB sticks detected in system - generic 'UEFI:Removable Device' fallback is UNSAFE:" 'Red'
        foreach ($u in $otherUsbDisks) {
            Write-Log ("  - Disk {0}: '{1}' ({2} GB)" -f $u.Number, $u.FriendlyName, [math]::Round($u.Size/1GB,1)) 'Red'
        }
        Write-Log "BIOS may boot one of these instead of IpdromREC." 'Red'
        Write-Log "Unplug other USB sticks (Ventoy, etc) and rerun, OR pass -Force to ignore." 'Yellow'
        Write-Log "Markers KEPT - boot IpdromREC flash manually via F11 if needed." 'Yellow'
        exit 11
    }

    # FALLBACK: одна removable в системе -> generic-entry однозначно её и загрузит.
    $genericId = $null
    foreach ($block in $blocks) {
        if ($block -notmatch '(\{[a-f0-9-]+\})') { continue }
        $gid = $matches[1]
        if ($gid -ieq '{bootmgr}' -or $gid -ieq '{fwbootmgr}') { continue }
        if ($block -match '(?im)^\s*description\s+UEFI:\s*Removable\s+Device') { $genericId = $gid; break }
    }
    if ($genericId) {
        if ($otherUsbDisks.Count -gt 0) {
            Write-Log "Fallback to generic 'UEFI:Removable Device' DESPITE other USB present (-Force)." 'Yellow'
        } else {
            Write-Log "Fallback to generic 'UEFI:Removable Device' entry: $genericId" 'Yellow'
            Write-Log "(IpdromREC is the only removable USB - BIOS will boot it.)" 'Gray'
        }
        $chosen = [pscustomobject]@{ Id = $genericId; Description = 'UEFI:Removable Device (generic fallback)' }
    } else {
        Write-Log "No matching entry and no generic Removable Device entry found." 'Red'
        Write-Log "Cannot set BootNext automatically on this BIOS." 'Red'
        Write-Log "Markers KEPT - boot the IpdromREC flash manually via F11 to run capture." 'Yellow'
        exit 9
    }
} else {
    if ($candidates.Count -gt 1) {
        Write-Log "Multiple USB entries found. Picking first one - review log if wrong." 'Yellow'
    }
    $chosen = $candidates[0]
}
Write-Log "Selected UEFI entry: $($chosen.Id)  '$($chosen.Description)'" 'Cyan'

# ===================== SET BOOTNEXT =====================
Write-Log "Setting one-time BootNext..." 'Yellow'
$bcdSetOut = bcdedit /set "{fwbootmgr}" bootsequence $chosen.Id 2>&1
foreach ($l in ($bcdSetOut -split "`r?`n")) { if ($l.Trim()) { Write-Log "  | $l" 'DarkGray' } }

if ($LASTEXITCODE -ne 0) {
    Write-Log "bcdedit BootNext failed (exit $LASTEXITCODE)." 'Red'
    Write-Log "Markers KEPT - boot the IpdromREC flash manually via F11 to run capture." 'Yellow'
    # НЕ удаляем маркеры: ручной F11-capture должен сработать.
    exit 10
}

Write-Log "BootNext armed. On next reboot, system will boot into IpdromREC WinPE." 'Green'

# ===================== REBOOT =====================
if ($NoReboot) {
    Write-Log "NoReboot flag set - preparation complete, NOT rebooting." 'Yellow'
    Write-Log "To execute capture manually: shutdown /r /t 0" 'Gray'
    exit 0
}

Write-Log "Rebooting in 10 seconds. Capture will run automatically in WinPE." 'Cyan'
Write-Log "After capture completes, system will reboot back to Windows." 'Cyan'
Start-Sleep -Seconds 10
Restart-Computer -Force
exit 0
