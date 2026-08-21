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
echo === [BUILD 2026-08-19-c revert-testtime] ===

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

:: === Автосборка RAID-массивов по конфигу SL (Intel VMD/NVMe + LSI/avago SAS/SATA) ===
:: Инертна, если в конфиге нет RAID-групп (build_rst/build_avago CHECK -> NONE) либо
:: на шаре нет нужных .vbs/утилит. На Pro/IoT/Server без RAID ничего не меняется.
:: Порядок по ТЗ: предупредить -> подтвердить -> очистить avago (иначе его массив
:: СКРЫВАЕТ NVMe от rstcli и RST-план пуст) -> показать ТОЧНЫЙ план -> подтвердить -> собрать.
if not exist "Y:\common\config\%SL%.txt" goto RAID_DONE
set "RSTNEED="
set "AVGNEED="
:: --- CHECK: нужны ли NVMe (RST) массивы? ---
if exist "Y:\common\build_rst.vbs" if exist "Y:\common\software\rstcli64.exe" (
  cscript //nologo "Y:\common\build_rst.vbs" "Y:\common\config\%SL%.txt" CHECK > X:\rstchk.txt 2>&1
  type X:\rstchk.txt
  find "RESULT=NEEDED" X:\rstchk.txt >nul
  if not errorlevel 1 set "RSTNEED=1"
)
:: --- CHECK: нужны ли avago (SAS/SATA) массивы? ---
if exist "Y:\common\build_avago.vbs" if exist "Y:\common\SoftForTest\StorCLI\storcli64.exe" (
  cscript //nologo "Y:\common\build_avago.vbs" "Y:\common\config\%SL%.txt" CHECK > X:\avgchk.txt 2>&1
  type X:\avgchk.txt
  find "RESULT=NEEDED" X:\avgchk.txt >nul
  if not errorlevel 1 set "AVGNEED=1"
)
if not defined RSTNEED if not defined AVGNEED goto RAID_DONE
echo.
cls
echo ===============================================================
echo   АВТОСБОРКА RAID-МАССИВОВ  (по конфигу SL=%SL%)
echo ===============================================================
echo Конфиг требует сборку RAID. Чтобы RST-план был точным, сначала
echo очищается конфигурация avago ^(его массив скрывает NVMe от rstcli^).
echo.
echo *** ВНИМАНИЕ: очистка УДАЛИТ массивы на контроллерах avago + RST.
echo *** ВСЕ данные на дисках этих контроллеров будут ПОТЕРЯНЫ.
set "CONFIRM="
set /p CONFIRM=Очистить контроллеры и показать план сборки? Y или YES:
call :IS_CONFIRMED
if not defined CONFIRM_OK (
  echo [raid] отменено оператором - контроллеры и диски НЕ тронуты.
  goto RAID_DONE
)
echo.
echo === Очистка конфигурации avago ^(storcli^) ===
if not exist "Y:\common\SoftForTest\StorCLI\storcli64.exe" goto AVAGO_CLR_DONE
set "STOR=Y:\common\SoftForTest\StorCLI\storcli64.exe"
%STOR% /c0/vall del force >nul 2>&1
%STOR% /c0/fall del >nul 2>&1
:: Сброс preserved/pinned cache: после удаления VD с write-back кэшем контроллер
:: держит его "pinned" и ОТКАЗЫВАЕТСЯ создавать новые VD (Failure, exit=84), пока
:: кэш не сброшен. Чистим и общий, и по каждому ID удалённого VD (0..15).
echo [raid] сброс preserved cache avago...
%STOR% /c0/vall delete preservedcache force >nul 2>&1
for /L %%i in (0,1,15) do %STOR% /c0/v%%i delete preservedcache force >nul 2>&1
%STOR% /c0 show preservedcache
echo [raid] avago очищен ^(VD + foreign + preserved cache^) - rstcli видит NVMe.
:AVAGO_CLR_DONE
echo.
echo === План сборки ^(после очистки avago - точный^) ===
echo.
set "RAIDSKIP="
if defined RSTNEED (
  cscript //nologo "Y:\common\build_rst.vbs" "Y:\common\config\%SL%.txt" DRYRUN > X:\rstplan.txt 2>&1
  type X:\rstplan.txt
  find "- SKIP." X:\rstplan.txt >nul
  if not errorlevel 1 set "RAIDSKIP=1"
)
if defined AVGNEED (
  cscript //nologo "Y:\common\build_avago.vbs" "Y:\common\config\%SL%.txt" DRYRUN > X:\avgplan.txt 2>&1
  type X:\avgplan.txt
  find "- SKIP." X:\avgplan.txt >nul
  if not errorlevel 1 set "RAIDSKIP=1"
)
echo.
:: ТЗ стр.53: если группу(ы) не удалось сопоставить с дисками (кол-во/тип не совпали
:: даже по Pass-2 -> "- SKIP." в плане) - предупредить и предложить выключение.
if not defined RAIDSKIP goto RAID_NOSKIP
echo *** ВНИМАНИЕ: часть групп из конфига НЕ сопоставлена с дисками ^(строки "- SKIP." выше^).
echo *** Реальные диски не совпадают с конфигурацией по кол-ву/типу.
set "CONFIRM="
set /p CONFIRM=ВЫКЛЮЧИТЬ машину для проверки? Y = выключить, иначе = продолжить всё равно:
call :IS_CONFIRMED
if defined CONFIRM_OK (
  echo [raid] выключение по требованию оператора ^(несопоставленные диски^).
  wpeutil shutdown
  goto :eof
)
:RAID_NOSKIP
set "CONFIRM="
set /p CONFIRM=Собрать RAID-массивы по плану выше? Y или YES:
call :IS_CONFIRMED
if not defined CONFIRM_OK (
  echo [raid] сборка отменена ^(avago уже очищен, массивы НЕ собраны^).
  goto RAID_DONE
)
echo.
echo === Сборка RAID ===
:: Собрать RST (NVMe): очищает свои метаданные + создаёт + init (кроме RAID-0)
if defined RSTNEED (
  echo [raid] --- RST ^(Intel VMD / NVMe^) ---
  cscript //nologo "Y:\common\build_rst.vbs" "Y:\common\config\%SL%.txt" EXECUTE
  if errorlevel 1 (
    echo *** [raid] RST-сборка НЕ удалась - см. вывод выше. Enter = продолжить всё равно.
    pause
  )
)
:: Собрать avago-массивы (SAS/SATA) через storcli (avago уже очищен выше)
if defined AVGNEED (
  echo [raid] --- avago ^(LSI MegaRAID SAS/SATA^) ---
  cscript //nologo "Y:\common\build_avago.vbs" "Y:\common\config\%SL%.txt" EXECUTE
  if errorlevel 1 (
    echo *** [raid] avago-сборка НЕ удалась - см. вывод выше. Enter = продолжить всё равно.
    pause
  )
)
:: Дать контроллерам показать новые массивы + обновить список дисков WinPE
echo [raid] пауза ~15 сек, затем diskpart rescan...
ping -n 16 127.0.0.1 >nul
(echo rescan)> X:\raid_rescan.txt
diskpart /s X:\raid_rescan.txt >nul
:RAID_DONE

:SELECT_START
echo.
cls
echo ===============================================================
echo   НАСТРОЙКА USB-ФЛЕШЕК
echo ===============================================================
echo Для каждой роли введите ИНДЕКС диска или Enter чтобы пропустить.
call :SHOW_USB

echo IpdromREC = флешка восстановления (restore.ffu).
echo (R = обновить список дисков, если только что вставили флешку)
:REC_ASK
set "RECDISK="
set /p RECDISK=Индекс RECDISK:
if /i "%RECDISK%"=="R" ( call :SHOW_USB & goto REC_ASK )
if /i "%RECDISK%"=="" set "RECDISK=SKIP"

echo.
echo IPDROM = флешка с документацией, драйверами и ПО.
echo (R = обновить список дисков)
:DOCS_ASK
set "DOCSDISK="
set /p DOCSDISK=Индекс DOCSDISK:
if /i "%DOCSDISK%"=="R" ( call :SHOW_USB & goto DOCS_ASK )
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

cls
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

cls
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

cls
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

:: === Ключ продукта: win11/Pro и Server 2019/2022. IoT ставится по GVLK
:: (в его autounattend нет плейсхолдера __PRODUCT_KEY__) - для IoT блок пропускается.
:: Enter = GVLK по умолчанию для данной ОС (ставится, ключ активации введёте позже).
set "PRODKEY="
set "PRODKEY_DEFAULT="
set "KEYOSNAME="
if /i "%WINVER%"=="win11"      set "PRODKEY_DEFAULT=VK7JG-NPHTM-C97JM-9MPGT-3V66T"
if /i "%WINVER%"=="win11"      set "KEYOSNAME=WINDOWS 11 PRO"
if /i "%WINVER%"=="server2019" set "PRODKEY_DEFAULT=N69G4-B89J2-4G8F4-WWYCC-J464C"
if /i "%WINVER%"=="server2019" set "KEYOSNAME=WINDOWS SERVER 2019 STANDARD"
if /i "%WINVER%"=="server2022" set "PRODKEY_DEFAULT=VDYBN-27WPP-V4HQT-9VMD4-VMK7H"
if /i "%WINVER%"=="server2022" set "KEYOSNAME=WINDOWS SERVER 2022 STANDARD"
if not defined PRODKEY_DEFAULT goto PRODKEY_DONE
echo ===============================================================
echo   КЛЮЧ ПРОДУКТА %KEYOSNAME%
echo ===============================================================
echo Формат: XXXXX-XXXXX-XXXXX-XXXXX-XXXXX (25 символов).
echo Enter = пропустить: поставится по GVLK, ключ активации введёте позже.
set /p PRODKEY=Ключ:
if not defined PRODKEY goto PRODKEY_SKIP
echo [key] Ключ принят: %PRODKEY%
goto PRODKEY_DONE
:PRODKEY_SKIP
echo [key] Ключ не введён - GVLK по умолчанию (без активации).
set "PRODKEY=%PRODKEY_DEFAULT%"
:PRODKEY_DONE
echo.

:: ===============================================================
:: ФАЗА 3: единая сводка + финальное подтверждение перед установкой.
:: Пошаговые подтверждения деструктивных операций выше сохранены; это
:: холистическая проверка ПЕРЕД самой установкой ОС и стресс-тестом.
:: Отклонение (не Y) = сброс выбора и повтор с начала блока выбора.
:: ===============================================================
set "OSNAME=Windows"
if /i "%WINVER%"=="win11"      set "OSNAME=Windows 11 Pro"
if /i "%WINVER%"=="iot"        set "OSNAME=Windows IoT Enterprise LTSC"
if /i "%WINVER%"=="server2019" set "OSNAME=Windows Server 2019 Standard"
if /i "%WINVER%"=="server2022" set "OSNAME=Windows Server 2022 Standard"

set "KEYINFO=по GVLK (ключ не требуется)"
if defined PRODKEY_DEFAULT if /i "%PRODKEY%"=="%PRODKEY_DEFAULT%" set "KEYINFO=GVLK по умолчанию - без активации"
if defined PRODKEY_DEFAULT if not "%PRODKEY%"=="%PRODKEY_DEFAULT%" set "KEYINFO=%PRODKEY%"

set "TESTINFO=720 мин (12ч по умолчанию)"
if defined TESTMIN set "TESTINFO=%TESTMIN% мин"

set "SYSINFO=%SYSDISK%"
if /i "%SYSDISK%"=="SKIP" set "SYSINFO=SKIP - autounattend выберет сам"
set "RECINFO=%RECDISK%"
if /i "%RECDISK%"=="SKIP" set "RECINFO=НЕТ"
set "DOCSINFO=%DOCSDISK%"
if /i "%DOCSDISK%"=="SKIP" set "DOCSINFO=НЕТ"
set "CLEANINFO=%CLEANDISKS%"
if /i "%CLEANDISKS%"=="SKIP" set "CLEANINFO=нет"
set "PROTINFO=%PROTECTLIST%"
if not defined PROTINFO set "PROTINFO=нет"

cls
echo ###############################################################
echo #   ИТОГОВАЯ КОНФИГУРАЦИЯ - ПРОВЕРЬТЕ ПЕРЕД УСТАНОВКОЙ
echo ###############################################################
echo.
echo   Серийный номер : %SL%
echo   ОС             : %WINVER%  ^| %OSNAME%
echo   Ключ           : %KEYINFO%
echo   Время теста    : %TESTINFO%
echo.
echo   --- Об устройстве (модель / материнская плата) ---
wmic computersystem get Manufacturer,Model /format:table
wmic baseboard get Manufacturer,Product /format:table
echo.
echo   --- Диски (внутренние) ---
call :SHOW_FIXED
echo   Системный диск           : %SYSINFO%
echo   Защищено (данные/архив)  : %PROTINFO%
echo   Очистка лишних дисков    : %CLEANINFO%
echo.
echo   --- Флешки (USB) ---
call :SHOW_USB
echo   Флешка восстановления    : %RECINFO%
echo   Флешка документации      : %DOCSINFO%
echo.
echo ###############################################################
set "CONFIRM="
set /p CONFIRM=Всё верно? Y или YES = установка, иначе = сброс и заново:
call :IS_CONFIRMED
if defined CONFIRM_OK goto SUMMARY_OK
echo.
echo [summary] Отклонено - сбрасываю выбор, повтор с начала блока выбора.
echo.
set "RECDISK=" & set "DOCSDISK=" & set "SYSDISK=" & set "SYSAUTO=" & set "PROTECTLIST="
set "CLEANDISKS=" & set "TESTHOURS=" & set "TESTMIN=" & set "PRODKEY="
set "CONFIRM=" & set "CONFIRM_OK="
goto SELECT_START
:SUMMARY_OK
echo === Подтверждено. Готовлю и запускаю установку Windows. ===
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
