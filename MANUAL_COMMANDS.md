# IPDROM — справочник ручных команд

Команды, использованные при отладке и тестировании пайплайна стресс-теста + создания FFU-образа. Запускать в **PowerShell от администратора**. Многие команды используют буквы дисков (G:, H:, J:, K: и т.д.) — **заменяй на актуальные** для своей машины.

---

## 1. Запуск стресс-теста

### Полный 30-минутный прогон с начала пайплайна
```powershell
Remove-Item 'C:\ProgramData\IPDROM_StressTest_Completed.flag' -Force -ErrorAction SilentlyContinue
& "G:\customization\scripts\auto_stress_test.ps1" -DurationMinutes 30
```
Удаляет флаг «уже отработано» (иначе launcher выйдет с «Stress test already completed») и запускает полный 30-минутный стресс. Замени `G:` на букву, под которой смонтирована Test ISO флешка.

### Найти, на какой букве сейчас Test ISO флешка
```powershell
Get-Volume | Where-Object { $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\customization\scripts\auto_stress_test.ps1") } | Select-Object DriveLetter, FileSystemLabel
```

### Tail логов стресс-теста в реальном времени
```powershell
Get-ChildItem C:\ProgramData\IPDROM\Logs\aida_fio_furmark_*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { Get-Content $_.FullName -Wait }
```
Открывает свежий лог aida_fio_furmark и держит его открытым (Ctrl+C для выхода). Не мешает идущему тесту.

### Tail логов orchestrator-скрипта
```powershell
Get-ChildItem C:\ProgramData\IPDROM\Logs\auto_stress_test_*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { Get-Content $_.FullName -Wait }
```

---

## 2. Создание FFU-образа

### Фаза 2 — пропатчить boot.wim из репозитория
```powershell
& "D:\TestISO\customization\scripts\Patch-BootWim.ps1"
```
Берёт `customization\winpe\boot.wim`, инжектирует наш `startnet.cmd` + `winpeshl.ini`, сохраняет как `boot_patched.wim` рядом. Без аргументов использует дефолтные пути из репо.

### Фаза 3 — подготовить IpdromREC флешку
```powershell
& "D:\TestISO\customization\scripts\Prepare-IpdromRecFlash.ps1"
```
Находит USB-флешку (32-256 GB), отсекает Ventoy и чужие. Если флешка уже наша → REFRESH (только обновить boot.wim). Если пустая → FRESH (разметить с нуля: WINRE FAT32 + IpdromREC NTFS, поставить EFI-бутлоадер).

### Фаза 4 — триггер захвата (dry-run)
```powershell
& "D:\TestISO\customization\scripts\Invoke-FfuCaptureReboot.ps1" -NoReboot
```
Подготавливает всё (пишет `.capture_pending`, ставит UEFI BootNext), **но не перезагружает машину**. Полезно для проверки, что BootNext успешно ставится.

### Фаза 4 — реальный захват с reboot в WinPE
```powershell
& "D:\TestISO\customization\scripts\Invoke-FfuCaptureReboot.ps1"
```
То же самое + `Restart-Computer -Force` через 10 секунд. Машина грузится в WinPE, делает захват, возвращается в Windows. На захват уйдёт ~5-30 минут в зависимости от размера системного диска и скорости флешки.

### Проверить результат захвата
```powershell
Get-Item 'K:\restore.ffu' -ErrorAction SilentlyContinue | Select-Object Name, @{n='SizeGB';e={[math]::Round($_.Length/1GB,2)}}, LastWriteTime
Get-Content 'K:\.capture_done' -ErrorAction SilentlyContinue
Get-Content 'K:\.capture_failed' -ErrorAction SilentlyContinue
Get-ChildItem 'K:\Logs\capture_*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { Get-Content $_.FullName | Select-Object -Last 30 }
```
Замени `K:` на букву IpdromREC.

### Очистить маркеры перед повторным запуском
```powershell
Remove-Item 'K:\.capture_pending','K:\.capture_done','K:\.capture_failed' -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\ProgramData\IPDROM_StressTest_Completed.flag' -Force -ErrorAction SilentlyContinue
bcdedit /deletevalue "{fwbootmgr}" bootsequence 2>&1 | Out-Null
```

---

## 3. Работа с boot.wim

### Смонтировать boot.wim только на чтение
```powershell
$mount = "$env:TEMP\wim_mount"
New-Item -ItemType Directory -Force -Path $mount | Out-Null
dism /Mount-Wim /WimFile:"D:\TestISO\customization\winpe\boot_patched.wim" /Index:1 /MountDir:$mount /ReadOnly
```

### Проверить содержимое смонтированного boot.wim
```powershell
$mount = "$env:TEMP\wim_mount"
Get-Content "$mount\Windows\System32\startnet.cmd" | Select-Object -First 20
Get-Content "$mount\Windows\System32\winpeshl.ini"
Get-ChildItem "$mount\Windows\System32\*.original" -ErrorAction SilentlyContinue | Select-Object Name, Length
```

### Размонтировать без сохранения
```powershell
dism /Unmount-Wim /MountDir:"$env:TEMP\wim_mount" /Discard
```

### Найти все boot.wim файлы на доступных дисках
```powershell
Get-Volume | Where-Object { $_.FileSystem -in 'FAT32','NTFS' -and $_.DriveLetter } | ForEach-Object {
    $path = "$($_.DriveLetter):\sources\boot.wim"
    if (Test-Path $path) {
        [pscustomobject]@{
            Drive  = "$($_.DriveLetter):"
            Label  = $_.FileSystemLabel
            BootWim = $path
            SizeMB = [math]::Round((Get-Item $path).Length / 1MB, 1)
        }
    }
}
```

---

## 4. UEFI / BootNext

### Проверить, что машина в UEFI режиме
```powershell
$env:firmware_type
```
Должно вернуть `Uefi`. Если `Legacy` — наш BootNext-механизм работать не будет.

### Посмотреть все UEFI boot entries
```powershell
bcdedit /enum firmware
```

### Проверить, стоит ли BootNext (одноразовая загрузка)
```powershell
bcdedit /enum "{fwbootmgr}" | Select-String "bootsequence"
```

### Сбросить BootNext (отменить запланированный boot с флешки)
```powershell
bcdedit /deletevalue "{fwbootmgr}" bootsequence
```

---

## 5. Диагностика дисков и флешек

### Полная таблица всех дисков системы
```powershell
Get-Disk | Format-Table Number, FriendlyName, BusType, IsRemovable, @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}}, OperationalStatus, PartitionStyle -AutoSize
```

### Список всех томов
```powershell
Get-Volume | Format-Table DriveLetter, FileSystemLabel, FileSystem, @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}}, @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}} -AutoSize
```

### Найти WINRE и IpdromREC партиции (наши)
```powershell
Get-Volume | Where-Object FileSystemLabel -in 'WINRE','IpdromREC' | Format-Table DriveLetter, FileSystemLabel, FileSystem, @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}}, @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}} -AutoSize
```

### Список всех файлов на WINRE партиции (для проверки бутлоадера)
```powershell
$winreLetter = (Get-Volume | Where-Object FileSystemLabel -eq 'WINRE' | Select-Object -First 1).DriveLetter
Get-ChildItem "${winreLetter}:\" -Recurse -File | Select-Object @{n='RelPath';e={$_.FullName.Substring(3)}}, Length | Format-Table -AutoSize
```

---

## 6. Power management (фикс зависаний во время Start-Sleep)

### Посмотреть, какой sleep timeout стоит сейчас
```powershell
powercfg -attributes SUB_SLEEP 7bc4a2f9-d8fc-4469-b07b-33eb785aaca0 -ATTRIB_HIDE
powercfg /Query SCHEME_CURRENT SUB_SLEEP 7bc4a2f9-d8fc-4469-b07b-33eb785aaca0
```
По умолчанию `0x00000078` (120 сек = 2 мин) — это и был виновник сдвига таймингов скриншотов AIDA в чистой Windows.

### Полностью отключить все режимы сна
```powershell
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /change disk-timeout-ac 0
powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_SLEEP 7bc4a2f9-d8fc-4469-b07b-33eb785aaca0 0
powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_SLEEP 7bc4a2f9-d8fc-4469-b07b-33eb785aaca0 0
powercfg /SETACTIVE SCHEME_CURRENT
```

---

## 7. Pagefile (фикс STATUS_COMMITMENT_LIMIT при стрессе)

### Проверить текущий размер pagefile
```powershell
Get-CimInstance Win32_PageFileUsage | Select-Object Name, AllocatedBaseSize, CurrentUsage, PeakUsage
Get-CimInstance Win32_OperatingSystem | Select-Object @{n='TotalRAM_GB';e={[math]::Round($_.TotalVisibleMemorySize/1MB,1)}}, @{n='CommitLimit_GB';e={[math]::Round($_.TotalVirtualMemorySize/1MB,1)}}, @{n='CommitPeak_GB';e={[math]::Round(($_.TotalVirtualMemorySize - $_.FreeVirtualMemory)/1MB,1)}}
```

### Поставить фиксированный pagefile 16-32 GB (требует перезагрузки)
```powershell
$cs = Get-CimInstance Win32_ComputerSystem
$cs | Set-CimInstance -Property @{ AutomaticManagedPagefile = $false }
Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | Remove-CimInstance -ErrorAction SilentlyContinue
New-CimInstance -ClassName Win32_PageFileSetting -Property @{
    Name        = 'C:\pagefile.sys'
    InitialSize = 16384
    MaximumSize = 32768
}
"Pagefile установлен 16-32 GB. РЕБУТ обязателен для применения."
```

---

## 8. GPU / FurMark / Vulkan

### Проверить какие GPU видны системе
```powershell
nvidia-smi
```

### Мониторинг GPU в реальном времени (обновление раз в секунду)
```powershell
nvidia-smi -l 1
```

### Информация о Vulkan-устройствах
```powershell
& "C:\Windows\System32\vulkaninfo.exe" --summary
```

### Тест FurMark на конкретной GPU вручную
```powershell
Start-Process -FilePath 'G:\SoftForTest\FurMark\furmark.exe' -ArgumentList '--demo','furmark-vk','--gpu-index','1','--width','1920','--height','1080','--max-time','60','--no-score-box','--disable-demo-options'; Start-Sleep 30; nvidia-smi
```
Запускает FurMark на GPU 1 (можно поменять на 0) на 60 секунд, после паузы покажет nvidia-smi для проверки нагрузки. Замени `G:` на букву Test ISO флешки.

---

## 9. Отчёты и архивы

### Найти последний созданный архив на рабочем столе
```powershell
Get-ChildItem "$env:USERPROFILE\Desktop\$env:COMPUTERNAME`_*.zip" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Select-Object Name, @{n='SizeMB';e={[math]::Round($_.Length/1MB,1)}}, LastWriteTime, FullName
```

### Ручная отправка последнего архива на сервер
```powershell
$archive = Get-ChildItem "$env:USERPROFILE\Desktop\$env:COMPUTERNAME`_*.zip" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $archive) { "Архив не найден"; return }
"Заливаю: $($archive.Name) ($([math]::Round($archive.Length/1MB,1)) MB)"
& curl.exe -sS -F ('file=@"' + $archive.FullName + '"') -w "`nHTTPSTATUS=%{http_code}`n" "http://10.0.6.41:3000/ulrep"
"Exit: $LASTEXITCODE"
```

### Список папок отчётов и скриншотов
```powershell
$reportsDir = Join-Path "$env:USERPROFILE\Desktop\$env:COMPUTERNAME" 'Reports'
$screensDir = Join-Path "$env:USERPROFILE\Desktop\$env:COMPUTERNAME" 'Screens'
"--- Reports ---"
Get-ChildItem $reportsDir -ErrorAction SilentlyContinue | Format-Table Name, Length, LastWriteTime -AutoSize
"--- Screens ---"
Get-ChildItem $screensDir -ErrorAction SilentlyContinue | Format-Table Name, Length, LastWriteTime -AutoSize
```

---

## 10. События системы (диагностика проблем)

### События виртуальной памяти / OOM
```powershell
Get-WinEvent -LogName System -MaxEvents 100 | Where-Object { $_.Id -in 2004,26 } | Format-Table TimeCreated, Id, ProviderName, @{n='Msg';e={$_.Message.Substring(0,[Math]::Min(120,$_.Message.Length))}} -AutoSize
```

### События WHEA (аппаратные ошибки)
```powershell
Get-WinEvent -LogName System -MaxEvents 50 | Where-Object { $_.ProviderName -like '*WHEA*' } | Format-Table TimeCreated, Id, @{n='Msg';e={$_.Message.Substring(0,[Math]::Min(120,$_.Message.Length))}}
```

### Boot/Shutdown события
```powershell
Get-WinEvent -LogName System -MaxEvents 50 | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Kernel-General' -and $_.Id -in 12,13 } | Format-Table TimeCreated, Id, @{n='Msg';e={$_.Message.Substring(0,[Math]::Min(120,$_.Message.Length))}}
```

### Kernel-Power (нештатные перезагрузки/BSOD)
```powershell
Get-WinEvent -LogName System -MaxEvents 50 | Where-Object { $_.Id -eq 41 -and $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' } | Format-Table TimeCreated, Id, @{n='Msg';e={$_.Message.Substring(0,[Math]::Min(120,$_.Message.Length))}}
```

---

## 11. Watchdog (на случай зависшего теста)

### Удалить scheduled task watchdog (если стресс завис, но машина ещё жива)
```powershell
Unregister-ScheduledTask -TaskName IPDROM_Watchdog_Reboot -Confirm:$false -ErrorAction SilentlyContinue
```

### Принудительно остановить все стресс-приложения
```powershell
Get-Process furmark, AIDA64Port, AIDA64BusinessPortable, aida64, fio -ErrorAction SilentlyContinue | Stop-Process -Force
Unregister-ScheduledTask -TaskName IPDROM_Watchdog_Reboot -Confirm:$false -ErrorAction SilentlyContinue
```

---

## 12. Чек-лист «всё ли готово к боевому прогону»

Запускать на свежей установке Windows перед началом стресса:

```powershell
"=== Pagefile ===";     Get-CimInstance Win32_PageFileUsage | Select-Object Name, AllocatedBaseSize
"=== Power: standby timeout ===";  powercfg /Query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE
"=== Power: unattended sleep ==="; powercfg -attributes SUB_SLEEP 7bc4a2f9-d8fc-4469-b07b-33eb785aaca0 -ATTRIB_HIDE; powercfg /Query SCHEME_CURRENT SUB_SLEEP 7bc4a2f9-d8fc-4469-b07b-33eb785aaca0 | Select-String "Текущ"
"=== Firmware type ==="; $env:firmware_type
"=== GPUs ===";          nvidia-smi --query-gpu=index,name --format=csv
"=== USB drives ===";    Get-Disk | Where-Object BusType -eq 'USB' | Format-Table Number, FriendlyName, @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}}, PartitionStyle -AutoSize
"=== Free space C: ==="; Get-PSDrive C | Select-Object @{n='FreeGB';e={[math]::Round($_.Free/1GB,1)}}
"=== Boot.wim в репо ==="; Get-Item D:\TestISO\customization\winpe\boot_patched.wim -ErrorAction SilentlyContinue | Select-Object FullName, @{n='SizeMB';e={[math]::Round($_.Length/1MB,1)}}
```

Идеальное состояние:
- AllocatedBaseSize >= 16384 (16 GB pagefile)
- Текущий AC index у unattended sleep = `0x00000000`
- firmware_type = `Uefi`
- nvidia-smi показывает все ожидаемые карты
- USB-диски в правильном диапазоне
- boot_patched.wim существует, ~500-600 MB
