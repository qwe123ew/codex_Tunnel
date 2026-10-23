$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'ProxyTools.ps1')
$utf8 = New-Object Text.UTF8Encoding $false
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('codex-vscode-launcher-tests-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $scratch 'private runtime'
$markers = Join-Path $scratch 'markers'
$passed = 0
function Check($condition, $message) { if (-not $condition) { throw ('FAIL: ' + $message) }; $script:passed++ }
try {
    [void][IO.Directory]::CreateDirectory($fixture); [void][IO.Directory]::CreateDirectory($markers)
    foreach ($name in @('Start-Tunnel.ps1','TunnelTools.ps1','ProxyTools.ps1','SshImport.ps1','remote-vscode-config.sh','remote-vscode-config.js')) {
        Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $fixture $name)
    }
    $source = @'
using System;
using System.IO;
using System.Text;
class VscodeSshFixture {
    static int Main(string[] args) {
        string markers = @"__MARKERS__";
        if (Array.IndexOf(args,"-G")>=0) {
            Console.WriteLine("hostname native.example.org"); Console.WriteLine(@"user domain\fixture"); Console.WriteLine("port 2222"); return 0;
        }
        File.WriteAllLines(Path.Combine(markers,"arguments.txt"),args,new UTF8Encoding(false));
        int index=Array.IndexOf(args,"-F");
        File.WriteAllText(Path.Combine(markers,"snapshot.txt"),File.ReadAllText(args[index+1]));
        File.WriteAllText(Path.Combine(markers,"payload.txt"),Console.In.ReadToEnd(),new UTF8Encoding(false));
        string mode=File.ReadAllText(Path.Combine(markers,"mode.txt"));
        Console.WriteLine("UNTRUSTED_PRIVATE_REMOTE_OUTPUT");
        if(mode=="success") { Console.WriteLine("VSCODE_CONFIGURED changed=1 targets=2"); return 0; }
        if(mode=="unchanged") { Console.WriteLine("VSCODE_CONFIGURED changed=0 targets=1"); return 0; }
        if(mode=="badexit") { Console.WriteLine("VSCODE_CONFIGURED changed=1 targets=1"); return 7; }
        if(mode=="malformed") { Console.WriteLine("VSCODE_ERROR code=malformed_settings"); return 1; }
        if(mode=="partial") { Console.WriteLine("VSCODE_ERROR code=partial_write"); return 1; }
        if(mode=="invalid") { Console.WriteLine("VSCODE_CONFIGURED changed=1 targets=999"); return 0; }
        Console.WriteLine("VSCODE_ERROR code=untrusted_code"); return 1;
    }
}
'@
    $source = $source.Replace('__MARKERS__', $markers.Replace('"','""'))
    $cs = Join-Path $scratch 'fixture.cs'; $ssh = Join-Path $scratch 'fixture ssh.exe'
    [IO.File]::WriteAllText($cs, $source, $utf8)
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $build = Invoke-ProxyProcess -FileName $compiler -Arguments @('/nologo','/target:exe',('/out:'+$ssh),$cs) -TimeoutSeconds 20
    Check ($build.ExitCode -eq 0) 'fixture SSH compiles'
    # Private runtime overrides cannot access real local proxy or remote servers.
    $override = @'

function Find-TunnelProgram { param([string]$Name) if ($Name -ne 'ssh') { throw 'Proxy probing must not run during settings action.' }; return '__SSH__' }
'@
    [IO.File]::AppendAllText((Join-Path $fixture 'TunnelTools.ps1'), $override.Replace('__SSH__',$ssh.Replace("'","''")), $utf8)
    $config = Join-Path $scratch 'original config'
    $configText = "Host fixture`n HostName native.example.org`n User domain\fixture`n Port 2222`n IdentityFile relative-key`n ProxyCommand ssh gateway -W %h:%p`n LocalForward 32001 localhost:80`n RemoteForward 32002 localhost:81`n DynamicForward 32003`n RemoteCommand original-command`n"
    [IO.File]::WriteAllText($config,$configText,$utf8)
    $before = (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
    $profile = Join-Path $scratch 'profile.json'
    [IO.File]::WriteAllText($profile,'{"version":1,"server":{"host":"manual.example.org","user":"fixture","port":2222,"identityFile":"none"},"jumpHosts":[{"host":"jump.example.org","user":"jumpuser","port":22,"identityFile":"none"}],"remotePort":12082,"checkIntervalSeconds":60}',$utf8)
    $status = Join-Path $scratch 'status.json'
    foreach ($case in @(@{Kind='native';Mode='success'},@{Kind='manual';Mode='unchanged'},@{Kind='native';Mode='malformed'},@{Kind='manual';Mode='badexit'},@{Kind='manual';Mode='invalid'},@{Kind='manual';Mode='unknown'},@{Kind='manual';Mode='partial'})) {
        [IO.File]::WriteAllText((Join-Path $markers 'mode.txt'),$case.Mode,$utf8)
        $snapshot = Join-Path $scratch ('snapshot-'+$case.Kind+'-'+$case.Mode)
        [void][IO.Directory]::CreateDirectory($snapshot)
        $args = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $fixture 'Start-Tunnel.ps1'),'-ConfigureVscode','-NoPrompt','-ConfigPath',$profile,'-GuiStatusPath',$status,'-NativeSnapshotDirectory',$snapshot)
        if ($case.Kind -eq 'native') { $args += @('-NativeAlias','fixture','-SshConfigPath',$config,'-NativeSshPath',$ssh) }
        $run = Invoke-ProxyProcess -FileName (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -Arguments $args -TimeoutSeconds 25
        Check (-not $run.TimedOut) ($case.Mode + ' completes within timeout')
        $result = [IO.File]::ReadAllText($status) | ConvertFrom-Json
        if ($case.Mode -in @('success','unchanged')) {
            Check ($run.ExitCode -eq 0 -and $result.phase -eq 'configured') ($case.Kind+' configures successfully')
            Check ($result.changed -eq ($case.Mode -eq 'success')) 'changed boolean preserved'
        } else { Check ($run.ExitCode -ne 0 -and $result.phase -eq 'error') ($case.Mode+' cannot report configured') }
        if ($case.Mode -eq 'malformed') { Check ($result.message -match 'JSON') 'fixed malformed-settings diagnostic surfaced' }
        if ($case.Mode -eq 'partial') { Check ($result.message -match 'settings.json.codex-tunnel-backup-') 'partial write directs user to retained backups' }
        Check (([IO.File]::ReadAllText($status)) -notmatch 'UNTRUSTED_PRIVATE_REMOTE_OUTPUT|untrusted_code') 'untrusted output cannot reach GUI IPC'
        $seen = [IO.File]::ReadAllLines((Join-Path $markers 'arguments.txt'))
        Check ($seen -notcontains '-R' -and $seen -contains 'ClearAllForwardings=yes') 'action reserves no tunnel ports'
        Check ($seen[$seen.Length-1] -eq "tr -d '\r' | sh -s -- 12082") 'only validated numeric port reaches remote command'
        $captured = [IO.File]::ReadAllText((Join-Path $markers 'snapshot.txt'))
        Check ($captured -notmatch 'LocalForward|RemoteForward|DynamicForward|original-command') 'all inherited forwarding and session commands removed'
        if ($case.Kind -eq 'native') { Check ($captured -match 'ProxyCommand ssh gateway -W %h:%p' -and $captured -match 'IdentityFile relative-key') 'native authentication route preserved' }
        else { Check ($captured -match 'ProxyJump portable-jump-1' -and $captured -match 'HostName jump.example.org') 'manual jump route preserved' }
        $payload = [IO.File]::ReadAllText((Join-Path $markers 'payload.txt'))
        Check ($payload -notmatch '__CODEX_TUNNEL_VSCODE_JS__' -and $payload -match 'http.useLocalProxyConfiguration') 'complete patcher embedded and streamed'
        Check (-not (Test-Path -LiteralPath $snapshot)) 'owned action snapshot cleaned'
    }
    Check ((Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash -ceq $before) 'original SSH bytes preserved'
    Write-Output ('PASS: '+$passed+' VS Code launcher assertions (synthetic SSH; no login/network)')
} finally {
    $resolved = [IO.Path]::GetFullPath($scratch)
    if ([IO.Path]::GetDirectoryName($resolved) -eq [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -and [IO.Path]::GetFileName($resolved).StartsWith('codex-vscode-launcher-tests-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Continue
    }
}
