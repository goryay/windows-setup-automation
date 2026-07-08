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

# Skip huge install images that don't belong on a repair flash (up to 4 GB each).
# .swm/.wim/.esd = Windows install media. Repair flash needs drivers + installers,
# not another copy of the install media — that's what IpdromREC is for.
$excludeFiles = @('*.swm', '*.wim', '*.esd', '*.iso')

# Sum size of folder excluding the big install-image files
function Measure-CopySize {
    param([string]$Src)
    $sum = 0
    Get-ChildItem -LiteralPath $Src -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $name = $_.Name
            -not ($excludeFiles | Where-Object { $name -like $_ })
        } |
        ForEach-Object { $sum += $_.Length }
    return $sum
}

# --- drivers ---
$driversSrc = Join-Path $UsbRoot 'drivers'
$driversDst = Join-Path $flashRoot 'drivers'
if (Test-Path -LiteralPath $driversSrc) {
    $needBytes = Measure-CopySize -Src $driversSrc
    $freeBytes = (Get-PSDrive -Name $flashLetter -ErrorAction SilentlyContinue).Free
    W ("drivers needs {0:N2} GB (excluding install images); free {1:N2} GB" -f ($needBytes/1GB), ($freeBytes/1GB))
    if ($needBytes -gt $freeBytes) {
        W "WARN: drivers would not fit even without install images. Skipping."
    } else {
        W "Copying drivers: $driversSrc -> $driversDst (excluding install images)"
        $rcLog = Join-Path $logDir 'deploy_extras_drivers.log'
        & robocopy.exe $driversSrc $driversDst /E /XJ /R:2 /W:5 /MT:8 /XF $excludeFiles /NFL /NDL /NP /LOG:$rcLog | Out-Null
        W "  drivers robocopy exit=$LASTEXITCODE"
    }
} else {
    W "WARN: drivers folder not found at $driversSrc - skipping."
}

# --- software ---
$softwareSrc = Join-Path $UsbRoot 'software'
$softwareDst = Join-Path $flashRoot 'software'
if (Test-Path -LiteralPath $softwareSrc) {
    $needBytes = Measure-CopySize -Src $softwareSrc
    $freeBytes = (Get-PSDrive -Name $flashLetter -ErrorAction SilentlyContinue).Free
    W ("software needs {0:N2} GB (excluding install images); free {1:N2} GB" -f ($needBytes/1GB), ($freeBytes/1GB))
    if ($needBytes -gt $freeBytes) {
        W "WARN: software would not fit. Skipping."
    } else {
        W "Copying software: $softwareSrc -> $softwareDst (excluding install images)"
        $rcLog = Join-Path $logDir 'deploy_extras_software.log'
        & robocopy.exe $softwareSrc $softwareDst /E /XJ /R:2 /W:5 /MT:8 /XF $excludeFiles /NFL /NDL /NP /LOG:$rcLog | Out-Null
        W "  software robocopy exit=$LASTEXITCODE"
    }
} else {
    W "WARN: software folder not found at $softwareSrc - skipping."
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
