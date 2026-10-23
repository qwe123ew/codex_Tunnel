# PowerShell 5.1 compatible; this module never changes global configuration.
function Assert-AllowedFields {
    param($Value, [string[]]$Allowed, [string]$Label)
    if ($null -eq $Value) { throw "$Label is missing." }
    $names = if ($Value -is [System.Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties.Name) }
    foreach ($name in $names) {
        if ($name -notin $Allowed) { throw "$Label contains an unsupported field. Do not store passwords or tokens in settings.json." }
    }
}

function Assert-PortNumber {
    param($Value, [int]$Minimum = 1, [string]$Label = 'Port')
    if ([string]$Value -notmatch '\A[0-9]{1,5}\z') { throw "$Label must be an integer." }
    if ([int]$Value -lt $Minimum -or [int]$Value -gt 65535) { throw "$Label must be between $Minimum and 65535." }
}

function Assert-SshEndpoint {
    param($Endpoint, [string]$Label)
    Assert-AllowedFields $Endpoint @('host', 'user', 'port', 'identityFile') $Label
    $address = [string]$Endpoint.host
    $parsedAddress = $null
    $validIp = [Net.IPAddress]::TryParse($address, [ref]$parsedAddress)
    $validDns = $address -match '\A[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?\z'
    if ($address.Length -gt 253 -or (-not $validIp -and -not $validDns) -or $address -match '[\s\[\]]') {
        throw "$Label host must be an IP address or a DNS hostname, without a username, port, spaces or shell commands."
    }
    if ([string]$Endpoint.user -notmatch '\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}\z') {
        throw "$Label user must contain only letters, digits, underscore, dot or hyphen."
    }
    Assert-PortNumber $Endpoint.port 1 "$Label SSH port"
    $keyPath = [string]$Endpoint.identityFile
    if ($keyPath -and $keyPath -ine 'none') {
        if ($keyPath -match '[\r\n"%\x00]') { throw "$Label identityFile contains unsupported characters." }
        if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) { throw "$Label identityFile is not present on this computer. Reconfigure or remove that optional path." }
    }
}

function Assert-TunnelProfile {
    param($Profile)
    Assert-AllowedFields $Profile @('version', 'server', 'jumpHosts', 'remotePort', 'checkIntervalSeconds') 'Profile'
    if ([string]$Profile.version -cne '1') { throw 'Unsupported settings version; expected version 1.' }
    Assert-SshEndpoint $Profile.server 'Server'
    $jumps = @($Profile.jumpHosts)
    if ($jumps.Count -gt 4) { throw 'At most four jump hosts are supported.' }
    $number = 0
    foreach ($jump in $jumps) {
        if ($null -eq $jump) { throw 'jumpHosts must be an array; use [] when no jump host is needed.' }
        $number++
        Assert-SshEndpoint $jump "Jump host $number"
    }
    Assert-PortNumber $Profile.remotePort 1024 'Remote proxy port'
    if ([string]$Profile.checkIntervalSeconds -notmatch '\A[0-9]{1,5}\z' -or [int]$Profile.checkIntervalSeconds -lt 10 -or [int]$Profile.checkIntervalSeconds -gt 86400) {
        throw 'checkIntervalSeconds must be between 10 and 86400.'
    }
}

function Read-TunnelProfile {
    param([string]$Path)
    $profile = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-TunnelProfile $profile
    return $profile
}

function Save-TunnelProfile {
    param($Profile, [string]$Path)
    Assert-TunnelProfile $Profile
    $json = $Profile | ConvertTo-Json -Depth 6
    $tempPath = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($tempPath, $json, (New-Object Text.UTF8Encoding $false))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tempPath, $Path, [NullString]::Value) }
        else { [IO.File]::Move($tempPath, $Path) }
    } finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
    }
}

function New-TunnelSshConfig {
    param($Profile, [string]$ProxyUrl, [switch]$NoForward)
    Assert-TunnelProfile $Profile
    if ($NoForward) { $ProxyUrl = 'http://127.0.0.1:1' }
    $uri = $null
    if (-not [Uri]::TryCreate($ProxyUrl, [UriKind]::Absolute, [ref]$uri)) { throw 'Invalid local proxy URL.' }
    $proxyIp = $null
    $isV6Loopback = [Net.IPAddress]::TryParse($uri.Host.Trim([char[]]'[]'), [ref]$proxyIp) -and $proxyIp.Equals([Net.IPAddress]::IPv6Loopback)
    if ($uri.Scheme -ne 'http' -or ($uri.Host -notin @('127.0.0.1', 'localhost') -and -not $isV6Loopback) -or $uri.UserInfo -or $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment) {
        throw 'Only an unauthenticated loopback HTTP proxy is supported.'
    }
    Assert-PortNumber $uri.Port
    $proxyAddress = if ($isV6Loopback) { '[::1]' } elseif ($uri.Host -eq 'localhost') { '127.0.0.1' } else { $uri.Host }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('Host portable-target')
    $lines.Add('  HostName ' + $Profile.server.host)
    $lines.Add('  User ' + $Profile.server.user)
    $lines.Add('  Port ' + $Profile.server.port)
    if ($Profile.server.identityFile) { $lines.Add('  IdentityFile "' + ([string]$Profile.server.identityFile).Replace('\', '/') + '"') }
    $jumpNames = @()
    for ($i = 0; $i -lt @($Profile.jumpHosts).Count; $i++) { $jumpNames += 'portable-jump-' + ($i + 1) }
    if ($jumpNames.Count -gt 0) { $lines.Add('  ProxyJump ' + ($jumpNames -join ',')) }
    if (-not $NoForward) {
        $lines.Add('  RemoteForward 127.0.0.1:' + $Profile.remotePort + ' ' + $proxyAddress + ':' + $uri.Port)
        $lines.Add('  ExitOnForwardFailure yes')
    }
    for ($i = 0; $i -lt $jumpNames.Count; $i++) {
        $jump = @($Profile.jumpHosts)[$i]
        $lines.Add('')
        $lines.Add('Host ' + $jumpNames[$i])
        $lines.Add('  HostName ' + $jump.host)
        $lines.Add('  User ' + $jump.user)
        $lines.Add('  Port ' + $jump.port)
        if ($jump.identityFile) { $lines.Add('  IdentityFile "' + ([string]$jump.identityFile).Replace('\', '/') + '"') }
    }
    $lines.Add('')
    $lines.Add('Host *')
    $lines.Add('  ForwardAgent no')
    $lines.Add('  ForwardX11 no')
    $lines.Add('  ServerAliveInterval 30')
    $lines.Add('  ServerAliveCountMax 3')
    $lines.Add('  ConnectTimeout 15')
    $lines.Add('  ConnectionAttempts 1')
    $lines.Add('  NumberOfPasswordPrompts 3')
    return ($lines -join "`n") + "`n"
}

function Get-RemoteMonitorCommand {
    param([int]$Port, [int]$Interval)
    Assert-PortNumber $Port 1024
    if ($Interval -lt 10 -or $Interval -gt 86400) { throw 'Invalid monitor interval.' }
    # PowerShell 5.1 may add CRLF to native stdin. Remove CR on the remote side.
    # Only validated numeric values enter this shell command; no profile text is interpolated.
    return "tr -d '\r' | sh -s -- $Port $Interval"
}

function Get-RemoteVscodeCommand {
    param([int]$Port)
    Assert-PortNumber $Port 1024
    return "tr -d '\r' | sh -s -- $Port"
}

function Find-TunnelProgram {
    param([ValidateSet('ssh', 'curl')][string]$Name)
    $preferred = if ($Name -eq 'ssh') { Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe' } else { Join-Path $env:SystemRoot 'System32\curl.exe' }
    if (Test-Path -LiteralPath $preferred -PathType Leaf) { return $preferred }
    $command = Get-Command ($Name + '.exe') -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { throw "$Name.exe is missing. Install/enable Windows OpenSSH Client or curl; this launcher does not download software automatically." }
    return $command.Source
}
