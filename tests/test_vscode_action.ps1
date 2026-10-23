param([string]$BackendAssembly = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('codex-vscode-action-tests-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $scratch 'fixture'
$markers = Join-Path $scratch 'markers'
$utf8 = New-Object Text.UTF8Encoding $false
[void][IO.Directory]::CreateDirectory($fixture)
[void][IO.Directory]::CreateDirectory($markers)
try {
    foreach ($name in @('TunnelTools.ps1','ProxyTools.ps1','SshImport.ps1','remote-monitor.sh','remote-vscode-config.sh','remote-vscode-config.js','read.md')) {
        [IO.File]::WriteAllText((Join-Path $fixture $name), '# fixture', $utf8)
    }
    $api = @'
param([string]$RequestPath, [string]$ResponsePath)
$request = [IO.File]::ReadAllText($RequestPath) | ConvertFrom-Json
if ($request.operation -ne 'prepare') { exit 9 }
if ($request.sessionPath -ne $request.savePath -and $request.profileJson -notmatch 'tunnel') { exit 8 }
[IO.File]::WriteAllText($request.sessionPath, $request.profileJson)
[IO.File]::WriteAllText($ResponsePath, '{"ok":true,"result":{"Prepared":true}}')
'@
    [IO.File]::WriteAllText((Join-Path $fixture 'Gui-Api.ps1'), $api, $utf8)
    $launcher = @'
param([switch]$ExecutableHost,[switch]$NoPrompt,[switch]$ConfigureVscode,[string]$ConfigPath,[string]$GuiStatusPath,[string]$NativeSnapshotDirectory,[string]$NativeAlias,[string]$NativeSshPath,[string]$SshConfigPath)
$markers = '__MARKERS__'
$profile = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
$label = $profile.label
if ($ConfigureVscode) {
    [IO.File]::WriteAllText((Join-Path $NativeSnapshotDirectory 'config-000.conf'), '# temporary fixture')
    [IO.File]::WriteAllText((Join-Path $markers ($label + '.snapshot')), $NativeSnapshotDirectory)
    [IO.File]::WriteAllText((Join-Path $markers ($label + '.args')), ($NativeAlias + '|' + $NativeSshPath + '|' + $SshConfigPath))
}
if ($label -eq 'success') { [IO.File]::WriteAllText($GuiStatusPath, '{"phase":"configured","changed":true,"targets":2}'); exit 0 }
if ($label -eq 'idempotent') { [IO.File]::WriteAllText($GuiStatusPath, '{"phase":"configured","changed":false,"targets":1}'); exit 0 }
if ($label -eq 'malformed') { [IO.File]::WriteAllText($GuiStatusPath, '{"phase":"error","message":"fixture malformed settings"}'); exit 1 }
if ($label -eq 'unconfirmed') { [IO.File]::WriteAllText($GuiStatusPath, '{"phase":"configured","changed":true,"targets":2}'); exit 7 }
$child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList '-NoProfile -Command "Start-Sleep -Seconds 300"' -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText((Join-Path $markers ($label + '.pids')), ($PID.ToString() + ',' + $child.Id.ToString()))
Start-Sleep -Seconds 300
'@
    [IO.File]::WriteAllText((Join-Path $fixture 'Start-Tunnel.ps1'), $launcher.Replace('__MARKERS__', $markers.Replace("'", "''")), $utf8)
    $harness = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using CodexTunnelGui;
public static class VscodeActionTests {
    static int passed; static string markers;
    static void Assert(bool condition, string message) { if (!condition) throw new Exception("FAIL: " + message); passed++; }
    static void Wait(Func<bool> predicate, string message) { Stopwatch clock=Stopwatch.StartNew(); while (!predicate() && clock.ElapsedMilliseconds<12000) Thread.Sleep(30); Assert(predicate(),message); }
    static ProfileInfo Profile(string name) { return new ProfileInfo { Json="{\"label\":\"" + name + "\",\"checkIntervalSeconds\":60}" }; }
    static bool Alive(int pid) { try { using (Process p=Process.GetProcessById(pid)) return !p.HasExited; } catch(ArgumentException) { return false; } }
    static int[] Pids(string name) { string path=Path.Combine(markers,name+".pids"); Wait(delegate { return File.Exists(path); },name+" starts"); return Array.ConvertAll(File.ReadAllText(path).Split(','),Int32.Parse); }
    static void Dead(int[] pids) { Wait(delegate { return !Alive(pids[0]) && !Alive(pids[1]); },"owned process tree ends"); }
    static void Failed(Task<VscodeConfigResult> task) { Wait(delegate { return task.IsCompleted; },"failed task completes"); Assert(task.IsFaulted || task.IsCanceled,"failure never returns success"); if (task.IsFaulted) { Exception observed=task.Exception; } }
    static TunnelBackend Backend(string fixture) { return (TunnelBackend)typeof(TunnelBackend).GetConstructor(BindingFlags.Instance|BindingFlags.NonPublic,null,new Type[]{typeof(string),typeof(bool)},null).Invoke(new object[]{fixture,false}); }
    static string Runtime(TunnelBackend backend) { object value=typeof(TunnelBackend).GetField("runtime",BindingFlags.Instance|BindingFlags.NonPublic).GetValue(backend); return (string)value.GetType().GetProperty("DirectoryPath",BindingFlags.Instance|BindingFlags.NonPublic).GetValue(value,null); }
    public static int Run(string fixture,string markerPath) {
        markers=markerPath; TunnelBackend backend=null;
        try {
            backend=Backend(fixture); string runtime=Runtime(backend);
            string never=Path.Combine(markers,"never-persist.json");
            typeof(TunnelBackend).GetProperty("ProfilePath").GetSetMethod(true).Invoke(backend,new object[]{never});
            backend.Start(Profile("tunnel"),11082,0); int[] tunnel=Pids("tunnel");
            ProfileInfo success=Profile("success"); success.NativeAlias="fixture host"; success.NativeSshPath="C:\\fixture path\\ssh.exe"; success.NativeConfigPath="C:\\fixture path\\config";
            Task<VscodeConfigResult> task=backend.ConfigureVscodeAsync(success,12082);
            success.NativeAlias="changed later";
            Assert(backend.IsConfiguringVscode,"pending action is observable");
            bool duplicate=false; try { backend.ConfigureVscodeAsync(Profile("success"),12082); } catch(InvalidOperationException) { duplicate=true; }
            Assert(duplicate,"duplicate configuration rejected");
            VscodeConfigResult result=task.GetAwaiter().GetResult();
            Assert(result.Changed && result.Targets==2,"confirmed success fields returned");
            Assert(File.ReadAllText(Path.Combine(markers,"success.args")).StartsWith("fixture host|"),"selected metadata is snapshotted");
            Assert(!Directory.Exists(File.ReadAllText(Path.Combine(markers,"success.snapshot"))),"successful snapshot cleaned");
            Assert(!backend.IsConfiguringVscode && backend.IsRunning && Alive(tunnel[0]),"success leaves active tunnel alive");
            Assert(!File.Exists(never),"action never writes persistent profile");
            result=backend.ConfigureVscodeAsync(Profile("idempotent"),12082).GetAwaiter().GetResult();
            Assert(!result.Changed && result.Targets==1,"unchanged settings result preserved");
            Failed(backend.ConfigureVscodeAsync(Profile("malformed"),12082));
            Failed(backend.ConfigureVscodeAsync(Profile("unconfirmed"),12082));
            Assert(backend.IsRunning && Alive(tunnel[0]),"configuration failure preserves running tunnel");
            task=backend.ConfigureVscodeAsync(Profile("cancel"),12082); int[] cancelled=Pids("cancel");
            backend.CancelVscodeConfiguration(); Failed(task); Dead(cancelled);
            Assert(backend.IsRunning && Alive(tunnel[0]),"action cancel preserves running tunnel");
            Assert(!Directory.Exists(File.ReadAllText(Path.Combine(markers,"cancel.snapshot"))),"cancelled snapshot cleaned");
            typeof(TunnelBackend).GetField("vscodeTimeoutMilliseconds",BindingFlags.Instance|BindingFlags.NonPublic).SetValue(backend,2000);
            task=backend.ConfigureVscodeAsync(Profile("timeout"),12082); int[] timeout=Pids("timeout"); Failed(task); Dead(timeout);
            Assert(backend.IsRunning && Alive(tunnel[0]),"bounded action timeout preserves tunnel");
            typeof(TunnelBackend).GetField("vscodeTimeoutMilliseconds",BindingFlags.Instance|BindingFlags.NonPublic).SetValue(backend,300000);
            task=backend.ConfigureVscodeAsync(Profile("dispose"),12082); int[] disposed=Pids("dispose");
            backend.Stop(); Dead(tunnel); Assert(!task.IsCompleted && Alive(disposed[0]),"stopping tunnel does not cancel independent configuration");
            backend.Dispose(); backend=null; Failed(task); Dead(disposed);
            Wait(delegate { return !Directory.Exists(runtime); },"dispose removes runtime and owned snapshots");
            Console.WriteLine("PASS: "+passed+" VS Code action lifecycle assertions (isolated fixtures)"); return 0;
        } catch(Exception error) { Console.Error.WriteLine(error); return 1; }
        finally { if(backend!=null) backend.Dispose(); }
    }
}
'@
    $source = Join-Path $scratch 'VscodeActionTests.cs'
    [IO.File]::WriteAllText($source, $harness, $utf8)
    $framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
    $output = Join-Path $scratch 'VscodeActionTests.dll'
    $arguments = @('/nologo','/target:library','/warn:4','/warnaserror+',('/out:' + $output),('/reference:' + (Join-Path $framework 'System.Web.Extensions.dll')), $source)
    if ($BackendAssembly) { $arguments += '/reference:' + [IO.Path]::GetFullPath($BackendAssembly); [void][Reflection.Assembly]::LoadFrom([IO.Path]::GetFullPath($BackendAssembly)) }
    else { $arguments += (Join-Path $root 'gui\TunnelBackend.cs'); $arguments += (Join-Path $root 'gui\ServerCatalog.cs') }
    & (Join-Path $framework 'csc.exe') @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Action harness compilation failed.' }
    [void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($output))
    if ([VscodeActionTests]::Run($fixture, $markers) -ne 0) { throw 'Action lifecycle tests failed.' }
} finally {
    $resolved = [IO.Path]::GetFullPath($scratch)
    if ([IO.Path]::GetDirectoryName($resolved) -eq [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -and [IO.Path]::GetFileName($resolved).StartsWith('codex-vscode-action-tests-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Continue
    }
}
