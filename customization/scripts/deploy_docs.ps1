[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$SLConfigPath,
    [Parameter(Mandatory)] [string]$DocsSource,
    [Parameter(Mandatory)] [string]$DesktopDest,
    [string]$FlashDest  = '',
    [string]$ServerBase = 'http://10.0.6.41:3000'
)

# =============================================================================
# Documentation delivery.
#
# 2026-10-06, production request: documents must come from the DATA SERVER, not
# from a folder that has to be kept in sync by hand.
#
#   GET <ServerBase>/hash/documentation/      -> JSON {"<file name>":"<md5>"}
#   GET <ServerBase>/dl/documentation/<name>  -> the file itself (name must be
#                                                percent-encoded; names are
#                                                Russian and contain spaces)
#
# TWO DIFFERENT HASHES ARE IN PLAY, and that is deliberate, not a mistake:
#   * the SL config "doc=" line carries SHA256 (64 hex) - it states WHICH
#     document version this particular machine must receive;
#   * the server catalogue carries MD5 (32 hex) - it states what the server
#     currently holds, and proves a download arrived intact.
# Verified on 2026-10-06 against "RE Servery IPDROM_v2.pdf" (6439545 bytes):
# both hashes match the same content. So we check both - MD5 catches a broken
# transfer, SHA256 catches the wrong document version.
#
# BEHAVIOUR CHANGE: a SHA256 mismatch now BLOCKS the copy. The previous version
# logged a warning and copied the file anyway, which defeats the point - a
# mismatching hash means it is not the document the config asked for, and that
# document ships to the customer.
#
# The local DocsSource folder is kept as a FALLBACK only. A data-server outage
# must not stop a build; it just means the documents come from the share, as
# before, and that is recorded in the log.
# =============================================================================

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'   # PS 5.1 progress bar makes downloads crawl

$logDir = Join-Path $env:ProgramData 'IPDROM\Logs'
New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
$logFile = Join-Path $logDir ("deploy_docs_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function W { param([string]$m) $line = '[{0}] {1}' -f (Get-Date -f 'yyyy-MM-dd HH:mm:ss'),$m; Add-Content -Path $logFile -Value $line -Encoding utf8; Write-Host $line }

W "=== deploy_docs started ==="
W "SLConfig:    $SLConfigPath"
W "DocsSource:  $DocsSource (fallback)"
W "DesktopDest: $DesktopDest"
W ("FlashDest:   " + $(if ($FlashDest) { $FlashDest } else { '<none>' }))
W "ServerBase:  $ServerBase"

if (-not (Test-Path -LiteralPath $SLConfigPath)) { W "FATAL: SL config not found."; exit 1 }

# --- 1. Which documents does this machine need -------------------------------
$docLine = $null
foreach ($line in (Get-Content -LiteralPath $SLConfigPath -Encoding UTF8)) {
    if ($line -match '^\s*doc\s*=\s*(.+)$') { $docLine = $matches[1].Trim(); break }
}
if (-not $docLine) { W "No doc= line in SL config. Nothing to deploy."; exit 0 }

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
if ($items.Count -eq 0) { W "Nothing to deliver."; exit 0 }

# --- 2. Server catalogue (non-fatal) -----------------------------------------
# Kept in a hashtable keyed by the exact file name, plus a lower-cased index so
# a difference in letter case between config and server does not lose a file.
$catalogue = @{}
$catLower  = @{}
$serverUp  = $false
$hashUrl   = ($ServerBase.TrimEnd('/')) + '/hash/documentation/'
try {
    $resp = Invoke-WebRequest -Uri $hashUrl -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
    $json = $resp.Content | ConvertFrom-Json -ErrorAction Stop
    foreach ($p in $json.PSObject.Properties) {
        $catalogue[$p.Name] = "$($p.Value)".ToLower()
        $catLower[$p.Name.ToLower()] = $p.Name
    }
    $serverUp = $true
    W "Server catalogue: $($catalogue.Count) document(s) listed at $hashUrl"
} catch {
    W "WARN: server catalogue unreachable ($hashUrl): $($_.Exception.Message)"
    W "WARN: falling back to the local folder for every document."
}

# --- 3. Staging --------------------------------------------------------------
# Nothing reaches Desktop/flash until it has passed SHA256. Download into a
# temporary folder first, so a failed check leaves the destinations untouched.
$stage = Join-Path $env:TEMP ("ipdrom_docs_{0}" -f (Get-Date -Format 'yyyyMMddHHmmss'))
New-Item -ItemType Directory -Path $stage -Force -ErrorAction SilentlyContinue | Out-Null

New-Item -ItemType Directory -Path $DesktopDest -Force -ErrorAction SilentlyContinue | Out-Null
if ($FlashDest) { New-Item -ItemType Directory -Path $FlashDest -Force -ErrorAction SilentlyContinue | Out-Null }

$okDesktop = 0; $okFlash = 0; $failed = 0
$fromServer = 0; $fromLocal = 0

foreach ($item in $items) {
    $verified = $null    # path to a file that passed SHA256

    # --- 3a. Preferred source: the data server -------------------------------
    if ($serverUp) {
        $serverName = $null
        if ($catalogue.ContainsKey($item.File)) {
            $serverName = $item.File
        } elseif ($catLower.ContainsKey($item.File.ToLower())) {
            $serverName = $catLower[$item.File.ToLower()]
            W "NOTE: '$($item.File)' matched server entry '$serverName' by case-insensitive name."
        }

        if (-not $serverName) {
            W "NOTE: '$($item.File)' is not in the server catalogue - will try the local folder."
        } else {
            $dlUrl = ($ServerBase.TrimEnd('/')) + '/dl/documentation/' + [uri]::EscapeDataString($serverName)
            $tmp   = Join-Path $stage ([IO.Path]::GetFileName($item.File))
            try {
                Invoke-WebRequest -Uri $dlUrl -OutFile $tmp -TimeoutSec 300 -UseBasicParsing -ErrorAction Stop

                $md5 = (Get-FileHash -LiteralPath $tmp -Algorithm MD5).Hash.ToLower()
                if ($md5 -ne $catalogue[$serverName]) {
                    W "ERROR: '$($item.File)' download corrupted - server MD5 $($catalogue[$serverName]), got $md5. Discarding."
                    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                } else {
                    $sha = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLower()
                    if ($sha -ne $item.Hash) {
                        W "ERROR: '$($item.File)' from server is the WRONG VERSION - config SHA256 $($item.Hash), got $sha. Discarding."
                        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                    } else {
                        $sizeKB = [math]::Round((Get-Item -LiteralPath $tmp).Length / 1KB, 1)
                        W "OK (server): '$($item.File)' $sizeKB KB, MD5 and SHA256 both match."
                        $verified = $tmp
                        $fromServer++
                    }
                }
            } catch {
                W "WARN: download failed for '$($item.File)': $($_.Exception.Message)"
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # --- 3b. Fallback: the local folder --------------------------------------
    if (-not $verified) {
        $src = Join-Path $DocsSource $item.File
        if (-not (Test-Path -LiteralPath $src)) {
            W "FAIL: '$($item.File)' unavailable - not delivered by the server and not found in $DocsSource"
            $failed++
            continue
        }
        try {
            $sha = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.ToLower()
        } catch {
            W "FAIL: SHA256 calc failed for $src : $($_.Exception.Message)"
            $failed++
            continue
        }
        if ($sha -ne $item.Hash) {
            # Deliberately NOT copied. See the behaviour-change note in the header.
            W "FAIL: local copy of '$($item.File)' is the WRONG VERSION - config SHA256 $($item.Hash), got $sha. NOT copied."
            $failed++
            continue
        }
        W "OK (local fallback): '$($item.File)' SHA256 matches."
        $verified = $src
        $fromLocal++
    }

    # --- 3c. Deliver ---------------------------------------------------------
    try {
        Copy-Item -LiteralPath $verified -Destination (Join-Path $DesktopDest $item.File) -Force -ErrorAction Stop
        $okDesktop++
    } catch { W "ERROR: desktop copy failed for '$($item.File)': $($_.Exception.Message)" }

    if ($FlashDest) {
        try {
            Copy-Item -LiteralPath $verified -Destination (Join-Path $FlashDest $item.File) -Force -ErrorAction Stop
            $okFlash++
        } catch { W "ERROR: flash copy failed for '$($item.File)': $($_.Exception.Message)" }
    }
}

Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue

W "=== deploy_docs finished: requested=$($items.Count), desktop=$okDesktop, flash=$okFlash, from-server=$fromServer, from-local=$fromLocal, failed=$failed ==="

# Non-zero tells the caller a required document did not reach the machine.
# deploy_extras currently only logs this; wiring it to the pipeline health gate
# is a separate decision.
if ($failed -gt 0) { exit 2 }
exit 0
