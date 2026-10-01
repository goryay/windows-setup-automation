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

# === ЛОГИ С ФЛЕШКИ: СНАЧАЛА НА СЕРВЕР, ПОТОМ УБРАТЬ (01.10.2026, претензия производства) ===
# На флешке восстановления оставались наши служебные логи (IpdromREC\Logs\capture_*.log
# и apply_*.log) и уезжали к заказчику. Просто удалить их нельзя - по ним разбирают
# прогоны. Поэтому: собираем архив, отправляем на сервер отчётов и удаляем с флешки
# ТОЛЬКО при подтверждённом ответе 2xx. Не подтвердилось - логи остаются на месте,
# диагностика важнее косметики.
#
# Блок стоит ЗДЕСЬ, а не рядом с остальной отправкой ниже, по одной причине: ниже
# diskpart уже перевёл диск в readonly, и удалить с флешки что-либо физически
# невозможно. Всё, что пишет на флешку, обязано выполниться до него.
#
# Вся логика завёрнута в try/catch без проброса: сбой выгрузки логов не имеет права
# помешать защите флешки, которая идёт следом.
#
# ЧЕГО ЭТОТ БЛОК НЕ ДЕЛАЕТ: не чистит C:\ProgramData\IPDROM\Logs. Образ FFU снят
# РАНЬШЕ этого скрипта, логи уже внутри него, и удаление сейчас почистит только
# живой диск, но не образ - при восстановлении они вернутся. Чтобы они не попадали
# в образ, выгружать их надо ДО захвата; это отдельная задача по отчётности.
# Здесь они просто попадают в архив, чтобы прогон разбирался целиком.
try {
    $slTag = ''
    try { $slTag = (Get-ItemProperty -Path 'HKLM:\Software\IPDROM' -Name 'SL' -ErrorAction SilentlyContinue).SL } catch {}
    if (-not $slTag) { $slTag = $env:COMPUTERNAME }

    $flashLogDir = Join-Path $recRoot 'Logs'
    $flashLogs   = @(Get-ChildItem -LiteralPath $flashLogDir -File -ErrorAction SilentlyContinue)
    W ("Flash logs found in {0}: {1} file(s)." -f $flashLogDir, $flashLogs.Count)

    if ($flashLogs.Count -eq 0) {
        W 'Nothing to collect from the flash - skipping log delivery.'
    } else {
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $stage = Join-Path $env:TEMP ("ipdrom_logs_{0}" -f $stamp)
        $zip   = Join-Path $env:TEMP ("{0}_logs_{1}.zip" -f $slTag, $stamp)

        New-Item -ItemType Directory -Path (Join-Path $stage 'winpe')   -Force -ErrorAction SilentlyContinue | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $stage 'windows') -Force -ErrorAction SilentlyContinue | Out-Null

        foreach ($f in $flashLogs) {
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $stage 'winpe') -Force -ErrorAction SilentlyContinue
        }
        $winLogs = @(Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue)
        foreach ($f in $winLogs) {
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $stage 'windows') -Force -ErrorAction SilentlyContinue
        }
        W ("Staged for upload: {0} WinPE log(s) + {1} Windows log(s)." -f $flashLogs.Count, $winLogs.Count)

        # Контекст прямо в архив, чтобы по нему было видно машину без сверки с базой.
        $facts = @"
SL:            $slTag
Компьютер:     $env:COMPUTERNAME
Собрано:       $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
restore.ffu:   $ffuGB ГБ
Флешка:        $($disk.FriendlyName) (диск $diskNum, шина $busType)
Разделов:      $($partitions.Count)
Логи WinPE:    $($flashLogs.Count) шт. из $flashLogDir
Логи Windows:  $($winLogs.Count) шт. из $logDir
"@
        Set-Content -LiteralPath (Join-Path $stage 'capture_facts.txt') -Value $facts -Encoding utf8

        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force -ErrorAction Stop
        $zipKB = [math]::Round((Get-Item -LiteralPath $zip).Length / 1KB, 1)
        W ("Log archive created: {0} ({1} KB)" -f $zip, $zipKB)

        # Выгрузка. Удаляем с флешки ТОЛЬКО по подтверждённому HTTP 2xx.
        $uploadOk = $false
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            $formArg = 'file=@"' + $zip + '"'
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                # --max-time 300: архив логов больше текстовой сводки, но всё равно
                # счёт на сотни килобайт. Ограничение обязательно - скрипт идёт в
                # видимой консоли уже собранной машины, висеть ему нельзя.
                $up    = & curl.exe -sS --max-time 300 -F $formArg -w "`nHTTPSTATUS=%{http_code}`n" 'http://10.0.6.41:3000/ulrep' 2>&1
                $upExit = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $prevEap
            }
            foreach ($l in ($up -split "`r?`n")) { if ($l.Trim()) { W "  | $l" } }
            $httpCode = ''
            foreach ($l in ($up -split "`r?`n")) {
                if ($l -match 'HTTPSTATUS=(\d{3})') { $httpCode = $matches[1] }
            }
            W ("Log archive upload: curl exit={0} http={1}" -f $upExit, $(if ($httpCode) { $httpCode } else { '<none>' }))
            if ($upExit -eq 0 -and $httpCode -match '^2\d\d$') { $uploadOk = $true }
        } else {
            W 'curl.exe not found - cannot deliver log archive.'
        }

        if ($uploadOk) {
            $wiped = 0
            foreach ($f in $flashLogs) {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path -LiteralPath $f.FullName)) { $wiped++ }
            }
            W ("Upload CONFIRMED - removed {0} of {1} log file(s) from the flash. Folder {2} left in place for future restores." -f $wiped, $flashLogs.Count, $flashLogDir)
            if ($wiped -lt $flashLogs.Count) {
                W ("  WARN: {0} log file(s) could not be removed and will ship on the flash." -f ($flashLogs.Count - $wiped))
            }
        } else {
            W 'Upload NOT confirmed - flash logs deliberately KEPT so the run can still be investigated.'
        }

        Remove-Item -LiteralPath $zip   -Force -Recurse -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stage -Force -Recurse -ErrorAction SilentlyContinue
    }
} catch {
    W "Flash log delivery failed (non-fatal, flash protection continues): $_"
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

# --- Доставка итога захвата на сервер отчётов (11.09.2026) ---
# Отчёт машины формируется на этапе [4.5/7] и уезжает на сервер на [6/7] - за
# несколько часов до того, как FFU вообще появится ([6.7/7], уже после перезагрузки
# в WinPE). Подтвердить наличие образа он физически не мог, и машина с провалившимся
# захватом выглядела в отчёте ровно как машина с успешным.
# Все нужные проверки сделаны ВЫШЕ (.capture_failed / наличие restore.ffu / размер
# не меньше 5 ГБ) - до этой строки скрипт доходит только при подтверждённом образе.
# Не хватало одной доставки, её и добавляем.
#
# Блок стоит ПОСЛЕ diskpart намеренно: защита флешки к этому моменту уже выполнена,
# поэтому никакая ошибка здесь не может ей помешать. Копию на саму флешку не пишем -
# диск уже переведён в readonly, и ради текстового файла снимать защиту нельзя.
try {
    $slName = ''
    try { $slName = (Get-ItemProperty -Path 'HKLM:\Software\IPDROM' -Name 'SL' -ErrorAction SilentlyContinue).SL } catch {}
    if (-not $slName) { $slName = $env:COMPUTERNAME }

    $captureTxt  = Join-Path $stateDir ("{0}_capture.txt" -f $slName)
    $captureBody = @"
SL:            $slName
Захват FFU:    ПОДТВЕРЖДЁН
restore.ffu:   $ffuGB ГБ
Проверено:     $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Флешка:        $($disk.FriendlyName) (диск $diskNum, шина $busType)
Разделов:      $($partitions.Count) - скрыты, диск переведён в readonly
"@
    Set-Content -LiteralPath $captureTxt -Value $captureBody -Encoding utf8
    W "Capture summary written: $captureTxt"

    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        # EAP='Continue' на время вызова обязателен: curl с -sS пишет ошибки связи в
        # stderr, а '2>&1' превращает их в ErrorRecord - при 'Stop' это терминирующая
        # ошибка. Та же причина, по которой недоступность сервера когда-то роняла
        # весь конвейер (см. комментарий в auto_stress_test.ps1).
        $formArg = 'file=@"' + $captureTxt + '"'
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            # --max-time ОБЯЗАТЕЛЕН: этот скрипт выполняется при первом входе уже
            # собранной машины, в видимой консоли. Если сервер отчётов примет
            # соединение и замолчит, curl по умолчанию будет ждать минутами, и
            # заказчик увидит висящее окно. Файл крошечный, 60 с хватит с запасом.
            $out  = & curl.exe -sS --max-time 60 -F $formArg -w "`nHTTPSTATUS=%{http_code}`n" 'http://10.0.6.41:3000/ulrep' 2>&1
            $cExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
        }
        foreach ($l in ($out -split "`r?`n")) { if ($l.Trim()) { W "  | $l" } }
        W "Capture summary upload: curl exit=$cExit"
    } else {
        W "curl.exe not found - capture summary kept locally only."
    }
} catch {
    W "Capture summary delivery failed (non-fatal, flash is already protected): $_"
}

# Self-remove scheduled task
try {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    W "Unregistered scheduled task '$taskName'."
} catch {}

# --- УБОРКА СЛУЖЕБНЫХ СКРИПТОВ (30.09.2026, приёмка производства) ---
# В образ уезжали скрипты конвейера и попадали на машину заказчика. Убрать их
# ДО захвата нельзя: этот скрипт сам запускается уже после него, а два соседних
# нужны до самого ребута в WinPE. Поэтому уборщиком назначен этот скрипт - он
# и так выполняется ровно один раз после захвата и снимает себя с расписания.
#
# Сюда МЫ ДОШЛИ только при подтверждённом образе: все ранние выходы (нет
# restore.ffu, сработал .capture_failed, размер меньше 5 ГБ, diskpart упал)
# расположены выше. Если что-то пошло не так - скрипты останутся на месте и
# запуск можно повторить.
#
# НЕ ТРОГАЕМ намеренно:
#   Logs\   - по ним разбираются прогоны. С 01.10.2026 они уезжают на сервер в
#             архиве (блок выгрузки выше), но удалять их здесь всё равно смысла
#             нет: образ FFU снят РАНЬШЕ этого скрипта, логи уже внутри него, и
#             очистка живого диска из образа их не уберёт. Чтобы они не попадали
#             в образ, выгружать надо ДО захвата - отдельная задача.
#   State\  - маркер защиты и <SL>_capture.txt, это записи о машине, не мусор
#   C:\WinPE - там же висит скрытая запись BCD, указывающая на boot.wim внутри.
#             Снести каталог без удаления записи - оставить битый пункт загрузки,
#             поэтому только вместе и отдельным заходом.
try {
    $scriptsDir = Join-Path $env:ProgramData 'IPDROM\Scripts'
    $self       = $PSCommandPath

    $junk = @(
        (Join-Path $scriptsDir 'launch_auto_stress_after_reboot.ps1'),
        (Join-Path $scriptsDir 'Invoke-FfuCaptureReboot.ps1'),
        (Join-Path $env:ProgramData 'IPDROM_StressTest_Completed.flag')
    )

    $removed = 0
    foreach ($p in $junk) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $p) {
            W "  cleanup: could not remove $p"
        } else {
            W "  cleanup: removed $(Split-Path $p -Leaf)"
            $removed++
        }
    }
    W "Pipeline scripts cleanup: $removed item(s) removed."

    # Себя - последним, и только если в каталоге не осталось чужого.
    if ($self -and (Test-Path -LiteralPath $self)) {
        Remove-Item -LiteralPath $self -Force -ErrorAction SilentlyContinue
        W "  cleanup: removed self ($([System.IO.Path]::GetFileName($self)))"
    }
    if (Test-Path -LiteralPath $scriptsDir) {
        $left = @(Get-ChildItem -LiteralPath $scriptsDir -Force -ErrorAction SilentlyContinue)
        if ($left.Count -eq 0) {
            Remove-Item -LiteralPath $scriptsDir -Force -ErrorAction SilentlyContinue
            W "  cleanup: removed empty Scripts folder."
        } else {
            W ("  cleanup: Scripts folder kept, {0} item(s) still inside: {1}" -f $left.Count, (($left | ForEach-Object { $_.Name }) -join ', '))
        }
    }
} catch {
    W "Pipeline scripts cleanup failed (non-fatal, flash is already protected): $_"
}

exit 0
