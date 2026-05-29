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
echo.
echo Press any key to see options.
echo ==============================================================
pause > nul

set IPDROM_REPLY=
set /p IPDROM_REPLY="Type R and press Enter to RESTORE, or anything else to cancel: "
if /i "%IPDROM_REPLY%"=="R" goto :do_apply

echo Cancelled. Rebooting in 5 seconds...
ping -n 6 127.0.0.1 > nul
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

dism /Capture-Ffu /ImageFile:"%FFU_OUT%" /CaptureDrive:\\.\PhysicalDrive%IPDROM_SYSDISK% /Name:"%FFU_NAME%" /Description:"%FFU_DESC%" >> "%IPDROM_LOG%" 2>&1
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
wmic diskdrive get Index,Model,Size,InterfaceType,MediaType /format:list | findstr /v "^$" >> "%IPDROM_LOG%" 2>&1
wmic diskdrive get Index,Model,Size,InterfaceType,MediaType

echo.
echo Find the SYSTEM DISK (usually Index=0 or Index=1, the internal NVMe/SATA).
echo DO NOT pick the IpdromREC USB - that would erase the recovery image itself.
echo.

set IPDROM_APPLYIDX=
set /p IPDROM_APPLYIDX="Enter disk Index to APPLY recovery to (or just Enter to cancel): "

if not defined IPDROM_APPLYIDX (
    echo Cancelled by user. >> "%IPDROM_LOG%"
    echo Cancelled. Rebooting...
    ping -n 6 127.0.0.1 > nul
    wpeutil reboot
    exit /b 0
)

:: --- Safety check: don't apply to IpdromREC USB itself ---
for /f "tokens=*" %%i in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "(Get-Partition -DriveLetter '%IPDROM_TARGET:~0,1%' -ErrorAction SilentlyContinue).DiskNumber" 2^>nul') do set IPDROM_TGTDISK=%%i
if defined IPDROM_TGTDISK if "%IPDROM_APPLYIDX%"=="%IPDROM_TGTDISK%" (
    echo ERROR: you picked Disk %IPDROM_APPLYIDX% which is the IpdromREC flash itself! >> "%IPDROM_LOG%"
    echo ERROR: you picked Disk %IPDROM_APPLYIDX% which is the IpdromREC flash itself!
    echo ABORT. Press any key to reboot.
    pause > nul
    wpeutil reboot
    exit /b 4
)

:: --- Confirmation ---
echo.
echo ==============================================================
echo  CONFIRMATION REQUIRED
echo ==============================================================
echo About to apply: %IPDROM_TARGET%\restore.ffu
echo Target disk:    PhysicalDrive%IPDROM_APPLYIDX%
echo.
echo This will COMPLETELY ERASE Disk %IPDROM_APPLYIDX%.
echo ALL data on it will be LOST.
echo.
choice /c YN /n /m "Type Y to proceed, N to cancel: "
if errorlevel 2 (
    echo Cancelled by user at confirmation. >> "%IPDROM_LOG%"
    echo Cancelled. Rebooting...
    ping -n 6 127.0.0.1 > nul
    wpeutil reboot
    exit /b 0
)

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

dism /Apply-Ffu /ImageFile:"%IPDROM_TARGET%\restore.ffu" /ApplyDrive:\\.\PhysicalDrive%IPDROM_APPLYIDX% >> "%IPDROM_LOG%" 2>&1
set DISM_EXIT=%ERRORLEVEL%

echo. >> "%IPDROM_LOG%"
echo DISM exit code: %DISM_EXIT% >> "%IPDROM_LOG%"

if %DISM_EXIT% NEQ 0 (
    echo APPLY FAILED with exit code %DISM_EXIT%. >> "%IPDROM_LOG%"
    echo APPLY FAILED. See log: %IPDROM_LOG%
    echo Press any key to reboot.
    pause > nul
    wpeutil reboot
    exit /b %DISM_EXIT%
)

echo === Apply completed successfully === >> "%IPDROM_LOG%"
echo.
echo ==============================================================
echo  RESTORE COMPLETED SUCCESSFULLY
echo ==============================================================
echo Remove the IpdromREC USB and reboot the machine.
echo It will boot into the restored Windows.
echo.
echo Auto-reboot in 30 seconds (or press any key now).
choice /c R /n /t 30 /d R > nul
wpeutil reboot
exit /b 0
