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

# Find IpdromDOCS flash by volume label
$vol = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.FileSystemLabel -eq 'IpdromDOCS' } | Select-Object -First 1
if (-not $vol) {
    W "IpdromDOCS flash not found (label 'IpdromDOCS' not present on any volume)."
    W "Operator either chose SKIP in WinPE, or docs flash was not prepared. Nothing to do."
    exit 0
}

$flashLetter = $vol.DriveLetter
if (-not $flashLetter) { W "IpdromDOCS volume has no drive letter assigned. Cannot copy."; exit 1 }
$flashRoot = "$($flashLetter):\"
W "IpdromDOCS flash root: $flashRoot"

$free = (Get-PSDrive -Name $flashLetter -ErrorAction SilentlyContinue).Free
if ($free) { W ("Free space on flash: {0:N1} GB" -f ($free / 1GB)) }

# =============================================================================
# Per-SL selection: only what a repair master actually needs for THIS machine.
# Full drivers/ and software/ folders (~30 GB each with .swm images) are NOT
# copied — only motherboard-specific drivers, RAID software (if RAID present)
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
    W "WARN: no SL config — will copy nothing selective."
}

# NOTE: motherboard drivers intentionally NOT copied — repair master doesn't
# reinstall the OS on the same board, they either restore via IpdromREC FFU or
# swap boards. Only RAID/GPU/docs go on the flash.

# --- MegaRAID software (LSI/Avago) if any RAID controller declared -------
$hasRaid = (($sl['raid1_model']) -and ($sl['raid1_model'] -ne 'None')) `
        -or (($sl['raid2_model']) -and ($sl['raid2_model'] -ne 'None'))
if ($hasRaid) {
    foreach ($subdir in @('AvagoMegaRaid', 'DriverAvagoMegaRaid')) {
        $src = Join-Path $UsbRoot "software\$subdir"
        $dst = Join-Path $flashRoot "software\$subdir"
        if (Test-Path -LiteralPath $src) {
            W "Copying RAID pkg $subdir: $src -> $dst"
            $rcLog = Join-Path $logDir "deploy_extras_$subdir.log"
            & robocopy.exe $src $dst /E /XJ /R:2 /W:5 /MT:8 /NFL /NDL /NP /LOG:$rcLog | Out-Null
            W "  $subdir robocopy exit=$LASTEXITCODE"
        } else {
            W "WARN: RAID pkg $subdir not found at $src"
        }
    }
} else {
    W "No RAID controllers in SL config — RAID software skipped."
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
    W "No discrete GPU in SL config — NVIDIA driver skipped."
}

# --- documentation via deploy_docs ---
if ($SLConfigPath -and (Test-Path -LiteralPath $SLConfigPath)) {
    $deployDocs = Join-Path $PSScriptRoot 'deploy_docs.ps1'
    if (Test-Path -LiteralPath $deployDocs) {
        $docsSrc = Join-Path $UsbRoot 'documentation'
        # Desktop root (no subfolder) — PDFs appear as icons directly on Desktop
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
