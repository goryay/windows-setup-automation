<#
.SYNOPSIS
    Patches a standard Windows boot.wim into IPDROM auto-capture WinPE.

    Takes a clean source boot.wim (from Windows installer ISO), copies it to
    output path, mounts it read-write, injects our startnet.cmd + winpeshl.ini
    into Windows\System32, commits and unmounts.

    Safe to re-run: a previous mount left dangling will be force-discarded.

.PARAMETER SourceWim
    Path to the input boot.wim. Required.

.PARAMETER OutputWim
    Path where to save the patched boot.wim. Required.

.PARAMETER Index
    WIM image index to patch. Default 1.

.PARAMETER WinpeFiles
    Folder containing startnet.cmd and winpeshl.ini. Default:
    <script dir>\..\winpe

.PARAMETER LogPath
    Where to write the operation log. Default in ProgramData\IPDROM\Logs.
#>
[CmdletBinding()]
param(
    # По умолчанию — забэндленный в репо boot.wim:
    #   D:\TestISO\customization\winpe\boot.wim
    [string]$SourceWim,
    # По умолчанию — рядом с source, имя boot_patched.wim:
    #   D:\TestISO\customization\winpe\boot_patched.wim
    [string]$OutputWim,
    [int]$Index = 1,
    [string]$WinpeFiles,
    [string]$LogPath
)

# ===================== APPLY DEFAULTS =====================
if (-not $WinpeFiles) {
    $WinpeFiles = Join-Path (Split-Path $PSScriptRoot -Parent) 'winpe'
}
if (-not $SourceWim) {
    $SourceWim = Join-Path $WinpeFiles 'boot.wim'
}
if (-not $OutputWim) {
    $OutputWim = Join-Path $WinpeFiles 'boot_patched.wim'
}

$ErrorActionPreference = 'Stop'

# ===================== LOG =====================
if (-not $LogPath) {
    $logDir = Join-Path $env:ProgramData 'IPDROM\Logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $LogPath = Join-Path $logDir ("patch_bootwim_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}

function Write-Log {
    param([string]$Msg, [string]$Color = 'White')
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
    Write-Host $Msg -ForegroundColor $Color
    try { $line | Out-File -FilePath $LogPath -Encoding utf8 -Append } catch {}
}

Write-Log "=== Patch-BootWim started ===" 'Cyan'
Write-Log "SourceWim:   $SourceWim"
Write-Log "OutputWim:   $OutputWim"
Write-Log "Index:       $Index"
Write-Log "Log:         $LogPath" 'Gray'

# ===================== VALIDATE INPUTS =====================
if (-not (Test-Path $SourceWim)) {
    Write-Log "Source WIM not found: $SourceWim" 'Red'
    exit 2
}

$startnetSrc  = Join-Path $WinpeFiles 'startnet.cmd'
$winpeshlSrc  = Join-Path $WinpeFiles 'winpeshl.ini'

foreach ($f in @($startnetSrc, $winpeshlSrc)) {
    if (-not (Test-Path $f)) {
        Write-Log "Required file missing: $f" 'Red'
        exit 3
    }
}
Write-Log "WinPE source files: $WinpeFiles" 'Gray'
Write-Log "  -> startnet.cmd  ($((Get-Item $startnetSrc).Length) bytes)" 'DarkGray'
Write-Log "  -> winpeshl.ini  ($((Get-Item $winpeshlSrc).Length) bytes)" 'DarkGray'

try {
    $dism = (Get-Command dism.exe -ErrorAction Stop).Source
} catch {
    Write-Log "dism.exe not found." 'Red'
    exit 4
}

# ===================== CLEAN UP OLD MOUNT (if any) =====================
$mountDir = Join-Path $env:TEMP "ipdrom_bootwim_mount_$(Get-Random)"
Write-Log "Cleaning up any stale WIM mounts..." 'Gray'
& $dism /Cleanup-Mountpoints 2>&1 | Out-Null

# ===================== COPY SOURCE TO OUTPUT =====================
Write-Log "Copying $SourceWim -> $OutputWim..." 'Yellow'
$outDir = Split-Path -Parent $OutputWim
if ($outDir -and -not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}
Copy-Item -LiteralPath $SourceWim -Destination $OutputWim -Force

# Remove read-only attribute (source WIM is often read-only on install media)
$attr = Get-Item $OutputWim
if ($attr.IsReadOnly) {
    $attr.IsReadOnly = $false
    Write-Log "Removed read-only attribute from output WIM." 'Gray'
}

# ===================== MOUNT =====================
New-Item -ItemType Directory -Force -Path $mountDir | Out-Null
Write-Log "Mounting WIM (index $Index) to $mountDir..." 'Yellow'

& $dism /Mount-Wim "/WimFile:$OutputWim" "/Index:$Index" "/MountDir:$mountDir" 2>&1 | ForEach-Object {
    Write-Log "  | $_" 'DarkGray'
}
if ($LASTEXITCODE -ne 0) {
    Write-Log "Mount failed (exit $LASTEXITCODE). Cleaning up." 'Red'
    Remove-Item -LiteralPath $mountDir -Force -Recurse -ErrorAction SilentlyContinue
    exit 5
}

# ===================== PATCH FILES =====================
$mounted = $true
try {
    $system32 = Join-Path $mountDir 'Windows\System32'
    if (-not (Test-Path $system32)) {
        throw "Mounted WIM does not have Windows\System32 — wrong index?"
    }

    # Backup originals before overwrite (for forensics)
    foreach ($name in @('startnet.cmd', 'winpeshl.ini')) {
        $orig = Join-Path $system32 $name
        if (Test-Path $orig) {
            $bak = "$orig.original"
            if (-not (Test-Path $bak)) {
                Copy-Item -LiteralPath $orig -Destination $bak -Force
                Write-Log "Backed up original $name -> $name.original" 'Gray'
            }
        }
    }

    Write-Log "Injecting startnet.cmd..." 'Yellow'
    Copy-Item -LiteralPath $startnetSrc -Destination (Join-Path $system32 'startnet.cmd') -Force

    Write-Log "Injecting winpeshl.ini..." 'Yellow'
    Copy-Item -LiteralPath $winpeshlSrc -Destination (Join-Path $system32 'winpeshl.ini') -Force

    # Verify the patch
    $startnetDst = Join-Path $system32 'startnet.cmd'
    $winpeshlDst = Join-Path $system32 'winpeshl.ini'
    Write-Log "Patched startnet.cmd size:  $((Get-Item $startnetDst).Length) bytes" 'Gray'
    Write-Log "Patched winpeshl.ini size: $((Get-Item $winpeshlDst).Length) bytes" 'Gray'

    Write-Log "Patch successful. Committing WIM..." 'Yellow'
} catch {
    Write-Log "Patch failed: $_" 'Red'
    Write-Log "Unmounting with /Discard..." 'Yellow'
    & $dism /Unmount-Wim "/MountDir:$mountDir" /Discard 2>&1 | Out-Null
    Remove-Item -LiteralPath $mountDir -Force -Recurse -ErrorAction SilentlyContinue
    exit 6
}

# ===================== COMMIT =====================
& $dism /Unmount-Wim "/MountDir:$mountDir" /Commit 2>&1 | ForEach-Object {
    Write-Log "  | $_" 'DarkGray'
}
if ($LASTEXITCODE -ne 0) {
    Write-Log "Commit failed (exit $LASTEXITCODE). WIM may be corrupted." 'Red'
    & $dism /Cleanup-Mountpoints 2>&1 | Out-Null
    Remove-Item -LiteralPath $mountDir -Force -Recurse -ErrorAction SilentlyContinue
    exit 7
}

Remove-Item -LiteralPath $mountDir -Force -Recurse -ErrorAction SilentlyContinue

$finalSize = [math]::Round((Get-Item $OutputWim).Length / 1MB, 1)
Write-Log "=== Patch-BootWim completed successfully ===" 'Green'
Write-Log "Output: $OutputWim ($finalSize MB)" 'Green'
exit 0
