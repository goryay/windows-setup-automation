<#
.SYNOPSIS
    Auto-detect IpdromREC flash drive candidate without asking the operator.

    Returns 0 to stdout if exactly one safe candidate is found AND sets
    VAR_IPDR_REC=1 in platform.bat. Otherwise sets VAR_IPDR_REC=0 with
    diagnostic log explaining why.

    Safety rules (ALL must hold for auto-selection):
      1. BusType = USB
      2. Removable media (IsRemovable=$true OR MediaType='Removable Media')
      3. Size in [32, 256] GB
      4. NOT a pipeline ISO flash (no Ventoy / VTOYEFI / IPDROM_Recovery labels,
         no customization\scripts or boot\ folder)
      5. Either fully empty (no partitions) OR already has WINRE + IpdromREC labels

    Exactly ONE candidate must match. Zero or two+ -> manual mode (no flag flip).

.PARAMETER PlatformBat
    Path to platform.bat to modify. Required.

.PARAMETER MinSizeGB
    Minimum acceptable size in GB. Default 32.

.PARAMETER MaxSizeGB
    Maximum acceptable size in GB. Default 256.

.PARAMETER LogPath
    Where to write the detection log. Default: ProgramData\IPDROM\Logs\.
#>
param(
    [Parameter(Mandatory)][string]$PlatformBat,
    [int]$MinSizeGB = 32,
    [int]$MaxSizeGB = 256,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

if (-not $LogPath) {
    $logDir = Join-Path $env:ProgramData 'IPDROM\Logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $LogPath = Join-Path $logDir ("detect_ipdromrec_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}

function Write-Log {
    param([string]$Msg, [string]$Color = 'White')
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
    Write-Host $Msg -ForegroundColor $Color
    try { $line | Out-File -FilePath $LogPath -Encoding utf8 -Append } catch {}
}

function Set-PlatformVar {
    param([int]$Value)
    if (-not (Test-Path $PlatformBat)) {
        Write-Log "platform.bat not found at $PlatformBat. Cannot write VAR_IPDR_REC." 'Red'
        return
    }
    $content = Get-Content -LiteralPath $PlatformBat
    if ($content.Count -lt 41) {
        Write-Log "platform.bat too short ($($content.Count) lines), expected ≥41." 'Red'
        return
    }
    $content[40] = "set VAR_IPDR_REC=$Value"
    $content | Set-Content -LiteralPath $PlatformBat -Encoding ASCII
    Write-Log "platform.bat line 41: 'set VAR_IPDR_REC=$Value' written." 'Green'
}

# ===================== ENUMERATE =====================
Write-Log "=== IpdromREC flash auto-detection started ===" 'Cyan'
Write-Log "PlatformBat:   $PlatformBat" 'Gray'
Write-Log "Size range:    ${MinSizeGB}..${MaxSizeGB} GB" 'Gray'
Write-Log "Log:           $LogPath" 'Gray'

# Excluded labels — pipeline volumes that must never be touched
$excludedLabels = @('Ventoy', 'VTOYEFI', 'IPDROM_Recovery', 'IPDROM_RECOVERY')
# Reserved good labels — these mean the flash is ALREADY our IpdromREC
$ourLabels = @('IpdromREC', 'WINRE', 'WinRE')

$allDisks = @(Get-Disk -ErrorAction SilentlyContinue | Sort-Object Number)
Write-Log "All physical disks visible (${($allDisks.Count)}):" 'Gray'
foreach ($d in $allDisks) {
    $sizeGB = [math]::Round($d.Size/1GB,1)
    Write-Log ("  Disk {0}: '{1}' {2} GB Bus={3} Removable={4} OperationalStatus={5}" -f `
        $d.Number, $d.FriendlyName, $sizeGB, $d.BusType, $d.IsRemovable, $d.OperationalStatus) 'Gray'
}

$candidates = New-Object System.Collections.Generic.List[object]
$rejected   = New-Object System.Collections.Generic.List[object]

foreach ($disk in $allDisks) {
    $reasons = New-Object System.Collections.Generic.List[string]
    $sizeGB  = [math]::Round($disk.Size/1GB,1)

    # 1) Bus = USB
    if ($disk.BusType -ne 'USB') { [void]$reasons.Add("BusType=$($disk.BusType) (need USB)") }

    # 2) Removable
    if (-not $disk.IsRemovable) { [void]$reasons.Add("not removable") }

    # 3) Size
    if ($sizeGB -lt $MinSizeGB) { [void]$reasons.Add("too small ($sizeGB GB < $MinSizeGB)") }
    if ($sizeGB -gt $MaxSizeGB) { [void]$reasons.Add("too big ($sizeGB GB > $MaxSizeGB)") }

    # 4) Check partition labels / content
    $partitions = @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue)
    $volumes = @()
    foreach ($p in $partitions) {
        if ($p.DriveLetter) {
            $v = Get-Volume -DriveLetter $p.DriveLetter -ErrorAction SilentlyContinue
            if ($v) { $volumes += $v }
        }
    }

    $hasExcludedLabel = $false
    $hasOurLabel      = $false
    $hasIsoContent    = $false
    foreach ($v in $volumes) {
        if ($excludedLabels -contains $v.FileSystemLabel) { $hasExcludedLabel = $true }
        if ($ourLabels      -contains $v.FileSystemLabel) { $hasOurLabel      = $true }
        if ($v.DriveLetter) {
            $root = "$($v.DriveLetter):\"
            if ((Test-Path (Join-Path $root 'customization\scripts')) -or
                (Test-Path (Join-Path $root 'boot')) -or
                (Test-Path (Join-Path $root 'ventoy'))) {
                $hasIsoContent = $true
            }
        }
    }

    if ($hasExcludedLabel) { [void]$reasons.Add("has excluded label ($($volumes.FileSystemLabel -join ','))") }
    if ($hasIsoContent)    { [void]$reasons.Add("contains ISO/Ventoy/customization content — pipeline flash") }

    # 5) Empty or already-ours?
    $isEmpty = ($partitions.Count -eq 0) -or ($disk.PartitionStyle -eq 'RAW')
    $isOurs  = $hasOurLabel
    if (-not ($isEmpty -or $isOurs)) {
        [void]$reasons.Add("has existing partitions/data that are not ours")
    }

    if ($reasons.Count -eq 0) {
        [void]$candidates.Add([pscustomobject]@{
            Disk      = $disk
            SizeGB    = $sizeGB
            Volumes   = $volumes
            IsEmpty   = $isEmpty
            IsOurs    = $isOurs
        })
    } else {
        [void]$rejected.Add([pscustomobject]@{
            Disk    = $disk
            SizeGB  = $sizeGB
            Reasons = $reasons -join '; '
        })
    }
}

# ===================== REPORT =====================
Write-Log "" 'White'
Write-Log "Rejected disks (${($rejected.Count)}):" 'Gray'
foreach ($r in $rejected) {
    Write-Log ("  Disk {0} '{1}' {2} GB -> {3}" -f $r.Disk.Number, $r.Disk.FriendlyName, $r.SizeGB, $r.Reasons) 'DarkGray'
}

Write-Log "" 'White'
Write-Log "Candidates (${($candidates.Count)}):" 'Cyan'
foreach ($c in $candidates) {
    $state = if ($c.IsOurs) { 'EXISTING IpdromREC (refresh)' } elseif ($c.IsEmpty) { 'EMPTY (will prepare)' } else { '?' }
    Write-Log ("  Disk {0} '{1}' {2} GB -> {3}" -f $c.Disk.Number, $c.Disk.FriendlyName, $c.SizeGB, $state) 'Green'
}

# ===================== DECISION =====================
Write-Log "" 'White'
if ($candidates.Count -eq 1) {
    $chosen = $candidates[0]
    Write-Log "DECISION: auto-selecting Disk $($chosen.Disk.Number) '$($chosen.Disk.FriendlyName)' as IpdromREC." 'Green'
    Set-PlatformVar -Value 1
    exit 0
} elseif ($candidates.Count -eq 0) {
    Write-Log "DECISION: no safe IpdromREC candidate found. Set VAR_IPDR_REC=0 (skip flash prep)." 'Yellow'
    Write-Log "         Plug in a USB stick that is empty or already labeled IpdromREC/WINRE." 'Yellow'
    Set-PlatformVar -Value 0
    exit 1
} else {
    Write-Log "DECISION: multiple ($($candidates.Count)) candidates found — REFUSING to choose automatically." 'Red'
    Write-Log "         Operator must unplug all but one IpdromREC candidate, then re-run." 'Red'
    Set-PlatformVar -Value 0
    exit 2
}
