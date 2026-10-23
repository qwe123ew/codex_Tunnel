$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'ProxyTools.ps1')
$utf8 = New-Object Text.UTF8Encoding $false
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('native launcher test ' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $scratch 'private runtime'
$markers = Join-Path $scratch 'markers'
$script:passed = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
}
$child = $null
try {
    [void][IO.Directory]::CreateDirectory($fixture)
    [void][IO.Directory]::CreateDirectory($markers)
    foreach ($name in @('Start-Tunnel.ps1', 'TunnelTools.ps1', 'ProxyTools.ps1', 'SshImport.ps1', 'remote-monitor.sh')) {
        Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $fixture $name)
    }
    # Overrides exist only in this test's private runtime. No listener, proxy,
    # network, installed SSH client or real server is used during launch.
    $proxyFixture = @'

function Get-ProxyCandidates {
    param([int]$ManualPort)
    return [pscustomobject]@{ Url = 'http://127.0.0.1:17897'; Source = 'isolated fixture' }
}
function Test-HttpProxy {
    param([string]$ProxyUrl, [string]$CurlPath, [int]$TimeoutSeconds)
    return [pscustomobject]@{ Success = $true; StatusCode = 401; Message = 'isolated fixture' }
}
'@
    [IO.File]::AppendAllText((Join-Path $fixture 'ProxyTools.ps1'), $proxyFixture, $utf8)
    $source = @'
using System;
using System.IO;
using System.Text;
class NativeSshFixture {
    static int Main(string[] args) {
        string marker = @"__MARKERS__";
        bool preview = Array.IndexOf(args, "-G") >= 0;
        int configIndex = Array.IndexOf(args, "-F");
        if (configIndex < 0 || configIndex + 1 >= args.Length || !File.Exists(args[configIndex + 1])) return 8;
        if (preview) {
            File.AppendAllText(Path.Combine(marker, "preview-count.txt"), "preview\n");
            Console.WriteLine("hostname native.example.org");
            Console.WriteLine(@"user domain\fixture");
            Console.WriteLine("port 2222");
            Console.WriteLine("identityfile missing-relative-key");
            Console.WriteLine("identitiesonly yes");
            return 0;
        }
        File.WriteAllLines(Path.Combine(marker, "arguments.txt"), args, new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(marker, "snapshot.txt"), File.ReadAllText(args[configIndex + 1]), new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(marker, "working-directory.txt"), Environment.CurrentDirectory);
        File.WriteAllText(Path.Combine(marker, "executable.txt"), System.Reflection.Assembly.GetExecutingAssembly().Location);
        File.WriteAllText(Path.Combine(marker, "monitor.txt"), Console.In.ReadToEnd(), new UTF8Encoding(false));
        Console.WriteLine("TUNNEL_READY target_http=401");
        return 0;
    }
}
'@
    $source = $source.Replace('__MARKERS__', $markers.Replace('"', '""'))
    $csPath = Join-Path $scratch 'NativeSshFixture.cs'
    $fakeSsh = Join-Path $scratch 'native fixture ssh.exe'
    [IO.File]::WriteAllText($csPath, $source, $utf8)
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $compile = Invoke-ProxyProcess -FileName $compiler -Arguments @('/nologo', '/target:exe', ('/out:' + $fakeSsh), $csPath) -TimeoutSeconds 20
    Assert-True ($compile.ExitCode -eq 0 -and (Test-Path -LiteralPath $fakeSsh)) 'isolated native SSH fixture compiles'
    $config = Join-Path $scratch 'original ssh.conf'
    $configText = @'
Host fixture
    HostName native.example.org
    User domain\fixture
    Port 2222
    IdentitiesOnly yes
    IdentityFile missing-relative-key
    HostKeyAlias native-fixture-key
    LocalForward 32101 localhost:80
    RemoteForward 32102 localhost:81
    RemoteCommand original-command
    ControlMaster auto
    ControlPath original-control-path
'@
    [IO.File]::WriteAllText($config, $configText, $utf8)
    $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($config))
    $profile = Join-Path $scratch 'native preferences.json'
    [IO.File]::WriteAllText($profile, '{"remotePort":12082,"checkIntervalSeconds":61}', $utf8)
    $status = Join-Path $scratch 'status.json'
    $snapshot = Join-Path $scratch 'owned snapshot'
    [void][IO.Directory]::CreateDirectory($snapshot)
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $fixture 'Start-Tunnel.ps1'),
        '-NativeAlias', 'fixture', '-SshConfigPath', $config, '-NativeSshPath', $fakeSsh,
        '-NativeSnapshotDirectory', $snapshot, '-ConfigPath', $profile, '-GuiStatusPath', $status, '-NoPrompt')
    $child = New-Object Diagnostics.Process
    $child.StartInfo = New-Object Diagnostics.ProcessStartInfo
    $child.StartInfo.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $child.StartInfo.Arguments = Join-ProxyProcessArguments $arguments
    $child.StartInfo.WorkingDirectory = $fixture
    $child.StartInfo.UseShellExecute = $false; $child.StartInfo.CreateNoWindow = $true
    $child.StartInfo.RedirectStandardOutput = $true; $child.StartInfo.RedirectStandardError = $true
    $child.StartInfo.StandardOutputEncoding = $utf8; $child.StartInfo.StandardErrorEncoding = $utf8
    [void]$child.Start()
    $stdoutTask = $child.StandardOutput.ReadToEndAsync(); $stderrTask = $child.StandardError.ReadToEndAsync()
    $finished = $child.WaitForExit(20000)
    if (-not $finished) { $child.Kill(); [void]$child.WaitForExit(2000) }
    Assert-True $finished 'real launcher completes within bounded fixture timeout'
    [void]$stdoutTask.Wait(1000); [void]$stderrTask.Wait(1000)
    $stdout = $stdoutTask.Result; $stderr = $stderrTask.Result
    Assert-True ($child.ExitCode -eq 0) ('real launcher exits successfully; fixture output: ' + $stdout + $stderr)
    Assert-True ($stdout -match 'TUNNEL_READY target_http=401') 'real launcher consumes and displays native monitor readiness'
    Assert-True ([IO.File]::ReadAllText((Join-Path $markers 'executable.txt')) -eq $fakeSsh) 'configured native executable is used for actual launch'
    $seen = [IO.File]::ReadAllLines((Join-Path $markers 'arguments.txt'))
    $forwardIndex = [Array]::IndexOf($seen, '-R')
    Assert-True ($forwardIndex -ge 0 -and $seen[$forwardIndex + 1] -eq '127.0.0.1:12082:127.0.0.1:17897') 'launcher passes configured remote port and verified proxy to reverse forward'
    Assert-True ($seen[$seen.Length - 2] -eq 'fixture' -and $seen[$seen.Length - 1] -eq "tr -d '\r' | sh -s -- 12082 61") 'native alias and numeric monitor command reach SSH as separate arguments'
    Assert-True ($seen -contains 'ClearAllForwardings=no' -and $seen -contains 'ExitOnForwardFailure=yes' -and $seen -contains '-T') 'native forwarding and noninteractive session controls reach actual SSH'
    $captured = [IO.File]::ReadAllText((Join-Path $markers 'snapshot.txt'))
    Assert-True ($captured -match 'IdentitiesOnly yes' -and $captured -match 'IdentityFile missing-relative-key' -and $captured -match 'HostKeyAlias native-fixture-key') 'launcher keeps native authentication settings and relative missing key reference'
    Assert-True ($captured -notmatch '32101|32102|original-command|original-control-path') 'launcher strips inherited forwards and session command/multiplexing effects'
    Assert-True ([IO.File]::ReadAllText((Join-Path $markers 'monitor.txt')) -match 'TUNNEL_READY') 'launcher sends the real monitor script through stdin'
    Assert-True ([IO.File]::ReadAllText((Join-Path $markers 'working-directory.txt')) -eq [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) 'relative native paths run from user home instead of extracted runtime'
    $finalStatus = [IO.File]::ReadAllText($status) | ConvertFrom-Json
    Assert-True ($finalStatus.phase -eq 'stopped' -and $finalStatus.proxyHttpStatus -eq 401 -and $finalStatus.sequence -ge 5) 'launcher publishes remote readiness and clean final GUI status'
    Assert-True (-not (Test-Path -LiteralPath $snapshot)) 'owned native snapshot files and directory are cleaned after exit'
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($config)) -ceq $before) 'original SSH configuration remains byte-identical after real launcher path'
    Write-Output ("PASS: {0} native launcher assertions (synthetic SSH/proxy; no login or network)" -f $script:passed)
} finally {
    if ($null -ne $child) {
        try { if (-not $child.HasExited) { $child.Kill(); [void]$child.WaitForExit(2000) } } catch { }
        $child.Dispose()
    }
    if ([IO.Path]::GetFullPath($scratch).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}
