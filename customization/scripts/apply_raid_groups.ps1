<#
.SYNOPSIS
    Читает RAID-группы из build_spec.txt и планирует создание DATA-массивов.

    ВАЖНО ПО ДИЗАЙНУ:
    - Системный массив (group_*_disk_system=TRUE) НЕ создаётся этим скриптом.
      Он создаётся вручную в RAID BIOS до установки Windows. Мы его не трогаем.
    - Только DATA-массивы (disk_system=FALSE) планируются/создаются здесь,
      после установки, на свободных (Unconfigured Good) дисках.

    ЭТАП 1 (сейчас): только -DryRun - парсинг + вывод плана. БЕЗ storcli, без железа.
    ЭТАП 2 (позже):  -Execute - реальное создание через storcli, когда будет
                     известен формат вывода storcli show с целевого сервера.

.PARAMETER UsbRoot
    Корень USB-флешки (где config\). Обязательный.

.PARAMETER ConfigPath
    Явный путь к файлу конфигурации. Если задан - используется как есть.

.PARAMETER ConfigDir
    Папка где искать SL*.txt. По умолчанию <UsbRoot>\config.

.PARAMETER ConfigRelPath
    Legacy: относительный путь к build_spec.txt. Если задан - имеет приоритет
    над auto-discovery.

.PARAMETER Execute
    Реально создавать массивы через storcli. БЕЗ него - только dry-run план.

.NOTES
    Формат группы в build_spec (пример реальной машины):
      group_2_host=LSI MegaRAID SAS9361-4I
      group_2_Type=RAID-1
      group_2_disk_type=HDD
      group_2_disk_size=20Tb
      group_2_disk_quantity=2
      group_2_disk_system=FALSE
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UsbRoot,
    [string]$ConfigPath,
    [string]$ConfigDir,
    [string]$ConfigRelPath,
    [switch]$Execute
)

if (-not $ConfigDir) { $ConfigDir = Join-Path $UsbRoot 'config' }

$ErrorActionPreference = 'Stop'

# ===================== LOG =====================
$logDir  = Join-Path $env:ProgramData 'IPDROM\Logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir ("apply_raid_groups_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function Write-Log {
    param([string]$Msg, [string]$Color = 'White')
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
    try { $line | Out-File -FilePath $logFile -Encoding utf8 -Append } catch {}
    Write-Host $Msg -ForegroundColor $Color
}

Write-Log "=== apply_raid_groups started ===" 'Cyan'
Write-Log "UsbRoot: $UsbRoot   Execute: $Execute"

# ===================== ПАРСЕР INI =====================
function Read-BuildSpec {
    param([Parameter(Mandatory)][string]$Path)
    $result = @{}
    foreach ($raw in (Get-Content -LiteralPath $Path -ErrorAction Stop)) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $result[$line.Substring(0, $eq).Trim()] = $line.Substring($eq + 1).Trim()
    }
    return $result
}

# ===================== МАППИНГ ТИПА RAID =====================
# build_spec Type -> storcli level token
function Convert-RaidType {
    param([string]$Type)
    $t = ($Type -replace '[\s\-_]', '').ToUpper()  # "RAID-1" -> "RAID1"
    switch ($t) {
        'RAID0'  { return 'r0' }
        'RAID1'  { return 'r1' }
        'RAID5'  { return 'r5' }
        'RAID6'  { return 'r6' }
        'RAID10' { return 'r10' }
        'RAID50' { return 'r50' }
        'RAID60' { return 'r60' }
        default  { return $null }
    }
}

# ===================== ПАРСЕР РАЗМЕРА ДИСКА =====================
# "0,24Tb" -> 240 (GB), "20Tb" -> 20000 (GB), "960Gb" -> 960
# Запятая = десятичный разделитель (RU). Возвращает примерный размер в GB.
function Convert-DiskSizeToGB {
    param([string]$Size)
    if ([string]::IsNullOrWhiteSpace($Size)) { return $null }
    $s = $Size.Trim().Replace(',', '.')
    if ($s -match '^([\d.]+)\s*([TG])b?$') {
        $num  = [double]$matches[1]
        $unit = $matches[2].ToUpper()
        if ($unit -eq 'T') { return [int]($num * 1000) }
        else               { return [int]$num }
    }
    return $null
}

# ===================== СБОР ГРУПП ИЗ КОНФИГА =====================
# Группы: group_<N>_<field>. Собираем по номеру N, динамически (не фиксированные X/Y/Z).
function Get-RaidGroups {
    param([hashtable]$Spec)
    $groups = @{}
    foreach ($key in $Spec.Keys) {
        if ($key -match '^group_(\d+)_(.+)$') {
            $n     = [int]$matches[1]
            $field = $matches[2]
            if (-not $groups.ContainsKey($n)) { $groups[$n] = @{} }
            $groups[$n][$field] = $Spec[$key]
        }
    }
    return $groups
}

# ===================== ПОИСК ФАЙЛА КОНФИГА =====================
# Тот же приоритет что в apply_build_spec.ps1 и Install-AxxonByBuildSpec.ps1:
#   1. -ConfigPath (явный)
#   2. -ConfigRelPath (legacy)
#   3. Auto-discovery в $ConfigDir: SL*-*.txt -> build_spec.txt
function Resolve-ConfigPath {
    param([string]$Explicit, [string]$RelPath, [string]$Dir, [string]$RootDir)

    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit) { return $Explicit }
        Write-Log "Explicit -ConfigPath not found: $Explicit" 'Red'
        return $null
    }
    if ($RelPath) {
        $p = Join-Path $RootDir $RelPath
        if (Test-Path -LiteralPath $p) { return $p }
        Write-Log "Explicit -ConfigRelPath not found: $p" 'Red'
        return $null
    }
    if (-not (Test-Path -LiteralPath $Dir)) {
        Write-Log "Config dir does not exist: $Dir" 'Yellow'
        return $null
    }

    # Priority: PXE preselection via HKLM\Software\IPDROM\SL (set by Specialize.ps1
    # from __INSTALL_SL__ marker in autounattend). Fallback to $env:IPDROM_FORCE_SL
    # which launcher exports from the same HKLM key. Only if neither yields a
    # matching file do we fall back to the mtime-sort auto-discovery.
    $forcedSL = $null
    try { $forcedSL = (Get-ItemProperty -Path 'HKLM:\Software\IPDROM' -Name 'SL' -ErrorAction Stop).SL } catch {}
    if (-not $forcedSL -and $env:IPDROM_FORCE_SL) { $forcedSL = $env:IPDROM_FORCE_SL }
    if ($forcedSL -and $forcedSL -match '^SL\w+-\w+$') {
        $forcedPath = Join-Path $Dir "$forcedSL.txt"
        if (Test-Path -LiteralPath $forcedPath) {
            Write-Log "Using PXE-preselected SL: $forcedSL -> $forcedPath" 'Green'
            return $forcedPath
        }
        Write-Log "PXE preselection SL=$forcedSL, but $forcedPath not found -- falling back to auto-discovery." 'Yellow'
    }

    $slCandidates = @(Get-ChildItem -Path $Dir -Filter 'SL*.txt' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^SL\w+-\w+(\s+\d+)?\.txt$' } |
        Sort-Object LastWriteTime -Descending)
    if ($slCandidates.Count -ge 1) {
        if ($slCandidates.Count -gt 1) {
            Write-Log "Found $($slCandidates.Count) SL*-*.txt files in $Dir - taking newest:" 'Yellow'
            foreach ($c in $slCandidates) {
                Write-Log ("  - {0}  ({1})" -f $c.Name, $c.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')) 'Gray'
            }
        }
        return $slCandidates[0].FullName
    }

    $legacy = Join-Path $Dir 'build_spec.txt'
    if (Test-Path -LiteralPath $legacy) {
        Write-Log "No SL*-*.txt found in $Dir, using legacy build_spec.txt." 'Gray'
        return $legacy
    }
    return $null
}

# ===================== ОСНОВНАЯ ЛОГИКА =====================
$configPath = Resolve-ConfigPath -Explicit $ConfigPath -RelPath $ConfigRelPath -Dir $ConfigDir -RootDir $UsbRoot
if (-not $configPath) {
    Write-Log "No config file found - nothing to do." 'Yellow'
    Write-Log "Tried: explicit=$ConfigPath, rel=$ConfigRelPath, dir=$ConfigDir (SL*-*.txt or build_spec.txt)" 'Gray'
    exit 0
}
Write-Log "Config: $configPath" 'Green'

$spec   = Read-BuildSpec -Path $configPath
$groups = Get-RaidGroups -Spec $spec

if ($groups.Count -eq 0) {
    Write-Log "No group_N_* entries in config - no RAID groups defined." 'Yellow'
    exit 0
}

Write-Log "Found $($groups.Count) RAID group(s) in config." 'Green'

# Разбираем каждую группу, строим план для DATA-массивов.
$plan = New-Object System.Collections.ArrayList
foreach ($n in ($groups.Keys | Sort-Object)) {
    $g = $groups[$n]

    $isSystem = ($g['disk_system'] -as [string]) -match '^(?i)true$'
    $level    = Convert-RaidType $g['Type']
    $qty      = [int]($g['disk_quantity'])
    $sizeGB   = Convert-DiskSizeToGB $g['disk_size']
    $dtype    = $g['disk_type']

    Write-Log ("Group {0}: Type={1} ({2}), disks={3} x {4} ({5} GB each), system={6}" -f `
        $n, $g['Type'], ($(if($level){$level}else{'UNKNOWN'})), $qty, $dtype, `
        ($(if($sizeGB){$sizeGB}else{'?'})), $g['disk_system']) 'Gray'

    if ($isSystem) {
        Write-Log "  -> SYSTEM array: created manually in RAID BIOS. SKIP (not touched)." 'Yellow'
        continue
    }
    if (-not $level) {
        Write-Log "  -> Unknown RAID type '$($g['Type'])'. SKIP this group." 'Red'
        continue
    }
    if ($qty -lt 1) {
        Write-Log "  -> disk_quantity invalid ($($g['disk_quantity'])). SKIP." 'Red'
        continue
    }

    $entry = [pscustomobject]@{
        Group     = $n
        Level     = $level
        Quantity  = $qty
        DiskType  = $dtype
        DiskSizeGB= $sizeGB
    }
    [void]$plan.Add($entry)
    Write-Log ("  -> DATA array planned: storcli /c0 add vd {0} drives=<{1}x {2} ~{3}GB Unconfigured-Good>" -f `
        $level, $qty, $dtype, ($(if($sizeGB){$sizeGB}else{'?'}))) 'Green'
}

Write-Log "" 'White'
Write-Log "=== PLAN SUMMARY: $($plan.Count) data array(s) to create ===" 'Cyan'
foreach ($p in $plan) {
    Write-Log ("  group {0}: {1} from {2}x {3} (~{4} GB)" -f $p.Group, $p.Level, $p.Quantity, $p.DiskType, $p.DiskSizeGB) 'White'
}

if ($plan.Count -eq 0) {
    Write-Log "No data arrays to create. Done." 'Green'
    exit 0
}

# ===================== ОПРОС ФИЗИЧЕСКИХ ДИСКОВ ЧЕРЕЗ STORCLI =====================
# Находим storcli (тот же путь что в pipeline, либо в PATH).
$storcli = $null
foreach ($p in @(
    (Join-Path $UsbRoot 'SoftForTest\StorCLI\storcli64.exe'),
    'storcli64.exe', 'storcli.exe'
)) {
    $cmd = Get-Command $p -ErrorAction SilentlyContinue
    if ($cmd) { $storcli = $cmd.Source; break }
    if (Test-Path $p) { $storcli = $p; break }
}
if (-not $storcli) {
    Write-Log "storcli not found - cannot enumerate physical disks." 'Red'
    exit 11
}
Write-Log "Using storcli: $storcli" 'Gray'

# Парсер PD-таблицы. Строки вида:
#   252:1     1 Onln   0 5.457 TB SATA HDD N   N  512B ST6000NM0115-1YZ110 U  -
# Берём: EID:Slt, State, Size+unit, Med(HDD/SSD).
function Get-PhysicalDrives {
    param([string]$Cli)
    $raw = & $Cli /c0/eall/sall show 2>&1
    $drives = New-Object System.Collections.ArrayList
    foreach ($line in $raw) {
        if ($line -match '^\s*(\d+:\d+)\s+\d+\s+(\S+)\s+\S+\s+([\d.]+)\s*(TB|GB)\s+\S+\s+(HDD|SSD)\b') {
            $sizeNum = [double]$matches[3]
            $unit    = $matches[4]
            $sizeGB  = if ($unit -eq 'TB') { [int]($sizeNum * 1000) } else { [int]$sizeNum }
            [void]$drives.Add([pscustomobject]@{
                Slot   = $matches[1]    # EID:Slt, напр. 252:5
                State  = $matches[2]    # Onln / UGood / ...
                SizeGB = $sizeGB
                Media  = $matches[5]    # HDD / SSD
            })
        }
    }
    return $drives
}

# Уже существующие виртуальные диски. Разбираем `/c0/vall show all`:
#   - строка "DG/VD TYPE ... Size" даёт уровень RAID и ёмкость
#   - "OS Drive Name = Disk N" привязывает VD к номеру диска в Windows, по нему
#     отличаем системный массив от data-массивов
# Нужно, чтобы повторные прогоны на одной машине не плодили дубликаты: каждая
# группа сначала пытается «занять» уже существующий VD своего уровня и только
# если занимать нечего - создаёт новый.
function Get-ExistingVirtualDrives {
    param([string]$Cli)
    $raw = & $Cli /c0/vall show all 2>&1
    $vds = New-Object System.Collections.ArrayList
    $cur = $null
    foreach ($line in $raw) {
        $s = "$line"
        if ($s -match '^/c\d+/v(\d+)\s*:') {
            if ($cur) { [void]$vds.Add($cur) }
            $cur = [pscustomobject]@{ Vd = [int]$matches[1]; Level = $null; SizeGB = $null; OsDisk = $null }
            continue
        }
        if (-not $cur) { continue }
        if (-not $cur.Level -and
            $s -match '^\s*\d+/\d+\s+(RAID\d+)\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+([\d.]+)\s*(TB|GB)') {
            $cur.Level  = $matches[1]
            $num        = [double]$matches[2]
            $cur.SizeGB = if ($matches[3] -eq 'TB') { [int]($num * 1000) } else { [int]$num }
        }
        if ($s -match '^\s*OS Drive Name\s*=\s*Disk\s+(\d+)') { $cur.OsDisk = [int]$matches[1] }
    }
    if ($cur) { [void]$vds.Add($cur) }
    return $vds
}

# ===================== JBOD -> UNCONFIGURED GOOD =====================
# Часть контроллеров/операторов оставляет data-диски в состоянии JBOD: диск
# виден в ОС напрямую, но storcli НЕ считает его свободным (UGood) и в новый VD
# не берёт. Именно из-за этого RAID-6 на SL836125-001 не собрался - все 14
# дисков были JBOD, freeDrives=0. Здесь переводим JBOD-диски в Unconfigured Good.
# ВНИМАНИЕ: это стирает данные на этих дисках. В нашем пайплайне ОС всегда на
# отдельном системном массиве (Intel VMD / системный VD), не на JBOD-диске
# этого контроллера, поэтому конвертация data-JBOD безопасна.
function Convert-JbodDrivesToGood {
    param([string]$Cli, $Drives)
    $jbod = @($Drives | Where-Object { $_.State -match '^(?i)JBOD' })
    if ($jbod.Count -eq 0) { return $false }

    Write-Log ("JBOD drives detected: {0}. Converting to Unconfigured Good so a VD can be built." -f $jbod.Count) 'Yellow'
    Write-Log "  NOTE: this erases those JBOD disks (OS is on a separate system array - safe on a build stand)." 'DarkGray'

    # 1) Снимаем JBOD-флаг с каждого диска -> Unconfigured Good.
    foreach ($d in $jbod) {
        $parts = $d.Slot -split ':'
        if ($parts.Count -ne 2) { continue }
        $eid = $parts[0]; $slt = $parts[1]
        Write-Log ("  set good: /c0/e{0}/s{1}  (was JBOD, ~{2}GB {3})" -f $eid, $slt, $d.SizeGB, $d.Media) 'Gray'
        $o = & $Cli "/c0/e$eid/s$slt" set good force 2>&1
        foreach ($l in $o) { Write-Log "    | $l" 'DarkGray' }
    }

    # 2) Отключаем JBOD-персоналию контроллера (best-effort): теперь, когда
    #    отдельных JBOD-дисков не осталось, прошивка обычно принимает команду,
    #    и вновь появляющиеся диски снова JBOD не становятся.
    Write-Log "  Disabling controller JBOD personality (set jbod=off)..." 'Gray'
    $j = & $Cli /c0 set jbod=off 2>&1
    foreach ($l in $j) { Write-Log "  | $l" 'DarkGray' }

    Start-Sleep -Seconds 3
    return $true
}

# Clear stale Foreign configuration if any. Drives that belonged to a previous
# RAID group on this controller sit in 'UGood F' (Foreign) state and StorCLI
# refuses to include them in a new VD with "resources already in use". On a
# stress-test/build stand we don't need the old metadata — subsequent steps
# format everything anyway. Idempotent: if nothing is Foreign, no-op.
try {
    $fcheck = & $storcli /c0/fall show 2>&1
    $foreignPresent = ($fcheck | Out-String) -match '(?i)foreign|frgn'
    if ($foreignPresent) {
        Write-Log "Foreign configuration detected on /c0 - clearing to unblock drives." 'Yellow'
        $fout = & $storcli /c0/fall del 2>&1
        foreach ($l in $fout) { Write-Log "  | $l" 'DarkGray' }
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Foreign configuration cleared." 'Green'
            Start-Sleep -Seconds 3
        } else {
            Write-Log "Foreign clear returned exit=$LASTEXITCODE (may need manual 'storcli /c0/fall del')." 'Yellow'
        }
    } else {
        Write-Log "No Foreign configuration present." 'Gray'
    }
} catch {
    Write-Log "Foreign check/clear threw: $_ (continuing anyway)." 'Yellow'
}

$allDrives = Get-PhysicalDrives -Cli $storcli
Write-Log "Enumerated $($allDrives.Count) physical drive(s):" 'Gray'
foreach ($d in $allDrives) {
    Write-Log ("  {0}  State={1}  {2}  ~{3}GB" -f $d.Slot, $d.State, $d.Media, $d.SizeGB) 'DarkGray'
}

# Если свободных (UGood) дисков не хватает под план, но на контроллере есть
# JBOD-диски - переводим их в Good и перечитываем список. Только при -Execute,
# и только когда UGood реально не хватает (не трогаем JBOD зря).
$ugoodNow = @($allDrives | Where-Object { $_.State -match '^(?i)UGood' }).Count
$needed   = [int](($plan | Measure-Object -Property Quantity -Sum).Sum)
if ($Execute -and $needed -gt $ugoodNow) {
    Write-Log ("Free UGood drives ({0}) < drives needed by plan ({1}) - checking for JBOD drives to convert..." -f $ugoodNow, $needed) 'Yellow'
    $converted = Convert-JbodDrivesToGood -Cli $storcli -Drives $allDrives
    if ($converted) {
        Write-Log "Re-enumerating physical drives after JBOD->Good conversion..." 'Gray'
        $allDrives = Get-PhysicalDrives -Cli $storcli
        foreach ($d in $allDrives) {
            Write-Log ("  {0}  State={1}  {2}  ~{3}GB" -f $d.Slot, $d.State, $d.Media, $d.SizeGB) 'DarkGray'
        }
    }
}

# ТОЛЬКО свободные диски (Unconfigured Good) можно брать в новый массив.
# Online (Onln) диски в существующих массивах - НИКОГДА не трогаем.
$freeDrives = New-Object System.Collections.ArrayList
foreach ($d in $allDrives) {
    if ($d.State -match '^(?i)UGood') { [void]$freeDrives.Add($d) }
}
Write-Log "Free (Unconfigured Good) drives available: $($freeDrives.Count)" 'Cyan'

if ($freeDrives.Count -eq 0) {
    Write-Log "No free (UGood) drives on the controller." 'Yellow'
    Write-Log "Groups matching an existing array are still fine; the rest cannot be created." 'Gray'
}

# ===================== УЖЕ СУЩЕСТВУЮЩИЕ МАССИВЫ =====================
$existingVds = @(Get-ExistingVirtualDrives -Cli $storcli)
Write-Log "" 'White'
Write-Log "Existing virtual drives on controller: $($existingVds.Count)" 'Cyan'

# Системный VD в пул не берём: его создаёт оператор в RAID BIOS вручную, и он
# не должен «закрывать» потребность в data-массиве того же уровня.
$sysDiskNumber = $null
try {
    $sysLetter     = ($env:SystemDrive).TrimEnd(':')
    $sysDiskNumber = (Get-Partition -DriveLetter $sysLetter -ErrorAction Stop).DiskNumber
} catch {
    Write-Log "Could not resolve the system disk number: $_" 'DarkGray'
}

$claimable = New-Object System.Collections.ArrayList
foreach ($v in $existingVds) {
    $isSys = (($null -ne $sysDiskNumber) -and ($v.OsDisk -eq $sysDiskNumber))
    $osTxt = if ($null -ne $v.OsDisk) { "Disk $($v.OsDisk)" } else { 'Disk ?' }
    $note  = if ($isSys) { '  <-- SYSTEM array, not claimable' } else { '' }
    Write-Log ("  VD{0}: {1}  ~{2}GB  {3}{4}" -f $v.Vd, $v.Level, $v.SizeGB, $osTxt, $note) 'DarkGray'
    if (-not $isSys) { [void]$claimable.Add($v) }
}

# ===================== ПОДБОР ДИСКОВ + СОЗДАНИЕ =====================
# Резервируем диски пофайлово, чтобы один диск не попал в два массива.
$used = @{}   # Slot -> $true

foreach ($p in $plan) {
    Write-Log "" 'White'
    Write-Log ("--- Group {0}: need {1}x {2} (~{3}GB) for {4} ---" -f $p.Group, $p.Quantity, $p.DiskType, $p.DiskSizeGB, $p.Level) 'Cyan'

    # Уже есть незанятый массив нужного уровня? Тогда ничего не создаём. Без
    # этой проверки повторные прогоны на одном стенде плодят одинаковые массивы,
    # пока на контроллере не кончатся свободные диски.
    $wantLevel = 'RAID' + $p.Level.Substring(1)
    $already   = $claimable | Where-Object { $_.Level -eq $wantLevel } | Select-Object -First 1
    if ($already) {
        Write-Log ("  Array {0} already exists (VD{1}, ~{2}GB) - creation skipped." -f $wantLevel, $already.Vd, $already.SizeGB) 'Yellow'
        [void]$claimable.Remove($already)
        continue
    }

    # Кандидаты: свободные, нужного типа, ещё не зарезервированные.
    # Размер используем мягко: предпочитаем близкие к указанному (+-25%), но
    # если точных нет, берём любые свободные нужного типа.
    $cands = @($freeDrives | Where-Object {
        -not $used.ContainsKey($_.Slot) -and
        $_.Media -ieq $p.DiskType
    })

    if ($p.DiskSizeGB) {
        $lo = $p.DiskSizeGB * 0.75
        $hi = $p.DiskSizeGB * 1.25
        $sized = @($cands | Where-Object { $_.SizeGB -ge $lo -and $_.SizeGB -le $hi })
        if ($sized.Count -ge $p.Quantity) { $cands = $sized }
        else { Write-Log "  (no exact size match within +-25%, using any $($p.DiskType) free drives)" 'DarkGray' }
    }

    if ($cands.Count -lt $p.Quantity) {
        Write-Log ("  NOT ENOUGH free {0} drives: need {1}, have {2}. SKIP this group." -f $p.DiskType, $p.Quantity, $cands.Count) 'Red'
        continue
    }

    $chosen = $cands | Select-Object -First $p.Quantity
    $slots  = ($chosen | ForEach-Object { $_.Slot }) -join ','
    foreach ($c in $chosen) { $used[$c.Slot] = $true }

    $cmdArgs = "/c0 add vd $($p.Level) drives=$slots"
    Write-Log "  Selected drives: $slots" 'Green'
    Write-Log "  storcli command: $storcli $cmdArgs" 'Green'

    if (-not $Execute) {
        Write-Log "  [DRY-RUN] not executed (-Execute to actually create)." 'Yellow'
        continue
    }

    # --- РЕАЛЬНОЕ СОЗДАНИЕ ---
    Write-Log "  Creating array..." 'Yellow'
    $out = & $storcli /c0 add vd $($p.Level) drives=$slots 2>&1
    foreach ($l in $out) { Write-Log "    | $l" 'DarkGray' }
    if ($LASTEXITCODE -eq 0) {
        Write-Log "  Array created OK (group $($p.Group), $($p.Level))." 'Green'
        # Дать контроллеру/ОС время увидеть новый VD (RAID-6 инициализируется
        # в фоне, но диск должен появиться до rescan в вызывающем скрипте).
        Start-Sleep -Seconds 8
    } else {
        Write-Log "  storcli add vd FAILED (exit $LASTEXITCODE). Group $($p.Group) skipped." 'Red'
    }
}

Write-Log "" 'White'
if (-not $Execute) {
    Write-Log "=== DRY-RUN complete. Re-run with -Execute to create the arrays above. ===" 'Yellow'
} else {
    Write-Log "=== Data array creation complete. ===" 'Cyan'
}
exit 0
