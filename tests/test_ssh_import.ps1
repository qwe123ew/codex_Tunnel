$ErrorActionPreference = 'Stop'
# Match the launcher: Windows OpenSSH writes config paths as UTF-8.
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'ProxyTools.ps1')
. (Join-Path $root 'TunnelTools.ps1')
$modulePath = Join-Path $root 'SshImport.ps1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw 'FAIL: read-only SSH import has not been implemented.' }
. $modulePath
$script:passed = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
}
function Assert-Rejected([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $failure = ''
    try { & $Action | Out-Null } catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match $Pattern) $Message
    return $failure
}
function Write-Fixture([string]$Name, [string]$Text) {
    $path = Join-Path $scratch $Name
    $newFixture = -not (Test-Path -LiteralPath $path)
    [void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
    [IO.File]::WriteAllText($path, $Text, (New-Object Text.UTF8Encoding $false))
    # Windows OpenSSH verifies included files even when the main -F config is
    # accepted. Limit only this newly-created fixture to the current user.
    $fixtureAcl = New-Object Security.AccessControl.FileSecurity
    $fixtureUser = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $fixtureAcl.SetOwner($fixtureUser)
    $fixtureAcl.SetAccessRuleProtection($true, $false)
    $fixtureRule = New-Object Security.AccessControl.FileSystemAccessRule($fixtureUser, 'FullControl', 'Allow')
    $fixtureAcl.AddAccessRule($fixtureRule)
    if ($newFixture) { Set-Acl -LiteralPath $path -AclObject $fixtureAcl }
    return $path
}
$ssh = Find-TunnelProgram ssh
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('ssh import tests ' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
try {
    $config = Write-Fixture 'direct.conf' @'
Host direct second *.wild !excluded
    HostName direct.example.org
    User alice
    Port 2222
    IdentityFile none
    LocalForward 4321 localhost:80
    RemoteForward 4322 localhost:81
    DynamicForward 4323
'@
    $before = [IO.File]::ReadAllText($config)
    $aliases = @(Get-SshConfigAliases -ConfigPath $config)
    Assert-True (($aliases.Alias -join ',') -eq 'direct,second') 'literal aliases only, in source order'
    Assert-True ($aliases[0].SourceFile -eq $config) 'alias source filename'
    $profile = Import-SshHostProfile -Alias direct -ConfigPath $config -SshPath $ssh
    Assert-TunnelProfile $profile
    Assert-True ($profile.server.host -eq 'direct.example.org' -and $profile.server.user -eq 'alice' -and $profile.server.port -eq 2222) 'effective direct endpoint'
    Assert-True ($profile.version -eq 1 -and $profile.remotePort -eq 11082 -and $profile.checkIntervalSeconds -eq 60 -and @($profile.jumpHosts).Count -eq 0) 'standard profile defaults'
    Assert-True ($profile.server.identityFile -eq 'none') 'explicit no-key identity sentinel preserved'
    Assert-True ((New-TunnelSshConfig $profile 'http://127.0.0.1:7890') -notmatch '4321|4322|4323|LocalForward|DynamicForward') 'original forwarding directives are not imported'
    Assert-True ([IO.File]::ReadAllText($config) -ceq $before) 'source config remains unchanged'

    $config = Write-Fixture 'jumps.conf' @'
Host gpu04
  HostName gpu04
  User researcher
  ProxyJump researcher@gateway.example.org,researcher@submit.example.org
Host gateway.example.org
  Port 2201
Host submit.example.org
  Port 2202
Host *
  IdentityFile none
'@
    $profile = Import-SshHostProfile gpu04 $config $ssh
    Assert-True ($profile.server.host -eq 'gpu04' -and $profile.server.user -eq 'researcher') 'common target imported'
    Assert-True (@($profile.jumpHosts).Count -eq 2) 'two ordered jumps'
    Assert-True ($profile.jumpHosts[0].host -eq 'gateway.example.org' -and $profile.jumpHosts[0].port -eq 2201 -and $profile.jumpHosts[0].user -eq 'researcher') 'first jump effective endpoint'
    Assert-True ($profile.jumpHosts[1].host -eq 'submit.example.org' -and $profile.jumpHosts[1].port -eq 2202) 'second jump effective endpoint'

    $config = Write-Fixture 'overrides.conf' @'
Host target
  HostName gpu.example.org
  User targetuser
  ProxyJump override@gate:2299,v6user@[2001:db8::2]:2220
Host gate
  HostName gate.example.org
  User ignoreduser
  Port 2200
Host *
  IdentityFile none
'@
    $profile = Import-SshHostProfile target $config $ssh
    Assert-True ($profile.jumpHosts[0].user -eq 'override' -and $profile.jumpHosts[0].port -eq 2299 -and $profile.jumpHosts[0].host -eq 'gate.example.org') 'jump user and port override alias config'
    Assert-True ($profile.jumpHosts[1].host -eq '2001:db8::2' -and $profile.jumpHosts[1].port -eq 2220) 'bracketed IPv6 jump parsed'

    $first = Write-Fixture 'include space/01-first.conf' "hOsT included`n User firstuser`n HostName included.example.org`n IdentityFile none`n"
    $second = Write-Fixture 'include space/02-second.conf' "Host included extra`n User seconduser`n"
    $glob = (Join-Path $scratch 'include space/*.conf').Replace('\', '/')
    $config = Write-Fixture 'include.conf' ("Include `"$glob`"`nHost included`n User lastuser`nHost final`n User finaluser`n IdentityFile none`n")
    $aliases = @(Get-SshConfigAliases $config)
    Assert-True (($aliases.Alias -join ',') -eq 'included,extra,final') 'quoted Include glob with alias deduplication'
    Assert-True ($aliases[0].SourceFile -eq $first) 'included alias keeps originating source'
    $profile = Import-SshHostProfile included $config $ssh
    Assert-True ($profile.server.user -eq 'firstuser') 'OpenSSH first matching value wins across includes'

    # The file beside this config must not be resolved as an Include relative to
    # the config directory: user-config Include uses the user .ssh directory.
    $relativeName = 'codex-import-relative-' + [guid]::NewGuid().ToString('N') + '.conf'
    $unused = Write-Fixture $relativeName "Host wrongbase`n User wrong`n"
    $config = Write-Fixture 'relative.conf' ("Include $relativeName`nHost rightbase`n User alice`n IdentityFile none`n")
    $aliases = @(Get-SshConfigAliases $config)
    Assert-True (($aliases.Alias -join ',') -eq 'rightbase') 'relative Include uses user .ssh, not source directory'
    $profile = Import-SshHostProfile rightbase $config $ssh
    Assert-True ($profile.server.user -eq 'alice') 'missing relative Include matches real ssh behavior'
    $config = Write-Fixture 'inline-comment.conf' "Include missing.conf#ambiguous`nHost example`n"
    [void](Assert-Rejected { Get-SshConfigAliases $config } 'inline.*comment|manual' 'ambiguous inline Include comment fails closed')

    $key = Write-Fixture 'key space/dummy-key' 'test marker, not a private key'
    $keyConfigPath = $key.Replace('\', '/')
    $config = Write-Fixture 'keys.conf' ("Host keyhost`n HostName key.example.org`n User keyuser`n IdentityFile `"$keyConfigPath`"`n")
    $profile = Import-SshHostProfile keyhost $config $ssh
    Assert-True ($profile.server.identityFile -eq $key) 'existing key path with spaces preserved without reading it'
    $unicodeName = 'key space/' + [char]0x6D4B + [char]0x8BD5 + '-key'
    $unicodeKey = Write-Fixture $unicodeName 'Unicode path marker'
    $config = Write-Fixture 'unicode-key.conf' ("Host keyhost`n User keyuser`n IdentityFile `"$($unicodeKey.Replace('\', '/'))`"`n")
    $profile = Import-SshHostProfile keyhost $config $ssh
    Assert-True ($profile.server.identityFile -ceq $unicodeKey) 'UTF-8 key path survives ssh -G and PS5.1 decoding'
    $key2 = Write-Fixture 'key space/dummy-key2' 'second marker'
    $config = Write-Fixture 'multi-keys.conf' ("Host keyhost`n User keyuser`n IdentityFile `"$keyConfigPath`"`n IdentityFile `"$($key2.Replace('\', '/'))`"`n")
    [void](Assert-Rejected { Import-SshHostProfile keyhost $config $ssh } 'multiple|more than one|ambigu' 'multiple existing keys require manual choice')
    $missing = (Join-Path $scratch 'missing-key').Replace('\', '/')
    $config = Write-Fixture 'missing-key.conf' ("Host keyhost`n User keyuser`n IdentityFile `"$missing`"`n")
    [void](Assert-Rejected { Import-SshHostProfile keyhost $config $ssh } 'identity|key' 'missing explicit key reports configuration issue')

    $config = Write-Fixture 'proxy-command.conf' "Host commandhost`n User alice`n ProxyCommand secret-token-do-not-echo --private-value`n IdentityFile none`n"
    $failure = Assert-Rejected { Import-SshHostProfile commandhost $config $ssh } 'ProxyCommand.*manual|manual.*ProxyCommand' 'ProxyCommand is unsupported'
    Assert-True ($failure -notmatch 'secret-token|private-value') 'command content never exposed'
    $config = Write-Fixture 'nested.conf' "Host target`n User alice`n ProxyJump gate`nHost gate`n User bob`n ProxyJump outer`nHost *`n IdentityFile none`n"
    [void](Assert-Rejected { Import-SshHostProfile target $config $ssh } 'nested|manual' 'nested per-hop jump is not silently dropped')
    $config = Write-Fixture 'five-jumps.conf' "Host target`n User alice`n ProxyJump j1,j2,j3,j4,j5`n IdentityFile none`n"
    [void](Assert-Rejected { Import-SshHostProfile target $config $ssh } 'four' 'jump count stays bounded')

    foreach ($specialSetting in @('IdentitiesOnly yes', 'IdentityAgent none', 'HostKeyAlias alternate-host', 'UserKnownHostsFile NUL', 'BindAddress 127.0.0.2', 'PasswordAuthentication no', 'StrictHostKeyChecking no')) {
        $config = Write-Fixture 'special-auth.conf' ("Host specialized`n User alice`n IdentityFile none`n $specialSetting`n")
        [void](Assert-Rejected { Import-SshHostProfile specialized $config $ssh } 'unsupported|manual|authentication' 'specialized authentication or routing is not silently lost')
    }

    $script:originalImportHome = ${function:Get-SshImportHome}
    $script:fixtureImportHome = Join-Path $scratch 'fake-home'
    function Get-SshImportHome { return $script:fixtureImportHome }
    $fields = @{ hostname = 'key.example.org'; user = 'alice'; port = '2222' }
    $missingDefaults = Resolve-SshImportIdentity @('~/.ssh/id_rsa', '~/.ssh/id_ed25519') $fields 'keyalias' @('~/.ssh/id_rsa', '~/.ssh/id_ed25519')
    Assert-True ($missingDefaults -eq '') 'absent default keys are ignored'
    [void](Assert-Rejected { Resolve-SshImportIdentity @('~/.ssh/id_rsa') $fields 'keyalias' @('~/.ssh/id_rsa', '~/.ssh/id_ed25519') } 'explicit IdentityFile' 'an explicit absent default-named key is not replaced with other defaults')
    $tokenKey = Write-Fixture 'fake-home/.ssh/key.example.org-alice-2222-keyalias' 'token expansion marker'
    $expandedKey = Resolve-SshImportIdentity @('%d/.ssh/%h-%r-%p-%n') $fields 'keyalias'
    Assert-True ($expandedKey -eq $tokenKey) 'supported home host user port alias key tokens expand safely'
    [void](Assert-Rejected { Resolve-SshImportIdentity @('%C/key') $fields 'keyalias' } 'unsupported token' 'unsupported key tokens refuse manual import')
    Set-Item -Path function:Get-SshImportHome -Value $script:originalImportHome

    $cycle1 = Join-Path $scratch 'cycle1.conf'
    $cycle2 = Join-Path $scratch 'cycle2.conf'
    [void](Write-Fixture 'cycle1.conf' ("Include `"$($cycle2.Replace('\', '/'))`"`nHost cyclic`n User alice`n"))
    [void](Write-Fixture 'cycle2.conf' ("Include `"$($cycle1.Replace('\', '/'))`"`n"))
    [void](Assert-Rejected { Get-SshConfigAliases $cycle1 } 'cycl|recurs' 'Include cycles rejected without ssh')
    for ($depth = 65; $depth -ge 1; $depth--) {
        $nextPath = (Join-Path $scratch ('depth-{0}.conf' -f ($depth + 1))).Replace('\', '/')
        $contents = if ($depth -eq 65) { "Host depth`n User alice`n" } else { "Include `"$nextPath`"`n" }
        [void](Write-Fixture ('depth-{0}.conf' -f $depth) $contents)
    }
    [void](Assert-Rejected { Get-SshConfigAliases (Join-Path $scratch 'depth-1.conf') } '64' 'Include graph traversal is bounded')

    # Use a real dangerous command as fixture data, never run it. The wrapper
    # proves rejection happens before ssh -G (which otherwise executes Match exec).
    $marker = Join-Path $scratch 'MATCH_EXEC_WAS_RUN'
    $script:importProbeCalls = 0
    $script:originalProxyProcess = ${function:Invoke-ProxyProcess}
    function Invoke-ProxyProcess {
        param([string]$FileName, [string[]]$Arguments, [int]$TimeoutSeconds)
        $script:importProbeCalls++
        & $script:originalProxyProcess @PSBoundParameters
    }
    foreach ($matchKeyword in @('exec', '"exec"', '!exec', '"!exec"')) {
        $dangerous = Write-Fixture 'danger.conf' ("Match $matchKeyword `"cmd.exe /c echo executed>$($marker.Replace('\', '/'))`"`nHost unsafe`n User alice`n")
        $config = Write-Fixture 'unsafe.conf' ("Include `"$($dangerous.Replace('\', '/'))`"`nHost safe`n User alice`n IdentityFile none`n")
        [void](Assert-Rejected { Import-SshHostProfile safe $config $ssh } 'Match.*exec' 'Match exec in Include rejected before any execution')
    }
    $hidden = Write-Fixture 'hidden-include/hidden.conf' "Match exec true`n"
    [IO.File]::SetAttributes($hidden, [IO.File]::GetAttributes($hidden) -bor [IO.FileAttributes]::Hidden)
    $hiddenGlob = (Join-Path $scratch 'hidden-include/*.conf').Replace('\', '/')
    $config = Write-Fixture 'hidden.conf' ("Include `"$hiddenGlob`"`nHost hidden`n User alice`n")
    [void](Assert-Rejected { Import-SshHostProfile hidden $config $ssh } 'Match.*exec' 'hidden Include files are preflighted')
    Assert-True ($script:importProbeCalls -eq 0) 'unsafe config never reaches ssh process'
    Assert-True (-not (Test-Path -LiteralPath $marker)) 'Match exec side-effect marker was never created'
    Set-Item -Path function:Invoke-ProxyProcess -Value $script:originalProxyProcess
} finally {
    $fullScratch = [IO.Path]::GetFullPath($scratch)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($fullScratch.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $fullScratch -Recurse -Force
    }
}
Write-Host "PASS: $script:passed SSH import checks (local ssh -G only; no login)"
