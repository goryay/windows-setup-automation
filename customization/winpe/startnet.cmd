@echo off
:: ==============================================================
:: IPDROM auto-capture WinPE entry point
:: Этот startnet.cmd запускается при boot'е нашего кастомного WinPE.
:: Действие:
::   1. Инициализирует сеть/окружение WinPE
::   2. Находит IpdromREC-партицию (по метке)
::   3. Находит системный диск (тот, где Windows раньше стояла)
::   4. Запускает dism /Capture-Ffu → restore.ffu на IpdromREC
::   5. Логирует всё в IpdromREC\Logs\capture_TIMESTAMP.log
::   6. Перезагружается обратно в Windows
:: ==============================================================

wpeinit

set IPDROM_LOG=
set IPDROM_TARGET=
set IPDROM_SYSDISK=

:: --- Wait for disks to settle (USB/PCIe enumeration) ---
echo Waiting 10 seconds for disks to enumerate...
ping -n 11 127.0.0.1 > nul

:: --- Find IpdromREC volume by label ---
for /f "tokens=2 delims==" %%i in ('wmic logicaldisk where "VolumeName='IpdromREC'" get DeviceID /value 2^>nul ^| find "="') do (
    set IPDROM_TARGET=%%i
)

if not defined IPDROM_TARGET (
    echo ERROR: IpdromREC partition not found by volume label.
    echo Cannot proceed without target. Listing available volumes:
    wmic logicaldisk get DeviceID,VolumeName,Size,FreeSpace
    echo.
    echo Press any key to reboot.
    pause > nul
    wpeutil reboot
    exit /b 1
)

echo Target IpdromREC partition: %IPDROM_TARGET%

:: ==============================================================
:: MODE GATE: что делать в WinPE
::   .capture_pending  есть  → захват системного диска в FFU (auto-pipeline)
::   .capture_pending  нет, restore.ffu есть → интерактивное ВОССТАНОВЛЕНИЕ
::   .capture_pending  нет, restore.ffu нет  → выход (ничего не делаем)
:: ==============================================================
if exist "%IPDROM_TARGET%\.capture_pending" (
    echo .capture_pending marker found - proceeding with auto-capture.
    goto :do_capture
)

if exist "%IPDROM_TARGET%\restore.ffu" goto :recovery_mode

echo No .capture_pending marker and no restore.ffu found on %IPDROM_TARGET%.
echo Nothing to do. Rebooting in 5 seconds...
ping -n 6 127.0.0.1 > nul
wpeutil reboot
exit /b 0

:: ==============================================================
:: RECOVERY MODE (label-based, не multi-line if-блок).
:: Раньше тут был "if exist (..." с многострочным блоком, и cmd-парсер
:: ломался на echo-строках с непаредуемыми парентезами типа (or no key),
:: что приводило к молчаливому ребуту.
:: Также раньше использовался "choice" - которого может не быть в
:: некоторых WinPE-сборках. Сейчас pause + set /p - они точно работают.
:: ==============================================================
:recovery_mode
echo.
echo ==============================================================
echo  RECOVERY MODE
echo ==============================================================
echo Found restore.ffu on %IPDROM_TARGET%
echo.
echo This will RESTORE the system disk from the recovery image.
echo ALL DATA on the system disk will be ERASED.
echo ==============================================================
echo.

:: Интерактив через PowerShell Read-Host - надёжнее чем cmd set /p в WinPE.
:: PS точно работает в этом WinPE (используется для Get-Partition ниже).
set IPDROM_REPLY=
for /f "usebackq delims=" %%i in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "(Read-Host 'Type R and press Enter to RESTORE (anything else cancels)').Trim()"`) do set IPDROM_REPLY=%%i

if /i "%IPDROM_REPLY%"=="R" goto :do_apply

echo Cancelled. Press any key to reboot.
pause > nul
wpeutil reboot
exit /b 0

:do_capture

:: --- Prepare log directory and timestamped log file ---
if not exist "%IPDROM_TARGET%\Logs" mkdir "%IPDROM_TARGET%\Logs"
for /f "tokens=2 delims==" %%i in ('wmic os get LocalDateTime /value ^| find "="') do set DT=%%i
set IPDROM_TIMESTAMP=%DT:~0,8%_%DT:~8,6%
set IPDROM_LOG=%IPDROM_TARGET%\Logs\capture_%IPDROM_TIMESTAMP%.log

echo === IPDROM auto-capture started at %DATE% %TIME% === > "%IPDROM_LOG%"
echo Target volume: %IPDROM_TARGET% >> "%IPDROM_LOG%"

:: --- Enumerate physical disks and find the system disk ---
echo Enumerating physical disks... >> "%IPDROM_LOG%"
wmic diskdrive get Index,Model,Size,InterfaceType,MediaType /format:list >> "%IPDROM_LOG%" 2>&1

:: System disk = the disk that has a Windows partition (NTFS volume with Windows folder).
:: We iterate logical drives looking for \Windows\System32\config\SYSTEM, then map back.
for %%L in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%L:\Windows\System32\config\SYSTEM" (
        echo Windows root found on %%L: >> "%IPDROM_LOG%"
        set IPDROM_SYSDRV=%%L:
        goto :found_sys
    )
)

echo ERROR: No Windows installation found on any volume. >> "%IPDROM_LOG%"
echo ERROR: No Windows installation found on any volume.
type "%IPDROM_LOG%"
echo Press any key to reboot.
pause > nul
wpeutil reboot
exit /b 2

:found_sys
echo System drive letter: %IPDROM_SYSDRV% >> "%IPDROM_LOG%"

:: --- Map drive letter to physical disk index via PowerShell ---
:: PowerShell is available in WinPE and handles Unicode/locale correctly.
:: Avoid diskpart text parsing which is fragile on RU-locale and UTF-16 output.
echo Querying system disk number via PowerShell... >> "%IPDROM_LOG%"
for /f "tokens=*" %%i in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "(Get-Partition -DriveLetter '%IPDROM_SYSDRV:~0,1%' -ErrorAction SilentlyContinue).DiskNumber" 2^>nul') do (
    if not defined IPDROM_SYSDISK set IPDROM_SYSDISK=%%i
)

if not defined IPDROM_SYSDISK (
    echo ERROR: Could not parse disk number for system volume. >> "%IPDROM_LOG%"
    echo ERROR: Could not parse disk number for system volume.
    type "%IPDROM_LOG%"
    pause > nul
    wpeutil reboot
    exit /b 3
)

echo System disk number: %IPDROM_SYSDISK% >> "%IPDROM_LOG%"
echo System disk: PhysicalDrive%IPDROM_SYSDISK%

:: --- Sanity check: don't capture the IpdromREC USB itself ---
:: Get disk number for the IpdromREC partition via PowerShell (locale-independent)
set IPDROM_TGTDISK=
for /f "tokens=*" %%i in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "(Get-Partition -DriveLetter '%IPDROM_TARGET:~0,1%' -ErrorAction SilentlyContinue).DiskNumber" 2^>nul') do (
    if not defined IPDROM_TGTDISK set IPDROM_TGTDISK=%%i
)

if defined IPDROM_TGTDISK (
    echo IpdromREC is on disk %IPDROM_TGTDISK% >> "%IPDROM_LOG%"
    if "%IPDROM_SYSDISK%"=="%IPDROM_TGTDISK%" (
        echo ERROR: system disk and IpdromREC are the same physical drive. ABORT. >> "%IPDROM_LOG%"
        echo ERROR: system disk and IpdromREC are the same physical drive. ABORT.
        type "%IPDROM_LOG%"
        pause > nul
        wpeutil reboot
        exit /b 4
    )
)

:: --- Backup old restore.ffu (if exists) before overwrite ---
if exist "%IPDROM_TARGET%\restore.ffu" (
    echo Backing up existing restore.ffu to restore.old.ffu... >> "%IPDROM_LOG%"
    if exist "%IPDROM_TARGET%\restore.old.ffu" del /f /q "%IPDROM_TARGET%\restore.old.ffu"
    ren "%IPDROM_TARGET%\restore.ffu" restore.old.ffu
)

:: --- Run DISM /Capture-Ffu ---
set FFU_OUT=%IPDROM_TARGET%\restore.ffu
set FFU_NAME=IPDROM-%COMPUTERNAME%-%IPDROM_TIMESTAMP%
set FFU_DESC=Captured %DATE% %TIME% via auto-capture WinPE

echo. >> "%IPDROM_LOG%"
echo === Running DISM /Capture-Ffu === >> "%IPDROM_LOG%"
echo Source : PhysicalDrive%IPDROM_SYSDISK% >> "%IPDROM_LOG%"
echo Target : %FFU_OUT% >> "%IPDROM_LOG%"
echo Name   : %FFU_NAME% >> "%IPDROM_LOG%"
echo. >> "%IPDROM_LOG%"

echo.
echo ==============================================================
echo  Capturing system disk to FFU image...
echo  Source: PhysicalDrive%IPDROM_SYSDISK%
echo  Target: %FFU_OUT%
echo  This takes 5-30 min. Progress bar below.
echo ==============================================================
echo.

:: DISM выводит прогресс-бар на ЭКРАН (без перенаправления в лог),
:: чтобы было видно процесс. Результат (exit code) пишем в лог отдельно ниже.
dism /Capture-Ffu /ImageFile:"%FFU_OUT%" /CaptureDrive:\\.\PhysicalDrive%IPDROM_SYSDISK% /Name:"%FFU_NAME%" /Description:"%FFU_DESC%"
set DISM_EXIT=%ERRORLEVEL%

echo. >> "%IPDROM_LOG%"
echo DISM exit code: %DISM_EXIT% >> "%IPDROM_LOG%"

if %DISM_EXIT% NEQ 0 (
    echo CAPTURE FAILED with exit code %DISM_EXIT%. Restoring old restore.ffu ^(if any^). >> "%IPDROM_LOG%"
    if exist "%FFU_OUT%" del /f /q "%FFU_OUT%"
    if exist "%IPDROM_TARGET%\restore.old.ffu" ren "%IPDROM_TARGET%\restore.old.ffu" restore.ffu
    echo FAILED %DATE% %TIME% exit=%DISM_EXIT% > "%IPDROM_TARGET%\.capture_failed"
    :: Удаляем pending маркер даже на провале, чтобы не зациклиться
    del /f /q "%IPDROM_TARGET%\.capture_pending"
    echo.
    echo Capture FAILED. See log:
    echo   %IPDROM_LOG%
    echo Press any key to reboot.
    pause > nul
    wpeutil reboot
    exit /b %DISM_EXIT%
)

:: --- Success ---
:: ВАЖНО: удаляем .capture_pending ПЕРВЫМ действием, чтобы даже если
:: последующий код повиснет/прервётся - флешка не зациклится на повторном
:: захвате при следующем boot'е.
del /f /q "%IPDROM_TARGET%\.capture_pending"
echo OK %DATE% %TIME% > "%IPDROM_TARGET%\.capture_done"
if exist "%IPDROM_TARGET%\restore.old.ffu" del /f /q "%IPDROM_TARGET%\restore.old.ffu"

:: --- Запоминаем РАЗМЕР исходного диска рядом с образом (12.09.2026) ---
:: Зачем: при восстановлении оператор вводит номер диска вручную, и ошибка стоит
:: дорого. На стенде SL111111-008 в списке рядом стояли системный NVMe на 477 ГБ
:: и архивный массив на 22351 ГБ; выбрать массив ничто не мешало, а подтверждение
:: выглядело точно так же, как при верном выборе - и 22 ТБ данных ушли бы молча.
:: Записанный здесь размер позволяет ветке восстановления заметить несоответствие
:: и потребовать осознанного подтверждения. Ошибка записи НЕ критична: без этого
:: файла проверка просто пропускается (так ведут себя все флешки, собранные ранее).
for /f "tokens=*" %%i in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[math]::Round((Get-Disk -Number %IPDROM_SYSDISK%).Size/1GB)" 2^>nul') do set IPDROM_SRCGB=%%i
if defined IPDROM_SRCGB (
    echo %IPDROM_SRCGB% > "%IPDROM_TARGET%\restore.info"
    echo Source disk size recorded: %IPDROM_SRCGB% GB >> "%IPDROM_LOG%"
) else (
    echo WARN: could not read source disk size - restore.info not written. >> "%IPDROM_LOG%"
)
echo === Capture completed successfully === >> "%IPDROM_LOG%"
echo === Capture completed successfully ===
echo Reboot in 5 seconds...
ping -n 6 127.0.0.1 > nul
wpeutil reboot
exit /b 0

:: ==============================================================
:: RESTORE / APPLY MODE
:: Применяет restore.ffu на физический диск (целевой системный диск).
:: ОСТОРОЖНО: системный диск будет ПОЛНОСТЬЮ перезаписан.
:: ==============================================================
:do_apply
echo.
echo === Apply-Ffu mode starting ===

:: --- Prepare log ---
if not exist "%IPDROM_TARGET%\Logs" mkdir "%IPDROM_TARGET%\Logs"

for /f "tokens=2 delims==" %%i in ('wmic os get LocalDateTime /value ^| find "="') do set DT=%%i
set IPDROM_TIMESTAMP=%DT:~0,8%_%DT:~8,6%
set IPDROM_LOG=%IPDROM_TARGET%\Logs\apply_%IPDROM_TIMESTAMP%.log

echo === IPDROM apply-ffu started at %DATE% %TIME% === > "%IPDROM_LOG%"
echo Target volume: %IPDROM_TARGET% >> "%IPDROM_LOG%"

:: --- Show available disks for user to pick ---
echo.
echo Available physical disks:
echo. >> "%IPDROM_LOG%"
echo Available physical disks: >> "%IPDROM_LOG%"
wmic diskdrive get Index,Model,Size,InterfaceType,MediaType /format:list >> "%IPDROM_LOG%" 2>&1

:: Показываем ТОЛЬКО кандидатов: USB из списка убраны (12.09.2026, замечание
:: тестировщика). Раньше флешки выводились вместе с предупреждением "не выбирай
:: USB" - лишний шум и лишний шанс ошибиться, тем более что выбрать их всё равно
:: не даёт заслон ниже. Полный список дисков по-прежнему уходит в лог (wmic выше),
:: так что для разбора полётов ничего не теряется.
:: Подстраховка: если внутренних дисков не нашлось вовсе (например, системный
:: пришёл через USB-адаптер), показываем ВСЁ - пустой список без объяснений хуже.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$all=@(Get-Disk|Sort-Object Number); $cand=@($all|Where-Object{$_.BusType -ne 'USB'}); if($cand.Count -eq 0){Write-Host 'WARNING: no internal disks detected - listing ALL disks:'; $cand=$all}; $cand|Format-Table Number,FriendlyName,@{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}},BusType,PartitionStyle -AutoSize; $h=$all.Count-$cand.Count; if($h -gt 0){Write-Host ('  (' + $h + ' USB disk(s) hidden - restoring to USB is not supported)')}"

echo.
echo Pick the SYSTEM DISK - the internal NVMe/SATA the server boots from.
echo WARNING: a large RAID volume in this list is the DATA array, not the system disk.
echo Applying the image to it would DESTROY all data stored there.
echo.

:ask_index
:: Интерактив через PowerShell Read-Host - надёжнее cmd set /p в WinPE.
set IPDROM_APPLYIDX=
for /f "usebackq delims=" %%i in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "(Read-Host 'Enter disk Index to APPLY recovery to, or X to cancel').Trim()"`) do set IPDROM_APPLYIDX=%%i

echo Selected disk index: [%IPDROM_APPLYIDX%]
if /i "%IPDROM_APPLYIDX%"=="X" goto :apply_cancel
if not defined IPDROM_APPLYIDX goto :apply_cancel

:: --- Safety check: don't apply to IpdromREC USB itself ---
for /f "tokens=*" %%i in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "(Get-Partition -DriveLetter '%IPDROM_TARGET:~0,1%' -ErrorAction SilentlyContinue).DiskNumber" 2^>nul') do set IPDROM_TGTDISK=%%i
if defined IPDROM_TGTDISK if "%IPDROM_APPLYIDX%"=="%IPDROM_TGTDISK%" (
    echo.
    echo ERROR: Disk %IPDROM_APPLYIDX% is the IpdromREC flash itself. Pick another.
    echo.
    goto :ask_index
)

:: --- Safety check 2: существует ли такой диск, и не USB ли это ---
:: На стенде в списке ДВЕ одинаковые Kingston DataTraveler 3.0. Проверка выше
:: прикрывает только ту, где лежит restore.ffu; вторую (флешку IPDROM) можно было
:: выбрать - и она стёрлась бы молча. Системный диск сервера всегда внутренний
:: NVMe/SATA, поэтому USB как цель отсекаем целиком. Заодно ловим несуществующий
:: индекс: опечатка раньше доходила до подтверждения и падала внутри DISM.
:: Ветка умеет ТОЛЬКО отказать и спросить заново - сама она ничего не выполняет.
set IPDROM_APPLYBUS=
for /f "tokens=*" %%i in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$d = Get-Disk -Number %IPDROM_APPLYIDX% -ErrorAction SilentlyContinue; if ($d) { $d.BusType } else { 'NODISK' }" 2^>nul') do set IPDROM_APPLYBUS=%%i

if /i "%IPDROM_APPLYBUS%"=="NODISK" (
    echo.
    echo ERROR: Disk %IPDROM_APPLYIDX% does not exist. Pick a Number from the list above.
    echo.
    goto :ask_index
)
if not defined IPDROM_APPLYBUS (
    echo.
    echo ERROR: cannot read disk %IPDROM_APPLYIDX% properties. Pick another.
    echo.
    goto :ask_index
)
if /i "%IPDROM_APPLYBUS%"=="USB" (
    echo.
    echo ERROR: Disk %IPDROM_APPLYIDX% is a USB disk ^(bus=%IPDROM_APPLYBUS%^).
    echo The system disk is an internal NVMe/SATA drive - never a USB stick.
    echo.
    goto :ask_index
)

:: --- Safety check 3: размер выбранного диска против размера исходного ---
:: Заслоны выше ловят USB и несуществующий индекс, но НЕ ловят главную опасность -
:: архивный массив. На стенде рядом с системным NVMe (477 ГБ) стоит массив на
:: 22351 ГБ, и подтверждение для него выглядело точно так же, как для верного
:: выбора. Сверяем с размером, записанным при захвате (restore.info).
:: Порог полуторакратный в обе стороны: замена диска на близкий по объёму вопросов
:: не вызовет, а промах в разы - вызовет.
:: Нет restore.info (флешки, собранные до 12.09.2026) - проверка пропускается.
:: Ветка умеет ТОЛЬКО спросить; сама она ничего не выполняет.
set IPDROM_SRCGB=
if exist "%IPDROM_TARGET%\restore.info" for /f "usebackq tokens=1" %%i in ("%IPDROM_TARGET%\restore.info") do set IPDROM_SRCGB=%%i

set IPDROM_TGTGB=
for /f "tokens=*" %%i in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[math]::Round((Get-Disk -Number %IPDROM_APPLYIDX%).Size/1GB)" 2^>nul') do set IPDROM_TGTGB=%%i

if not defined IPDROM_SRCGB goto :size_ok
if not defined IPDROM_TGTGB goto :size_ok

set /a IPDROM_SIZEBAD=0
set /a "IPDROM_T2=%IPDROM_TGTGB%*2"
set /a "IPDROM_S3=%IPDROM_SRCGB%*3"
if %IPDROM_T2% GTR %IPDROM_S3% set /a IPDROM_SIZEBAD=1
set /a "IPDROM_S2=%IPDROM_SRCGB%*2"
set /a "IPDROM_T3=%IPDROM_TGTGB%*3"
if %IPDROM_S2% GTR %IPDROM_T3% set /a IPDROM_SIZEBAD=1
if %IPDROM_SIZEBAD%==0 goto :size_ok

echo.
echo ==============================================================
echo  !!! SIZE MISMATCH !!!
echo ==============================================================
echo Recovery image was captured from a %IPDROM_SRCGB% GB disk.
echo Disk %IPDROM_APPLYIDX% is %IPDROM_TGTGB% GB.
echo.
echo This is very likely the DATA array, not the system disk.
echo Restoring here would DESTROY every file stored on it.
echo ==============================================================
echo.
echo SIZE MISMATCH: image %IPDROM_SRCGB% GB vs disk %IPDROM_APPLYIDX% = %IPDROM_TGTGB% GB >> "%IPDROM_LOG%"
set IPDROM_ERASE=
for /f "usebackq delims=" %%i in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "(Read-Host 'Type ERASE in capitals to continue anyway, or X to pick another disk').Trim()"`) do set IPDROM_ERASE=%%i
:: Сравнение БЕЗ /i - нужны именно заглавные. 'Y' жмут не глядя, слово - набирают осознанно.
if not "%IPDROM_ERASE%"=="ERASE" goto :ask_index
echo Operator confirmed ERASE despite size mismatch. >> "%IPDROM_LOG%"

:size_ok

:: --- Confirmation ---
echo.
echo ==============================================================
echo  CONFIRMATION REQUIRED
echo ==============================================================
echo About to apply: %IPDROM_TARGET%\restore.ffu
echo Target disk:    PhysicalDrive%IPDROM_APPLYIDX%
echo.
echo This will COMPLETELY ERASE Disk %IPDROM_APPLYIDX%. ALL data lost.
echo.
set IPDROM_CONFIRM=
for /f "usebackq delims=" %%i in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "(Read-Host 'Type Y to proceed, anything else cancels').Trim()"`) do set IPDROM_CONFIRM=%%i
if /i not "%IPDROM_CONFIRM%"=="Y" goto :apply_cancel

:: --- Run DISM /Apply-Ffu ---
echo. >> "%IPDROM_LOG%"
echo === Running DISM /Apply-Ffu === >> "%IPDROM_LOG%"
echo Source : %IPDROM_TARGET%\restore.ffu >> "%IPDROM_LOG%"
echo Target : PhysicalDrive%IPDROM_APPLYIDX% >> "%IPDROM_LOG%"
echo. >> "%IPDROM_LOG%"

echo.
echo Applying image... this will take 5-30 minutes depending on disk speed.
echo Progress is shown below.
echo.

dism /Apply-Ffu /ImageFile:"%IPDROM_TARGET%\restore.ffu" /ApplyDrive:\\.\PhysicalDrive%IPDROM_APPLYIDX%
set DISM_EXIT=%ERRORLEVEL%

echo. >> "%IPDROM_LOG%"
echo DISM exit code: %DISM_EXIT% >> "%IPDROM_LOG%"

if not "%DISM_EXIT%"=="0" goto :apply_failed

echo === Apply completed successfully === >> "%IPDROM_LOG%"
echo.
echo ==============================================================
echo  RESTORE COMPLETED SUCCESSFULLY
echo ==============================================================
echo Remove the IpdromREC USB and reboot the machine.
echo It will boot into the restored Windows.
echo.
echo Press any key to reboot.
pause > nul
wpeutil reboot
exit /b 0

:apply_cancel
echo Cancelled by user. >> "%IPDROM_LOG%"
echo.
echo Apply cancelled. Press any key to reboot.
pause > nul
wpeutil reboot
exit /b 0

:apply_failed
echo APPLY FAILED with exit code %DISM_EXIT%. >> "%IPDROM_LOG%"
echo.
echo ==============================================================
echo  APPLY FAILED (exit %DISM_EXIT%)
echo ==============================================================
echo See log: %IPDROM_LOG%
echo Press any key to reboot.
pause > nul
wpeutil reboot
exit /b %DISM_EXIT%
