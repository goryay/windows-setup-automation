<#
install_intellectx.ps1 — автоматическая установка Intellect X
Основан на install_intellectx_old.ps1, удалены интерактивные меню,
все параметры берутся из JSON-конфига.
Исправлено: возвращена предустановка PostgreSQL и VC++ с корректными параметрами.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigFile
)

$ErrorActionPreference = 'Stop'

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

# ---- Параметры из конфига ----
$BaseUrl   = $config.general.baseUrl
$WorkRoot  = if ($config.general.workRoot) { $config.general.workRoot } else { "$env:TEMP\intellectx_http" }
$KeepCache = if ($config.general.keepCache) { $true } else { $false }

$InstallType    = $config.installType        # ServerClient, Client, raftserver
$CmdProps       = if ($config.cmdProps) { $config.cmdProps } else { "" }
$AddonsList     = if ($config.addons) { @($config.addons) } else { @() }
$NoMirrorOpen   = $true   # не открывать проводник

# ---- /REMOVE: список компонентов для исключения ----
# По доке ITV допустимы: Acrobat, BaseProduct, IPDriverPack_x86, Guardant_amd64,
#   Postgres, dotnetfx35_x86, Redist2005_x86, Redist2010_x86, DetectorPack
# Новый формат: "removeComponents": ["Guardant_amd64", "Acrobat"]
# Старый формат (совместимость): "removeGuardant": true -> добавляет "Guardant_amd64"
$RemoveComponents = @()
if ($config.PSObject.Properties.Name -contains 'removeComponents' -and $config.removeComponents) {
    $RemoveComponents = @($config.removeComponents)
}
if ($config.PSObject.Properties.Name -contains 'removeGuardant' -and $config.removeGuardant) {
    if ($RemoveComponents -notcontains 'Guardant_amd64') {
        $RemoveComponents += 'Guardant_amd64'
    }
}

# ---- Подготовка URL ----
$BaseUrl = $BaseUrl.TrimEnd('/')
try { $u = [Uri]$BaseUrl } catch { throw "Invalid BaseUrl: $BaseUrl" }
$script:ServerRoot = "{0}://{1}:{2}" -f $u.Scheme, $u.Host, $u.Port
$script:ShareRoot  = $u.AbsolutePath.Trim('/')

# ---- Функция из оригинала для корректного пути к base ----
function Get-BaseRelPath {
    if ($script:ShareRoot -match '/base/?$') {
        return $script:ShareRoot
    } else {
        return ($script:ShareRoot.TrimEnd('/') + '/base')
    }
}

# ---- Рабочие папки ----
$Downloads = Join-Path $WorkRoot 'downloads'
$Logs      = Join-Path $WorkRoot 'logs'
New-Item -ItemType Directory -Force -Path $WorkRoot,$Downloads,$Logs | Out-Null

# ============================================================
#   ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ (полностью из оригинала)
# ============================================================

function Write-Info([string]$m){ Write-Host $m -ForegroundColor Cyan }
function Write-Warn([string]$m){ Write-Warning $m }
function Write-Ok  ([string]$m){ Write-Host $m -ForegroundColor Green }

# Удаление локальной папки после успешной установки.
# Подчиняется флагу keepCache в конфиге: если true — папка остаётся.
function Remove-DownloadFolder {
    param([string]$Path)
    if ($KeepCache) { return }
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path $Path)) { return }
    try {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        Write-Host ("  -> очищено: {0}" -f $Path) -ForegroundColor DarkGray
    } catch {
        Write-Warn ("Не удалось удалить '{0}': {1}" -f $Path, $_.Exception.Message)
    }
}

# Хардкод-таблица addons/ — используется как fallback на случай,
# если /hash отдал пусто или упал. Если на сервере появляется новый аддон,
# он автоматически подтянется через /hash без правки этого блока.
function Get-AddonsHardcoded {
    param([string]$Rel, [string]$ShareRootRel)

    $rel = $Rel.Trim('/')
    $sr  = $ShareRootRel.Trim('/')

    if ($rel -ieq "$sr/addons" -or $rel -ieq 'addons') {
        return @(
            [pscustomobject]@{ name = 'acfa';                 is_dir = $true },
            [pscustomobject]@{ name = 'face_recognition';     is_dir = $true },
            [pscustomobject]@{ name = 'iv_audioanalytics';    is_dir = $true },
            [pscustomobject]@{ name = 'neuro_pack';           is_dir = $true },
            [pscustomobject]@{ name = 'report';               is_dir = $true },
            [pscustomobject]@{ name = 'rr_lpr';               is_dir = $true },
            [pscustomobject]@{ name = 'rr_sdk';               is_dir = $true },
            [pscustomobject]@{ name = 'tva_crowd';            is_dir = $true },
            [pscustomobject]@{ name = 'vi';                   is_dir = $true },
            [pscustomobject]@{ name = 'vi_face_recongnition'; is_dir = $true },
            [pscustomobject]@{ name = 'vl_analytics';         is_dir = $true },
            [pscustomobject]@{ name = 'vl_face_recognition';  is_dir = $true },
            [pscustomobject]@{ name = 'vl_fight';             is_dir = $true },
            [pscustomobject]@{ name = 'vl_ppe';               is_dir = $true },
            [pscustomobject]@{ name = 'vl_sdk';               is_dir = $true },
            [pscustomobject]@{ name = 'vt_lpr';               is_dir = $true }
        )
    }

    $isSub = { param($sub) ($rel -ieq "$sr/addons/$sub" -or $rel -ieq "addons/$sub") }

    if (& $isSub 'acfa')                 { return @([pscustomobject]@{ name='ACFA-DriversPack-9.1.25-r-x64.msi'; is_dir=$false }) }
    if (& $isSub 'face_recognition')     { return @(
        [pscustomobject]@{ name='DetectorPack-Addon-Face-Recognition-Pack-3.14.1.184-x64.msi'; is_dir=$false },
        [pscustomobject]@{ name='media1.cab'; is_dir=$false },
        [pscustomobject]@{ name='media2.cab'; is_dir=$false },
        [pscustomobject]@{ name='media3.cab'; is_dir=$false }
    ) }
    if (& $isSub 'iv_audioanalytics')    { return @([pscustomobject]@{ name='DetectorPack-Addon-IV-AudioAnalytics-3.14.1.184-x64.msi'; is_dir=$false }) }
    if (& $isSub 'neuro_pack')           { return @(
        [pscustomobject]@{ name='DetectorPack-Addon-Neuro-Pack-3.14.1.184-x64.msi'; is_dir=$false },
        [pscustomobject]@{ name='media1.cab'; is_dir=$false },
        [pscustomobject]@{ name='media2.cab'; is_dir=$false },
        [pscustomobject]@{ name='media3.cab'; is_dir=$false },
        [pscustomobject]@{ name='media4.cab'; is_dir=$false }
    ) }
    if (& $isSub 'report')               { return @([pscustomobject]@{ name='Intellect X Reports-3.22.0(8)-x64.exe'; is_dir=$false }) }
    if (& $isSub 'rr_lpr')               { return @([pscustomobject]@{ name='DetectorPack-Addon-RR-LPR-3.14.1.184-x64.msi'; is_dir=$false }) }
    if (& $isSub 'rr_sdk')               { return @(
        [pscustomobject]@{ name='DetectorPack-Addon-RR-SDK-3.14.1.184-x64.msi'; is_dir=$false },
        [pscustomobject]@{ name='media1.cab'; is_dir=$false },
        [pscustomobject]@{ name='media2.cab'; is_dir=$false }
    ) }
    if (& $isSub 'tva_crowd')            { return @(
        [pscustomobject]@{ name='DetectorPack-Addon-TVA-Crowd-3.14.1.184-x64.msi'; is_dir=$false },
        [pscustomobject]@{ name='media1.cab'; is_dir=$false }
    ) }
    if (& $isSub 'vi')                   { return @(
        [pscustomobject]@{ name='DetectorPack-Addon-VI-3.14.1.184-x64.msi'; is_dir=$false },
        [pscustomobject]@{ name='media1.cab'; is_dir=$false },
        [pscustomobject]@{ name='media2.cab'; is_dir=$false },
        [pscustomobject]@{ name='media3.cab'; is_dir=$false }
    ) }
    if (& $isSub 'vi_face_recongnition') { return @(
        [pscustomobject]@{ name='DetectorPack-Addon-VI-Face-Recognition-3.14.1.184-x64.msi'; is_dir=$false },
        [pscustomobject]@{ name='media1.cab'; is_dir=$false },
        [pscustomobject]@{ name='media2.cab'; is_dir=$false },
        [pscustomobject]@{ name='media3.cab'; is_dir=$false }
    ) }
    if (& $isSub 'vl_analytics')         { return @([pscustomobject]@{ name='DetectorPack-Addon-VL-Analytics-3.14.1.184-x64.msi'; is_dir=$false }) }
    if (& $isSub 'vl_face_recognition')  { return @([pscustomobject]@{ name='DetectorPack-Addon-VL-Face-Recognition-3.14.1.184-x64.msi'; is_dir=$false }) }
    if (& $isSub 'vl_fight')             { return @([pscustomobject]@{ name='DetectorPack-Addon-VL-Fight-3.14.1.184-x64.msi'; is_dir=$false }) }
    if (& $isSub 'vl_ppe')               { return @([pscustomobject]@{ name='DetectorPack-Addon-VL-PPE-3.14.1.184-x64.msi'; is_dir=$false }) }
    if (& $isSub 'vl_sdk')               { return @(
        [pscustomobject]@{ name='DetectorPack-Addon-VL-SDK-3.14.1.184-x64.msi'; is_dir=$false },
        [pscustomobject]@{ name='media1.cab'; is_dir=$false },
        [pscustomobject]@{ name='media2.cab'; is_dir=$false },
        [pscustomobject]@{ name='media3.cab'; is_dir=$false }
    ) }
    if (& $isSub 'vt_lpr')               { return @([pscustomobject]@{ name='DetectorPack-Addon-VT-LPR-3.14.1.184-x64.msi'; is_dir=$false }) }

    return @()
}

# Если /hash для addons-пути отдал пусто — берём данные из хардкод-таблицы.
function Apply-AddonsFallback {
    param($Result, [string]$Rel, [string]$ShareRootRel)
    if ((-not $Result -or $Result.Count -eq 0) -and ($Rel -match '(?i)(^|/)addons(/|$)')) {
        return (Get-AddonsHardcoded -Rel $Rel -ShareRootRel $ShareRootRel)
    }
    return $Result
}

# ---- Get-ShareEntries: сначала /hash, при пустом ответе для addons — fallback ----
function Get-ShareEntries {
    param([Parameter(Mandatory=$true)][string]$RelPath)

    $rel = $RelPath.Trim('/')
    $sr  = $script:ShareRoot.Trim('/')

    if ([string]::IsNullOrWhiteSpace($rel)) {
        $url = "$($script:ServerRoot)/hash"
    } else {
        $url = "$($script:ServerRoot)/hash/$rel"
    }

    $json = $null
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop
        $json = $resp.Content | ConvertFrom-Json
    } catch {
        Write-Warn "Не удалось получить ${url}: $($_.Exception.Message)"
        $json = $null
    }

    if ($null -eq $json) {
        if ($rel -match '(?i)(^|/)addons(/|$)') {
            return (Get-AddonsHardcoded -Rel $rel -ShareRootRel $sr)
        }
        return @()
    }

    $result = New-Object System.Collections.Generic.List[object]

    # массив объектов/строк
    if ($json -is [System.Collections.IEnumerable] -and -not ($json -is [string])) {
        foreach ($e in $json) {
            if ($null -eq $e) { continue }

            if ($e.PSObject -and $e.PSObject.Properties.Name -contains 'name') {
                $name = $e.name
                if (-not $name) { continue }

                $isDir = $false
                if     ($e.PSObject.Properties.Name -contains 'is_dir') { $isDir = [bool]$e.is_dir }
                elseif ($e.PSObject.Properties.Name -contains 'dir')    { $isDir = [bool]$e.dir }
                elseif ($e.PSObject.Properties.Name -contains 'type')   { $isDir = ($e.type -eq 'dir') }

                $result.Add([pscustomobject]@{ name = $name; is_dir = $isDir }) | Out-Null
                continue
            }

            if ($e -is [string]) {
                $result.Add([pscustomobject]@{ name = $e; is_dir = $false }) | Out-Null
            }
        }
        return (Apply-AddonsFallback $result $rel $sr)
    }

    # объект с полем entries / files
    if ($json.PSObject) {
        $names = $json.PSObject.Properties.Name

        if ($names -contains 'entries') {
            foreach ($e in $json.entries) {
                if ($null -eq $e) { continue }
                if ($e.PSObject -and $e.PSObject.Properties.Name -contains 'name') {
                    $name = $e.name
                    if (-not $name) { continue }

                    $isDir = $false
                    if     ($e.PSObject.Properties.Name -contains 'is_dir') { $isDir = [bool]$e.is_dir }
                    elseif ($e.PSObject.Properties.Name -contains 'dir')    { $isDir = [bool]$e.dir }
                    elseif ($e.PSObject.Properties.Name -contains 'type')   { $isDir = ($e.type -eq 'dir') }

                    $result.Add([pscustomobject]@{ name = $name; is_dir = $isDir }) | Out-Null
                }
            }
            return (Apply-AddonsFallback $result $rel $sr)
        }

        if ($names -contains 'files') {
            foreach ($e in $json.files) {
                if ($null -eq $e) { continue }
                if ($e.PSObject -and $e.PSObject.Properties.Name -contains 'name') {
                    $name = $e.name
                    if (-not $name) { continue }

                    $isDir = $false
                    if     ($e.PSObject.Properties.Name -contains 'is_dir') { $isDir = [bool]$e.is_dir }
                    elseif ($e.PSObject.Properties.Name -contains 'dir')    { $isDir = [bool]$e.dir }
                    elseif ($e.PSObject.Properties.Name -contains 'type')   { $isDir = ($e.type -eq 'dir') }

                    $result.Add([pscustomobject]@{ name = $name; is_dir = $isDir }) | Out-Null
                }
            }
            return (Apply-AddonsFallback $result $rel $sr)
        }

        # объект-словарь: поля = имена
        foreach ($p in $json.PSObject.Properties) {
            $name = $p.Name
            if (-not $name) { continue }
            $val = $p.Value
            $isDir = $false
            if ($val -and $val.PSObject) {
                if     ($val.PSObject.Properties.Name -contains 'is_dir') { $isDir = [bool]$val.is_dir }
                elseif ($val.PSObject.Properties.Name -contains 'dir')    { $isDir = [bool]$val.dir }
                elseif ($val.PSObject.Properties.Name -contains 'type')   { $isDir = ($val.type -eq 'dir') }
            }
            $result.Add([pscustomobject]@{ name = $name; is_dir = $isDir }) | Out-Null
        }
        return (Apply-AddonsFallback $result $rel $sr)
    }

    return (Apply-AddonsFallback $result $rel $sr)
}

# ---- Get-DlUrl ----
function Get-DlUrl {
    param([Parameter(Mandatory=$true)][string]$RelPath)
    $rel = $RelPath.Trim('/')
    if ([string]::IsNullOrWhiteSpace($rel)) {
        throw "Get-DlUrl: пустой RelPath"
    }
    return "$($script:ServerRoot)/dl/$rel"
}

# ---- Mirror-ShareDir ----
function Mirror-ShareDir {
    param(
        [Parameter(Mandatory=$true)][string]$RelPath,
        [Parameter(Mandatory=$true)][string]$LocalRoot,
        [int]$ProgressId = 0
    )

    $rootRel = $RelPath.Trim('/')
    New-Item -ItemType Directory -Force -Path $LocalRoot | Out-Null

    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@{ rel = $rootRel; local = $LocalRoot })

    $processed = 0

    while ($queue.Count -gt 0) {
        $item  = $queue.Dequeue()
        $rel   = $item.rel
        $local = $item.local

        try {
            $entries = Get-ShareEntries -RelPath $rel
        } catch {
            Write-Warn "Не удалось получить /hash/${rel}: $($_.Exception.Message)"
            continue
        }

        foreach ($e in $entries) {
            $name = $e.name
            if (-not $name) { continue }

            if ($e.is_dir) {
                $subRel   = ($rel.TrimEnd('/') + "/" + $name)
                $subLocal = Join-Path $local $name
                New-Item -ItemType Directory -Force -Path $subLocal | Out-Null
                $queue.Enqueue(@{ rel = $subRel; local = $subLocal })
            } else {
                $relFile = ($rel.TrimEnd('/') + "/" + $name).Trim('/')
                $url     = Get-DlUrl -RelPath $relFile
                $dst     = Join-Path $local $name

                if (Test-Path $dst) { continue }

                $processed++
                if ($ProgressId -gt 0) {
                    $pct = [Math]::Min(99, [int]($processed * 100 / ($processed + 5)))
                    Write-Progress -Id $ProgressId -Activity "Зеркалирование дистрибутива" -Status "$relFile" -PercentComplete $pct
                }

                try {
                    Invoke-WebRequest -Uri $url -UseBasicParsing -OutFile $dst -ErrorAction Stop
                } catch {
                    Write-Warn "Ошибка скачивания ${url}: $($_.Exception.Message)"
                }
            }
        }
    }

    if ($ProgressId -gt 0) {
        Write-Progress -Id $ProgressId -Activity "Зеркалирование дистрибутива" -Completed
    }
}

# ---- Find-FirstShareFile ----
function Find-FirstShareFile {
    param(
        [Parameter(Mandatory=$true)][string]$RootRel,
        [Parameter(Mandatory=$true)][string]$RegexPattern,
        [int]$MaxDepth = 8
    )

    $rootRelNorm = $RootRel.Trim('/')

    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $queue   = New-Object System.Collections.Queue
    $queue.Enqueue(@{ rel = $rootRelNorm; depth = 0 })

    while ($queue.Count -gt 0) {
        $item  = $queue.Dequeue()
        $rel   = $item.rel
        $depth = $item.depth

        if ($visited.Contains($rel)) { continue }
        $visited.Add($rel) | Out-Null

        try {
            $entries = Get-ShareEntries -RelPath $rel
        } catch {
            Write-Warn "Не удалось прочитать /hash/${rel}: $($_.Exception.Message)"
            continue
        }

        foreach ($e in $entries) {
            $name = $e.name
            if (-not $name) { continue }

            if ($e.is_dir) {
                if ($depth -lt $MaxDepth) {
                    $subRel = ($rel.TrimEnd('/') + "/" + $name)
                    $queue.Enqueue(@{ rel = $subRel; depth = $depth + 1 })
                }
            } else {
                if ($name -match $RegexPattern) {
                    $fullRel = ($rel.TrimEnd('/') + "/" + $name).Trim('/')
                    return [pscustomobject]@{
                        Name     = $name
                        RelDir   = $rel
                        RelPath  = $fullRel
                    }
                }
            }
        }
    }

    return $null
}

# ---- Start-Proc ----
function Start-Proc([string]$FilePath,[string]$Arguments,[string]$LogPath,[string]$WorkingDirectory){
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    if($WorkingDirectory){ $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $null = $p.Start()
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    if($LogPath){
        $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        @(
            "=== $ts ===",
            "File: $FilePath",
            "Args: $Arguments",
            "WD:   $WorkingDirectory",
            "Exit: $($p.ExitCode)",
            "--- STDOUT ---",
            $out,
            "--- STDERR ---",
            $err
        ) | Out-File -FilePath $LogPath -Encoding UTF8 -Append
    }
    $p.ExitCode
}

# ---- Wait-RedistExit ----
function Wait-RedistExit {
    param([int]$TimeoutSec = 3600)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $appeared = $false
    while((Get-Date) -lt $deadline){
        $p = Get-Process -Name 'Redist' -ErrorAction SilentlyContinue
        if($p){ $appeared = $true; break }
        Start-Sleep -Seconds 2
    }
    if($appeared){
        while((Get-Date) -lt $deadline){
            $p = Get-Process -Name 'Redist' -ErrorAction SilentlyContinue
            if(-not $p){ break }
            Start-Sleep -Seconds 2
        }
    }
}

# ---- Install-MSI-Quiet ----
function Install-MSI-Quiet {
    param(
        [string]$Path,
        [string]$LogDir,
        [int]$ProgressId = 0,
        [string]$Activity = "Установка MSI",
        [string]$StatusPrefix = "Установка пакета",
        [switch]$UseUi,
        [string]$ExtraProps = "",
        # UI режим msiexec. По умолчанию определяется по -UseUi (full/qn).
        # Для аддонов с битыми CA, которым нужен InstallUISequence (типа
        # 'Выберите язык установки', Intellect X Reports Wizard) - используй '/qb!'
        # (progress bar без модальных диалогов и кнопки Cancel).
        [ValidateSet('','/qn','/qb','/qb!','/qb-!','/passive')]
        [string]$UiMode = ''
    )

    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $log = Join-Path $LogDir ("msi_" + (Get-Date -Format "yyyyMMdd_HHmmss") + "_" + (Split-Path $Path -Leaf) + ".log")
    Write-Host ("  -> MSI: {0}" -f (Split-Path $Path -Leaf)) -ForegroundColor Cyan

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "$env:SystemRoot\System32\msiexec.exe"

    # Определение UI-флага:
    #   1. Если UiMode задан явно - используем его (приоритет).
    #   2. Иначе по -UseUi: switch true = full UI (нет флага), false = /qn (legacy).
    $effectiveUi = ''
    if (-not [string]::IsNullOrWhiteSpace($UiMode)) {
        $effectiveUi = $UiMode
    } elseif (-not $UseUi) {
        $effectiveUi = '/qn'
    }

    $argsList = @("/i `"$Path`"")
    if ($effectiveUi) { $argsList += $effectiveUi }
    $argsList += "/norestart"
    $argsList += "/l*v `"$log`""
    if ($ExtraProps) { $argsList += $ExtraProps }

    $psi.Arguments = $argsList -join ' '

    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $null = $p.Start()

    if ($ProgressId -gt 0) {
        $percent = 80
        while (-not $p.HasExited) {
            $percent = [math]::Min(99, $percent + 1)
            Write-Progress -Id $ProgressId -Activity $Activity -Status ("{0}: {1}" -f $StatusPrefix, (Split-Path $Path -Leaf)) -PercentComplete $percent
            Start-Sleep -Milliseconds 700
        }
    } else {
        $p.WaitForExit()
    }

    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()

    if ($LogDir) {
        $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        @(
            "=== $ts ===",
            "File: msiexec.exe",
            "Args: $($psi.Arguments)",
            "Exit: $($p.ExitCode)",
            "--- STDOUT ---",
            $out,
            "--- STDERR ---",
            $err
        ) | Out-File -FilePath $log -Encoding UTF8 -Append
    }

    if ($p.ExitCode -notin 0,3010,1641) {
        throw "MSI exit code $($p.ExitCode). Log: $log"
    }
}

# ---- Install-Any ----
function Install-Any {
    param([string]$Path,[switch]$Silent,[string]$LogDir,[string]$WorkingDir)
    $ext  = [IO.Path]::GetExtension($Path)
    $name = [IO.Path]::GetFileName($Path)
    if ($ext -ieq '.msi') {
        if ($Silent) {
            Install-MSI-Quiet -Path $Path -LogDir $LogDir
        } else {
            Start-Process "$env:SystemRoot\System32\msiexec.exe" -ArgumentList "/i `"$Path`"" -WorkingDirectory $WorkingDir
        }
        return
    }
    if ($ext -ieq '.exe') {
        New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
        $log = Join-Path $LogDir ("exe_" + (Get-Date -Format "yyyyMMdd_HHmmss") + "_" + $name + ".log")
        if ($Silent) {
            $candidates = @(
                '--silent',
                '--quiet',
                '--unattended',
                '--mode unattended --unattendedmodeui none',
                '--unattendedmodeui none',
                '/S','/silent','/VERYSILENT','/quiet /norestart','/qn /norestart'
            )
            foreach ($k in $candidates) {
                try {
                    $ec = Start-Proc -FilePath $Path -Arguments $k -LogPath $log -WorkingDirectory $WorkingDir
                    if ($ec -in 0,3010,1641) { return }
                } catch {}
            }
        }
        Start-Process -FilePath $Path -WorkingDirectory $WorkingDir -Wait | Out-Null
        return
    }
    Write-Warning "Неизвестный тип файла: $name — пропуск."
}

# ---- Is-GuardantMsi ----
function Is-GuardantMsi {
    param([string]$Path)
    $leaf = [IO.Path]::GetFileName($Path)
    return ($leaf -match '(?i)^GrdDrivers\.msi$')
}

# ---- Close-ExplorerForPath ----
function Close-ExplorerForPath {
    param([string]$Path)
    try {
        $full = (Resolve-Path $Path -ErrorAction Stop).ProviderPath
    } catch { return }

    try {
        $shell = New-Object -ComObject Shell.Application
    } catch { return }

    foreach ($w in $shell.Windows()) {
        try {
            $loc = $w.Document.Folder.Self.Path
            if ([string]::IsNullOrWhiteSpace($loc)) { continue }
            if ($loc.TrimEnd('\') -ieq $full.TrimEnd('\')) {
                $w.Quit()
            }
        } catch { }
    }
}

# ---- Test-IntellectXInstalled (проверка по реестру) ----
function Test-IntellectXInstalled {
    try {
        $apps = Get-InstalledApps
    } catch {
        return $false
    }

    $hit = $apps | Where-Object {
        $n = $_.DisplayName
        if ([string]::IsNullOrWhiteSpace($n)) { return $false }
        return ($n -match '(?i)^\s*Intellect\s*X\b' -or $n -match '(?i)^\s*IntellectX\b')
    } | Select-Object -First 1

    return [bool]$hit
}

# ---- Test-PostgresInstalled (проверка наличия ITV PostgreSQL) ----
function Test-PostgresInstalled {
    try { $apps = Get-InstalledApps } catch { return $false }
    $hit = $apps | Where-Object {
        $_.DisplayName -match '(?i)\bPostgreSQL\b' -and
        $_.Publisher   -match '(?i)\bITV\b'
    } | Select-Object -First 1
    return [bool]$hit
}

# ---- Install-AllVcRedist (ставит все VC++ Redistributable из base/Redist) ----
function Install-AllVcRedist {
    param([string]$BaseLocalDir, [string]$BaseRel)

    $vcDirs = @('VC2008','VC2010','VC2013','VC2015-VC2022')

    foreach ($vc in $vcDirs) {
        $localDir = Join-Path $BaseLocalDir "Redist\$vc\x64"
        # Имя файла зависит от версии: VC2015-VC2022 = vc_redist.x64.exe, остальные = vcredist_x64.exe
        $exeName  = if ($vc -eq 'VC2015-VC2022') { 'vc_redist.x64.exe' } else { 'vcredist_x64.exe' }
        $localFile = Join-Path $localDir $exeName

        if (-not (Test-Path $localFile)) {
            $url = "$($script:ServerRoot)/dl/$($BaseRel.Trim('/'))/Redist/$vc/x64/$exeName"
            Write-Host "$vc не найден, скачиваю..." -ForegroundColor DarkGray
            New-Item -ItemType Directory -Force -Path $localDir | Out-Null
            try {
                Invoke-WebRequest -Uri $url -OutFile $localFile -UseBasicParsing -ErrorAction Stop
            } catch {
                Write-Warn ("Не удалось скачать {0}: {1}" -f $vc, $_.Exception.Message)
                continue
            }
        }

        if (Test-Path $localFile) {
            Write-Host ("Устанавливаю {0} ..." -f $vc) -ForegroundColor Yellow
            $p = Start-Process -FilePath $localFile -ArgumentList "/install /quiet /norestart" -Wait -PassThru
            # Коды 0 (OK), 3010 (reboot required), 1638 (already installed/newer)
            if ($p.ExitCode -in 0,3010,1638) {
                Write-Ok ("  {0}: OK (код {1})" -f $vc, $p.ExitCode)
            } else {
                Write-Warn ("  {0}: код {1}" -f $vc, $p.ExitCode)
            }
        }
    }
}

# ---- Get-InstalledApps (из оригинала) ----
function Get-InstalledApps {
    $roots = @(
        @{ Hive='HKLM'; Path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' },
        @{ Hive='HKLM'; Path='HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' }
    )
    $apps = New-Object System.Collections.Generic.List[object]

    foreach ($r in $roots) {
        if (-not (Test-Path $r.Path)) { continue }

        Get-ChildItem $r.Path | ForEach-Object {
            $p = Get-ItemProperty $_.PsPath -ErrorAction SilentlyContinue
            if (-not $p) { return }

            $dn = $p.DisplayName
            if ([string]::IsNullOrWhiteSpace($dn)) { return }

            [void]$apps.Add([pscustomobject]@{
                Hive                 = $r.Hive
                RegPath              = $_.PsPath
                Key                  = $_.PsChildName
                DisplayName          = $dn
                DisplayVersion       = $p.DisplayVersion
                UninstallString      = $p.UninstallString
                QuietUninstallString = $p.QuietUninstallString
                Publisher            = $p.Publisher
                InstallLocation      = $p.InstallLocation
            })
        }
    }
    $apps
}

# ---- Install-CoreDetectorAndDrivers ----
function Install-CoreDetectorAndDrivers {
    param(
        [string]$InstallType,
        [string[]]$RemoveList = @()
    )

    # Если пользователь явно исключил DetectorPack через /REMOVE — не ставим.
    if ($RemoveList -contains 'DetectorPack') {
        Write-Host ""
        Write-Host "DetectorPack исключён через /REMOVE — пропускаю установку base_detector." -ForegroundColor DarkGray
        return
    }

    Write-Host ""
    Write-Host "==== Установка DetectorPack / DriversPack ====" -ForegroundColor Yellow

    $detRel = ($script:ShareRoot.TrimEnd('/') + '/base_detector')
    Write-Host ("Каталог base_detector (SHARE_DIR): {0}" -f $detRel) -ForegroundColor DarkGray

    $localRoot = Join-Path $Downloads 'base_detector'
    Mirror-ShareDir -RelPath $detRel -LocalRoot $localRoot

    if (-not (Test-Path $localRoot)) {
        Write-Warning "После зеркалирования нет локальной папки base_detector: $localRoot"
        return
    }

    $detMsi = Get-ChildItem -Path $localRoot -Filter '*.msi' -Recurse -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -match '(?i)DetectorPack.*\.msi' } |
              Select-Object -First 1

    $drvMsi = Get-ChildItem -Path $localRoot -Filter '*.msi' -Recurse -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -match '(?i)DriversPack.*\.msi' } |
              Select-Object -First 1

    if (-not $detMsi -and -not $drvMsi) {
        Write-Warning "В base_detector не найдено MSI DetectorPack/DriversPack."
        return
    }

    if ($detMsi) {
        Write-Host ""
        Write-Host ("Устанавливаю DetectorPack: {0}" -f $detMsi.Name) -ForegroundColor Yellow
        Install-MSI-Quiet -Path $detMsi.FullName -LogDir $Logs -ProgressId 40 -Activity "Установка DetectorPack" -StatusPrefix "DetectorPack" -UseUi:$false
        Write-Ok "DetectorPack установлен."
    } else {
        Write-Warning "DetectorPack MSI не найден в $localRoot"
    }

    if ($drvMsi) {
        Write-Host ""
        Write-Host ("Устанавливаю DriversPack: {0}" -f $drvMsi.Name) -ForegroundColor Yellow
        Install-MSI-Quiet -Path $drvMsi.FullName -LogDir $Logs -ProgressId 41 -Activity "Установка DriversPack" -StatusPrefix "DriversPack" -UseUi:$false
        Write-Ok "DriversPack установлен."
    } else {
        Write-Warning "DriversPack MSI не найден в $localRoot"
    }

    Remove-DownloadFolder -Path $localRoot
}

# ============================================================
#   УСТАНОВКА БАЗЫ (с предварительной установкой PostgreSQL и VC++)
# ============================================================

function Install-IntellectX-BaseAuto {
    param(
        [string]$InstallType,
        [string[]]$RemoveList = @(),
        [string]$CmdProps
    )

    $progressId = 1
    Write-Progress -Id $progressId -Activity "Установка Intellect X (база)" -Status "Подготовка" -PercentComplete 0

    Write-Host ""
    Write-Host "==== Установка Intellect X (база, тихий режим) ====" -ForegroundColor Yellow

    $baseRel = Get-BaseRelPath
    Write-Host ("Корень SHARE_DIR: {0}" -f $script:ShareRoot)   -ForegroundColor DarkGray
    Write-Host ("Каталог base:     {0}" -f $baseRel)           -ForegroundColor DarkGray
    Write-Host ("Сервер:           {0}" -f $script:ServerRoot) -ForegroundColor DarkGray

    $hadBefore = $false
    try { $hadBefore = Test-IntellectXInstalled } catch { $hadBefore = $false }

    $dstFolder   = Join-Path $Downloads 'base_full'
    $setupPath   = Join-Path $dstFolder 'setup.exe'
    $productPath = Join-Path $dstFolder 'Product.msi'

    Write-Progress -Id $progressId -Activity "Установка Intellect X (база)" -Status "Зеркалирование base/" -PercentComplete 10
    Mirror-ShareDir -RelPath $baseRel -LocalRoot $dstFolder -ProgressId $progressId

    if (-not (Test-Path $setupPath)) {
        Write-Progress -Id $progressId -Activity "Установка Intellect X (база)" -Completed
        throw "После зеркалирования не найден setup.exe в '$setupPath'."
    }

    # ===== 1. Visual C++ Redistributable (все 4 версии: 2008/2010/2013/2015-2022) =====
    Write-Host ""
    Write-Host "Проверка и установка VC++ Redistributable..." -ForegroundColor Yellow
    Install-AllVcRedist -BaseLocalDir $dstFolder -BaseRel $baseRel

    # ===== 2. PostgreSQL (только если не установлен ITV-вариант) =====
    if (Test-PostgresInstalled) {
        Write-Ok "PostgreSQL (ITV) уже установлен — пропускаю."
    } else {
        $pgInstallerPath = Join-Path $dstFolder 'Redist\PostgreSQL\PostgresInstaller.msi'

        # Если MSI нет в зеркале — пытаемся скачать с сервера
        if (-not (Test-Path $pgInstallerPath)) {
            $pgRelPath   = "Redist/PostgreSQL/PostgresInstaller.msi"
            $pgLocalDir  = Join-Path $dstFolder "Redist\PostgreSQL"
            $pgLocalFile = Join-Path $pgLocalDir "PostgresInstaller.msi"
            $pgUrl = "$($script:ServerRoot)/dl/$($baseRel.Trim('/'))/$pgRelPath"
            Write-Warning "PostgresInstaller.msi отсутствует в base_full — пробую скачать вручную."
            if (-not (Test-Path $pgLocalDir)) {
                New-Item -Path $pgLocalDir -ItemType Directory -Force | Out-Null
            }
            try {
                Invoke-WebRequest -Uri $pgUrl -OutFile $pgLocalFile -UseBasicParsing -ErrorAction Stop
                Write-Host "PostgresInstaller.msi скачан в $pgLocalFile" -ForegroundColor Green
                $pgInstallerPath = $pgLocalFile
            } catch {
                Write-Warning "Не удалось скачать PostgreSQL: $($_.Exception.Message)"
            }
        }

        if (Test-Path $pgInstallerPath) {
            Write-Host "Устанавливаю PostgreSQL (IntellectX версия)..." -ForegroundColor Yellow
            $pgInstallLog = Join-Path $Logs "postgres_install_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
            $pgArgs = @(
                "/i `"$pgInstallerPath`"",
                "/qn",
                "/norestart",
                "/l*v `"$pgInstallLog`""
            )
            $proc = Start-Process msiexec.exe -ArgumentList $pgArgs -Wait -NoNewWindow -PassThru
            if ($proc.ExitCode -in 0,3010,1638) {
                Write-Ok "PostgreSQL установлен/обновлён."
            } else {
                Write-Warning "PostgreSQL вернул код $($proc.ExitCode). Лог: $pgInstallLog"
                Write-Warning "Продолжаем, но установка Intellect X скорее всего упадёт."
            }
        } else {
            Write-Warning "PostgresInstaller.msi не найден. Установка Intellect X, скорее всего, не удастся."
        }
    }

    # ===== 3. Запуск setup.exe Intellect X =====
    Write-Host ""
    Write-Host "Формирование параметров запуска setup.exe..." -ForegroundColor Yellow

    $setupArgs = @(
        '/quiet',
        '/norestart',
        '/debug',
        ("/INSTALLTYPE=""{0}""" -f $InstallType)
    )
    if ($RemoveList -and $RemoveList.Count -gt 0) {
        $setupArgs += ('/REMOVE="{0}"' -f ($RemoveList -join ','))
    }
    if (-not [string]::IsNullOrWhiteSpace($CmdProps)) {
        $escapedCmdProps = $CmdProps -replace '"', '\"'
        $setupArgs += ("/CMD=""{0}""" -f $escapedCmdProps)
    }

    $arguments = ($setupArgs -join ' ')
    $exeLog = Join-Path $Logs ("exe_{0}_setup.exe.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

    Write-Host ""
    Write-Host "Запускаю ТИХУЮ установку (setup.exe)..." -ForegroundColor Yellow
    Write-Host "==> $setupPath $arguments" -ForegroundColor DarkGray

    Write-Progress -Id $progressId -Activity "Установка Intellect X (база)" -Status "Запуск setup.exe" -PercentComplete 60
    $code = Start-Proc -FilePath $setupPath -Arguments $arguments -LogPath $exeLog -WorkingDirectory $dstFolder

    Write-Progress -Id $progressId -Activity "Установка Intellect X (база)" -Status "Ожидание Redist.exe" -PercentComplete 80
    Wait-RedistExit -TimeoutSec 3600

    $hasAfter = $false
    try { $hasAfter = Test-IntellectXInstalled } catch { $hasAfter = $false }

    if ($hasAfter) {
        if (-not $hadBefore) {
            Write-Ok "Готово. Intellect X установлен (после setup.exe)."
        } else {
            Write-Ok "Intellect X уже был установлен, выполнено обновление/повторная установка (после setup.exe)."
        }
        Write-Ok "Лог setup.exe: $exeLog"

        Install-CoreDetectorAndDrivers -InstallType $InstallType -RemoveList $RemoveList

        if (-not $NoMirrorOpen) {
            Close-ExplorerForPath -Path $dstFolder
        }
        Remove-DownloadFolder -Path $dstFolder
        Write-Progress -Id $progressId -Activity "Установка Intellect X (база)" -Status "Завершено" -PercentComplete 100
        return
    }

    # Fallback: Product.msi
    if (-not (Test-Path $productPath)) {
        Write-Warn "setup.exe вернул код $code, и Intellect X не обнаружен."
        Write-Warn "Product.msi в '$dstFolder' не найден — fallback невозможен."
        Write-Warn "Смотри лог setup.exe: $exeLog"
        if (-not $NoMirrorOpen) {
            Close-ExplorerForPath -Path $dstFolder
        }
        Write-Progress -Id $progressId -Activity "Установка Intellect X (база)" -Status "Завершено (без установки)" -PercentComplete 100
        return
    }

    Write-Warn "После setup.exe Intellect X не найден. Пробую прямую установку Product.msi..."

    $msiLog = Join-Path $Logs ("msi_{0}_Product.msi.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $msiArgs = @(
        "/i `"$productPath`"",
        "/qn",
        "/norestart",
        "/l*v `"$msiLog`"",
        "INSTALLTYPE=$InstallType"
    )
    if ($RemoveList -and $RemoveList.Count -gt 0) {
        $msiArgs += ('REMOVE={0}' -f ($RemoveList -join ','))
    }
    if (-not [string]::IsNullOrWhiteSpace($CmdProps)) {
        $msiArgs += $CmdProps
    }

    $msiCmd = $msiArgs -join ' '
    Write-Host "msiexec.exe $msiCmd" -ForegroundColor DarkGray

    $msiCode = Start-Proc -FilePath "$env:SystemRoot\System32\msiexec.exe" -Arguments $msiCmd -LogPath $msiLog -WorkingDirectory $dstFolder

    $hasAfterMsi = $false
    try { $hasAfterMsi = Test-IntellectXInstalled } catch { $hasAfterMsi = $false }

    if ($hasAfterMsi) {
        if (-not $hadBefore) {
            Write-Ok "Готово. Intellect X установлен (через Product.msi)."
        } else {
            Write-Ok "Intellect X уже был установлен, выполнено обновление/повторная установка (через Product.msi)."
        }
        Write-Ok "Логи:"
        Write-Ok "  setup.exe:   $exeLog"
        Write-Ok "  Product.msi: $msiLog"

        Install-CoreDetectorAndDrivers -InstallType $InstallType -RemoveList $RemoveList
        Remove-DownloadFolder -Path $dstFolder
    } else {
        Write-Warn "Даже после Product.msi Intellect X не найден в системе."
        Write-Warn "Коды завершения: setup.exe = $code, msiexec = $msiCode"
        Write-Warn "Логи:"
        Write-Warn "  setup.exe:   $exeLog"
        Write-Warn "  Product.msi: $msiLog"
    }

    if (-not $NoMirrorOpen) {
        Close-ExplorerForPath -Path $dstFolder
    }
    Write-Progress -Id $progressId -Activity "Установка Intellect X (база)" -Status "Завершено" -PercentComplete 100
}

# ============================================================
#   УСТАНОВКА АДДОНОВ (без меню, по списку из конфига)
# ============================================================

# Останавливает запущенные процессы/службы Intellect X перед установкой аддонов.
# После Install-IntellectX-BaseAuto setup.exe автоматически запускает AppHost
# и сервисы, и MSI-аддоны падают с диалогом 'Installation suspended! Please stop
# AppHost!' который требует ручного нажатия Cancel/Retry. Гасим всё что мешает.
# НЕ трогаем PostgreSQL - аддоны (Reports, etc.) пишут в БД во время установки.
function Stop-IntellectXProcesses {
    Write-Host "Останавливаю Intellect X процессы перед установкой аддонов..." -ForegroundColor Yellow

    # Сервисы IntellectX (если есть). Не трогаем postgresql-* - аддоны работают с БД.
    $svcPatterns = @('AppHost*','IntellectX*','ngp_*','axxon*','itv*')
    foreach ($pat in $svcPatterns) {
        Get-Service -Name $pat -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' } | ForEach-Object {
            try {
                Stop-Service -Name $_.Name -Force -ErrorAction Stop
                Write-Host ("  -> сервис остановлен: {0}" -f $_.Name) -ForegroundColor DarkGray
            } catch {
                Write-Warn ("  -> не удалось остановить {0}: {1}" -f $_.Name, $_.Exception.Message)
            }
        }
    }

    # Процессы, которые MSI просит закрыть в 'Installation suspended'.
    $procPatterns = @('AppHost','IntellectX','axxon*','itv*','intellect','idb')
    foreach ($pat in $procPatterns) {
        Get-Process -Name $pat -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Stop-Process -Id $_.Id -Force -ErrorAction Stop
                Write-Host ("  -> процесс убит: {0} (PID {1})" -f $_.Name, $_.Id) -ForegroundColor DarkGray
            } catch {
                Write-Warn ("  -> не удалось убить {0} (PID {1}): {2}" -f $_.Name, $_.Id, $_.Exception.Message)
            }
        }
    }

    Start-Sleep -Seconds 3
    Write-Ok "Intellect X процессы остановлены."
}

function Install-IntellectX-AddonsAuto {
    param([string[]]$Addons)
    if (-not $Addons -or $Addons.Count -eq 0) { return }

    Write-Host "==== Установка аддонов ====" -ForegroundColor Yellow

    # КРИТИЧНО: гасим AppHost/IntellectX/etc. перед установкой аддонов.
    # Иначе вылазит диалог 'Installation suspended! Please stop AppHost!'
    # с кнопками Cancel/Retry - в unattended-режиме это блокирует pipeline.
    Stop-IntellectXProcesses

    # Путь к каждому аддону строится напрямую: addons/<name>.
    # Имя должно совпадать с папкой на сервере (включая опечатки, например vi_face_recongnition).
    # Новый аддон на сервере = просто добавь имя папки в "addons" в конфиге.

    foreach ($addonName in $Addons) {
        if ([string]::IsNullOrWhiteSpace($addonName)) { continue }
        Write-Host "Установка аддона: $addonName" -ForegroundColor Cyan

        $fullRel = ($script:ShareRoot.TrimEnd('/') + '/addons/' + $addonName).Trim('/')
        $dstFolder = Join-Path $Downloads ("addon_" + ($addonName -replace '[^\w\-]','_'))

        if (Test-Path $dstFolder) {
            Remove-Item -Path $dstFolder -Recurse -Force -ErrorAction SilentlyContinue
        }

        Write-Host "Зеркалирую $fullRel ..."
        Mirror-ShareDir -RelPath $fullRel -LocalRoot $dstFolder -ProgressId 10

        # Ищем первый MSI/EXE в папке
        $pkg = Get-ChildItem -Path $dstFolder -Recurse -Include '*.msi','*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $pkg) {
            Write-Warn "В папке $dstFolder не найден MSI/EXE."
            continue
        }

        $pkgPath = $pkg.FullName
        Write-Host "Найден пакет: $($pkg.Name)"

        $ext = $pkg.Extension
        $installed = $false
        if ($ext -ieq '.msi') {
            # /qb! - минимальный progress bar без модалок и Cancel. Нужен потому что
            # часть аддонов имеет CA в InstallUISequence (диалог 'Выберите язык'),
            # который при /qn просто не вызывается и MSI валится.
            # REBOOT=ReallySuppress - чтобы не было диалога 'перезагрузить сейчас?'.
            Install-MSI-Quiet -Path $pkgPath -LogDir $Logs -UiMode '/qb!' -ExtraProps 'REBOOT=ReallySuppress'
            $installed = $true
        } elseif ($ext -ieq '.exe') {
            # Расширенный список silent-флагов для разных инсталляторов:
            #   Inno Setup:     /SILENT /SP- /SUPPRESSMSGBOXES /NORESTART
            #   NSIS:           /S
            #   InstallShield:  /s /v"/qn"  или  -s -SMS
            #   MSI bootstrapper: /quiet /norestart, /q
            # Intellect X Reports = Inno Setup -> правильный флаг /SILENT /SP- /SUPPRESSMSGBOXES.
            $cands = @(
                '/SILENT /SP- /SUPPRESSMSGBOXES /NORESTART',
                '/VERYSILENT /SP- /SUPPRESSMSGBOXES /NORESTART',
                '/S',
                '/silent',
                '/quiet /norestart',
                '-s -SMS'
            )
            foreach ($c in $cands) {
                $p = Start-Process -FilePath $pkgPath -ArgumentList $c -Wait -PassThru
                if ($p.ExitCode -in 0,3010,1641) {
                    $installed = $true
                    break
                }
            }
            if (-not $installed) {
                # БЫЛО: fallback на интерактивный запуск (Start-Process -Wait без аргументов)
                # БЛОКИРОВАЛО pipeline когда оператора нет у машины. Теперь - skip + warning.
                Write-Warn "Не удалось тихо установить $addonName (все silent-флаги вернули non-zero exit). Пропускаю."
                Write-Warn "  Файл: $pkgPath"
                Write-Warn "  Чтобы добавить новый silent-флаг - правь \$cands в Install-IntellectX-AddonsAuto."
            }
        } else {
            Write-Warn "Неизвестный тип файла: $pkgPath"
        }

        if ($installed) {
            Remove-DownloadFolder -Path $dstFolder
        }
    }
}

# ============================================================
#   ЗАПУСК
# ============================================================

Write-Host "==== Установка Intellect X (автоматический режим) ====" -ForegroundColor Yellow
Write-Host "Тип установки: $InstallType"
Write-Host "Конфиг: $ConfigFile"

Install-IntellectX-BaseAuto -InstallType $InstallType -RemoveList $RemoveComponents -CmdProps $CmdProps
Install-IntellectX-AddonsAuto -Addons $AddonsList

Write-Host "Установка Intellect X завершена." -ForegroundColor Green