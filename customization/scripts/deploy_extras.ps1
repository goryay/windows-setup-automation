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
    # Volume + not-subst filter: subst F: -> C:\IPDROM doesn't register as a
    # distinct MSFT_Volume, so Get-Volume already excludes it. But belt-and-
    # suspenders: enforce a real drive letter with a physical disk backing.
    Get-Volume -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FileSystemLabel -eq 'IPDROM' -and $_.DriveLetter -and
            ($null -ne (Get-Partition -DriveLetter $_.DriveLetter -ErrorAction SilentlyContinue))
        } |
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

    # Force letter=T to avoid collision with subst F: -> C:\IPDROM
    # (subst is process-level and can mask a physically-assigned F:, causing all
    # copies to land back inside C:\IPDROM. T: is far from any expected letter.)
    $dpFormat = @"
select disk $($docs.Number)
$convertLine
create partition primary
format fs=ntfs label="IPDROM" quick
assign letter=T
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
# Sources and destinations
# =============================================================================
$softsSrc    = Join-Path $UsbRoot 'software\docs\softs'
$driversSrc  = Join-Path $UsbRoot 'software\docs\drivers'
$softwareDst = Join-Path $flashRoot 'software'
$driversDst  = Join-Path $flashRoot 'drivers'

foreach ($p in @($softsSrc, $driversSrc)) {
    if (-not (Test-Path -LiteralPath $p)) {
        W "WARN: source dir missing: $p"
    }
}

New-Item -ItemType Directory -Path $softwareDst -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path $driversDst  -Force -ErrorAction SilentlyContinue | Out-Null

# =============================================================================
# Parse SL config into a hashtable (case-insensitive keys)
# =============================================================================
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
    W "  axxonsoft:           $($sl['axxonsoft'])"
    W "  guardant_num:        $($sl['guardant_num'])"
} else {
    W "WARN: no SL config -- selective copies will be skipped."
}

# Helper: copy file OR folder from $Src into $DstDir with logging
function Copy-ToFlash {
    param(
        [Parameter(Mandatory)] [string]$Src,
        [Parameter(Mandatory)] [string]$DstDir,
        [string]$Reason = ''
    )
    if (-not (Test-Path -LiteralPath $Src)) {
        W "  MISS: $Src (reason: $Reason)"
        return
    }
    if (-not (Test-Path -LiteralPath $DstDir)) {
        New-Item -ItemType Directory -Path $DstDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $item = Get-Item -LiteralPath $Src -ErrorAction SilentlyContinue
    if (-not $item) { W "  MISS: cannot Get-Item $Src"; return }
    $name = $item.Name
    try {
        if ($item.PSIsContainer) {
            # Copy folder recursively into DstDir (preserves folder name)
            Copy-Item -LiteralPath $Src -Destination $DstDir -Recurse -Force -ErrorAction Stop
        } else {
            Copy-Item -LiteralPath $Src -Destination $DstDir -Force -ErrorAction Stop
        }
        W "  OK: $name -> $DstDir ($Reason)"
    } catch {
        W "  FAILED: $name -> $DstDir : $($_.Exception.Message)"
    }
}

# Helper: find files in $Dir matching regex on Name (case-insensitive)
function Find-BySrcRegex {
    param([string]$Dir, [string]$Pattern)
    if (-not (Test-Path -LiteralPath $Dir)) { return @() }
    Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $Pattern }
}

# =============================================================================
# 1) Fixed items: 7-Zip + Adobe Reader (always, regardless of SL)
# =============================================================================
W "--- Fixed items (7-Zip + Adobe Reader) ---"
$fixedPatterns = @('(?i)^7z.*\.exe$', '(?i)^AdbeRdr.*\.exe$|(?i)Adobe.*Reader.*\.exe$')
foreach ($pat in $fixedPatterns) {
    $matches_ = Find-BySrcRegex -Dir $softsSrc -Pattern $pat
    foreach ($f in $matches_) { Copy-ToFlash -Src $f.FullName -DstDir $softwareDst -Reason "fixed" }
}

# =============================================================================
# 2) MegaRAID: software + driver, if any RAID controller declared in SL
# =============================================================================
$hasRaid = (($sl['raid1_model']) -and ($sl['raid1_model'] -ne 'None')) `
        -or (($sl['raid2_model']) -and ($sl['raid2_model'] -ne 'None'))
if ($hasRaid) {
    W "--- RAID controller declared in SL -> copying MegaRAID software + driver ---"
    foreach ($f in (Find-BySrcRegex -Dir $softsSrc   -Pattern '(?i)(avago|megaraid|lsi).*\.(zip|exe|msi)$')) {
        Copy-ToFlash -Src $f.FullName -DstDir $softwareDst -Reason "RAID software"
    }
    foreach ($f in (Find-BySrcRegex -Dir $driversSrc -Pattern '(?i)(avago|megaraid|lsi).*\.(zip|exe|msi|7z)$')) {
        Copy-ToFlash -Src $f.FullName -DstDir $driversDst -Reason "RAID driver"
    }
} else {
    W "No RAID controllers in SL -- MegaRAID software+driver skipped."
}

# =============================================================================
# 3) Axxon Intellect / IntellectX (based on axxonsoft key)
# =============================================================================
$axxonsoft = if ($sl['axxonsoft']) { $sl['axxonsoft'].ToLower() } else { '' }
switch ($axxonsoft) {
    'i' {
        W "--- axxonsoft=i -> Intellect ---"
        foreach ($f in (Find-BySrcRegex -Dir $softsSrc -Pattern '(?i)^Intellect_.*\.zip$')) {
            Copy-ToFlash -Src $f.FullName -DstDir $softwareDst -Reason "Intellect"
        }
    }
    'ix' {
        W "--- axxonsoft=ix -> IntellectX ---"
        foreach ($f in (Find-BySrcRegex -Dir $softsSrc -Pattern '(?i)IntellectX.*\.zip$')) {
            Copy-ToFlash -Src $f.FullName -DstDir $softwareDst -Reason "IntellectX"
        }
    }
    default { W "axxonsoft='$axxonsoft' -- no Intellect/IntellectX copied." }
}

# =============================================================================
# 4) Detector Pack (if axxonsoft_addons mentions any Detector item)
# =============================================================================
$addons = if ($sl['axxonsoft_addons']) { $sl['axxonsoft_addons'] } else { '' }
# Cyrillic 'Детектор' constructed via char codes so .ps1 file encoding doesn't
# matter -- Windows PowerShell in RU locale reads BOM-less UTF-8 as Windows-1251
# and mangles literals like 'Детектор' into 'Р”РµС‚РµРєС‚РѕСЂ' at parse time.
$rusDetector = -join @(0x0414,0x0435,0x0442,0x0435,0x043A,0x0442,0x043E,0x0440 | ForEach-Object { [char]$_ })
$hasDetector = $addons -match ("(?i)" + [regex]::Escape($rusDetector) + '|Detector')
if ($hasDetector) {
    W "--- Detector Pack requested in SL addons ---"
    foreach ($f in (Find-BySrcRegex -Dir $softsSrc -Pattern '(?i)DetectorPack')) {
        Copy-ToFlash -Src $f.FullName -DstDir $softwareDst -Reason "Detector Pack"
    }
} else {
    W "No Detector Pack in SL addons -- skipped."
}

# =============================================================================
# 5) Guardant drivers (if any guardant key OR addon Guardant/Senselock)
# =============================================================================
$guardantNum = 0
[void][int]::TryParse(("" + $sl['guardant_num']), [ref]$guardantNum)
$hasGuardant = ($guardantNum -gt 0) -or ($addons -match '(?i)Guardant|Senselock')
if ($hasGuardant) {
    W "--- Guardant key present (guardant_num=$guardantNum or addon match) -> copying driver ---"
    foreach ($f in (Find-BySrcRegex -Dir $softsSrc -Pattern '(?i)(^Grd|Guardant).*\.exe$')) {
        Copy-ToFlash -Src $f.FullName -DstDir $softwareDst -Reason "Guardant"
    }
} else {
    W "No Guardant in SL -- Guardant driver skipped."
}

# =============================================================================
# 6) NVIDIA / discrete GPU driver (from drivers/ folder)
# =============================================================================
$gpuDisc = ($sl['gpu_discrete'] -eq 'TRUE') `
        -and ($sl['gpu_discrete_model']) `
        -and ($sl['gpu_discrete_model'] -ne 'None')
if ($gpuDisc) {
    W "--- Discrete GPU declared -> copying NVIDIA/Quadro driver ---"
    foreach ($f in (Find-BySrcRegex -Dir $driversSrc -Pattern '(?i)(nvidia|quadro|geforce|whql).*\.exe$|^\d+\.\d{2,}-.*\.exe$')) {
        Copy-ToFlash -Src $f.FullName -DstDir $driversDst -Reason "GPU driver"
    }
} else {
    W "No discrete GPU in SL -- NVIDIA driver skipped."
}

# =============================================================================
# 7) Motherboard drivers (auto-match by mb_model against drivers/ folder)
# =============================================================================
function Get-DriverTokens {
    param([string]$Text)
    if (-not $Text) { return @() }
    $normalized = $Text -replace '[^A-Za-z0-9]+', ' '
    @($normalized.ToUpper() -split '\s+' | Where-Object { $_ -and $_.Length -ge 2 })
}

function Find-MbDriverAsset {
    param([string]$MbModel, [string]$DriversDir)
    if (-not $MbModel -or -not (Test-Path -LiteralPath $DriversDir)) { return $null }
    $mbTokens = @(Get-DriverTokens $MbModel)
    if ($mbTokens.Count -lt 2) { return $null }

    $items = Get-ChildItem -LiteralPath $DriversDir -ErrorAction SilentlyContinue |
        Where-Object { $_.PSIsContainer -or $_.Name -match '(?i)\.(7z|zip)$' }

    $best = $null
    $bestScore = -1
    foreach ($it in $items) {
        # Skip well-known non-mb items (RAID driver zip, NVIDIA/PCIe SATA cards)
        if ($it.Name -match '(?i)avago|megaraid|lsi|nvidia|quadro|geforce|whql|pcie.*sata|^\d+\.\d{2,}-') { continue }

        $baseName = if ($it.PSIsContainer) { $it.Name } else { [IO.Path]::GetFileNameWithoutExtension($it.Name) }
        $drvTokens = @(Get-DriverTokens $baseName)
        if ($drvTokens.Count -lt 2) { continue }

        $matched = @($drvTokens | Where-Object { $mbTokens -contains $_ }).Count
        if ($matched -lt 2) { continue }
        $extra   = $drvTokens.Count - $matched
        $score   = $matched - ($extra * 0.5)

        W ("    candidate: '$baseName' matched=$matched extra=$extra score=$score")

        if ($score -gt $bestScore) {
            $bestScore = $score
            $best = $it
        }
    }

    if ($best) {
        W ("  best mb driver match: '$($best.Name)' score=$bestScore")
    }
    return $best
}

W "--- Motherboard driver auto-match ---"
$mbAsset = Find-MbDriverAsset -MbModel $sl['mb_model'] -DriversDir $driversSrc
if ($mbAsset) {
    Copy-ToFlash -Src $mbAsset.FullName -DstDir $driversDst -Reason "MB drivers ($($sl['mb_model']))"
} else {
    W "  No mb driver matched for mb_model='$($sl['mb_model'])'."
}

# =============================================================================
# 8) Documentation (unchanged: via deploy_docs)
# =============================================================================
if ($SLConfigPath -and (Test-Path -LiteralPath $SLConfigPath)) {
    $deployDocs = Join-Path $PSScriptRoot 'deploy_docs.ps1'
    if (Test-Path -LiteralPath $deployDocs) {
        $docsSrc = Join-Path $UsbRoot 'documentation'
        $desktopDst = [Environment]::GetFolderPath('Desktop')
        $flashDocsDst = Join-Path $flashRoot 'Documentation'
        W "--- Documentation via deploy_docs ---"
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
