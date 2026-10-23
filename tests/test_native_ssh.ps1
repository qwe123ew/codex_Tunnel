$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'ProxyTools.ps1')
. (Join-Path $root 'TunnelTools.ps1')
. (Join-Path $root 'SshImport.ps1')
$script:passed = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
}
function Assert-Rejected([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $failure = ''
    try { & $Action | Out-Null } catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match $Pattern) $Message
}
function Write-Fixture([string]$Name, [string]$Text) {
    $path = Join-Path $scratch $Name
    [void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
    [IO.File]::WriteAllText($path, $Text, (New-Object Text.UTF8Encoding $false))
    $acl = New-Object Security.AccessControl.FileSecurity
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetOwner($sid); $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')))
    Set-Acl -LiteralPath $path -AclObject $acl
    return $path
}
function Get-Effective([string[]]$Arguments) {
    $result = Invoke-ProxyProcess -FileName $ssh -Arguments (@('-G') + $Arguments) -TimeoutSeconds 10
    Assert-True ($result.ExitCode -eq 0 -and -not $result.TimedOut) 'native ssh -G parses generated configuration without login'
    return $result.Output
}
$ssh = Find-TunnelProgram ssh
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('native ssh tests ' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
try {
    $firstKey = Write-Fixture 'keys/one' 'fixture-not-a-private-key'
    $secondKey = Write-Fixture 'keys/two' 'fixture-not-a-private-key'
    $config = Write-Fixture 'native.conf' @"
Host configured
    HostName gpu.example.org
    User researcher
    Port 2222
    IdentitiesOnly yes
    IdentityFile "$($firstKey.Replace('\', '/'))"
    IdentityFile "$($secondKey.Replace('\', '/'))"
    IdentityFile "$($scratch.Replace('\', '/'))/missing-key"
    HostKeyAlias configured-key
    PreferredAuthentications publickey,password
    LocalForward 32101 localhost:80
    RemoteForward 32102 localhost:81
    DynamicForward 32103
    ClearAllForwardings yes
    RemoteCommand command-must-not-run
    LocalCommand local-command-must-not-run
    PermitLocalCommand yes
    RequestTTY force
    ControlMaster auto
    ControlPath control-path-must-not-be-used
    ControlPersist yes
"@
    $original = [IO.File]::ReadAllBytes($config)
    $native = Get-NativeSshProfile -Alias configured -ConfigPath $config -SshPath $ssh
    Assert-True ($native.Host -eq 'gpu.example.org' -and $native.User -eq 'researcher' -and $native.Port -eq 2222) 'native display reads the real endpoint despite specialized auth and multiple keys'
    Assert-True ($native.NativeAlias -eq 'configured' -and $native.NativeConfigPath -eq $config -and $native.NativeSshPath -eq $ssh) 'native source references are retained'
    $ownedPreview = Join-Path $scratch 'caller owned preview'
    [void][IO.Directory]::CreateDirectory($ownedPreview)
    $native = Get-NativeSshProfile -Alias configured -ConfigPath $config -SshPath $ssh -PreviewDirectory $ownedPreview
    Assert-True ($native.Host -eq 'gpu.example.org' -and -not (Test-Path -LiteralPath $ownedPreview)) 'caller-owned preview snapshots are cleaned after a successful import'
    $snapshotDirectory = Join-Path $scratch 'snapshot one'
    $snapshot = New-NativeTunnelConfig -ConfigPath $config -DestinationDirectory $snapshotDirectory
    $arguments = @(New-NativeSshArguments -ConfigPath $snapshot.RootPath -Alias configured -RemotePort 11082 -ProxyUrl 'http://127.0.0.1:7897')
    $effective = Get-Effective $arguments
    Assert-True ($effective -match '(?m)^identitiesonly yes\r?$' -and $effective -match '(?m)^hostkeyalias configured-key\r?$') 'authentication and host-key settings are preserved'
    Assert-True ((@($effective -split '\r?\n' | Where-Object { $_ -match '^identityfile ' })).Count -eq 3) 'multiple and missing identity file references remain native SSH choices'
    Assert-True ($effective -notmatch '32101|32102|32103|command-must-not-run|control-path-must-not-be-used') 'old forwarding, local/remote commands and multiplexing are removed'
    Assert-True ($effective -match '(?m)^remoteforward \[?127\.0\.0\.1\]?:11082 \[?127\.0\.0\.1\]?:7897\r?$' -and @($effective -split '\r?\n' | Where-Object { $_ -match '^remoteforward ' }).Count -eq 1) 'only the requested loopback reverse proxy forward is present'
    Assert-True ($effective -match '(?m)^clearallforwardings no\r?$' -and $effective -match '(?m)^exitonforwardfailure yes\r?$') 'own forwarding is not cleared and a bind failure stops launch'
    Assert-True ($effective -match '(?m)^requesttty false\r?$|(?m)^requesttty no\r?$' -and $effective -match '(?m)^controlmaster false\r?$|(?m)^controlmaster no\r?$') 'native tunnel runs without TTY or shared SSH master'
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($config)) -ceq [Convert]::ToBase64String($original)) 'source SSH config remains byte-identical'

    $config = Write-Fixture 'proxy-command.conf' @'
Host via-command
    HostName internal.example.org
    User user-name
    ProxyCommand command-that-does-not-exist --private-placeholder %h %p
    IdentityFile none
'@
    $native = Get-NativeSshProfile via-command $config $ssh
    Assert-True ($native.Host -eq 'internal.example.org' -and $native.Route -match 'ProxyCommand') 'ProxyCommand is described without executing it during preview'
    Assert-True ($native.Route -notmatch 'private-placeholder|command-that-does-not-exist') 'ProxyCommand text is not exposed in the GUI route'
    $snapshot = New-NativeTunnelConfig $config (Join-Path $scratch 'snapshot command')
    $effective = Get-Effective @('-F', $snapshot.RootPath, '--', 'via-command')
    Assert-True ($effective -match '(?m)^proxycommand command-that-does-not-exist --private-placeholder %h %p\r?$') 'configured ProxyCommand is preserved for an explicit connection'

    $config = Write-Fixture 'nested.conf' @'
Host nested-target
    HostName gpu.internal
    User target
    ProxyJump last-hop
Host last-hop
    HostName last.internal
    User last
    ProxyJump first-hop
Host first-hop
    HostName first.example.org
    User first
Host *
    IdentityFile none
'@
    $native = Get-NativeSshProfile nested-target $config $ssh
    Assert-True ($native.Host -eq 'gpu.internal' -and $native.Route -match 'last-hop') 'nested jump configuration no longer blocks target display'
    $snapshot = New-NativeTunnelConfig $config (Join-Path $scratch 'snapshot nested')
    $effective = Get-Effective @('-F', $snapshot.RootPath, '--', 'last-hop')
    Assert-True ($effective -match '(?m)^proxyjump first-hop\r?$') 'native snapshot retains nested jump rules'

    $included = Write-Fixture 'include space/details.conf' @'
Host shared
    HostName included.example.org
Match originalhost shared
    User matched-user
    Port 2208
    RemoteForward 32109 localhost:82
Host *
    IdentitiesOnly yes
'@
    $config = Write-Fixture 'include-root.conf' ("Include `"$($included.Replace('\', '/'))`"`nHost shared`n  User later-user`n  IdentityFile none`n")
    $native = Get-NativeSshProfile shared $config $ssh
    Assert-True ($native.Host -eq 'included.example.org' -and $native.User -eq 'matched-user' -and $native.Port -eq 2208) 'Include ordering and Match originalhost semantics are preserved'
    $snapshot = New-NativeTunnelConfig $config (Join-Path $scratch 'snapshot include')
    Assert-True (@($snapshot.Files).Count -eq 2) 'root and included files are independently snapshotted'
    $rootText = [IO.File]::ReadAllText($snapshot.RootPath)
    Assert-True ($rootText -notmatch [regex]::Escape($included.Replace('\', '/'))) 'all Include references point to owned snapshot files'
    $effective = Get-Effective @('-F', $snapshot.RootPath, '--', 'shared')
    Assert-True ($effective -notmatch '32109') 'forwarding inside Include files is also removed'

    $config = Write-Fixture 'windows-include.conf' ("Include `"$included`"`nHost windows-path another *.wild !excluded`n  HostName 127.0.0.1`n  User local`n")
    $aliases = @(Get-NativeSshConfigAliases $config)
    Assert-True (($aliases.Alias -join ',') -eq 'shared,windows-path,another') 'native alias discovery accepts Windows Include paths in source order'
    Assert-True ($aliases[0].SourceFile -eq $included) 'native alias discovery retains original Include source path'
    $native = Get-NativeSshProfile shared $config $ssh
    Assert-True ($native.Host -eq 'included.example.org' -and $native.User -eq 'matched-user') 'Windows Include path preview uses the same graph as discovery'
    $config = Write-Fixture 'domain-user.conf' @'
Host domain-user
    HostName 127.0.0.1
    User example\researcher
    IdentityFile relative-key
'@
    $native = Get-NativeSshProfile domain-user $config $ssh
    Assert-True ($native.User -eq 'example\researcher') 'native preview accepts domain usernames and relative identity paths without manual-profile restrictions'

    $marker = Join-Path $scratch 'must-not-exist'
    $unsafe = Write-Fixture 'unsafe.conf' ("Host guarded`n  HostName 127.0.0.1`n  User local`nMatch exec `"cmd /c echo executed > $marker`"`n  Port 2223`n")
    Assert-Rejected { Get-NativeSshProfile guarded $unsafe $ssh } 'Match exec' 'preview refuses dynamic local command evaluation'
    [void][IO.Directory]::CreateDirectory($ownedPreview)
    Assert-Rejected { Get-NativeSshProfile -Alias guarded -ConfigPath $unsafe -SshPath $ssh -PreviewDirectory $ownedPreview } 'Match exec' 'caller-owned preview also preflights dynamic commands'
    Assert-True (-not (Test-Path -LiteralPath $ownedPreview)) 'caller-owned preview directory is cleaned after failed preflight'
    Assert-Rejected { New-NativeTunnelConfig $unsafe (Join-Path $scratch 'unsafe snapshot') } 'Match exec' 'start preflight refuses dynamic local command evaluation'
    Assert-True (-not (Test-Path -LiteralPath $marker)) 'no Match exec side effect is created'
    Assert-Rejected { New-NativeTunnelConfig '\\unreachable.invalid\ssh\config' (Join-Path $scratch 'network') } 'Network|local' 'UNC source is rejected before network file access'
    Assert-Rejected { New-NativeSshArguments $config configured 11082 'http://example.org:7897' } 'loopback|proxy' 'remote or credentialed proxy destinations are rejected'
    Assert-Rejected { New-NativeSshArguments $config '-oBad=yes' 11082 'http://127.0.0.1:7897' } 'alias' 'host alias cannot become a command option'
    Write-Output ("PASS: {0} native SSH assertions" -f $script:passed)
} finally {
    # The test created this unique directory and only deletes that exact root.
    if ([IO.Path]::GetFullPath($scratch).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}
