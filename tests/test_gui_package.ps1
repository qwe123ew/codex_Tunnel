param([Parameter(Mandatory = $true)][string]$Executable)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('gui portable 中文 ' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
$backend = $null
$passed = 0
function Check($condition, $message) {
    if (-not $condition) { throw ('FAIL: ' + $message) }
    $script:passed++
}
try {
    # Only the EXE is copied. All backend scripts must come from its resources.
    $portable = Join-Path $scratch '隧道 程序.exe'
    Copy-Item -LiteralPath ([IO.Path]::GetFullPath($Executable)) -Destination $portable
    Add-Type -AssemblyName System.Web.Extensions
    # Load copied bytes so this test process does not lock its disposable EXE.
    $assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($portable))
    $names = @($assembly.GetManifestResourceNames())
    Check ($names.Count -eq 10) 'nine public runtime resources plus one branding icon'
    foreach ($name in $names) {
        if ($name -eq 'CodexTunnelGui.Brand.app.ico') {
            Check $true 'branding resource allowlist'
            $source = Join-Path $root 'gui/assets/app.ico'
        } else {
            $leaf = $name.Replace('CodexTunnelGui.Runtime.', '')
            Check ($leaf -in @('Start-Tunnel.ps1','TunnelTools.ps1','ProxyTools.ps1','SshImport.ps1','remote-monitor.sh','remote-vscode-config.sh','remote-vscode-config.js','read.md','Gui-Api.ps1')) 'runtime resource allowlist'
            $source = if ($leaf -eq 'Gui-Api.ps1') { Join-Path $root ('gui/' + $leaf) } else { Join-Path $root $leaf }
        }
        $stream = $assembly.GetManifestResourceStream($name)
        $hash = [Security.Cryptography.SHA256]::Create()
        try {
            $actual = [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '')
            Check ($actual -eq (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash) 'embedded bytes match audited source'
        } finally { $stream.Dispose(); $hash.Dispose() }
    }
    Add-Type -AssemblyName PresentationCore
    $iconBytes = $assembly.GetManifestResourceStream('CodexTunnelGui.Brand.app.ico')
    try {
        $icon = [Windows.Media.Imaging.BitmapDecoder]::Create($iconBytes, [Windows.Media.Imaging.BitmapCreateOptions]::None, [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        Check ($icon.Frames.Count -eq 9) 'Windows decoder accepts all nine icon resolutions'
        Check (($icon.Frames.PixelWidth -join ',') -eq '16,20,24,32,40,48,64,128,256') 'icon covers title bar through high-DPI Explorer sizes'
    } finally { $iconBytes.Dispose() }
    $backend = New-Object CodexTunnelGui.TunnelBackend
    $runtime = $backend.GetType().GetField('runtime', [Reflection.BindingFlags]'Instance,NonPublic').GetValue($backend)
    $runtimePath = $runtime.GetType().GetProperty('DirectoryPath', [Reflection.BindingFlags]'Instance,NonPublic').GetValue($runtime, $null)
    Check (Test-Path -LiteralPath (Join-Path $runtimePath 'Gui-Api.ps1')) 'default backend extracts embedded resources'
    $config = Join-Path $scratch 'SSH 配置.conf'
    [IO.File]::WriteAllText($config, "Host portable-fixture`n HostName gpu.example.org`n User tester`n Port 2222`n IdentityFile none`n")
    $profileBefore = if (Test-Path -LiteralPath $backend.ProfilePath) { (Get-FileHash -LiteralPath $backend.ProfilePath -Algorithm SHA256).Hash } else { 'absent' }
    $entries = $backend.LoadHostsAsync($config).GetAwaiter().GetResult()
    Check ($entries.Count -eq 1 -and $entries[0].Alias -eq 'portable-fixture') 'embedded helper lists fixture from Unicode path'
    $profile = $backend.ResolveHostAsync('portable-fixture', $config).GetAwaiter().GetResult()
    Check ($profile.Host -eq 'gpu.example.org' -and $profile.User -eq 'tester' -and $profile.Port -eq 2222) 'embedded helper resolves fixture with native ssh -G'
    Check (-not $backend.IsRunning) 'read-only package test never starts SSH tunnel'
    $profileAfter = if (Test-Path -LiteralPath $backend.ProfilePath) { (Get-FileHash -LiteralPath $backend.ProfilePath -Algorithm SHA256).Hash } else { 'absent' }
    Check ($profileBefore -eq $profileAfter) 'read-only operations preserve GUI profile'
    $nativeEntry = New-Object CodexTunnelGui.HostEntry
    $nativeEntry.Kind = 'ssh'; $nativeEntry.Alias = 'portable-fixture'; $nativeEntry.ConfigPath = $config
    $nativeProfile = $backend.ResolveEntryAsync($nativeEntry).GetAwaiter().GetResult()
    Check ($nativeProfile.Host -eq 'gpu.example.org' -and $nativeProfile.NativeAlias -eq 'portable-fixture' -and $nativeProfile.NativeConfigPath -eq $config) 'standalone embedded native SSH flow resolves selected source'
    Check (@(Get-ChildItem -LiteralPath $runtimePath -Directory -Filter 'native-*').Count -eq 0) 'native preview snapshot is cleaned after embedded operation'
    # Exercise the new-computer flow using an application-owned fixture store,
    # with no SSH config and no real AppData writes or server connection.
    $storePath = Join-Path $scratch 'saved servers.json'
    $backend.GetType().GetProperty('ServersPath').SetValue($backend, $storePath, $null)
    $manualJson = '{"version":1,"server":{"host":"gpu.example.org","user":"researcher","port":2222,"identityFile":"none"},"jumpHosts":[{"host":"gateway.example.org","user":"first","port":2200,"identityFile":"none"},{"host":"login.example.org","user":"second","port":22,"identityFile":"none"}],"remotePort":12082,"checkIntervalSeconds":60}'
    $saved = $backend.SaveServerAsync('Portable saved server', $manualJson, $null).GetAwaiter().GetResult()
    Check ($saved.Kind -eq 'saved' -and $saved.Id) 'manual add returns a selectable saved entry'
    $catalog = $backend.LoadCatalogAsync((Join-Path $scratch 'missing ssh config')).GetAwaiter().GetResult()
    Check ($catalog.Hosts.Count -eq 1 -and $catalog.Hosts[0].Id -eq $saved.Id) 'saved server works with no SSH configuration'
    $savedProfile = $backend.ResolveEntryAsync($catalog.Hosts[0]).GetAwaiter().GetResult()
    Check ($savedProfile.Host -eq 'gpu.example.org' -and $savedProfile.JumpCount -eq 2) 'embedded validation preserves manual server and ordered jumps'
    Check ((($savedProfile.Json | ConvertFrom-Json).remotePort) -eq 12082) 'saved remote proxy port is preserved'
    Check (-not $backend.IsRunning) 'saving and resolving never starts a tunnel'
    $backend.Dispose(); $backend = $null
    Check (-not (Test-Path -LiteralPath $runtimePath)) 'embedded runtime is cleaned on dispose'
    Write-Host "PASS: $passed portable GUI package checks (no server login or network)"
} finally {
    if ($null -ne $backend) { $backend.Dispose() }
    $resolved = [IO.Path]::GetFullPath($scratch)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolved) -eq $tempRoot -and [IO.Path]::GetFileName($resolved).StartsWith('gui portable 中文 ')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
