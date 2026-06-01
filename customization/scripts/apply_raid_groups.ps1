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
    Корень USB-флешки (где config\build_spec.txt). Обязательный.

.PARAMETER ConfigRelPath
    Путь к конфигу относительно UsbRoot. По умолчанию config\build_spec.txt.

.PARAMETER Execute
    Реально создавать массивы через storcli. БЕЗ него - только dry-run план.
    (Пока НЕ реализовано - заглушка, чтобы случайно не тронуть железо.)

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
    [string]$ConfigRelPath = 'config\build_spec.txt',
    [switch]$Execute
)

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

# ===================== ОСНОВНАЯ ЛОГИКА =====================
$configPath = Join-Path $UsbRoot $ConfigRelPath
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Log "Config not found at $configPath - nothing to do." 'Yellow'
    exit 0
}

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

$allDrives = Get-PhysicalDrives -Cli $storcli
Write-Log "Enumerated $($allDrives.Count) physical drive(s):" 'Gray'
foreach ($d in $allDrives) {
    Write-Log ("  {0}  State={1}  {2}  ~{3}GB" -f $d.Slot, $d.State, $d.Media, $d.SizeGB) 'DarkGray'
}

# ТОЛЬКО свободные диски (Unconfigured Good) можно брать в новый массив.
# Online (Onln) диски в существующих массивах - НИКОГДА не трогаем.
$freeDrives = New-Object System.Collections.ArrayList
foreach ($d in $allDrives) {
    if ($d.State -match '^(?i)UGood') { [void]$freeDrives.Add($d) }
}
Write-Log "Free (Unconfigured Good) drives available: $($freeDrives.Count)" 'Cyan'

if ($freeDrives.Count -eq 0) {
    Write-Log "No free (UGood) drives - nothing can be created. All disks are in arrays." 'Yellow'
    Write-Log "(This is expected if the system array uses all disks, or data disks aren't inserted.)" 'Gray'
    exit 0
}

# ===================== ПОДБОР ДИСКОВ + СОЗДАНИЕ =====================
# Резервируем диски пофайлово, чтобы один диск не попал в два массива.
$used = @{}   # Slot -> $true

foreach ($p in $plan) {
    Write-Log "" 'White'
    Write-Log ("--- Group {0}: need {1}x {2} (~{3}GB) for {4} ---" -f $p.Group, $p.Quantity, $p.DiskType, $p.DiskSizeGB, $p.Level) 'Cyan'

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
