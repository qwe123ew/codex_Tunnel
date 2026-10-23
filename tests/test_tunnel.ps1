$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$module = Join-Path $root 'TunnelTools.ps1'
if (-not (Test-Path -LiteralPath $module)) { throw 'FAIL: generic profile/config helpers have not been implemented.' }
. $module
$script:passed = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
}
function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-True $rejected $Message
}
function New-TestProfile {
    return [pscustomobject]@{
        version = 1
        server = [pscustomobject]@{ host = 'gpu.example.org'; user = 'alice'; port = 2222; identityFile = '' }
        jumpHosts = @(
            [pscustomobject]@{ host = 'gate.example.org'; user = 'bob'; port = 2200; identityFile = '' },
            [pscustomobject]@{ host = '10.0.0.8'; user = 'carol'; port = 22; identityFile = '' }
        )
        remotePort = 11082
        checkIntervalSeconds = 60
    }
}
$profile = New-TestProfile
Assert-TunnelProfile $profile
$text = New-TunnelSshConfig -Profile $profile -ProxyUrl 'http://127.0.0.1:7897'
Assert-True ($text -match 'HostName gpu.example.org') 'custom server is preserved'
Assert-True ($text -match 'User alice') 'custom user is preserved'
Assert-True ($text -match 'Port 2222') 'custom SSH port is preserved'
Assert-True ($text -match 'ProxyJump portable-jump-1,portable-jump-2') 'ordered independent jumps'
Assert-True ($text -match 'RemoteForward 127.0.0.1:11082 127.0.0.1:7897') 'auto proxy port mapped only to remote loopback'
Assert-True (($text | Select-String 'RemoteForward' -AllMatches).Matches.Count -eq 1) 'one forwarding declaration'
Assert-True ($text -notmatch 'StrictHostKeyChecking no|UserKnownHostsFile|ProxyCommand|Include ') 'no host-key bypass or inherited global configuration'
$v6 = New-TunnelSshConfig -Profile $profile -ProxyUrl 'http://[::1]:7897'
Assert-True ($v6 -match 'RemoteForward 127.0.0.1:11082 \[::1\]:7897') 'IPv6 local proxy preserved'
$noKey = New-TestProfile; $noKey.server.identityFile = 'none'
$noKeyConfig = New-TunnelSshConfig -Profile $noKey -ProxyUrl 'http://127.0.0.1:7897'
Assert-True ($noKeyConfig -match 'IdentityFile "none"') 'explicit IdentityFile none survives import'
foreach ($bad in @("host`nProxyCommand bad", '-oProxyCommand=bad', 'user@host', 'host/name', 'host name')) {
    $p = New-TestProfile; $p.server.host = $bad
    Assert-Rejected { Assert-TunnelProfile $p } "reject host injection: $bad"
}
foreach ($bad in @("alice`r`n", '-root', 'a b', 'a;cmd', '$(cmd)')) {
    $p = New-TestProfile; $p.server.user = $bad
    Assert-Rejected { Assert-TunnelProfile $p } 'reject unsafe user'
}
foreach ($bad in @(0, -1, 65536, 22.5, '22x', "22`n")) {
    $p = New-TestProfile; $p.server.port = $bad
    Assert-Rejected { Assert-TunnelProfile $p } 'reject invalid port'
}
$p = New-TestProfile; $p.remotePort = 80
Assert-Rejected { Assert-TunnelProfile $p } 'remote listener cannot require privileged port'
$p = New-TestProfile; $p.checkIntervalSeconds = 0
Assert-Rejected { Assert-TunnelProfile $p } 'reject busy-loop monitor interval'
$p = New-TestProfile; $p.server | Add-Member password 'do-not-save'
Assert-Rejected { Assert-TunnelProfile $p } 'reject password in profile'
$p = New-TestProfile; $p.server.host = '2001:db8::1'; Assert-TunnelProfile $p
Assert-True $true 'IPv6 destination supported'
foreach ($url in @('http://evil.example:7890', 'http://u:p@127.0.0.1:7890', 'socks5://127.0.0.1:7890', 'http://127.0.0.1:7890/path')) {
    Assert-Rejected { New-TunnelSshConfig -Profile $profile -ProxyUrl $url } 'reject invalid/nonlocal proxy'
}
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('tunnel tests space ' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
try {
    $settingsPath = Join-Path $scratch 'settings.json'
    Save-TunnelProfile -Profile $profile -Path $settingsPath
    $loaded = Read-TunnelProfile -Path $settingsPath
    Assert-True ($loaded.server.user -eq 'alice' -and $loaded.jumpHosts.Count -eq 2) 'JSON profile round trip'
    Assert-True ([IO.File]::ReadAllText($settingsPath) -notmatch 'password|token') 'profile contains no credentials'
    $replacement = New-TestProfile; $replacement.remotePort = 11083
    Save-TunnelProfile -Profile $replacement -Path $settingsPath
    $reloaded = Read-TunnelProfile -Path $settingsPath
    Assert-True ($reloaded.remotePort -eq 11083) 'existing profile atomically overwritten on PowerShell 5.1'
    Assert-True (@(Get-ChildItem -LiteralPath $scratch -Filter '*.tmp').Count -eq 0) 'profile overwrite leaves no temporary files'
    $sshConfig = Join-Path $scratch 'ssh config'
    [IO.File]::WriteAllText($sshConfig, $text, (New-Object Text.UTF8Encoding $false))
    $ssh = (Get-Command ssh.exe).Source
    $effective = @(& $ssh -G -F $sshConfig portable-target 2>$null)
    Assert-True ($LASTEXITCODE -eq 0) 'OpenSSH accepts isolated config with spaces'
    Assert-True ($effective -contains 'hostname gpu.example.org') 'OpenSSH resolves target'
    Assert-True ($effective -contains 'user alice') 'OpenSSH resolves target user'
    Assert-True ($effective -contains 'port 2222') 'OpenSSH resolves target SSH port'
    $jump = @(& $ssh -G -F $sshConfig portable-jump-1 2>$null)
    Assert-True ($LASTEXITCODE -eq 0) 'OpenSSH accepts jump config'
    Assert-True ($jump -contains 'user bob') 'jump uses its own user'
    Assert-True (-not ($jump -match '^remoteforward ')) 'jump cannot inherit remote forwarding'
    Assert-True (-not ($jump -match '^proxyjump ')) 'jump has no recursive jump configuration'
} finally {
    if ([IO.Path]::GetFullPath($scratch).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
}
Write-Host "PASS: $script:passed tunnel/profile checks"
