<#
.SYNOPSIS
    Sets up a Windows PC for DuoPC: the TightVNC server, locked to this PC, behind DuoPC Gateway, an
    encrypted (TLS 1.3) front door the phone pairs with by QR code. No Tailscale needed.

.DESCRIPTION
    Run once, in PowerShell opened with "Run as administrator":

        powershell -ExecutionPolicy Bypass -File .\Setup-DuoPC.ps1

    What it does:
      1. Downloads TightVNC 2.8.85 (free, GPL) from tightvnc.com, checks its digital signature, and
         installs only the server, as a Windows service (so the lock screen and UAC prompts work too).
      2. Gives TightVNC a random password and makes it accept connections from this PC only
         (127.0.0.1). Nothing on the network can reach it directly.
      3. Builds DuoPC Gateway from the source next to this script (needs the .NET 8 SDK), installs
         it to Program Files\DuoPC and runs it as a service on port 5960. It accepts only TLS 1.3
         connections from paired phones, and passes them on to TightVNC.
      4. Opens port 5960 in Windows Firewall for the gateway only, and closes any older VNC rules.
      5. Shows a QR code to scan in DuoPC, and how to set up port forwarding on your router.

    TightVNC 2.8 is used on purpose: TightVNC 4 moves passwords to its own sign-in method, which
    other VNC apps (including DuoPC) can't use.

.PARAMETER PublicHost
    The address the phone uses away from home: a dynamic DNS name (best) or your public IP. If you
    leave it out, the script asks, and can look up your current public IP for you.

.PARAMETER Port
    The port the gateway listens on. Default 5960.

.PARAMETER ExternalPort
    The outside port your router forwards to the gateway, if it isn't the same as -Port.

.PARAMETER Pair
    Only pair another phone (or pair again): shows a new QR code. Changes nothing else.

.PARAMETER Check
    Changes nothing. Checks TightVNC, the gateway, the firewall, and that both answer as they should.

.PARAMETER Uninstall
    Removes the gateway (service, files, certificate, pairings), its firewall rule, and TightVNC.
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')] [Parameter(ParameterSetName = 'Pair')] [string] $PublicHost,
    [Parameter(ParameterSetName = 'Install')] [ValidateRange(1, 65535)] [int] $Port = 5960,
    [Parameter(ParameterSetName = 'Install')] [Parameter(ParameterSetName = 'Pair')] [ValidateRange(1, 65535)] [int] $ExternalPort,
    [Parameter(ParameterSetName = 'Pair')] [switch] $Pair,
    [Parameter(ParameterSetName = 'Check')] [switch] $Check,
    [Parameter(ParameterSetName = 'Uninstall')] [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'

$TightVncVersion = '2.8.85'
$VncPort = 5900
$ServiceName = 'DuoPCGateway'
$InstallDir = Join-Path $env:ProgramFiles 'DuoPC'
$GatewayExe = Join-Path $InstallDir 'DuoPCGateway.exe'
$DataDir = Join-Path $env:ProgramData 'DuoPC'
$GatewayProject = Join-Path $PSScriptRoot 'DuoPCGateway\DuoPCGateway.csproj'
$GatewayRule = 'DuoPC-Gateway'
$OldVncRule = 'DuoPC-VNC'          # from the Tailscale-only version of this script
$TightVncKey = 'HKLM:\SOFTWARE\TightVNC\Server'

function Write-Step([string] $text) { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Write-Ok([string] $text) { Write-Host "    [ok] $text" -ForegroundColor Green }
function Write-Warn([string] $text) { Write-Host "    [!]  $text" -ForegroundColor Yellow }
function Write-Bad([string] $text) { Write-Host "    [x]  $text" -ForegroundColor Red }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (-not (Test-Admin)) { throw 'Run this in PowerShell opened with "Run as administrator".' }
}

function Get-TightVncInstall {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'TightVNC*' } |
        Select-Object -First 1
}

# The IPv4 address on the interface with a default gateway: what the router forwards to.
function Get-LanAddress {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
    if (-not $route) { return $null }
    Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1 -ExpandProperty IPAddress
}

function New-VncPassword {
    # No look-alikes (0/O, 1/l/I). VNC passwords are at most 8 characters.
    $alphabet = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = New-Object byte[] 8
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
}

# DES-ECB with an 8-byte key, the way VNC uses it.
function Invoke-Des([byte[]] $key, [byte[]] $data) {
    $des = [Security.Cryptography.DES]::Create()
    try {
        $des.Mode = 'ECB'; $des.Padding = 'None'
        $des.CreateEncryptor($key, $null).TransformFinalBlock($data, 0, $data.Length)
    } finally { $des.Dispose() }
}

function Get-ReversedBits([byte] $b) {
    $r = 0
    for ($i = 0; $i -lt 8; $i++) { if ($b -band (1 -shl $i)) { $r = $r -bor (1 -shl (7 - $i)) } }
    [byte]$r
}

function ConvertTo-VncKey([string] $password) {
    $key = New-Object byte[] 8
    $raw = [Text.Encoding]::ASCII.GetBytes($password)
    [Array]::Copy($raw, $key, [Math]::Min(8, $raw.Length))
    , $key
}

# How TightVNC stores its password in the registry: DES with VNC's well-known fixed key
# (17 52 6b 06 23 4e 58 07, written here bit-reversed for standard DES).
function ConvertTo-TightVncStoredPassword([string] $password) {
    $fixedKey = [byte[]](0xE8, 0x4A, 0xD6, 0x60, 0xC4, 0x72, 0x1A, 0xE0)
    , (Invoke-Des $fixedKey (ConvertTo-VncKey $password))
}

# Talks VNC to a server as far as the list of sign-in types, or, given a password, all the way
# through VNC password sign-in. Classic VNC password sign-in is type 2.
function Test-RfbServer([string] $Address, [int] $Port, [string] $Password, [int] $TimeoutMs = 4000) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $client.BeginConnect($Address, $Port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw "no answer on $($Address):$Port (timed out)" }
        $client.EndConnect($connect)
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $stream.WriteTimeout = $TimeoutMs

        $readExactly = {
            param([int] $count)
            $buffer = New-Object byte[] $count
            $offset = 0
            while ($offset -lt $count) {
                $n = $stream.Read($buffer, $offset, $count - $offset)
                if ($n -le 0) { throw 'the server closed the connection' }
                $offset += $n
            }
            , $buffer
        }
        $readUInt32 = { $raw = & $readExactly 4; [Array]::Reverse($raw); [BitConverter]::ToUInt32($raw, 0) }

        $banner = [Text.Encoding]::ASCII.GetString((& $readExactly 12))
        if ($banner -notmatch '^RFB (\d{3})\.(\d{3})\n$') { throw "not a VNC server (it said '$($banner.Trim())')" }
        $major = [int]$Matches[1]; $minor = [int]$Matches[2]
        $v38 = $major -gt 3 -or $minor -ge 8

        if ($major -eq 3 -and $minor -lt 7) {
            $stream.Write([Text.Encoding]::ASCII.GetBytes("RFB 003.003`n"), 0, 12)
            $types = @(& $readUInt32)
        } else {
            $reply = if ($v38) { "RFB 003.008`n" } else { "RFB 003.007`n" }
            $stream.Write([Text.Encoding]::ASCII.GetBytes($reply), 0, 12)
            $count = (& $readExactly 1)[0]
            if ($count -eq 0) {
                $length = & $readUInt32
                $reason = if ($length -gt 0 -and $length -lt 4096) { [Text.Encoding]::UTF8.GetString((& $readExactly $length)) } else { '' }
                throw "the server refused the connection: $reason"
            }
            $types = @((& $readExactly $count) | ForEach-Object { [int]$_ })
        }
        $result = [pscustomobject]@{
            Version        = "$major.$minor"
            SecurityTypes  = $types
            HasVncPassword = $types -contains 2
            HasNoSignIn    = $types -contains 1
            SignedIn       = $null
        }
        if ($Password -and $result.HasVncPassword) {
            if ($minor -ge 7 -or $major -gt 3) { $stream.Write([byte[]](2), 0, 1) }
            $challenge = & $readExactly 16
            $key = ConvertTo-VncKey $Password
            for ($i = 0; $i -lt 8; $i++) { $key[$i] = Get-ReversedBits $key[$i] }
            $response = Invoke-Des $key $challenge
            $stream.Write($response, 0, 16)
            $result.SignedIn = (& $readUInt32) -eq 0
        }
        $result
    } finally {
        $client.Close()
    }
}

# A TLS 1.3 handshake with the gateway, returning its certificate's SHA-256. Sends no pairing token.
function Test-GatewayTls([string] $Address, [int] $Port, [int] $TimeoutMs = 4000) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $client.BeginConnect($Address, $Port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw "no answer on $($Address):$Port (timed out)" }
        $client.EndConnect($connect)
        $acceptAny = [System.Net.Security.RemoteCertificateValidationCallback] { $true }   # we compare the fingerprint ourselves
        $tls = New-Object System.Net.Security.SslStream($client.GetStream(), $false, $acceptAny)
        $tls.ReadTimeout = $TimeoutMs
        $tls.AuthenticateAsClient('DuoPC', $null, [Security.Authentication.SslProtocols]12288, $false)   # 12288 = TLS 1.3
        $certificate = New-Object Security.Cryptography.X509Certificates.X509Certificate2 $tls.RemoteCertificate
        $sha = [Security.Cryptography.SHA256]::Create()
        [pscustomobject]@{
            Protocol    = "$($tls.SslProtocol)"
            Fingerprint = -join ($sha.ComputeHash($certificate.RawData) | ForEach-Object { $_.ToString('x2') })
        }
    } finally {
        $client.Close()
    }
}

function Install-TightVnc([string] $password) {
    $existing = Get-TightVncInstall
    if ($existing -and "$($existing.DisplayVersion)" -like '4.*') {
        throw "TightVNC $($existing.DisplayVersion) is installed. Remove it first (Settings -> Apps -> TightVNC), then run this script again."
    }
    if ($existing) {
        Write-Ok "already installed: $($existing.DisplayName) $($existing.DisplayVersion)"
    } else {
        Write-Step "Downloading TightVNC $TightVncVersion"
        $arch = if ([Environment]::Is64BitOperatingSystem) { '64bit' } else { '32bit' }
        $url = "https://www.tightvnc.com/download/$TightVncVersion/tightvnc-$TightVncVersion-gpl-setup-$arch.msi"
        $dir = Join-Path $env:TEMP 'DuoPC'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $msi = Join-Path $dir "tightvnc-$TightVncVersion-$arch.msi"
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing
        Write-Ok $url

        $signature = Get-AuthenticodeSignature -FilePath $msi
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'GlavSoft') {
            Remove-Item $msi -Force
            throw "The installer's signature didn't check out ($($signature.Status), $($signature.SignerCertificate.Subject)). Nothing was installed."
        }
        Write-Ok "signed by $($signature.SignerCertificate.GetNameInfo('SimpleName', $false))"

        Write-Step 'Installing the TightVNC server'
        $arguments = @('/i', "`"$msi`"", '/quiet', '/norestart',
            'ADDLOCAL=Server', 'SERVER_REGISTER_AS_SERVICE=1', 'SERVER_ADD_FIREWALL_EXCEPTION=0', 'SERVER_ALLOW_SAS=1',
            'SET_USEVNCAUTHENTICATION=1', 'VALUE_OF_USEVNCAUTHENTICATION=1',
            'SET_PASSWORD=1', "VALUE_OF_PASSWORD=`"$password`"",
            'SET_ALLOWLOOPBACK=1', 'VALUE_OF_ALLOWLOOPBACK=1',
            'SET_LOOPBACKONLY=1', 'VALUE_OF_LOOPBACKONLY=1',
            'SET_ACCEPTHTTPCONNECTIONS=1', 'VALUE_OF_ACCEPTHTTPCONNECTIONS=0')
        $process = Start-Process -FilePath msiexec.exe -ArgumentList $arguments -Wait -PassThru
        Remove-Item $msi -Force -ErrorAction SilentlyContinue
        if ($process.ExitCode -notin 0, 3010) { throw "The TightVNC installer failed (exit code $($process.ExitCode))." }
        Write-Ok 'installed as a service'
    }

    # Set directly as well, so running the script again (or over an older install) applies them.
    Write-Step 'Locking TightVNC to this PC'
    if (-not (Test-Path $TightVncKey)) { New-Item -Path $TightVncKey -Force | Out-Null }
    $dwords = @{ UseVncAuthentication = 1; AllowLoopback = 1; LoopbackOnly = 1; AcceptHttpConnections = 0; AcceptRfbConnections = 1; RfbPort = $VncPort; AlwaysShared = 1 }
    foreach ($name in $dwords.Keys) { Set-ItemProperty -Path $TightVncKey -Name $name -Value $dwords[$name] -Type DWord }
    Set-ItemProperty -Path $TightVncKey -Name IpAccessControl -Value '127.0.0.1-127.0.0.1:0,0.0.0.0-255.255.255.255:1' -Type String
    Set-ItemProperty -Path $TightVncKey -Name Password -Value (ConvertTo-TightVncStoredPassword $password) -Type Binary
    Set-Service -Name tvnserver -StartupType Automatic
    Restart-Service -Name tvnserver
    Start-Sleep -Seconds 2
    Write-Ok "accepts connections from 127.0.0.1 only, on port $VncPort"
}

function Install-Gateway {
    Write-Step 'Building DuoPC Gateway'
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    $sdks = if ($dotnet) { & dotnet --list-sdks 2>$null } else { @() }
    if (-not ($sdks | Where-Object { $_ -match '^(\d+)\.' -and [int]$Matches[1] -ge 8 })) {
        throw 'The .NET 8 SDK (or newer) is needed to build the gateway: https://dotnet.microsoft.com/download'
    }
    if (-not (Test-Path $GatewayProject)) { throw "Can't find $GatewayProject. Run this script from the windows folder of the DuoPC repo." }

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Stopped') { Stop-Service -Name $ServiceName; Start-Sleep -Seconds 1 }
    $runtime = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'win-arm64' } else { 'win-x64' }
    & dotnet publish $GatewayProject -c Release -r $runtime --self-contained false -p:PublishSingleFile=true -o $InstallDir --nologo -v quiet
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $GatewayExe)) { throw 'Building the gateway failed (see above).' }
    Write-Ok "installed to $InstallDir"

    & $GatewayExe config --port $Port --vnc-port $VncPort --listen any | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Configuring the gateway failed.' }

    $binaryPath = "`"$GatewayExe`" run"
    if (-not $service) {
        New-Service -Name $ServiceName -DisplayName 'DuoPC Gateway' -BinaryPathName $binaryPath -StartupType Automatic `
            -Description 'Encrypted connections from the DuoPC app to TightVNC on this PC.' | Out-Null
    } else {
        & sc.exe config $ServiceName binPath= $binaryPath start= auto | Out-Null
    }
    # Restart it if it ever stops unexpectedly.
    & sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/60000 | Out-Null
    Start-Service -Name $ServiceName
    Write-Ok "running as a service on port $Port, starts with Windows"
}

function Set-GatewayFirewall {
    Write-Step 'Windows Firewall'
    Get-NetFirewallRule -Name $GatewayRule, $OldVncRule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -Name $GatewayRule -DisplayName 'DuoPC Gateway' `
        -Description 'Encrypted connections from paired DuoPC phones. Added by Setup-DuoPC.ps1.' `
        -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Program $GatewayExe -Profile Any | Out-Null
    Write-Ok "port $Port open, for the gateway only"
    # TightVNC itself must not be reachable from outside; rules from an earlier install let it be.
    Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*TightVNC*' -or $_.DisplayName -like '*tvnserver*' } |
        ForEach-Object {
            Disable-NetFirewallRule -Name $_.Name
            Write-Ok "turned off the older rule '$($_.DisplayName)'"
        }
}

function Resolve-PublicHost {
    if ($PublicHost) { return $PublicHost }
    Write-Host '    To use DuoPC away from home, the phone needs your home internet address:'
    Write-Host '    a dynamic DNS name (best: it follows your IP when it changes, e.g. from your router or duckdns.org)'
    Write-Host '    or your public IP. Press Enter to look up your current public IP (asks api.ipify.org).'
    $answer = (Read-Host '    Address').Trim()
    if ($answer) { return $answer }
    try {
        $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org' -UseBasicParsing -TimeoutSec 10).ToString().Trim()
        Write-Ok "your public IP is $ip (it may change; a dynamic DNS name won't)"
        return $ip
    } catch {
        $lan = Get-LanAddress
        Write-Warn "Couldn't look it up. Using this PC's local address $lan, which works only at home; edit it in the app later."
        return $lan
    }
}

function Show-Pairing {
    Write-Step 'Pair your phone'
    $hostForPhone = Resolve-PublicHost
    $inside = (Get-Content (Join-Path $DataDir 'gateway.json') -Raw | ConvertFrom-Json).port
    $outside = if ($ExternalPort) { $ExternalPort } else { $inside }
    & $GatewayExe pair --host $hostForPhone --port $outside --name $env:COMPUTERNAME --device ('Phone ' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
    if ($LASTEXITCODE -ne 0) { throw 'Making a pairing code failed.' }

    $lan = Get-LanAddress
    Write-Step 'For use away from home: forward a port on your router'
    Write-Host "    In your router's settings (often http://192.168.1.1 or http://192.168.0.1), add a port forward:"
    Write-Host "        TCP, outside port $outside  ->  $lan, port $inside" -ForegroundColor White
    Write-Host '    Also give this PC a fixed local address there (DHCP reservation), so the forward keeps working.'
    Write-Host '    At home, the phone can connect without the forward if your router supports "NAT loopback";'
    Write-Host "    if it doesn't, edit the PC in the app and use $lan while you're at home."
}

function Invoke-Check {
    $healthy = $true
    $admin = Test-Admin

    Write-Step 'TightVNC'
    $install = Get-TightVncInstall
    if ($install) { Write-Ok "installed: $($install.DisplayName) $($install.DisplayVersion)" } else { Write-Bad 'not installed'; $healthy = $false }
    $tvn = Get-Service -Name tvnserver -ErrorAction SilentlyContinue
    if ($tvn -and $tvn.Status -eq 'Running') { Write-Ok 'service running' } else { Write-Bad 'service not running'; $healthy = $false }
    $settings = Get-ItemProperty -Path $TightVncKey -ErrorAction SilentlyContinue
    if ($settings -and $settings.LoopbackOnly -eq 1) { Write-Ok 'accepts connections from this PC only' }
    else { Write-Bad 'not limited to this PC (LoopbackOnly is off): run this script to fix'; $healthy = $false }
    try {
        $probe = Test-RfbServer -Address 127.0.0.1 -Port $VncPort
        Write-Ok "answers on 127.0.0.1:$VncPort (VNC $($probe.Version), sign-in types $($probe.SecurityTypes -join ', '))"
        if (-not $probe.HasVncPassword) { Write-Bad "doesn't offer VNC password sign-in"; $healthy = $false }
        if ($probe.HasNoSignIn) { Write-Warn 'also lets people in without a password' }
    } catch { Write-Bad "VNC server: $($_.Exception.Message)"; $healthy = $false }

    Write-Step 'DuoPC Gateway'
    $gw = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($gw -and $gw.Status -eq 'Running') { Write-Ok 'service running' } else { Write-Bad 'service not running'; $healthy = $false }
    $gatewayPort = $Port
    if ($admin -and (Test-Path (Join-Path $DataDir 'gateway.json'))) {
        $config = Get-Content (Join-Path $DataDir 'gateway.json') -Raw | ConvertFrom-Json
        $gatewayPort = $config.port
        $devices = @($config.devices)
        if ($devices.Count) { Write-Ok "paired phones: $(($devices | ForEach-Object { $_.name }) -join ', ')" } else { Write-Warn 'no phones paired yet: run with -Pair' }
    }
    try {
        $tls = Test-GatewayTls -Address 127.0.0.1 -Port $gatewayPort
        Write-Ok "answers with $($tls.Protocol) on port $gatewayPort, certificate $($tls.Fingerprint.Substring(0, 16))..."
        if ($admin -and (Test-Path $GatewayExe)) {
            $expected = (& $GatewayExe fingerprint | Out-String).Trim()
            if ($expected -eq $tls.Fingerprint) { Write-Ok 'certificate matches the one phones are paired with' }
            else { Write-Bad 'certificate differs from the gateway''s own: something else is on this port'; $healthy = $false }
        }
    } catch { Write-Bad "gateway: $($_.Exception.Message)"; $healthy = $false }

    Write-Step 'Windows Firewall'
    $rule = Get-NetFirewallRule -Name $GatewayRule -ErrorAction SilentlyContinue
    if ($rule -and $rule.Enabled -eq 'True') { Write-Ok "rule 'DuoPC Gateway' is on" } else { Write-Bad "rule 'DuoPC Gateway' missing or off"; $healthy = $false }
    $vncOpen = Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*TightVNC*' -or $_.Name -eq $OldVncRule }
    foreach ($r in $vncOpen) { Write-Warn "this rule still lets the network reach VNC directly: '$($r.DisplayName)'" }

    if (-not $admin) { Write-Host "`n    (Run as administrator to also check pairings and the certificate.)" }
    Write-Host ''
    if ($healthy) { Write-Host 'All good on this PC. If the phone still can''t connect from outside, check the router''s port forward.' -ForegroundColor Green }
    else { Write-Host 'Something needs attention (see above).' -ForegroundColor Yellow }
}

function Invoke-Install {
    Assert-Admin
    Write-Host 'Setting up DuoPC: TightVNC behind an encrypted gateway.' -ForegroundColor White

    $password = New-VncPassword    # random; it travels inside the pairing code, so nobody types it
    Install-TightVnc $password
    Install-Gateway
    & $GatewayExe config --vnc-password $password | Out-Null

    Write-Step 'Checking it works'
    $probe = Test-RfbServer -Address 127.0.0.1 -Port $VncPort -Password $password
    if ($probe.SignedIn) { Write-Ok 'the gateway can sign in to TightVNC' }
    else { throw "TightVNC didn't accept the new password. Open the TightVNC tray icon -> Configuration and check Server -> Primary password, then run this script again." }
    $tls = Test-GatewayTls -Address 127.0.0.1 -Port $Port
    Write-Ok "gateway answers with $($tls.Protocol)"

    Set-GatewayFirewall
    $password = $null
    Show-Pairing
    Write-Host ''
    Write-Host '    Check everything any time:   .\Setup-DuoPC.ps1 -Check'
    Write-Host '    Pair another phone:          .\Setup-DuoPC.ps1 -Pair'
    Write-Host "    Unpair a phone:              & '$GatewayExe' devices / revoke NAME"
}

function Invoke-Uninstall {
    Assert-Admin
    Write-Step 'Removing DuoPC Gateway'
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service) {
        if ($service.Status -ne 'Stopped') { Stop-Service -Name $ServiceName }
        & sc.exe delete $ServiceName | Out-Null
        Write-Ok 'service removed'
    }
    Get-NetFirewallRule -Name $GatewayRule, $OldVncRule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Write-Ok 'firewall rule removed'
    foreach ($dir in $InstallDir, $DataDir) {
        if (Test-Path $dir) { Remove-Item -Recurse -Force $dir; Write-Ok "deleted $dir" }
    }

    Write-Step 'Uninstalling TightVNC'
    $install = Get-TightVncInstall
    if (-not $install) { Write-Ok 'not installed'; return }
    $code = $install.PSChildName
    if ($code -notmatch '^\{[0-9A-Fa-f-]+\}$') { throw "Couldn't find TightVNC's installer ID; remove it from Settings -> Apps." }
    $process = Start-Process -FilePath msiexec.exe -ArgumentList @('/x', $code, '/quiet', '/norestart') -Wait -PassThru
    if ($process.ExitCode -notin 0, 3010) { throw "Uninstall failed (exit code $($process.ExitCode))." }
    Write-Ok "removed $($install.DisplayName)"
}

switch ($PSCmdlet.ParameterSetName) {
    'Check' { Invoke-Check }
    'Uninstall' { Invoke-Uninstall }
    'Pair' {
        Assert-Admin
        if (-not (Test-Path $GatewayExe)) { throw 'The gateway isn''t installed yet: run this script without -Pair first.' }
        Show-Pairing
    }
    default { Invoke-Install }
}
