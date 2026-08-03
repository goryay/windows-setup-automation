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

function Invoke-LocalWinPEStage {
    # Стейдж локального WinPE для capture-trigger без зависимости от USB-выбора BIOS.
    # Копирует boot.wim+boot.sdi на C:\WinPE\, создаёт СКРЫТЫЙ osloader-entry
    # в локальной BCD (НЕ в displayorder -> не показывается в boot-меню).
    # Invoke-FfuCaptureReboot потом ставит {bootmgr} bootsequence на этот GUID.
    # Cleanup делается WinPE startnet.cmd ДО DISM, поэтому в FFU мусор не попадает.
    param([string]$PatchedWim)

    $sysDrv  = $env:SystemDrive   # "C:"
    $stageDir = Join-Path $sysDrv 'WinPE'

    # --- IDEMPOTENCY: delete previous hidden entry if exists ---
    # If Prepare-IpdromRecFlash is run multiple times, avoid orphaned BCD entries.
    $prevGuidFile = Join-Path $stageDir 'capture_entry_guid.txt'
    if (Test-Path $prevGuidFile) {
        $prevGuid = (Get-Content -LiteralPath $prevGuidFile -Raw).Trim()
        if ($prevGuid) {
            Write-Log "  Deleting previous hidden osloader entry: $prevGuid" 'Gray'
            & bcdedit /delete $prevGuid /f 2>&1 | Out-Null
        }
    }

    New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

    # --- Копируем boot.wim ---
    $stageWim = Join-Path $stageDir 'boot.wim'
    Copy-Item -LiteralPath $PatchedWim -Destination $stageWim -Force
    $wimMB = [math]::Round((Get-Item $stageWim).Length / 1MB, 1)
    Write-Log "  Staged boot.wim -> $stageWim ($wimMB MB)" 'Gray'

    # --- Копируем boot.sdi (из живой OS) ---
    $sdiSrc = @(
        (Join-Path $env:SystemRoot 'Boot\DVD\EFI\boot.sdi'),
        (Join-Path $env:SystemRoot 'Boot\DVD\PCAT\boot.sdi'),
        (Join-Path $env:SystemRoot 'System32\boot.sdi')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $sdiSrc) { throw "boot.sdi not found in any standard location" }
    $stageSdi = Join-Path $stageDir 'boot.sdi'
    Copy-Item -LiteralPath $sdiSrc -Destination $stageSdi -Force
    Write-Log "  Staged boot.sdi -> $stageSdi (from $sdiSrc)" 'Gray'

    # --- Сохраняем ОРИГИНАЛЬНОЕ состояние {ramdiskoptions} ---
    # IDEMPOTENCY: если ramdiskoptions_orig.json уже существует от прошлого запуска,
    # значит мы УЖЕ модифицировали {ramdiskoptions} - не переписываем (иначе сохраним
    # свои значения как "оригинальные" и cleanup восстановит их неправильно).
    $rdoJson = Join-Path $stageDir 'ramdiskoptions_orig.json'
    if (Test-Path $rdoJson) {
        $rdoState = Get-Content -LiteralPath $rdoJson -Raw | ConvertFrom-Json
        Write-Log "  Reusing saved {ramdiskoptions} original state from $rdoJson (existed=$($rdoState.existed))" 'Gray'
    } else {
        $rdoEnum  = bcdedit /enum '{ramdiskoptions}' 2>&1
        $rdoState = [pscustomobject]@{ existed = $false; sdidevice = $null; sdipath = $null }
        if ($LASTEXITCODE -eq 0) {
            foreach ($l in $rdoEnum) {
                if ($l -match '(?i)^\s*ramdisksdidevice\s+(.+)$') { $rdoState.sdidevice = $matches[1].Trim() }
                if ($l -match '(?i)^\s*ramdisksdipath\s+(.+)$')   { $rdoState.sdipath   = $matches[1].Trim() }
            }
            if ($rdoState.sdidevice -or $rdoState.sdipath) { $rdoState.existed = $true }
        }
        $rdoState | ConvertTo-Json | Set-Content -LiteralPath $rdoJson -Encoding utf8 -Force
        Write-Log "  Saved {ramdiskoptions} original state (existed=$($rdoState.existed)) -> $rdoJson" 'Gray'
    }

    # --- Настраиваем {ramdiskoptions} на наш boot.sdi ---
    if (-not $rdoState.existed) {
        & bcdedit /create '{ramdiskoptions}' /d "Ramdisk Options" 2>&1 | Out-Null
    }
    & bcdedit /set '{ramdiskoptions}' ramdisksdidevice "partition=$sysDrv" 2>&1 | Out-Null
    & bcdedit /set '{ramdiskoptions}' ramdisksdipath '\WinPE\boot.sdi' 2>&1 | Out-Null

    # --- Создаём СКРЫТЫЙ osloader entry ---
    $createOut = bcdedit /create /d "IPDROM Capture WinPE" /application osloader 2>&1
    $capGuid = $null
    foreach ($l in $createOut) {
        if ($l -match '(\{[a-f0-9-]+\})') { $capGuid = $matches[1]; break }
    }
    if (-not $capGuid) {
        throw "Failed to create osloader entry. bcdedit output: $($createOut -join '; ')"
    }

    & bcdedit /set $capGuid device     "ramdisk=[$sysDrv]\WinPE\boot.wim,{ramdiskoptions}" 2>&1 | Out-Null
    & bcdedit /set $capGuid osdevice   "ramdisk=[$sysDrv]\WinPE\boot.wim,{ramdiskoptions}" 2>&1 | Out-Null
    & bcdedit /set $capGuid path       '\windows\system32\winload.efi' 2>&1 | Out-Null
    & bcdedit /set $capGuid systemroot '\windows' 2>&1 | Out-Null
    & bcdedit /set $capGuid winpe      yes 2>&1 | Out-Null
    & bcdedit /set $capGuid detecthal  yes 2>&1 | Out-Null

    # ВАЖНО: не добавляем в {bootmgr} /displayorder - чтобы entry был НЕВИДИМ
    # в boot-menu обычного юзера. Вызывается ТОЛЬКО через bootsequence one-shot.

    $capGuidFile = Join-Path $stageDir 'capture_entry_guid.txt'
    Set-Content -LiteralPath $capGuidFile -Value $capGuid -Encoding ASCII -Force
    Write-Log "  Created hidden osloader entry: $capGuid" 'Green'
    Write-Log "  GUID saved -> $capGuidFile" 'Gray'

    # --- Пишем Cleanup-CaptureStaging.ps1 (для WinPE startnet.cmd) ---
    $cleanupPath = Join-Path $stageDir 'Cleanup-CaptureStaging.ps1'
    $cleanupBody = @'
# Cleanup-CaptureStaging.ps1 - runs IN WinPE before DISM /Capture-Ffu.
# Restores system BCD to clean state so captured FFU has no staging artifacts.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SysDrive,  # e.g. "C:" - WinPE-mounted system Windows drive
    [string]$LogPath
)
$ErrorActionPreference = 'Continue'
function L($m) {
    Write-Host $m
    if ($LogPath) { try { "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'),$m | Out-File $LogPath -Append -Encoding utf8 } catch {} }
}

$stageDir   = Join-Path $SysDrive 'WinPE'
$origJson   = Join-Path $stageDir 'ramdiskoptions_orig.json'
$guidFile   = Join-Path $stageDir 'capture_entry_guid.txt'

L "Cleanup-CaptureStaging started. SysDrive=$SysDrive"

# Read state BEFORE deleting staging files
$capGuid = $null
if (Test-Path $guidFile) { $capGuid = (Get-Content -LiteralPath $guidFile -Raw).Trim() }
$rdoOrig = $null
if (Test-Path $origJson) { $rdoOrig = Get-Content -LiteralPath $origJson -Raw | ConvertFrom-Json }

# Find system ESP and mount it (WinPE doesn't auto-assign letter to ESP)
$sysLetter  = $SysDrive.TrimEnd(':')
$sysDiskNum = (Get-Partition -DriveLetter $sysLetter -ErrorAction SilentlyContinue).DiskNumber
if ($null -eq $sysDiskNum) { L "ERROR: cannot resolve disk number for $SysDrive"; exit 1 }
$esp = Get-Disk -Number $sysDiskNum | Get-Partition | Where-Object { $_.Type -eq 'System' } | Select-Object -First 1
if (-not $esp) { L "ERROR: no ESP partition on disk $sysDiskNum"; exit 2 }

if (-not $esp.DriveLetter) {
    # Find a free letter
    $used = (Get-Volume).DriveLetter | Where-Object { $_ }
    $free = 'YZWVUTS'.ToCharArray() | Where-Object { $used -notcontains $_ } | Select-Object -First 1
    if (-not $free) { L "ERROR: no free drive letter for ESP"; exit 3 }
    Add-PartitionAccessPath -DiskNumber $sysDiskNum -PartitionNumber $esp.PartitionNumber -AccessPath "${free}:" -ErrorAction SilentlyContinue
    $esp = Get-Partition -DiskNumber $sysDiskNum -PartitionNumber $esp.PartitionNumber
}
$espLetter = $esp.DriveLetter
$sysBcd    = "${espLetter}:\EFI\Microsoft\Boot\BCD"
if (-not (Test-Path $sysBcd)) { L "ERROR: system BCD not found at $sysBcd"; exit 4 }
L "System BCD: $sysBcd"

# Delete our hidden osloader entry
if ($capGuid) {
    & bcdedit /store $sysBcd /delete $capGuid /f 2>&1 | ForEach-Object { L "  | delete ${capGuid}: $_" }
}

# Restore {ramdiskoptions} to original state
if ($rdoOrig) {
    if ($rdoOrig.existed) {
        if ($rdoOrig.sdidevice) { & bcdedit /store $sysBcd /set '{ramdiskoptions}' ramdisksdidevice $rdoOrig.sdidevice 2>&1 | ForEach-Object { L "  | restore sdidevice: $_" } }
        if ($rdoOrig.sdipath)   { & bcdedit /store $sysBcd /set '{ramdiskoptions}' ramdisksdipath   $rdoOrig.sdipath   2>&1 | ForEach-Object { L "  | restore sdipath: $_"   } }
    } else {
        # We created {ramdiskoptions} - delete it
        & bcdedit /store $sysBcd /delete '{ramdiskoptions}' /f 2>&1 | ForEach-Object { L "  | delete ramdiskoptions: $_" }
    }
}

# Wipe staging dir from system disk so it isn't in the captured FFU
Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
L "Removed staging dir: $stageDir"
L "Cleanup-CaptureStaging completed."
exit 0
'@
    Set-Content -LiteralPath $cleanupPath -Value $cleanupBody -Encoding utf8 -Force
    Write-Log "  Wrote $cleanupPath" 'Gray'

    Write-Log "Local WinPE staged: bootsequence-ready, will be picked at next reboot." 'Green'
}

# ===================== FIND CANDIDATE FLASH =====================
Write-Log "Scanning for candidate USB flash drives..." 'Yellow'

$pipelineLabels = @('Ventoy','VTOYEFI','IPDROM_Recovery','RECOVERY','VTOY','IPDROM')

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

    # Trim to handle padded FAT32 labels (stored right-padded with spaces).
    $labelsTrimmed  = @($labels | ForEach-Object { $_.Trim() })
    $hasWinreLabel  = $labelsTrimmed -icontains 'WINRE'
    $hasIpdromLabel = $labelsTrimmed -icontains 'IpdromREC'
    # Historically required BOTH labels. But `format.com /V:X` sometimes fails to
    # set the label on FAT32 quick format, leaving one partition unlabeled. If we
    # required both, we'd reject a partial state as "foreign" and never recover.
    # Accept EITHER label as ours - it's clearly not user data since our labels
    # aren't used by anything else, and worst case we FRESH-reformat.
    $isOurs   = ($hasWinreLabel -or $hasIpdromLabel)
    $isEmpty  = ($partitions.Count -eq 0) -or ($d.PartitionStyle -eq 'RAW')
    # Recyclable = disk has partitions but ALL labels are empty AND no user-recognizable
    # files (no filesystem-level pipeline markers). This covers the case where a previous
    # install.bat or Prepare-IpdromRecFlash FRESH run partially succeeded and left the
    # flash in a half-formatted state (e.g. WINRE partition created RAW, format failed,
    # IpdromREC never created). Since there are no labels and no visible files, we can
    # safely wipe and retry — no user data is at risk.
    $anyLabel = ($labels.Count -gt 0)
    $isRecyclable = ($partitions.Count -gt 0) -and (-not $anyLabel) -and (-not $hasPipelineMark)
    # "Foreign" = has partitions with unrecognized labels, but not ours
    if (-not ($isOurs -or $isEmpty -or $isRecyclable) -and -not $hasPipelineMark) {
        [void]$reasons.Add("foreign partitions/data (labels: $($labels -join ',' )))")
    }
    if ($isRecyclable) {
        Write-Log ("  note:      Disk {0} has {1} unlabeled partition(s) — treating as recyclable (previous half-format)." -f $d.Number, $partitions.Count) 'DarkYellow'
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
    Write-Log "Multiple candidates ($($candidates.Count)) - refuse to guess. Unplug extras and rerun (or use -Force)." 'Red'
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

    Write-Log "Re-staging local WinPE for capture trigger..." 'Yellow'
    Invoke-LocalWinPEStage -PatchedWim $PatchedWim

    Write-Log "=== REFRESH completed successfully ===" 'Green'
    Write-Log "Flash ready at Disk $($disk.Number):" 'Green'
    Write-Log "  WINRE:     $winreRoot" 'Green'
    Write-Log "  IpdromREC: $ipdromRoot" 'Green'
    exit 0
}

# ===================== FRESH PATH =====================
Write-Log "FRESH: wiping and partitioning Disk $($disk.Number)..." 'Cyan'

# When prepare_flash runs in the automated pipeline (after Intellect install +
# 30-min stress test + cleanup), Windows Volume Manager gets into a state where
# freshly-formatted FAT32 partitions on removable USB don't get MSFT_Volume
# registration. bcdboot and bcdedit then fail with "Cannot create system store"
# or "Element not found". Force-restart Virtual Disk Service (vds) to clear
# stale state. This is what "reboot before flash prep" would do at the WMI
# layer without the cost of an actual reboot.
Write-Log "Restarting Virtual Disk Service (vds) to clear stale WMI state before partitioning..." 'Gray'
try {
    Restart-Service -Name vds -Force -ErrorAction Stop
    Start-Sleep -Seconds 5
    # Trigger a Get-Volume enumeration to warm up the WMI cache after restart.
    Get-Volume -ErrorAction SilentlyContinue | Out-Null
    Write-Log "  vds restarted, WMI cache warmed." 'Gray'
} catch {
    Write-Log "  vds restart failed (non-fatal): $($_.Exception.Message)" 'Yellow'
}

# Diskpart script: clean + GPT + WINRE (FAT32, basic data) + IpdromREC (NTFS).
# Раздел НЕ помечается как ESP: на removable USB Windows запрещает и
# "create partition efi", и "set id=c12a7328..." с ошибкой
# "Эта операция не поддерживается на сменных носителях".
# Это OK: BIOS грузит \EFI\Boot\bootx64.efi с любого removable-раздела
# через generic "UEFI:Removable Device" boot-entry (которая у ASUS/etc
# создаётся автоматически при наличии removable USB с bootx64.efi).
# В Invoke-FfuCaptureReboot.ps1 fallback на этот generic-entry и работает в проде,
# когда в системе только наша IpdromREC флешка.
#
# ВАЖНО: `clean` на USB-flash кратковременно "отсоединяет" диск от PnP-слоя
# Windows, и следующий `convert gpt` в том же diskpart-сессии падает с
# "Указано несуществующее устройство" (0x80070491). Разбиваем на две сессии
# с `rescan` и паузой между ними — стандартный workaround.
# 'attributes disk clear readonly' FIRST: a flash reused from a previous build
# still carries the readonly attribute that protect_ipdromrec set at the end of
# its cycle, and diskpart clean then fails with "media is write-protected"
# (0x80070013). Clearing it is a harmless no-op on a normal flash.
$dpClean = @"
select disk $($disk.Number)
attributes disk clear readonly
clean
rescan
exit
"@

# "Device not ready" (0x80070015 / -2147024875) is a common transient on a USB
# flash that sat idle for hours (e.g. through a 12h stress test) - the device
# needs a moment to re-enumerate. Retry the clean a few times with a short wait
# and a Get-Disk nudge before giving up, so one hiccup doesn't kill the whole
# FFU capture (which is exactly what happened on the first production run).
$rc = 1
for ($attempt = 1; $attempt -le 4; $attempt++) {
    Get-Disk -Number $disk.Number -ErrorAction SilentlyContinue | Out-Null
    $rc = Invoke-Diskpart -Script $dpClean
    if ($rc -eq 0) { break }
    Write-Log "diskpart clean attempt $attempt/4 failed (exit $rc) - flash may be 'not ready' after idle; waiting 8s and retrying..." 'Yellow'
    Start-Sleep -Seconds 8
}
if ($rc -ne 0) {
    Write-Log "diskpart clean failed after 4 attempts (exit $rc). Aborting." 'Red'
    exit 6
}

# Wait for PnP to re-enumerate the wiped disk before the next diskpart session.
Start-Sleep -Seconds 5

# Check current partition style. Windows 11 on UEFI often auto-initializes a freshly
# cleaned removable disk to GPT before we get a chance to convert. In that case
# `convert gpt` fails with 0x80070057 ("disk is not MBR format") and takes down the
# whole diskpart script. Only issue `convert gpt` if the disk is RAW or MBR.
$diskAfterClean = Get-Disk -Number $disk.Number -ErrorAction SilentlyContinue
$partStyle = if ($diskAfterClean) { $diskAfterClean.PartitionStyle } else { 'RAW' }
Write-Log "  Disk $($disk.Number) partition style after clean: $partStyle" 'Gray'

# Partitioning + formatting via PowerShell APIs instead of diskpart. Reason:
# on Win11, diskpart's "create partition primary size=N" -> "format" sequence
# is race-prone. Sometimes the new partition isn't yet selected by the time
# format runs, and the whole script aborts with "Том не выбран" (no volume
# selected). Set-Disk / New-Partition / Format-Volume handle the timing and
# selection atomically and let us specify sizes precisely.
#
# Ordering matters: -AssignDriveLetter on New-Partition is ASYNCHRONOUS on Win11
# removable USB - the returned partition object has an empty DriveLetter until
# the mount manager catches up, which takes 1-5+ seconds. Two mitigations:
#   1) Format FIRST via pipeline ($part | Format-Volume) which uses the partition
#      object directly and doesn't need a drive letter.
#   2) Assign the drive letter AFTER formatting via Add-PartitionAccessPath, then
#      re-query Get-Partition and wait until DriveLetter is populated.
if ($partStyle -ne 'GPT') {
    Write-Log "  Setting partition style to GPT via Set-Disk..." 'Gray'
    Set-Disk -Number $disk.Number -PartitionStyle GPT -ErrorAction Stop
    Start-Sleep -Seconds 2
}

function Wait-ForDriveLetter {
    param([int]$DiskNumber, [int]$PartitionNumber, [int]$TimeoutSec = 20)
    for ($i = 0; $i -lt $TimeoutSec; $i++) {
        $p = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction SilentlyContinue
        if ($p -and $p.DriveLetter -and ($p.DriveLetter -ne [char]0)) { return $p }
        Start-Sleep -Seconds 1
    }
    return $null
}

function Format-DriveByLetter {
    # Format a RAW partition by drive letter using native format.com.
    # We CAN'T use Format-Volume because it requires a pre-existing MSFT_Volume
    # object, which doesn't get materialized on a RAW partition until it's
    # formatted (chicken-and-egg). format.com works purely by drive letter.
    param(
        [Parameter(Mandatory)] [char]$DriveLetter,
        [Parameter(Mandatory)] [ValidateSet('FAT32','NTFS','exFAT')] [string]$FileSystem,
        [Parameter(Mandatory)] [string]$Label
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    # /Q = quick format, /Y = suppress the "OK to format?" prompt (Win10+ supports this).
    # We ALSO pipe "Y" to stdin in case /Y is not enough on some builds.
    $psi.Arguments = "/c format ${DriveLetter}: /FS:$FileSystem /V:$Label /Q /Y"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    try {
        $p.StandardInput.WriteLine('Y')
        $p.StandardInput.Close()
    } catch { }
    if (-not $p.WaitForExit(120000)) {
        try { $p.Kill() } catch { }
        throw "format.com timed out (>120s) for $Label"
    }
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    foreach ($ln in (($stdout + $stderr) -split "`r?`n")) {
        if ($ln.Trim()) { Write-Log "    | $ln" 'DarkGray' }
    }
    if ($p.ExitCode -ne 0) {
        throw "format.com exited with code $($p.ExitCode) for $Label"
    }

    # Belt-and-suspenders: format.com's /V:Label sometimes silently fails to stick
    # (esp. on FAT32 quick format), leaving the volume with an empty label. Verify
    # and explicitly re-set via the `label` command if needed. `label X: Y` (with
    # label as positional arg) does not prompt interactively.
    Start-Sleep -Seconds 3
    $currentLabel = ''
    try {
        $vol = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
        if ($vol) { $currentLabel = $vol.FileSystemLabel }
    } catch { }
    Write-Log "    Post-format label check: current='$currentLabel', want='$Label'" 'Gray'
    if (($currentLabel).Trim() -ine $Label) {
        Write-Log "    Label mismatch - enforcing via 'label' command..." 'Yellow'
        $labelPsi = New-Object System.Diagnostics.ProcessStartInfo
        $labelPsi.FileName = 'cmd.exe'
        $labelPsi.Arguments = "/c label ${DriveLetter}: $Label"
        $labelPsi.RedirectStandardOutput = $true
        $labelPsi.RedirectStandardError  = $true
        $labelPsi.UseShellExecute        = $false
        $labelPsi.CreateNoWindow         = $true
        $lp = [System.Diagnostics.Process]::Start($labelPsi)
        $lp.WaitForExit(15000) | Out-Null
        $lout = $lp.StandardOutput.ReadToEnd() + $lp.StandardError.ReadToEnd()
        foreach ($ln in ($lout -split "`r?`n")) { if ($ln.Trim()) { Write-Log "    | $ln" 'DarkGray' } }
        Start-Sleep -Seconds 2
        try {
            $vol2 = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
            if ($vol2) { Write-Log "    Label after 'label' command: '$($vol2.FileSystemLabel)'" 'Gray' }
        } catch { }
    }
}

# New-Partition -AssignDriveLetter is async: returns a partition object where
# .DriveLetter is still empty. We MUST wait for the mount manager to actually
# assign the letter before doing anything letter-dependent (Format-Volume).
# Also - piping a raw partition to Format-Volume doesn't work on PS 5.1
# (Format-Volume expects MSFT_Volume via pipeline, not MSFT_Partition, so
# parameter binding fails and script dies silently under $ErrorActionPreference=Stop).
# Solution: format by DriveLetter AFTER waiting for it.
try {
    Write-Log "  Creating WINRE partition ($WinreSizeMB MB FAT32)..." 'Gray'
    $winrePart = New-Partition -DiskNumber $disk.Number `
        -Size ($WinreSizeMB * 1MB) `
        -AssignDriveLetter `
        -ErrorAction Stop
    Write-Log "  New-Partition returned #$($winrePart.PartitionNumber), initial DriveLetter='$($winrePart.DriveLetter)' (may still be empty - waiting)..." 'Gray'
    $winrePart = Wait-ForDriveLetter -DiskNumber $disk.Number -PartitionNumber $winrePart.PartitionNumber
    if (-not $winrePart) { throw "WINRE partition never got a drive letter within 20 seconds" }
    Write-Log "  WINRE partition got letter $($winrePart.DriveLetter): - formatting as FAT32 via format.com..." 'Gray'
    Format-DriveByLetter -DriveLetter ([char]$winrePart.DriveLetter) -FileSystem 'FAT32' -Label 'WINRE'
    Write-Log "  WINRE ready at $($winrePart.DriveLetter):" 'Green'

    Write-Log "  Creating IpdromREC partition (remaining space, NTFS)..." 'Gray'
    $ipdromPart = New-Partition -DiskNumber $disk.Number `
        -UseMaximumSize `
        -AssignDriveLetter `
        -ErrorAction Stop
    Write-Log "  New-Partition returned #$($ipdromPart.PartitionNumber), initial DriveLetter='$($ipdromPart.DriveLetter)' (may still be empty - waiting)..." 'Gray'
    $ipdromPart = Wait-ForDriveLetter -DiskNumber $disk.Number -PartitionNumber $ipdromPart.PartitionNumber
    if (-not $ipdromPart) { throw "IpdromREC partition never got a drive letter within 20 seconds" }
    Write-Log "  IpdromREC partition got letter $($ipdromPart.DriveLetter): - formatting as NTFS via format.com..." 'Gray'
    Format-DriveByLetter -DriveLetter ([char]$ipdromPart.DriveLetter) -FileSystem 'NTFS' -Label 'IpdromREC'
    Write-Log "  IpdromREC ready at $($ipdromPart.DriveLetter):" 'Green'
} catch {
    Write-Log "PARTITIONING FAILED at exception boundary: $($_.Exception.Message)" 'Red'
    Write-Log "  Exception type: $($_.Exception.GetType().FullName)" 'Red'
    Write-Log "  Stack: $($_.ScriptStackTrace)" 'DarkRed'
    Write-Log "Aborting Prepare-IpdromRecFlash." 'Red'
    exit 7
}

# Refresh volume info
Start-Sleep -Seconds 3
$disk = Get-Disk -Number $disk.Number

# We already have $winrePart and $ipdromPart from the PowerShell API path above
# with drive letters populated. Use them directly - no need to search by label
# (Get-Volume can lag several seconds after format.com and return nothing).
# Wait for MSFT_Volume objects to appear as a sanity check, then log.
function Wait-ForVolumeByLetter {
    param([char]$DriveLetter, [int]$TimeoutSec = 30)
    for ($i = 0; $i -lt $TimeoutSec; $i++) {
        $v = Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
        if ($v) { return $v }
        Start-Sleep -Seconds 1
    }
    return $null
}

$winreRoot  = "$($winrePart.DriveLetter):"
$ipdromRoot = "$($ipdromPart.DriveLetter):"

function Force-VolumeRemount {
    # Windows sometimes leaves MSFT_Volume WMI registration in an incomplete state
    # after format.com on a fresh partition, especially under load. Remove and
    # re-assign the drive letter to force PnP re-enumeration and volume registration.
    param([int]$DiskNumber, [int]$PartitionNumber, [char]$OriginalLetter)
    try {
        Write-Log "    Forcing volume remount for ${OriginalLetter}: via letter cycle..." 'Gray'
        Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber `
            -AccessPath "${OriginalLetter}:\" -ErrorAction Stop
        Start-Sleep -Seconds 2
        Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber `
            -AssignDriveLetter -ErrorAction Stop
        Start-Sleep -Seconds 3
    } catch {
        Write-Log "    Remount cycle failed (non-fatal): $($_.Exception.Message)" 'Yellow'
    }
}

$winreVol = Wait-ForVolumeByLetter -DriveLetter ([char]$winrePart.DriveLetter)
if (-not $winreVol) {
    Write-Log "MSFT_Volume for WINRE not registered - forcing remount..." 'Yellow'
    Force-VolumeRemount -DiskNumber $disk.Number -PartitionNumber $winrePart.PartitionNumber -OriginalLetter ([char]$winrePart.DriveLetter)
    # Re-query partition (letter may have changed after cycle)
    $winrePart = Get-Partition -DiskNumber $disk.Number -PartitionNumber $winrePart.PartitionNumber
    if ($winrePart.DriveLetter -and ($winrePart.DriveLetter -ne [char]0)) {
        $winreVol = Wait-ForVolumeByLetter -DriveLetter ([char]$winrePart.DriveLetter) -TimeoutSec 30
    }
    if (-not $winreVol) {
        Write-Log "WARNING: WINRE MSFT_Volume still not visible after remount. Proceeding anyway (BCD creation may fail)." 'Red'
    } else {
        Write-Log "WINRE MSFT_Volume registered after remount at $($winrePart.DriveLetter):" 'Green'
    }
}
$ipdromVol = Wait-ForVolumeByLetter -DriveLetter ([char]$ipdromPart.DriveLetter)
if (-not $ipdromVol) {
    Write-Log "MSFT_Volume for IpdromREC not registered - forcing remount..." 'Yellow'
    Force-VolumeRemount -DiskNumber $disk.Number -PartitionNumber $ipdromPart.PartitionNumber -OriginalLetter ([char]$ipdromPart.DriveLetter)
    $ipdromPart = Get-Partition -DiskNumber $disk.Number -PartitionNumber $ipdromPart.PartitionNumber
    if ($ipdromPart.DriveLetter -and ($ipdromPart.DriveLetter -ne [char]0)) {
        $ipdromVol = Wait-ForVolumeByLetter -DriveLetter ([char]$ipdromPart.DriveLetter) -TimeoutSec 30
    }
    if (-not $ipdromVol) {
        Write-Log "WARNING: IpdromREC MSFT_Volume still not visible after remount. Proceeding anyway." 'Red'
    }
}

Write-Log "Partitions ready:" 'Green'
if ($winreVol) {
    Write-Log "  WINRE:     $winreRoot ($([math]::Round($winreVol.Size/1MB)) MB $($winreVol.FileSystem), label='$($winreVol.FileSystemLabel)')"
} else {
    Write-Log "  WINRE:     $winreRoot (MSFT_Volume not visible yet, but format.com succeeded)"
}
if ($ipdromVol) {
    Write-Log "  IpdromREC: $ipdromRoot ($([math]::Round($ipdromVol.Size/1GB,1)) GB $($ipdromVol.FileSystem), label='$($ipdromVol.FileSystemLabel)')"
} else {
    Write-Log "  IpdromREC: $ipdromRoot (MSFT_Volume not visible yet, but format.com succeeded)"
}

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

    # bcdboot on a freshly-formatted FAT32 removable partition sometimes fails with
    # BFSVC Error c00000bb (STATUS_NOT_SUPPORTED) "Failed to set element application
    # device". Two mitigations:
    #   1) Multiple bcdboot attempts with different flags + waits between them.
    #      MUST run under ErrorActionPreference=Continue - otherwise PS 5.1 treats
    #      any bcdboot stderr as a terminating error and kills the loop on attempt 1.
    #   2) If all bcdboot attempts fail, fall back to manual EFI setup: copy the
    #      EFI files by hand from WIM to F:\EFI and create the BCD store via bcdedit.
    #      This bypasses bcdboot's problematic "application device" resolution on
    #      removable media entirely.
    Start-Sleep -Seconds 5
    $bcdbootAttempts = @(
        @{ Args = @("$wimMount\Windows", '/s', $winreRoot, '/f', 'UEFI');                     Label = 'UEFI' },
        @{ Args = @("$wimMount\Windows", '/s', $winreRoot, '/f', 'UEFI', '/l', 'en-US');      Label = 'UEFI+en-US' },
        @{ Args = @("$wimMount\Windows", '/s', $winreRoot, '/f', 'ALL');                      Label = 'ALL' }
    )
    $bcdbootOK = $false
    # Isolate from outer ErrorActionPreference=Stop - native stderr must NOT become
    # a terminating error inside the retry loop.
    & {
        $ErrorActionPreference = 'Continue'
        foreach ($att in $bcdbootAttempts) {
            Write-Log "  bcdboot attempt: $($att.Label) $($att.Args -join ' ')" 'Gray'
            $bcdOut = & bcdboot @($att.Args) 2>&1
            $bcdExit = $LASTEXITCODE
            foreach ($ln in $bcdOut) {
                $line = if ($ln -is [System.Management.Automation.ErrorRecord]) { $ln.Exception.Message } else { [string]$ln }
                if ($line.Trim()) { Write-Log "  | $line" 'DarkGray' }
            }
            if ($bcdExit -eq 0) {
                Write-Log "  bcdboot succeeded ($($att.Label))." 'Green'
                $script:bcdbootOK = $true
                break
            }
            Write-Log "  bcdboot $($att.Label) failed (exit $bcdExit), sleeping 5s and trying next..." 'Yellow'
            Start-Sleep -Seconds 5
        }
    }

    if (-not $bcdbootOK) {
        Write-Log "All bcdboot attempts failed. Falling back to manual EFI setup..." 'Yellow'

        # 1) Copy EFI bootloader files manually from mounted WIM.
        $efiRoot   = Join-Path $winreRoot 'EFI'
        $efiBoot   = Join-Path $efiRoot   'Boot'
        $efiMsBoot = Join-Path $efiRoot   'Microsoft\Boot'
        New-Item -ItemType Directory -Force -Path $efiBoot   | Out-Null
        New-Item -ItemType Directory -Force -Path $efiMsBoot | Out-Null

        # Standard removable-media EFI layout: \EFI\Boot\bootx64.efi is the firmware entry.
        $srcBootmgrEfi = Join-Path $wimMount 'Windows\Boot\EFI\bootmgfw.efi'
        if (-not (Test-Path $srcBootmgrEfi)) { throw "Fallback: bootmgfw.efi not found in WIM at $srcBootmgrEfi" }
        Copy-Item -LiteralPath $srcBootmgrEfi -Destination (Join-Path $efiBoot 'bootx64.efi') -Force
        Copy-Item -LiteralPath $srcBootmgrEfi -Destination (Join-Path $efiMsBoot 'bootmgfw.efi') -Force

        # memtest.efi (optional but bcdboot copies it).
        $srcMemtest = Join-Path $wimMount 'Windows\Boot\EFI\memtest.efi'
        if (Test-Path $srcMemtest) {
            Copy-Item -LiteralPath $srcMemtest -Destination (Join-Path $efiMsBoot 'memtest.efi') -Force
        }

        # Copy en-us boot resources (some firmwares refuse to boot without them).
        $srcEnUs = Join-Path $wimMount 'Windows\Boot\EFI\en-us'
        if (Test-Path $srcEnUs) {
            $dstEnUs = Join-Path $efiMsBoot 'en-us'
            New-Item -ItemType Directory -Force -Path $dstEnUs | Out-Null
            Copy-Item -LiteralPath (Join-Path $srcEnUs '*') -Destination $dstEnUs -Recurse -Force
        }
        $srcFonts = Join-Path $wimMount 'Windows\Boot\EFI\Fonts'
        if (Test-Path $srcFonts) {
            Copy-Item -LiteralPath $srcFonts -Destination $efiMsBoot -Recurse -Force
        }
        $srcResources = Join-Path $wimMount 'Windows\Boot\EFI\Resources'
        if (Test-Path $srcResources) {
            Copy-Item -LiteralPath $srcResources -Destination $efiMsBoot -Recurse -Force
        }

        Write-Log "  Manually copied EFI bootloader files to $efiRoot" 'Gray'

        # 2) Create BCD store manually via bcdedit.
        # KEY INSIGHT: bcdedit /createstore fails on freshly-formatted FAT32 on
        # removable USB with "Element not found" - Windows Volume Manager may not
        # yet have the D: volume fully registered. Workaround: create the BCD
        # store on C:\ (where bcdedit ALWAYS works because system store exists),
        # populate it fully, then just Copy-Item to the USB. This bypasses all
        # WMI/volume registration issues.
        $bcdStore    = Join-Path $efiMsBoot 'BCD'
        $tempBcdDir  = Join-Path $env:TEMP "ipdrom_bcd_$(New-Guid)"
        $tempBcd     = Join-Path $tempBcdDir 'BCD'
        New-Item -ItemType Directory -Force -Path $tempBcdDir | Out-Null
        Remove-Item -LiteralPath $bcdStore -Force -ErrorAction SilentlyContinue

        & {
            $ErrorActionPreference = 'Continue'
            Write-Log "  Creating BCD store on C:\ temp path first: $tempBcd" 'Gray'
            & bcdedit /createstore "$tempBcd" 2>&1 | ForEach-Object {
                $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
                if ($line.Trim()) { Write-Log "  | $line" 'DarkGray' }
            }
            if ($LASTEXITCODE -ne 0) { throw "Fallback: bcdedit /createstore on C:\ temp failed (exit $LASTEXITCODE)" }
        }
        Write-Log "  BCD store created at $tempBcd (will populate then copy to USB)" 'Green'

        # Populate BCD with a minimal WinPE ramdisk boot entry. This mirrors what
        # bcdboot would have done, but with device=partition=X: instead of the
        # unresolvable "application device" placeholder that trips c00000bb.
        function Invoke-BcdEdit {
            param([string[]]$BcdArgs)
            & {
                $ErrorActionPreference = 'Continue'
                $out = & bcdedit @BcdArgs 2>&1
                foreach ($ln in $out) {
                    $line = if ($ln -is [System.Management.Automation.ErrorRecord]) { $ln.Exception.Message } else { [string]$ln }
                    if ($line.Trim()) { Write-Log "  | $line" 'DarkGray' }
                }
                return $LASTEXITCODE
            }
        }

        # Use temp store path (on C:\) for all bcdedit operations. Copy to USB at end.
        $storeArg = "$tempBcd"

        # Create bootmgr entry.
        Invoke-BcdEdit -BcdArgs @('/store', $storeArg, '/create', '{bootmgr}', '/d', 'Windows Boot Manager') | Out-Null
        Invoke-BcdEdit -BcdArgs @('/store', $storeArg, '/set', '{bootmgr}', 'device', "partition=$winreRoot") | Out-Null
        Invoke-BcdEdit -BcdArgs @('/store', $storeArg, '/set', '{bootmgr}', 'path', '\EFI\Microsoft\Boot\bootmgfw.efi') | Out-Null
        Invoke-BcdEdit -BcdArgs @('/store', $storeArg, '/set', '{bootmgr}', 'locale', 'en-US') | Out-Null
        Invoke-BcdEdit -BcdArgs @('/store', $storeArg, '/set', '{bootmgr}', 'timeout', '30') | Out-Null

        # Create ramdiskoptions.
        Invoke-BcdEdit -BcdArgs @('/store', $storeArg, '/create', '{ramdiskoptions}', '/d', 'Ramdisk options') | Out-Null
        Invoke-BcdEdit -BcdArgs @('/store', $storeArg, '/set', '{ramdiskoptions}', 'ramdisksdidevice', 'boot') | Out-Null
        Invoke-BcdEdit -BcdArgs @('/store', $storeArg, '/set', '{ramdiskoptions}', 'ramdisksdipath', '\boot\boot.sdi') | Out-Null

        # Create WinPE osloader entry.
        $osloaderOutput = & bcdedit /store $storeArg /create /d 'Windows PE Recovery' /application osloader 2>&1
        $osloaderGuid = $null
        foreach ($ln in $osloaderOutput) {
            $lineStr = if ($ln -is [System.Management.Automation.ErrorRecord]) { $ln.Exception.Message } else { [string]$ln }
            if ($lineStr -match '(\{[0-9a-f-]+\})') { $osloaderGuid = $Matches[1]; break }
            if ($lineStr.Trim()) { Write-Log "  | $lineStr" 'DarkGray' }
        }
        if (-not $osloaderGuid) { throw "Fallback: could not parse osloader GUID from bcdedit output." }
        Write-Log "  Created osloader entry: $osloaderGuid" 'Gray'

        $ramdiskDevice = "ramdisk=[boot]\sources\boot.wim,{ramdiskoptions}"
        Invoke-BcdEdit -BcdArgs @('/store', $storeArg, '/set', $osloaderGuid, 'device', $ramdiskDevice) | Out-Null
        Invoke-BcdEdit -BcdArgs @('/store', $storeArg, '/set', $osloaderGuid, 'osdevice', $ramdiskDevice) | Out-Null
        Invoke-BcdEdit -BcdArgs @('/store', $storeArg, '/set', $osloaderGuid, 'path', '\windows\system32\winload.efi') | Out-Null
        Invoke-BcdEdit -BcdArgs @('/store', $storeArg, '/set', $osloaderGuid, 'systemroot', '\windows') | Out-Null
        Invoke-BcdEdit -BcdArgs @('/store', $storeArg, '/set', $osloaderGuid, 'winpe', 'yes') | Out-Null
        Invoke-BcdEdit -BcdArgs @('/store', $storeArg, '/set', $osloaderGuid, 'detecthal', 'yes') | Out-Null
        Invoke-BcdEdit -BcdArgs @('/store', $storeArg, '/set', $osloaderGuid, 'locale', 'en-US') | Out-Null

        # Wire osloader as {bootmgr}'s default + displayorder.
        Invoke-BcdEdit -BcdArgs @('/store', $storeArg, '/set', '{bootmgr}', 'default', $osloaderGuid) | Out-Null
        Invoke-BcdEdit -BcdArgs @('/store', $storeArg, '/displayorder', $osloaderGuid) | Out-Null

        Write-Log "  Manual BCD store populated with WinPE ramdisk entry." 'Green'

        # Copy the fully-populated BCD from C:\ temp to the USB.
        Write-Log "  Copying populated BCD to USB target: $bcdStore" 'Gray'
        Copy-Item -LiteralPath $tempBcd -Destination $bcdStore -Force -ErrorAction Stop
        # Cleanup temp
        Remove-Item -LiteralPath $tempBcdDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "  BCD store deployed on USB at $bcdStore" 'Green'

        # Signal to the downstream "Patching USB BCD store" step (which uses
        # bcdedit /store D:\...) that it should be skipped - our BCD on USB
        # is already complete, and bcdedit can't open it on the removable
        # partition with unregistered MSFT_Volume anyway.
        $script:manualEfiFallbackUsed = $true

        $bcdbootOK = $true
    }

    if (-not $bcdbootOK) { throw "bcdboot failed after $($bcdbootAttempts.Count) attempts and manual fallback also failed." }

    Write-Log "Bootloader installed on $winreRoot." 'Green'

    # ===================== COPY boot.sdi (ramdisk descriptor) =====================
    # Без boot.sdi bootmgr не разрезолвит ramdisk=[boot]\sources\boot.wim ->
    # 0xC0000098/0xC0000225. В кастомном boot.wim файла boot.sdi обычно НЕТ
    # (искать в WIM бесполезно). Берём с ЖИВОЙ системы (C:\Windows...) - там есть.
    Write-Log "Copying boot.sdi (from live OS, not from WIM)..." 'Yellow'
    $bootSdiSrc = $null
    $sdiCandidates = @(
        (Join-Path $env:SystemRoot 'Boot\DVD\EFI\boot.sdi'),
        (Join-Path $env:SystemRoot 'Boot\DVD\PCAT\boot.sdi'),
        (Join-Path $env:SystemRoot 'System32\boot.sdi'),
        (Join-Path $env:SystemRoot 'System32\Recovery\boot.sdi'),
        (Join-Path $wimMount 'Windows\Boot\DVD\EFI\boot.sdi')
    )
    foreach ($p in $sdiCandidates) {
        if (Test-Path $p) { $bootSdiSrc = $p; break }
    }
    if ($bootSdiSrc) {
        $bootSdiDst = Join-Path $winreRoot 'boot\boot.sdi'
        New-Item -ItemType Directory -Force -Path (Split-Path $bootSdiDst -Parent) | Out-Null
        Copy-Item -LiteralPath $bootSdiSrc -Destination $bootSdiDst -Force
        $sdiSize = (Get-Item $bootSdiDst).Length
        Write-Log "  boot.sdi copied: $bootSdiDst ($sdiSize bytes from $bootSdiSrc)" 'Green'
    } else {
        Write-Log "  boot.sdi NOT FOUND anywhere - WinPE will fail to boot (0xC0000098)." 'Red'
        Write-Log "  Check C:\Windows\Boot\DVD\EFI\boot.sdi exists." 'Red'
    }

} catch {
    Write-Log "Bootloader install failed: $_" 'Red'
    & dism /Unmount-Wim "/MountDir:$wimMount" /Discard 2>&1 | Out-Null
    Remove-Item -LiteralPath $wimMount -Force -Recurse -ErrorAction SilentlyContinue
    exit 9
}

& dism /Unmount-Wim "/MountDir:$wimMount" /Discard 2>&1 | ForEach-Object { Write-Log "  | $_" 'DarkGray' }
Remove-Item -LiteralPath $wimMount -Force -Recurse -ErrorAction SilentlyContinue

# ===================== FIX USB BCD STORE (CRITICAL) =====================
# bcdboot $wimMount\Windows создаёт BCD на USB с device=unknown и абсолютным
# путём к winload.efi в mount-каталоге Temp. После размонтирования путь
# становится невалидным и bootmgr выдаёт 0xC0000225.
# ИСПРАВЛЯЕМ {default} entry чтобы он указывал на ramdisk WinPE-boot:
#   device      = ramdisk=[boot]\sources\boot.wim,{ramdiskoptions}
#   osdevice    = то же самое
#   path        = \windows\system32\winload.efi  (относительный, из boot.wim)
#   systemroot  = \windows
# И создаём {ramdiskoptions} который указывает на \boot\boot.sdi.
Write-Log "Patching USB BCD store for WinPE ramdisk boot..." 'Yellow'
$winreBcd = Join-Path $winreRoot 'EFI\Microsoft\Boot\BCD'
# If manual EFI fallback ran (bcdboot failed all 3 attempts), the BCD store
# on USB was populated from C:\ temp and ALREADY contains ramdiskoptions +
# default OS loader entries. bcdedit on D:\ (removable USB with missing
# MSFT_Volume registration) will fail with "Cannot open BCD"/"Element not
# found" and clutter the log with useless errors. Skip patching if we know
# we're in manual-fallback state.
if ($script:manualEfiFallbackUsed) {
    Write-Log "Manual EFI fallback was used - BCD store already fully populated on USB. Skipping patch step." 'Gray'
} elseif (-not (Test-Path $winreBcd)) {
    Write-Log "BCD store NOT FOUND at $winreBcd - bootmgr won't work." 'Red'
} else {
    # 1. Создаём {ramdiskoptions}. /create {ramdiskoptions} - well-known GUID.
    $rdOut = bcdedit /store "$winreBcd" /create '{ramdiskoptions}' /d "Ramdisk Options" 2>&1
    foreach ($l in $rdOut) { Write-Log "  | create ramdiskoptions: $l" 'DarkGray' }
    # Ошибка "уже существует" - не фатальна, продолжаем (это REFRESH case).

    # 2. Настраиваем где лежит boot.sdi.
    $r = bcdedit /store "$winreBcd" /set '{ramdiskoptions}' ramdisksdidevice boot 2>&1
    foreach ($l in $r) { Write-Log "  | set ramdisksdidevice: $l" 'DarkGray' }
    $r = bcdedit /store "$winreBcd" /set '{ramdiskoptions}' ramdisksdipath '\boot\boot.sdi' 2>&1
    foreach ($l in $r) { Write-Log "  | set ramdisksdipath: $l" 'DarkGray' }

    # 3. Переписываем {default} OS Loader для WinPE через ramdisk.
    $r = bcdedit /store "$winreBcd" /set '{default}' device 'ramdisk=[boot]\sources\boot.wim,{ramdiskoptions}' 2>&1
    foreach ($l in $r) { Write-Log "  | set default device: $l" 'DarkGray' }
    $r = bcdedit /store "$winreBcd" /set '{default}' osdevice 'ramdisk=[boot]\sources\boot.wim,{ramdiskoptions}' 2>&1
    foreach ($l in $r) { Write-Log "  | set default osdevice: $l" 'DarkGray' }
    $r = bcdedit /store "$winreBcd" /set '{default}' path '\windows\system32\winload.efi' 2>&1
    foreach ($l in $r) { Write-Log "  | set default path: $l" 'DarkGray' }
    $r = bcdedit /store "$winreBcd" /set '{default}' systemroot '\windows' 2>&1
    foreach ($l in $r) { Write-Log "  | set default systemroot: $l" 'DarkGray' }

    # 4. Диагностический дамп после правок - чтобы в логе было видно итоговое состояние.
    Write-Log "Final USB BCD content:" 'DarkGray'
    $dump = bcdedit /store "$winreBcd" /enum all 2>&1
    foreach ($l in $dump) { Write-Log "  | $l" 'DarkGray' }
}

# ===================== FIRMWARE BOOT ENTRY =====================
# НЕ создаём firmware-запись вручную через bcdedit /copy.
# Раньше тут был такой блок - он создавал запись "IPDROM Recovery FFU" с
# device=partition=WINRE, который на REMOVABLE USB невалиден ("несуществующее
# устройство"). Invoke-FfuCaptureReboot находил ЭТУ кривую запись вместо
# generic и BootNext падал -> авто-capture не запускался.
#
# На removable USB пометить раздел как ESP нельзя (set id=c12a7328... и
# create partition efi оба запрещены Windows на сменных носителях).
# Поэтому полагаемся на generic "UEFI:Removable Device" boot-entry,
# которую BIOS создаёт автоматически для любого removable с \EFI\Boot\bootx64.efi.
# В production-среде (вставлена только IpdromREC) она однозначно грузит нашу флешку.
Write-Log "Firmware entry: relying on generic 'UEFI:Removable Device' (removable USB cannot be marked ESP)." 'Gray'

# ===================== INITIALIZE IPDROMREC PARTITION =====================
Write-Log "Initializing IpdromREC partition..." 'Yellow'
New-Item -ItemType Directory -Force -Path (Join-Path $ipdromRoot 'Logs') | Out-Null
# Create a hint file describing the flash purpose and how to restore
$readme = @"
=== IPDROM Recovery Flash ===
Prepared by Prepare-IpdromRecFlash.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Source machine: $env:COMPUTERNAME

Layout:
  WINRE     : FAT32, bootable WinPE (auto-capture + restore mode)
  IpdromREC : NTFS, holds restore.ffu (the recovery image)

==============================================================
HOW TO RESTORE THIS MACHINE FROM THE BACKUP
==============================================================

When the system is broken and needs to be restored to factory state:

1. Plug this USB into the broken machine
2. Power on, press F11/F12 (boot menu key varies by motherboard)
3. Select "UEFI: <flash model>, Partition 1" from the boot menu
4. WinPE will load and detect restore.ffu on this flash
5. You will see:
       RECOVERY MODE
       Press R within 30 seconds to RESTORE
       Any other key (or no key) - cancel and reboot
6. Press R
7. You will see a list of physical disks. Find the SYSTEM DISK
   (usually the internal NVMe/SATA SSD, NOT this USB flash)
8. Enter its Index number (e.g. 0 or 1) and press Enter
9. Confirm with Y when asked
10. Wait 5-30 minutes while DISM /Apply-Ffu writes the image
11. When done, "RESTORE COMPLETED SUCCESSFULLY" appears
12. Remove the USB and reboot - the machine boots into the restored Windows

==============================================================
MANUAL RESTORE (if WinPE menu doesn't work)
==============================================================

If the automatic menu doesn't work, in WinPE press Shift+F10 to open cmd, then:

  diskpart
  list disk         (find your IpdromREC USB letter and target system disk Index)
  exit

  dism /Apply-Ffu /ImageFile:Z:\restore.ffu /ApplyDrive:\\.\PhysicalDriveN

Replace Z: with the IpdromREC drive letter and N with target disk number.
DO NOT pick the USB flash itself as ApplyDrive - that would wipe the image.

==============================================================
"@
Set-Content -LiteralPath (Join-Path $ipdromRoot 'README.txt') -Value $readme -Encoding utf8

# ===================== STAGE LOCAL WINPE FOR CAPTURE TRIGGER =====================
Write-Log "Staging local WinPE for capture trigger..." 'Yellow'
Invoke-LocalWinPEStage -PatchedWim $PatchedWim

Write-Log "=== FRESH preparation completed successfully ===" 'Green'
Write-Log "Flash ready at Disk $($disk.Number):" 'Green'
Write-Log "  WINRE:     $winreRoot" 'Green'
Write-Log "  IpdromREC: $ipdromRoot" 'Green'
Write-Log "Local WinPE staged at C:\WinPE\ - bootsequence-ready." 'Cyan'
exit 0
