<#
.SYNOPSIS
  Автоматическая установка Интеллекта (классическая версия) с раздающего сервера.
  Использует конфигурационный файл JSON для всех параметров.

.DESCRIPTION
  Скрипт скачивает дистрибутив по manifest-файлу (или через зеркалирование для клиента),
  устанавливает базу (Server, Client или Admin) и, при необходимости, аддоны (включая ACFA).
  Все настройки берутся из JSON-файла, переданного через параметр -ConfigFile.
  Интерактивные запросы отсутствуют.

.PARAMETER ConfigFile
  Путь к JSON-файлу конфигурации (обязательный).

.EXAMPLE
  .\install_intellect.ps1 -ConfigFile "C:\configs\server.json"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "Этот скрипт требует PowerShell 7 или выше. Текущая версия: $($PSVersionTable.PSVersion). Запусти через pwsh.exe."
}

# ---- Чтение конфига ----
if (-not (Test-Path $ConfigFile)) {
    Write-Error "Config file not found: $ConfigFile"
    exit 1
}
try {
    $config = Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json
}
catch {
    Write-Error "Failed to parse JSON config: $_"
    exit 1
}

# ---- Базовые настройки из конфига ----
$BaseUrl   = $config.general.baseUrl
$WorkRoot  = if ($config.general.PSObject.Properties['workRoot']) { $config.general.workRoot } else { "$env:TEMP\intellect_http" }
$KeepCache = if ($config.general.PSObject.Properties['keepCache']) { $config.general.keepCache } else { $false }

$InstallType = $config.installType

# ---- SQL настройки (для Server) ----
$SqlSettings = @{
    Instance        = '(local)'
    AuthType        = 'Windows'
    Username        = ''
    Password        = ''
    DbIntellectName = 'intellect'
    DbTitlesName    = 'titles'
}
if ($config.PSObject.Properties['sql']) {
    $sqlNode = $config.sql
    if ($sqlNode.PSObject.Properties['instance'])      { $SqlSettings.Instance = $sqlNode.instance }
    if ($sqlNode.PSObject.Properties['authType'])      { $SqlSettings.AuthType = $sqlNode.authType }
    if ($sqlNode.PSObject.Properties['username'])      { $SqlSettings.Username = $sqlNode.username }
    if ($sqlNode.PSObject.Properties['password'])      { $SqlSettings.Password = $sqlNode.password }
    if ($sqlNode.PSObject.Properties['dbIntellectName']) { $SqlSettings.DbIntellectName = $sqlNode.dbIntellectName }
    if ($sqlNode.PSObject.Properties['dbTitlesName'])  { $SqlSettings.DbTitlesName = $sqlNode.dbTitlesName }
}

$GuardantRemove = $false
if ($config.PSObject.Properties['guardant']) {
    if ($config.guardant.PSObject.Properties['remove']) {
        $GuardantRemove = $config.guardant.remove
    }
}

$CmdProps = ""
if ($config.PSObject.Properties['options']) {
    if ($config.options.PSObject.Properties['cmdProps']) {
        $CmdProps = $config.options.cmdProps
    }
}

$InstallDir = "C:\Program Files\Intellect"
if ($config.PSObject.Properties['options'] -and $config.options.PSObject.Properties['installDir']) {
    $InstallDir = $config.options.installDir
}

$AddonsList = @()
if ($config.PSObject.Properties['addons']) {
    $AddonsList = @($config.addons)
}

$AcfaModules = @()
if ($config.PSObject.Properties['acfa']) {
    if ($config.acfa.PSObject.Properties['modules']) {
        $AcfaModules = @($config.acfa.modules)
    }
}

# ---- Подготовка URL ----
$BaseUrl = $BaseUrl.TrimEnd('/')
try { $u = [Uri]$BaseUrl } catch { throw "Invalid BaseUrl: $BaseUrl" }
$script:ServerRoot = "{0}://{1}:{2}" -f $u.Scheme, $u.Host, $u.Port
$script:ShareRoot  = $u.AbsolutePath.Trim('/')

# ---- Рабочие папки ----
$Downloads = Join-Path $WorkRoot 'downloads'
$Logs      = Join-Path $WorkRoot 'logs'
New-Item -ItemType Directory -Force -Path $WorkRoot,$Downloads,$Logs | Out-Null

# ============================================================
#   ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ (без изменений)
# ============================================================

function Write-Ok   ([string]$m){ Write-Host $m -ForegroundColor Green  }
function Write-Warn ([string]$m){ Write-Warning $m                      }
function Write-Info ([string]$m){ Write-Host $m -ForegroundColor Cyan   }
function Write-Step ([string]$m){ Write-Host $m -ForegroundColor Yellow }
function Ok   ([string]$m){ Write-Ok $m }
function Warn ([string]$m){ Write-Warn $m }

function Get-ShareEntries {
    param([Parameter(Mandatory=$true)][string]$RelPath)

    $rel = $RelPath.Trim('/')
    $u1 = if ([string]::IsNullOrWhiteSpace($rel)) { "$($script:ServerRoot)/hash" } else { "$($script:ServerRoot)/hash/$rel" }
    $u2 = if ($u1.EndsWith('/')) { $u1 } else { $u1 + '/' }

    function Invoke-HashUrl([string]$u) {
        try {
            return (Invoke-WebRequest -Uri $u -UseBasicParsing -ErrorAction Stop)
        } catch {
            return $null
        }
    }

    $resp = Invoke-HashUrl $u1
    if (-not $resp -or [string]::IsNullOrWhiteSpace($resp.Content)) {
        $resp = Invoke-HashUrl $u2
    } else {
        $trim = ($resp.Content.Trim())
        if ($trim -eq "{}" -or $trim -eq "[]" ) {
            $resp2 = Invoke-HashUrl $u2
            if ($resp2 -and -not [string]::IsNullOrWhiteSpace($resp2.Content)) {
                $resp = $resp2
            }
        }
    }

    if (-not $resp) {
        throw "Не удалось получить данные по URL: $u1 (и $u2)"
    }

    try {
        $json = $resp.Content | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $head = $resp.Content.Substring(0,[Math]::Min(200,$resp.Content.Length))
        throw "Ответ /hash не JSON. Первые 200 символов: $head"
    }

    $out = @()

    if ($json -is [System.Collections.IEnumerable] -and -not ($json -is [System.Collections.IDictionary]) -and -not ($json -is [string])) {
        foreach ($e in @($json)) {
            if ($null -eq $e) { continue }
            if ($e -is [string]) {
                $n = $e.Trim()
                if ($n) { $out += [pscustomobject]@{ name=$n.TrimEnd('/'); is_dir=$n.EndsWith('/') } }
            } else {
                $n = $null
                foreach($k in @("name","path","file","filename","rel","item")) {
                    if ($e.PSObject.Properties.Match($k).Count -gt 0) { $n = [string]$e.$k; break }
                }
                if (-not $n) { continue }
                $isDir = $false
                foreach($k in @("is_dir","isdir","dir","folder")) {
                    if ($e.PSObject.Properties.Match($k).Count -gt 0) { $isDir = [bool]$e.$k; break }
                }
                if ($e.PSObject.Properties.Match("type").Count -gt 0) {
                    if ([string]$e.type -match "dir|folder") { $isDir = $true }
                }
                $out += [pscustomobject]@{ name=$n.Trim().TrimStart('/').TrimEnd('/'); is_dir=$isDir }
            }
        }
        return $out
    }

    if ($json -is [System.Collections.IDictionary] -or $json -is [pscustomobject]) {
        $props = @()
        if ($json -is [System.Collections.IDictionary]) {
            $props = $json.Keys | ForEach-Object { [pscustomobject]@{ Name=[string]$_; Value=$json[$_] } }
        } else {
            $props = $json.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name=$_.Name; Value=$_.Value } }
        }

        foreach ($p in $props) {
            $name = [string]$p.Name
            if ([string]::IsNullOrWhiteSpace($name)) { continue }

            $val = $p.Value
            $isDir = $false
            if ($name.EndsWith('/')) { $isDir = $true; $name = $name.TrimEnd('/') }
            elseif ($val -is [System.Collections.IDictionary] -or $val -is [pscustomobject]) { $isDir = $true }

            $out += [pscustomobject]@{ name=$name; is_dir=$isDir }
        }
        return $out
    }

    if ($json -is [string]) { return @([pscustomobject]@{ name=$json; is_dir=$false }) }

    throw "Неожиданный формат JSON /hash. Тип: $($json.GetType().FullName)"
}

function Dl-Url([string]$RelFile) {
    $rel = $RelFile.TrimStart('/')
    return "$($script:ServerRoot)/dl/$rel"
}

function Download-File {
    param(
        [Parameter(Mandatory=$true)][string]$RelFile,
        [Parameter(Mandatory=$true)][string]$Dest
    )
    $destDir = Split-Path $Dest -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
    Invoke-WebRequest -Uri (Dl-Url $RelFile) -UseBasicParsing -OutFile $Dest -ErrorAction Stop
}

function Mirror-ShareDir {
    param(
        [Parameter(Mandatory=$true)][string]$RelPath,
        [Parameter(Mandatory=$true)][string]$LocalRoot,
        [int]$ProgressId = 1
    )

    if (-not (Test-Path $LocalRoot)) { New-Item -ItemType Directory -Force -Path $LocalRoot | Out-Null }

    $entries = Get-ShareEntries -RelPath $RelPath
    $total = @($entries).Count
    $i = 0

    foreach ($e in @($entries)) {
        $i++
        $name = [string]$e.name
        if (-not $name) { continue }

        $remote = ($RelPath.TrimEnd('/') + '/' + $name).TrimStart('/')
        $local  = Join-Path $LocalRoot $name

        $pct = if ($total -gt 0) { [int](($i / $total) * 100) } else { 0 }
        Write-Progress -Id $ProgressId -Activity "Скачивание: $RelPath" -Status $name -PercentComplete $pct

        if ($e.is_dir) {
            if (-not (Test-Path $local)) { New-Item -ItemType Directory -Force -Path $local | Out-Null }
            Mirror-ShareDir -RelPath $remote -LocalRoot $local -ProgressId $ProgressId
        } else {
            Download-File -RelFile $remote -Dest $local
        }
    }

    Write-Progress -Id $ProgressId -Activity "Скачивание: $RelPath" -Completed
}

function Start-Proc {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string]$Arguments,
        [string]$WorkingDirectory,
        [string]$LogPath
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    if ($LogPath) {
        New-Item -ItemType Directory -Force -Path (Split-Path $LogPath -Parent) | Out-Null
        Set-Content -LiteralPath $LogPath -Value ($out + "`r`n" + $err) -Encoding UTF8
    }

    return $p.ExitCode
}

function Fix-LanguagesCaseForWindows {
    param([Parameter(Mandatory=$true)][string]$BaseFolder)

    $src = Join-Path $BaseFolder "languages\Setup"
    $dst = Join-Path $BaseFolder "Languages\Setup"

    if (-not (Test-Path $src)) {
        throw "Не найден источник языков: $src"
    }

    if (Test-Path $dst) {
        $mst = Get-ChildItem -LiteralPath $dst -Recurse -Filter *.mst -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($mst) { return }
    }

    New-Item -ItemType Directory -Force -Path $dst | Out-Null

    Write-Info "Исправляю регистр папки языков: копирую languages\Setup -> Languages\Setup"
    Copy-Item -LiteralPath (Join-Path $src "*") -Destination $dst -Recurse -Force

    $mst2 = Get-ChildItem -LiteralPath $dst -Recurse -Filter *.mst -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $mst2) {
        throw "После копирования не найден *.mst в $dst"
    }

    Write-Ok ("Языки готовы: {0}" -f $mst2.FullName)
}

function Ensure-LanguagesSetup {
    param([Parameter(Mandatory=$true)][string]$DstFolder)

    $target = Join-Path $DstFolder "languages\Setup"
    if (Test-Path $target) { return }

    Write-Info "Языковые файлы отсутствуют — докачиваю base/languages/Setup ..."

    $rel = ($script:ShareRoot.TrimEnd('/') + '/base/languages/Setup').TrimStart('/')

    try {
        Mirror-ShareDir -RelPath $rel -LocalRoot $target -ProgressId 5
    } catch {
        throw "Не удалось скачать языковые файлы из '$rel'. Причина: $($_.Exception.Message)"
    }

    if (-not (Test-Path $target)) {
        throw "Языковые файлы всё ещё не появились: $target"
    }
}

function Is-ServerOS {
  try {
    $p = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    return ($p.ProductType -ne 1)
  } catch {
    return $false
  }
}

function Ensure-IIS-Features {
  param([string[]]$FeatureNames)

  if (-not $FeatureNames -or $FeatureNames.Count -eq 0) { return }

  $isServer = Is-ServerOS
  if ($isServer) {
    try { Import-Module ServerManager -ErrorAction Stop | Out-Null } catch { throw "Не удалось загрузить модуль ServerManager для IIS: $($_.Exception.Message)" }
    foreach ($f in $FeatureNames) {
      try {
        $st = Get-WindowsFeature -Name $f -ErrorAction Stop
        if (-not $st.Installed) {
          Write-Info ("IIS: включаю WindowsFeature {0} ..." -f $f)
          $r = Add-WindowsFeature -Name $f -ErrorAction Stop
        }
      } catch {
        throw "IIS: не удалось включить WindowsFeature '$f': $($_.Exception.Message)"
      }
    }
    return
  }

  foreach ($f in $FeatureNames) {
    $dismArgs = "/online /Enable-Feature /FeatureName:$f /All /NoRestart"
    Write-Info ("IIS: включаю optional feature {0} ..." -f $f)
    $p = Start-Process -FilePath "$env:SystemRoot\System32\dism.exe" -ArgumentList $dismArgs -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -notin 0,3010,1641) {
      throw "DISM не смог включить feature '$f'. Код: $($p.ExitCode)"
    }
  }
}

function Ensure-WebReportPrereqs {
  param(
    [string]$TransformRel = "",
    [switch]$SkipDotNet
  )

  Write-Host ""
  Write-Host "WEB_REPORT: проверка prerequisites (IIS / ASP.NET / WCF)..." -ForegroundColor Yellow

  $iis = @(
    "IIS-WebServerRole",
    "IIS-WebServer",
    "IIS-CommonHttpFeatures",
    "IIS-StaticContent",
    "IIS-DefaultDocument",
    "IIS-HttpErrors",
    "IIS-HttpRedirect",
    "IIS-ApplicationDevelopment",
    "IIS-ASPNET45",
    "IIS-NetFxExtensibility45",
    "IIS-ISAPIExtensions",
    "IIS-ISAPIFilter",
    "IIS-ManagementConsole"
  )

  try {
    Ensure-IIS-Features -FeatureNames $iis
    Write-Ok "WEB_REPORT: IIS компоненты включены (или уже были включены)."
  } catch {
    Write-Warn ("WEB_REPORT: не удалось включить IIS автоматически: {0}" -f $_.Exception.Message)
    Write-Warn "Продолжаю установку — но MSI может падать 1603, если IIS отсутствует."
  }

  try {
    $iisreset = Join-Path $env:SystemRoot "System32\iisreset.exe"
    if (Test-Path $iisreset) { Start-Process -FilePath $iisreset -ArgumentList "/noforce" -Wait | Out-Null }
  } catch {}
}

function Resolve-IntellectSqlInstance {
    try {
        $svc = Get-Service -Name "MSSQLSERVER" -ErrorAction SilentlyContinue
        if ($svc) { return '(local)' }
    } catch {}

    try {
        $named = Get-Service -Name "MSSQL`$*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($named) {
            $instanceName = $named.Name -replace '^MSSQL\$', ''
            return ".\$instanceName"
        }
    } catch {}

    return $null
}

function Ensure-SqlServiceForInstance {
    param([Parameter(Mandatory=$true)][string]$SqlInstanceValue)
    if ($SqlInstanceValue -eq '(local)' -or $SqlInstanceValue -eq '.' -or $SqlInstanceValue -eq 'localhost') {
        $svc = Get-Service -Name "MSSQLSERVER" -ErrorAction SilentlyContinue
        if (-not $svc) { throw "SQL Service MSSQLSERVER не найден." }
        if ($svc.Status -ne 'Running') { Start-Service "MSSQLSERVER"; Start-Sleep -Seconds 2 }
        Write-Info "SQL service найден: MSSQLSERVER"
    }
}

function Ensure-SqlDefaultInstance {
    param([Parameter(Mandatory=$true)][string]$BaseDstFolder)

    $sqlDir = Join-Path $BaseDstFolder "Redist\SQL Server Express"
    if (-not (Test-Path $sqlDir)) { throw "Не найден каталог SQL Server Express: $sqlDir" }

    $exe = Get-ChildItem -LiteralPath $sqlDir -Filter "SQLEXPR_x64_ENU.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) { $exe = Get-ChildItem -LiteralPath $sqlDir -Filter "SQLEXPR_x86_ENU.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $exe) { throw "Не найден SQLEXPR_*.exe в $sqlDir" }

    Write-Info ("Запускаю установку SQL Express: {0}" -f $exe.FullName)
    $log = Join-Path $Logs ("sql_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
    $sqlArgs = "/qs /x:setup /ACTION=Install /FEATURES=SQL /INSTANCENAME=MSSQLSERVER /SQLSVCACCOUNT=`"NT AUTHORITY\NETWORK SERVICE`" /SQLSYSADMINACCOUNTS=`"BUILTIN\Administrators`" /TCPENABLED=1 /NPENABLED=1 /IACCEPTSQLSERVERLICENSETERMS"
    $ec = Start-Proc -FilePath $exe.FullName -Arguments $sqlArgs -WorkingDirectory $sqlDir -LogPath $log
    if ($ec -notin 0,3010,1641) { throw "SQL Express installer exit code: $ec. Log: $log" }
    Write-Ok "SQL Express установлен/обновлён. Код: $ec. Log: $log"
}

function Ensure-IntellectSqlRights {
    param([Parameter(Mandatory=$true)][string]$Server)

    $q = @"
IF NOT EXISTS (SELECT * FROM sys.server_principals WHERE name = N'BUILTIN\Administrators')
  CREATE LOGIN [BUILTIN\Administrators] FROM WINDOWS;
EXEC sp_addsrvrolemember N'BUILTIN\Administrators', N'sysadmin';

IF NOT EXISTS (SELECT * FROM sys.server_principals WHERE name = N'NT AUTHORITY\NETWORK SERVICE')
  CREATE LOGIN [NT AUTHORITY\NETWORK SERVICE] FROM WINDOWS;
EXEC sp_addsrvrolemember N'NT AUTHORITY\NETWORK SERVICE', N'sysadmin';
"@

    $sqlcmd = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
    if ($sqlcmd) {
        $tmpSql = [System.IO.Path]::GetTempFileName() + ".sql"
        try {
            Set-Content -LiteralPath $tmpSql -Value $q -Encoding UTF8
            $p = Start-Process -FilePath $sqlcmd.Source `
                -ArgumentList @("-S", $Server, "-E", "-i", "`"$tmpSql`"", "-b") `
                -Wait -PassThru -WindowStyle Hidden
            if ($p.ExitCode -ne 0) { throw "sqlcmd.exe exit code: $($p.ExitCode)" }
            Write-Info "SQL права выданы (sqlcmd.exe): BUILTIN\Администраторы + NT AUTHORITY\NETWORK SERVICE"
            return
        }
        finally {
            try { Remove-Item -LiteralPath $tmpSql -ErrorAction SilentlyContinue } catch {}
        }
    }

    try { Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue | Out-Null } catch {}
    try { if (Get-Module -ListAvailable -Name SqlServer) { Import-Module SqlServer -ErrorAction SilentlyContinue | Out-Null } } catch {}

    if (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue) {
        Invoke-Sqlcmd -ServerInstance $Server -Query $q -ErrorAction Stop | Out-Null
        Write-Info "SQL права выданы (Invoke-Sqlcmd): BUILTIN\Администраторы + NT AUTHORITY\NETWORK SERVICE"
        return
    }

    throw "Не найден ни sqlcmd.exe, ни Invoke-Sqlcmd. Установи SQL Server Command Line Utilities."
}

function Find-InstalledPath([string]$PreferredInstallDir) {
    $candidates = @(
        $PreferredInstallDir,
        "C:\Program Files (x86)\Интеллект",
        "C:\Program Files\Интеллект",
        "C:\Program Files (x86)\Intellect",
        "C:\Program Files\Intellect",
        "C:\Program Files (x86)\AxxonSoft\Intellect",
        "C:\Program Files\AxxonSoft\Intellect"
    ) | Where-Object { $_ -and $_.Trim() -ne "" }

    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }

    $uninstRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    foreach ($root in $uninstRoots) {
        foreach ($k in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            try {
                $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
                $dn = [string]$p.DisplayName
                if (-not $dn) { continue }

                if ($dn -match 'Intellect|Интеллект|Axxon') {
                    Write-Host ("Найдена запись в Программах: {0}  (ver {1})" -f $dn, $p.DisplayVersion) -ForegroundColor Cyan
                    $loc = [string]$p.InstallLocation
                    if ($loc -and (Test-Path $loc)) { return $loc }
                }
            } catch {}
        }
    }

    return $null
}

function Wait-MsiSince([datetime]$StartStamp, [int]$MaxMinutes = 60) {
    Write-Step "Жду завершения msiexec (если setup запустил MSI в фоне)..."
    $deadline = (Get-Date).AddMinutes($MaxMinutes)

    while ((Get-Date) -lt $deadline) {
        $msi = Get-CimInstance Win32_Process -Filter "Name='msiexec.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                try {
                    $cd = [System.Management.ManagementDateTimeConverter]::ToDateTime($_.CreationDate)
                    $cd -ge $StartStamp.AddSeconds(-5)
                } catch { $false }
            }

        if (-not $msi) { break }

        $pids = ($msi.ProcessId | Sort-Object -Unique) -join ", "
        Write-Info ("msiexec ещё работает (PID): {0}" -f $pids)
        Start-Sleep -Seconds 5
    }

    Write-Ok "msiexec завершён (или не запускался)"
}

function Show-MsiFailHint {
  param([Parameter(Mandatory=$true)][string]$LogPath)

  if (-not (Test-Path -LiteralPath $LogPath)) { return }

  Write-Host ""
  Write-Host "==== MSI DIAG: $LogPath ====" -ForegroundColor Yellow

  try {
    $hit = Select-String -Path $LogPath -Pattern "Return value 3" -SimpleMatch | Select-Object -Last 1
    if ($hit) {
      $ctx = Select-String -Path $LogPath -Pattern "Return value 3" -Context 0,25 | Select-Object -Last 1
      $ctx.Context.PostContext | ForEach-Object { $_.Line } | ForEach-Object {
        if ($_ -match "error|failed|CustomAction|CAQuietExec|condition|InstallValidate") {
          Write-Host $_ -ForegroundColor Red
        } else {
          Write-Host $_
        }
      }
    } else {
      Get-Content -LiteralPath $LogPath -Tail 80 | ForEach-Object { Write-Host $_ }
    }
  } catch {
    Write-Warning "Не смог прочитать лог: $($_.Exception.Message)"
  }

  Write-Host "==== END MSI DIAG ====" -ForegroundColor Yellow
  Write-Host ""
}

function Install-Msi-Quiet {
  param(
    [Parameter(Mandatory=$true)][string]$MsiPath,
    [string]$ExtraProps = "",
    [string]$TransformsRel = "",
    [int]$InstallLevel = 2
  )

  New-Item -ItemType Directory -Force -Path $Logs | Out-Null
  $log = Join-Path $Logs ("msi_" + (Get-Date -Format "yyyyMMdd_HHmmss") + "_" + (Split-Path $MsiPath -Leaf) + ".log")

  $parts = @(
    "/i `"$MsiPath`""
    "/qn"
    "/norestart"
    "INSTALLLEVEL=$InstallLevel"
    "/l*v `"$log`""
  )

  if ($TransformsRel) {
    $mstPath = $TransformsRel
    if (-not [System.IO.Path]::IsPathRooted($mstPath)) {
      $mstPath = Join-Path (Split-Path $MsiPath -Parent) $TransformsRel
    }
    if (-not (Test-Path -LiteralPath $mstPath)) {
      Warn "TRANSFORMS указан, но файл не найден: $mstPath"
    } else {
      $parts += ("TRANSFORMS=`"{0}`"" -f $mstPath)
    }
  }

  if ($ExtraProps) { $parts += $ExtraProps }

  $argLine = ($parts -join " ")
  Write-Host ("  -> msiexec.exe {0}" -f $argLine) -ForegroundColor DarkGray
  $p = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList $argLine -Wait -PassThru

  if ($p.ExitCode -in 0,3010,1641) {
    Ok ("  OK. Лог: {0}" -f $log)
    return [pscustomobject]@{ Ok=$true; ExitCode=$p.ExitCode; Log=$log }
  }

  Warn ("  MSI exit code {0}. Log: {1}" -f $p.ExitCode, $log)
  Show-MsiFailHint -LogPath $log
  return [pscustomobject]@{ Ok=$false; ExitCode=$p.ExitCode; Log=$log }
}

function Get-RuTransformRel([string]$DstFolder) {
  $mst1 = Join-Path $DstFolder "Languages\Setup\ru\ru.mst"
  $mst2 = Join-Path $DstFolder "languages\Setup\ru\ru.mst"
  if (Test-Path $mst1) { return "Languages\Setup\ru\ru.mst" }
  if (Test-Path $mst2) { return "languages\Setup\ru\ru.mst" }
  return ""
}

function Chunk-Array([string[]]$arr, [int]$size) {
  $chunks = @()
  if (-not $arr) { return $chunks }
  for ($i=0; $i -lt $arr.Count; $i += $size) {
    $end = [Math]::Min($i + $size - 1, $arr.Count - 1)
    $chunks += ,($arr[$i..$end])
  }
  return $chunks
}

function Install-AcfaWithFallback {
  param(
    [Parameter(Mandatory=$true)][string]$MsiPath,
    [Parameter(Mandatory=$true)][string[]]$Features,
    [string]$TransformRel = "",
    [int]$ChunkSize = 15
  )

  $core = @("base","axacfa_ru")
  $featuresU = @($Features | Where-Object { $_ } | Select-Object -Unique)
  $all = @($core + $featuresU) | Select-Object -Unique

  Write-Host ("ACFA ADDLOCAL будет: {0}" -f ($all -join ",")) -ForegroundColor Cyan

  $r = Install-Msi-Quiet -MsiPath $MsiPath -ExtraProps ('ADDLOCAL="{0}"' -f ($all -join ",")) -TransformsRel $TransformRel
  if ($r.Ok) { return }

  Warn "ACFA: полный список дал ошибку. Ставлю ядро и пробую чанками."

  $rCore = Install-Msi-Quiet -MsiPath $MsiPath -ExtraProps ('ADDLOCAL="{0}"' -f ($core -join ",")) -TransformsRel $TransformRel
  if (-not $rCore.Ok) { throw "ACFA: не удалось поставить даже ядро (base,axacfa_ru). Код $($rCore.ExitCode). Лог: $($rCore.Log)" }

  if (-not $featuresU -or $featuresU.Count -eq 0) { Ok "ACFA: ядро установлено (без модулей)."; return }

  $bad = New-Object System.Collections.Generic.List[string]
  $chunks = Chunk-Array -arr $featuresU -size $ChunkSize

  foreach ($ch in $chunks) {
    $list = (@($core + $ch) | Select-Object -Unique) -join ","
    $props  = ('ADDLOCAL="{0}" REINSTALL=ALL REINSTALLMODE=vomus' -f $list)
    $rCh = Install-Msi-Quiet -MsiPath $MsiPath -ExtraProps $props -TransformsRel $TransformRel
    if ($rCh.Ok) { continue }

    Warn ("ACFA: чанк упал (код {0}). Дроблю до одиночных: {1}" -f $rCh.ExitCode, ($ch -join ","))

    foreach ($one in $ch) {
      $list1 = (@($core + @($one)) | Select-Object -Unique) -join ","
      $props1 = ('ADDLOCAL="{0}" REINSTALL=ALL REINSTALLMODE=vomus' -f $list1)
      $rOne = Install-Msi-Quiet -MsiPath $MsiPath -ExtraProps $props1 -TransformsRel $TransformRel
      if (-not $rOne.Ok) { [void]$bad.Add($one) }
    }
  }

  if ($bad.Count -gt 0) {
    Warn "ACFA: некоторые модули не установились. Проблемные фичи:"
    foreach ($b in ($bad | Select-Object -Unique)) { Write-Host ("  - {0}" -f $b) -ForegroundColor Yellow }
    Warn "Смотри логи MSI: $Logs"
  } else {
    Ok "ACFA: установлено чанками."
  }
}

function Ensure-WebReport-SetupIniQuiet {
  param([Parameter(Mandatory=$true)][string]$DstFolder)

  $ini = Join-Path $DstFolder "setup.ini"

  if (-not (Test-Path $ini)) {
    @"
[Info]
Name=RSWT
Version=1.00.000
DiskSpace=8000

[Startup]
CmdLine=/quiet /norestart
"@ | Set-Content -LiteralPath $ini -Encoding ASCII
    Write-Info "web_report: setup.ini создан и настроен на /quiet"
    return
  }

  $txt = Get-Content -LiteralPath $ini -Raw -ErrorAction SilentlyContinue
  if (-not $txt) { $txt = "" }

  if ($txt -notmatch '(?im)^\s*\[Startup\]\s*$') {
    $txt = $txt.TrimEnd() + "`r`n`r`n[Startup]`r`n"
  }

  if ($txt -match '(?im)^\s*CmdLine\s*=.*$') {
    $txt = [regex]::Replace($txt, '(?im)^\s*CmdLine\s*=.*$', 'CmdLine=/quiet /norestart')
  } else {
    $txt = [regex]::Replace($txt, '(?im)^\s*\[Startup\]\s*$', "[Startup]`r`nCmdLine=/quiet /norestart")
  }

  Set-Content -LiteralPath $ini -Value $txt -Encoding ASCII
  Write-Info "web_report: setup.ini обновлён (CmdLine=/quiet /norestart)"
}

function Install-AddonFolder {
  param(
    [Parameter(Mandatory=$true)][string]$GroupName,
    [Parameter(Mandatory=$true)][string]$DstFolder,
    [string[]]$AcfaModules
  )

  $mstRel = Get-RuTransformRel -DstFolder $DstFolder

  $msi = Join-Path $DstFolder "Product.msi"
  $exe = Join-Path $DstFolder "setup.exe"
  if (Test-Path $msi) {
    if ($GroupName -ieq "web_report") {
      Write-Host ""
      Write-Host "WEB_REPORT: ставлю тихо и без подвисаний (IIS prereqs + MSI, fallback на setup.exe)" -ForegroundColor Yellow

      Ensure-WebReportPrereqs

      $mstRel = Get-RuTransformRel -DstFolder $DstFolder

      $r = Install-Msi-Quiet -MsiPath $msi -TransformsRel $mstRel
      if ($r.Ok) {
        Ok "WEB_REPORT: установлен тихо через MSI."
        return
      }

      Warn ("WEB_REPORT: MSI не поставился (код {0}). Пробую setup.exe в тихом режиме как fallback." -f $r.ExitCode)

      if (-not (Test-Path $exe)) { throw "WEB_REPORT: setup.exe не найден: $exe" }

      $stamp = Get-Date
      $log = Join-Path $Logs ("setup_" + (Get-Date -Format "yyyyMMdd_HHmmss") + "_web_report.log")

      $p = Start-Process -FilePath $exe -WorkingDirectory $DstFolder -ArgumentList "/quiet /norestart" -PassThru
      $finished = $true
      try {
        $finished = $p.WaitForExit(30 * 60 * 1000)
      } catch { $finished = $false }

      if (-not $finished) {
        try { $p.Kill() } catch {}
        throw "WEB_REPORT: setup.exe завис (30 мин) — процесс остановлен. Проверь prerequisites/логи в %TEMP%."
      }

      $ec = $p.ExitCode
      try {
        Set-Content -LiteralPath $log -Value ("setup.exe exit code: {0}" -f $ec) -Encoding UTF8
      } catch {}

      Write-Info ("WEB_REPORT: setup.exe exit code: {0}. Лог: {1}" -f $ec, $log)

      Wait-MsiSince -StartStamp $stamp -MaxMinutes 60

      if ($ec -in 0,3010,1641) {
        Ok "WEB_REPORT: установлен через setup.exe (тихо)."
        return
      }

      throw "WEB_REPORT: setup.exe завершился ошибкой. Код $ec. Лог: $log"
    }

    if ($GroupName -ieq "acfa") {
      if ($AcfaModules -and $AcfaModules.Count -gt 0) {
        Install-AcfaWithFallback -MsiPath $msi -Features $AcfaModules -TransformRel $mstRel
      } else {
        $r = Install-Msi-Quiet -MsiPath $msi -ExtraProps 'ADDLOCAL="base,axacfa_ru"' -TransformsRel $mstRel
        if (-not $r.Ok) { throw "ACFA (ядро) не установилось. Код $($r.ExitCode). Лог: $($r.Log)" }
      }
    }
    else {
      $r = Install-Msi-Quiet -MsiPath $msi -TransformsRel $mstRel
      if (-not $r.Ok) { throw "MSI аддона '$GroupName' завершился ошибкой. Код $($r.ExitCode). Лог: $($r.Log)" }
    }
    return
  }

  if (Test-Path $exe) {
    $log = Join-Path $Logs ("exe_" + (Get-Date -Format "yyyyMMdd_HHmmss") + "_" + (Split-Path $exe -Leaf) + ".log")
    $cands = @('/quiet /norestart','/silent','/S','/VERYSILENT')
    foreach ($c in $cands) {
      $ec = Start-Proc -FilePath $exe -Arguments $c -WorkingDirectory $DstFolder -LogPath $log
      if ($ec -in 0,3010,1641) { Ok ("EXE OK (ключ: {0}). Лог: {1}" -f $c, $log); return }
    }
    throw "Не удалось подобрать тихий ключ для setup.exe аддона $GroupName"
  }

  throw "В папке нет Product.msi и setup.exe: $DstFolder"
}

# ============================================================
#   УСТАНОВКА БАЗЫ (Server/Client/Admin) — единая функция через Mirror-ShareDir
# ============================================================

function Install-Intellect-Base-Unified {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('Server','Client','Admin')][string]$InstallType,
        [switch]$RemoveGuardant,
        [string]$SqlInstance = '(local)',
        [hashtable]$SqlSettings,
        [string]$InstallDir,
        [string]$CmdProps,
        [switch]$KeepCache
    )

    Write-Host ""
    Write-Host ("==== Установка Интеллекта: {0} ====" -f $InstallType) -ForegroundColor Yellow
    Write-Host ("[*] Guardant: {0}" -f $(if ($RemoveGuardant) { 'НЕТ (/REMOVE)' } else { 'ДА (без /REMOVE)' })) -ForegroundColor DarkGray

    $baseRel   = ($script:ShareRoot.TrimEnd('/') + '/base').TrimStart('/')
    $tmpRoot   = Join-Path $env:TEMP ("intellect_install_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
    $baseLocal = Join-Path $tmpRoot "base"
    New-Item -ItemType Directory -Force -Path $tmpRoot,$baseLocal | Out-Null

    $startStamp = Get-Date

    try {
        Write-Step ("Зеркалирую base целиком: /hash/{0}" -f $baseRel)
        Mirror-ShareDir -RelPath $baseRel -LocalRoot $baseLocal -ProgressId 20
        Write-Ok "base скачан"

        # Некоторые /hash возвращают только файлы верхнего уровня — докачиваем подпапки явно.
        # WORKAROUND: HTTP-listing-сервис на сервере не отдаёт подкаталоги в JSON
        # (например /hash/<base>/Redist/ возвращает {}), поэтому Mirror-ShareDir рекурсивно
        # не находит нужные prerequisites. Перечисляем все известные подпапки явно.
        # ПРИМЕЧАНИЕ: список нужно поддерживать в актуальном состоянии при изменениях
        # структуры на сервере. Когда listing-сервис починят - блок станет no-op.
        $extraDirs = @(
            "languages/Setup",
            "languages/Setup/ru",
            "languages/Setup/en",
            "Drivers",
            "Key",
            "Redist",
            "ipint.driverpack",
            # Каждая подпапка Redist отдельно - без этого setup.exe не находит VC++/.NET/SQL/...
            "Redist/Acrobat Reader",
            "Redist/CamMonitor",
            "Redist/Dotnet4.6",
            "Redist/Elasticsearch",
            "Redist/Fonts",
            "Redist/Java",
            "Redist/MSXML 40 SP2",
            "Redist/ReportViewer",
            "Redist/SQL Server Express",
            "Redist/VC2005_SP1",
            "Redist/VC2010_x64_Runtime",
            "Redist/VC2010_x86_Runtime",
            "Redist/VC2013",
            "Redist/VC2013/x64",
            "Redist/VC2013/x86",
            "Redist/VC2017",
            "Redist/VC2017/x64",
            "Redist/VC2017/x86"
        )
        foreach ($d in $extraDirs) {
            try {
                $relD = ($baseRel.TrimEnd('/') + '/' + $d).TrimStart('/')
                $locD = Join-Path $baseLocal ($d -replace '/', '\')
                Mirror-ShareDir -RelPath $relD -LocalRoot $locD -ProgressId 21
            } catch {}
        }

        Ensure-LanguagesSetup -DstFolder $baseLocal
        Fix-LanguagesCaseForWindows -BaseFolder $baseLocal

        $setupExe = Join-Path $baseLocal "setup.exe"
        if (-not (Test-Path $setupExe)) { throw "setup.exe не найден в base: $setupExe" }
        Write-Ok "setup.exe найден"

        # SQL подготовка только для Server
        if ($InstallType -eq 'Server') {
            $sqlFound = $null
            try { $sqlFound = Resolve-IntellectSqlInstance } catch { $sqlFound = $null }

            if (-not $sqlFound) {
                Write-Info "Server: SQL не найден — ставлю SQL Express (DEFAULT MSSQLSERVER) из Redist..."
                try { Ensure-SqlDefaultInstance -BaseDstFolder $baseLocal }
                catch { throw "Server: не удалось установить SQL Express. Причина: $($_.Exception.Message)" }
                $SqlInstance = '(local)'
            } else {
                $SqlInstance = $sqlFound
                try { Ensure-SqlServiceForInstance -SqlInstanceValue $SqlInstance } catch {}
            }

            try { Ensure-IntellectSqlRights -Server $SqlInstance }
            catch { Write-Warn ("Не удалось выдать SQL-права (продолжаю): {0}" -f $_.Exception.Message) }
        }

        # Базовый /CMD (либо из конфига, либо дефолт по документации)
        if ([string]::IsNullOrWhiteSpace($CmdProps)) {
            if ($InstallType -eq 'Server') {
                $CmdProps = 'CREATE_QUICKLAUNCH_SHORTCUT=\"1\" INSTALL_AS_SERVICE=\"1\"'
            } else {
                $CmdProps = 'CREATE_QUICKLAUNCH_SHORTCUT=\"1\"'
            }
        }

        # Дополнительные свойства /CMD по документации ITV.
        # Добавляем только если их ещё нет в $CmdProps (чтобы не перетереть значения из конфига).
        $extra = @()

        if ($InstallType -eq 'Server' -and $SqlSettings) {
            if ($CmdProps -notmatch 'SQL_INSTANCE\\?=')      { $extra += ('SQL_INSTANCE=\"{0}\"' -f $SqlSettings.Instance) }
            if ($CmdProps -notmatch 'SQL_AUTHTYPE\\?=')      { $extra += ('SQL_AUTHTYPE=\"{0}\"' -f $SqlSettings.AuthType) }
            if ($SqlSettings.AuthType -eq 'Sql') {
                if ($SqlSettings.Username -and $CmdProps -notmatch 'SQL_USERNAME\\?=') { $extra += ('SQL_USERNAME=\"{0}\"' -f $SqlSettings.Username) }
                if ($SqlSettings.Password -and $CmdProps -notmatch 'SQL_PASSWORD\\?=') { $extra += ('SQL_PASSWORD=\"{0}\"' -f $SqlSettings.Password) }
            }
            if ($CmdProps -notmatch 'DB_INTELLECT_NAME\\?=') { $extra += ('DB_INTELLECT_NAME=\"{0}\"' -f $SqlSettings.DbIntellectName) }
            if ($CmdProps -notmatch 'DB_TITLES_NAME\\?=')    { $extra += ('DB_TITLES_NAME=\"{0}\"' -f $SqlSettings.DbTitlesName) }
        }

        if ($InstallDir -and $InstallDir.Trim() -and ($CmdProps -notmatch 'INSTALLDIR\\?=')) {
            $extra += ('INSTALLDIR=\"{0}\"' -f $InstallDir)
        }

        if ($extra.Count -gt 0) {
            $CmdProps = ($CmdProps + ' ' + ($extra -join ' ')).Trim()
        }

        $argList = @(
            "/quiet",
            "/norestart",
            '/LANG="ru"',
            ('/INSTALLTYPE="{0}"' -f $InstallType)
        )
        if ($RemoveGuardant) {
            $argList += '/REMOVE="Acrobat Guardant_x86"'
        }
        $argList += "/CMD=`"$CmdProps`""

        Write-Host ""
        Write-Info "Команда установки:"
        Write-Host ("  {0} {1}" -f $setupExe, ($argList -join " ")) -ForegroundColor DarkGray
        Write-Host ""

        $startStamp = Get-Date
        Write-Step "Запуск установки..."
        $proc = Start-Process -FilePath $setupExe -WorkingDirectory $baseLocal -ArgumentList $argList -Wait -PassThru
        Write-Ok ("setup.exe завершился (код: {0})" -f $proc.ExitCode)

        Wait-MsiSince -StartStamp $startStamp -MaxMinutes 60

        Write-Step "Проверка установки..."
        $installedPath = Find-InstalledPath -PreferredInstallDir $InstallDir

        if ($InstallType -eq 'Client') {
            $root = $installedPath
            if (-not $root) {
                $root = "C:\Program Files (x86)\Интеллект"
                if (-not (Test-Path $root)) { $root = "C:\Program Files\Интеллект" }
            }
            $modules = @(
                (Join-Path $root "Modules"),
                (Join-Path $root "Modules64")
            ) | Where-Object { Test-Path $_ }

            $clientExe = $null
            if ($modules) {
                $clientExe = Get-ChildItem -LiteralPath $modules -Recurse -File -Filter *.exe -ErrorAction SilentlyContinue |
                    Where-Object { $_.Length -gt 2MB } |
                    Sort-Object Length -Descending |
                    Select-Object -First 1 -ExpandProperty FullName
            }

            if ($clientExe) {
                Write-Ok ("CLIENT установлен. Найден exe: {0}" -f $clientExe)
                Write-Ok ("Папка установки: {0}" -f $root)
            } else {
                Write-Warn "CLIENT: не нашёл *.exe в Modules/Modules64. Похоже на откат MSI."
                Write-Warn ("Оставляю кеш для диагностики: {0}" -f $tmpRoot)
                $KeepCache = $true
            }
        }
        else {
            if ($installedPath) {
                Write-Ok ("Похоже, установилось сюда: {0}" -f $installedPath)
            } else {
                Write-Warn "Не вижу папку установки. Оставляю кеш для диагностики."
                $KeepCache = $true
            }
        }

        if ($proc.ExitCode -notin 0,3010,1641) {
            Write-Warn "setup.exe вернул код $($proc.ExitCode). Смотри %TEMP% и журнал установщика."
        }
    }
    finally {
        if (-not $KeepCache) {
            Write-Step "Удаляю временную папку..."
            try { Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue; Write-Ok "Временная папка удалена: $tmpRoot" }
            catch { Write-Warn "Не смог удалить временную папку: $tmpRoot" }
        } else {
            Write-Warn "KeepCache включён — временная папка оставлена: $tmpRoot"
        }
    }

    Write-Host ""
    Write-Ok ("{0} — готово." -f $InstallType)
}

# ============================================================
#   УСТАНОВКА АДДОНОВ (автоматическая, без меню)
# ============================================================

function Install-AddonsFromConfig {
    param(
        [string[]]$Addons,
        [string[]]$AcfaModules
    )
    if (-not $Addons -or $Addons.Count -eq 0) { return }

    foreach ($group in $Addons) {
        Write-Host ""
        Write-Host ("==== Установка аддона: {0} ====" -f $group) -ForegroundColor Cyan

        $relDir    = ($script:ShareRoot.TrimEnd('/') + "/addons/" + $group).Trim('/')
        $dstFolder = Join-Path $Downloads ("addon_" + $group)

        if (Test-Path -LiteralPath $dstFolder) {
            try { Remove-Item -LiteralPath $dstFolder -Recurse -Force -ErrorAction Stop } catch {}
        }

        $installFailed = $false
        try {
            Write-Info ("Зеркалирую {0} ..." -f $relDir)
            Mirror-ShareDir -RelPath $relDir -LocalRoot $dstFolder -ProgressId 10
            Install-AddonFolder -GroupName $group -DstFolder $dstFolder -AcfaModules $AcfaModules
            Write-Ok ("Аддон '{0}' установлен." -f $group)
        }
        catch {
            $installFailed = $true
            Write-Warn ("Ошибка установки аддона '{0}': {1}" -f $group, $_.Exception.Message)
        }
        finally {
            if (Test-Path -LiteralPath $dstFolder) {
                if ($installFailed) {
                    Write-Warn ("Установочные файлы оставлены для диагностики: {0}" -f $dstFolder)
                } else {
                    try {
                        Remove-Item -LiteralPath $dstFolder -Recurse -Force -ErrorAction Stop
                        Write-Info ("Установочные файлы аддона удалены: {0}" -f $dstFolder)
                    } catch {
                        Write-Warn ("Не удалось удалить {0}: {1}" -f $dstFolder, $_.Exception.Message)
                    }
                }
            }
        }
    }
}

# ============================================================
#   ГЛАВНАЯ ЛОГИКА УСТАНОВКИ
# ============================================================

Write-Host "==== Установка Интеллекта (автоматический режим) ====" -ForegroundColor Yellow
Write-Host "Тип установки: $InstallType"
Write-Host "Конфиг: $ConfigFile"

# 1. Установка базы (единый путь для Server/Client/Admin)
if ($InstallType -notin @('Server','Client','Admin')) {
    throw "Неизвестный InstallType: $InstallType (ожидается Server | Client | Admin)"
}

Install-Intellect-Base-Unified `
    -InstallType $InstallType `
    -RemoveGuardant:$GuardantRemove `
    -SqlInstance $SqlSettings.Instance `
    -SqlSettings $SqlSettings `
    -InstallDir $InstallDir `
    -CmdProps $CmdProps `
    -KeepCache:$KeepCache

# 2. Установка аддонов (если указаны)
if ($AddonsList.Count -gt 0) {
    Install-AddonsFromConfig -Addons $AddonsList -AcfaModules $AcfaModules
}

Write-Host ""
Write-Host "Установка Интеллекта завершена." -ForegroundColor Green