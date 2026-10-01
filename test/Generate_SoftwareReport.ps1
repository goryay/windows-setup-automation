param(
    [string]$ComputerName,
    [string]$OutputFolder,
    [switch]$IncludeSoftware
)

if (-not $ComputerName) { $ComputerName = $env:COMPUTERNAME }
if (-not $OutputFolder) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $OutputFolder = Join-Path (Join-Path $desktop $ComputerName) 'Reports'
}
New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null

$ts = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$ReportPath = Join-Path $OutputFolder "Software_Report_$ts.html"

$ErrorActionPreference = 'Stop'

# ---------- helpers ----------

function ConvertTo-Size {
    param([uint64]$Bytes)
    if ($Bytes -ge 1PB) { '{0:N1} ПБ' -f ($Bytes/1PB) }
    elseif ($Bytes -ge 1TB) { '{0:N2} ТБ' -f ($Bytes/1TB) }
    elseif ($Bytes -ge 1GB) { '{0:N1} ГБ' -f ($Bytes/1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N1} МБ' -f ($Bytes/1MB) }
    elseif ($Bytes -ge 1KB) { '{0:N1} КБ' -f ($Bytes/1KB) }
    else { "$Bytes Б" }
}

function HtmlEnc {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return ($Text -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;')
}

function Pre {
    param([string]$Text)
    return "<pre>$(HtmlEnc $Text)</pre>"
}

function Try-Dmtf {
    param([string]$Dmtf, [string]$Format = 'yyyy-MM-dd')
    if ([string]::IsNullOrWhiteSpace($Dmtf)) { return '-' }
    try {
        $dt = [System.Management.ManagementDateTimeConverter]::ToDateTime($Dmtf)
        if ($dt -is [datetime] -and $dt.Year -gt 1601) { return $dt.ToString($Format) }
    } catch {}
    return '-'
}

function Get-UptimeSpan {
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        if ($os.LastBootUpTime) {
            return (New-TimeSpan -Start $os.LastBootUpTime -End (Get-Date))
        }
    } catch {}
    return New-TimeSpan -Seconds 0
}

function Section {
    param(
        [string]$Id,
        [string]$Title,
        [string]$BodyHtml,
        [switch]$NoCollapse
    )
    if ($NoCollapse) {
        return @"
<div id="$Id" class="section">
    <h2>$Title</h2>
    $BodyHtml
</div>
"@
    }
    return @"
<div id="$Id" class="section">
    <h2 onclick='toggleVisibility(this)' style='cursor:pointer;'>$Title</h2>
    <div class='desktop-items-container' style='display:none;'>
        $BodyHtml
    </div>
</div>
"@
}

function SubBlock {
    param([string]$Title, [string]$BodyHtml, [string]$Tag = 'h3')
    return @"
<$Tag onclick='toggleVisibility(this)' style='cursor:pointer;'>$Title</$Tag>
<div class='desktop-items-container' style='display:none;'>
    $BodyHtml
</div>
"@
}

# ---------- data collectors ----------

function Get-UninstallEntries {
    param([switch]$IncludeSystemComponents = $false)

    $views = @(
        [Microsoft.Win32.RegistryView]::Registry64,
        [Microsoft.Win32.RegistryView]::Registry32
    )
    $hives = @(
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; Paths = @('Software\Microsoft\Windows\CurrentVersion\Uninstall') },
        @{ Hive = [Microsoft.Win32.RegistryHive]::CurrentUser;  Paths = @('Software\Microsoft\Windows\CurrentVersion\Uninstall') }
    )

    $results = @()
    foreach ($view in $views) {
        foreach ($h in $hives) {
            try {
                $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($h.Hive, $view)
                foreach ($relPath in $h.Paths) {
                    try {
                        $key = $base.OpenSubKey($relPath)
                        if (-not $key) { continue }
                        foreach ($subName in $key.GetSubKeyNames()) {
                            try {
                                $sk = $key.OpenSubKey($subName)
                                if (-not $sk) { continue }
                                $name = $sk.GetValue('DisplayName')
                                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                                $ver   = $sk.GetValue('DisplayVersion')
                                $pub   = $sk.GetValue('Publisher')
                                $rtype = $sk.GetValue('ReleaseType')
                                $scomp = $sk.GetValue('SystemComponent')
                                $instDt = $sk.GetValue('InstallDate')
                                $uninst = $sk.GetValue('UninstallString')

                                if (-not $IncludeSystemComponents) {
                                    if ($scomp -eq 1) { continue }
                                    if ($rtype -match 'Update|Hotfix') { continue }
                                    if ($name -match '^(Security Update|Update for|KB\d+)') { continue }
                                }

                                $scope = if ($h.Hive -eq [Microsoft.Win32.RegistryHive]::CurrentUser) { 'User' } else { 'Machine' }
                                $viewStr = if ($view -eq [Microsoft.Win32.RegistryView]::Registry64) { 'x64' } else { 'x86' }

                                $results += [pscustomobject]@{
                                    Name        = $name
                                    Version     = $ver
                                    Publisher   = $pub
                                    InstallDate = $instDt
                                    Uninstall   = $uninst
                                    Scope       = $scope
                                    View        = $viewStr
                                }
                            } catch {}
                        }
                    } catch {}
                }
            } catch {}
        }
    }
    $results
}

# ---------- HTML section builders ----------

function Build-ServerInfo {
    $os    = try { Get-CimInstance Win32_OperatingSystem } catch { $null }
    $cs    = try { Get-CimInstance Win32_ComputerSystem  } catch { $null }
    $bios  = try { Get-CimInstance Win32_BIOS            } catch { $null }
    $bb    = try { Get-CimInstance Win32_BaseBoard       } catch { $null }
    $cpu   = try { (Get-CimInstance Win32_Processor)[0]  } catch { $null }
    $gpus  = try { @(Get-CimInstance Win32_VideoController) } catch { @() }
    $mem   = try { @(Get-CimInstance Win32_PhysicalMemory)  } catch { @() }
    $vdisk = try { @(Get-CimInstance MSFT_VirtualDisk -Namespace 'Root\Microsoft\Windows\Storage') } catch { @() }
    $pd    = try { @(Get-PhysicalDisk) } catch { @() }
    $bat   = try { @(Get-CimInstance Win32_Battery) } catch { @() }

    $serial = if ($bios) { $bios.SerialNumber } else { '-' }
    if ([string]::IsNullOrWhiteSpace($serial) -or $serial -eq 'To Be Filled By O.E.M.') {
        $serial = if ($bb) { $bb.SerialNumber } else { '-' }
    }
    $model = if ($cs -and $cs.Model) { "$($cs.Manufacturer) $($cs.Model)" } else { '-' }

    $osLine = if ($os) { "$($os.Caption) $($os.OSArchitecture), сборка $($os.BuildNumber)" } else { '-' }

    $bbLine = if ($bb) {
        "Модель: $($bb.Product), Серийный номер: $($bb.SerialNumber), Версия BIOS: $($bios.SMBIOSBIOSVersion) ($(Try-Dmtf $bios.ReleaseDate))"
    } else { '-' }

    $cpuLine = if ($cpu) {
        $ht = if ($cpu.NumberOfLogicalProcessors -gt $cpu.NumberOfCores) { 'Включён' } else { 'Выключен' }
        "$($cpu.Name) | Ядра: $($cpu.NumberOfCores) | Потоки: $($cpu.NumberOfLogicalProcessors) | Hyper-Threading: $ht | Макс. частота: $($cpu.MaxClockSpeed) МГц"
    } else { '-' }

    $totalRam = ($mem | Measure-Object -Property Capacity -Sum).Sum
    $ramTotalStr = if ($totalRam) { ConvertTo-Size ([uint64]$totalRam) } else { '-' }
    $modules = @()
    foreach ($m in $mem) {
        $cap = if ($m.Capacity) { ConvertTo-Size ([uint64]$m.Capacity) } else { '-' }
        $spd = if ($m.Speed) { "$($m.Speed) МГц" } else { '-' }
        $modules += "$cap $($m.Manufacturer) $($m.PartNumber) $($m.DeviceLocator) $spd"
    }
    $ramLine = if ($modules.Count -gt 0) {
        "$ramTotalStr ($($mem.Count) шт: $($modules -join '; '))"
    } else { $ramTotalStr }

    $gpuLine = if ($gpus.Count -gt 0) {
        ($gpus | ForEach-Object { $_.Name }) -join '; '
    } else { 'Графический адаптер не определён' }

    $raidRows = @()
    if ($vdisk.Count -gt 0) {
        foreach ($vd in $vdisk) {
            $sz = if ($vd.Size) { ConvertTo-Size ([uint64]$vd.Size) } else { '-' }
            $raidRows += "<span style='color:#04a3ff9d;'>Имя:</span> $($vd.FriendlyName) <span style='color:#04a3ff9d;'>Тип:</span> $($vd.ResiliencySettingName) <span style='color:#04a3ff9d;'>Состояние:</span> $($vd.HealthStatus) <span style='color:#04a3ff9d;'>Размер:</span> $sz"
        }
    }
    $raidHtml = if ($raidRows.Count -gt 0) { ($raidRows -join '<br>') } else { 'Storage Spaces не настроены' }

    $sysDrive = $env:SystemDrive
    $sysVol = try { Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$sysDrive'" } catch { $null }
    $sysLine = if ($sysVol) {
        $sz = ConvertTo-Size ([uint64]$sysVol.Size)
        $fr = ConvertTo-Size ([uint64]$sysVol.FreeSpace)
        "Диск $($sysVol.DeviceID) ($($sysVol.FileSystem)), $sz всего, $fr свободно"
    } else { '-' }

    $pdRows = @()
    $idx = 0
    foreach ($d in $pd) {
        $sz = if ($d.Size) { ConvertTo-Size ([uint64]$d.Size) } else { '-' }
        $bus = $d.BusType
        $media = $d.MediaType
        $sn = if ($d.SerialNumber) { $d.SerialNumber.Trim() } else { '-' }
        $pdRows += "<span style='color:#04a3ff9d;'>Disk${idx}:</span> $($d.FriendlyName) <span style='color:#04a3ff9d;'>SN:</span> $sn <span style='color:#04a3ff9d;'>Bus:</span> $bus <span style='color:#04a3ff9d;'>Media:</span> $media <span style='color:#04a3ff9d;'>Size:</span> $sz <span style='color:#04a3ff9d;'>Health:</span> $($d.HealthStatus)"
        $idx++
    }
    $pdRowsHtml = ''
    if ($pdRows.Count -gt 0) {
        $first = $pdRows[0]
        $pdRowsHtml += "<tr><td rowspan='$($pdRows.Count)'>Физические диски</td><td>$first</td></tr>"
        for ($i = 1; $i -lt $pdRows.Count; $i++) {
            $pdRowsHtml += "<tr><td>$($pdRows[$i])</td></tr>"
        }
    } else {
        $pdRowsHtml = "<tr><td>Физические диски</td><td>-</td></tr>"
    }

    $batLine = if ($bat.Count -gt 0) {
        ($bat | ForEach-Object { "$($_.Name) $($_.EstimatedChargeRemaining)% статус=$($_.BatteryStatus)" }) -join '; '
    } else { 'Аккумулятор не обнаружен (стационарный ПК / питание от сети)' }

    $uptime = Get-UptimeSpan
    $uptStr = '{0}д {1}ч {2}м' -f $uptime.Days, $uptime.Hours, $uptime.Minutes

    $tableHtml = @"
<table border="2" style="inline-size: 100%; font-size: 16px;">
    <tr><td>Серийный номер</td><td>$(HtmlEnc $serial)</td></tr>
    <tr><td>Модель</td><td>$(HtmlEnc $model)</td></tr>
    <tr><td>Операционная система</td><td>$(HtmlEnc $osLine)</td></tr>
    <tr><td>Материнская плата</td><td>$(HtmlEnc $bbLine)</td></tr>
    <tr><td>Процессор</td><td>$(HtmlEnc $cpuLine)</td></tr>
    <tr><td>Оперативная память</td><td>$(HtmlEnc $ramLine)</td></tr>
    <tr><td>Действующая графика</td><td>$(HtmlEnc $gpuLine)</td></tr>
    <tr><td>Storage Spaces / RAID</td><td>$raidHtml</td></tr>
    $pdRowsHtml
    <tr><td>Системный диск</td><td>$(HtmlEnc $sysLine)</td></tr>
    <tr><td>Аккумулятор / питание</td><td>$(HtmlEnc $batLine)</td></tr>
    <tr><td>Время работы</td><td>$(HtmlEnc $uptStr)</td></tr>
</table>
"@
    return $tableHtml
}

function Build-Disks {
    $lsblkLines = @()
    $lsblkLines += ('{0,-20} {1,-10} {2,-10} {3,-12} {4}' -f 'NAME','SIZE','TYPE','FS','MOUNTPOINT')
    $disks = try { @(Get-Disk) } catch { @() }
    foreach ($d in $disks) {
        $sz = if ($d.Size) { ConvertTo-Size ([uint64]$d.Size) } else { '-' }
        $lsblkLines += ('{0,-20} {1,-10} {2,-10} {3,-12} {4}' -f ("Disk" + $d.Number), $sz, 'disk', '-', $d.FriendlyName)
        $parts = try { Get-Partition -DiskNumber $d.Number -ErrorAction Stop } catch { @() }
        foreach ($p in $parts) {
            $psz = if ($p.Size) { ConvertTo-Size ([uint64]$p.Size) } else { '-' }
            $vol = $null
            try { $vol = Get-Volume -Partition $p -ErrorAction Stop } catch {}
            $fs = if ($vol -and $vol.FileSystem) { $vol.FileSystem } else { '-' }
            $mp = if ($p.DriveLetter) { "$($p.DriveLetter):" } elseif ($vol -and $vol.Path) { $vol.Path } else { '-' }
            $lsblkLines += ('  |- {0,-16} {1,-10} {2,-10} {3,-12} {4}' -f ("part" + $p.PartitionNumber), $psz, 'part', $fs, $mp)
        }
    }
    $lsblkHtml = Pre ($lsblkLines -join "`r`n")

    $blkLines = @()
    $vols = try { Get-CimInstance Win32_Volume } catch { @() }
    foreach ($v in $vols) {
        if (-not $v.DriveLetter -and -not $v.DeviceID) { continue }
        $id = if ($v.DriveLetter) { $v.DriveLetter } else { $v.DeviceID }
        $guid = ''
        if ($v.DeviceID -match '\\\\\?\\Volume\{([0-9a-fA-F-]+)\}') { $guid = $matches[1] }
        $blkLines += ('{0}  LABEL="{1}"  FS="{2}"  SERIAL="{3}"  GUID="{4}"' -f $id, $v.Label, $v.FileSystem, $v.SerialNumber, $guid)
    }
    $blkHtml = Pre ($blkLines -join "`r`n")

    $dfLines = @()
    $dfLines += ('{0,-14} {1,12} {2,12} {3,12} {4,5}  {5}' -f 'FileSystem','Size','Used','Avail','Use%','MountPoint')
    $ld = try { Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3 OR DriveType=2 OR DriveType=5" } catch { @() }
    foreach ($d in $ld) {
        $size = [uint64]($d.Size -as [uint64])
        $free = [uint64]($d.FreeSpace -as [uint64])
        $used = if ($size -ge $free) { $size - $free } else { 0 }
        $pct  = if ($size) { [math]::Round(100 * ($used / $size)) } else { 0 }
        $fs   = if ($d.FileSystem) { $d.FileSystem } else { '-' }
        $dfLines += ('{0,-14} {1,12} {2,12} {3,12} {4,4}%  {5}' -f $fs, (ConvertTo-Size $size), (ConvertTo-Size $used), (ConvertTo-Size $free), $pct, $d.DeviceID)
    }
    $dfHtml = Pre ($dfLines -join "`r`n")

    $smartLines = @()
    $pd = try { @(Get-PhysicalDisk) } catch { @() }
    foreach ($p in $pd) {
        $smartLines += "--- $($p.FriendlyName) (SN: $($p.SerialNumber)) ---"
        $smartLines += "  Bus: $($p.BusType)  Media: $($p.MediaType)  Health: $($p.HealthStatus)  Usage: $($p.Usage)"
        try {
            $rc = $p | Get-StorageReliabilityCounter -ErrorAction Stop
            if ($rc) {
                $smartLines += "  Temperature: $($rc.Temperature) C   Max: $($rc.TemperatureMax) C"
                $smartLines += "  PowerOnHours: $($rc.PowerOnHours)   StartStopCycles: $($rc.StartStopCycleCount)"
                $smartLines += "  Wear: $($rc.Wear)   ReadErrors(Total): $($rc.ReadErrorsTotal)   WriteErrors(Total): $($rc.WriteErrorsTotal)"
            }
        } catch {
            $smartLines += "  (нет данных SMART)"
        }
    }
    $smartHtml = Pre ($smartLines -join "`r`n")

    $osBlock = (SubBlock 'lsblk (Get-Disk / Get-Partition / Get-Volume)' $lsblkHtml) +
               (SubBlock 'blkid (Win32_Volume)' $blkHtml) +
               (SubBlock 'df (Win32_LogicalDisk)' $dfHtml) +
               (SubBlock 'SMART (Get-StorageReliabilityCounter)' $smartHtml)

    $mvText = try { (mountvol | Out-String).Trim() } catch { '(mountvol недоступен)' }
    $mountBlock = SubBlock 'Правила монтирования (mountvol)' (Pre $mvText)

    $rem = try { Get-CimInstance Win32_LogicalDisk -Filter "DriveType=2" } catch { @() }
    $ipdrom = $rem | Where-Object { $_.VolumeName -eq 'IPDROM' } | Select-Object -First 1
    # Разделы флешки восстановления называются 'IpdromREC' и 'WINRE'. До 11.09.2026
    # здесь искали подстроку 'recovery', которой нет ни в одной из этих меток, поэтому
    # секция ВСЕГДА печатала 'Не найдено' - независимо от того, что реально на флешке.
    $recVol   = $rem | Where-Object { $_.VolumeName -eq 'IpdromREC' } | Select-Object -First 1
    $winreVol = $rem | Where-Object { $_.VolumeName -eq 'WINRE' }     | Select-Object -First 1

    # Содержимое флешки на два уровня вглубь, с размерами каталогов.
    function Get-FlashTree {
        param([string]$Root)
        $lines = New-Object System.Collections.ArrayList
        $top = @()
        try { $top = @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop | Sort-Object @{E={-not $_.PSIsContainer}}, Name) } catch { return '(нет доступа к содержимому)' }
        foreach ($e in $top) {
            if ($e.PSIsContainer) {
                $inner = @()
                try { $inner = @(Get-ChildItem -LiteralPath $e.FullName -Recurse -File -Force -ErrorAction SilentlyContinue) } catch {}
                $sum = if ($inner.Count) { ($inner | Measure-Object -Property Length -Sum).Sum } else { 0 }
                [void]$lines.Add(('[{0}]  {1} файл(ов), {2}' -f $e.Name, $inner.Count, (ConvertTo-Size ([uint64]$sum))))
                $sub = @()
                try { $sub = @(Get-ChildItem -LiteralPath $e.FullName -Force -ErrorAction SilentlyContinue | Sort-Object @{E={-not $_.PSIsContainer}}, Name) } catch {}
                foreach ($s in $sub) {
                    if ($s.PSIsContainer) {
                        $si = @()
                        try { $si = @(Get-ChildItem -LiteralPath $s.FullName -Recurse -File -Force -ErrorAction SilentlyContinue) } catch {}
                        $ss = if ($si.Count) { ($si | Measure-Object -Property Length -Sum).Sum } else { 0 }
                        [void]$lines.Add(('    [{0}]  {1} файл(ов), {2}' -f $s.Name, $si.Count, (ConvertTo-Size ([uint64]$ss))))
                    } else {
                        [void]$lines.Add(('    {0}  {1}' -f $s.Name, (ConvertTo-Size ([uint64]$s.Length))))
                    }
                }
            } else {
                [void]$lines.Add(('{0}  {1}' -f $e.Name, (ConvertTo-Size ([uint64]$e.Length))))
            }
        }
        if ($lines.Count -eq 0) { return '(пусто)' }
        return ($lines -join "`r`n")
    }

    function FlashInfo($v) {
        if (-not $v) { return Pre 'Не найдено' }
        $root = $v.DeviceID + '\'
        # Раньше считался ТОЛЬКО верхний уровень, а в корне флешки лежат одни каталоги -
        # отсюда бессмысленное 'Папок: 1, Файлов: 0' при полностью заполненной флешке.
        $allFiles = @()
        $allDirs  = @()
        try { $allFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue) } catch {}
        try { $allDirs  = @(Get-ChildItem -LiteralPath $root -Recurse -Directory -Force -ErrorAction SilentlyContinue) } catch {}
        $used = if ($allFiles.Count) { ($allFiles | Measure-Object -Property Length -Sum).Sum } else { 0 }
        $sz = if ($v.Size) { ConvertTo-Size ([uint64]$v.Size) } else { '-' }
        $fr = if ($v.FreeSpace) { ConvertTo-Size ([uint64]$v.FreeSpace) } else { '-' }
        $head = @"
$root
Метка:    $($v.VolumeName)
ФС:       $($v.FileSystem)
Размер:   $sz (свободно $fr)
Папок:    $($allDirs.Count) (рекурсивно)
Файлов:   $($allFiles.Count) (рекурсивно), суммарно $(ConvertTo-Size ([uint64]$used))

Содержимое:
"@
        # Явный перевод строки: here-string НЕ сохраняет последний перенос перед "@,
        # поэтому дерево приклеивалось вплотную к заголовку 'Содержимое:'.
        return Pre ($head + "`r`n" + (Get-FlashTree -Root $root))
    }

    # Образ восстановления. ВАЖНО про порядок этапов: этот отчёт формируется на
    # этапе [4.5/7], а FFU создаётся на [6.7/7] - уже после перезагрузки в WinPE,
    # то есть через несколько часов. Поэтому отсутствие здесь флешки восстановления
    # НЕ означает провал захвата, и отчёт не должен делать вид, что это проверка.
    # Достоверный итог даёт protect_ipdromrec.ps1 при следующей загрузке: он
    # проверяет .capture_failed, наличие restore.ffu и его размер, после чего
    # пишет маркер. Если маркер уже есть - показываем его.
    function Get-CaptureStatus {
        $flag = Join-Path $env:ProgramData 'IPDROM\State\IpdromREC_Protected.flag'
        if (Test-Path -LiteralPath $flag) {
            $c = try { (Get-Content -LiteralPath $flag -Raw -ErrorAction Stop).Trim() } catch { '(маркер не прочитан)' }
            return "ЗАХВАТ ПОДТВЕРЖДЁН`r`n`r`n$c"
        }
        return @"
Образ ещё не захвачен на момент формирования отчёта - это ШТАТНО.
Отчёт делается на этапе [4.5/7], FFU создаётся на [6.7/7] после перезагрузки в WinPE.

Итог захвата подтверждает protect_ipdromrec.ps1 при следующей загрузке:
он проверяет маркер .capture_failed, наличие restore.ffu и его размер,
после чего отправляет на сервер отдельный файл '<SL>_capture.txt'.
Локальная копия: C:\ProgramData\IPDROM\State\
"@
    }

    $flashBlock = (SubBlock 'Флешка IPDROM' (FlashInfo $ipdrom) 'h4') +
                  (SubBlock 'Образ восстановления (FFU)' (Pre (Get-CaptureStatus)) 'h4') +
                  (SubBlock 'Флешка восстановления: раздел IpdromREC' (FlashInfo $recVol) 'h4') +
                  (SubBlock 'Флешка восстановления: раздел WINRE' (FlashInfo $winreVol) 'h4')
    $flashOuter = SubBlock 'Флешки восстановления и IPDROM' $flashBlock

    $body = (SubBlock 'ОС' $osBlock) + $mountBlock + $flashOuter
    return $body
}

function Build-CPU {
    $cpu = try { (Get-CimInstance Win32_Processor)[0] } catch { $null }
    if (-not $cpu) { return Pre 'Информация о процессоре недоступна' }

    $ht = if ($cpu.NumberOfLogicalProcessors -gt $cpu.NumberOfCores) { 'Включён' } else { 'Выключен' }

    $lines = @()
    $lines += "Архитектура:            $($cpu.AddressWidth)-bit"
    $lines += "Имя модели:             $($cpu.Name)"
    $lines += "Производитель:          $($cpu.Manufacturer)"
    $lines += "Описание:               $($cpu.Description)"
    $lines += "ID процессора:          $($cpu.ProcessorId)"
    $lines += "Семейство:              $($cpu.Family)"
    $lines += "Сокет:                  $($cpu.SocketDesignation)"
    $lines += "Ядер:                   $($cpu.NumberOfCores)"
    $lines += "Логических процессоров: $($cpu.NumberOfLogicalProcessors)"
    $lines += "Hyper-Threading:        $ht"
    $lines += "Макс. частота:          $($cpu.MaxClockSpeed) МГц"
    $lines += "Текущая частота:        $($cpu.CurrentClockSpeed) МГц"
    $lines += "Виртуализация:          $($cpu.VirtualizationFirmwareEnabled)"
    $lines += "L2 cache:               $($cpu.L2CacheSize) КБ"
    $lines += "L3 cache:               $($cpu.L3CacheSize) КБ"

    $header = "<p><strong>Процессор:</strong> $(HtmlEnc $cpu.Name)</p>" +
              "<p><strong>Hyper-Threading:</strong> $ht</p>" +
              "<p><strong>Ядер / Потоков:</strong> $($cpu.NumberOfCores) / $($cpu.NumberOfLogicalProcessors)</p>"

    return $header + (SubBlock 'Подробные характеристики (Win32_Processor)' (Pre ($lines -join "`r`n")))
}

function Build-Platform {
    $pciLines = @()
    $pci = try { Get-CimInstance Win32_PnPEntity | Where-Object { $_.DeviceID -like 'PCI\*' } } catch { @() }
    foreach ($p in ($pci | Sort-Object Name)) {
        $pciLines += ('{0}  [{1}]' -f $p.Name, $p.DeviceID)
    }
    $pciBlock = SubBlock 'PCI-устройства (Win32_PnPEntity PCI\*)' (Pre ($pciLines -join "`r`n"))

    $cs   = try { Get-CimInstance Win32_ComputerSystem  } catch { $null }
    $bios = try { Get-CimInstance Win32_BIOS            } catch { $null }
    $bb   = try { Get-CimInstance Win32_BaseBoard       } catch { $null }
    $sys  = try { Get-CimInstance Win32_SystemEnclosure } catch { $null }

    $lshw = @()
    $lshw += $env:COMPUTERNAME.ToLower()
    $lshw += "  description: System"
    $lshw += "  product:     $($cs.Model)"
    $lshw += "  vendor:      $($cs.Manufacturer)"
    $lshw += "  serial:      $(if ($sys) { $sys.SerialNumber } else { $bios.SerialNumber })"
    $lshw += ""
    $lshw += "  *-core (Motherboard)"
    $lshw += "       product: $($bb.Product)"
    $lshw += "       vendor:  $($bb.Manufacturer)"
    $lshw += "       version: $($bb.Version)"
    $lshw += "       serial:  $($bb.SerialNumber)"
    $lshw += ""
    $lshw += "     *-firmware (BIOS)"
    $lshw += "          vendor:  $($bios.Manufacturer)"
    $lshw += "          version: $($bios.SMBIOSBIOSVersion)"
    $lshw += "          date:    $(Try-Dmtf $bios.ReleaseDate)"
    $lshw += ""
    $lshw += "     *-memory (System Memory)"
    $mem = try { @(Get-CimInstance Win32_PhysicalMemory) } catch { @() }
    foreach ($m in $mem) {
        $cap = if ($m.Capacity) { ConvertTo-Size ([uint64]$m.Capacity) } else { '-' }
        $lshw += "        *-bank $($m.DeviceLocator)"
        $lshw += "             product: $($m.PartNumber)"
        $lshw += "             vendor:  $($m.Manufacturer)"
        $lshw += "             serial:  $($m.SerialNumber)"
        $lshw += "             size:    $cap"
        $lshw += "             speed:   $($m.Speed) МГц"
    }
    $lshwBlock = SubBlock 'lshw (Win32_ComputerSystem / BIOS / BaseBoard / PhysicalMemory)' (Pre ($lshw -join "`r`n"))

    return $pciBlock + $lshwBlock
}

function Build-USB {
    $lines = @()
    $usb = try { Get-CimInstance Win32_PnPEntity | Where-Object { $_.DeviceID -like 'USB\*' } } catch { @() }
    foreach ($u in ($usb | Sort-Object Name)) {
        $nm = if ($u.Name) { $u.Name } else { $u.Description }
        $st = if ($u.Status) { $u.Status } else { '-' }
        $lines += ('{0}  [{1}]  status={2}' -f $nm, $u.DeviceID, $st)
    }
    if ($lines.Count -eq 0) { $lines = @('USB-устройства не обнаружены') }
    return Pre ($lines -join "`r`n")
}

function Build-Network {
    $rows = @()
    $adapters = try { Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -ne 'Disabled' } } catch { @() }
    foreach ($a in $adapters) {
        $cfg = try { Get-NetIPConfiguration -InterfaceIndex $a.ifIndex -ErrorAction Stop } catch { $null }
        $ipv4 = if ($cfg -and $cfg.IPv4Address) { ($cfg.IPv4Address | ForEach-Object { $_.IPAddress }) -join ', ' } else { '-' }
        $gw   = if ($cfg -and $cfg.IPv4DefaultGateway) { ($cfg.IPv4DefaultGateway | ForEach-Object { $_.NextHop }) -join ', ' } else { '-' }
        $dns  = if ($cfg -and $cfg.DNSServer) { ($cfg.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses -join ', ' }) -join ', ' } else { '-' }
        $mac  = $a.MacAddress
        $spd  = if ($a.LinkSpeed) { $a.LinkSpeed } else { '-' }
        $rows += @"
$($a.Name) ($($a.InterfaceDescription)): status=$($a.Status) mtu=$($a.MtuSize) speed=$spd
    inet    $ipv4
    ether   $mac
    gateway $gw
    dns     $dns
"@
    }
    if ($rows.Count -eq 0) { $rows = @('Сетевых адаптеров не обнаружено') }
    return Pre (($rows -join "`r`n`r`n"))
}

function Build-Power {
    $lines = @()
    $bat = try { @(Get-CimInstance Win32_Battery) } catch { @() }
    if ($bat.Count -gt 0) {
        foreach ($b in $bat) {
            $lines += "Аккумулятор: $($b.Name)"
            $lines += "  Состояние: $($b.BatteryStatus) (1=Discharging, 2=AC, 3=Fully Charged, ...)"
            $lines += "  Заряд:     $($b.EstimatedChargeRemaining) %"
            $lines += "  Время до разрядки: $($b.EstimatedRunTime) мин"
            $lines += ""
        }
    } else {
        $lines += "Батарея не обнаружена (стационарный ПК или питание только от сети)."
        $lines += ""
    }

    $plan = try { (powercfg /getactivescheme 2>&1 | Out-String).Trim() } catch { '(powercfg недоступен)' }
    $lines += "Активная схема электропитания:"
    $lines += "  $plan"
    return Pre ($lines -join "`r`n")
}

function Build-InstalledPrograms {
    $soft = @( Get-UninstallEntries )
    $soft = $soft | ForEach-Object {
        $id = $_.InstallDate
        $fmt = if ($id -is [string] -and $id -match '^\d{8}$') {
            "{0}-{1}-{2}" -f $id.Substring(0,4), $id.Substring(4,2), $id.Substring(6,2)
        } else { "$id" }
        [pscustomobject]@{
            Name        = $_.Name
            Ver         = $_.Version
            Pub         = $_.Publisher
            InstallDate = $fmt
            Scope       = $_.Scope
            View        = $_.View
        }
    }

    $appx = @()
    try { $appx = @( Get-AppxPackage | Select-Object Name, Publisher, Version ) } catch {}

    $intel = @($soft | Where-Object {
        $_.Name -match '(?i)\bIntellect\b' -or
        $_.Name -match '(?i)\bIntellect\s*X\b' -or
        $_.Name -match '(?i)Axxon.*Intellect'
    } | Sort-Object Name, Ver)

    $guardSrv = $null
    try { $guardSrv = Get-Service aksusbd -ErrorAction Stop } catch {}
    $guardDev = @()
    try { $guardDev = @( Get-PnpDevice -FriendlyName '*Guardant*','*Sentinel*HASP*','*SafeNet*HASP*' -ErrorAction SilentlyContinue ) } catch {}

    $lines = @()
    $lines += '== Intellect / Intellect X =='
    if ($intel -and $intel.Count -gt 0) {
        foreach ($i in $intel) { $lines += "$($i.Name)  $($i.Ver)  $($i.Pub)" }
    } else {
        $lines += 'Не найдено'
    }

    $lines += ''
    $lines += '== Guardant / Sentinel =='
    $status = if ($guardSrv) { "$($guardSrv.Status)" } else { 'служба не установлена' }
    $lines += "Служба aksusbd: $status"
    if ($guardDev -and $guardDev.Count -gt 0) {
        foreach ($d in $guardDev) {
            $fn = if ($d.FriendlyName) { $d.FriendlyName } else { $d.InstanceId }
            $st = if ($d.Status) { $d.Status } else { '-' }
            $lines += "Устройство: $fn [$st]"
        }
    } else {
        $lines += 'Ключи Guardant/Sentinel не обнаружены'
    }

    if ($IncludeSoftware) {
        $lines += ''
        $lines += '== Установленные пакеты (MSI / EXE из реестра) =='
        if ($soft.Count -gt 0) {
            foreach ($s in ($soft | Sort-Object Name, Ver, Pub, Scope, View)) {
                $nm = if ($s.Name) { $s.Name } else { '-' }
                $vr = if ($s.Ver)  { $s.Ver }  else { '-' }
                $pb = if ($s.Pub)  { $s.Pub }  else { '-' }
                $sc = if ($s.Scope) { $s.Scope } else { '-' }
                $vw = if ($s.View)  { $s.View }  else { '-' }
                $dt = if ($s.InstallDate) { $s.InstallDate } else { '-' }
                $lines += "$nm  $vr  $pb  [$sc/$vw]  $dt"
            }
        } else {
            $lines += 'Нет данных'
        }

        $lines += ''
        $lines += '== UWP / Store (Appx) текущий пользователь =='
        if ($appx.Count -gt 0) {
            foreach ($a in ($appx | Sort-Object Name, Version)) {
                $pub = if ($a.Publisher) { $a.Publisher } else { '-' }
                $lines += "$($a.Name)  $($a.Version)  $pub"
            }
        } else {
            $lines += 'Нет данных'
        }
    } else {
        $lines += ''
        $lines += '(Запустите скрипт с ключом -IncludeSoftware, чтобы получить полный список установленных пакетов и UWP/Store приложений.)'
    }

    return Pre ($lines -join "`r`n")
}

function Build-Logs {
    $lines = @()
    try {
        $sys = Get-EventLog -LogName System -Newest 50 -ErrorAction Stop |
               Select-Object TimeGenerated, EntryType, Source, EventID, Message
        foreach ($e in $sys) {
            $msg = ($e.Message -replace '\s+', ' ')
            if ($msg.Length -gt 200) { $msg = $msg.Substring(0,200) + '...' }
            $lines += ('{0:yyyy-MM-dd HH:mm:ss}  [{1,-11}]  {2}/{3}  {4}' -f $e.TimeGenerated, $e.EntryType, $e.Source, $e.EventID, $msg)
        }
    } catch {
        $lines += '(Не удалось прочитать журнал System)'
    }
    if ($lines.Count -eq 0) { $lines = @('Записей нет') }
    return (SubBlock 'System (последние 50 событий)' (Pre ($lines -join "`r`n")))
}

# ---------- assemble HTML ----------

$serverInfoHtml = Build-ServerInfo
$disksHtml      = Build-Disks
$cpuHtml        = Build-CPU
$platformHtml   = Build-Platform
$usbHtml        = Build-USB
$netHtml        = Build-Network
$powerHtml      = Build-Power
$progHtml       = Build-InstalledPrograms
$logsHtml       = Build-Logs

$now = Get-Date
$title = "Отчёт о системе: $ComputerName ($($now.ToString('yyyy-MM-dd HH:mm')))"

$css = @'
:root {
    --bg-color: #cacccd;
    --text-color: #333;
    --sidebar-bg: #f4f4f4;
    --section-bg: #f4f4f4;
    --border-color: #333;
    --link-hover: #ddd;
    --button-bg: #333;
    --button-hover: #555;
}
body.dark-theme {
    --bg-color: #1e1e1e;
    --text-color: #f4f4f4;
    --sidebar-bg: #2e2e2e;
    --section-bg: #333;
    --border-color: #f4f4f4;
    --link-hover: #444;
    --button-bg: #555;
    --button-hover: #777;
}
b { color: #04a3ff9d; }
body {
    font-family: Arial, sans-serif;
    margin: 0;
    background-color: var(--bg-color);
    color: var(--text-color);
    display: flex;
    flex-direction: column;
    min-block-size: 100vh;
}
h1 { text-align: center; }
.sidebar {
    inline-size: 220px;
    background-color: var(--sidebar-bg);
    padding: 20px;
    box-shadow: 2px 0 5px rgba(0,0,0,0.1);
    position: fixed;
    block-size: 100%;
    overflow-y: auto;
}
.sidebar a {
    display: block;
    color: var(--text-color);
    padding: 10px;
    text-decoration: none;
    border-block-end: 1px solid var(--border-color);
}
.sidebar a.active {
    background-color: var(--link-hover);
    font-weight: bold;
}
.sidebar a:hover { background-color: var(--link-hover); }
.content {
    margin-inline-start: 260px;
    padding: 20px;
    flex: 1;
}
.section {
    margin-block-end: 20px;
    padding: 20px;
    border: 1px solid var(--border-color);
    background-color: var(--section-bg);
    border-radius: 10px;
    box-shadow: 0 4px 8px rgba(0, 0, 0, 0.1);
}
h2, h3, h4 {
    border-block-end: 1px solid var(--border-color);
    padding-block-end: 5px;
    margin-block-end: 10px;
}
pre {
    background-color: rgba(0,0,0,0.05);
    padding: 10px;
    border-radius: 5px;
    overflow-x: auto;
    white-space: pre-wrap;
    word-wrap: break-word;
}
body.dark-theme pre { background-color: rgba(255,255,255,0.05); }
table { border-collapse: collapse; }
table td { padding: 6px 10px; }
.back-to-top {
    display: inline-block;
    inline-size: auto;
    min-inline-size: 120px;
    margin: 10px;
    padding: 10px 16px;
    text-align: center;
    background-color: var(--button-bg);
    color: #fff;
    text-decoration: none;
    border: none;
    border-radius: 5px;
    box-shadow: 0 4px 8px rgba(0, 0, 0, 0.1);
    cursor: pointer;
}
.back-to-top:hover { background-color: var(--button-hover); }
.footer-actions { text-align: center; margin: 20px 0; }
'@

$js = @'
function toggleVisibility(element) {
    var content = element.nextElementSibling;
    if (!content) return;
    content.style.display = (content.style.display === 'none') ? 'block' : 'none';
}
function expandAllSections() {
    document.querySelectorAll(".desktop-items-container").forEach(function(c) {
        c.style.display = 'block';
    });
}
function collapseAllSections() {
    document.querySelectorAll(".desktop-items-container").forEach(function(c) {
        c.style.display = 'none';
    });
}
document.addEventListener("DOMContentLoaded", function() {
    var saved = null;
    try { saved = localStorage.getItem('reportTheme'); } catch (e) {}
    if (saved === 'dark' ||
        (saved === null && window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches)) {
        document.body.classList.add('dark-theme');
    }
    var btn = document.getElementById('toggle-theme');
    if (btn) {
        btn.addEventListener('click', function() {
            document.body.classList.toggle('dark-theme');
            try {
                localStorage.setItem('reportTheme',
                    document.body.classList.contains('dark-theme') ? 'dark' : 'light');
            } catch (e) {}
        });
    }
    var sections = document.querySelectorAll(".section");
    var navLinks = document.querySelectorAll(".sidebar a");
    var observer = new IntersectionObserver(function(entries) {
        entries.forEach(function(entry) {
            if (entry.isIntersecting) {
                var id = entry.target.getAttribute("id");
                navLinks.forEach(function(link) {
                    link.classList.remove("active");
                    if (link.getAttribute("href") && link.getAttribute("href").substring(1) === id) {
                        link.classList.add("active");
                    }
                });
            }
        });
    }, { root: null, rootMargin: "0px", threshold: 0.35 });
    sections.forEach(function(s) { observer.observe(s); });
});
'@

$sidebar = @'
<div class="sidebar">
    <h1>Навигация</h1>
    <button id="toggle-theme" style="margin-block-end: 20px; inline-size: 100%; padding: 10px; background-color: var(--button-bg); color: white; border: none; border-radius: 5px; cursor: pointer;">Сменить тему</button>
    <a href="#server-info">Информация о сервере</a>
    <a href="#disks">Информация о дисках</a>
    <a href="#lscpu">Подробно о процессоре</a>
    <a href="#lsmb">Подробно о платформе</a>
    <a href="#lsusb">USB-устройства</a>
    <a href="#lseth">Сетевые устройства</a>
    <a href="#lspsu">Источник питания</a>
    <a href="#installed-programs">Установленные программы</a>
    <a href="#logs">Логи системы</a>
</div>
'@

$sec1 = Section -Id 'server-info'        -Title 'Информация о сервере'    -BodyHtml $serverInfoHtml -NoCollapse
$sec2 = Section -Id 'disks'              -Title 'Информация о дисках'     -BodyHtml $disksHtml
$sec3 = Section -Id 'lscpu'              -Title 'Подробнее о процессоре'  -BodyHtml $cpuHtml
$sec4 = Section -Id 'lsmb'               -Title 'Подробнее о платформе'   -BodyHtml $platformHtml
$sec5 = Section -Id 'lsusb'              -Title 'USB-устройства'          -BodyHtml $usbHtml
$sec6 = Section -Id 'lseth'              -Title 'Сетевые устройства'      -BodyHtml $netHtml
$sec7 = Section -Id 'lspsu'              -Title 'Источник питания'        -BodyHtml $powerHtml
$sec8 = Section -Id 'installed-programs' -Title 'Установленные программы' -BodyHtml $progHtml
$sec9 = Section -Id 'logs'               -Title 'Логи системы'            -BodyHtml $logsHtml

$html = @"
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$title</title>
    <style>
$css
    </style>
</head>
<body>
    <a id="top"></a>
    $sidebar
    <div class="content">
        <h1>$title</h1>
        $sec1
        $sec2
        $sec3
        $sec4
        $sec5
        $sec6
        $sec7
        $sec8
        $sec9
        <div class="footer-actions">
            <a href="#top" class="back-to-top">Вверх</a>
            <button class="back-to-top" onclick="expandAllSections()">Развернуть все</button>
            <button class="back-to-top" onclick="collapseAllSections()">Свернуть все</button>
        </div>
    </div>
    <script>
$js
    </script>
</body>
</html>
"@

Set-Content -LiteralPath $ReportPath -Value $html -Encoding UTF8
Write-Host "Готово: $ReportPath"
