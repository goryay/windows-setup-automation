param(
    [string]$BackupLabel = 'IpdromREC'
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Color = 'White')
    Write-Host $Message -ForegroundColor $Color
    try { "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message | Out-File -FilePath $script:LogFile -Encoding utf8 -Append } catch {}
}

# ===================== LOG =====================
$logDir = Join-Path $env:ProgramData 'IPDROM\Logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$script:LogFile = Join-Path $logDir ("backup_capture_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

Write-Log "=== Backup capture started ===" 'Cyan'
Write-Log "Target volume label: $BackupLabel"

# ===================== DISM PRESENT =====================
try {
    $dism = (Get-Command dism.exe -ErrorAction Stop).Source
    Write-Log "DISM path: $dism" 'Gray'
} catch {
    Write-Log "dism.exe not found." 'Red'
    exit 2
}

# ===================== FIND BACKUP VOLUME =====================
$backupVolume = Get-Volume -ErrorAction SilentlyContinue |
    Where-Object { $_.FileSystemLabel -eq $BackupLabel -and $_.DriveLetter } |
    Select-Object -First 1

if (-not $backupVolume) {
    Write-Log "Volume with label '$BackupLabel' not found. Capture skipped." 'Yellow'
    Write-Log "Make sure the IpdromREC USB is plugged in and partition is labeled correctly." 'Yellow'
    exit 0
}

$backupDrive   = "$($backupVolume.DriveLetter):"
$backupFreeGB  = [math]::Round($backupVolume.SizeRemaining / 1GB, 1)
$backupTotalGB = [math]::Round($backupVolume.Size / 1GB, 1)
Write-Log "Found target volume: $backupDrive ($backupTotalGB GB total, $backupFreeGB GB free)" 'Green'

# ===================== FIND SYSTEM DISK =====================
$sysDriveLetter = $env:SystemDrive.TrimEnd(':')
try {
    $sysPart = Get-Partition -DriveLetter $sysDriveLetter -ErrorAction Stop
    $sysDisk = Get-Disk -Number $sysPart.DiskNumber -ErrorAction Stop
} catch {
    Write-Log "Cannot identify system disk for $sysDriveLetter`: $_" 'Red'
    exit 3
}

$capturePath   = "\\.\PhysicalDrive$($sysDisk.Number)"
$sysDiskSizeGB = [math]::Round($sysDisk.Size / 1GB, 1)
Write-Log "System disk: $($sysDisk.FriendlyName) (Disk $($sysDisk.Number), $sysDiskSizeGB GB)" 'Gray'
Write-Log "CaptureDrive: $capturePath" 'Gray'

# Sanity: enough free space? .ffu/.wim compresses, but estimate ~50%
$estSizeGB = [math]::Round($sysDisk.Size * 0.5 / 1GB, 1)
if ($backupVolume.SizeRemaining -lt $sysDisk.Size * 0.4) {
    Write-Log "WARNING: only $backupFreeGB GB free, capture may need up to $estSizeGB GB. Continuing anyway." 'Yellow'
}

# ===================== PRESERVE OLD BACKUP =====================
$ffuPath    = Join-Path $backupDrive 'restore.ffu'
$ffuOldPath = Join-Path $backupDrive 'restore.old.ffu'
$ffuNewPath = Join-Path $backupDrive 'restore.new.ffu'
$wimPath    = Join-Path $backupDrive 'restore.wim'
$wimNewPath = Join-Path $backupDrive 'restore.new.wim'

# Clean temp leftovers from any previous failed attempts
foreach ($p in @($ffuNewPath, $wimNewPath)) {
    if (Test-Path $p) {
        Write-Log "Removing leftover: $p" 'DarkGray'
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    }
}

# ===================== ATTEMPT 1: DISM /Capture-Ffu =====================
$ffuName = "IPDROM-$env:COMPUTERNAME-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$ffuDesc = "Captured $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') on $env:COMPUTERNAME after stress test"

Write-Log "Attempt 1: DISM /Capture-Ffu (may fail on running OS - that's expected)" 'Cyan'
Write-Log "  -> $dism /Capture-Ffu /ImageFile:$ffuNewPath /CaptureDrive:$capturePath /Name:`"$ffuName`" /Description:`"$ffuDesc`""

$ffuOk = $false
try {
    $ffuOutFile = Join-Path $logDir ("ffu_dism_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    & $dism /Capture-Ffu "/ImageFile:$ffuNewPath" "/CaptureDrive:$capturePath" "/Name:$ffuName" "/Description:$ffuDesc" *> $ffuOutFile
    $ffuExit = $LASTEXITCODE
    Write-Log "DISM exit code: $ffuExit (full output: $ffuOutFile)" 'Gray'
    if ($ffuExit -eq 0 -and (Test-Path $ffuNewPath) -and (Get-Item $ffuNewPath).Length -gt 100MB) {
        $ffuOk = $true
    } else {
        Write-Log "FFU capture did not produce a valid file. Removing partial." 'Yellow'
        # Show last 30 lines of DISM output so user sees actual error inline
        if (Test-Path $ffuOutFile) {
            Write-Log "--- DISM /Capture-Ffu tail ---" 'DarkGray'
            Get-Content -LiteralPath $ffuOutFile -Tail 30 -ErrorAction SilentlyContinue |
                ForEach-Object { Write-Log "  | $_" 'DarkGray' }
            Write-Log "--- end DISM tail ---" 'DarkGray'
        }
        if (Test-Path $ffuNewPath) { Remove-Item -LiteralPath $ffuNewPath -Force -ErrorAction SilentlyContinue }
    }
} catch {
    Write-Log "FFU capture threw: $_" 'Yellow'
    if (Test-Path $ffuNewPath) { Remove-Item -LiteralPath $ffuNewPath -Force -ErrorAction SilentlyContinue }
}

if ($ffuOk) {
    Write-Log "FFU capture SUCCEEDED." 'Green'
    # Rotate: restore.ffu → restore.old.ffu, restore.new.ffu → restore.ffu
    if (Test-Path $ffuOldPath) { Remove-Item -LiteralPath $ffuOldPath -Force -ErrorAction SilentlyContinue }
    if (Test-Path $ffuPath)    { Rename-Item -LiteralPath $ffuPath -NewName 'restore.old.ffu' -Force }
    Rename-Item -LiteralPath $ffuNewPath -NewName 'restore.ffu' -Force
    $sizeGB = [math]::Round((Get-Item $ffuPath).Length / 1GB, 2)
    Write-Log "Saved: $ffuPath ($sizeGB GB)" 'Green'
    exit 0
}

# ===================== ATTEMPT 2: DISM /Capture-Image (.wim) =====================
Write-Log "Attempt 2: DISM /Capture-Image (.wim of C: via VSS shadow copy)" 'Cyan'
$wimName = "IPDROM-$env:COMPUTERNAME-C-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$wimDesc = "Captured $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') on $env:COMPUTERNAME (C: only, via VSS)"

Write-Log "  -> $dism /Capture-Image /ImageFile:$wimNewPath /CaptureDir:$env:SystemDrive\ /Name:`"$wimName`" /Description:`"$wimDesc`" /Compress:Fast"

$wimOk = $false
try {
    $wimOutFile = Join-Path $logDir ("wim_dism_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    & $dism /Capture-Image "/ImageFile:$wimNewPath" "/CaptureDir:$env:SystemDrive\" "/Name:$wimName" "/Description:$wimDesc" /Compress:Fast *> $wimOutFile
    $wimExit = $LASTEXITCODE
    Write-Log "DISM exit code: $wimExit (full output: $wimOutFile)" 'Gray'
    if ($wimExit -eq 0 -and (Test-Path $wimNewPath) -and (Get-Item $wimNewPath).Length -gt 100MB) {
        $wimOk = $true
    } else {
        Write-Log "WIM capture did not produce a valid file." 'Red'
        if (Test-Path $wimOutFile) {
            Write-Log "--- DISM /Capture-Image tail ---" 'DarkGray'
            Get-Content -LiteralPath $wimOutFile -Tail 30 -ErrorAction SilentlyContinue |
                ForEach-Object { Write-Log "  | $_" 'DarkGray' }
            Write-Log "--- end DISM tail ---" 'DarkGray'
        }
        if (Test-Path $wimNewPath) { Remove-Item -LiteralPath $wimNewPath -Force -ErrorAction SilentlyContinue }
    }
} catch {
    Write-Log "WIM capture threw: $_" 'Red'
    if (Test-Path $wimNewPath) { Remove-Item -LiteralPath $wimNewPath -Force -ErrorAction SilentlyContinue }
}

if ($wimOk) {
    Write-Log "WIM capture SUCCEEDED (fallback)." 'Green'
    if (Test-Path $wimPath) {
        $wimOldPath = Join-Path $backupDrive 'restore.old.wim'
        if (Test-Path $wimOldPath) { Remove-Item -LiteralPath $wimOldPath -Force -ErrorAction SilentlyContinue }
        Rename-Item -LiteralPath $wimPath -NewName 'restore.old.wim' -Force
    }
    Rename-Item -LiteralPath $wimNewPath -NewName 'restore.wim' -Force
    $sizeGB = [math]::Round((Get-Item $wimPath).Length / 1GB, 2)
    Write-Log "Saved: $wimPath ($sizeGB GB)" 'Green'
    Write-Log "NOTE: This is a .wim of C: only. To restore: boot WinPE, recreate partitions, then 'dism /Apply-Image /ImageFile:Z:\restore.wim /Index:1 /ApplyDir:C:\'." 'Yellow'
    Write-Log "NOTE: For full-disk .ffu of running boot disk, need WinPE-side auto-capture (deferred)." 'Yellow'
    exit 0
}

# ===================== BOTH FAILED =====================
Write-Log "Both FFU and WIM capture attempts failed." 'Red'
Write-Log "Existing restore.ffu (if any) is untouched and still valid for restore." 'Yellow'
Write-Log "Manual capture from WinPE is still possible as before." 'Yellow'
exit 1
