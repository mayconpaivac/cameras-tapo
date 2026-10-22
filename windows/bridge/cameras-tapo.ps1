<#
  Cameras Tapo - ponte de acesso remoto (servico do PC de casa)

  Le C:\ProgramData\CamerasTapo\bridge.json, que o app do Windows escreve sempre que
  as cameras mudam, achando cada camera pelo MAC mesmo se o IP mudar.
  - Video: o go2rtc (incluido) retransmite cada lente em rtsp://<este PC>:8554/cam<n>_<lente>.
    Cada camera recebe uma conexao so por lente, nao importa quantos apps assistam.
  - Movimento (ONVIF): portas 20200+n repassam direto para a camera.
  Tambem responde a lista de cameras em http://<este PC>:20200/cameras para o app do Mac
  sincronizar (as senhas vao criptografadas com o codigo de pareamento).
  Tudo so aceita conexoes do Tailscale (100.64.0.0/10).

  Normalmente instalado pelo instalador do app. Manualmente (PowerShell como Administrador):
      powershell -ExecutionPolicy Bypass -File .\cameras-tapo.ps1 -Install
      powershell -ExecutionPolicy Bypass -File .\cameras-tapo.ps1 -Uninstall
#>
param([switch]$Install, [switch]$Uninstall, [switch]$Run)
$ErrorActionPreference = 'Stop'

$TaskName  = 'Cameras Tapo - ponte'
$RuleName  = 'Cameras Tapo (somente Tailscale)'
$Dir       = Join-Path $env:ProgramData 'CamerasTapo'
$Installed = Join-Path $Dir 'cameras-tapo.ps1'
$Config    = Join-Path $Dir 'bridge.json'
$LogFile   = Join-Path $Dir 'ponte.log'
$SyncPort  = 20200
$RestreamPort = 8554
$Private   = Join-Path $Dir 'private'          # go2rtc config (has passwords): SYSTEM/Admins only
$Go2rtc    = Join-Path $Dir 'go2rtc.exe'
$Go2rtcCfg = Join-Path $Private 'go2rtc.yaml'
$Entropy   = [Text.Encoding]::UTF8.GetBytes('CamerasTapo.bridge.v1')
$RtspBase  = 5540
$OnvifBase = 20200
$MaxSlots  = 99

function Write-Log([string]$msg) {
    $line = "$(Get-Date -Format s)  $msg"
    Write-Host $line
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) { Move-Item -Force $LogFile "$LogFile.old" }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch {}
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $id
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Abra o PowerShell como Administrador (botao direito > Executar como administrador).'
    }
}

function Get-TailscaleIp {
    $exe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (-not (Test-Path $exe)) { return $null }
    try { return (& $exe ip -4 | Select-Object -First 1) } catch { return $null }
}

function Read-Config {
    if (-not (Test-Path $Config)) { return $null }
    try { return (Get-Content -Raw -Encoding UTF8 $Config | ConvertFrom-Json) } catch { Write-Log "bridge.json invalido: $_"; return $null }
}

# --- Finding cameras ---------------------------------------------------------

$script:LastSweep = [datetime]::MinValue

function Update-Neighbors([string]$subnet) {
    $tasks = foreach ($i in 1..254) {
        (New-Object System.Net.NetworkInformation.Ping).SendPingAsync("$subnet.$i", 600)
    }
    try { [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks) } catch {}
    $script:LastSweep = Get-Date
}

function Find-CameraIp($cam, [string]$subnet) {
    if (-not $cam.mac) { return $null }
    $mac = ($cam.mac -replace ':', '-').ToUpper()
    $n = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.LinkLayerAddress -eq $mac -and $_.IPAddress -like "$subnet.*" -and $_.State -ne 'Unreachable' } |
        Select-Object -First 1
    if ($n) { return $n.IPAddress }
    return $null
}

# --- Port forwarding ---------------------------------------------------------

# Current rules in our port ranges: "listenport" -> "connectaddress".
function Get-CurrentRules {
    $map = @{}
    foreach ($line in (netsh interface portproxy show v4tov4)) {
        $p = ($line.Trim() -split '\s+')
        if ($p.Count -ge 4 -and $p[1] -match '^\d+$') {
            $port = [int]$p[1]
            if (($port -gt $RtspBase -and $port -le $RtspBase + $MaxSlots) -or ($port -gt $OnvifBase -and $port -le $OnvifBase + $MaxSlots)) {
                $map[[string]$port] = $p[2]
            }
        }
    }
    return $map
}

function Set-Rule([string]$port, [int]$targetPort, [string]$ip) {
    try { netsh interface portproxy delete v4tov4 listenport=$port listenaddress=0.0.0.0 | Out-Null } catch {}
    if ($ip) { netsh interface portproxy add v4tov4 listenport=$port listenaddress=0.0.0.0 connectport=$targetPort connectaddress=$ip | Out-Null }
}

$script:FirewallPorts = ''

function Set-Firewall([int[]]$ports) {
    $key = ($ports | Sort-Object) -join ','
    if ($key -eq $script:FirewallPorts) { return }
    Remove-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Action Allow -Protocol TCP `
        -LocalPort $ports -RemoteAddress '100.64.0.0/10' -Profile Any | Out-Null
    $script:FirewallPorts = $key
}

# --- Restream (go2rtc) ---------------------------------------------------------

Add-Type -AssemblyName System.Security

# Secrets in bridge.json are encrypted by the app with DPAPI (LocalMachine).
function Unprotect-Secret([string]$b64) {
    if (-not $b64) { return $null }
    try {
        $bytes = [Convert]::FromBase64String($b64)
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $Entropy, 'LocalMachine')
        return [Text.Encoding]::UTF8.GetString($plain)
    } catch { return $null }
}

function Quote-Yaml([string]$s) { return "'" + ($s -replace "'", "''") + "'" }

$script:Go2rtcProc = $null
$script:Go2rtcNextStart = Get-Date

function Write-Go2rtcConfig($cfg, $cams, [hashtable]$ips) {
    $pw = Unprotect-Secret $cfg.restreamSecret
    $lines = @(
        'api:', '  listen: "127.0.0.1:1984"',
        'rtsp:', "  listen: "":$RestreamPort""", '  default_query: "video"'
    )
    if ($pw) { $lines += @('  username: "cameras"', "  password: $(Quote-Yaml $pw)") }
    $lines += @('webrtc:', '  listen: "127.0.0.1:8555"', 'srtp:', '  listen: ""',
                'log:', '  format: "text"', '  level: "info"', 'streams:')
    foreach ($cam in $cams) {
        $slot = [int]$cam.slot
        $secret = Unprotect-Secret $cam.localSecret
        if ($slot -lt 1 -or -not $secret) { continue }
        $auth = [Uri]::EscapeDataString([string]$cam.username) + ':' + [Uri]::EscapeDataString($secret)
        $hostPort = "$($ips[[string]$slot]):$([int]$cam.port)"
        $lines += "  cam${slot}_0: $(Quote-Yaml "rtsp://$auth@$hostPort/stream1")"
        if ($cam.dualLens) { $lines += "  cam${slot}_1: $(Quote-Yaml "rtsp://$auth@$hostPort/stream6")" }
    }
    $text = ($lines -join "`r`n") + "`r`n"
    $old = if (Test-Path $Go2rtcCfg) { [IO.File]::ReadAllText($Go2rtcCfg) } else { '' }
    if ($text -eq $old) { return $false }
    [IO.File]::WriteAllText($Go2rtcCfg, $text, (New-Object Text.UTF8Encoding $false))
    return $true
}

function Stop-Go2rtc {
    if ($script:Go2rtcProc -and -not $script:Go2rtcProc.HasExited) {
        try { $script:Go2rtcProc.Kill(); $script:Go2rtcProc.WaitForExit(5000) | Out-Null } catch {}
    }
    $script:Go2rtcProc = $null
    Get-Process -Name go2rtc -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $Go2rtc } | Stop-Process -Force -ErrorAction SilentlyContinue
}

# Keeps go2rtc running; restarts it when its config changed or it exited.
function Confirm-Go2rtc([bool]$restart) {
    if (-not (Test-Path $Go2rtc) -or -not (Test-Path $Go2rtcCfg)) { return }
    $running = $script:Go2rtcProc -and -not $script:Go2rtcProc.HasExited
    if ($running -and -not $restart) { return }
    if (-not $running -and (Get-Date) -lt $script:Go2rtcNextStart) { return }
    Stop-Go2rtc
    $script:Go2rtcProc = Start-Process -FilePath $Go2rtc -ArgumentList @('-config', "`"$Go2rtcCfg`"") `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput (Join-Path $Dir 'go2rtc.log') -RedirectStandardError (Join-Path $Dir 'go2rtc-erros.log')
    $script:Go2rtcNextStart = (Get-Date).AddSeconds(10) # don't spin if it keeps crashing
    Write-Log "retransmissao (go2rtc) iniciada, pid $($script:Go2rtcProc.Id)"
}

function Sync-Bridge {
    $cfg = Read-Config
    $cams = @()
    if ($cfg -and $cfg.cameras) { $cams = @($cfg.cameras) }
    $subnet = if ($cfg -and $cfg.subnet) { $cfg.subnet } else { '10.1.1' }

    # Ping sweep only when some camera is missing from the ARP table (at most every 5 min).
    $missing = @($cams | Where-Object { -not (Find-CameraIp $_ $subnet) })
    if ($missing.Count -gt 0 -and ((Get-Date) - $script:LastSweep).TotalMinutes -ge 5) {
        Update-Neighbors $subnet
    }

    $desired = @{}
    $ips = @{}
    foreach ($cam in $cams) {
        $slot = [int]$cam.slot
        if ($slot -lt 1 -or $slot -gt $MaxSlots) { continue }
        $ip = Find-CameraIp $cam $subnet
        if (-not $ip) { $ip = $cam.host }
        $ips[[string]$slot] = $ip
        $desired[[string]($OnvifBase + $slot)] = @($ip, 2020)   # PTZ goes straight to the camera
    }

    # Video is restreamed by go2rtc (old RTSP port forwards are removed below).
    if ($cfg) {
        $changed = Write-Go2rtcConfig $cfg $cams $ips
        if ($changed) { Write-Log 'configuracao da retransmissao atualizada' }
        Confirm-Go2rtc $changed
    }

    $current = Get-CurrentRules
    foreach ($port in $desired.Keys) {
        $ip = $desired[$port][0]
        if ($current[$port] -ne $ip) {
            Set-Rule $port $desired[$port][1] $ip
            Write-Log "porta $port -> ${ip}:$($desired[$port][1])"
        }
    }
    foreach ($port in @($current.Keys)) {
        if (-not $desired.ContainsKey($port)) { Set-Rule $port 0 $null; Write-Log "porta $port removida" }
    }

    $ports = @($SyncPort, $RestreamPort) + @($desired.Keys | ForEach-Object { [int]$_ })
    Set-Firewall $ports
}

# --- Service loop: keeps the bridge current and answers the Mac --------------

function Send-Response($ctx, [int]$status, [string]$type, [byte[]]$body) {
    $ctx.Response.StatusCode = $status
    $ctx.Response.ContentType = $type
    $ctx.Response.ContentLength64 = $body.Length
    $ctx.Response.OutputStream.Write($body, 0, $body.Length)
    $ctx.Response.Close()
}

function Test-Allowed($address) {
    if ([System.Net.IPAddress]::IsLoopback($address)) { return $true }
    $b = $address.MapToIPv4().GetAddressBytes()
    return ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) # Tailscale only
}

function Invoke-Request($ctx) {
    try {
        if (-not (Test-Allowed $ctx.Request.RemoteEndPoint.Address)) {
            Send-Response $ctx 403 'text/plain' ([Text.Encoding]::UTF8.GetBytes('forbidden')); return
        }
        switch ($ctx.Request.Url.AbsolutePath) {
            '/cameras' {
                $body = if (Test-Path $Config) { [IO.File]::ReadAllBytes($Config) } else { [Text.Encoding]::UTF8.GetBytes('{"version":1,"cameras":[]}') }
                Send-Response $ctx 200 'application/json; charset=utf-8' $body
            }
            '/ping' { Send-Response $ctx 200 'text/plain' ([Text.Encoding]::UTF8.GetBytes('ok')) }
            default { Send-Response $ctx 404 'text/plain' ([Text.Encoding]::UTF8.GetBytes('not found')) }
        }
    } catch { Write-Log "pedido falhou: $_" }
}

function Invoke-BridgeLoop {
    Write-Log 'ponte iniciada'
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://+:$SyncPort/")
    $listener.Start()
    $pending = $listener.GetContextAsync()
    $lastWrite = [datetime]::MinValue
    $nextSync = Get-Date
    while ($true) {
        if ($pending.Wait(1000)) {
            Invoke-Request $pending.Result
            $pending = $listener.GetContextAsync()
        }
        $w = if (Test-Path $Config) { (Get-Item $Config).LastWriteTimeUtc } else { [datetime]::MinValue }
        Confirm-Go2rtc $false
        if ($w -ne $lastWrite -or (Get-Date) -ge $nextSync) {
            $lastWrite = $w
            try { Sync-Bridge } catch { Write-Log "erro ao atualizar: $_" }
            $nextSync = (Get-Date).AddMinutes(2)
        }
    }
}

# --- Install / uninstall -----------------------------------------------------

function Install-Bridge {
    Assert-Admin
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    if ($PSCommandPath -ne $Installed) { Copy-Item -Force -Path $PSCommandPath -Destination $Installed }
    # The app (normal user) writes bridge.json here.
    & icacls $Dir /grant '*S-1-5-32-545:(OI)(CI)M' /T /Q | Out-Null
    # go2rtc's config holds camera passwords: only SYSTEM and Administrators may read it.
    New-Item -ItemType Directory -Force -Path $Private | Out-Null
    & icacls $Private /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /Q | Out-Null
    $src = Join-Path $PSScriptRoot 'go2rtc.exe'
    if ((Test-Path $src) -and ($src -ne $Go2rtc)) {
        Get-Process -Name go2rtc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        Copy-Item -Force -Path $src -Destination $Go2rtc
    }

    Set-Service -Name iphlpsvc -StartupType Automatic   # portproxy needs the IP Helper service
    Start-Service -Name iphlpsvc
    Set-Firewall @($SyncPort, $RestreamPort)

    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Installed`" -Run"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName

    Write-Log 'ponte instalada'
    Write-Host ''
    Write-Host 'Ponte instalada. Adicione as cameras no app do Windows; a ponte se atualiza sozinha.' -ForegroundColor Green
    $ts = Get-TailscaleIp
    if ($ts) { Write-Host "Endereco deste PC no Tailscale: $ts  (coloque no app do Mac, em Acesso remoto)" -ForegroundColor Cyan }
    else { Write-Host 'Tailscale nao encontrado. Instale em tailscale.com/download e entre na sua conta.' -ForegroundColor Yellow }
}

function Uninstall-Bridge {
    Assert-Admin
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*cameras-tapo.ps1*-Run*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-Process -Name go2rtc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    foreach ($port in @((Get-CurrentRules).Keys)) { Set-Rule $port 0 $null }
    Remove-Item -Recurse -Force -Path $Private -ErrorAction SilentlyContinue
    Remove-Item -Force -Path $Go2rtc -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    Remove-Item -Force -Path $Installed -ErrorAction SilentlyContinue
    Write-Host 'Ponte removida.' -ForegroundColor Green
}

if ($Uninstall) { Uninstall-Bridge }
elseif ($Install) { Install-Bridge }
elseif ($Run) { Invoke-BridgeLoop }
else { Assert-Admin; Sync-Bridge }
