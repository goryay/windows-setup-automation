[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$SLConfigPath,
    [Parameter(Mandatory)] [string]$DocsSource,
    [Parameter(Mandatory)] [string]$DesktopDest,
    [string]$FlashDest = ''
)

$ErrorActionPreference = 'Continue'

$logDir = Join-Path $env:ProgramData 'IPDROM\Logs'
New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
$logFile = Join-Path $logDir ("deploy_docs_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function W { param([string]$m) $line = '[{0}] {1}' -f (Get-Date -f 'yyyy-MM-dd HH:mm:ss'),$m; Add-Content -Path $logFile -Value $line -Encoding utf8; Write-Host $line }

W "=== deploy_docs started ==="
W "SLConfig:    $SLConfigPath"
W "DocsSource:  $DocsSource"
W "DesktopDest: $DesktopDest"
W ("FlashDest:   " + $(if ($FlashDest) { $FlashDest } else { '<none>' }))

if (-not (Test-Path -LiteralPath $SLConfigPath)) { W "FATAL: SL config not found."; exit 1 }
if (-not (Test-Path -LiteralPath $DocsSource))   { W "FATAL: DocsSource folder not found."; exit 1 }

# Find doc= line in SL config
$docLine = $null
foreach ($line in (Get-Content -LiteralPath $SLConfigPath -Encoding UTF8)) {
    if ($line -match '^\s*doc\s*=\s*(.+)$') { $docLine = $matches[1].Trim(); break }
}

if (-not $docLine) { W "No doc= line in SL config. Nothing to deploy."; exit 0 }

# Parse: split by ';', each item is /filename::sha256hash
$items = @()
foreach ($chunk in ($docLine -split ';')) {
    $chunk = $chunk.Trim()
    if (-not $chunk) { continue }
    if ($chunk -match '^\/?(.+?)::([0-9a-fA-F]{64})\s*$') {
        $items += [pscustomobject]@{ File = $matches[1].Trim(); Hash = $matches[2].ToLower() }
    } else {
        W "WARN: cannot parse doc entry: '$chunk'"
    }
}
W "Parsed $($items.Count) doc entries from config."

New-Item -ItemType Directory -Path $DesktopDest -Force -ErrorAction SilentlyContinue | Out-Null
if ($FlashDest) { New-Item -ItemType Directory -Path $FlashDest -Force -ErrorAction SilentlyContinue | Out-Null }

$okDesktop = 0; $okFlash = 0; $missing = 0; $hashMismatch = 0

foreach ($item in $items) {
    $src = Join-Path $DocsSource $item.File
    if (-not (Test-Path -LiteralPath $src)) { W "MISS: $($item.File) not found in $DocsSource"; $missing++; continue }

    try {
        $actual = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.ToLower()
    } catch {
        W "ERROR: SHA256 calc failed for $src : $($_.Exception.Message)"
        continue
    }
    if ($actual -ne $item.Hash) {
        W "WARN: hash mismatch for $($item.File) - expected $($item.Hash), got $actual - copying anyway"
        $hashMismatch++
    }

    try {
        Copy-Item -LiteralPath $src -Destination (Join-Path $DesktopDest $item.File) -Force -ErrorAction Stop
        $okDesktop++
    } catch { W "ERROR: desktop copy failed for $($item.File): $($_.Exception.Message)" }

    if ($FlashDest) {
        try {
            Copy-Item -LiteralPath $src -Destination (Join-Path $FlashDest $item.File) -Force -ErrorAction Stop
            $okFlash++
        } catch { W "ERROR: flash copy failed for $($item.File): $($_.Exception.Message)" }
    }
}

W "=== deploy_docs finished: desktop=$okDesktop, flash=$okFlash, missing=$missing, hash-mismatch=$hashMismatch ==="
exit 0
