﻿<# setup_apps_and_theme.ps1
# Объединённый скрипт кастомизации: системные настройки, установка ПО, брендинг, аудит

# --- 0. Поиск корневого диска с папкой software ---
foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
    $root = $drive.RootDirectory.FullName
    if (Test-Path (Join-Path $root "software")) {
        $script:driveRoot = $root
        break
    }
}

if (-not $script:driveRoot) {
    Write-Warning "Не найден диск с папкой software."
    exit
}
Write-Host "Найден диск: $script:driveRoot"

# ========== СЛУЖЕБНЫЕ ФУНКЦИИ ==========
function Invoke-ExternalInstaller {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [switch]$IgnoreExitCode3010
    )
    if (-not (Test-Path $FilePath)) {
        Write-Warning "Файл не найден: $FilePath"
        return $false
    }
    Write-Host "Запуск: $FilePath $Arguments"
    $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -eq 0) { return $true }
    if ($IgnoreExitCode3010 -and $p.ExitCode -eq 3010) {
        Write-Warning "Установщик запросил перезагрузку (3010): $FilePath"
        return $true
    }
    throw "Установщик завершился с кодом $($p.ExitCode): $FilePath"
}

function Install-MegaRaidStack {
    param([Parameter(Mandatory)][string]$DriveRoot)

    Write-Host "`n=== Установка Avago MegaRAID ===" -ForegroundColor Cyan

    $driverDir = Join-Path $DriveRoot 'software\DriverAvagoMegaRaid'
    $msmDir    = Join-Path $DriveRoot 'software\AvagoMegaRaid'

    if (Test-Path $driverDir) {
        Write-Host "Установка драйвера MegaRAID из $driverDir"
        pnputil /add-driver "$driverDir\*.inf" /subdirs /install
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "pnputil завершился с кодом $LASTEXITCODE для MegaRAID driver"
        }
    } else {
        Write-Warning "Папка драйвера MegaRAID не найдена: $driverDir"
    }

    if (-not (Test-Path $msmDir)) {
        Write-Warning "Папка ПО MegaRAID не найдена: $msmDir"
        return
    }

    $vcRedist = Get-ChildItem -Path (Join-Path $msmDir 'ISSetupPrerequisites') -Filter 'vcredist_x86.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($vcRedist) {
        try {
            Invoke-ExternalInstaller -FilePath $vcRedist.FullName -Arguments '/quiet /norestart' -IgnoreExitCode3010
        } catch {
            Write-Warning "VC++ prerequisite для MegaRAID не установился: $_"
        }
    }

    $msi = Join-Path $msmDir 'MSM.msi'
    $setupExe = Join-Path $msmDir 'setup.exe'

    if (Test-Path $msi) {
        try {
            $logDir = Join-Path $env:ProgramData 'IPDROM\Logs'
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            $msiLog = Join-Path $logDir 'MSM_install.log'
            Invoke-ExternalInstaller -FilePath 'msiexec.exe' -Arguments "/i `"$msi`" /qn /norestart /L*v `"$msiLog`"" -IgnoreExitCode3010
        } catch {
            Write-Warning "MSM.msi не установился: $_"
            if (Test-Path $setupExe) {
                try {
                    Invoke-ExternalInstaller -FilePath $setupExe -Arguments '/s /v"/qn REBOOT=ReallySuppress"' -IgnoreExitCode3010
                } catch {
                    Write-Warning "setup.exe MegaRAID не установился: $_"
                }
            }
        }
    } elseif (Test-Path $setupExe) {
        try {
            Invoke-ExternalInstaller -FilePath $setupExe -Arguments '/s /v"/qn REBOOT=ReallySuppress"' -IgnoreExitCode3010
        } catch {
            Write-Warning "setup.exe MegaRAID не установился: $_"
        }
    } else {
        Write-Warning "Ни MSM.msi, ни setup.exe не найдены в $msmDir"
    }
}


# ========== 1. СИСТЕМНЫЕ НАСТРОЙКИ (требуют прав администратора) ==========
Write-Host "`n=== Применяем системные настройки ==="

# 1.1 Отключение гибернации
Write-Host "Отключаем гибернацию..."
powercfg.exe /h off

# 1.2 Установка схемы питания "Высокая производительность"
Write-Host "Устанавливаем схему питания 'Высокая производительность'..."
powercfg.exe /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c

# 1.3 Настройка файла подкачки (фиксированный размер)
Write-Host "Настраиваем файл подкачки (C: 2048–4096 МБ)..."
try {
    $cs = Get-WmiObject -Class Win32_ComputerSystem -EnableAllPrivileges
    $cs.AutomaticManagedPagefile = $false
    $cs.Put()
    $pagefile = Get-WmiObject -Class Win32_PageFileSetting -Filter "Name='C:\\pagefile.sys'" -ErrorAction SilentlyContinue
    if (-not $pagefile) {
        $pagefile = Get-WmiObject -Class Win32_PageFileSetting -EnableAllPrivileges
        $pagefile.Create("C:\pagefile.sys", 2048, 4096)
    } else {
        $pagefile.InitialSize = 2048
        $pagefile.MaximumSize = 4096
        $pagefile.Put()
    }
} catch {
    Write-Warning "Не удалось настроить файл подкачки: $_"
}

# 1.4 Отключение UAC
Write-Host "Отключаем UAC..."
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA /t REG_DWORD /d 0 /f

# 1.5 Отключение брандмауэра Windows
Write-Host "Отключаем брандмауэр..."
netsh advfirewall set allprofiles state off

# 1.6 Отключение автоматических обновлений Windows
Write-Host "Отключаем автоматические обновления..."
Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
Set-Service wuauserv -StartupType Disabled
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v AUOptions /t REG_DWORD /d 2 /f

# 1.7 Заполнение OEM-информации (производитель, телефон, сайт, логотип)
Write-Host "Настраиваем OEM-информацию..."
$oemLogoSource = Join-Path $script:driveRoot "customization\logo\oemlogo.bmp"
$oemLogoDest = "C:\Windows\System32\oemlogo.bmp"
if (Test-Path $oemLogoSource) {
    Copy-Item $oemLogoSource $oemLogoDest -Force
    reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" /v Logo /t REG_SZ /d $oemLogoDest /f
} else {
    Write-Warning "Логотип OEM не найден: $oemLogoSource"
}
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" /v Manufacturer /t REG_SZ /d "IPDROM" /f
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" /v Model /t REG_SZ /d "IPDROM Workstation" /f
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" /v SupportPhone /t REG_SZ /d "8-800-550-21-85" /f
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" /v SupportURL /t REG_SZ /d "http://www.ipdrom.ru/" /f

Write-Host "Системные настройки завершены."

# ========== 2. УСТАНОВКА ПРОГРАММ ==========
Write-Host "`n=== Установка программ ==="
$softwarePath = Join-Path $script:driveRoot "software"

# 7-Zip
$sevenZip = Get-ChildItem "$softwarePath\7zip\7z*-x64.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($sevenZip) {
    Write-Host "Устанавливаю 7-Zip..."
    Start-Process -FilePath $sevenZip.FullName -ArgumentList '/S' -Wait
}

# Adobe Reader
$acrobat = Get-ChildItem "$softwarePath\Acrobat\*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($acrobat) {
    Write-Host "Устанавливаю Adobe Reader..."
    Start-Process -FilePath $acrobat.FullName -ArgumentList '/sAll /rs /msi EULA_ACCEPT=YES' -Wait
}

# WinAudit (просто копируем, запустим позже)
$winauditSrc = "$softwarePath\WinAudit\WinAudit.exe"
$winauditDest = "C:\Program Files\WinAudit\WinAudit.exe"
if (Test-Path $winauditSrc) {
    New-Item -ItemType Directory -Path "C:\Program Files\WinAudit" -Force | Out-Null
    Copy-Item $winauditSrc $winauditDest -Force
    Write-Host "WinAudit скопирован."
}

# ========== 3. БРЕНДИНГ (обои, блокировка, аватар) ==========
Write-Host "`n=== Настройка брендинга ==="

# Обои рабочего стола
$wallpaperSrc = Join-Path $script:driveRoot "customization\wallpapers\Ipdrom-desktop-1920x1080.jpg"
$wallpaperDir = "C:\Windows\Web\Wallpaper\IPDROM"
$wallpaperDest = Join-Path $wallpaperDir "Ipdrom-desktop-1920x1080.jpg"
if (Test-Path $wallpaperSrc) {
    if (-not (Test-Path $wallpaperDir)) { New-Item -ItemType Directory -Path $wallpaperDir -Force | Out-Null }
    Copy-Item $wallpaperSrc $wallpaperDest -Force
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name Wallpaper -Value $wallpaperDest
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name WallpaperStyle -Value 2
    rundll32.exe user32.dll, UpdatePerUserSystemParameters
    Write-Host "Обои установлены."
} else {
    Write-Warning "Файл обоев не найден: $wallpaperSrc"
}

# Изображение блокировки
$logonSrc = Join-Path $script:driveRoot "customization\wallpapers\Ipdrom-logon-1920x1080.jpg"
$logonDest = Join-Path $wallpaperDir "Ipdrom-logon-1920x1080.jpg"

if (Test-Path $logonSrc) {
    Copy-Item $logonSrc $logonDest -Force

    # Основной метод: Personalization CSP (работает в Pro)
    $CSPPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"
    if (!(Test-Path $CSPPath)) {
        New-Item -Path $CSPPath -Force | Out-Null
    }
    New-ItemProperty -Path $CSPPath -Name "LockScreenImagePath" -Value $logonDest -PropertyType String -Force
    New-ItemProperty -Path $CSPPath -Name "LockScreenImageStatus" -Value 1 -PropertyType DWord -Force
    New-ItemProperty -Path $CSPPath -Name "LockScreenImageUrl" -Value $logonDest -PropertyType String -Force

    $PolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
    if (!(Test-Path $PolicyPath)) {
        New-Item -Path $PolicyPath -Force | Out-Null
    }
    New-ItemProperty -Path $PolicyPath -Name "LockScreenImage" -Value $logonDest -PropertyType String -Force

    Write-Host "Изображение блокировки установлено."
} else {
    Write-Warning "Файл блокировки не найден: $logonSrc"
}

# ========== 3.5. УСТАНОВКА VC++ REDISTRIBUTABLE ==========
Write-Host "`n=== Установка Visual C++ Redistributable (из drivers\ps) ==="
$driversPsPath = Join-Path $script:driveRoot "drivers\ps"
if (Test-Path $driversPsPath) {
    $redistFiles = @(
        @{Name="VC_redist.x64_13.exe";    Description="VC++ 2013"},
        @{Name="vcredist_x64_15.exe";     Description="VC++ 2015-2022"}
    )
    foreach ($file in $redistFiles) {
        $fullPath = Join-Path $driversPsPath $file.Name
        if (Test-Path $fullPath) {
            Write-Host "Устанавливаю $($file.Description) ($($file.Name))..."
            $p = Start-Process -FilePath $fullPath -ArgumentList "/install /quiet /norestart" -Wait -PassThru
            switch ($p.ExitCode) {
                0 { Write-Host "  Успешно установлено." }
                1638 { Write-Host "  Уже установлено (код 1638)." }
                3010 { Write-Host "  Требуется перезагрузка (код 3010)." }
                default { Write-Warning "  Ошибка: код $($p.ExitCode)." }
            }
        } else {
            Write-Warning "Файл не найден: $fullPath"
        }
    }
} else {
    Write-Warning "Папка drivers\ps не найдена: $driversPsPath"
}

# ========== 4. УСТАНОВКА ИНТЕЛЛЕКТА ПО ВЫБОРУ ==========
Write-Host "`n=== Установка Intellect ==="
$choiceFile = Join-Path $script:driveRoot "choice.txt"
if (Test-Path $choiceFile) {
    $choice = Get-Content $choiceFile -Raw | ForEach-Object { $_.Trim() }
    Write-Host "Выбор: $choice"

    if ($choice -like "intellect-*") {
        $scriptInt = Join-Path $script:driveRoot "intellect\install_intellect.ps1"
        if (Test-Path $scriptInt) {
            $configName = switch -Wildcard ($choice) {
                "intellect-server" { "server.json" }
                "intellect-client" { "client.json" }
                "intellect-admin"  { "admin.json" }
                default { "server.json" }
            }
            $configPath = Join-Path $script:driveRoot "intellect\configs\$configName"
            if (Test-Path $configPath) {
                Write-Host "Установка Intellect с конфигом $configName..."
                & $scriptInt -ConfigFile $configPath
            } else { Write-Warning "Конфиг не найден: $configPath" }
        } else { Write-Warning "Скрипт Intellect не найден: $scriptInt" }
    } # Установка Intellect X
    elseif ($choice -like "intellectx-*") {
        $scriptX = Join-Path $script:driveRoot "intellectx\install_intellectx.ps1"
        if (Test-Path $scriptX) {
            $configName = switch -Wildcard ($choice) {
                "intellectx-serverclient" { "serverclient.json" }
                "intellectx-client"       { "client.json" }
                "intellectx-raftserver"  { "raftserver.json" }
                default { "serverclient.json" }
            }
            $configPath = Join-Path $script:driveRoot "intellectx\configs\$configName"
            if (Test-Path $configPath) {
                Write-Host "Установка Intellect X с конфигом $configName..."
                $logFile = "$env:TEMP\install_intellectx_wrapper.log"
                try {
                    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptX -ConfigFile $configPath *>> $logFile
                    Write-Host "Intellect X установка завершена (код: $LASTEXITCODE)"
                } catch {
                    Write-Host "Ошибка запуска Intellect X: $_"
                }
            } else {
                Write-Warning "Конфиг Intellect X не найден: $configPath"
            }
        } else {
            Write-Warning "Скрипт Intellect X не найден: $scriptX"
        }
    }
    else {
        Write-Host "Неизвестный выбор в choice.txt: $choice"
    }
} else {
    Write-Host "choice.txt не найден, установка Intellect пропущена."
}

# ========== 5. АУДИТ И ОЧИСТКА ==========
Write-Host "`n=== Завершающие операции ==="

# Запуск WinAudit (создание отчёта на рабочем столе)
$winauditPath = "C:\Program Files\WinAudit\WinAudit.exe"
if (Test-Path $winauditPath) {
    $reportPath = [Environment]::GetFolderPath("Desktop") + "\WinAudit_Report.html"
    Write-Host "Запускаю WinAudit, отчёт: $reportPath"
    Start-Process -FilePath $winauditPath -ArgumentList "/output=`"$reportPath`" /quiet" -Wait -NoNewWindow
} else {
    Write-Warning "WinAudit.exe не найден"
}

# Очистка временных файлов
Write-Host "Очистка временных файлов..."
$systemTemp = [Environment]::GetEnvironmentVariable("TEMP", "Machine")
if ($systemTemp) { Remove-Item "$systemTemp\*" -Recurse -Force -ErrorAction SilentlyContinue }
$userTemp = [Environment]::GetEnvironmentVariable("TEMP", "User")
if ($userTemp) { Remove-Item "$userTemp\*" -Recurse -Force -ErrorAction SilentlyContinue }
Remove-Item "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Очистка завершена."

# Отключение чата на панели задач
Write-Host "Отключаем значок чата..."
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarMn" -Value 0 -Type DWord -Force

# Перезапуск проводника для применения обоев
Write-Host "Перезапускаем проводник..."
Stop-Process -Name explorer -Force

Install-MegaRaidStack -DriveRoot $script:driveRoot

# ========== 5.5. УСТАНОВКА ЗАВИСИМОСТЕЙ ДЛЯ ТЕСТИРОВАНИЯ ==========
Write-Host "`n=== Установка зависимостей для тестирования ===" -ForegroundColor Cyan

# Ищем install_dependencies.ps1
$installDepsScript = $null
$possibleDepsPaths = @(
    (Join-Path $script:driveRoot "install_dependencies.ps1"),
    (Join-Path $PSScriptRoot "..\..\install_dependencies.ps1"),
    (Join-Path $PSScriptRoot "install_dependencies.ps1")
)

foreach ($path in $possibleDepsPaths) {
    if (Test-Path $path) {
        $installDepsScript = $path
        break
    }
}

if ($installDepsScript) {
    Write-Host "Запуск install_dependencies.ps1..."
    try {
        & $installDepsScript
        Write-Host "Зависимости установлены." -ForegroundColor Green
    } catch {
        Write-Warning "Ошибка установки зависимостей: $_"
    }
} else {
    Write-Warning "install_dependencies.ps1 не найден"
}

# ========== 6. ПЕРЕЗАГРУЗКА ПЕРЕД АВТОМАТИЧЕСКИМ СТРЕСС-ТЕСТОМ ==========
Write-Host "`n=== Подготовка к перезагрузке перед стресс-тестом ===" -ForegroundColor Cyan

$programDataRoot = Join-Path $env:ProgramData 'IPDROM'
$rebootMarker = Join-Path $programDataRoot 'BeforeStressTestReboot.done'
$taskName = 'IPDROM_AutoStressTest_AfterReboot'
New-Item -ItemType Directory -Path $programDataRoot -Force | Out-Null

$autoTestScript = Join-Path $script:driveRoot "customization\scripts\auto_stress_test.ps1"
if (-not (Test-Path $autoTestScript)) {
    $autoTestScript = Join-Path $PSScriptRoot "auto_stress_test.ps1"
}

if (-not (Test-Path $rebootMarker)) {
    if (Test-Path $autoTestScript) {
        try {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

            $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$autoTestScript`" -DurationMinutes 720"

            $action = New-ScheduledTaskAction -Execute $psExe -Argument $arg
            $trigger = New-ScheduledTaskTrigger -AtLogOn
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

            Register-ScheduledTask -TaskName $taskName `
                                   -Action $action `
                                   -Trigger $trigger `
                                   -Settings $settings `
                                   -RunLevel Highest `
                                   -Force | Out-Null

            Set-Content -Path $rebootMarker -Value (Get-Date -Format 's') -Force
            Write-Host "Стресс-тест будет автоматически запущен после входа в Windows." -ForegroundColor Yellow
            Write-Host "Scheduled Task: $taskName"
            Write-Host "Сценарий теста: $autoTestScript"
            Write-Host "Выполняется перезагрузка системы..." -ForegroundColor Yellow
            Restart-Computer -Force
            exit
        } catch {
            throw "Не удалось подготовить автозапуск стресс-теста после перезагрузки: $_"
        }
    } else {
        Write-Warning "auto_stress_test.ps1 не найден, стресс-тест пропущен."
    }
} else {
    Write-Host "Перезагрузка перед тестированием уже была выполнена ранее, повторно не требуется." -ForegroundColor Green
    if (Test-Path $autoTestScript) {
        Write-Host "Запуск стресс-теста без дополнительной перезагрузки: $autoTestScript"
        & $autoTestScript -DurationMinutes 720
    } else {
        Write-Warning "auto_stress_test.ps1 не найден, тест пропущен."
    }
}

Write-Host "`n=== Кастомизация полностью завершена ==="
