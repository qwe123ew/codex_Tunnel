param([string]$BackendAssembly = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('codex-catalog-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
$utf8 = New-Object Text.UTF8Encoding $false
$script:passed = 0
function Check($condition, [string]$message) { if (-not $condition) { throw "FAIL: $message" }; $script:passed++ }
function Write-Text([string]$path, [string]$text) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllText($path, $text, $utf8)
}
function Await($task) { return $task.GetAwaiter().GetResult() }
function Reject([scriptblock]$action, [string]$message) {
    $failed = $false
    try { & $action | Out-Null } catch { $failed = $true }
    Check $failed $message
}
function New-Backend([string]$path) {
    $instance = New-Object CodexTunnelGui.TunnelBackend($root)
    $instance.GetType().GetProperty('ServersPath').SetValue($instance, $path, $null)
    $instance.GetType().GetField('catalogUserHome', 'Instance,NonPublic').SetValue($instance, (Join-Path $scratch 'home'))
    $instance.GetType().GetField('catalogAppData', 'Instance,NonPublic').SetValue($instance, (Join-Path $scratch 'appdata'))
    return $instance
}
$backend = $null; $second = $null; $processes = @()
try {
    if (-not $BackendAssembly) {
        $BackendAssembly = Join-Path $scratch 'catalog.dll'
        & (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe') /nologo /target:library /warn:4 /warnaserror+ /reference:System.Web.Extensions.dll ('/out:' + $BackendAssembly) (Join-Path $root 'gui\TunnelBackend.cs') (Join-Path $root 'gui\ServerCatalog.cs')
        Check ($LASTEXITCODE -eq 0) 'C#5 framework backend compiles'
    }
    Add-Type -AssemblyName System.Web.Extensions
    [void][Reflection.Assembly]::LoadFrom([IO.Path]::GetFullPath($BackendAssembly))
    $store = Join-Path $scratch 'data\servers.json'
    $backend = New-Backend $store
    $empty = Await ($backend.LoadCatalogAsync())
    Check ($empty.Hosts.Count -eq 0 -and $empty.Warnings.Count -eq 0) 'new computer with no SSH configuration is a valid empty catalog'
    Check (-not [IO.File]::Exists($store)) 'read-only load does not create a store'
    $profile = @{ version=1; server=@{host='gpu.example.org';user='research';port=2222;identityFile=''}; jumpHosts=@(
        @{host='gate.example.org';user='first';port=2200;identityFile='none'},
        @{host='internal.example.org';user='second';port=22;identityFile=''}
    ); remotePort=11082; checkIntervalSeconds=60 }
    $json = $profile | ConvertTo-Json -Depth 8 -Compress
    $saved = Await ($backend.SaveServerAsync('研究服务器', $json))
    Check ($saved.Kind -eq 'saved' -and $saved.SourceLabel -eq '软件保存' -and $saved.Alias -eq '研究服务器') 'manual entry has readable source label'
    Check ($saved.Id -match '^[0-9a-f]{32}$') 'manual entry has stable generated ID'
    $second = New-Backend $store
    $loaded = Await ($second.LoadCatalogAsync())
    Check ($loaded.Hosts.Count -eq 1 -and $loaded.Hosts[0].Id -eq $saved.Id) 'save persists across backend restart without SSH config'
    $resolved = Await ($second.ResolveEntryAsync($loaded.Hosts[0]))
    Check ($resolved.JumpCount -eq 2 -and $resolved.Route -eq 'first@gate.example.org:2200 -> second@internal.example.org:22 -> research@gpu.example.org:2222') 'two ordered jump hosts retained and resolved'
    $updated = Await ($backend.SaveServerAsync('更新后的名称', $json, $saved.Id))
    Check ($updated.Id -eq $saved.Id -and (Await ($backend.LoadCatalogAsync())).Hosts.Count -eq 1) 'editing preserves ID and replaces only one record'
    $other = Await ($backend.SaveServerAsync('另一台', $json))
    [void](Await ($backend.SaveServerAsync('重复保存', $json, $saved.Id)))
    Check ((Await ($backend.LoadCatalogAsync())).Hosts.Count -eq 2) 'repeated atomic replace preserves other saved records'

    $baseline = [IO.File]::ReadAllText($store)
    Reject { Await ($backend.SaveServerAsync('', $json)) } 'empty name rejected'
    Reject { Await ($backend.SaveServerAsync(('x' * 65), $json)) } 'overlong name rejected'
    Reject { Await ($backend.SaveServerAsync("bad`nname", $json)) } 'control characters rejected'
    Reject { Await ($backend.SaveServerAsync('unknown edit', $json, [guid]::NewGuid().ToString('N'))) } 'unknown ID cannot append accidental edit'
    $invalid = $json.Replace('"port":2222', '"port":70000')
    Reject { Await ($backend.SaveServerAsync('invalid port', $invalid)) } 'out-of-range SSH port rejected before save'
    $credential = $json.Replace('"version":1', '"version":1,"password":"NEVER-STORE-SECRET"')
    Reject { Await ($backend.SaveServerAsync('secret', $credential)) } 'password field rejected before save'
    $shellHost = $json.Replace('gpu.example.org', 'gpu.example.org;whoami')
    Reject { Await ($backend.SaveServerAsync('bad host', $shellHost)) } 'shell-like hostname rejected'
    Check ([IO.File]::ReadAllText($store) -ceq $baseline) 'rejected inputs leave existing store byte-identical'
    Check (-not [IO.File]::ReadAllText($store).Contains('NEVER-STORE-SECRET')) 'credential value never persisted'

    $key = Join-Path $scratch 'temporary-key'
    Write-Text $key 'fixture-key-content-never-copied'
    $profile.server.identityFile = $key
    $keyJson = $profile | ConvertTo-Json -Depth 8 -Compress
    $keyEntry = Await ($backend.SaveServerAsync('密钥路径测试', $keyJson))
    [IO.File]::Delete($key)
    Check ((Await ($backend.LoadCatalogAsync())).Hosts.Count -eq 3) 'missing optional private key does not hide saved catalog'
    Check (((Await ($backend.ReadSavedServerAsync($keyEntry.Id))).Json | ConvertFrom-Json).server.identityFile -eq $key) 'edit operation retains missing key path for correction'
    Reject { Await ($backend.ResolveEntryAsync($keyEntry)) } 'actual launch resolution rejects missing identity file'
    Check (-not [IO.File]::ReadAllText($store).Contains('fixture-key-content-never-copied')) 'private key contents never copied'

    # Discover standard SSH plus VS Code JSONC custom path. No user's real
    # home/AppData/configuration is consulted by these injected fixtures.
    $default = Join-Path $scratch 'home\.ssh\config'
    $custom = Join-Path $scratch 'home\team settings\ssh.conf'
    $include = Join-Path ([IO.Path]::GetDirectoryName($custom)) 'included.conf'
    Write-Text $default "Host default-host`n HostName default.example.org`n User research`n"
    Write-Text $include "Host included-host`n HostName included.example.org`n User research`n"
    Write-Text $custom ('Include "' + $include.Replace('\','/') + '"' + "`nHost custom-host`n HostName custom.example.org`n User research`n")
    $settings = Join-Path $scratch 'appdata\Code\User\settings.json'
    Write-Text $settings @'
{
  // This is a JSONC settings file.
  "unrelated.url": "https://example.org/a//b/*literal*/",
  "remote.SSH.configFile": "${userHome}/team settings/ssh.conf", /* a comment */
}
'@
    $insiders = Join-Path $scratch 'appdata\Code - Insiders\User\settings.json'
    Write-Text $insiders ('{"remote.SSH.configFile":' + ($default | ConvertTo-Json -Compress) + '}')
    $beforeDefault = [IO.File]::ReadAllText($default); $beforeSettings = [IO.File]::ReadAllText($settings)
    $auto = Await ($backend.LoadCatalogAsync())
    Check ($auto.Hosts.Count -eq 6 -and $auto.ConfigPaths.Count -eq 2 -and $auto.Warnings.Count -eq 0) 'auto discovery combines saved/default/VS Code and deduplicates same root path'
    $included = @($auto.Hosts | Where-Object Alias -eq 'included-host')[0]
    Check ($included.Kind -eq 'ssh' -and $included.ConfigPath -eq $custom -and $included.SourceFile -eq $include) 'Include alias retains root for resolution and included source for provenance'
    Check ($included.SourceLabel -eq 'VS Code') 'custom source identified as VS Code'
    # A common Remote-SSH setup changes only the executable, while retaining
    # ~/.ssh/config. Keep that client attached to the alias instead of silently
    # parsing it with the system client. Discovery never executes these files.
    $clientOne = Join-Path $scratch 'clients\Git One\ssh.exe'
    $clientTwo = Join-Path $scratch 'clients\Git Two\ssh.exe'
    Write-Text $clientOne 'not executed by discovery'
    Write-Text $clientTwo 'not executed by discovery'
    Write-Text $settings (@{ 'remote.SSH.path'=$clientOne; 'remote.SSH.configFile'='' } | ConvertTo-Json -Compress)
    $clientOnly = Await ($backend.LoadCatalogAsync())
    $defaultEntries = @($clientOnly.Hosts | Where-Object Alias -eq 'default-host')
    Check ($defaultEntries.Count -eq 2 -and $clientOnly.Warnings.Count -eq 0) 'explicit SSH client plus empty configFile uses default SSH root'
    Check ($defaultEntries[0].SshPath -eq $clientOne -and $defaultEntries[1].SourceLabel -eq '本机 SSH') 'automatic selection prefers configured VS Code SSH client before the system fallback'
    Check (@($defaultEntries | Where-Object SshPath -eq $clientOne).Count -eq 1) 'VS Code client path preserved on the catalog entry'
    Check (@($defaultEntries.Id | Select-Object -Unique).Count -eq 2) 'same root and alias with different clients have distinct stable IDs'
    Write-Text $settings (@{ 'remote.SSH.path'=$clientOne } | ConvertTo-Json -Compress)
    Write-Text $insiders (@{ 'remote.SSH.path'=$clientOne } | ConvertTo-Json -Compress)
    $sameClient = Await ($backend.LoadCatalogAsync())
    Check (@($sameClient.Hosts | Where-Object Alias -eq 'default-host').Count -eq 2) 'identical config and client across Code editions deduplicate'
    Write-Text $insiders (@{ 'remote.SSH.path'=$clientTwo } | ConvertTo-Json -Compress)
    $twoClients = Await ($backend.LoadCatalogAsync())
    Check (@($twoClients.Hosts | Where-Object Alias -eq 'default-host').Count -eq 3) 'same SSH root with two configured clients remains independently selectable'
    $orderedClients = @($twoClients.Hosts | Where-Object Alias -eq 'default-host')
    Check ($orderedClients[0].SshPath -eq $clientOne -and $orderedClients[1].SshPath -eq $clientTwo -and -not $orderedClients[2].SshPath) 'configured-client preference preserves discovery order within Code editions'
    Check (@($twoClients.Hosts | Where-Object { $_.Alias -eq 'default-host' -and $_.SourceLabel -eq 'VS Code Insiders' -and $_.SshPath -eq $clientTwo }).Count -eq 1) 'different Code edition remains distinguishable in server selection'
    Write-Text $insiders ('{"remote.SSH.configFile":' + ($default | ConvertTo-Json -Compress) + '}')
    Write-Text $settings (@{ 'remote.SSH.path'=(Join-Path $scratch 'missing-ssh.exe') } | ConvertTo-Json -Compress)
    $invalidClient = Await ($backend.LoadCatalogAsync())
    Check ($invalidClient.Warnings.Count -eq 1 -and $invalidClient.Warnings[0].Contains('remote.SSH.path')) 'missing configured SSH client produces an actionable warning'
    Check (@($invalidClient.Hosts | Where-Object Alias -eq 'default-host').Count -eq 1) 'invalid configured client does not silently create a fallback VS Code source'
    Write-Text $settings '{"remote.SSH.path":"\\\\never-access-this-host\\share\\ssh.exe"}'
    $networkClient = Await ($backend.LoadCatalogAsync())
    Check ($networkClient.Warnings.Count -eq 1 -and $networkClient.ConfigPaths.Count -eq 1) 'network SSH executable rejected before SMB access'
    Write-Text $settings $beforeSettings
    $explicit = Await ($backend.LoadCatalogAsync($default))
    Check ($explicit.Hosts.Count -eq 4 -and $explicit.ConfigPaths.Count -eq 1) 'explicit source limits SSH discovery without hiding saved entries'
    Check ([IO.File]::ReadAllText($default) -ceq $beforeDefault -and [IO.File]::ReadAllText($settings) -ceq $beforeSettings) 'discovery preserves SSH and VS Code source bytes'
    $missing = Await ($backend.LoadCatalogAsync((Join-Path $scratch 'missing.conf')))
    Check ($missing.Hosts.Count -eq 3 -and $missing.Warnings.Count -eq 1) 'missing explicit SSH file preserves saved entries with warning'
    $network = Await ($backend.LoadCatalogAsync('\\never-access-this-host\share\config'))
    Check ($network.Hosts.Count -eq 3 -and $network.ConfigPaths.Count -eq 0 -and $network.Warnings.Count -eq 1) 'UNC source rejected before filesystem or SMB access'
    $device = Await ($backend.LoadCatalogAsync('\\?\C:\never-access-config'))
    Check ($device.Hosts.Count -eq 3 -and $device.ConfigPaths.Count -eq 0 -and $device.Warnings.Count -eq 1) 'extended device path rejected before filesystem access'
    Write-Text $insiders '{bad jsonc'
    $partial = Await ($backend.LoadCatalogAsync())
    Check ($partial.Hosts.Count -eq 6 -and $partial.Warnings.Count -eq 1) 'bad VS Code settings does not discard other sources'
    Write-Text $default 'Match exec "must-never-run"'
    $partial = Await ($backend.LoadCatalogAsync())
    Check ($partial.Hosts.Count -eq 5 -and $partial.Warnings.Count -eq 2) 'unsupported SSH config yields warning while saved/custom remain available'

    # A corrupted store is visible as a warning and can never be silently
    # replaced by the next save; readable SSH sources remain selectable.
    $corrupt = Join-Path $scratch 'corrupt\servers.json'
    Write-Text $corrupt '{BROKEN-STORE-PRESERVE-ME'
    $badBackend = New-Backend $corrupt
    try {
        $badList = Await ($badBackend.LoadCatalogAsync($custom))
        Check ($badList.Hosts.Count -eq 2 -and $badList.Warnings.Count -eq 1) 'corrupt app store does not hide valid SSH aliases'
        Reject { Await ($badBackend.SaveServerAsync('must not replace', $json)) } 'save refuses corrupt store'
        Check ([IO.File]::ReadAllText($corrupt) -ceq '{BROKEN-STORE-PRESERVE-ME') 'corrupt bytes retained exactly'
    } finally { $badBackend.Dispose() }

    # Two separate Windows processes write the same store concurrently. This
    # exercises the OS file lock, not merely an in-process C# monitor.
    $parallelStore = Join-Path $scratch 'parallel\servers.json'
    $fixturePath = Join-Path $scratch 'parallel-profile.json'; Write-Text $fixturePath $json
    $writer = Join-Path $scratch 'writer.ps1'
    Write-Text $writer @'
param($Assembly, $Root, $Store, $Profile, $Name, $Result)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Web.Extensions
[void][Reflection.Assembly]::LoadFrom($Assembly)
$backend = New-Object CodexTunnelGui.TunnelBackend($Root)
$backend.GetType().GetProperty('ServersPath').SetValue($backend,$Store,$null)
try { $task=$backend.SaveServerAsync($Name,[IO.File]::ReadAllText($Profile)); $entry=$task.GetAwaiter().GetResult(); [IO.File]::WriteAllText($Result,$entry.Id) }
finally { $backend.Dispose() }
'@
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    foreach ($number in 1..2) {
        $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$writer,$BackendAssembly,$root,$parallelStore,$fixturePath,('parallel-' + $number),(Join-Path $scratch ('result-' + $number + '.txt')))
        $quoted = ($arguments | ForEach-Object { '"' + $_.Replace('"','\"') + '"' }) -join ' '
        $processes += Start-Process -FilePath $powershell -ArgumentList $quoted -WindowStyle Hidden -PassThru
    }
    foreach ($process in $processes) { Check ($process.WaitForExit(45000)) 'concurrent writer completes within deadline'; Check ($process.ExitCode -eq 0) 'concurrent writer exits successfully' }
    $parallel = [IO.File]::ReadAllText($parallelStore) | ConvertFrom-Json
    Check ($parallel.servers.Count -eq 2) 'cross-process additions both survive'
    Check (($parallel.servers.name | Sort-Object) -join ',' -eq 'parallel-1,parallel-2') 'cross-process store contains both distinct records'
    Check (@(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($parallelStore)) -Filter '*.tmp').Count -eq 0) 'atomic writers leave no temporary files'
    $lockedBackend = New-Backend $parallelStore
    $held = [IO.File]::Open(($parallelStore + '.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $waiting = $lockedBackend.SaveServerAsync('waits for lock', $json)
        Start-Sleep -Seconds 3
        Check (-not $waiting.IsCompleted) 'save waits while another process owns catalog lock'
    } finally { $held.Dispose() }
    try {
        [void](Await $waiting)
        Check (([IO.File]::ReadAllText($parallelStore) | ConvertFrom-Json).servers.Count -eq 3) 'waiting save reloads and preserves existing records after lock released'
    } finally { $lockedBackend.Dispose() }
    $backend.Dispose(); $backend=$null
    Write-Output ('PASS: {0} server catalog assertions (isolated fixtures, no SSH connection)' -f $script:passed)
} finally {
    if ($backend) { $backend.Dispose() }; if ($second) { $second.Dispose() }
    foreach ($process in $processes) { if (-not $process.HasExited) { $process.Kill() }; $process.Dispose() }
    # Only delete this generated and fully resolved temp fixture directory.
    $resolved = [IO.Path]::GetFullPath($scratch)
    if ([IO.Path]::GetDirectoryName($resolved) -eq [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -and [IO.Path]::GetFileName($resolved).StartsWith('codex-catalog-tests-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
