@echo off
chcp 65001 >nul 2>&1
wpeinit

:: wimboot places extra initrd files into X:\Windows\System32, not X:\
set "STAGE=X:\Windows\System32"

echo === Инициализация сети (wpeutil InitializeNetwork) ===
wpeutil InitializeNetwork /allownetworking
echo InitializeNetwork errorlevel=%errorlevel%

echo === Перезапуск LanmanWorkstation ===
net stop LanmanWorkstation /y >nul 2>&1
net start LanmanWorkstation 2>nul

echo === Ожидание 20 сек пока поднимется SMB ===
ping -n 21 127.0.0.1 >nul

echo === Ожидание сервера 10.0.6.42 (ICMP) ===
for /l %%s in (1,1,60) do (
  ping -n 1 -w 1000 10.0.6.42 >nul && goto NETOK
)
echo *** Сервер недоступен - переход в командную строку ***
ipconfig /all
cmd
goto :eof

:NETOK
set "WINVER=win11"
if exist "%STAGE%\winver.txt" set /p WINVER=<"%STAGE%\winver.txt"
echo === Версия: %WINVER% ===

set "SL=UNKNOWN"
if exist "%STAGE%\slid.txt" set /p SL=<"%STAGE%\slid.txt"
echo === Конфигурация SL: %SL% ===

echo.
echo ===============================================================
echo   НАСТРОЙКА USB-ФЛЕШЕК
echo ===============================================================
echo Для каждой роли введите ИНДЕКС диска или Enter чтобы пропустить.
call :SHOW_USB

echo IpdromREC = флешка восстановления (restore.ffu).
set "RECDISK="
set /p RECDISK=Индекс RECDISK:
if /i "%RECDISK%"=="" set "RECDISK=SKIP"

echo.
echo IPDROM = флешка с документацией, драйверами и ПО.
set "DOCSDISK="
set /p DOCSDISK=Индекс DOCSDISK:
if /i "%DOCSDISK%"=="" set "DOCSDISK=SKIP"

if /i "%RECDISK%"=="SKIP" (
  echo [rec ] пропущено - Prepare-IpdromRecFlash попробует позже.
  goto DOCS_FMT
)
if /i not "%DOCSDISK%"=="SKIP" if "%RECDISK%"=="%DOCSDISK%" (
  echo *** Один диск на ОБЕ роли - DOCS принудительно пропущен ***
  set "DOCSDISK=SKIP"
)

echo.
echo *** ВНИМАНИЕ: диск %RECDISK% будет ОЧИЩЕН и помечен IpdromREC.
echo *** ВСЕ данные на этом диске будут ПОТЕРЯНЫ.
set "CONFIRM="
set /p CONFIRM=Введите YES для подтверждения:
if /i not "%CONFIRM%"=="YES" (
  echo [rec ] отменено оператором.
  set "RECDISK=SKIP"
  goto DOCS_FMT
)

echo === Форматирование диска %RECDISK% [WINRE + IpdromREC] ===
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
  echo *** Prepare-IpdromRecFlash попробует переформатировать позже.
) else (
  echo [rec ] OK - разделы WINRE и IpdromREC готовы.
)

:DOCS_FMT
if /i "%DOCSDISK%"=="SKIP" (
  echo [docs] пропущено - документы только на Рабочем столе.
  goto FLASH_DONE
)

echo.
echo *** ВНИМАНИЕ: диск %DOCSDISK% будет ОЧИЩЕН и помечен IPDROM.
echo *** ВСЕ данные на этом диске будут ПОТЕРЯНЫ.
set "CONFIRM="
set /p CONFIRM=Введите YES для подтверждения:
if /i not "%CONFIRM%"=="YES" (
  echo [docs] отменено оператором.
  goto FLASH_DONE
)

echo === Форматирование диска %DOCSDISK% как IPDROM ===
:: DOCS flash is data-only, MBR is fine (no boot needed).
:: 'convert gpt' after 'clean' silently fails in WinPE diskpart on raw disks
:: (needs MBR-initialized first), which then skips create/format/assign quietly
:: - so we skip GPT entirely. Letter=Q assigned explicitly, then format.com
:: enforces the IPDROM label reliably (diskpart's label=... is flaky on USB).
(
  echo select disk %DOCSDISK%
  echo clean
  echo create partition primary
  echo format fs=ntfs quick
  echo assign letter=Q
  echo exit
) > X:\docs_format.txt
diskpart /s X:\docs_format.txt
if errorlevel 1 (
  echo *** diskpart DOCS failed with errorlevel %errorlevel% ***
  goto DOCS_END
)
:: Verify Q: actually got assigned before touching format.com
if not exist Q:\ (
  echo *** Q: не назначен diskpart, форматирование прервано ***
  goto DOCS_END
)
echo [docs] diskpart OK. Применяю метку IPDROM через format.com...
format Q: /q /fs:ntfs /v:IPDROM /y
if errorlevel 1 (
  echo *** format.com не сработал, пробую команду label ***
  label Q: IPDROM
)
echo [docs] OK - раздел IPDROM готов на Q:.
:DOCS_END

:FLASH_DONE
echo === Флешки настроены. Продолжаю установку Windows. ===
echo.

echo ===============================================================
echo   ДИСК ДЛЯ УСТАНОВКИ WINDOWS (SYSDISK)
echo ===============================================================
call :SHOW_FIXED
echo Уже выбрано:  REC=%RECDISK%  DOCS=%DOCSDISK%
echo.
echo Для IoT ОБЯЗАТЕЛЬНО выбрать индекс (иначе установка упадёт).
echo Для Pro введите SKIP чтобы autounattend выбрал цель сам.

set "SYSDISK="
set /p SYSDISK=Индекс SYSDISK:
if /i "%SYSDISK%"=="" set "SYSDISK=SKIP"

if /i "%SYSDISK%"=="SKIP" (
  echo [sys ] SKIP - autounattend выберет цель сам.
  goto SYS_DONE
)

echo.
echo *** ВНИМАНИЕ: диск %SYSDISK% будет ОЧИЩЕН на разделы EFI/MSR/Windows.
echo *** ВСЕ данные на этом диске будут ПОТЕРЯНЫ.
set "CONFIRM="
set /p CONFIRM=Введите YES для подтверждения:
if /i not "%CONFIRM%"=="YES" (
  echo [sys ] отменено оператором.
  set "SYSDISK=SKIP"
  goto SYS_DONE
)

echo === Подготовка диска %SYSDISK% для установки Windows ===
(
  echo select disk %SYSDISK%
  echo clean
  echo convert gpt
  echo create partition efi size=300
  echo format quick fs=fat32 label="System"
  echo assign letter=S
  echo create partition msr size=16
  echo create partition primary
  echo format quick fs=ntfs label="Windows"
  echo assign letter=W
  echo exit
) > X:\sys_format.txt
diskpart /s X:\sys_format.txt
if errorlevel 1 (
  echo *** diskpart SYS failed with errorlevel %errorlevel% ***
  echo *** Autounattend может попробовать, но установка вероятно упадёт.
) else (
  echo [sys ] OK - разделы EFI/MSR/Windows готовы на диске %SYSDISK%.
)

:SYS_DONE
echo.

echo ===============================================================
echo   ОЧИСТКА ЛИШНИХ ДИСКОВ
echo ===============================================================
echo Стирает таблицы разделов чтобы BIOS не грузил СТАРУЮ ОС.
call :SHOW_FIXED
echo Уже выбрано:  REC=%RECDISK%  DOCS=%DOCSDISK%  SYS=%SYSDISK%
echo.
echo Индексы через запятую, напр. 2 или 0,2 - Enter/SKIP чтобы пропустить.
echo Пропустите Диск 0 если это ваш RAID с данными.
echo SYSDISK/RECDISK/DOCSDISK игнорируются автоматически.

set "CLEANDISKS="
set /p CLEANDISKS=Диски для очистки:
if /i "%CLEANDISKS%"=="" set "CLEANDISKS=SKIP"
if /i "%CLEANDISKS%"=="SKIP" (
  echo [clean] SKIP - ничего не чищено.
  goto CLEAN_DONE
)

echo.
echo *** ВНИМАНИЕ: диски [ %CLEANDISKS% ] потеряют ВСЕ данные.
set "CONFIRM="
set /p CONFIRM=Введите YES для подтверждения:
if /i not "%CONFIRM%"=="YES" (
  echo [clean] отменено оператором.
  goto CLEAN_DONE
)

for %%d in (%CLEANDISKS%) do (
  if "%%d"=="%SYSDISK%" (
    echo [clean] диск %%d = SYSDISK - пропуск.
  ) else if "%%d"=="%RECDISK%" (
    echo [clean] диск %%d = RECDISK - пропуск.
  ) else if "%%d"=="%DOCSDISK%" (
    echo [clean] диск %%d = DOCSDISK - пропуск.
  ) else (
    echo === Очистка диска %%d ===
    (
      echo select disk %%d
      echo clean
      echo exit
    ) > X:\clean_%%d.txt
    diskpart /s X:\clean_%%d.txt
    if errorlevel 1 (
      echo *** очистка диска %%d НЕ УДАЛАСЬ
    ) else (
      echo [clean] диск %%d очищен.
    )
  )
)

:CLEAN_DONE
echo.

echo === Монтирование SMB-шары (10 попыток со сбросом состояния) ===
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
  echo Попытка %RETRIES%/10 не удалась, повтор через 10 сек...
  ping -n 11 127.0.0.1 >nul
  goto MOUNT_RETRY
)
echo *** SMB не смонтирован после 10 попыток ***
echo --- ipconfig /all ---
ipconfig /all
echo --- Пробую прямой доступ к каталогу (другой код ошибки) ---
dir \\10.0.6.42\winpxe\ 2>&1
cmd
goto :eof

:MOUNT_OK
echo === SMB-шара смонтирована с попытки %RETRIES% ===
Y:
cd \%WINVER%
if not exist setup.exe (
  echo *** Нет setup.exe в папке версии %WINVER% - переход в консоль ***
  dir Y:\
  cmd
  goto :eof
)

if exist "%STAGE%\autounattend.xml" (
  set "UAFILE=%STAGE%\autounattend.xml"
  echo === Использую autounattend с сервера, SL=%SL% ===
) else (
  set "UAFILE=Y:\%WINVER%\autounattend.xml"
  echo === Готовый autounattend отсутствует - беру исходный ***
)

:: Autounattend carries a hardcoded <DiskID>. If it does not match the SYSDISK
:: the operator picked, Setup cannot find the target partition, WillShowUI=OnError
:: fires and Setup falls back to the FULL interactive wizard - which also throws
:: away SetupUILanguage and every other unattend setting. So this patch matters.
:: PowerShell is absent from PXE WinPE, hence the cscript fallback.
if /i "%SYSDISK%"=="SKIP" goto SETUP_START

echo === Правка autounattend: DiskID -^> %SYSDISK% ===
powershell.exe -NoProfile -Command "$f='%UAFILE%'; $c=[System.IO.File]::ReadAllText($f); $c=[regex]::Replace($c,'<DiskID>\d+</DiskID>','<DiskID>%SYSDISK%</DiskID>'); [System.IO.File]::WriteAllText($f,$c,[System.Text.UTF8Encoding]::new($false))" >nul 2>&1
if not errorlevel 1 goto PATCH_OK

echo     PowerShell недоступен, пробую VBScript...
if not exist "Y:\common\patch_diskid.vbs" (
  echo *** Не найден Y:\common\patch_diskid.vbs
  goto PATCH_FAIL
)
cscript.exe //nologo "Y:\common\patch_diskid.vbs" "%UAFILE%" %SYSDISK%
if not errorlevel 1 goto PATCH_OK

:PATCH_FAIL
echo *** Правка DiskID НЕ УДАЛАСЬ - Setup возьмёт жёстко заданный DiskID.
echo *** Setup покажет экраны выбора языка и раздела - выберите вручную:
echo *** язык Русский, затем раздел Windows на диске %SYSDISK%.
goto SETUP_START

:PATCH_OK
:: Не используем findstr для проверки - его нет в PXE WinPE.
:: patch_diskid.vbs сам печатает "patch_diskid: DiskID set to N".

:SETUP_START
echo === Запуск установки Windows с %UAFILE% ===
start /wait setup.exe /unattend:%UAFILE%
goto :eof

:: ============================================================
:: Подпрограммы: заново запрашивают и показывают диски, чтобы
:: оператору не приходилось листать вверх. Вызываются перед
:: каждым вопросом о выборе диска.
:: ============================================================
:SHOW_USB
echo.
echo Обнаруженные USB-накопители:
echo.
wmic diskdrive where "InterfaceType='USB'" get Index,Model,Size /format:table
echo Размеры в байтах; делите на 1000000000 чтобы получить ГБ.
echo.
exit /b

:SHOW_FIXED
echo.
echo Обнаруженные внутренние диски (не USB):
echo.
wmic diskdrive where "InterfaceType!='USB'" get Index,Model,Size /format:table
echo Размеры в байтах; делите на 1000000000 чтобы получить ГБ.
echo.
exit /b
