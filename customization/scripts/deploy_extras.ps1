[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$UsbRoot,
    [string]$SLConfigPath = ''
)

$ErrorActionPreference = 'Continue'

$logDir = Join-Path $env:ProgramData 'IPDROM\Logs'
New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
$logFile = Join-Path $logDir ("deploy_extras_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function W { param([string]$m) $line = '[{0}] {1}' -f (Get-Date -f 'yyyy-MM-dd HH:mm:ss'),$m; Add-Content -Path $logFile -Value $line -Encoding utf8; Write-Host $line }

W "=== deploy_extras started ==="
W "UsbRoot:      $UsbRoot"
W ("SLConfigPath: " + $(if ($SLConfigPath) { $SLConfigPath } else { '<none>' }))

# =============================================================================
# Find the DOCS flash. Two paths:
#   (1) Existing IPDROM-labeled volume  -> just use it (operator prepared it).
#   (2) No IPDROM volume  -> autoformat: pick a small USB flash (8..32 GB) that
#       is unlabeled / RAW / empty and format it as IPDROM NTFS. This lets the
#       operator skip WinPE prompts entirely, or recover from a failed WinPE
#       diskpart. Refuses if 0 or >1 candidates - safer than guessing.
# =============================================================================
$DOCS_MIN_GB = 8
$DOCS_MAX_GB = 32     # anything >=32 GB is a REC candidate, not DOCS

function Find-IpdromDocsVolume {
    Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.FileSystemLabel -eq 'IPDROM' } |
        Select-Object -First 1
}

$vol = Find-IpdromDocsVolume
if (-not $vol) {
    W "IPDROM label not found on any volume. Trying auto-format fallback..."

    # Enumerate USB removable disks in the DOCS size band
    $usbDisks = @(Get-Disk -ErrorAction SilentlyContinue | Where-Object {
        $_.BusType -eq 'USB' -and (-not $_.IsBoot) -and (-not $_.IsSystem)
    })

    $candidates = @()
    foreach ($d in $usbDisks) {
        $sizeGB = [math]::Round($d.Size / 1GB, 1)
        if ($sizeGB -lt $DOCS_MIN_GB -or $sizeGB -gt $DOCS_MAX_GB) {
            W ("  reject: Disk {0} '{1}' {2} GB - out of DOCS size band {3}..{4}" -f $d.Number, $d.FriendlyName, $sizeGB, $DOCS_MIN_GB, $DOCS_MAX_GB)
            continue
        }
        # Check that partitions are unlabeled or empty. Refuse to touch a flash
        # with any recognizable user data (labeled volumes, ventoy, etc).
        $parts = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue)
        $vols  = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object {
            $parts.AccessPaths -contains "$($_.DriveLetter):\" -or $parts.DriveLetter -contains $_.DriveLetter
        })
        $labels = @($vols | ForEach-Object { $_.FileSystemLabel } | Where-Object { $_ })
        $isEmpty = ($parts.Count -eq 0) -or ($d.PartitionStyle -eq 'RAW') -or ($labels.Count -eq 0)
        if (-not $isEmpty) {
            W ("  reject: Disk {0} '{1}' {2} GB - has user data (labels: {3})" -f $d.Number, $d.FriendlyName, $sizeGB, ($labels -join ','))
            continue
        }
        W ("  CANDIDATE: Disk {0} '{1}' {2} GB - eligible for IPDROM autoformat" -f $d.Number, $d.FriendlyName, $sizeGB)
        $candidates += $d
    }

    if ($candidates.Count -eq 0) {
        W "No USB flash in $DOCS_MIN_GB..$DOCS_MAX_GB GB range eligible for autoformat. Nothing to do."
        exit 0
    }
    if ($candidates.Count -gt 1) {
        W "Multiple ($($candidates.Count)) candidates - refuse to guess. Unplug extras and rerun."
        exit 0
    }

    $docs = $candidates[0]
    W "Autoformatting Disk $($docs.Number) '$($docs.FriendlyName)' as IPDROM (NTFS)..."

    # Two-pass diskpart, same pattern as Prepare-IpdromRecFlash:
    #   Pass 1: clean + rescan (releases handles, forces PnP re-enumeration)
    #   Wait 3-5s for Windows to settle
    #   Check partition style - Win11 auto-initializes cleaned USB flashes to GPT.
    #   If already GPT, skip "convert gpt" (it requires MBR/RAW source, otherwise
    #   fails with 0x80070057 "The specified disk is not MBR format").
    #   Pass 2: (optional convert) + create partition + format + assign
    function Invoke-DocsDiskpart {
        param([string]$Script)
        $tmp = Join-Path $env:TEMP "ipdrom_docs_fmt_$(New-Guid).txt"
        Set-Content -LiteralPath $tmp -Value $Script -Encoding ASCII
        $dpOut = & diskpart.exe /s $tmp 2>&1
        $dpExit = $LASTEXITCODE
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        foreach ($ln in ($dpOut -split "`r?`n")) { if ($ln.Trim()) { W "  | $ln" } }
        return $dpExit
    }

    $dpClean = @"
select disk $($docs.Number)
clean
rescan
exit
"@
    W "  diskpart pass 1: clean + rescan"
    $rc = Invoke-DocsDiskpart -Script $dpClean
    if ($rc -ne 0) {
        W "diskpart clean failed with exit $rc. Cannot continue autoformat."
        exit 1
    }

    Start-Sleep -Seconds 5

    $diskAfterClean = Get-Disk -Number $docs.Number -ErrorAction SilentlyContinue
    $partStyle = if ($diskAfterClean) { $diskAfterClean.PartitionStyle } else { 'RAW' }
    W "  Disk $($docs.Number) partition style after clean: $partStyle"
    $convertLine = if ($partStyle -eq 'GPT') { '' } else { "convert gpt`n" }

    $dpFormat = @"
select disk $($docs.Number)
$convertLine
create partition primary
format fs=ntfs label="IPDROM" quick
assign
exit
"@
    W "  diskpart pass 2: partition + format + assign"
    $rc = Invoke-DocsDiskpart -Script $dpFormat
    if ($rc -ne 0) {
        W "diskpart format failed with exit $rc. Cannot continue autoformat."
        exit 1
    }

    Start-Sleep -Seconds 3
    $vol = Find-IpdromDocsVolume
    if (-not $vol) {
        W "Autoformat completed but IPDROM volume still not visible. Aborting."
        exit 1
    }
    W "IPDROM autoformat succeeded."
}

$flashLetter = $vol.DriveLetter
if (-not $flashLetter) { W "IPDROM volume has no drive letter assigned. Cannot copy."; exit 1 }
$flashRoot = "$($flashLetter):\"
W "IPDROM flash root: $flashRoot"

$free = (Get-PSDrive -Name $flashLetter -ErrorAction SilentlyContinue).Free
if ($free) { W ("Free space on flash: {0:N1} GB" -f ($free / 1GB)) }

# =============================================================================
# Per-SL selection: only what a repair master actually needs for THIS machine.
# Full drivers/ and software/ folders (~30 GB each with .swm images) are NOT
# copied -- only motherboard-specific drivers, RAID software (if RAID present)
# and NVIDIA driver (if discrete GPU present). Docs handled via deploy_docs.
# =============================================================================

# Parse SL config into a hashtable (case-insensitive keys)
$sl = @{}
if ($SLConfigPath -and (Test-Path -LiteralPath $SLConfigPath)) {
    foreach ($line in (Get-Content -LiteralPath $SLConfigPath -Encoding UTF8)) {
        if ($line -match '^\s*([^=#][^=]*?)\s*=\s*(.*)\s*$') {
            $sl[$matches[1].Trim().ToLower()] = $matches[2].Trim()
        }
    }
    W "Parsed $($sl.Count) SL config keys."
    W "  mb_model:            $($sl['mb_model'])"
    W "  gpu_discrete:        $($sl['gpu_discrete']) (model=$($sl['gpu_discrete_model']))"
    W "  raid1_model:         $($sl['raid1_model'])"
    W "  raid2_model:         $($sl['raid2_model'])"
} else {
    W "WARN: no SL config -- will copy nothing selective."
}

# NOTE: motherboard drivers intentionally NOT copied -- repair master doesn't
# reinstall the OS on the same board, they either restore via IpdromREC FFU or
# swap boards. Only RAID/GPU/docs go on the flash.

# --- MegaRAID software (LSI/Avago) if any RAID controller declared -------
# Copy the .zip archive as-is - repair master unpacks on the target machine.
$hasRaid = (($sl['raid1_model']) -and ($sl['raid1_model'] -ne 'None')) `
        -or (($sl['raid2_model']) -and ($sl['raid2_model'] -ne 'None'))
if ($hasRaid) {
    $softwareDir = Join-Path $UsbRoot 'software'
    $raidZips = Get-ChildItem -LiteralPath $softwareDir -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Extension -eq '.zip' -and $_.Name -match '(?i)avago|megaraid|lsi'
        }
    if ($raidZips) {
        $raidDst = Join-Path $flashRoot 'software'
        New-Item -ItemType Directory -Path $raidDst -Force -ErrorAction SilentlyContinue | Out-Null
        foreach ($z in $raidZips) {
            W "Copying RAID archive: $($z.Name) -> $raidDst"
            try {
                Copy-Item -LiteralPath $z.FullName -Destination $raidDst -Force -ErrorAction Stop
            } catch {
                W "  Copy failed: $($_.Exception.Message)"
            }
        }
    } else {
        W "WARN: RAID controller in SL but no *.zip (avago|megaraid|lsi) archive found in $softwareDir"
    }
} else {
    W "No RAID controllers in SL config -- RAID software skipped."
}

# --- NVIDIA driver if discrete GPU declared ------------------------------
$gpuDisc = ($sl['gpu_discrete'] -eq 'TRUE') `
        -and ($sl['gpu_discrete_model']) `
        -and ($sl['gpu_discrete_model'] -ne 'None')
if ($gpuDisc) {
    $softwareDir = Join-Path $UsbRoot 'software'
    # Match: files with 'nvidia' in name (case-insensitive) OR NVIDIA versioned
    # installer pattern like "551.86-desktop-*.exe"
    $nvFiles = Get-ChildItem -LiteralPath $softwareDir -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Extension -eq '.exe' -and (
                $_.Name -match '(?i)nvidia' -or
                $_.Name -match '^\d+\.\d{2,}-desktop.*'
            )
        }
    if ($nvFiles) {
        $nvDst = Join-Path $flashRoot 'software\NVIDIA'
        New-Item -ItemType Directory -Path $nvDst -Force -ErrorAction SilentlyContinue | Out-Null
        foreach ($nv in $nvFiles) {
            W "Copying NVIDIA installer: $($nv.Name) -> $nvDst"
            try {
                Copy-Item -LiteralPath $nv.FullName -Destination $nvDst -Force -ErrorAction Stop
            } catch {
                W "  Copy failed: $($_.Exception.Message)"
            }
        }
    } else {
        W "WARN: gpu_discrete=TRUE in SL but no NVIDIA installer found in $softwareDir"
    }
} else {
    W "No discrete GPU in SL config -- NVIDIA driver skipped."
}

# --- documentation via deploy_docs ---
if ($SLConfigPath -and (Test-Path -LiteralPath $SLConfigPath)) {
    $deployDocs = Join-Path $PSScriptRoot 'deploy_docs.ps1'
    if (Test-Path -LiteralPath $deployDocs) {
        $docsSrc = Join-Path $UsbRoot 'documentation'
        # Desktop root (no subfolder) -- PDFs appear as icons directly on Desktop
        $desktopDst = [Environment]::GetFolderPath('Desktop')
        # Flash keeps a Documentation subfolder for organization
        $flashDocsDst = Join-Path $flashRoot 'Documentation'
        W "Calling deploy_docs to copy per-SL PDFs to flash + refresh desktop..."
        try {
            & $deployDocs -SLConfigPath $SLConfigPath -DocsSource $docsSrc -DesktopDest $desktopDst -FlashDest $flashDocsDst
        } catch { W "deploy_docs threw: $($_.Exception.Message)" }
    } else {
        W "deploy_docs.ps1 not found next to deploy_extras.ps1 - docs not copied to flash."
    }
} else {
    W "No SL config provided - skipping docs copy."
}

# Report final free space
$freeAfter = (Get-PSDrive -Name $flashLetter -ErrorAction SilentlyContinue).Free
if ($freeAfter) { W ("Free space on flash after copy: {0:N1} GB" -f ($freeAfter / 1GB)) }

W "=== deploy_extras finished ==="
exit 0
