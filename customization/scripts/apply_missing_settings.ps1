<#
.SYNOPSIS
    Donastraivaet sistemu po pp. iz Check-IPDROM-Config, kotorye ranshe
    ne vyplnyalis' setup_apps_and_theme.ps1.

    Pokryvaet (nomera sootvetstvuyut Check-IPDROM-Config):
       1  OEMBackground=1                  (brending ekrana logona)
       3  EnableFirstLogonAnimation=0      (animaciya pri pervom vhode)
       9  ShowFrequent=0, ShowRecent=0     (chasto/nedavno v Provodnike)
      11  AllowEdgeSwipe=0                 (svaypy ekrana)
      12  Start_ShowHelp=0                 (znachok pomoshchi v Start)
      14  EnablePrefetcher=0               (otklyuchaem Prefetch)
      16  Label C: = "System Disk"
      19  Klassicheskiy PKM v Win11        (HKCU\Software\Classes\CLSID...)
      22  UseDefaultTile=1                 (zapret menyat' avatar)
      22b user.png -> User Account Pictures (brendirovanniy avatar-tile)
      26  lfsvc / DPS / diagnosticshub     (otklyuchaem sluzhby)
      27  DisableNotificationCenter=1      (centr uvedomleniy)
      28  ToastEnabled=0                   (toast-uvedomleniya)

    HKCU-veshchi primenyayutsya k:
       - tekushchemu pol'zovatelyu (HKCU)
       - default user hive (chtoby novye akkaunty unasledovali)

    Pp. 4, 5 (monitor/disk power) - uzhe nastraivayutsya powercfg
    v setup_apps_and_theme.ps1, eto bag samogo checkera (chitaet ne ottuda),
    a ne sborki. Tem ne menee dlya nadezhnosti dublyrayem PolicyAC tut zhe.

    P. 24 (tema IPDROM) trebuet fizicheskogo fayla .theme - eto otdelnaya
    zadacha (delaesh' v themepack i kladesh' v C:\Windows\Resources\Themes\).
    Zdes' tol'ko stavim wallpaper-bazu, kotoraya uzhe est' v setup_apps_and_theme.

.NOTES
    Idempotenten: vse reg.exe add / Set-Service mozhno gnat' povtorno.
    Vyzyvat' iz setup_apps_and_theme.ps1 v konce, pered Restart-Computer.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

# ===================== LOG =====================
$logDir  = Join-Path $env:ProgramData 'IPDROM\Logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir ("apply_missing_settings_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function Write-Log {
    param([string]$Msg, [string]$Color = 'White')
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
    try { $line | Out-File -FilePath $logFile -Encoding utf8 -Append } catch {}
    Write-Host $Msg -ForegroundColor $Color
}

Write-Log "=== apply_missing_settings started ===" 'Cyan'

# ---------- helper: write HKCU value to current user + default user ----------
# Default-user hive (C:\Users\Default\NTUSER.DAT) chitaem cherez reg.exe LOAD
# kak HKU\IpdromDefault, primenyaem i UNLOAD.
$defLoaded = $false
$defHive   = 'C:\Users\Default\NTUSER.DAT'
$defKey    = 'IpdromDefault'
try {
    reg.exe load "HKU\$defKey" $defHive 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $defLoaded = $true
        Write-Log "Default user hive loaded as HKU\$defKey" 'Gray'
    } else {
        Write-Log "Could not load default user hive (LASTEXITCODE=$LASTEXITCODE) - new users will not inherit HKCU tweaks." 'Yellow'
    }
} catch {
    Write-Log "reg.exe LOAD failed: $_" 'Yellow'
}

function Set-HkcuValue {
    param(
        [Parameter(Mandatory)][string]$SubKey,   # e.g. 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Type,     # REG_DWORD / REG_SZ
        [Parameter(Mandatory)][string]$Data
    )
    # current user
    reg.exe add "HKCU\$SubKey" /v $Name /t $Type /d $Data /f | Out-Null
    # default user (esli zagruzilsya)
    if ($script:defLoaded) {
        reg.exe add "HKU\$($script:defKey)\$SubKey" /v $Name /t $Type /d $Data /f | Out-Null
    }
}

# ===================== 1. OEMBackground (brending logona) =====================
Write-Log "[1]  OEMBackground=1" 'Cyan'
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\Background" /v OEMBackground /t REG_DWORD /d 1 /f | Out-Null

# ===================== 3. EnableFirstLogonAnimation=0 =====================
Write-Log "[3]  EnableFirstLogonAnimation=0" 'Cyan'
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableFirstLogonAnimation /t REG_DWORD /d 0 /f | Out-Null

# ===================== 9. ShowFrequent / ShowRecent =====================
Write-Log "[9]  ShowFrequent=0, ShowRecent=0 (Quick Access)" 'Cyan'
Set-HkcuValue -SubKey 'Software\Microsoft\Windows\CurrentVersion\Explorer' -Name 'ShowFrequent' -Type REG_DWORD -Data 0
Set-HkcuValue -SubKey 'Software\Microsoft\Windows\CurrentVersion\Explorer' -Name 'ShowRecent'   -Type REG_DWORD -Data 0

# ===================== 11. AllowEdgeSwipe=0 =====================
Write-Log "[11] AllowEdgeSwipe=0 (edge swipes off)" 'Cyan'
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\EdgeUI" /v AllowEdgeSwipe /t REG_DWORD /d 0 /f | Out-Null

# ===================== 12. Start_ShowHelp=0 =====================
Write-Log "[12] Start_ShowHelp=0" 'Cyan'
Set-HkcuValue -SubKey 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_ShowHelp' -Type REG_DWORD -Data 0

# ===================== 14. EnablePrefetcher=0 =====================
# Tehnicheski na NVMe Prefetch ne nuzhen i tol'ko zhret IO pri zagruzke.
# Stavim 0 (off), kak ozhidaet checker. Tam zhe Superfetch (SysMain) - ostavlyaem
# kak est', otdel'nyy peremennyy.
Write-Log "[14] EnablePrefetcher=0" 'Cyan'
reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters" /v EnablePrefetcher /t REG_DWORD /d 0 /f | Out-Null

# ===================== 16. Label C: = "System Disk" =====================
Write-Log "[16] Label C: = 'System Disk'" 'Cyan'
try {
    Set-Volume -DriveLetter C -NewFileSystemLabel 'System Disk' -ErrorAction Stop
    Write-Log "  Label set." 'Green'
} catch {
    # fallback cherez label.exe (na sluchaj esli Set-Volume nedostupen)
    cmd.exe /c "label C: System Disk" 2>&1 | Out-Null
    Write-Log "  Used label.exe fallback." 'Yellow'
}

# ===================== 19. Klassicheskiy PKM v Win11 =====================
# Empty default-value v InprocServer32 polnost'yu vyklyuchaet "Show more options".
# Eto HKCU-tvik, primenyaetsya k tekushchemu pol'zovatelyu + default user.
Write-Log "[19] Classic context menu (Win11)" 'Cyan'
$classicCLSID = 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
# /ve = (Default) value, pustaya stroka
reg.exe add "HKCU\$classicCLSID" /f /ve /d "" | Out-Null
if ($defLoaded) {
    reg.exe add "HKU\$defKey\$classicCLSID" /f /ve /d "" | Out-Null
}

# ===================== 22. UseDefaultTile=1 (zapret menyat' avatar) =====================
Write-Log "[22] UseDefaultTile=1 (lock user picture)" 'Cyan'
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v UseDefaultTile /t REG_DWORD /d 1 /f | Out-Null

# ===================== 22b. Branded default account picture (user.png) =====================
# UseDefaultTile=1 (above) forces every account to the DEFAULT tile located in
# C:\ProgramData\Microsoft\User Account Pictures\. Nothing ever replaced that default
# with our branded image, so Windows kept showing the stock silhouette. Copy
# customization\avatars\user.png over the default tiles. They are TrustedInstaller-owned,
# so take ownership + grant Administrators (SID S-1-5-32-544, locale-safe) before overwrite.
Write-Log "[22b] Brand default account tiles with user.png" 'Cyan'
$avatarSrc   = $null
$avatarRoots = @()
$irFile = 'C:\ProgramData\IPDROM\State\InstallRoot.txt'
if (Test-Path $irFile) { $avatarRoots += ((Get-Content $irFile -Raw -ErrorAction SilentlyContinue).Trim()) }
$avatarRoots += 'C:\IPDROM'
foreach ($d in [System.IO.DriveInfo]::GetDrives()) { $avatarRoots += $d.RootDirectory.FullName }
foreach ($r in $avatarRoots) {
    if ([string]::IsNullOrWhiteSpace($r)) { continue }
    $cand = Join-Path $r 'customization\avatars\user.png'
    if (Test-Path $cand) { $avatarSrc = $cand; break }
}
if ($avatarSrc) {
    Write-Log "  source: $avatarSrc" 'Gray'
    $picDir = Join-Path $env:ProgramData 'Microsoft\User Account Pictures'
    if (-not (Test-Path $picDir)) { New-Item -ItemType Directory -Force -Path $picDir | Out-Null }
    # Folder ownership first so missing size-variants can be (re)created.
    & takeown.exe /f "$picDir" 2>&1 | Out-Null
    & icacls.exe  "$picDir" /grant "*S-1-5-32-544:(OI)(CI)F" 2>&1 | Out-Null
    # user.png = legacy fallback; user-<size>.png = the tiles actually rendered in the UI.
    foreach ($name in @('user.png','user-32.png','user-40.png','user-48.png','user-192.png')) {
        $dst = Join-Path $picDir $name
        if (Test-Path $dst) {
            & takeown.exe /f "$dst" 2>&1 | Out-Null
            & icacls.exe  "$dst" /grant "*S-1-5-32-544:F" 2>&1 | Out-Null
        }
        try {
            Copy-Item -LiteralPath $avatarSrc -Destination $dst -Force -ErrorAction Stop
            Write-Log "  -> $name replaced" 'Green'
        } catch {
            Write-Log "  !! $name : $($_.Exception.Message)" 'Yellow'
        }
    }
} else {
    Write-Log "  user.png source NOT found (customization\avatars\user.png) - avatar not branded" 'Yellow'
}

# ===================== 26. Sluzhby: lfsvc, DPS, diagnosticshub =====================
Write-Log "[26] Disable services: lfsvc, DPS, diagnosticshub.standardcollector.service" 'Cyan'
$svcs = @(
    'lfsvc',                                       # Geolocation Service
    'DPS',                                          # Diagnostic Policy Service
    'diagnosticshub.standardcollector.service'     # Microsoft (R) Diagnostics Hub
)
foreach ($s in $svcs) {
    try {
        $svc = Get-Service -Name $s -ErrorAction Stop
        if ($svc.Status -eq 'Running') {
            Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
        }
        Set-Service -Name $s -StartupType Disabled -ErrorAction Stop
        Write-Log "  $s -> Disabled" 'Green'
    } catch {
        Write-Log "  $s : $_" 'Yellow'
    }
}

# ===================== 27. DisableNotificationCenter=1 =====================
Write-Log "[27] DisableNotificationCenter=1" 'Cyan'
Set-HkcuValue -SubKey 'Software\Policies\Microsoft\Windows\Explorer' -Name 'DisableNotificationCenter' -Type REG_DWORD -Data 1
# Mashinnaya policy dublyruet (na sluchaj esli checker chitaet HKLM)
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer" /v DisableNotificationCenter /t REG_DWORD /d 1 /f | Out-Null

# ===================== 28. ToastEnabled=0 =====================
Write-Log "[28] ToastEnabled=0" 'Cyan'
Set-HkcuValue -SubKey 'Software\Microsoft\Windows\CurrentVersion\PushNotifications' -Name 'ToastEnabled' -Type REG_DWORD -Data 0

# ===================== UNLOAD default user hive =====================
if ($defLoaded) {
    # GC pered UNLOAD - inache reg.exe ne otpustit hive iz-za vise schih handles.
    [gc]::Collect()
    [gc]::WaitForPendingFinalizers()
    reg.exe unload "HKU\$defKey" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Default user hive unloaded." 'Gray'
    } else {
        Write-Log "reg.exe UNLOAD failed (LASTEXITCODE=$LASTEXITCODE) - hive may stay loaded until reboot." 'Yellow'
    }
}

Write-Log "=== apply_missing_settings finished ===" 'Cyan'
exit 0
