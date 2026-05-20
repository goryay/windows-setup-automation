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
:: SAFETY GATE: захват выполняется ТОЛЬКО при наличии маркера
:: .capture_pending на IpdromREC. Маркер кладёт Windows-side скрипт
:: непосредственно перед reboot'ом в WinPE.
:: Если оператор случайно бутнулся с флешки без триггера из Windows —
:: мы НИЧЕГО не делаем, просто перезагружаемся обратно.
:: ==============================================================
if not exist "%IPDROM_TARGET%\.capture_pending" (
    echo No .capture_pending marker found on %IPDROM_TARGET%
    echo This boot was not triggered by IPDROM auto-capture pipeline.
    echo Rebooting back to default boot device in 5 seconds...
    ping -n 6 127.0.0.1 > nul
    wpeutil reboot
    exit /b 0
)

echo .capture_pending marker found — proceeding with auto-capture.

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

:: --- Map drive letter to physical disk index via diskpart ---
echo list disk > "%TEMP%\dp_list.txt"
echo exit >> "%TEMP%\dp_list.txt"
diskpart /s "%TEMP%\dp_list.txt" >> "%IPDROM_LOG%" 2>&1

:: Find disk that contains the system drive. PowerShell-free method via diskpart:
:: SELECT VOLUME (letter) → DETAIL VOLUME shows Disk ###
set DPSCRIPT=%TEMP%\dp_detail.txt
echo select volume %IPDROM_SYSDRV:~0,1% > "%DPSCRIPT%"
echo detail volume >> "%DPSCRIPT%"
echo exit >> "%DPSCRIPT%"

set DETAIL=%TEMP%\dp_detail_out.txt
diskpart /s "%DPSCRIPT%" > "%DETAIL%" 2>&1
type "%DETAIL%" >> "%IPDROM_LOG%"

:: Parse selected disk row — locale-independent.
:: detail volume marks the disk row containing the selected volume with "*".
:: Format (RU): "* Диск N    В сети ..."  /  (EN): "* Disk N    Online ..."
:: We grep for lines starting with "*" then take 3rd whitespace token (the number).
for /f "tokens=3" %%i in ('findstr /R "^[ ]*\*" "%DETAIL%" 2^>nul') do (
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
:: Get disk number for the IpdromREC partition for comparison
set DPSCRIPT2=%TEMP%\dp_check_target.txt
echo select volume %IPDROM_TARGET:~0,1% > "%DPSCRIPT2%"
echo detail volume >> "%DPSCRIPT2%"
echo exit >> "%DPSCRIPT2%"
set DETAIL2=%TEMP%\dp_target_out.txt
diskpart /s "%DPSCRIPT2%" > "%DETAIL2%" 2>&1

set IPDROM_TGTDISK=
for /f "tokens=3" %%i in ('findstr /R "^[ ]*\*" "%DETAIL2%" 2^>nul') do (
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
    echo CAPTURE FAILED with exit code %DISM_EXIT%. Restoring old restore.ffu (if any). >> "%IPDROM_LOG%"
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
if exist "%IPDROM_TARGET%\restore.old.ffu" del /f /q "%IPDROM_TARGET%\restore.old.ffu"
echo OK %DATE% %TIME% > "%IPDROM_TARGET%\.capture_done"
:: Удаляем pending маркер, чтобы при следующем boot'е с этой флешки
:: WinPE сразу ушёл в reboot без повторного захвата
del /f /q "%IPDROM_TARGET%\.capture_pending"
echo === Capture completed successfully === >> "%IPDROM_LOG%"
echo === Capture completed successfully ===
echo Reboot in 10 seconds...
ping -n 11 127.0.0.1 > nul
wpeutil reboot
exit /b 0
