param(
    [string]$BackupLabel = 'IPDROM_BACKUP'
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Color = 'White')
    Write-Host $Message -ForegroundColor $Color
}

try {
    $wbadmin = Get-Command wbadmin.exe -ErrorAction Stop
} catch {
    Write-Error 'wbadmin.exe not found on this system.'
    exit 2
}

$backupVolume = Get-Volume -ErrorAction SilentlyContinue |
    Where-Object { $_.FileSystemLabel -eq $BackupLabel -and $_.DriveLetter } |
    Select-Object -First 1

if (-not $backupVolume) {
    Write-Warning "Backup drive with label '$BackupLabel' not found. Full backup skipped."
    exit 0
}

$backupTarget = "$($backupVolume.DriveLetter):"
$programDataRoot = Join-Path $env:ProgramData 'IPDROM'
$logDir = Join-Path $programDataRoot 'Logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

$logFile = Join-Path $logDir ("full_backup_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$markerFile = Join-Path $logDir 'full_backup_last_success.txt'

Write-Log "Backup target: $backupTarget" 'Gray'
Write-Log "Log file: $logFile" 'Gray'
"=== FULL BACKUP START $(Get-Date -Format s) ===" | Out-File -FilePath $logFile -Encoding utf8

# Sanity checks
if ($backupTarget.TrimEnd('\') -ieq $env:SystemDrive.TrimEnd('\')) {
    Write-Error 'Backup target cannot be the system drive.'
    exit 3
}

if ($backupVolume.FileSystem -ne 'NTFS') {
    Write-Warning "Backup drive file system is '$($backupVolume.FileSystem)'. NTFS is recommended for wbadmin targets."
}

& $wbadmin.Source start backup -backupTarget:$backupTarget -allCritical -quiet *>> $logFile
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    Write-Error "wbadmin failed with exit code $exitCode. See $logFile"
    exit $exitCode
}

$computerName = $env:COMPUTERNAME
$wibPath = Join-Path $backupTarget "WindowsImageBackup\$computerName"
if (Test-Path $wibPath) {
    "SUCCESS $(Get-Date -Format s) :: $wibPath" | Out-File -FilePath $markerFile -Encoding utf8
}

Write-Log "Full backup completed successfully to $backupTarget" 'Green'
exit 0
