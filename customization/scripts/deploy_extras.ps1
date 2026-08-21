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
# MegaRAID software/driver only for a REAL LSI/Avago/MegaRAID controller.
# raid1_model can be 'None', an integrated-Intel label, or a real LSI name -
# only the last should pull the Avago software onto the customer flash. A plain
# "not empty / not None" check wrongly copied Avago for integrated controllers.
$raidModelRx = '(?i)avago|megaraid|lsi|broadcom'
$hasRaid = (($sl['raid1_model']) -match $raidModelRx) -or (($sl['raid2_model']) -match $raidModelRx)
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
# Значения ключа - те же, что понимает Install-AxxonByBuildSpec:
#   i = Intellect classic | x = IntellectX | a = Axxon Next
# Здесь раньше стояло 'ix' вместо 'x', поэтому для SL с IntellectX (SL002)
# дистрибутив на флешку не копировался вообще - ветка уходила в default.
$axxonsoft = if ($sl['axxonsoft']) { $sl['axxonsoft'].ToLower() } else { '' }
switch ($axxonsoft) {
    'i' {
        W "--- axxonsoft=i -> Intellect ---"
        foreach ($f in (Find-BySrcRegex -Dir $softsSrc -Pattern '(?i)^Intellect_.*\.zip$')) {
            Copy-ToFlash -Src $f.FullName -DstDir $softwareDst -Reason "Intellect"
        }
    }
    'x' {
        W "--- axxonsoft=x -> IntellectX ---"
        foreach ($f in (Find-BySrcRegex -Dir $softsSrc -Pattern '(?i)^IntellectX.*\.zip$')) {
            Copy-ToFlash -Src $f.FullName -DstDir $softwareDst -Reason "IntellectX"
        }
    }
    'a' {
        W "--- axxonsoft=a -> Axxon Next ---"
        $anFiles = @(Find-BySrcRegex -Dir $softsSrc -Pattern '(?i)axxon.*next.*\.(zip|exe|msi)$')
        if ($anFiles.Count -eq 0) {
            W "  WARN: Axxon Next requested in SL but no installer found in $softsSrc"
        }
        foreach ($f in $anFiles) { Copy-ToFlash -Src $f.FullName -DstDir $softwareDst -Reason "Axxon Next" }
    }
    default { W "axxonsoft='$axxonsoft' -- unknown value, no Axxon distribution copied." }
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
# Pick the ONE driver matching the declared GPU model (same rules as the stress
# script) so ONLY the right driver hits the flash, not every NVIDIA .exe in the
# folder. Fully automatic from gpu_discrete_model - no operator choice.
function Select-NvidiaDriverForModel {
    param([string]$DriversDir, [string]$GpuModel)
    $exes = @(Get-ChildItem -LiteralPath $DriversDir -Filter '*.exe' -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -match '(?i)quadro|geforce|nvidia|desktop|-dch-|rtx|^\d+\.\d{2,}-' })
    if ($exes.Count -eq 0) { return $null }
    if ($exes.Count -eq 1) { return $exes[0] }
    $m = "$GpuModel"
    if ($m -match '(?i)\bquadro\b|\bnvs\b') {
        $pick = $exes | Where-Object { $_.Name -match '(?i)quadro|rtx' } | Sort-Object Length -Descending | Select-Object -First 1
        if ($pick) { return $pick }
    } elseif ($m -match '(?i)\bGT\s*7\d0\b|\bGT\s*6\d0\b|\bGT\s*710\b') {
        $pick = $exes | Where-Object { $_.Name -match '^47\d\.' } | Sort-Object Length -Descending | Select-Object -First 1
        if ($pick) { return $pick }
    }
    $pick = $exes | Where-Object { $_.Name -match '(?i)desktop' -and $_.Name -notmatch '(?i)quadro' } | Sort-Object Length -Descending | Select-Object -First 1
    if ($pick) { return $pick }
    return ($exes | Sort-Object Length -Descending | Select-Object -First 1)
}

$gpuDisc = ($sl['gpu_discrete'] -eq 'TRUE') `
        -and ($sl['gpu_discrete_model']) `
        -and ($sl['gpu_discrete_model'] -ne 'None')
if ($gpuDisc) {
    $nvDrv = Select-NvidiaDriverForModel -DriversDir $driversSrc -GpuModel $sl['gpu_discrete_model']
    if ($nvDrv) {
        W "--- Discrete GPU '$($sl['gpu_discrete_model'])' -> copying matched driver: $($nvDrv.Name) ---"
        Copy-ToFlash -Src $nvDrv.FullName -DstDir $driversDst -Reason "GPU driver (matched to model)"
    } else {
        W "Discrete GPU declared but no matching NVIDIA driver found in $driversSrc."
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

# Fallback source for MB drivers: the per-board install sets under
# drivers\platforms. Used when software\docs\drivers has no curated vendor pack
# for this board. A driver pack on the customer flash is REQUIRED by the delivery
# standard, so rather than ship nothing we copy the board's driver-store folders
# (the same INFs Windows Setup installs from) onto the flash. Service scaffolding
# (platform.bat, offline_root PDFs, empty offline_drivers_*) is skipped.
function Copy-MbDriverFromPlatforms {
    param(
        [string]$MbModel,
        [string]$PlatformsDir,
        [string]$DstDir,
        [string]$FlashLetter
    )
    if (-not (Test-Path -LiteralPath $PlatformsDir)) {
        W "  platforms fallback: dir not found ($PlatformsDir) -- no MB driver shipped."
        return
    }
    # Same strict token matcher as the curated packs (by mb_model only, so
    # 'Z790 UD' requires BOTH Z790 and UD -> won't grab a neighbouring board).
    $board = Find-MbDriverAsset -MbModel $MbModel -DriversDir $PlatformsDir
    if (-not $board) {
        W "  platforms fallback: no board folder matched mb_model='$MbModel' in $PlatformsDir."
        return
    }
    W "  platforms fallback: matched board folder '$($board.Name)'."

    # INF-bearing subfolders only (driver-store export). Skip empty/service dirs.
    $drvFolders = @(Get-ChildItem -LiteralPath $board.FullName -Directory -ErrorAction SilentlyContinue |
        Where-Object { Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter *.inf -ErrorAction SilentlyContinue | Select-Object -First 1 })
    if ($drvFolders.Count -eq 0) {
        W "  platforms fallback: no INF-bearing content under '$($board.Name)' -- nothing to ship."
        return
    }

    # Space guard: total payload vs free space on the flash (keep 1 GB margin).
    $needBytes = 0L
    foreach ($f in $drvFolders) {
        $needBytes += (Get-ChildItem -LiteralPath $f.FullName -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    }
    $freeBytes = (Get-PSDrive -Name $FlashLetter -ErrorAction SilentlyContinue).Free
    if ($freeBytes -and (($needBytes + 1GB) -gt $freeBytes)) {
        W ("  platforms fallback: not enough space (need {0:N1} GB + 1 GB margin, free {1:N1} GB) -- MB driver NOT shipped." -f ($needBytes/1GB), ($freeBytes/1GB))
        return
    }

    $destBoard = Join-Path $DstDir $board.Name
    W ("  platforms fallback: shipping {0:N1} GB of drivers -> $destBoard" -f ($needBytes/1GB))
    foreach ($f in $drvFolders) {
        Copy-ToFlash -Src $f.FullName -DstDir $destBoard -Reason "MB drivers from platforms ($($board.Name))"
    }
}

W "--- Motherboard driver auto-match ---"
# Match on vendor+model together: platform folders are named <Vendor>_<Model>
# ('SuperMicro_X13SAE-F', 'MSI_Z390-A-PRO', 'FLAB.687265.004'). Some models alone
# tokenize to <2 tokens (e.g. 'X13SAE-F' -> just 'X13SAE'), so mb_model-only never
# reaches the >=2-token match. Prefixing mb_vendor supplies the 2nd token.
$mbSearch = (('{0} {1}' -f $sl['mb_vendor'], $sl['mb_model']).Trim())
W "  mb search string: '$mbSearch'"
$mbAsset = Find-MbDriverAsset -MbModel $mbSearch -DriversDir $driversSrc
if ($mbAsset) {
    Copy-ToFlash -Src $mbAsset.FullName -DstDir $driversDst -Reason "MB drivers ($mbSearch)"
} else {
    W "  No curated mb pack matched for '$mbSearch' in $driversSrc."
    # A driver pack on the flash is required by the delivery standard. With no
    # curated vendor pack, fall back to the board's install set in drivers\platforms.
    Copy-MbDriverFromPlatforms -MbModel $mbSearch -PlatformsDir (Join-Path $UsbRoot 'drivers\platforms') -DstDir $driversDst -FlashLetter $flashLetter
}

# =============================================================================
# 7.5) Intel RST driver (setuprst.exe) — only for a real SYSTEM-LEVEL RAID.
# Two conditions must hold together on the same group:
#   group_N_disk_system = TRUE   -> this is the system disk group
#   group_N_Type        = RAID-x -> and it is an actual RAID array
# disk_system=TRUE alone is NOT enough: a system group can be 'wo_RAID'
# (single disk, no array) — that needs no RAID driver at all.
# System RAID itself is built manually in BIOS by the operator; we only ship
# and install the driver so Windows can see/manage the array.
# =============================================================================
$hasSystemRaid = $false
$sysRaidType   = ''
$sysRaidHost   = ''
foreach ($k in $sl.Keys) {
    # NOTE: capture the group number immediately. Chaining a second -match in the
    # same if-condition overwrites $matches and would blank out $gn.
    if ($k -notmatch '^group_(\d+)_disk_system$') { continue }
    $gn = $matches[1]
    if ($sl[$k] -notmatch '^(?i)true$') { continue }

    # SL keys are lower-cased at parse time, so group_1_Type -> group_1_type
    $typeRaw  = "" + $sl["group_${gn}_type"]
    # "RAID-1" / "RAID 1" / "raid_1" -> "RAID1";  "wo_RAID" -> "WORAID"
    $typeNorm = ($typeRaw -replace '[\s\-_]', '').ToUpper()
    if ($typeNorm -match '^RAID\d+$') {
        $hasSystemRaid = $true
        $sysRaidType   = $typeRaw
        $sysRaidHost   = "" + $sl["group_${gn}_host"]
        break
    }
    W "  group_${gn}: disk_system=TRUE but Type='$typeRaw' is not a RAID level -- not a system RAID."
}
if ($hasSystemRaid) {
    W "--- System RAID detected (Type='$sysRaidType', host='$sysRaidHost') -> Intel RST driver ---"
    $rstFiles = @(Find-BySrcRegex -Dir $softsSrc -Pattern '(?i)^setuprst\.exe$')
    if ($rstFiles.Count -gt 0) {
        foreach ($rst in $rstFiles) {
            # Copy to IPDROM flash first (repair-master will have it even if install fails)
            Copy-ToFlash -Src $rst.FullName -DstDir $softwareDst -Reason "Intel RST installer (system RAID)"

            # Silent install on live system. The OLD flags '-s -f -acceptall -r n'
            # were rejected with exit 1639 (invalid command line): 19.5 has no
            # '-f', '-acceptall' is now '-accepteula', and '-r' takes a LOG PATH,
            # not 'n'. Correct flags:
            #   -silent      = no dialogs (-s is the short form)
            #   -accepteula  = MANDATORY for silent (accepts EULA), per ReadMe
            #   -norestart   = do NOT reboot. CRITICAL: this runs BEFORE the FFU
            #                  capture; an installer reboot here would restart the
            #                  launcher mid-pipeline and corrupt the flow.
            # '-norestart' is community-documented and confirmed working, but our
            # exact binary's ReadMe does not list it - and this binary rejects
            # unknown flags with 1639. So we try WITH -norestart first and, only
            # if that specific 1639 comes back, retry without it (the driver is
            # already injected at the same version, so a reboot is unlikely even
            # then). Installs the "Intel Rapid Storage Technology" management app
            # + service, which is what lets the operator SEE the system RAID.
            # Exit codes: 0 = OK, 3010 = OK but needs reboot, 1639 = bad flag.
            $rstArgSets = @(
                @('-silent','-accepteula','-norestart'),
                @('-silent','-accepteula')
            )
            foreach ($argSet in $rstArgSets) {
                W ("  Silent install: {0} {1}" -f $rst.FullName, ($argSet -join ' '))
                $rc = $null
                try {
                    $proc = Start-Process -FilePath $rst.FullName -ArgumentList $argSet `
                        -Wait -PassThru -NoNewWindow -ErrorAction Stop
                    $rc = $proc.ExitCode
                } catch {
                    W "  setuprst.exe launch FAILED: $($_.Exception.Message)"
                    break
                }
                if ($rc -eq 0 -or $rc -eq 3010) {
                    W "  setuprst.exe OK (exit=$rc)"
                    break
                }
                if ($rc -eq 1639) {
                    W "  exit 1639 (a flag was rejected) - retrying with a reduced flag set..."
                    continue
                }
                W "  setuprst.exe returned exit=$rc (non-zero; install error)"
                break
            }
        }
    } else {
        W "  WARN: system RAID declared in SL but setuprst.exe not found in $softsSrc"
    }
} else {
    W "No system-level RAID in SL (no group with disk_system=TRUE + Type=RAID-x) -- Intel RST skipped."
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
