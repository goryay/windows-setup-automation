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
set /p CONFIRM=Для подтверждения введите Y или YES:
call :IS_CONFIRMED
if not defined CONFIRM_OK (
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
set /p CONFIRM=Для подтверждения введите Y или YES:
call :IS_CONFIRMED
if not defined CONFIRM_OK (
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

:: ===== Авто-детект дисков по конфигу SL (система + защита данных/архива) =====
:: SMB уже смонтирован в начале (сразу после определения SL) - берём конфиг с Y:.
set "SYSAUTO="
set "PROTECTLIST="
if not exist "Y:\common\detect_sysdisk.vbs" goto SYSAUTO_DONE
if not exist "Y:\common\config\%SL%.txt" goto SYSAUTO_DONE
cscript //nologo "Y:\common\detect_sysdisk.vbs" "Y:\common\config\%SL%.txt" > X:\detect.txt 2>&1
type X:\detect.txt
for /f "usebackq tokens=1,* delims==" %%a in ("X:\detect.txt") do (
  if /i "%%a"=="RESULT" set "SYSAUTO=%%b"
  if /i "%%a"=="PROTECT" set "PROTECTLIST=%%b"
)
if not defined SYSAUTO goto SYSAUTO_DONE
:: RESULT валиден только если это число (иначе NONE/AMBIGUOUS/ERROR)
set "SYSBAD="
for /f "delims=0123456789" %%A in ("%SYSAUTO%") do set "SYSBAD=%%A"
if defined SYSBAD set "SYSAUTO="
:SYSAUTO_DONE

echo.
if defined SYSAUTO goto SYSAUTO_SHOW
echo [auto] Автоопределение не дало однозначного диска - выберите индекс вручную.
goto SYSAUTO_ASK
:SYSAUTO_SHOW
echo [auto] Обнаружен системный диск: %SYSAUTO%  - по конфигу SL=%SL%
echo        Enter или Y = принять диск %SYSAUTO%; либо введите другой индекс; либо SKIP.
:SYSAUTO_ASK

set "SYSDISK="
set /p SYSDISK=Индекс SYSDISK:
if defined SYSAUTO if /i "%SYSDISK%"=="" set "SYSDISK=%SYSAUTO%"
if defined SYSAUTO if /i "%SYSDISK%"=="Y" set "SYSDISK=%SYSAUTO%"
if defined SYSAUTO if /i "%SYSDISK%"=="YES" set "SYSDISK=%SYSAUTO%"
if /i "%SYSDISK%"=="" set "SYSDISK=SKIP"

if /i "%SYSDISK%"=="SKIP" (
  echo [sys ] SKIP - autounattend выберет цель сам.
  goto SYS_DONE
)

echo.
echo *** ВНИМАНИЕ: диск %SYSDISK% будет ОЧИЩЕН на разделы EFI/MSR/Windows.
echo *** ВСЕ данные на этом диске будут ПОТЕРЯНЫ.
set "CONFIRM="
set /p CONFIRM=Для подтверждения введите Y или YES:
call :IS_CONFIRMED
if not defined CONFIRM_OK (
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
echo Авто-защита от очистки (система/данные/архив по конфигу): %PROTECTLIST%
echo.
echo Индексы через запятую, напр. 2 или 0,2 - Enter/SKIP чтобы пропустить.
echo Защищённые диски и флешки (SYS/REC/DOCS) пропускаются автоматически.

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
set /p CONFIRM=Для подтверждения введите Y или YES:
call :IS_CONFIRMED
if not defined CONFIRM_OK (
  echo [clean] отменено оператором.
  goto CLEAN_DONE
)

for %%d in (%CLEANDISKS%) do call :CLEAN_ONE %%d

:CLEAN_DONE
echo.

echo ===============================================================
echo   ДЛИТЕЛЬНОСТЬ СТРЕСС-ТЕСТА
echo ===============================================================
echo Сколько ЧАСОВ гонять стресс-тест после установки?
echo Enter = 12 часов (по умолчанию).
set "TESTHOURS="
set /p TESTHOURS=Часов:
set "TESTMIN="
if not defined TESTHOURS (
  echo [test] Оставлено по умолчанию - 12 часов.
  goto TESTDUR_DONE
)
set "TESTHOURS_BAD="
for /f "delims=0123456789" %%A in ("%TESTHOURS%") do set "TESTHOURS_BAD=%%A"
if defined TESTHOURS_BAD (
  echo [test] "%TESTHOURS%" - не число, беру 12 часов по умолчанию.
  goto TESTDUR_DONE
)
set /a TESTMIN=%TESTHOURS%*60
if %TESTMIN% LEQ 0 (
  echo [test] Значение недопустимо, беру 12 часов по умолчанию.
  set "TESTMIN="
  goto TESTDUR_DONE
)
echo [test] Тест будет идти %TESTHOURS% ч (%TESTMIN% мин).
:TESTDUR_DONE
echo.

:: === Ключ продукта: только win11/Pro. IoT и Server ставятся по GVLK,
:: их autounattend плейсхолдера __PRODUCT_KEY__ не содержит - блок пропускается.
set "PRODKEY="
if /i not "%WINVER%"=="win11" goto PRODKEY_DONE
echo ===============================================================
echo   КЛЮЧ ПРОДУКТА WINDOWS 11 PRO
echo ===============================================================
echo Формат: XXXXX-XXXXX-XXXXX-XXXXX-XXXXX (25 символов).
echo Enter = пропустить: поставится Pro без активации, ключ введёте позже.
set /p PRODKEY=Ключ:
if not defined PRODKEY goto PRODKEY_SKIP
echo [key] Ключ принят: %PRODKEY%
goto PRODKEY_DONE
:PRODKEY_SKIP
echo [key] Ключ не введён - Pro без активации (generic key).
set "PRODKEY=VK7JG-NPHTM-C97JM-9MPGT-3V66T"
:PRODKEY_DONE
echo.

:: SMB смонтирован в начале (сразу после определения SL); Y: уже доступен,
:: setup.exe проверен, CWD = Y:\%WINVER%. Продолжаем к правке autounattend.

if exist "%STAGE%\autounattend.xml" (
  set "UASRC=%STAGE%\autounattend.xml"
  echo === Использую autounattend с сервера, SL=%SL% ===
) else (
  set "UASRC=Y:\%WINVER%\autounattend.xml"
  echo === Готовый autounattend отсутствует - беру исходный ===
)

:: Patch a WRITABLE local copy on X: (ramdisk). The source can sit on the
:: read-only SMB share (Y:) or a staged path where the write-back fails
:: SILENTLY - that is exactly how an operator-entered test duration got lost:
:: __TEST_MINUTES__ was never replaced, Specialize wrote no TestMinutes, and the
:: test ran with the 720-min default. Copying to X: guarantees the patch lands
:: AND that Setup reads exactly the file we patched.
set "UAFILE=X:\autounattend_patched.xml"
copy /y "%UASRC%" "%UAFILE%" >nul
if exist "%UAFILE%" (
  echo === autounattend скопирован на X: для правки ===
) else (
  echo *** Копирование не удалось - патчу источник напрямую.
  set "UAFILE=%UASRC%"
)

:: Autounattend carries a hardcoded <DiskID> plus a __TEST_MINUTES__ placeholder.
:: If DiskID disagrees with SYSDISK, Setup drops into the full interactive wizard
:: (losing SetupUILanguage etc.), so the patch must succeed. PowerShell is usually
:: absent in PXE WinPE -> cscript fallback. DISKARG=SKIP leaves DiskID untouched
:: (autounattend picks the disk). NO ">nul 2>&1" here: we WANT errors visible.
set "DISKARG=%SYSDISK%"
if /i "%SYSDISK%"=="SKIP" set "DISKARG=SKIP"
echo === Правка autounattend: DiskID=%DISKARG%, TestMin=%TESTMIN% ===

powershell.exe -NoProfile -Command "$f='%UAFILE%'; $c=[System.IO.File]::ReadAllText($f); if('%DISKARG%' -ne 'SKIP'){$c=[regex]::Replace($c,'<DiskID>\s*\d+\s*</DiskID>','<DiskID>%DISKARG%</DiskID>')}; if('%TESTMIN%' -ne ''){$c=$c.Replace('__TEST_MINUTES__','%TESTMIN%')}; if('%PRODKEY%' -ne ''){$c=$c.Replace('__PRODUCT_KEY__','%PRODKEY%')}; [System.IO.File]::WriteAllText($f,$c,[System.Text.UTF8Encoding]::new($false))"
if not errorlevel 1 goto PATCH_VERIFY

echo     PowerShell недоступен/ошибка, пробую VBScript...
if not exist "Y:\common\patch_diskid.vbs" (
  echo *** Не найден Y:\common\patch_diskid.vbs
  goto PATCH_FAIL
)
cscript.exe //nologo "Y:\common\patch_diskid.vbs" "%UAFILE%" %DISKARG% "%TESTMIN%" "%PRODKEY%"
if not errorlevel 1 goto PATCH_VERIFY

:PATCH_FAIL
echo *** Правка autounattend НЕ УДАЛАСЬ.
if /i not "%SYSDISK%"=="SKIP" echo *** Setup покажет выбор языка/раздела - выберите вручную: Русский, раздел Windows на диске %SYSDISK%.
goto SETUP_START

:PATCH_VERIFY
:: Best-effort visibility: confirm placeholders are gone.
:: find.exe returns errorlevel 1 when the string is NOT found (= replaced OK).
:: 1) Product key (win11/Pro only; PRODKEY is defined only for win11).
if not defined PRODKEY goto PV_TESTMIN
find "__PRODUCT_KEY__" "%UAFILE%" >nul 2>&1
if errorlevel 1 goto PV_KEY_OK
echo *** ВНИМАНИЕ: __PRODUCT_KEY__ остался - Setup спросит ключ вручную.
goto PV_TESTMIN
:PV_KEY_OK
echo     [patch] Ключ продукта применён.
:PV_TESTMIN
:: 2) Test duration.
if not defined TESTMIN goto SETUP_START
find "__TEST_MINUTES__" "%UAFILE%" >nul 2>&1
if errorlevel 1 goto TESTMIN_APPLIED
echo *** ВНИМАНИЕ: __TEST_MINUTES__ остался в файле - длительность теста НЕ применилась (пойдёт дефолт)!
goto SETUP_START
:TESTMIN_APPLIED
echo     [patch] Длительность теста применена: %TESTMIN% мин.

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

:IS_CONFIRMED
:: Подтверждение опасных операций (затирание дисков). Принимаем Y или YES,
:: регистр не важен. Кириллицу (да/д) намеренно НЕ принимаем: в WinPE консоли
:: (chcp 65001) многобайтный ввод через set /p ненадёжен, а YES и так латиница.
set "CONFIRM_OK="
if /i "%CONFIRM%"=="Y"   set "CONFIRM_OK=1"
if /i "%CONFIRM%"=="YES" set "CONFIRM_OK=1"
exit /b

:CLEAN_ONE
:: Очистка одного диска из списка. Авто-пропуск SYS/REC/DOCS и защищённых
:: (данные/архив из PROTECTLIST). Вызов: call :CLEAN_ONE <index>.
set "CLD=%~1"
if "%CLD%"=="%SYSDISK%"  ( echo [clean] диск %CLD% = SYSDISK - пропуск.  & exit /b )
if "%CLD%"=="%RECDISK%"  ( echo [clean] диск %CLD% = RECDISK - пропуск.  & exit /b )
if "%CLD%"=="%DOCSDISK%" ( echo [clean] диск %CLD% = DOCSDISK - пропуск. & exit /b )
for %%p in (%PROTECTLIST%) do if "%%p"=="%CLD%" ( echo [clean] диск %CLD% = данные/архив - ЗАЩИЩЁН, пропуск. & exit /b )
echo === Очистка диска %CLD% ===
(
  echo select disk %CLD%
  echo clean
  echo exit
) > X:\clean_%CLD%.txt
diskpart /s X:\clean_%CLD%.txt
if errorlevel 1 (
  echo *** очистка диска %CLD% НЕ УДАЛАСЬ
) else (
  echo [clean] диск %CLD% очищен.
)
exit /b
