param([string]$BackendAssembly = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('codex-gui-lifecycle-tests-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $scratch 'fixture'
$markers = Join-Path $scratch 'markers'
$utf8 = New-Object Text.UTF8Encoding $false
[void][IO.Directory]::CreateDirectory($fixture)
[void][IO.Directory]::CreateDirectory($markers)
$markerLiteral = $markers.Replace("'", "''")
try {
    # These allowlisted runtime fixtures never consult SSH, global configuration,
    # real proxies or the network. They exercise the compiled process/job code.
    foreach ($name in @('TunnelTools.ps1','ProxyTools.ps1','SshImport.ps1','remote-monitor.sh','remote-vscode-config.sh','remote-vscode-config.js','read.md')) {
        [IO.File]::WriteAllText((Join-Path $fixture $name), '# fixture', $utf8)
    }
    $apiFixture = @'
param([string]$RequestPath, [string]$ResponsePath)
$ErrorActionPreference = 'Stop'
$markers = '__MARKERS__'
$request = [IO.File]::ReadAllText($RequestPath) | ConvertFrom-Json
if ($request.operation -eq 'prepare') {
    $profile = $request.profileJson | ConvertFrom-Json
    if ($request.nativeAlias) {
        [IO.File]::WriteAllText((Join-Path $markers 'native-prepare.json'), (@{ alias=$request.nativeAlias; config=$request.nativeConfigPath; client=$request.nativeSshPath; preview=$request.nativePreviewDirectory } | ConvertTo-Json -Compress))
    }
    if ($profile.label -eq 'preparing') {
        $child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList '-NoProfile -Command "Start-Sleep -Seconds 300"' -WindowStyle Hidden -PassThru
        [IO.File]::WriteAllText((Join-Path $markers 'prepare.json'), (@{ parent = $PID; child = $child.Id } | ConvertTo-Json -Compress))
        Start-Sleep -Seconds 300
    }
    [IO.File]::WriteAllText($request.sessionPath, $request.profileJson)
    $result = @{ Prepared = $true }
} elseif ($request.operation -eq 'native-import') {
    [IO.File]::WriteAllText((Join-Path $request.nativePreviewDirectory 'config-000.conf'), '# native preview fixture snapshot')
    [IO.File]::WriteAllText((Join-Path $markers ('native-preview-' + $request.alias + '.txt')), $request.nativePreviewDirectory)
    if ($request.alias -eq 'cancel-preview') {
        $child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList '-NoProfile -Command "Start-Sleep -Seconds 300"' -WindowStyle Hidden -PassThru
        [IO.File]::WriteAllText((Join-Path $markers 'preview.json'), (@{ parent=$PID; child=$child.Id } | ConvertTo-Json -Compress))
        Start-Sleep -Seconds 300
    }
    $result = @{ Json='{"label":"native","checkIntervalSeconds":10}'; Host='native.example.org'; User='DOMAIN\researcher'; Port=2222; Route='OpenSSH native fixture'; JumpCount=1; NativeAlias=$request.alias; NativeConfigPath=$request.sshConfig; NativeSshPath=$request.sshPath }
} elseif ($request.operation -eq 'probe') {
    $child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList '-NoProfile -Command "Start-Sleep -Seconds 300"' -WindowStyle Hidden -PassThru
    [IO.File]::WriteAllText((Join-Path $markers 'helper.json'), (@{ parent = $PID; child = $child.Id } | ConvertTo-Json -Compress))
    Start-Sleep -Seconds 300
    $result = @{ Success = $false; Url = ''; Message = 'fixture'; StatusCode = 0 }
} else { $result = @() }
[IO.File]::WriteAllText($ResponsePath, (@{ ok = $true; result = $result; message = '' } | ConvertTo-Json -Depth 10 -Compress))
'@
    [IO.File]::WriteAllText((Join-Path $fixture 'Gui-Api.ps1'), $apiFixture.Replace('__MARKERS__', $markerLiteral), $utf8)
    $tunnelFixture = @'
param([switch]$ExecutableHost, [switch]$NoPrompt, [string]$ConfigPath, [string]$GuiStatusPath, [int]$ProxyPort, [string]$NativeAlias, [string]$SshConfigPath, [string]$NativeSshPath, [string]$NativeSnapshotDirectory)
$ErrorActionPreference = 'Stop'
$markers = '__MARKERS__'
$profile = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
$label = $profile.label
if ($NativeAlias) {
    [IO.File]::WriteAllText((Join-Path $NativeSnapshotDirectory 'config-000.conf'), '# fixture root snapshot')
    [IO.File]::WriteAllText((Join-Path $NativeSnapshotDirectory 'config-064.conf'), '# fixture final allowlisted snapshot')
    [IO.File]::WriteAllText((Join-Path $markers 'native-arguments.json'), (@{ alias=$NativeAlias; config=$SshConfigPath; client=$NativeSshPath; directory=$NativeSnapshotDirectory } | ConvertTo-Json -Compress))
}
trap { [IO.File]::WriteAllText((Join-Path $markers ($label + '.error.txt')), ($_ | Out-String)); exit 9 }
$child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList '-NoProfile -Command "Start-Sleep -Seconds 300"' -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText((Join-Path $markers ($label + '.json')), (@{ parent = $PID; child = $child.Id } | ConvertTo-Json -Compress))
function Set-Status([long]$Sequence, [string]$Phase, [int]$Http = 0) {
    $text = @{ Sequence = $Sequence; Phase = $Phase; Message = ('fixture ' + $label + ' ' + $Phase); ProxyUrl = 'http://127.0.0.1:12345'; HttpStatus = $Http; ProxyHttpStatus = 401 } | ConvertTo-Json -Compress
    $temp = $GuiStatusPath + '.tmp'
    [IO.File]::WriteAllText($temp, $text)
    if (Test-Path -LiteralPath $GuiStatusPath) { [IO.File]::Replace($temp, $GuiStatusPath, [System.Management.Automation.Language.NullString]::Value) }
    else { [IO.File]::Move($temp, $GuiStatusPath) }
}
Set-Status 1 'proxy-ready' 401
$last = ''
while ($true) {
    $commandPath = Join-Path $markers ($label + '.command')
    if (Test-Path -LiteralPath $commandPath) {
        $command = [IO.File]::ReadAllText($commandPath)
        if ($command -ne $last) {
            switch ($command) {
                'ready' { Set-Status 2 'ready' 401 }
                'stale' { Set-Status 1 'error' }
                'invalid' { Set-Status 3 'unrecognized' }
                'corrupt' { [IO.File]::WriteAllText($GuiStatusPath, '{broken') }
                'recover' { Set-Status 4 'degraded' 403 }
                'renewed' { Set-Status 5 'ready' 401 }
                'exit' { exit 7 }
            }
            $last = $command
        }
    }
    Start-Sleep -Milliseconds 50
}
'@
    [IO.File]::WriteAllText((Join-Path $fixture 'Start-Tunnel.ps1'), $tunnelFixture.Replace('__MARKERS__', $markerLiteral), $utf8)
    $harness = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using CodexTunnelGui;

public static class LifecycleTests
{
    private static int passed;
    private static readonly object gate = new object();
    private static readonly List<TunnelStatus> states = new List<TunnelStatus>();
    private static string markers;
    private static void Assert(bool value, string description) {
        if (!value) throw new Exception("FAIL: " + description);
        passed++;
    }
    private static void Wait(Func<bool> predicate, string description, int timeoutMilliseconds = 12000) {
        Stopwatch timer = Stopwatch.StartNew();
        while (!predicate() && timer.ElapsedMilliseconds < timeoutMilliseconds) Thread.Sleep(25);
        Assert(predicate(), description + " (last state: " + (Last() == null ? "none" : Last().Phase + ": " + Last().Message) + ")");
    }
    private static TunnelStatus Last() {
        lock (gate) return states.Count == 0 ? null : states[states.Count - 1];
    }
    private static bool Phase(string phase) { TunnelStatus status = Last(); return status != null && status.Phase == phase; }
    private static void Command(string label, string command) { File.WriteAllText(Path.Combine(markers, label + ".command"), command); }
    private static Dictionary<string, int> Pids(string label) {
        string path = Path.Combine(markers, label + ".json");
        Wait(delegate { return File.Exists(path) && new FileInfo(path).Length > 0; }, label + " fixture process tree starts");
        return new JavaScriptSerializer().Deserialize<Dictionary<string, int>>(File.ReadAllText(path));
    }
    private static bool Alive(int id) {
        try { using (Process process = Process.GetProcessById(id)) return !process.HasExited; }
        catch (ArgumentException) { return false; }
    }
    private static void Dead(Dictionary<string, int> pids, string label) {
        Wait(delegate { return !Alive(pids["parent"]) && !Alive(pids["child"]); }, label + " parent and descendant ended");
    }
    private static ProfileInfo Profile(string label) { return new ProfileInfo { Json = "{\"label\":\"" + label + "\",\"checkIntervalSeconds\":10}" }; }
    private static string Runtime(TunnelBackend backend) {
        object value = typeof(TunnelBackend).GetField("runtime", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(backend);
        return (string)value.GetType().GetProperty("DirectoryPath", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(value, null);
    }
    private static TunnelBackend Backend(string fixture) {
        ConstructorInfo fixtureConstructor = typeof(TunnelBackend).GetConstructor(BindingFlags.Instance | BindingFlags.NonPublic,
            null, new Type[] { typeof(string), typeof(bool) }, null);
        if (fixtureConstructor == null) throw new Exception("Backend lacks isolated hidden-console fixture constructor.");
        TunnelBackend backend = (TunnelBackend)fixtureConstructor.Invoke(new object[] { fixture, false });
        typeof(TunnelBackend).GetProperty("ProfilePath").GetSetMethod(true).Invoke(backend, new object[] { Path.Combine(markers, "never-user-profile.json") });
        backend.StatusChanged += delegate(TunnelStatus status) {
            lock (gate) states.Add(status);
            if (status.Phase == "error") {
                object owned = typeof(TunnelBackend).GetField("tunnel", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(backend);
                if (owned != null) {
                    object code = owned.GetType().GetProperty("ExitCode", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(owned, null);
                    Console.Error.WriteLine("Fixture tunnel child exit code: " + code);
                }
            }
        };
        return backend;
    }
    public static int Run(string[] args) {
        markers = args[1];
        TunnelBackend backend = null;
        Process unrelated = null;
        try {
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            unrelated = Process.Start(new ProcessStartInfo(powershell, "-NoProfile -Command \"Start-Sleep -Seconds 300\"") { UseShellExecute = false, CreateNoWindow = true });
            backend = Backend(args[0]);
            string runtime = Runtime(backend);
            backend.Start(Profile("preparing"), 11082, 0);
            Dictionary<string, int> preparing = Pids("prepare");
            Assert(backend.IsRunning, "pending prepare counts as a running start");
            backend.Stop();
            Assert(!backend.IsRunning, "Stop cancels before SSH process creation");
            backend.Start(Profile("first"), 11082, 0);
            Dead(preparing, "cancelled prepare helper");
            Dictionary<string, int> first = Pids("first");
            Wait(delegate { return Phase("proxy-ready"); }, "local proxy-ready IPC reaches backend");
            Thread.Sleep(450);
            Assert(Phase("proxy-ready"), "local proxy proof never promotes remote to ready");
            Assert(backend.IsRunning, "tunnel remains running while awaiting remote proof");
            Command("first", "ready");
            Wait(delegate { return Phase("ready"); }, "remote ready IPC reaches backend");
            Assert(Last().HttpStatus == 401, "remote target HTTP status is preserved");
            long sequence = Last().Sequence;
            foreach (string command in new string[] { "stale", "invalid", "corrupt" }) {
                Command("first", command); Thread.Sleep(650);
                Assert(Phase("ready") && Last().Sequence == sequence, command + " status cannot replace accepted state");
            }
            Command("first", "recover");
            Wait(delegate { return Phase("degraded"); }, "valid state resumes after malformed snapshot");
            // The minimum allowed profile interval is ten seconds. Exercise
            // actual expiry in the poll loop, not a duplicate of its formula.
            Console.WriteLine("Checking real heartbeat expiry (about 55 seconds)...");
            Wait(delegate { return Phase("unverified"); }, "missing heartbeat expires prior target verification", 61000);
            Assert(backend.IsRunning, "expired proof does not terminate a live tunnel");
            Assert(Last().ProxyHttpStatus == 401, "expiry preserves separate local proxy proof");
            Command("first", "renewed");
            Wait(delegate { return Phase("ready"); }, "fresh remote status restores ready after expiry");
            backend.Stop();
            Assert(!backend.IsRunning && Phase("stopped"), "Stop resets running state and publishes stopped");
            Dead(first, "Stop owned tunnel");
            Assert(!unrelated.HasExited, "Stop preserves unrelated process");
            backend.Start(Profile("second"), 11082, 0);
            Dictionary<string, int> second = Pids("second");
            Wait(delegate { return Phase("proxy-ready"); }, "restart reaches its own proxy phase");
            Assert(backend.IsRunning, "old cleanup cannot clear restarted state");
            Command("second", "exit");
            Wait(delegate { return Phase("error") && !backend.IsRunning; }, "unexpected process exit is an error");
            Dead(second, "unexpected-exit job cleanup");
            Assert(!unrelated.HasExited, "error cleanup preserves unrelated process");

            HostEntry nativeEntry = new HostEntry { Kind = "ssh", Alias = "existing-host",
                ConfigPath = Path.Combine(markers, "existing ssh config"), SshPath = Path.Combine(markers, "existing ssh.exe") };
            ProfileInfo native = backend.ResolveEntryAsync(nativeEntry).GetAwaiter().GetResult();
            Assert(native.NativeAlias == nativeEntry.Alias && native.NativeConfigPath == nativeEntry.ConfigPath
                && native.NativeSshPath == nativeEntry.SshPath, "SSH selection uses native API and preserves config/client metadata");
            Assert(native.User == @"DOMAIN\researcher", "native display metadata does not pass through restrictive manual-profile schema");
            string completedPreviewDirectory = File.ReadAllText(Path.Combine(markers, "native-preview-existing-host.txt"));
            Assert(!Directory.Exists(completedPreviewDirectory), "completed native preview snapshot is removed before returning");
            backend.Start(native, 11082, 0);
            native.NativeAlias = "changed-after-start";
            Dictionary<string, int> nativePids = Pids("native");
            Wait(delegate { return Phase("proxy-ready"); }, "native start reaches fixture tunnel");
            Dictionary<string, string> nativePrepare = new JavaScriptSerializer().Deserialize<Dictionary<string, string>>(File.ReadAllText(Path.Combine(markers, "native-prepare.json")));
            Assert(nativePrepare["alias"] == nativeEntry.Alias && nativePrepare["config"] == nativeEntry.ConfigPath
                && nativePrepare["client"] == nativeEntry.SshPath, "prepare receives original native metadata snapshot");
            Dictionary<string, string> nativeArguments = new JavaScriptSerializer().Deserialize<Dictionary<string, string>>(File.ReadAllText(Path.Combine(markers, "native-arguments.json")));
            Assert(nativeArguments["alias"] == nativeEntry.Alias && nativeArguments["config"] == nativeEntry.ConfigPath
                && nativeArguments["client"] == nativeEntry.SshPath, "native CLI arguments preserve whitespace and original metadata");
            string nativeDirectory = nativeArguments["directory"];
            Assert(nativePrepare["preview"] == nativeDirectory, "prepare and start previews share the owned session snapshot location");
            Assert(Path.GetDirectoryName(nativeDirectory) == runtime && Directory.Exists(nativeDirectory), "native snapshot directory belongs to this runtime only");
            backend.Stop();
            Dead(nativePids, "native Stop owned tunnel");
            Wait(delegate { return !Directory.Exists(nativeDirectory); }, "native snapshot files removed after child job ends");
            backend.Dispose(); backend = null;
            Wait(delegate { return !Directory.Exists(runtime); }, "completed runtime and IPC files are removed");

            lock (gate) states.Clear();
            backend = Backend(args[0]); runtime = Runtime(backend);
            Task<ProxyInfo> probe = backend.CheckProxyAsync(12345);
            Dictionary<string, int> helper = Pids("helper");
            Assert(!backend.IsRunning, "probe helper is not a running tunnel");
            backend.Dispose(); backend = null;
            Wait(delegate { return probe.IsCompleted; }, "Dispose cancels pending API task");
            Assert(probe.IsFaulted || probe.IsCanceled, "cancelled probe cannot return a successful result");
            if (probe.IsFaulted) { Exception observed = probe.Exception; }
            Dead(helper, "Dispose probe helper");
            Wait(delegate { return !Directory.Exists(runtime); }, "cancelled helper runtime is removed");
            Assert(!unrelated.HasExited, "window-close cleanup preserves unrelated process");

            backend = Backend(args[0]); runtime = Runtime(backend);
            Task<ProfileInfo> preview = backend.ResolveNativeHostAsync("cancel-preview", Path.Combine(markers, "never-user-config"), Path.Combine(markers, "never-ssh.exe"));
            Dictionary<string, int> previewPids = Pids("preview");
            string cancelledPreviewDirectory = File.ReadAllText(Path.Combine(markers, "native-preview-cancel-preview.txt"));
            Assert(Path.GetDirectoryName(cancelledPreviewDirectory) == runtime && File.Exists(Path.Combine(cancelledPreviewDirectory, "config-000.conf")), "native preview uses an owned runtime snapshot while helper runs");
            backend.Dispose(); backend = null;
            Wait(delegate { return preview.IsCompleted; }, "Dispose cancels a pending native preview");
            Assert(preview.IsFaulted || preview.IsCanceled, "cancelled native preview cannot return a result");
            if (preview.IsFaulted) { Exception observed = preview.Exception; }
            Dead(previewPids, "Dispose native preview helper");
            Wait(delegate { return !Directory.Exists(cancelledPreviewDirectory) && !Directory.Exists(runtime); }, "force-cancelled preview snapshot and runtime removed after helper job ends");
            Console.WriteLine("GUI backend lifecycle tests passed: " + passed);
            return 0;
        } catch (Exception error) {
            Console.Error.WriteLine(error.ToString());
            lock (gate) foreach (TunnelStatus state in states) Console.Error.WriteLine("Observed " + state.Sequence + " " + state.Phase + ": " + state.Message);
            foreach (string errorFile in Directory.GetFiles(markers, "*.error.txt")) Console.Error.WriteLine(File.ReadAllText(errorFile));
            return 1;
        }
        finally {
            if (backend != null) backend.Dispose();
            if (unrelated != null) { try { if (!unrelated.HasExited) unrelated.Kill(); unrelated.WaitForExit(3000); } catch {} unrelated.Dispose(); }
        }
    }
}
'@
    $harnessPath = Join-Path $scratch 'LifecycleTests.cs'
    [IO.File]::WriteAllText($harnessPath, $harness, $utf8)
    $framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
    $assemblyPath = Join-Path $scratch 'LifecycleTests.dll'
    $compilerArgs = @('/nologo','/target:library','/warn:4','/warnaserror+',('/out:' + $assemblyPath),('/reference:' + (Join-Path $framework 'System.Web.Extensions.dll')), $harnessPath)
    if ($BackendAssembly) {
        $assembly = [IO.Path]::GetFullPath($BackendAssembly)
        $compilerArgs += '/reference:' + $assembly
        [void][Reflection.Assembly]::LoadFrom($assembly)
    } else {
        $compilerArgs += Join-Path $root 'gui\TunnelBackend.cs'
        $compilerArgs += Join-Path $root 'gui\ServerCatalog.cs'
    }
    & (Join-Path $framework 'csc.exe') @compilerArgs
    if ($LASTEXITCODE -ne 0) { throw 'Lifecycle harness compilation failed.' }
    [void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($assemblyPath))
    if ([LifecycleTests]::Run(@($fixture, $markers)) -ne 0) { throw 'GUI backend lifecycle tests failed.' }
} finally {
    $resolved = [IO.Path]::GetFullPath($scratch)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolved) -eq $tempRoot -and [IO.Path]::GetFileName($resolved).StartsWith('codex-gui-lifecycle-tests-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Continue
    }
}
