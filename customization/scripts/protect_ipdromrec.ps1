[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$logDir = Join-Path $env:ProgramData 'IPDROM\Logs'
New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
$logFile = Join-Path $logDir ("protect_ipdromrec_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function W { param([string]$m) $line = '[{0}] {1}' -f (Get-Date -f 'yyyy-MM-dd HH:mm:ss'),$m; Add-Content -Path $logFile -Value $line -Encoding utf8; Write-Host $line }

# Drop QuickEdit mode for THIS console immediately. Registry (set by
# disable_autolock before FFU capture) already disables it for new consoles, but
# this is belt-and-suspenders for the exact console that hung 12 hours on run
# 005: with QuickEdit on, any click/selection in the window freezes the process
# until a key is pressed. SetConsoleMode strips ENABLE_QUICK_EDIT_MODE (0x40)
# while keeping ENABLE_EXTENDED_FLAGS (0x80) so the change takes effect. Wrapped
# in try/catch: if launched without a real console, this simply no-ops.
try {
    if (-not ('IPDROM.Con' -as [type])) {
        Add-Type -Namespace IPDROM -Name Con -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetStdHandle(int nStdHandle);
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool GetConsoleMode(System.IntPtr hConsoleHandle, out uint lpMode);
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool SetConsoleMode(System.IntPtr hConsoleHandle, uint dwMode);
'@
    }
    $conIn = [IPDROM.Con]::GetStdHandle(-10)   # STD_INPUT_HANDLE
    $conMode = [uint32]0
    if ([IPDROM.Con]::GetConsoleMode($conIn, [ref]$conMode)) {
        $conMode = ($conMode -band (-bnot [uint32]0x40)) -bor [uint32]0x80
        [void][IPDROM.Con]::SetConsoleMode($conIn, $conMode)
        W "QuickEdit disabled for this console (SetConsoleMode) - no freeze-on-click."
    }
} catch { }

$stateDir   = Join-Path $env:ProgramData 'IPDROM\State'
$markerFlag = Join-Path $stateDir 'IpdromREC_Protected.flag'
$taskName   = 'IPDROM_ProtectRec'

W "=== protect_ipdromrec started ==="

if (Test-Path -LiteralPath $markerFlag) {
    W "Already protected (marker $markerFlag exists). Unregistering task and exiting."
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    exit 0
}

# Give USB / disk stack time to enumerate after boot
W "Waiting 15s for disk enumeration..."
Start-Sleep -Seconds 15

# Find IpdromREC volume
$recVol = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.FileSystemLabel -eq 'IpdromREC' } | Select-Object -First 1
if (-not $recVol) {
    W "IpdromREC volume not found. Cannot protect. (Was FFU capture actually successful?)"
    exit 1
}
$recLetter = $recVol.DriveLetter
if (-not $recLetter) { W "IpdromREC volume has no drive letter. Cannot verify FFU."; exit 1 }
$recRoot = "$($recLetter):\"

$ffuPath    = Join-Path $recRoot 'restore.ffu'
$failedPath = Join-Path $recRoot '.capture_failed'

if (Test-Path -LiteralPath $failedPath) {
    W "Found .capture_failed marker on IpdromREC. FFU capture failed - REFUSING to protect."
    exit 1
}
if (-not (Test-Path -LiteralPath $ffuPath)) {
    W "restore.ffu not found on $recRoot - REFUSING to protect."
    exit 1
}
$ffuSize = (Get-Item -LiteralPath $ffuPath).Length
$ffuGB   = [math]::Round($ffuSize / 1GB, 2)
W ("restore.ffu found: {0} GB" -f $ffuGB)
if ($ffuGB -lt 5) {
    W "restore.ffu is suspiciously small ($ffuGB GB) - REFUSING to protect for safety."
    exit 1
}

# Get disk number
$part = Get-Partition -DriveLetter $recLetter -ErrorAction SilentlyContinue
if (-not $part) { W "Cannot find partition for ${recLetter}:"; exit 1 }
$diskNum = $part.DiskNumber

# Safety: confirm target disk is USB before touching it
$disk = Get-Disk -Number $diskNum -ErrorAction SilentlyContinue
if (-not $disk) { W "Cannot get Disk $diskNum info."; exit 1 }
$busType = "$($disk.BusType)"
W "Target disk: $diskNum bus=$busType friendly='$($disk.FriendlyName)'"
if ($busType -ne 'USB') {
    W "*** REFUSING to set readonly on non-USB disk (BusType='$busType'). Aborting for safety."
    exit 1
}

# Enumerate partitions to hide them from Windows Explorer before locking readonly
# Sequence in diskpart: remove drive letters -> set GPT 'no auto-letter' attribute
# (persists across reboots) -> lock whole disk readonly (must be LAST — after this
# no more writes possible). UEFI-boot from EFI partition and WinPE-side FFU restore
# (label-based lookup via Get-Volume -FileSystemLabel) both keep working.
$partitions = @(Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue | Sort-Object PartitionNumber)
W "Partitions on disk $diskNum to hide: $($partitions.Count)"
foreach ($p in $partitions) {
    $letter = if ($p.DriveLetter) { "$($p.DriveLetter):" } else { '<none>' }
    W "  #$($p.PartitionNumber) letter=$letter size=$([math]::Round($p.Size / 1MB, 1)) MB"
}

$dpLines = @("select disk $diskNum")
foreach ($p in $partitions) {
    $dpLines += "select partition $($p.PartitionNumber)"
    $dpLines += "remove noerr"
    $dpLines += "gpt attributes=0x8000000000000000"
}
$dpLines += "select disk $diskNum"
$dpLines += "attributes disk set readonly"
$dpLines += "exit"

$scriptFile = Join-Path $env:TEMP 'ipdrom_protect_rec.txt'
($dpLines -join "`r`n") | Set-Content -LiteralPath $scriptFile -Encoding ascii

W "Running: diskpart /s $scriptFile (hide partitions from Explorer, then set disk readonly)"
$dpOut = & diskpart.exe /s $scriptFile 2>&1
foreach ($l in $dpOut) { W "  | $l" }
$dpExit = $LASTEXITCODE
Remove-Item -LiteralPath $scriptFile -Force -ErrorAction SilentlyContinue

if ($dpExit -ne 0) {
    W "diskpart returned exit=$dpExit - protect FAILED."
    exit 1
}

# Marker + cleanup
New-Item -ItemType Directory -Path $stateDir -Force -ErrorAction SilentlyContinue | Out-Null
$markerContent = @"
Protected at $(Get-Date -Format 's')
Disk number: $diskNum
FriendlyName: $($disk.FriendlyName)
FFU size:    $ffuGB GB
"@
Set-Content -LiteralPath $markerFlag -Value $markerContent -Encoding utf8

W "=== IpdromREC flash successfully protected. Marker: $markerFlag ==="

# Self-remove scheduled task
try {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    W "Unregistered scheduled task '$taskName'."
} catch {}

exit 0
