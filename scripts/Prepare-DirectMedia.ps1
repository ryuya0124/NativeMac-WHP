param(
    [Parameter(Mandatory=$true)][string]$HostAddress,
    [string]$OpenSslPath,
    [ValidateRange(1024,65535)][int]$TlsPort = 54887,
    [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$mediaAddress = [Net.IPAddress]::Parse($HostAddress)
if ($mediaAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
    [Net.IPAddress]::IsLoopback($mediaAddress) -or $HostAddress -eq '0.0.0.0') { throw 'Select an explicit Windows IPv4 interface.' }
if ($TlsPort -in @(54883,54884)) { throw 'TLS must have its own port.' }
if (!$OutputDirectory) { $OutputDirectory = Join-Path $projectRoot 'artifacts/direct-media' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$localArtifacts = [IO.Path]::GetFullPath((Join-Path $projectRoot 'artifacts')) + [IO.Path]::DirectorySeparatorChar
if (!$OutputDirectory.StartsWith($localArtifacts,[StringComparison]::OrdinalIgnoreCase)) { throw 'Private transport material must stay in ignored artifacts/.' }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Refusing to replace existing transport keys or configuration.' }
if (!$OpenSslPath) {
    $opensslCommand = Get-Command openssl -ErrorAction SilentlyContinue
    if ($opensslCommand) { $OpenSslPath = $opensslCommand.Source }
    else { $OpenSslPath = Join-Path $env:ProgramFiles 'Git/usr/bin/openssl.exe' }
}
if (!(Test-Path -LiteralPath $OpenSslPath)) { throw 'Supply an installed OpenSSL executable.' }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$mediaAcl = New-Object Security.AccessControl.DirectorySecurity
$mediaIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().User
$mediaAcl.SetOwner($mediaIdentity)
$mediaAcl.SetAccessRuleProtection($true,$false)
$mediaAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($mediaIdentity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
Set-Acl -LiteralPath $OutputDirectory -AclObject $mediaAcl
$certificate = Join-Path $OutputDirectory 'host-certificate.pem'
$privateKey = Join-Path $OutputDirectory 'host-private-key.pem'
& $OpenSslPath req -x509 -newkey rsa:3072 -sha256 -noenc -keyout $privateKey -out $certificate -days 365 `
    -subj '/CN=NativeMacMedia' -addext 'subjectAltName=DNS:NativeMacMedia' -addext 'extendedKeyUsage=serverAuth' `
    2> (Join-Path $OutputDirectory 'certificate-generation.log')
if ($LASTEXITCODE -ne 0) { throw 'Local certificate generation failed.' }
$der = Join-Path $OutputDirectory 'host-certificate.der'
& $OpenSslPath x509 -in $certificate -outform DER -out $der
if ($LASTEXITCODE -ne 0) { throw 'Certificate conversion failed.' }
$pin = (Get-FileHash -LiteralPath $der -Algorithm SHA256).Hash.ToLowerInvariant()
Remove-Item -LiteralPath $der
$secret = New-Object byte[] 32
$generator = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $generator.GetBytes($secret) } finally { $generator.Dispose() }
[IO.File]::WriteAllBytes((Join-Path $OutputDirectory 'client-secret.bin'),$secret)
$secretHex = ([BitConverter]::ToString($secret)).Replace('-','').ToLowerInvariant()
@{listenAddress=$HostAddress;listenPort=$TlsPort;certificate='host-certificate.pem';privateKey='host-private-key.pem';secretFile='client-secret.bin';codecPort=54883;audioPort=54884} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'host.json')
@{hostAddress=$HostAddress;hostPort=$TlsPort;certificate='host-certificate.pem';certificateSHA256=$pin;secret=$secretHex;audio=$true} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'guest.json')
Write-Output "Prepared private direct-media configuration in $OutputDirectory. No credentials were printed."
