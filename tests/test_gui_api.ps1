param([string]$BackendAssembly = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$api = Join-Path $root 'gui\Gui-Api.ps1'
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$utf8 = New-Object Text.UTF8Encoding $false
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('codex-gui-api-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
$script:passed = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
}
function Invoke-Api($Request) {
    $requestPath = Join-Path $scratch 'request.json'
    $responsePath = Join-Path $scratch 'response.json'
    [IO.File]::WriteAllText($requestPath, ($Request | ConvertTo-Json -Depth 12), $utf8)
    $printed = @(& $powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $api -RequestPath $requestPath -ResponsePath $responsePath 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) 'helper exits cleanly'
    Assert-True ($printed.Count -eq 0) 'IPC helper never prints profile or child output'
    Assert-True (Test-Path -LiteralPath $responsePath) 'response file exists'
    Assert-True (-not (Test-Path -LiteralPath ($responsePath + '.tmp'))) 'response temporary file removed'
    $raw = [IO.File]::ReadAllText($responsePath, [Text.Encoding]::UTF8)
    Assert-True (-not $raw.Contains('NEVER-ECHO-THIS-SECRET')) 'response does not echo rejected sensitive fields'
    return ($raw | ConvertFrom-Json)
}
try {
    $config = Join-Path $scratch 'ssh config.conf'
    $fixture = "Host direct second *.wild !skip`n HostName server.example.org`n User testuser`n Port 2222`n IdentityFile none`n"
    [IO.File]::WriteAllText($config, $fixture, $utf8)
    $listed = Invoke-Api @{ operation = 'list'; sshConfig = $config }
    Assert-True $listed.ok 'list succeeds'
    Assert-True (($listed.result.Alias -join ',') -eq 'direct,second') 'literal aliases in source order'
    Assert-True ($listed.result[0].SourceFile -eq $config) 'source path preserved'
    $imported = Invoke-Api @{ operation = 'import'; alias = 'direct'; sshConfig = $config }
    Assert-True $imported.ok 'import uses ssh -G successfully without connecting'
    Assert-True ($imported.result.Host -eq 'server.example.org' -and $imported.result.User -eq 'testuser' -and $imported.result.Port -eq 2222) 'resolved endpoint DTO'
    Assert-True ($imported.result.JumpCount -eq 0 -and $imported.result.Route -eq 'testuser@server.example.org:2222') 'route and jump count'
    $profile = $imported.result.Json | ConvertFrom-Json
    Assert-True ($profile.server.identityFile -eq 'none') 'identity sentinel preserved'
    Assert-True ([IO.File]::ReadAllText($config) -ceq $fixture) 'read and import preserve original SSH config'

    # Native GUI flow keeps authentication in SSH instead of rejecting working
    # configurations that cannot fit the manual editor's restricted schema.
    $nativeConfig = Join-Path $scratch 'native.conf'
    $nativeText = @'
Host native
 HostName native.example.org
 User domain\researcher
 Port 2222
 IdentitiesOnly yes
 IdentityFile "missing-one"
 IdentityFile "missing-two"
 ProxyCommand cmd /c echo NEVER-ECHO-THIS-SECRET
 RemoteForward 19999 localhost:19998
'@
    [IO.File]::WriteAllText($nativeConfig, $nativeText, $utf8)
    $native = Invoke-Api @{ operation = 'native-import'; alias = 'native'; sshConfig = $nativeConfig }
    Assert-True ($native.ok -and $native.result.Host -eq 'native.example.org' -and $native.result.User -eq 'domain\researcher') 'native GUI resolves endpoint with original authentication options'
    Assert-True ($native.result.NativeAlias -eq 'native' -and $native.result.NativeConfigPath -eq $nativeConfig -and (Test-Path -LiteralPath $native.result.NativeSshPath)) 'native client and reference metadata retained'
    Assert-True ($native.result.Route -like 'ProxyCommand*' -and -not $native.result.Route.Contains('NEVER-ECHO')) 'native route labels proxy command without disclosing it'
    $nativeSave = Join-Path $scratch 'native-profile.json'; $nativeSession = Join-Path $scratch 'native-session.json'
    $nativePrepared = Invoke-Api @{ operation = 'prepare'; profileJson = $native.result.Json; nativeAlias = 'native'; nativeConfigPath = $nativeConfig; nativeSshPath = $native.result.NativeSshPath; remotePort = 12082; savePath = $nativeSave; sessionPath = $nativeSession }
    Assert-True $nativePrepared.ok 'native prepare bypasses manual endpoint conversion and validates source'
    $nativeSavedText = [IO.File]::ReadAllText($nativeSave)
    $nativeSaved = $nativeSavedText | ConvertFrom-Json
    Assert-True ($nativeSaved.remotePort -eq 12082 -and $nativeSaved.server.user -eq 'domain\researcher') 'native prepared display profile uses requested remote port'
    Assert-True (-not $nativeSavedText.Contains('NEVER-ECHO') -and -not $nativeSavedText.Contains('ProxyCommand')) 'native snapshot JSON contains no source command values'
    Assert-True ([IO.File]::ReadAllText($nativeConfig) -ceq $nativeText) 'native import and prepare preserve source bytes'

    $bad = Invoke-Api @{ operation = 'import'; alias = '--NEVER-ECHO-THIS-SECRET'; sshConfig = $config }
    Assert-True (-not $bad.ok) 'option-like alias rejected safely'
    $missing = Invoke-Api @{ operation = 'list'; sshConfig = (Join-Path $scratch 'missing.conf') }
    Assert-True (-not $missing.ok) 'missing config returns structured failure'
    $empty = Join-Path $scratch 'empty.conf'
    [IO.File]::WriteAllText($empty, '# no aliases', $utf8)
    $emptyList = Invoke-Api @{ operation = 'list'; sshConfig = $empty }
    Assert-True ($emptyList.ok -and $emptyList.result -is [array] -and $emptyList.result.Count -eq 0) 'empty list retains array type'

    # An allocated-and-released loopback port has no proxy. Manual mode never
    # consults the user's real proxy configuration or connects directly online.
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $closedPort = $listener.LocalEndpoint.Port
    $listener.Stop()
    $probe = Invoke-Api @{ operation = 'probe'; manualPort = $closedPort }
    Assert-True ($probe.ok -and -not $probe.result.Success) 'closed local port is not a working proxy'
    Assert-True ($probe.result.StatusCode -eq 0) 'closed proxy cannot claim target HTTP success'
    $badPort = Invoke-Api @{ operation = 'probe'; manualPort = -1 }
    Assert-True (-not $badPort.ok) 'negative manual port rejected'

    # Exercise the GUI's two-request acceptance rule without Internet access.
    # Only this private fixture replaces modules; production files are untouched.
    $mockRuntime = Join-Path $scratch 'mock-runtime'
    [void][IO.Directory]::CreateDirectory($mockRuntime)
    Copy-Item -LiteralPath $api -Destination (Join-Path $mockRuntime 'Gui-Api.ps1')
    [IO.File]::WriteAllText((Join-Path $mockRuntime 'SshImport.ps1'), '# unused fixture', $utf8)
    [IO.File]::WriteAllText((Join-Path $mockRuntime 'TunnelTools.ps1'), 'function Find-TunnelProgram { return "fixture-curl" }', $utf8)
    $fakeProxy = @'
$script:probeCalls = 0
function Get-ProxyCandidates { return [pscustomobject]@{ Url = 'http://127.0.0.1:34567' } }
function Test-HttpProxy {
    param($ProxyUrl, $CurlPath, $TimeoutSeconds)
    $script:probeCalls++
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'calls.txt'), [string]$script:probeCalls)
    $secondFails = Test-Path -LiteralPath (Join-Path $PSScriptRoot 'second-fails.txt')
    return [pscustomobject]@{ Success = (-not $secondFails -or $script:probeCalls -eq 1); StatusCode = 401 }
}
'@
    [IO.File]::WriteAllText((Join-Path $mockRuntime 'ProxyTools.ps1'), $fakeProxy, $utf8)
    $productionApi = $api
    $api = Join-Path $mockRuntime 'Gui-Api.ps1'
    try {
        $twice = Invoke-Api @{ operation = 'probe'; manualPort = 34567 }
        Assert-True ($twice.ok -and $twice.result.Success -and $twice.result.StatusCode -eq 401) 'two successful HTTPS responses accepted'
        Assert-True ([IO.File]::ReadAllText((Join-Path $mockRuntime 'calls.txt')) -eq '2') 'successful candidate probed exactly twice'
        [IO.File]::WriteAllText((Join-Path $mockRuntime 'second-fails.txt'), '', $utf8)
        $flaky = Invoke-Api @{ operation = 'probe'; manualPort = 34567 }
        Assert-True ($flaky.ok -and -not $flaky.result.Success) 'first success followed by failed confirmation rejected'
        Assert-True ([IO.File]::ReadAllText((Join-Path $mockRuntime 'calls.txt')) -eq '2') 'flaky candidate confirmation actually attempted'
    } finally { $api = $productionApi }

    $saved = Join-Path $scratch 'saved-profile.json'
    $session = Join-Path $scratch 'session-profile.json'
    $prepared = Invoke-Api @{ operation = 'prepare'; profileJson = $imported.result.Json; remotePort = 12082; savePath = $saved; sessionPath = $session }
    Assert-True ($prepared.ok -and $prepared.result.Prepared) 'validated profile prepared'
    Assert-True (([IO.File]::ReadAllText($saved) | ConvertFrom-Json).remotePort -eq 12082) 'requested remote port persisted'
    Assert-True ([IO.File]::ReadAllText($saved) -ceq [IO.File]::ReadAllText($session)) 'independent session profile matches persistence'
    $reprepared = Invoke-Api @{ operation = 'prepare'; profileJson = $imported.result.Json; remotePort = 13082; savePath = $saved; sessionPath = $session }
    Assert-True ($reprepared.ok -and ([IO.File]::ReadAllText($saved) | ConvertFrom-Json).remotePort -eq 13082) 'existing profile atomically replaced on subsequent start'
    $before = [IO.File]::ReadAllText($saved)
    $profile | Add-Member -NotePropertyName password -NotePropertyValue 'NEVER-ECHO-THIS-SECRET'
    $rejected = Invoke-Api @{ operation = 'prepare'; profileJson = ($profile | ConvertTo-Json -Depth 8); remotePort = 12082; savePath = $saved; sessionPath = $session }
    Assert-True (-not $rejected.ok) 'password field rejected before persistence'
    Assert-True ([IO.File]::ReadAllText($saved) -ceq $before) 'rejected profile does not overwrite saved state'
    $invalid = Invoke-Api @{ operation = 'unknown'; data = 'NEVER-ECHO-THIS-SECRET' }
    Assert-True (-not $invalid.ok) 'unsupported operation is structured failure'

    if ($BackendAssembly) {
        Add-Type -AssemblyName System.Web.Extensions
        # Windows PowerShell 5.1 Add-Type -Path rejects .exe assemblies, although
        # the release GUI is a regular managed assembly containing this backend.
        [void][Reflection.Assembly]::LoadFrom([IO.Path]::GetFullPath($BackendAssembly))
        $backend = New-Object CodexTunnelGui.TunnelBackend($root)
        try {
            $task = $backend.LoadHostsAsync($config)
            $hosts = $task.GetAwaiter().GetResult()
            Assert-True ($hosts.Count -eq 2 -and $hosts[0].Alias -eq 'direct') 'C# backend hidden job IPC list'
            $task = $backend.ResolveHostAsync('direct', $config)
            $resolved = $task.GetAwaiter().GetResult()
            Assert-True ($resolved.Host -eq 'server.example.org') 'C# backend JSON DTO import'
            Assert-True (-not $backend.IsRunning) 'read-only operations do not mark tunnel running'
            Assert-True ($backend.ProfilePath.EndsWith('\CodexProxyTunnel\gui-profile.json')) 'GUI profile is separate from CLI settings'
        } finally { $backend.Dispose() }
    }
    Write-Output ("GUI API tests passed: {0}" -f $script:passed)
} finally {
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolvedScratch) -eq $tempRoot -and [IO.Path]::GetFileName($resolvedScratch).StartsWith('codex-gui-api-tests-')) {
        Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
    }
}
