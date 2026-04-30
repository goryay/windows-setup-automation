param(
    [string]$ComputerName = $env:COMPUTERNAME,
    [string]$OutputFolder,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

function Find-SmartCtl {
    $candidates = @(
        'C:\Program Files\smartmontools\bin\smartctl.exe',
        'C:\Program Files (x86)\smartmontools\bin\smartctl.exe'
    )

    $cmd = Get-Command smartctl.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { $candidates = @($cmd.Source) + $candidates }

    foreach ($path in $candidates | Select-Object -Unique) {
        if ($path -and (Test-Path $path)) { return $path }
    }
    return $null
}

function Get-FirstMatchValue {
    param(
        [string]$Text,
        [string[]]$Patterns
    )
    foreach ($pattern in $Patterns) {
        $m = [regex]::Match($Text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)
        if ($m.Success) { return $m.Groups[1].Value.Trim() }
    }
    return $null
}

$smartctlPath = Find-SmartCtl
if (-not $smartctlPath) {
    Write-Warning 'smartctl.exe not found. SMART report skipped.'
    exit 0
}

if (-not $OutputFolder) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $baseFolder = Join-Path $desktop $ComputerName
    $OutputFolder = Join-Path $baseFolder 'Reports'
}
New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null

$diskLines = @(& $smartctlPath --scan-open 2>$null)
if (-not $diskLines -or $diskLines.Count -eq 0) {
    $diskLines = @(& $smartctlPath --scan 2>$null)
}
$diskIds = @($diskLines | ForEach-Object { ($_ -split '\s+')[0].Trim() } | Where-Object { $_ }) | Select-Object -Unique

if (-not $diskIds -or $diskIds.Count -eq 0) {
    Write-Warning 'No disks found by smartctl. SMART report skipped.'
    exit 0
}

$report = foreach ($disk in $diskIds) {
    try {
        $diskInfo = & $smartctlPath --all $disk 2>&1 | Out-String
    } catch {
        $diskInfo = $_ | Out-String
    }

    $type = if ($diskInfo -match 'NVMe') { 'NVMe' } else { 'SATA/HDD' }
    $temp = if ($type -eq 'NVMe') {
        Get-FirstMatchValue -Text $diskInfo -Patterns @('(?m)^Temperature:\s*([^\r\n]+)')
    } else {
        Get-FirstMatchValue -Text $diskInfo -Patterns @('(?m)^194\s+Temperature_Celsius\s+.+?-\s+([0-9]+)', '(?m)^190\s+Airflow_Temperature_Cel\s+.+?-\s+([0-9]+)')
    }

    [pscustomobject]@{
        Disk = $disk
        Type = $type
        Model = Get-FirstMatchValue -Text $diskInfo -Patterns @('(?m)^Device Model:\s*(.+)$','(?m)^Model Number:\s*(.+)$','(?m)^Product:\s*(.+)$')
        Serial = Get-FirstMatchValue -Text $diskInfo -Patterns @('(?m)^Serial Number:\s*(.+)$')
        Health = Get-FirstMatchValue -Text $diskInfo -Patterns @('(?m)^SMART overall-health self-assessment test result:\s*(.+)$','(?m)^SMART Health Status:\s*(.+)$','(?m)^SMART overall-health self-assessment test result:\s*(.+)$')
        Temperature = $temp
        PowerOnHours = Get-FirstMatchValue -Text $diskInfo -Patterns @('(?m)^Power On Hours:\s*(.+)$','(?m)^9\s+Power_On_Hours\s+.+?-\s+([0-9]+)')
        MediaErrors = Get-FirstMatchValue -Text $diskInfo -Patterns @('(?m)^Media and Data Integrity Errors:\s*(.+)$')
        ReallocatedSectors = Get-FirstMatchValue -Text $diskInfo -Patterns @('(?m)^5\s+Reallocated_Sector_Ct\s+.+?-\s+([0-9]+)')
        PendingSectors = Get-FirstMatchValue -Text $diskInfo -Patterns @('(?m)^197\s+Current_Pending_Sector\s+.+?-\s+([0-9]+)')
        SMARTData = $diskInfo
    }
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$csvReport = Join-Path $OutputFolder "SMART_Report_All_Disks_$stamp.csv"
$fullReport = Join-Path $OutputFolder "SMART_Full_Details_$stamp.txt"

$report | Select-Object * -ExcludeProperty SMARTData | Export-Csv -Path $csvReport -NoTypeInformation -Encoding UTF8
$report | ForEach-Object {
    "===== $($_.Disk) ($($_.Type)) ====="
    $_.SMARTData
    ''
} | Out-File -FilePath $fullReport -Encoding UTF8

Write-Host "SMART reports saved:" -ForegroundColor Green
Write-Host "  CSV:  $csvReport" -ForegroundColor Cyan
Write-Host "  Full: $fullReport" -ForegroundColor Cyan

if (-not $NoPause) {
    Start-Sleep -Seconds 2
}
exit 0
