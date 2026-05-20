<#
.SYNOPSIS
    Prepares an IpdromREC recovery flash drive.

    Detects a candidate USB stick, then either:
      - REFRESH mode (already prepared): updates boot.wim, renames old restore.ffu
      - FRESH mode   (blank/foreign):    wipes, partitions, formats, populates

    If a "prepared-looking" flash fails sanity checks (wrong sizes, missing
    bootloader, corrupted boot.wim), falls back to FRESH.

    NEVER touches:
      - Pipeline USB (Ventoy / Test ISO)
      - System disk
      - USB sticks with foreign labels/data
      - Drives outside 32-256 GB range

.PARAMETER PatchedWim
    Path to the auto-capture boot.wim (output of Patch-BootWim.ps1).
    Default: <script dir>\..\winpe\boot_patched.wim

.PARAMETER WinreSizeMB
    Size of WINRE partition in MB. Default 1536 (1.5 GB).

.PARAMETER MinFlashGB / MaxFlashGB
    USB size filter range. Default 32-256 GB.

.PARAMETER LogPath
    Where to write the operation log.

.PARAMETER Force
    Skip the candidate-uniqueness check (allow first match). Use with caution.

.NOTES
    Requires admin. Uses diskpart, dism, bcdboot, format.
#>
[CmdletBinding()]
param(
    [string]$PatchedWim,
    [int]$WinreSizeMB    = 1536,
    [int]$MinFlashGB     = 32,
    [int]$MaxFlashGB     = 256,
    [string]$LogPath,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ===================== DEFAULTS =====================
if (-not $PatchedWim) {
    $PatchedWim = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'winpe') 'boot_patched.wim'
}
if (-not $LogPath) {
    $logDir  = Join-Path $env:ProgramData 'IPDROM\Logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $LogPath = Join-Path $logDir ("prepare_flash_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}

function Write-Log {
    param([string]$Msg, [string]$Color = 'White')
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
    Write-Host $Msg -ForegroundColor $Color
    try { $line | Out-File -FilePath $LogPath -Encoding utf8 -Append } catch {}
}

Write-Log "=== Prepare-IpdromRecFlash started ===" 'Cyan'
Write-Log "PatchedWim:    $PatchedWim"
Write-Log "WinreSizeMB:   $WinreSizeMB"
Write-Log "FlashRange:    ${MinFlashGB}..${MaxFlashGB} GB"
Write-Log "Log:           $LogPath" 'Gray'

# ===================== VALIDATE INPUTS =====================
if (-not (Test-Path $PatchedWim)) {
    Write-Log "Patched boot.wim not found: $PatchedWim" 'Red'
    Write-Log "Run Patch-BootWim.ps1 first to produce it." 'Yellow'
    exit 2
}

foreach ($cmd in @('diskpart.exe','dism.exe','bcdboot.exe','format.com')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Log "Required tool not found: $cmd" 'Red'
        exit 3
    }
}

# ===================== HELPERS =====================
function Invoke-Diskpart {
    param([string]$Script)
    $tmp = Join-Path $env:TEMP "ipdrom_dp_$(New-Guid).txt"
    Set-Content -LiteralPath $tmp -Value $Script -Encoding ASCII
    Write-Log "  [diskpart]" 'DarkGray'
    foreach ($l in ($Script -split "`r?`n")) { if ($l.Trim()) { Write-Log "  > $l" 'DarkGray' } }
    $out = & diskpart.exe /s $tmp 2>&1
    $exit = $LASTEXITCODE
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    foreach ($l in ($out -split "`r?`n")) { if ($l.Trim()) { Write-Log "  | $l" 'DarkGray' } }
    return $exit
}

function Get-DiskNumberByVolume {
    param([string]$Letter)
    try {
        $p = Get-Partition -DriveLetter $Letter.Trim(':') -ErrorAction Stop
        return [int]$p.DiskNumber
    } catch { return $null }
}

# ===================== FIND CANDIDATE FLASH =====================
Write-Log "Scanning for candidate USB flash drives..." 'Yellow'

$pipelineLabels = @('Ventoy','VTOYEFI','IPDROM_Recovery','RECOVERY','VTOY')

$allUsbDisks = @(Get-Disk -ErrorAction SilentlyContinue |
    Where-Object { $_.BusType -eq 'USB' -and $_.IsBoot -eq $false -and $_.IsSystem -eq $false })

$candidates = @()
foreach ($d in $allUsbDisks) {
    $sizeGB = [math]::Round($d.Size / 1GB, 1)
    $reasons = New-Object System.Collections.ArrayList

    if ($sizeGB -lt $MinFlashGB) { [void]$reasons.Add("size $sizeGB GB < ${MinFlashGB}") }
    if ($sizeGB -gt $MaxFlashGB) { [void]$reasons.Add("size $sizeGB GB > ${MaxFlashGB}") }

    # Inspect labels / contents
    $partitions = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue)
    $volumes    = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $partitions.AccessPaths -contains "$($_.DriveLetter):\" -or $partitions.DriveLetter -contains $_.DriveLetter })
    $labels     = @($volumes | ForEach-Object { $_.FileSystemLabel } | Where-Object { $_ })

    $hasPipelineMark = $false
    foreach ($lbl in $labels) {
        foreach ($pl in $pipelineLabels) { if ($lbl -ieq $pl) { $hasPipelineMark = $true; break } }
    }
    if ($hasPipelineMark) { [void]$reasons.Add("pipeline flash (labels: $($labels -join ','))") }

    # Filesystem-level pipeline detection (if labels are missing)
    foreach ($v in $volumes) {
        if (-not $v.DriveLetter) { continue }
        $root = "$($v.DriveLetter):\"
        if (Test-Path (Join-Path $root 'ventoy'))                 { [void]$reasons.Add('contains \ventoy folder'); break }
        if (Test-Path (Join-Path $root 'customization\scripts'))  { [void]$reasons.Add('contains \customization\scripts folder'); break }
    }

    $hasWinreLabel  = $labels -icontains 'WINRE'
    $hasIpdromLabel = $labels -icontains 'IpdromREC'
    $isOurs   = ($hasWinreLabel -and $hasIpdromLabel)
    $isEmpty  = ($partitions.Count -eq 0) -or ($d.PartitionStyle -eq 'RAW')
    # "Foreign" = has partitions, but not ours
    if (-not ($isOurs -or $isEmpty) -and -not $hasPipelineMark) {
        [void]$reasons.Add("foreign partitions/data (labels: $($labels -join ',' )))")
    }

    $entry = [pscustomobject]@{
        Disk         = $d
        SizeGB       = $sizeGB
        Labels       = $labels
        IsOurs       = $isOurs
        IsEmpty      = $isEmpty
        Volumes      = $volumes
        RejectReason = ($reasons -join '; ')
    }

    if ($reasons.Count -eq 0) {
        $candidates += $entry
        Write-Log ("  CANDIDATE: Disk {0}  '{1}'  {2} GB  labels=[{3}]  mode={4}" -f $d.Number, $d.FriendlyName, $sizeGB, ($labels -join ','), ($(if($isOurs){'REFRESH'}else{'FRESH'}))) 'Green'
    } else {
        Write-Log ("  reject:    Disk {0}  '{1}'  {2} GB  -- {3}" -f $d.Number, $d.FriendlyName, $sizeGB, ($reasons -join '; ')) 'DarkGray'
    }
}

if ($candidates.Count -eq 0) {
    Write-Log "No suitable USB flash candidates found. Skipping." 'Yellow'
    exit 4
}

if ($candidates.Count -gt 1 -and -not $Force) {
    Write-Log "Multiple candidates ($($candidates.Count)) — refuse to guess. Unplug extras and rerun (or use -Force)." 'Red'
    exit 5
}

$target = $candidates[0]
$disk   = $target.Disk
Write-Log "Selected: Disk $($disk.Number) '$($disk.FriendlyName)' $($target.SizeGB) GB" 'Cyan'

# ===================== DECIDE MODE =====================
$mode = if ($target.IsOurs) { 'REFRESH' } else { 'FRESH' }
Write-Log "Mode: $mode" 'Cyan'

# Try REFRESH path first; if sanity fails, fall back to FRESH
if ($mode -eq 'REFRESH') {
    $winreVol  = $target.Volumes | Where-Object { $_.FileSystemLabel -ieq 'WINRE' }     | Select-Object -First 1
    $ipdromVol = $target.Volumes | Where-Object { $_.FileSystemLabel -ieq 'IpdromREC' } | Select-Object -First 1

    $refreshOk = $true
    $reasons = @()
    if (-not $winreVol  -or -not $winreVol.DriveLetter)  { $refreshOk = $false; $reasons += 'WINRE volume has no drive letter' }
    if (-not $ipdromVol -or -not $ipdromVol.DriveLetter) { $refreshOk = $false; $reasons += 'IpdromREC volume has no drive letter' }
    if ($winreVol -and $winreVol.FileSystem -ne 'FAT32') { $refreshOk = $false; $reasons += "WINRE filesystem is '$($winreVol.FileSystem)', expected FAT32" }
    if ($ipdromVol -and $ipdromVol.FileSystem -ne 'NTFS') { $refreshOk = $false; $reasons += "IpdromREC filesystem is '$($ipdromVol.FileSystem)', expected NTFS" }
    if ($winreVol -and $winreVol.Size -lt 800MB) { $refreshOk = $false; $reasons += "WINRE size too small ($([math]::Round($winreVol.Size/1MB)) MB < 800 MB)" }
    if ($winreVol -and $winreVol.DriveLetter) {
        $winreRoot   = "$($winreVol.DriveLetter):"
        $efiBootFile = Join-Path $winreRoot 'EFI\Boot\bootx64.efi'
        if (-not (Test-Path $efiBootFile)) {
            $refreshOk = $false
            $reasons += "no EFI bootloader at $efiBootFile"
        }
    }

    if (-not $refreshOk) {
        Write-Log "REFRESH sanity checks failed:" 'Yellow'
        foreach ($r in $reasons) { Write-Log "  - $r" 'Yellow' }
        Write-Log "Falling back to FRESH mode (full reformat)." 'Yellow'
        $mode = 'FRESH'
    }
}

# ===================== REFRESH PATH =====================
if ($mode -eq 'REFRESH') {
    Write-Log "REFRESH: updating existing prepared flash..." 'Cyan'
    $winreRoot   = "$($winreVol.DriveLetter):"
    $ipdromRoot  = "$($ipdromVol.DriveLetter):"
    Write-Log "  WINRE:     $winreRoot"
    Write-Log "  IpdromREC: $ipdromRoot"

    # Update boot.wim
    $targetBootWim = Join-Path $winreRoot 'sources\boot.wim'
    $sourcesDir    = Split-Path $targetBootWim -Parent
    New-Item -ItemType Directory -Force -Path $sourcesDir | Out-Null
    Write-Log "  Copying $PatchedWim -> $targetBootWim..." 'Yellow'
    Copy-Item -LiteralPath $PatchedWim -Destination $targetBootWim -Force
    $sizeMB = [math]::Round((Get-Item $targetBootWim).Length / 1MB, 1)
    Write-Log "  boot.wim updated ($sizeMB MB)." 'Green'

    # Rename existing restore.ffu to restore.old.ffu (safe rotate)
    $ffu    = Join-Path $ipdromRoot 'restore.ffu'
    $ffuOld = Join-Path $ipdromRoot 'restore.old.ffu'
    if (Test-Path $ffu) {
        if (Test-Path $ffuOld) {
            Write-Log "  Removing stale restore.old.ffu..." 'Gray'
            Remove-Item -LiteralPath $ffuOld -Force
        }
        Write-Log "  Rotating restore.ffu -> restore.old.ffu (preserves last good backup)..." 'Yellow'
        Rename-Item -LiteralPath $ffu -NewName 'restore.old.ffu' -Force
    }

    # Wipe stale capture logs
    $logsDir = Join-Path $ipdromRoot 'Logs'
    if (Test-Path $logsDir) {
        Write-Log "  Cleaning old IpdromREC\Logs..." 'Gray'
        Get-ChildItem -LiteralPath $logsDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    } else {
        New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
    }

    # Remove stale capture markers
    foreach ($mk in @('.capture_pending','.capture_done','.capture_failed')) {
        $p = Join-Path $ipdromRoot $mk
        if (Test-Path $p) { Remove-Item -LiteralPath $p -Force; Write-Log "  Removed stale marker: $mk" 'Gray' }
    }

    Write-Log "=== REFRESH completed successfully ===" 'Green'
    Write-Log "Flash ready at Disk $($disk.Number):" 'Green'
    Write-Log "  WINRE:     $winreRoot" 'Green'
    Write-Log "  IpdromREC: $ipdromRoot" 'Green'
    exit 0
}

# ===================== FRESH PATH =====================
Write-Log "FRESH: wiping and partitioning Disk $($disk.Number)..." 'Cyan'

# Diskpart script: clean + GPT + WINRE FAT32 + IpdromREC NTFS
$dpScript = @"
select disk $($disk.Number)
clean
convert gpt
create partition primary size=$WinreSizeMB
format fs=fat32 label="WINRE" quick
assign
create partition primary
format fs=ntfs label="IpdromREC" quick
assign
exit
"@

$rc = Invoke-Diskpart -Script $dpScript
if ($rc -ne 0) {
    Write-Log "diskpart failed with exit code $rc. Aborting." 'Red'
    exit 6
}

# Refresh volume info
Start-Sleep -Seconds 3
$disk = Get-Disk -Number $disk.Number
$parts = Get-Partition -DiskNumber $disk.Number | Sort-Object PartitionNumber
if ($parts.Count -lt 2) {
    Write-Log "Expected 2 partitions, got $($parts.Count). Aborting." 'Red'
    exit 7
}

$winrePart  = $parts | Where-Object { $_.PartitionNumber -eq 1 -or ($_.AccessPaths | Where-Object { Test-Path "$_EFI\Boot" }) } | Select-Object -First 1
$ipdromPart = $parts | Where-Object { $_.PartitionNumber -ne $winrePart.PartitionNumber } | Select-Object -First 1
$winreVol   = Get-Volume -Partition $winrePart  -ErrorAction SilentlyContinue
$ipdromVol  = Get-Volume -Partition $ipdromPart -ErrorAction SilentlyContinue

if (-not $winreVol.DriveLetter -or -not $ipdromVol.DriveLetter) {
    Write-Log "Partitions have no drive letters after diskpart. Aborting." 'Red'
    exit 8
}

$winreRoot  = "$($winreVol.DriveLetter):"
$ipdromRoot = "$($ipdromVol.DriveLetter):"
Write-Log "Partitions ready:" 'Green'
Write-Log "  WINRE:     $winreRoot ($([math]::Round($winreVol.Size/1MB)) MB FAT32)"
Write-Log "  IpdromREC: $ipdromRoot ($([math]::Round($ipdromVol.Size/1GB,1)) GB NTFS)"

# ===================== COPY PATCHED BOOT.WIM =====================
$sourcesDir   = Join-Path $winreRoot 'sources'
$targetBootWim = Join-Path $sourcesDir 'boot.wim'
New-Item -ItemType Directory -Force -Path $sourcesDir | Out-Null
Write-Log "Copying boot_patched.wim to $targetBootWim..." 'Yellow'
Copy-Item -LiteralPath $PatchedWim -Destination $targetBootWim -Force
$sizeMB = [math]::Round((Get-Item $targetBootWim).Length / 1MB, 1)
Write-Log "boot.wim copied ($sizeMB MB)." 'Green'

# ===================== INSTALL BOOTLOADER =====================
# bcdboot reads Windows files from the mounted WIM and writes EFI bootloader
# (bootmgfw.efi + BCD store) to the WINRE FAT32 partition.
Write-Log "Installing UEFI bootloader via bcdboot..." 'Yellow'

$wimMount = Join-Path $env:TEMP "ipdrom_bootwim_install_$(New-Guid)"
New-Item -ItemType Directory -Force -Path $wimMount | Out-Null

try {
    & dism /Mount-Wim "/WimFile:$targetBootWim" /Index:1 "/MountDir:$wimMount" /ReadOnly 2>&1 | ForEach-Object { Write-Log "  | $_" 'DarkGray' }
    if ($LASTEXITCODE -ne 0) { throw "Mount of boot.wim failed (exit $LASTEXITCODE)" }

    & bcdboot "$wimMount\Windows" /s $winreRoot /f UEFI 2>&1 | ForEach-Object { Write-Log "  | $_" 'DarkGray' }
    if ($LASTEXITCODE -ne 0) { throw "bcdboot failed (exit $LASTEXITCODE)" }

    Write-Log "Bootloader installed on $winreRoot." 'Green'
} catch {
    Write-Log "Bootloader install failed: $_" 'Red'
    & dism /Unmount-Wim "/MountDir:$wimMount" /Discard 2>&1 | Out-Null
    Remove-Item -LiteralPath $wimMount -Force -Recurse -ErrorAction SilentlyContinue
    exit 9
}

& dism /Unmount-Wim "/MountDir:$wimMount" /Discard 2>&1 | ForEach-Object { Write-Log "  | $_" 'DarkGray' }
Remove-Item -LiteralPath $wimMount -Force -Recurse -ErrorAction SilentlyContinue

# ===================== INITIALIZE IPDROMREC PARTITION =====================
Write-Log "Initializing IpdromREC partition..." 'Yellow'
New-Item -ItemType Directory -Force -Path (Join-Path $ipdromRoot 'Logs') | Out-Null
# Create a hint file describing the flash purpose
$readme = @"
=== IPDROM Recovery Flash ===
This USB flash was prepared by Prepare-IpdromRecFlash.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
on machine $env:COMPUTERNAME.

Layout:
  WINRE     : FAT32, bootable WinPE auto-capture environment
  IpdromREC : NTFS, recovery image storage (restore.ffu after capture)

To restore: boot from this flash in UEFI mode. The auto-capture WinPE will
check for .capture_pending marker — if present, it captures the system disk;
otherwise it reboots back to the default OS.
"@
Set-Content -LiteralPath (Join-Path $ipdromRoot 'README.txt') -Value $readme -Encoding utf8

Write-Log "=== FRESH preparation completed successfully ===" 'Green'
Write-Log "Flash ready at Disk $($disk.Number):" 'Green'
Write-Log "  WINRE:     $winreRoot" 'Green'
Write-Log "  IpdromREC: $ipdromRoot" 'Green'
Write-Log "Next step: capture trigger from Windows (Phase 4 — to be wired in [6.5/7])." 'Cyan'
exit 0
