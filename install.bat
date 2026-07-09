@echo off
wpeinit

:: wimboot places extra initrd files into X:\Windows\System32, not X:\
set "STAGE=X:\Windows\System32"

echo === Initializing network (wpeutil InitializeNetwork) ===
wpeutil InitializeNetwork /allownetworking
echo InitializeNetwork errorlevel=%errorlevel%

echo === (Re)starting LanmanWorkstation ===
net stop LanmanWorkstation /y >nul 2>&1
net start LanmanWorkstation 2>nul

echo === Waiting 20 sec for SMB stack to come up ===
ping -n 21 127.0.0.1 >nul

echo === Waiting for server 10.0.6.42 (ICMP) ===
for /l %%s in (1,1,60) do (
  ping -n 1 -w 1000 10.0.6.42 >nul && goto NETOK
)
echo *** Server unreachable - dropping to shell ***
ipconfig /all
cmd
goto :eof

:NETOK
set "WINVER=win11"
if exist "%STAGE%\winver.txt" set /p WINVER=<"%STAGE%\winver.txt"
echo === Selected version: %WINVER% ===

set "SL=UNKNOWN"
if exist "%STAGE%\slid.txt" set /p SL=<"%STAGE%\slid.txt"
echo === Selected SL: %SL% ===

echo.
echo ===============================================================
echo   USB FLASH SETUP
echo ===============================================================
echo Detected USB drives:
echo.
wmic diskdrive where "InterfaceType='USB'" get Index,Model,Size /format:table
echo.
echo Sizes are in bytes. Divide by 1000000000 for GB.
echo.
echo For each role: enter disk INDEX from table above, or SKIP.
echo If SKIP - the corresponding pipeline step is either skipped
echo (docs) or the flash is autodetected by size (rec).
echo.

set "RECDISK="
set /p RECDISK=Index for IpdromREC (recovery flash / restore.ffu)?
if /i "%RECDISK%"=="" set "RECDISK=SKIP"

set "DOCSDISK="
set /p DOCSDISK=Index for IPDROM (docs + drivers + software)?
if /i "%DOCSDISK%"=="" set "DOCSDISK=SKIP"

if /i "%RECDISK%"=="SKIP" (
  echo [rec ] skipped - Prepare-IpdromRecFlash will try later.
  goto DOCS_FMT
)
if /i not "%DOCSDISK%"=="SKIP" if "%RECDISK%"=="%DOCSDISK%" (
  echo *** Same disk for BOTH roles - DOCS forced to SKIP ***
  set "DOCSDISK=SKIP"
)

echo.
echo *** WARNING: disk %RECDISK% will be WIPED and labeled
echo *** IpdromREC. ALL data on this disk will be LOST.
set "CONFIRM="
set /p CONFIRM=Type YES to confirm (anything else cancels REC format):
if /i not "%CONFIRM%"=="YES" (
  echo [rec ] cancelled by operator.
  set "RECDISK=SKIP"
  goto DOCS_FMT
)

echo === Formatting disk %RECDISK% as [WINRE + IpdromREC] ===
(
  echo select disk %RECDISK%
  echo clean
  echo convert gpt
  echo create partition primary size=1536
  echo format fs=fat32 label="WINRE" quick
  echo assign
  echo create partition primary
  echo format fs=ntfs label="IpdromREC" quick
  echo assign
  echo exit
) > X:\rec_format.txt
diskpart /s X:\rec_format.txt
if errorlevel 1 (
  echo *** diskpart REC failed with errorlevel %errorlevel% ***
  echo *** Prepare-IpdromRecFlash will try to reformat later.
) else (
  echo [rec ] OK - WINRE and IpdromREC partitions ready.
)

:DOCS_FMT
if /i "%DOCSDISK%"=="SKIP" (
  echo [docs] skipped - docs will only be on Desktop; extras skipped.
  goto FLASH_DONE
)

echo.
echo *** WARNING: disk %DOCSDISK% will be WIPED and labeled
echo *** IPDROM. ALL data on this disk will be LOST.
set "CONFIRM="
set /p CONFIRM=Type YES to confirm (anything else cancels DOCS format):
if /i not "%CONFIRM%"=="YES" (
  echo [docs] cancelled by operator.
  goto FLASH_DONE
)

echo === Formatting disk %DOCSDISK% as IPDROM ===
(
  echo select disk %DOCSDISK%
  echo clean
  echo convert gpt
  echo create partition primary
  echo format fs=ntfs label="IPDROM" quick
  echo assign
  echo exit
) > X:\docs_format.txt
diskpart /s X:\docs_format.txt
if errorlevel 1 (
  echo *** diskpart DOCS failed with errorlevel %errorlevel% ***
) else (
  echo [docs] OK - IPDROM partition ready.
)

:FLASH_DONE
echo === Flash roles configured. Continuing Windows install. ===
echo.

echo === Mounting SMB share (10 retries with state reset) ===
set RETRIES=0
:MOUNT_RETRY
:: Drop any cached state from previous attempt - WinPE sometimes caches a failure
net use * /delete /y >nul 2>&1
:: First touch IPC$ to establish a session, then map the share
net use \\10.0.6.42\IPC$ /user:pxe pxe >nul 2>&1
net use Y: \\10.0.6.42\winpxe /user:pxe pxe /persistent:no
if not errorlevel 1 goto MOUNT_OK
set /a RETRIES+=1
if %RETRIES% lss 10 (
  echo Mount attempt %RETRIES%/10 failed, retry in 10 sec...
  ping -n 11 127.0.0.1 >nul
  goto MOUNT_RETRY
)
echo *** SMB mount failed after 10 retries ***
echo --- ipconfig /all ---
ipconfig /all
echo --- Trying direct dir access (different error code) ---
dir \\10.0.6.42\winpxe\ 2>&1
cmd
goto :eof

:MOUNT_OK
echo === SMB share mounted on attempt %RETRIES% ===
Y:
cd \%WINVER%
if not exist setup.exe (
  echo *** No setup.exe in version %WINVER% folder - drop to shell ***
  dir Y:\
  cmd
  goto :eof
)

if exist "%STAGE%\autounattend.xml" (
  set "UAFILE=%STAGE%\autounattend.xml"
  echo === Using server-patched autounattend with SL=%SL% ===
) else (
  set "UAFILE=Y:\%WINVER%\autounattend.xml"
  echo === Pre-patched autounattend missing - using original ***
)

echo === Starting Windows Setup with %UAFILE% ===
start /wait setup.exe /unattend:%UAFILE%
