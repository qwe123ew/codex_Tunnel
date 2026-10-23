using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;

[assembly: AssemblyTitle("CodexProxyTunnel")]
[assembly: AssemblyDescription("Visible console launcher for the isolated Codex SSH proxy tunnel")]
[assembly: AssemblyProduct("CodexProxyTunnel")]
[assembly: AssemblyVersion("1.2.0.0")]
[assembly: AssemblyFileVersion("1.2.0.0")]

namespace CodexProxyTunnel
{
    internal static class Program
    {
        internal const string Version = "1.2.0";

        private static int Main(string[] args)
        {
            try { Console.OutputEncoding = new UTF8Encoding(false); } catch { }
            try { Console.InputEncoding = new UTF8Encoding(false); } catch { }
            try
            {
                Options options = Options.Parse(args);
                if (options.Mode == "help") { PrintHelp(); return 0; }
                if (options.Mode == "version")
                {
                    Console.WriteLine("CodexProxyTunnel " + Version);
                    return 0;
                }
                if (options.Mode == null) { return RunMenu(options); }
                return RunAction(options, options.Mode);
            }
            catch (ArgumentException error)
            {
                Console.Error.WriteLine("参数错误：" + error.Message);
                Console.Error.WriteLine("运行 CodexProxyTunnel.exe --help 查看用法。");
                return 2;
            }
            catch (Exception error)
            {
                Console.Error.WriteLine("启动未完成：" + error.Message);
                return 1;
            }
        }

        private static int RunMenu(Options options)
        {
            while (true)
            {
                Console.WriteLine();
                Console.WriteLine("Codex SSH 代理隧道  v" + Version);
                Console.WriteLine("配置：" + options.ConfigPath);
                Console.WriteLine("  1  启动隧道（直接回车）");
                Console.WriteLine("  2  配置 / 选择服务器");
                Console.WriteLine("  3  检测本机代理");
                Console.WriteLine("  4  查看 SSH 信息查询方法");
                Console.WriteLine("  5  列出本机 SSH 主机");
                Console.WriteLine("  0  退出");
                Console.Write("请选择 [1]：");
                string choice = ReadMenuLine();
                if (choice == null) { return 0; }
                choice = choice.Trim().TrimStart('\uFEFF');
                if (choice == "0") { return 0; }
                string mode;
                switch (choice)
                {
                    case "": case "1": mode = "start"; break;
                    case "2": mode = "configure"; break;
                    case "3": mode = "check"; break;
                    case "4": mode = "ssh-help"; break;
                    case "5": mode = "list-hosts"; break;
                    default:
                        Console.WriteLine("请输入 0 到 5 之间的数字。");
                        continue;
                }
                try
                {
                    int result = RunAction(options, mode);
                    Console.WriteLine("本次操作已结束（退出码 " + result + "）。");
                }
                catch (Exception error)
                {
                    Console.Error.WriteLine("启动未完成：" + error.Message);
                }
            }
        }

        // Console.ReadLine can prefetch redirected input needed by the child wizard.
        // Reading one byte at a time leaves all subsequent lines on the inherited pipe.
        private static string ReadMenuLine()
        {
            if (Native.GetFileType(Native.GetStdHandle(-10)) == 2)
            {
                return Console.ReadLine();
            }
            Stream input = Console.OpenStandardInput();
            List<byte> bytes = new List<byte>();
            while (true)
            {
                int next = input.ReadByte();
                if (next < 0) { return bytes.Count == 0 ? null : Encoding.UTF8.GetString(bytes.ToArray()); }
                if (next == 10) { return Encoding.UTF8.GetString(bytes.ToArray()); }
                if (bytes.Count >= 4096) { throw new ArgumentException("菜单输入过长。"); }
                bytes.Add((byte)next);
            }
        }

        private static int RunAction(Options options, string mode)
        {
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(powershell))
            {
                throw new FileNotFoundException("找不到 Windows PowerShell 5.1。", powershell);
            }
            if (mode == "start" || mode == "configure")
            {
                Directory.CreateDirectory(Path.GetDirectoryName(options.ConfigPath));
            }
            using (RuntimeFiles runtime = new RuntimeFiles())
            {
                List<string> arguments = new List<string>();
                arguments.Add(powershell);
                arguments.Add("-NoLogo");
                arguments.Add("-NoProfile");
                arguments.Add("-ExecutionPolicy");
                arguments.Add("Bypass");
                arguments.Add("-File");
                arguments.Add(Path.Combine(runtime.DirectoryPath, "Start-Tunnel.ps1"));
                arguments.Add("-ExecutableHost");
                arguments.Add("-ConfigPath");
                arguments.Add(options.ConfigPath);
                if (options.SshConfigPath != null)
                {
                    arguments.Add("-SshConfigPath");
                    arguments.Add(options.SshConfigPath);
                }
                if (options.ProxyPort != 0)
                {
                    arguments.Add("-ProxyPort");
                    arguments.Add(options.ProxyPort.ToString(CultureInfo.InvariantCulture));
                }
                switch (mode)
                {
                    case "configure": arguments.Add("-Configure"); break;
                    case "check": arguments.Add("-CheckOnly"); break;
                    case "ssh-help": arguments.Add("-ShowSshHelp"); break;
                    case "list-hosts": arguments.Add("-ListSshHosts"); break;
                }
                if (options.Manual) { arguments.Add("-ManualSetup"); }
                if (options.NoPrompt) { arguments.Add("-NoPrompt"); }
                // Script resources use PSScriptRoot. Preserve the caller's directory
                // for deliberately supplied relative identity-file paths.
                return Native.RunOwnedConsoleProcess(powershell, JoinArguments(arguments), Environment.CurrentDirectory);
            }
        }

        private static string JoinArguments(IEnumerable<string> arguments)
        {
            StringBuilder result = new StringBuilder();
            foreach (string argument in arguments)
            {
                if (result.Length != 0) { result.Append(' '); }
                result.Append(QuoteArgument(argument));
            }
            return result.ToString();
        }

        // Windows CommandLineToArgvW / CRT quoting: escape only backslashes before
        // quotes and the closing quote. No shell or PowerShell expression is built.
        private static string QuoteArgument(string argument)
        {
            StringBuilder result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char value in argument)
            {
                if (value == '\\') { slashes++; continue; }
                if (value == '"')
                {
                    result.Append('\\', slashes * 2 + 1);
                    result.Append('"');
                }
                else
                {
                    result.Append('\\', slashes);
                    result.Append(value);
                }
                slashes = 0;
            }
            result.Append('\\', slashes * 2);
            result.Append('"');
            return result.ToString();
        }

        private static void PrintHelp()
        {
            Console.WriteLine("CodexProxyTunnel " + Version);
            Console.WriteLine("Usage: CodexProxyTunnel.exe [MODE] [OPTIONS]");
            Console.WriteLine("No MODE: visible interactive menu; Enter starts the tunnel, 0 exits.");
            Console.WriteLine("Modes (choose one):");
            Console.WriteLine("  --start        Start the tunnel (configure first if needed)");
            Console.WriteLine("  --configure    Select an SSH host or enter a manual server profile");
            Console.WriteLine("  --check        Check the local HTTP proxy only");
            Console.WriteLine("  --ssh-help     Show SSH lookup commands");
            Console.WriteLine("  --list-hosts   List aliases in the SSH configuration");
            Console.WriteLine("  --help         Show this help");
            Console.WriteLine("  --version      Show the application version");
            Console.WriteLine("Options:");
            Console.WriteLine("  --config PATH      Profile path (default: %LOCALAPPDATA%\\CodexProxyTunnel\\settings.json)");
            Console.WriteLine("  --ssh-config PATH  Read aliases from this SSH config");
            Console.WriteLine("  --proxy-port N     Local HTTP/Mixed proxy port, 1-65535");
            Console.WriteLine("  --manual           Configure server details manually");
            Console.WriteLine("  --no-prompt        Disable setup/proxy prompts (SSH authentication remains interactive)");
            Console.WriteLine("  --no-pause         Compatibility flag; command modes always exit without pausing");
            Console.WriteLine("SSH password/MFA stays in this console. Ctrl+C stops the current operation.");
            Console.WriteLine("No administrator access, local Codex changes, or global SSH changes are required.");
        }
    }

    internal sealed class Options
    {
        internal string Mode;
        internal string ConfigPath;
        internal string SshConfigPath;
        internal int ProxyPort;
        internal bool Manual;
        internal bool NoPrompt;

        internal static Options Parse(string[] args)
        {
            Options result = new Options();
            HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
            for (int i = 0; i < args.Length; i++)
            {
                string option = args[i];
                if (!seen.Add(option)) { throw new ArgumentException("重复参数：" + option); }
                switch (option)
                {
                    case "--start": case "--configure": case "--check": case "--ssh-help":
                    case "--list-hosts": case "--help": case "--version":
                        if (result.Mode != null) { throw new ArgumentException("只能选择一种运行模式。"); }
                        result.Mode = option.Substring(2);
                        break;
                    case "--config": result.ConfigPath = NormalizePath(ReadValue(args, ref i), option); break;
                    case "--ssh-config": result.SshConfigPath = NormalizePath(ReadValue(args, ref i), option); break;
                    case "--proxy-port":
                        string port = ReadValue(args, ref i);
                        if (!Int32.TryParse(port, NumberStyles.None, CultureInfo.InvariantCulture, out result.ProxyPort)
                            || result.ProxyPort < 1 || result.ProxyPort > 65535)
                        {
                            throw new ArgumentException("--proxy-port 必须为 1 到 65535 之间的整数。");
                        }
                        break;
                    case "--manual": result.Manual = true; break;
                    case "--no-prompt": result.NoPrompt = true; break;
                    case "--no-pause": break;
                    default: throw new ArgumentException("不支持的参数：" + option);
                }
            }
            if (result.ConfigPath == null)
            {
                string localData = Environment.GetEnvironmentVariable("LOCALAPPDATA");
                if (String.IsNullOrWhiteSpace(localData))
                {
                    localData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                }
                if (String.IsNullOrWhiteSpace(localData)) { throw new IOException("无法确定应用配置目录。"); }
                result.ConfigPath = NormalizePath(Path.Combine(localData, @"CodexProxyTunnel\settings.json"), "--config");
            }
            return result;
        }

        private static string ReadValue(string[] args, ref int index)
        {
            if (index + 1 >= args.Length || args[index + 1].StartsWith("--", StringComparison.Ordinal)
                || String.IsNullOrWhiteSpace(args[index + 1]))
            {
                throw new ArgumentException(args[index] + " 缺少参数值。");
            }
            index++;
            return args[index];
        }

        private static string NormalizePath(string path, string option)
        {
            if (path.IndexOfAny(new char[] { '\r', '\n', '\0', '"' }) >= 0)
            {
                throw new ArgumentException(option + " 路径包含无效字符。");
            }
            try { return Path.GetFullPath(path); }
            catch (Exception error)
            {
                if (error is ArgumentException || error is NotSupportedException || error is PathTooLongException)
                {
                    throw new ArgumentException(option + " 路径无效：" + error.Message);
                }
                throw;
            }
        }
    }

    internal sealed class RuntimeFiles : IDisposable
    {
        private static readonly string[] Names = new string[]
        {
            "Start-Tunnel.ps1", "TunnelTools.ps1", "ProxyTools.ps1", "SshImport.ps1", "remote-monitor.sh", "read.md"
        };
        private readonly string tempRoot;
        internal string DirectoryPath { get; private set; }

        internal RuntimeFiles()
        {
            string resolvedTemp = Path.GetFullPath(Path.GetTempPath());
            string root = Path.GetPathRoot(resolvedTemp);
            tempRoot = resolvedTemp.Length > root.Length ? resolvedTemp.TrimEnd(Path.DirectorySeparatorChar) : resolvedTemp;
            DirectoryPath = Path.GetFullPath(Path.Combine(tempRoot, "CodexProxyTunnel-" + Guid.NewGuid().ToString("N")));
            if (Directory.Exists(DirectoryPath) || File.Exists(DirectoryPath))
            {
                throw new IOException("临时运行目录已存在，请重试。");
            }
            Directory.CreateDirectory(DirectoryPath);
            try
            {
                AssertOwnedDirectory();
                foreach (string name in Names)
                {
                    using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream("CodexProxyTunnel.Runtime." + name))
                    {
                        if (source == null) { throw new IOException("EXE 缺少内置文件：" + name); }
                        using (FileStream output = new FileStream(OwnedFilePath(name), FileMode.CreateNew, FileAccess.Write, FileShare.Read))
                        {
                            source.CopyTo(output);
                        }
                    }
                }
            }
            catch { Dispose(); throw; }
        }

        private void AssertOwnedDirectory()
        {
            string actual = Path.GetFullPath(DirectoryPath);
            if (!String.Equals(Path.GetDirectoryName(actual), tempRoot, StringComparison.OrdinalIgnoreCase)
                || !Path.GetFileName(actual).StartsWith("CodexProxyTunnel-", StringComparison.Ordinal)
                || (File.GetAttributes(actual) & FileAttributes.ReparsePoint) != 0)
            {
                throw new IOException("临时目录安全检查未通过。");
            }
        }

        private string OwnedFilePath(string name)
        {
            string path = Path.GetFullPath(Path.Combine(DirectoryPath, name));
            if (!String.Equals(Path.GetDirectoryName(path), DirectoryPath, StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException("临时文件不在本次运行目录内。");
            }
            return path;
        }

        public void Dispose()
        {
            if (!Directory.Exists(DirectoryPath)) { return; }
            try
            {
                AssertOwnedDirectory();
                foreach (string name in Names)
                {
                    string path = OwnedFilePath(name);
                    if (File.Exists(path)) { File.Delete(path); }
                }
                // Nonrecursive: unexpected contents are deliberately left alone.
                Directory.Delete(DirectoryPath, false);
            }
            catch (Exception error)
            {
                Console.Error.WriteLine("临时目录未完全清理：" + DirectoryPath + "（" + error.Message + "）");
            }
        }
    }

    internal static class Native
    {
        private const uint CreateSuspended = 0x00000004;
        private const uint StartUseStdHandles = 0x00000100;
        private const uint JobKillOnClose = 0x00002000;

        internal static int RunOwnedConsoleProcess(string executable, string commandLine, string workingDirectory)
        {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) { throw new Win32Exception(Marshal.GetLastWin32Error(), "无法创建本次进程组。"); }
            ProcessInformation process = new ProcessInformation();
            bool exited = false;
            ConsoleCancelEventHandler cancel = delegate(object sender, ConsoleCancelEventArgs args)
            {
                // Windows also sends Ctrl+C to PowerShell/SSH in the shared console.
                // Keep this owner alive until they exit so finally can clean up.
                args.Cancel = true;
            };
            Console.CancelKeyPress += cancel;
            try
            {
                ExtendedLimitInformation limits = new ExtendedLimitInformation();
                limits.BasicLimitInformation.LimitFlags = JobKillOnClose;
                if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimitInformation))))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "无法设置本次进程组的退出清理。");
                }
                StartupInformation startup = new StartupInformation();
                startup.cb = (uint)Marshal.SizeOf(typeof(StartupInformation));
                startup.dwFlags = StartUseStdHandles;
                startup.hStdInput = GetStdHandle(-10);
                startup.hStdOutput = GetStdHandle(-11);
                startup.hStdError = GetStdHandle(-12);
                // Native equivalent of UseShellExecute=false, no redirects, no hidden
                // window. Suspend before job assignment so SSH descendants cannot escape.
                if (!CreateProcess(executable, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero,
                    true, CreateSuspended, IntPtr.Zero, workingDirectory, ref startup, out process))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "无法启动 Windows PowerShell。");
                }
                if (!AssignProcessToJobObject(job, process.hProcess))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "无法保护本次子进程的生命周期，已取消启动。");
                }
                if (ResumeThread(process.hThread) == UInt32.MaxValue)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "无法恢复 Windows PowerShell 进程。");
                }
                if (WaitForSingleObject(process.hProcess, UInt32.MaxValue) != 0)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "等待 Windows PowerShell 退出失败。");
                }
                exited = true;
                uint exitCode;
                if (!GetExitCodeProcess(process.hProcess, out exitCode))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "无法读取 Windows PowerShell 退出码。");
                }
                return unchecked((int)exitCode);
            }
            finally
            {
                if (!exited && process.hProcess != IntPtr.Zero)
                {
                    // Only the exact process created above may be terminated on error.
                    TerminateProcess(process.hProcess, 1);
                    WaitForSingleObject(process.hProcess, 5000);
                }
                CloseHandle(job); // Kills only descendants owned by this invocation.
                if (process.hThread != IntPtr.Zero) { CloseHandle(process.hThread); }
                if (process.hProcess != IntPtr.Zero) { CloseHandle(process.hProcess); }
                Console.CancelKeyPress -= cancel;
            }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInformation
        {
            internal uint cb;
            internal string lpReserved;
            internal string lpDesktop;
            internal string lpTitle;
            internal uint dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            internal ushort wShowWindow, cbReserved2;
            internal IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            internal IntPtr hProcess, hThread;
            internal uint dwProcessId, dwThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimitInformation
        {
            internal long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            internal uint LimitFlags;
            internal UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            internal uint ActiveProcessLimit;
            internal UIntPtr Affinity;
            internal uint PriorityClass, SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters
        {
            internal ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
            internal ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedLimitInformation
        {
            internal BasicLimitInformation BasicLimitInformation;
            internal IoCounters IoInfo;
            internal UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetInformationJobObject(IntPtr job, int informationClass, ref ExtendedLimitInformation information, uint length);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcess(string application, StringBuilder commandLine, IntPtr processAttributes,
            IntPtr threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inheritHandles, uint creationFlags,
            IntPtr environment, string currentDirectory, ref StartupInformation startup, out ProcessInformation process);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll")]
        internal static extern IntPtr GetStdHandle(int standardHandle);
        [DllImport("kernel32.dll")]
        internal static extern uint GetFileType(IntPtr file);
    }
}
