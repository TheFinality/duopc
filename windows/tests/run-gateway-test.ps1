# Builds DuoPC Gateway and tests it end to end on 127.0.0.1, against a stand-in VNC server:
# pinned TLS 1.3, pairing token accepted and rejected, blocking after 5 wrong tokens, no plain VNC.
# Uses a temporary data folder and binds to loopback only, so it changes nothing on this PC.
$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot '..\DuoPCGateway\DuoPCGateway.csproj'
$out = Join-Path ([IO.Path]::GetTempPath()) "duopc-gateway-test-$PID"
$env:DUOPC_GATEWAY_DIR = Join-Path $out 'data'
dotnet build $project -c Release -o (Join-Path $out 'bin') --nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw 'build failed' }
$exe = Join-Path $out 'bin\DuoPCGateway.exe'
& $exe config --port 45960 --vnc-port 45901 --listen 127.0.0.1 | Out-Null
$uri = (& $exe pair --host 127.0.0.1 --device 'CI phone' --vnc-password 'test1234' | Select-String '^duopc://').Line
$uriFile = Join-Path $out 'uri.txt'
Set-Content -Path $uriFile -Value $uri -Encoding ascii
$python = (Get-Command python -ErrorAction SilentlyContinue).Source
$vnc = Start-Process $python -ArgumentList @("$PSScriptRoot\fake_vnc.py", 45901, 120) -PassThru -WindowStyle Hidden
$gateway = Start-Process $exe -ArgumentList 'run' -PassThru -WindowStyle Hidden
try {
    Start-Sleep -Seconds 4
    & $python "$PSScriptRoot\gateway_e2e.py" $uriFile
    $code = $LASTEXITCODE
    Get-Content (Join-Path $env:DUOPC_GATEWAY_DIR 'gateway.log')
} finally {
    Stop-Process -Id $gateway.Id, $vnc.Id -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
}
exit $code
