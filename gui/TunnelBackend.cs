using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace CodexTunnelGui
{
    public sealed class HostEntry
    {
        public string Alias, SourceFile, Id, Kind, ConfigPath, SourceLabel, SshPath;
        public override string ToString() { return (Alias ?? "") + (String.IsNullOrEmpty(SourceLabel) ? "" : "  ·  " + SourceLabel); }
    }
    public sealed class HostCatalog
    {
        public HostEntry[] Hosts;
        public string[] Warnings, ConfigPaths;
        public string Summary;
    }
    public sealed class ProfileInfo
    {
        public string Json, Host, User, Route, NativeAlias, NativeConfigPath, NativeSshPath;
        public int Port, JumpCount;
    }
    public sealed class ProxyInfo
    {
        public bool Success;
        public string Url, Message;
        public int StatusCode;
    }
    public sealed class TunnelStatus
    {
        public string Phase, Message, ProxyUrl;
        public int HttpStatus, ProxyHttpStatus;
        public long Sequence;
    }
    public sealed class VscodeConfigResult
    {
        public bool Changed;
        public int Targets;
        public string Message;
    }
    internal sealed class VscodeActionStatus
    {
        public string Phase { get; set; }
        public string Message { get; set; }
        public bool Changed { get; set; }
        public int Targets { get; set; }
    }

    // All subprocesses are suspended until assigned to their own kill-on-close
    // job. Neither shutdown nor probing ever touches another application's SSH.
    public sealed class TunnelBackend : IDisposable
    {
        private readonly object gate = new object();
        private readonly GuiRuntimeFiles runtime;
        private readonly bool showAuthenticationConsole;
        private readonly HashSet<GuiOwnedProcess> helpers = new HashSet<GuiOwnedProcess>();
        private readonly CancellationTokenSource lifetime = new CancellationTokenSource();
        private GuiOwnedProcess tunnel;
        private GuiOwnedProcess vscodeAction;
        private CancellationTokenSource startCancellation;
        private CancellationTokenSource vscodeCancellation;
        private bool disposed, running;
        private bool configuringVscode;
        private int vscodeTimeoutMilliseconds = 300000;
        private int activeOperations;
        private long sequence, generation;
        // Injectable only through reflection in isolated fixture tests.
        private string catalogUserHome, catalogAppData;

        public event Action<TunnelStatus> StatusChanged;
        public event Action<string> Log;
        public bool IsRunning { get { lock (gate) { return running; } } }
        public bool IsConfiguringVscode { get { lock (gate) { return configuringVscode; } } }
        public string ProfilePath { get; private set; }
        public string ServersPath { get; private set; }

        public TunnelBackend() : this(null, true) { }
        // Source-directory injection makes integration tests independent of GUI
        // windows. Every allowlisted file is copied into an owned runtime folder.
        public TunnelBackend(string runtimeDirectory) : this(runtimeDirectory, true) { }
        // Internal fixture seam: all public application entry points retain the
        // visible authentication console required for SSH passwords and MFA.
        internal TunnelBackend(string runtimeDirectory, bool showAuthenticationConsole)
        {
            this.showAuthenticationConsole = showAuthenticationConsole;
            string localData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (String.IsNullOrWhiteSpace(localData)) { throw new IOException("无法确定应用配置目录。"); }
            ProfilePath = Path.Combine(localData, "CodexProxyTunnel", "gui-profile.json");
            ServersPath = Path.Combine(localData, "CodexProxyTunnel", "servers.json");
            catalogUserHome = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            catalogAppData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            runtime = new GuiRuntimeFiles(runtimeDirectory);
        }

        public Task<HostEntry[]> LoadHostsAsync(string sshConfig)
        {
            return RunAsync(delegate(CancellationToken token) {
                return CallApi<HostEntry[]>(new Dictionary<string, object> {
                    { "operation", "list" }, { "sshConfig", sshConfig ?? "" }
                }, token, 30000);
            });
        }

        public Task<ProfileInfo> ResolveHostAsync(string alias, string sshConfig)
        {
            if (String.IsNullOrWhiteSpace(alias)) { throw new ArgumentException("请先选择 SSH 主机。"); }
            return RunAsync(delegate(CancellationToken token) {
                return CallApi<ProfileInfo>(new Dictionary<string, object> {
                    { "operation", "import" }, { "alias", alias }, { "sshConfig", sshConfig ?? "" }
                }, token, 45000);
            });
        }

        public Task<HostCatalog> LoadCatalogAsync(string sshConfig = null)
        {
            return RunAsync(delegate(CancellationToken token) {
                List<HostEntry> hosts = new List<HostEntry>();
                List<string> warnings = new List<string>();
                try { hosts.AddRange(ServerCatalog.ReadEntries(ServersPath)); }
                catch (Exception error) {
                    if (!(error is IOException) && !(error is UnauthorizedAccessException) && !(error is ArgumentException) && !(error is InvalidOperationException)) { throw; }
                    warnings.Add("软件服务器配置无法读取；原文件已保留，请修复后再保存。");
                }
                List<ConfigSource> sources = ServerCatalog.DiscoverConfigs(sshConfig,
                    catalogUserHome, catalogAppData, warnings);
                foreach (ConfigSource source in sources)
                {
                    token.ThrowIfCancellationRequested();
                    try {
                        HostEntry[] found = CallApi<HostEntry[]>(new Dictionary<string, object> {
                            { "operation", "list" }, { "sshConfig", source.Path }
                        }, token, 30000);
                        foreach (HostEntry entry in found) {
                            entry.Kind = "ssh"; entry.Id = source.Path + "|" + (source.SshPath ?? "") + "|" + entry.Alias;
                            entry.ConfigPath = source.Path; entry.SourceLabel = source.Label; entry.SshPath = source.SshPath;
                            hosts.Add(entry);
                        }
                    }
                    catch (GuiApiException) { warnings.Add("无法读取 SSH 配置：" + source.Path + "。其他来源仍可使用。"); }
                }
                return new HostCatalog {
                    Hosts = hosts.ToArray(), Warnings = warnings.ToArray(),
                    ConfigPaths = sources.ConvertAll(delegate(ConfigSource source) { return source.Path; }).ToArray(),
                    Summary = hosts.Count == 0 ? "未发现服务器，可以直接添加。" : "已读取 " + hosts.Count.ToString(CultureInfo.InvariantCulture) + " 个服务器配置。"
                };
            });
        }

        public Task<ProfileInfo> ResolveEntryAsync(HostEntry entry)
        {
            if (entry == null) { throw new ArgumentException("请先选择服务器。"); }
            if (entry.Kind != "saved") { return ResolveNativeHostAsync(entry.Alias, entry.ConfigPath ?? entry.SourceFile, entry.SshPath); }
            return RunAsync(delegate(CancellationToken token) {
                string json = ServerCatalog.ReadProfile(ServersPath, entry.Id);
                return ValidateProfile(json, token);
            });
        }

        public Task<ProfileInfo> ResolveNativeHostAsync(string alias, string sshConfig, string sshPath)
        {
            if (String.IsNullOrWhiteSpace(alias)) { throw new ArgumentException("请先选择 SSH 主机。"); }
            return RunAsync(delegate(CancellationToken token) {
                string previewDirectory = runtime.NewNativeSnapshotDirectory();
                try {
                    return CallApi<ProfileInfo>(new Dictionary<string, object> {
                        { "operation", "native-import" }, { "alias", alias },
                        { "sshConfig", sshConfig ?? "" }, { "sshPath", sshPath ?? "" },
                        { "nativePreviewDirectory", previewDirectory }
                    }, token, 45000);
                }
                finally {
                    // CallApi has disposed the helper job before returning or
                    // throwing, including cancellation during ssh -G preview.
                    runtime.DeleteNativeSnapshotDirectory(previewDirectory);
                }
            });
        }

        public Task<HostEntry> SaveServerAsync(string name, string profileJson, string id = null)
        {
            ServerCatalog.ValidateName(name);
            return RunAsync(delegate(CancellationToken token) {
                ProfileInfo profile = ValidateProfile(profileJson, token);
                return ServerCatalog.Save(ServersPath, name.Trim(), profile.Json, id, token);
            });
        }

        public Task<ProfileInfo> ReadSavedServerAsync(string id)
        {
            return RunAsync(delegate(CancellationToken token) {
                token.ThrowIfCancellationRequested();
                return ServerCatalog.DescribeProfile(ServerCatalog.ReadProfile(ServersPath, id));
            });
        }

        private ProfileInfo ValidateProfile(string json, CancellationToken token)
        {
            return CallApi<ProfileInfo>(new Dictionary<string, object> {
                { "operation", "validate" }, { "profileJson", json ?? "" }
            }, token, 30000);
        }

        public Task<ProxyInfo> CheckProxyAsync(int manualPort = 0)
        {
            CheckPort(manualPort, 0, "本机代理端口");
            return RunAsync(delegate(CancellationToken token) {
                return CallApi<ProxyInfo>(new Dictionary<string, object> {
                    { "operation", "probe" }, { "manualPort", manualPort }
                }, token, 85000);
            });
        }

        public void Start(ProfileInfo profile, int remotePort, int manualProxyPort)
        {
            if (profile == null || String.IsNullOrWhiteSpace(profile.Json)) { throw new ArgumentException("请先导入 SSH 主机。"); }
            CheckPort(remotePort, 1024, "远端代理端口");
            CheckPort(manualProxyPort, 0, "本机代理端口");
            // Copy metadata now so a later selection cannot change a pending
            // run. Native JSON is display data; OpenSSH keeps its own semantics.
            ProfileInfo snapshot = new ProfileInfo { Json = profile.Json,
                NativeAlias = profile.NativeAlias, NativeConfigPath = profile.NativeConfigPath, NativeSshPath = profile.NativeSshPath };
            CancellationTokenSource cancellation;
            long thisGeneration;
            lock (gate)
            {
                ThrowIfDisposed();
                if (running) { throw new InvalidOperationException("隧道正在启动或运行。"); }
                running = true;
                thisGeneration = ++generation;
                cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                startCancellation = cancellation;
                activeOperations++;
            }
            PublishCurrent(thisGeneration, "detecting", "正在准备独立配置并检测本机代理。", "", 0);
            Task.Factory.StartNew(delegate {
                RunTunnel(snapshot, remotePort, manualProxyPort, thisGeneration, cancellation);
            }, CancellationToken.None, TaskCreationOptions.None, TaskScheduler.Default);
        }

        public Task<VscodeConfigResult> ConfigureVscodeAsync(ProfileInfo profile, int remotePort)
        {
            if (profile == null || String.IsNullOrWhiteSpace(profile.Json)) { throw new ArgumentException("请先选择服务器。"); }
            CheckPort(remotePort, 1024, "远端代理端口");
            ProfileInfo snapshot = new ProfileInfo { Json = profile.Json, NativeAlias = profile.NativeAlias,
                NativeConfigPath = profile.NativeConfigPath, NativeSshPath = profile.NativeSshPath };
            CancellationTokenSource cancellation;
            lock (gate)
            {
                ThrowIfDisposed();
                if (configuringVscode) { throw new InvalidOperationException("正在配置远程 VS Code，请等待当前操作完成。"); }
                configuringVscode = true;
                cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                cancellation.CancelAfter(vscodeTimeoutMilliseconds);
                vscodeCancellation = cancellation;
                activeOperations++;
            }
            return Task.Factory.StartNew(delegate { return RunVscodeConfiguration(snapshot, remotePort, cancellation); },
                CancellationToken.None, TaskCreationOptions.None, TaskScheduler.Default);
        }

        private VscodeConfigResult RunVscodeConfiguration(ProfileInfo profile, int remotePort, CancellationTokenSource cancellation)
        {
            string sessionPath = runtime.NewDataPath("vscode-profile", ".json");
            string statusPath = runtime.NewDataPath("vscode-status", ".json");
            string snapshotDirectory = null;
            GuiOwnedProcess child = null;
            try
            {
                CancellationToken token = cancellation.Token;
                snapshotDirectory = runtime.NewNativeSnapshotDirectory();
                Dictionary<string, object> request = new Dictionary<string, object> {
                    { "operation", "prepare" }, { "profileJson", profile.Json }, { "remotePort", remotePort },
                    // The settings action never updates persisted connection preferences.
                    { "sessionPath", sessionPath }, { "savePath", sessionPath }
                };
                bool native = !String.IsNullOrWhiteSpace(profile.NativeAlias);
                if (native) {
                    request["nativeAlias"] = profile.NativeAlias;
                    request["nativeConfigPath"] = profile.NativeConfigPath ?? "";
                    request["nativeSshPath"] = profile.NativeSshPath ?? "";
                    request["nativePreviewDirectory"] = snapshotDirectory;
                }
                CallApi<Dictionary<string, object>>(request, token, 30000);
                List<string> args = PowerShellArguments(Path.Combine(runtime.DirectoryPath, "Start-Tunnel.ps1"));
                args.Add("-ExecutableHost"); args.Add("-NoPrompt"); args.Add("-ConfigureVscode");
                args.Add("-ConfigPath"); args.Add(sessionPath);
                args.Add("-GuiStatusPath"); args.Add(statusPath);
                args.Add("-NativeSnapshotDirectory"); args.Add(snapshotDirectory);
                if (native) {
                    args.Add("-NativeAlias"); args.Add(profile.NativeAlias);
                    args.Add("-SshConfigPath"); args.Add(profile.NativeConfigPath ?? "");
                    args.Add("-NativeSshPath"); args.Add(profile.NativeSshPath ?? "");
                }
                lock (gate) {
                    token.ThrowIfCancellationRequested(); ThrowIfDisposed();
                    child = new GuiOwnedProcess(PowerShellPath(), JoinArguments(args), runtime.DirectoryPath, showAuthenticationConsole);
                    vscodeAction = child;
                }
                while (!child.HasExited) { token.ThrowIfCancellationRequested(); token.WaitHandle.WaitOne(100); }
                token.ThrowIfCancellationRequested();
                VscodeActionStatus status = null;
                if (File.Exists(statusPath) && new FileInfo(statusPath).Length <= 65536) {
                    try { status = Serializer().Deserialize<VscodeActionStatus>(File.ReadAllText(statusPath, Encoding.UTF8)); }
                    catch (ArgumentException) { }
                    catch (InvalidOperationException) { }
                }
                if (status != null && status.Phase == "error") {
                    throw new GuiApiException(String.IsNullOrWhiteSpace(status.Message) ? "远程 VS Code 配置失败，请查看身份验证窗口中的提示。" : status.Message);
                }
                if (child.ExitCode != 0 || status == null || status.Phase != "configured" || status.Targets < 1 || status.Targets > 128) {
                    throw new GuiApiException("远程 VS Code 配置未完成。请检查 SSH 登录或网络状态后重试。");
                }
                return new VscodeConfigResult { Changed = status.Changed, Targets = status.Targets,
                    Message = status.Changed ? "已配置远程 VS Code 代理并备份原有设置。请回到远程 VS Code 重新加载窗口。"
                        : "远程 VS Code 已使用此代理，无需更改。请回到远程 VS Code 重新加载窗口。" };
            }
            catch (OperationCanceledException) {
                throw new OperationCanceledException("远程 VS Code 配置已取消或超过 5 分钟，不会停止已有隧道。远程设置可能已写入，重新点击配置可检查并完成。");
            }
            finally
            {
                if (child != null) { child.Dispose(); }
                runtime.DeleteNativeSnapshotDirectory(snapshotDirectory);
                runtime.DeleteDataFile(sessionPath); runtime.DeleteDataFile(statusPath); runtime.DeleteDataFile(statusPath + ".tmp");
                lock (gate) {
                    if (Object.ReferenceEquals(vscodeAction, child)) { vscodeAction = null; }
                    if (Object.ReferenceEquals(vscodeCancellation, cancellation)) { vscodeCancellation = null; configuringVscode = false; }
                }
                cancellation.Dispose();
                FinishOperation();
            }
        }

        public void CancelVscodeConfiguration()
        {
            GuiOwnedProcess owned;
            lock (gate) {
                if (vscodeCancellation != null) { vscodeCancellation.Cancel(); }
                owned = vscodeAction;
            }
            if (owned != null) { owned.Terminate(); }
        }

        private void RunTunnel(ProfileInfo profile, int remotePort, int manualProxyPort, long thisGeneration, CancellationTokenSource cancellation)
        {
            string sessionPath = runtime.NewDataPath("profile", ".json");
            string statusPath = runtime.NewDataPath("status", ".json");
            string nativeSnapshotDirectory = null;
            GuiOwnedProcess child = null;
            string phase = "detecting";
            TunnelStatus latest = null;
            try
            {
                CancellationToken token = cancellation.Token;
                Dictionary<string, object> request = new Dictionary<string, object> {
                    { "operation", "prepare" }, { "profileJson", profile.Json }, { "remotePort", remotePort },
                    { "sessionPath", sessionPath }, { "savePath", ProfilePath }
                };
                if (!String.IsNullOrWhiteSpace(profile.NativeAlias)) {
                    nativeSnapshotDirectory = runtime.NewNativeSnapshotDirectory();
                    request["nativeAlias"] = profile.NativeAlias;
                    request["nativeConfigPath"] = profile.NativeConfigPath ?? "";
                    request["nativeSshPath"] = profile.NativeSshPath ?? "";
                    request["nativePreviewDirectory"] = nativeSnapshotDirectory;
                }
                CallApi<Dictionary<string, object>>(request, token, 30000);
                Dictionary<string, object> preparedProfile = Serializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(sessionPath, Encoding.UTF8));
                int checkIntervalSeconds = Convert.ToInt32(preparedProfile["checkIntervalSeconds"], CultureInfo.InvariantCulture);
                token.ThrowIfCancellationRequested();
                List<string> args = PowerShellArguments(Path.Combine(runtime.DirectoryPath, "Start-Tunnel.ps1"));
                args.Add("-ExecutableHost"); args.Add("-NoPrompt");
                args.Add("-ConfigPath"); args.Add(sessionPath);
                args.Add("-GuiStatusPath"); args.Add(statusPath);
                if (nativeSnapshotDirectory != null) {
                    args.Add("-NativeAlias"); args.Add(profile.NativeAlias);
                    args.Add("-SshConfigPath"); args.Add(profile.NativeConfigPath ?? "");
                    args.Add("-NativeSshPath"); args.Add(profile.NativeSshPath ?? "");
                    args.Add("-NativeSnapshotDirectory"); args.Add(nativeSnapshotDirectory);
                }
                if (manualProxyPort != 0) { args.Add("-ProxyPort"); args.Add(manualProxyPort.ToString(CultureInfo.InvariantCulture)); }
                lock (gate)
                {
                    token.ThrowIfCancellationRequested(); ThrowIfDisposed();
                    child = new GuiOwnedProcess(PowerShellPath(), JoinArguments(args), runtime.DirectoryPath, showAuthenticationConsole);
                    tunnel = child;
                }
                long lastSourceSequence = -1;
                long lastMonitorSequence = -1;
                Stopwatch monitorAge = new Stopwatch();
                bool staleReported = false;
                while (true)
                {
                    token.ThrowIfCancellationRequested();
                    phase = ReadStatus(statusPath, lastSourceSequence, phase, thisGeneration, ref latest, out lastSourceSequence);
                    if (latest != null && latest.Sequence != lastMonitorSequence
                        && (latest.Phase == "ready" || latest.Phase == "degraded" || latest.Phase == "unverified"))
                    {
                        lastMonitorSequence = latest.Sequence;
                        monitorAge.Restart();
                        staleReported = false;
                    }
                    if (!staleReported && monitorAge.IsRunning && (phase == "ready" || phase == "degraded")
                        && IsHeartbeatExpired(monitorAge.ElapsedMilliseconds, checkIntervalSeconds))
                    {
                        staleReported = true;
                        phase = "unverified";
                        PublishCurrent(thisGeneration, phase, "超过预期时间未收到服务器检测结果，连接仍保留，网络状态待重新确认。",
                            latest.ProxyUrl, 0, latest.ProxyHttpStatus);
                    }
                    if (child.HasExited) { break; }
                    token.WaitHandle.WaitOne(300);
                }
                lock (gate) { if (generation == thisGeneration) { running = false; } }
                phase = ReadStatus(statusPath, lastSourceSequence, phase, thisGeneration, ref latest, out lastSourceSequence);
                if (child.ExitCode != 0 && phase != "error")
                {
                    PublishCurrent(thisGeneration, "error", "连接进程已退出。请查看 SSH 控制台中的身份验证或网络提示。", "", 0);
                }
                else if (phase != "error" && phase != "stopped")
                {
                    PublishCurrent(thisGeneration, "stopped", "隧道已停止。", "", 0);
                }
                else if (latest != null)
                {
                    // Deliver terminal state once more after IsRunning becomes
                    // false so UI controls reliably return to an idle state.
                    PublishCurrent(thisGeneration, latest.Phase, latest.Message, latest.ProxyUrl, latest.HttpStatus, latest.ProxyHttpStatus);
                }
            }
            catch (OperationCanceledException) { }
            catch (GuiApiException error) { MarkNotRunning(thisGeneration); PublishCurrent(thisGeneration, "error", error.Message, "", 0); }
            catch (Exception) { MarkNotRunning(thisGeneration); PublishCurrent(thisGeneration, "error", "隧道启动失败。请检查系统 PowerShell、SSH 和配置目录权限。", "", 0); }
            finally
            {
                if (child != null) { child.Dispose(); }
                runtime.DeleteNativeSnapshotDirectory(nativeSnapshotDirectory);
                lock (gate)
                {
                    if (Object.ReferenceEquals(tunnel, child)) { tunnel = null; }
                    if (generation == thisGeneration) { running = false; startCancellation = null; }
                }
                cancellation.Dispose();
                runtime.DeleteDataFile(sessionPath);
                runtime.DeleteDataFile(statusPath);
                runtime.DeleteDataFile(statusPath + ".tmp");
                FinishOperation();
            }
        }

        private string ReadStatus(string path, long previous, string phase, long thisGeneration, ref TunnelStatus latest, out long accepted)
        {
            accepted = previous;
            try
            {
                if (!File.Exists(path) || new FileInfo(path).Length > 65536) { return phase; }
                TunnelStatus value = Serializer().Deserialize<TunnelStatus>(File.ReadAllText(path, Encoding.UTF8));
                if (value == null || value.Sequence <= previous || !ValidPhase(value.Phase)) { return phase; }
                accepted = value.Sequence;
                if (value.Phase != "bind-warning") { latest = value; }
                PublishCurrent(thisGeneration, value.Phase, value.Message ?? "", value.ProxyUrl ?? "", value.HttpStatus, value.ProxyHttpStatus);
                return value.Phase == "bind-warning" ? phase : value.Phase;
            }
            catch (IOException) { return phase; }
            catch (UnauthorizedAccessException) { return phase; }
            catch (ArgumentException) { return phase; }
            catch (InvalidOperationException) { return phase; }
        }

        private static bool ValidPhase(string phase)
        {
            return phase == "detecting" || phase == "proxy-ready" || phase == "connecting" || phase == "ready"
                || phase == "degraded" || phase == "unverified" || phase == "error" || phase == "stopped" || phase == "bind-warning";
        }

        // Allow the monitor interval plus 45 seconds for its bounded 15-second
        // curl request and transport delay. A live SSH process is not a fresh
        // HTTPS result; a newer monitor snapshot is required to restore ready.
        internal static bool IsHeartbeatExpired(long elapsedMilliseconds, int intervalSeconds)
        {
            return elapsedMilliseconds >= ((long)intervalSeconds + 45) * 1000;
        }

        public void Stop()
        {
            GuiOwnedProcess owned;
            long stoppedGeneration;
            lock (gate)
            {
                if (!running) { return; }
                stoppedGeneration = ++generation;
                running = false;
                if (startCancellation != null) { startCancellation.Cancel(); }
                startCancellation = null;
                owned = tunnel; tunnel = null;
            }
            if (owned != null) { owned.Terminate(); }
            PublishCurrent(stoppedGeneration, "stopped", "隧道已停止；本机代理软件保持运行。", "", 0);
        }

        private Task<T> RunAsync<T>(Func<CancellationToken, T> action)
        {
            lock (gate) { ThrowIfDisposed(); activeOperations++; }
            return Task.Factory.StartNew(delegate {
                try { return action(lifetime.Token); }
                finally { FinishOperation(); }
            }, CancellationToken.None, TaskCreationOptions.None, TaskScheduler.Default);
        }

        private T CallApi<T>(Dictionary<string, object> request, CancellationToken token, int timeoutMilliseconds)
        {
            string requestPath = runtime.NewDataPath("request", ".json");
            string responsePath = runtime.NewDataPath("response", ".json");
            GuiOwnedProcess helper = null;
            try
            {
                token.ThrowIfCancellationRequested();
                File.WriteAllText(requestPath, Serializer().Serialize(request), new UTF8Encoding(false));
                List<string> args = PowerShellArguments(Path.Combine(runtime.DirectoryPath, "Gui-Api.ps1"));
                args.Add("-RequestPath"); args.Add(requestPath);
                args.Add("-ResponsePath"); args.Add(responsePath);
                lock (gate)
                {
                    token.ThrowIfCancellationRequested(); ThrowIfDisposed();
                    helper = new GuiOwnedProcess(PowerShellPath(), JoinArguments(args), runtime.DirectoryPath, false);
                    helpers.Add(helper);
                }
                Stopwatch watch = Stopwatch.StartNew();
                while (!helper.HasExited)
                {
                    token.ThrowIfCancellationRequested();
                    if (watch.ElapsedMilliseconds > timeoutMilliseconds) { throw new GuiApiException("操作已超时，请检查配置或手动指定代理端口后重试。"); }
                    token.WaitHandle.WaitOne(100);
                }
                token.ThrowIfCancellationRequested();
                if (helper.ExitCode != 0 || !File.Exists(responsePath) || new FileInfo(responsePath).Length > 1024 * 1024)
                {
                    throw new GuiApiException("后台操作未返回有效结果。请检查 Windows PowerShell 和文件权限。");
                }
                JavaScriptSerializer serializer = Serializer();
                Dictionary<string, object> envelope = serializer.Deserialize<Dictionary<string, object>>(File.ReadAllText(responsePath, Encoding.UTF8));
                if (!envelope.ContainsKey("ok") || !(envelope["ok"] is bool) || !(bool)envelope["ok"])
                {
                    throw new GuiApiException(envelope.ContainsKey("message") ? Convert.ToString(envelope["message"], CultureInfo.InvariantCulture) : "后台操作失败。");
                }
                return serializer.Deserialize<T>(serializer.Serialize(envelope["result"]));
            }
            finally
            {
                if (helper != null)
                {
                    lock (gate) { helpers.Remove(helper); }
                    helper.Dispose();
                }
                runtime.DeleteDataFile(requestPath);
                runtime.DeleteDataFile(responsePath);
                runtime.DeleteDataFile(responsePath + ".tmp");
            }
        }

        private static JavaScriptSerializer Serializer() { return new JavaScriptSerializer { MaxJsonLength = 1024 * 1024, RecursionLimit = 32 }; }
        private static void CheckPort(int port, int minimum, string label)
        {
            if (port < minimum || port > 65535) { throw new ArgumentException(label + "应为 " + minimum + "–65535。"); }
        }
        private void ThrowIfDisposed() { if (disposed) { throw new ObjectDisposedException("TunnelBackend"); } }
        private void FinishOperation()
        {
            lock (gate) { activeOperations--; if (disposed && activeOperations == 0) { runtime.Dispose(); lifetime.Dispose(); } }
        }
        private void MarkNotRunning(long currentGeneration)
        {
            lock (gate) { if (generation == currentGeneration) { running = false; } }
        }
        private void PublishCurrent(long currentGeneration, string phase, string message, string proxy, int http, int proxyHttpStatus = 0)
        {
            // Observers must dispatch asynchronously. Holding this lock across
            // delivery prevents an obsolete run from publishing after Stop.
            lock (gate)
            {
                if (generation != currentGeneration || disposed) { return; }
                Publish(phase, message, proxy, http, proxyHttpStatus);
            }
        }
        private void Publish(string phase, string message, string proxy, int http, int proxyHttpStatus)
        {
            TunnelStatus status = new TunnelStatus { Phase = phase, Message = message, ProxyUrl = proxy, HttpStatus = http, ProxyHttpStatus = proxyHttpStatus, Sequence = Interlocked.Increment(ref sequence) };
            Action<TunnelStatus> handler = StatusChanged;
            if (handler != null) { try { handler(status); } catch { } }
            Action<string> logger = Log;
            if (logger != null) { try { logger(message); } catch { } }
        }
        public void Dispose()
        {
            Stop();
            CancelVscodeConfiguration();
            lock (gate)
            {
                if (disposed) { return; }
                disposed = true;
                lifetime.Cancel();
                foreach (GuiOwnedProcess helper in helpers) { helper.Terminate(); }
                if (activeOperations == 0) { runtime.Dispose(); lifetime.Dispose(); }
            }
        }
        private static string PowerShellPath()
        {
            string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(path)) { throw new IOException("找不到 Windows PowerShell 5.1。"); }
            return path;
        }
        private static List<string> PowerShellArguments(string script)
        {
            return new List<string> { PowerShellPath(), "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script };
        }
        internal static string JoinArguments(IEnumerable<string> arguments)
        {
            StringBuilder result = new StringBuilder();
            foreach (string argument in arguments)
            {
                if (result.Length > 0) { result.Append(' '); }
                result.Append('"'); int slashes = 0;
                foreach (char value in argument)
                {
                    if (value == '\\') { slashes++; continue; }
                    result.Append('\\', value == '"' ? slashes * 2 + 1 : slashes);
                    result.Append(value); slashes = 0;
                }
                result.Append('\\', slashes * 2); result.Append('"');
            }
            return result.ToString();
        }
    }

    internal sealed class GuiApiException : Exception { internal GuiApiException(string message) : base(message) { } }

    internal sealed class GuiRuntimeFiles : IDisposable
    {
        private static readonly string[] Names = { "Start-Tunnel.ps1", "TunnelTools.ps1", "ProxyTools.ps1", "SshImport.ps1", "remote-monitor.sh", "remote-vscode-config.sh", "remote-vscode-config.js", "read.md", "Gui-Api.ps1" };
        private readonly HashSet<string> dataFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private readonly HashSet<string> nativeDirectories = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private readonly string tempRoot;
        internal string DirectoryPath { get; private set; }
        internal GuiRuntimeFiles(string sourceDirectory)
        {
            string resolvedTemp = Path.GetFullPath(Path.GetTempPath());
            string volumeRoot = Path.GetPathRoot(resolvedTemp);
            tempRoot = resolvedTemp.Length > volumeRoot.Length ? resolvedTemp.TrimEnd(Path.DirectorySeparatorChar) : resolvedTemp;
            DirectoryPath = Path.Combine(tempRoot, "CodexProxyTunnel-Gui-" + Guid.NewGuid().ToString("N"));
            if (Directory.Exists(DirectoryPath) || File.Exists(DirectoryPath)) { throw new IOException("临时运行目录已存在。"); }
            Directory.CreateDirectory(DirectoryPath);
            try
            {
                AssertOwnedDirectory();
                foreach (string name in Names)
                {
                    Stream source;
                    if (sourceDirectory == null) { source = Assembly.GetExecutingAssembly().GetManifestResourceStream("CodexTunnelGui.Runtime." + name); }
                    else
                    {
                        string file = Path.Combine(sourceDirectory, name);
                        if (name == "Gui-Api.ps1" && !File.Exists(file)) { file = Path.Combine(sourceDirectory, "gui", name); }
                        source = File.OpenRead(file);
                    }
                    using (source)
                    {
                        if (source == null) { throw new IOException("EXE 缺少内置文件。"); }
                        using (FileStream output = new FileStream(Path.Combine(DirectoryPath, name), FileMode.CreateNew, FileAccess.Write)) { source.CopyTo(output); }
                    }
                }
            }
            catch { Dispose(); throw; }
        }
        private void AssertOwnedDirectory()
        {
            string actual = Path.GetFullPath(DirectoryPath);
            if (!String.Equals(Path.GetDirectoryName(actual), tempRoot, StringComparison.OrdinalIgnoreCase)
                || !Path.GetFileName(actual).StartsWith("CodexProxyTunnel-Gui-", StringComparison.Ordinal)
                || (File.GetAttributes(actual) & FileAttributes.ReparsePoint) != 0) { throw new IOException("临时目录安全检查未通过。"); }
        }
        internal string NewDataPath(string purpose, string suffix)
        {
            lock (dataFiles)
            {
                string path = Path.Combine(DirectoryPath, purpose + "-" + Guid.NewGuid().ToString("N") + suffix);
                dataFiles.Add(path); dataFiles.Add(path + ".tmp"); return path;
            }
        }
        internal void DeleteDataFile(string path)
        {
            lock (dataFiles)
            {
                if (!dataFiles.Contains(path)) { return; }
                try { AssertOwnedDirectory(); if (File.Exists(path)) { File.Delete(path); } dataFiles.Remove(path); } catch { }
            }
        }
        internal string NewNativeSnapshotDirectory()
        {
            lock (dataFiles)
            {
                AssertOwnedDirectory();
                string path = Path.Combine(DirectoryPath, "native-" + Guid.NewGuid().ToString("N"));
                if (Directory.Exists(path) || File.Exists(path)) { throw new IOException("SSH 临时配置目录已存在。"); }
                Directory.CreateDirectory(path);
                nativeDirectories.Add(path);
                return path;
            }
        }
        internal void DeleteNativeSnapshotDirectory(string path)
        {
            lock (dataFiles)
            {
                if (path == null || !nativeDirectories.Contains(path)) { return; }
                try
                {
                    AssertOwnedDirectory();
                    if (!String.Equals(Path.GetDirectoryName(Path.GetFullPath(path)), DirectoryPath, StringComparison.OrdinalIgnoreCase)) { return; }
                    if (!Directory.Exists(path)) { nativeDirectories.Remove(path); return; }
                    if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) { return; }
                    // The native snapshot writer owns at most these 65 files.
                    // Never enumerate/delete unknown entries or recurse.
                    for (int index = 0; index < 65; index++) {
                        string file = Path.Combine(path, "config-" + index.ToString("000", CultureInfo.InvariantCulture) + ".conf");
                        if (File.Exists(file) && (File.GetAttributes(file) & FileAttributes.ReparsePoint) == 0) { File.Delete(file); }
                    }
                    Directory.Delete(path, false);
                    nativeDirectories.Remove(path);
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }
        public void Dispose()
        {
            lock (dataFiles)
            {
                if (!Directory.Exists(DirectoryPath)) { return; }
                try
                {
                    AssertOwnedDirectory();
                    foreach (string nativeDirectory in new List<string>(nativeDirectories)) { DeleteNativeSnapshotDirectory(nativeDirectory); }
                    foreach (string file in dataFiles) { if (File.Exists(file)) { File.Delete(file); } }
                    foreach (string name in Names) { string path = Path.Combine(DirectoryPath, name); if (File.Exists(path)) { File.Delete(path); } }
                    Directory.Delete(DirectoryPath, false); // Unexpected contents are preserved.
                }
                catch { }
            }
        }
    }

    internal sealed class GuiOwnedProcess : IDisposable
    {
        private readonly object gate = new object();
        private IntPtr job, process;
        internal GuiOwnedProcess(string executable, string commandLine, string workingDirectory, bool visible)
        {
            ProcessInformation info = new ProcessInformation();
            try
            {
                job = CreateJobObject(IntPtr.Zero, null);
                if (job == IntPtr.Zero) { throw new Win32Exception(); }
                ExtendedLimitInformation limits = new ExtendedLimitInformation();
                limits.BasicLimitInformation.LimitFlags = 0x2000;
                if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimitInformation)))) { throw new Win32Exception(); }
                StartupInformation startup = new StartupInformation();
                startup.cb = (uint)Marshal.SizeOf(typeof(StartupInformation));
                startup.lpTitle = visible ? "Codex SSH 身份验证与连接" : null;
                uint flags = 0x00000004 | (visible ? 0x00000010u : 0x08000000u);
                if (!CreateProcess(executable, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false,
                    flags, IntPtr.Zero, workingDirectory, ref startup, out info)) { throw new Win32Exception(); }
                process = info.hProcess;
                if (!AssignProcessToJobObject(job, process)) { throw new Win32Exception(); }
                if (ResumeThread(info.hThread) == UInt32.MaxValue) { throw new Win32Exception(); }
            }
            catch
            {
                if (process != IntPtr.Zero) { TerminateProcess(process, 1); }
                Dispose(); throw;
            }
            finally { if (info.hThread != IntPtr.Zero) { CloseHandle(info.hThread); } }
        }
        internal bool HasExited { get { lock (gate) { return process == IntPtr.Zero || WaitForSingleObject(process, 0) == 0; } } }
        internal int ExitCode
        {
            get { lock (gate) { uint code; return process != IntPtr.Zero && GetExitCodeProcess(process, out code) ? unchecked((int)code) : 1; } }
        }
        internal void Terminate()
        {
            lock (gate)
            {
                if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
                if (process != IntPtr.Zero) { WaitForSingleObject(process, 2000); }
            }
        }
        public void Dispose()
        {
            lock (gate)
            {
                Terminate();
                if (process != IntPtr.Zero) { CloseHandle(process); process = IntPtr.Zero; }
            }
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInformation
        {
            internal uint cb;
            internal string lpReserved, lpDesktop, lpTitle;
            internal uint dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            internal ushort wShowWindow, cbReserved2;
            internal IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
        }
        [StructLayout(LayoutKind.Sequential)] private struct ProcessInformation { internal IntPtr hProcess, hThread; internal uint dwProcessId, dwThreadId; }
        [StructLayout(LayoutKind.Sequential)] private struct BasicLimitInformation
        {
            internal long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            internal uint LimitFlags;
            internal UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            internal uint ActiveProcessLimit;
            internal UIntPtr Affinity;
            internal uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)] private struct IoCounters
        {
            internal ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount;
        }
        [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimitInformation
        {
            internal BasicLimitInformation BasicLimitInformation;
            internal IoCounters IoInfo;
            internal UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetInformationJobObject(IntPtr job, int informationClass, ref ExtendedLimitInformation information, uint length);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CreateProcess(string application, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inheritHandles, uint creationFlags, IntPtr environment, string currentDirectory, ref StartupInformation startup, out ProcessInformation process);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool TerminateProcess(IntPtr process, uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
    }
}
