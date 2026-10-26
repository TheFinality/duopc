<#
.SYNOPSIS
    Sets up a Windows PC for DuoPC: installs the TightVNC server, sets its password, and lets in
    only your Tailscale devices.

.DESCRIPTION
    Run once, in an elevated PowerShell (Run as administrator):

        powershell -ExecutionPolicy Bypass -File .\Setup-DuoPC.ps1

    What it does:
      1. Downloads TightVNC 2.8.85 (free, GPL) from tightvnc.com and checks its digital signature.
      2. Installs only the server, as a Windows service, so it works at the sign-in screen, the lock
         screen and UAC prompts too.
      3. Sets the VNC password (up to 8 characters; that's the VNC protocol's limit), turns off the
         Java web viewer, and lets in connections only from Tailscale addresses (100.64.0.0/10).
      4. Adds a Windows Firewall rule for the VNC port that allows only Tailscale addresses, and
         turns off any older TightVNC rule that allowed everyone.
      5. Prints the name and port to enter in the app.

    TightVNC 2.8 is used on purpose: TightVNC 4 moves passwords to its own sign-in method, which
    other VNC apps (including DuoPC) can't use.

.PARAMETER Check
    Changes nothing. Reports whether TightVNC, the firewall rule and Tailscale are set up, and
    whether the server answers like a VNC server should.

.PARAMETER Uninstall
    Removes the DuoPC firewall rule and uninstalls TightVNC.

.PARAMETER AllowLan
    Also allow devices on your local network (not just Tailscale). VNC isn't encrypted, so only do
    this on a network you trust.

.PARAMETER Port
    The VNC port. Default 5900.
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Check')] [switch] $Check,
    [Parameter(ParameterSetName = 'Uninstall')] [switch] $Uninstall,
    [Parameter(ParameterSetName = 'Install')] [switch] $AllowLan,
    [Parameter(ParameterSetName = 'Install')] [Parameter(ParameterSetName = 'Check')]
    [ValidateRange(1, 65535)] [int] $Port = 5900
)

$ErrorActionPreference = 'Stop'

$TightVncVersion = '2.8.85'
$FirewallRuleName = 'DuoPC-VNC'
$FirewallRuleDisplay = 'DuoPC VNC server'
$TailscaleV4 = '100.64.0.0/10'
$TailscaleV6 = 'fd7a:115c:a1e0::/48'
# TightVNC's own access list: allow Tailscale's range, deny everything else.
$TailscaleAcl = '100.64.0.0-100.127.255.255:0'
$LanAcl = '10.0.0.0-10.255.255.255:0,172.16.0.0-172.31.255.255:0,192.168.0.0-192.168.255.255:0'
$DenyAllAcl = '0.0.0.0-255.255.255.255:1'

function Write-Step([string] $text) { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Write-Ok([string] $text) { Write-Host "    [ok] $text" -ForegroundColor Green }
function Write-Warn([string] $text) { Write-Host "    [!]  $text" -ForegroundColor Yellow }
function Write-Bad([string] $text) { Write-Host "    [x]  $text" -ForegroundColor Red }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TightVncInstall {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'TightVNC*' } |
        Select-Object -First 1
}

function Get-TailscaleExe {
    $candidates = @("$env:ProgramFiles\Tailscale\tailscale.exe", "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe")
    $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($cmd) { $candidates = @($cmd.Source) + $candidates }
    $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}

# This PC's Tailscale name and IPv4 address, or $null when Tailscale isn't running.
function Get-TailscaleSelf {
    $exe = Get-TailscaleExe
    if (-not $exe) { return $null }
    try {
        $status = & $exe status --json 2>$null | Out-String | ConvertFrom-Json
    } catch { return $null }
    if (-not $status -or -not $status.Self) { return $null }
    $ipv4 = @($status.Self.TailscaleIPs) | Where-Object { $_ -notlike '*:*' } | Select-Object -First 1
    $dns = "$($status.Self.DNSName)".TrimEnd('.')
    [pscustomobject]@{
        State     = $status.BackendState
        IPv4      = $ipv4
        DnsName   = $dns
        ShortName = if ($dns) { $dns.Split('.')[0] } else { $status.Self.HostName }
    }
}

# Connects and reads as far as the server's list of sign-in types (no password is sent), then
# hangs up. Classic VNC password sign-in is type 2.
function Test-RfbServer([string] $Address, [int] $Port, [int] $TimeoutMs = 4000) {
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

        $banner = [Text.Encoding]::ASCII.GetString((& $readExactly 12))
        if ($banner -notmatch '^RFB (\d{3})\.(\d{3})\n$') { throw "not a VNC server (it said '$($banner.Trim())')" }
        $major = [int]$Matches[1]; $minor = [int]$Matches[2]

        $types = @()
        if ($major -eq 3 -and $minor -lt 7) {
            # 3.3: the server picks the type itself, as a 4-byte number.
            $stream.Write([Text.Encoding]::ASCII.GetBytes("RFB 003.003`n"), 0, 12)
            $raw = & $readExactly 4
            [Array]::Reverse($raw)
            $types = @([BitConverter]::ToUInt32($raw, 0))
        } else {
            $reply = if ($minor -ge 8 -or $major -gt 3) { "RFB 003.008`n" } else { "RFB 003.007`n" }
            $stream.Write([Text.Encoding]::ASCII.GetBytes($reply), 0, 12)
            $count = (& $readExactly 1)[0]
            if ($count -eq 0) {
                $raw = & $readExactly 4
                [Array]::Reverse($raw)
                $length = [BitConverter]::ToUInt32($raw, 0)
                $reason = if ($length -gt 0 -and $length -lt 4096) { [Text.Encoding]::UTF8.GetString((& $readExactly $length)) } else { '' }
                throw "the server refused the connection: $reason"
            }
            $types = @((& $readExactly $count) | ForEach-Object { [int]$_ })
        }
        [pscustomobject]@{
            Version          = "$major.$minor"
            SecurityTypes    = $types
            HasVncPassword   = $types -contains 2
            HasNoSignIn      = $types -contains 1
        }
    } finally {
        $client.Close()
    }
}

function New-VncPassword {
    # No look-alikes (0/O, 1/l/I), so it's easy to type on the phone.
    $alphabet = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = New-Object byte[] 8
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
}

function ConvertTo-PlainText([Security.SecureString] $secure) {
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Read-VncPassword {
    Write-Host '    Choose the VNC password the app will use (1-8 characters).'
    Write-Host '    Press Enter on its own to have one made up for you.'
    while ($true) {
        $first = ConvertTo-PlainText (Read-Host '    Password' -AsSecureString)
        if ($first.Length -eq 0) {
            $generated = New-VncPassword
            Write-Host "    Your VNC password is: $generated" -ForegroundColor Magenta
            Write-Host '    Write it down: you will type it into the app once.'
            return $generated
        }
        if ($first.Length -gt 8) { Write-Warn 'VNC passwords are at most 8 characters. Try again.'; continue }
        if ($first.Contains('"')) { Write-Warn "Leave out the "" character. Try again."; continue }
        $second = ConvertTo-PlainText (Read-Host '    Same again' -AsSecureString)
        if ($first -ne $second) { Write-Warn "They don't match. Try again."; continue }
        return $first
    }
}

function Invoke-Check {
    $healthy = $true

    Write-Step 'TightVNC'
    $install = Get-TightVncInstall
    if ($install) {
        Write-Ok "installed: $($install.DisplayName) $($install.DisplayVersion)"
        if ("$($install.DisplayVersion)" -like '4.*') { Write-Warn 'TightVNC 4 may only offer its own sign-in; run this script again to install 2.8.'; $healthy = $false }
    } else { Write-Bad 'not installed (run this script without -Check)'; $healthy = $false }

    $service = Get-Service -Name tvnserver -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Running') { Write-Ok 'service running' }
    elseif ($service) { Write-Bad "service is $($service.Status)"; $healthy = $false }
    else { Write-Bad 'service not found'; $healthy = $false }

    $listening = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    if ($listening) { Write-Ok "listening on port $Port" } else { Write-Bad "nothing is listening on port $Port"; $healthy = $false }

    Write-Step 'Windows Firewall'
    $rule = Get-NetFirewallRule -Name $FirewallRuleName -ErrorAction SilentlyContinue
    if ($rule -and $rule.Enabled -eq 'True') {
        $remote = ($rule | Get-NetFirewallAddressFilter).RemoteAddress -join ', '
        Write-Ok "rule '$FirewallRuleDisplay' allows: $remote"
    } else { Write-Bad "rule '$FirewallRuleDisplay' missing or off"; $healthy = $false }
    $open = Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*TightVNC*' }
    foreach ($r in $open) { Write-Warn "another rule is also on: '$($r.DisplayName)'" }

    Write-Step 'Tailscale'
    $self = Get-TailscaleSelf
    if (-not $self) { Write-Bad 'not installed or not running: get it from https://tailscale.com/download'; $healthy = $false }
    elseif ($self.State -ne 'Running') { Write-Bad "Tailscale is $($self.State): open it and sign in"; $healthy = $false }
    else {
        Write-Ok "this PC is '$($self.ShortName)' ($($self.IPv4)) on your tailnet"
        Write-Step 'VNC server answering over Tailscale'
        try {
            $probe = Test-RfbServer -Address $self.IPv4 -Port $Port
            Write-Ok "VNC protocol $($probe.Version), sign-in types: $($probe.SecurityTypes -join ', ')"
            if ($probe.HasVncPassword) { Write-Ok 'offers a VNC password sign-in, which DuoPC uses' }
            else { Write-Bad "doesn't offer a VNC password sign-in (type 2)"; $healthy = $false }
            if ($probe.HasNoSignIn) { Write-Warn 'also lets people in without a password' }
        } catch {
            Write-Bad $_.Exception.Message
            Write-Warn 'If the server hung up straight away, TightVNC may be treating a test from this PC as a loopback'
            Write-Warn 'connection, which it refuses. Try connecting from the phone instead.'
            $healthy = $false
        }
    }

    Write-Host ''
    if ($healthy) { Write-Host 'All good.' -ForegroundColor Green } else { Write-Host 'Something needs attention (see above).' -ForegroundColor Yellow }
}

function Invoke-Install {
    if (-not (Test-Admin)) { throw 'Run this in PowerShell opened with "Run as administrator".' }

    Write-Step 'Checking Tailscale'
    $self = Get-TailscaleSelf
    if ($self -and $self.State -eq 'Running') { Write-Ok "this PC is '$($self.ShortName)' ($($self.IPv4))" }
    else {
        Write-Warn 'Tailscale is not running on this PC. Install it from https://tailscale.com/download'
        Write-Warn 'and sign in with the same account as your phone. You can do that after this script.'
    }

    $existing = Get-TightVncInstall
    if ($existing -and "$($existing.DisplayVersion)" -like '4.*') {
        Write-Warn "TightVNC $($existing.DisplayVersion) is installed. Remove it first (Settings -> Apps), or run this script with -Uninstall, then run it again."
        throw 'TightVNC 4 is installed.'
    }

    Write-Step 'VNC password'
    $password = Read-VncPassword

    Write-Step "Downloading TightVNC $TightVncVersion"
    $arch = if ([Environment]::Is64BitOperatingSystem) { '64bit' } else { '32bit' }
    $url = "https://www.tightvnc.com/download/$TightVncVersion/tightvnc-$TightVncVersion-gpl-setup-$arch.msi"
    $dir = Join-Path $env:TEMP 'DuoPC'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $msi = Join-Path $dir "tightvnc-$TightVncVersion-$arch.msi"
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing
    Write-Ok "$url"

    $signature = Get-AuthenticodeSignature -FilePath $msi
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'GlavSoft') {
        Remove-Item $msi -Force
        throw "The installer's signature didn't check out ($($signature.Status), $($signature.SignerCertificate.Subject)). Nothing was installed."
    }
    Write-Ok "signed by $($signature.SignerCertificate.GetNameInfo('SimpleName', $false))"

    Write-Step 'Installing the TightVNC server'
    $acl = if ($AllowLan) { "$TailscaleAcl,$LanAcl,$DenyAllAcl" } else { "$TailscaleAcl,$DenyAllAcl" }
    $properties = @(
        'ADDLOCAL=Server',
        'SERVER_REGISTER_AS_SERVICE=1',
        'SERVER_ADD_FIREWALL_EXCEPTION=0',      # our own, narrower rule below
        'SERVER_ALLOW_SAS=1',                   # Ctrl+Alt+Del from the app
        'SET_USEVNCAUTHENTICATION=1', 'VALUE_OF_USEVNCAUTHENTICATION=1',
        'SET_PASSWORD=1', "VALUE_OF_PASSWORD=`"$password`"",
        'SET_ACCEPTRFBCONNECTIONS=1', 'VALUE_OF_ACCEPTRFBCONNECTIONS=1',
        'SET_ACCEPTHTTPCONNECTIONS=1', 'VALUE_OF_ACCEPTHTTPCONNECTIONS=0',
        "SET_RFBPORT=1", "VALUE_OF_RFBPORT=$Port",
        'SET_IPACCESSCONTROL=1', "VALUE_OF_IPACCESSCONTROL=`"$acl`"",
        'SET_ALWAYSSHARED=1', 'VALUE_OF_ALWAYSSHARED=1'
    )
    $arguments = @('/i', "`"$msi`"", '/quiet', '/norestart') + $properties
    $process = Start-Process -FilePath msiexec.exe -ArgumentList $arguments -Wait -PassThru
    $password = $null
    Remove-Item $msi -Force -ErrorAction SilentlyContinue
    if ($process.ExitCode -notin 0, 3010) { throw "The TightVNC installer failed (exit code $($process.ExitCode))." }
    Write-Ok 'installed as a service'
    if ($process.ExitCode -eq 3010) { Write-Warn 'Windows wants a restart to finish; restart when convenient.' }

    $service = Get-Service -Name tvnserver -ErrorAction SilentlyContinue
    if ($service) {
        Set-Service -Name tvnserver -StartupType Automatic
        if ($service.Status -ne 'Running') { Start-Service -Name tvnserver }
        Write-Ok 'service running, starts with Windows'
    } else { Write-Warn "the TightVNC service wasn't found; restart the PC and run this script with -Check" }

    Write-Step 'Windows Firewall'
    Get-NetFirewallRule -Name $FirewallRuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    $remote = @($TailscaleV4, $TailscaleV6)
    if ($AllowLan) { $remote += 'LocalSubnet' }
    New-NetFirewallRule -Name $FirewallRuleName -DisplayName $FirewallRuleDisplay `
        -Description 'Lets DuoPC reach the TightVNC server. Added by Setup-DuoPC.ps1.' `
        -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -RemoteAddress $remote -Profile Any | Out-Null
    Write-Ok "port $Port open to: $($remote -join ', ')"
    # Rules from an earlier TightVNC install let in any address; ours is the only way in now.
    Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*TightVNC*' } |
        ForEach-Object {
            Disable-NetFirewallRule -Name $_.Name
            Write-Ok "turned off the older rule '$($_.DisplayName)'"
        }

    Write-Step 'Done. In DuoPC on your phone, tap + and enter:'
    $self = Get-TailscaleSelf
    $hostName = if ($self -and $self.ShortName) { $self.ShortName } else { '<this PC''s Tailscale name>' }
    Write-Host "      Hostname:  $hostName" -ForegroundColor White
    if ($self -and $self.IPv4) { Write-Host "                 (or $($self.IPv4))" -ForegroundColor DarkGray }
    Write-Host "      Port:      $Port" -ForegroundColor White
    Write-Host '      Password:  the VNC password from above (leave the username empty)' -ForegroundColor White
    Write-Host ''
    Write-Host '    Check everything any time with:  .\Setup-DuoPC.ps1 -Check'
}

function Invoke-Uninstall {
    if (-not (Test-Admin)) { throw 'Run this in PowerShell opened with "Run as administrator".' }
    Write-Step 'Removing the firewall rule'
    $rule = Get-NetFirewallRule -Name $FirewallRuleName -ErrorAction SilentlyContinue
    if ($rule) { $rule | Remove-NetFirewallRule; Write-Ok 'removed' } else { Write-Ok 'there was none' }

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
    default { Invoke-Install }
}
