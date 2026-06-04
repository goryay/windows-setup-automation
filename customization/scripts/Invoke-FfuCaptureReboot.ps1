<#
.SYNOPSIS
    Triggers FFU capture by rebooting into LOCALLY-STAGED WinPE.

    Workflow:
      1. Validate IpdromREC partition is ready (boot.wim + EFI bootloader present)
      2. Write .capture_pending marker on IpdromREC
      3. Write stress-test-completed flag so launcher doesn't re-run after return
      4. Read GUID of local WinPE BCD entry from C:\WinPE\capture_entry_guid.txt
         (created by Prepare-IpdromRecFlash.ps1)
      5. Set one-time {bootmgr} bootsequence to that GUID
      6. Restart-Computer

    On reboot: Windows bootmgr loads (no USB picking), sees bootsequence,
    ramdisk-boots WinPE from C:\WinPE\boot.wim. WinPE captures FFU to IpdromREC
    USB, cleans up C:\WinPE\ and BCD entry, reboots. Default boot order
    returns to regular Windows. Launcher sees Completed flag and exits.

    This approach works even when Ventoy/other USBs are plugged in - because
    boot decision is made by Windows bootmgr on system disk, not by BIOS.

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

# ===================== LOCATE LOCAL CAPTURE BCD ENTRY =====================
# Prepare-IpdromRecFlash стейджит C:\WinPE\boot.wim + создаёт СКРЫТЫЙ osloader entry
# в локальной BCD. Мы тут ставим {bootmgr} bootsequence на этот GUID -
# одноразовый next-boot. Windows bootmgr грузится с системного диска (как обычно),
# видит bootsequence, ramdisk-bootит наш WinPE c C:\WinPE\boot.wim.
# Никаких USB-выборов BIOS - Ventoy/прочие removable не влияют вообще.
$capGuidPath = Join-Path $env:SystemDrive 'WinPE\capture_entry_guid.txt'
if (-not (Test-Path $capGuidPath)) {
    Write-Log "Local WinPE not staged: $capGuidPath not found." 'Red'
    Write-Log "Run Prepare-IpdromRecFlash.ps1 first - it stages the local capture entry." 'Yellow'
    exit 9
}
$capGuid = (Get-Content -LiteralPath $capGuidPath -Raw).Trim()
Write-Log "Local capture BCD entry GUID: $capGuid" 'Gray'

# Verify entry still exists in BCD
$verify = bcdedit /enum $capGuid 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Log "BCD entry $capGuid no longer exists - re-run Prepare-IpdromRecFlash.ps1." 'Red'
    foreach ($l in $verify) { Write-Log "  | $l" 'DarkGray' }
    exit 10
}

# ===================== SET BOOTSEQUENCE =====================
# {bootmgr} bootsequence - one-time next-boot. Consumed by bootmgr, NOT persisted.
# After WinPE capture reboots back -> next boot uses {default} (regular Windows).
Write-Log "Setting one-time {bootmgr} bootsequence to local WinPE entry..." 'Yellow'
$bcdSetOut = bcdedit /set '{bootmgr}' bootsequence $capGuid 2>&1
foreach ($l in ($bcdSetOut -split "`r?`n")) { if ($l.Trim()) { Write-Log "  | $l" 'DarkGray' } }

if ($LASTEXITCODE -ne 0) {
    Write-Log "bcdedit bootsequence failed (exit $LASTEXITCODE)." 'Red'
    Write-Log "Markers KEPT - boot the IpdromREC flash manually via F11 to run capture." 'Yellow'
    exit 11
}

Write-Log "bootsequence armed. Next reboot -> local WinPE -> capture FFU to IpdromREC." 'Green'

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
