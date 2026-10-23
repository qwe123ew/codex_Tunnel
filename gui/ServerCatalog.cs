using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace CodexTunnelGui
{
    internal sealed class ConfigSource { internal string Path, Label, SshPath; }

    // An application-owned catalog. SSH sources are read-only; neither SSH
    // contents nor credentials are copied into this store during discovery.
    internal static class ServerCatalog
    {
        private const int MaxBytes = 1024 * 1024;
        private static JavaScriptSerializer Json() { return new JavaScriptSerializer { MaxJsonLength = MaxBytes, RecursionLimit = 24 }; }
        private static InvalidOperationException Invalid() { return new InvalidOperationException("软件服务器配置格式无效；原文件已保留。"); }
        internal static void ValidateName(string name)
        {
            if (String.IsNullOrWhiteSpace(name) || name.Trim().Length > 64) { throw new ArgumentException("服务器名称应为 1–64 个字符。"); }
            foreach (char value in name) { if (Char.IsControl(value)) { throw new ArgumentException("服务器名称不能包含控制字符。"); } }
        }
        private static Dictionary<string, object> ObjectValue(object value, params string[] allowed)
        {
            Dictionary<string, object> result = value as Dictionary<string, object>;
            if (result == null) { throw Invalid(); }
            foreach (string key in result.Keys) { if (Array.IndexOf(allowed, key) < 0) { throw Invalid(); } }
            return result;
        }
        private static object Required(Dictionary<string, object> value, string key)
        {
            object result; if (!value.TryGetValue(key, out result) || result == null) { throw Invalid(); } return result;
        }
        private static string Text(Dictionary<string, object> value, string key)
        {
            string result = Required(value, key) as string; if (result == null) { throw Invalid(); } return result;
        }
        private static int Number(object value, int min, int max)
        {
            string text = Convert.ToString(value, CultureInfo.InvariantCulture); int number;
            if (!Regex.IsMatch(text ?? "", "\\A[0-9]{1,5}\\z") || !Int32.TryParse(text, out number) || number < min || number > max) { throw Invalid(); }
            return number;
        }
        private static IList ArrayValue(object value)
        {
            IList result = value as IList;
            if (result == null || value is string || value is Dictionary<string, object>) { throw Invalid(); }
            return result;
        }
        private static Dictionary<string, object> Endpoint(object value)
        {
            Dictionary<string, object> endpoint = ObjectValue(value, "host", "user", "port", "identityFile");
            string host = Text(endpoint, "host"), user = Text(endpoint, "user");
            IPAddress address;
            if (host.Length > 253 || Regex.IsMatch(host, "[\\s\\[\\]]") ||
                (!IPAddress.TryParse(host, out address) && !Regex.IsMatch(host, "\\A[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?\\z"))) { throw Invalid(); }
            if (!Regex.IsMatch(user, "\\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}\\z")) { throw Invalid(); }
            Number(Required(endpoint, "port"), 1, 65535);
            object key;
            if (endpoint.TryGetValue("identityFile", out key) && key != null)
            {
                if (!(key is string) || Regex.IsMatch((string)key, "[\\r\\n\"%\\x00]")) { throw Invalid(); }
            }
            return endpoint;
        }
        private static Dictionary<string, object> Profile(object value)
        {
            Dictionary<string, object> profile = ObjectValue(value, "version", "server", "jumpHosts", "remotePort", "checkIntervalSeconds");
            Number(Required(profile, "version"), 1, 1); Endpoint(Required(profile, "server"));
            IList hops = ArrayValue(Required(profile, "jumpHosts"));
            if (hops.Count > 4) { throw Invalid(); }
            foreach (object hop in hops) { Endpoint(hop); }
            Number(Required(profile, "remotePort"), 1024, 65535);
            Number(Required(profile, "checkIntervalSeconds"), 10, 86400);
            return profile;
        }
        private static string Id(string value)
        {
            Guid id;
            if (!Guid.TryParseExact(value, "N", out id) && !Guid.TryParseExact(value, "D", out id)) { throw Invalid(); }
            return id.ToString("N");
        }
        private static List<Dictionary<string, object>> Read(string path)
        {
            List<Dictionary<string, object>> records = new List<Dictionary<string, object>>();
            if (!File.Exists(path)) { return records; }
            if (new FileInfo(path).Length > MaxBytes) { throw Invalid(); }
            Dictionary<string, object> document = ObjectValue(Json().DeserializeObject(File.ReadAllText(path, Encoding.UTF8)), "version", "servers");
            Number(Required(document, "version"), 1, 1);
            IList entries = ArrayValue(Required(document, "servers"));
            if (entries.Count > 500) { throw Invalid(); }
            HashSet<string> ids = new HashSet<string>(StringComparer.Ordinal);
            foreach (object item in entries)
            {
                Dictionary<string, object> record = ObjectValue(item, "id", "name", "profile");
                string id = Id(Text(record, "id"));
                if (!ids.Add(id)) { throw Invalid(); }
                ValidateName(Text(record, "name"));
                Profile(Required(record, "profile"));
                record["id"] = id; records.Add(record);
            }
            return records;
        }
        private static HostEntry Entry(Dictionary<string, object> record, string path)
        {
            return new HostEntry { Id = Text(record, "id"), Alias = Text(record, "name"), Kind = "saved", SourceLabel = "软件保存", SourceFile = path, ConfigPath = path };
        }
        internal static HostEntry[] ReadEntries(string path)
        {
            List<HostEntry> result = new List<HostEntry>();
            foreach (Dictionary<string, object> record in Read(path)) { result.Add(Entry(record, path)); }
            return result.ToArray();
        }
        internal static string ReadProfile(string path, string id)
        {
            string wanted = Id(id);
            foreach (Dictionary<string, object> record in Read(path))
            {
                if (Text(record, "id") == wanted) { return Json().Serialize(record["profile"]); }
            }
            throw new InvalidOperationException("该服务器已不存在，请刷新列表。");
        }
        internal static ProfileInfo DescribeProfile(string json)
        {
            Dictionary<string, object> profile = Profile(Json().DeserializeObject(json));
            Dictionary<string, object> server = Endpoint(profile["server"]);
            IList jumps = ArrayValue(profile["jumpHosts"]);
            List<string> route = new List<string>();
            foreach (object hop in jumps) { route.Add(RoutePart(Endpoint(hop))); }
            route.Add(RoutePart(server));
            return new ProfileInfo { Json = Json().Serialize(profile), Host = Text(server, "host"), User = Text(server, "user"),
                Port = Number(server["port"], 1, 65535), JumpCount = jumps.Count, Route = String.Join(" -> ", route) };
        }
        private static string RoutePart(Dictionary<string, object> endpoint)
        {
            return Text(endpoint, "user") + "@" + Text(endpoint, "host") + ":" + Convert.ToString(endpoint["port"], CultureInfo.InvariantCulture);
        }
        internal static HostEntry Save(string path, string name, string json, string id, CancellationToken token)
        {
            ValidateName(name);
            Dictionary<string, object> profile = Profile(Json().DeserializeObject(json));
            string savedId = String.IsNullOrEmpty(id) ? Guid.NewGuid().ToString("N") : Id(id);
            if (!Path.IsPathRooted(path)) { throw new ArgumentException("软件配置路径必须是绝对路径。"); }
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            using (FileStream fileLock = AcquireLock(path + ".lock", token))
            {
                token.ThrowIfCancellationRequested();
                List<Dictionary<string, object>> records = Read(path);
                Dictionary<string, object> record = records.Find(delegate(Dictionary<string, object> candidate) { return Text(candidate, "id") == savedId; });
                if (!String.IsNullOrEmpty(id) && record == null) { throw new InvalidOperationException("该服务器已不存在，请刷新后重试。"); }
                if (record == null)
                {
                    if (records.Count >= 500) { throw new InvalidOperationException("软件最多保存 500 个服务器配置。"); }
                    record = new Dictionary<string, object> { { "id", savedId } }; records.Add(record);
                }
                record["name"] = name.Trim(); record["profile"] = profile;
                string contents = Json().Serialize(new Dictionary<string, object> { { "version", 1 }, { "servers", records } });
                if (Encoding.UTF8.GetByteCount(contents) > MaxBytes) { throw Invalid(); }
                string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                try
                {
                    File.WriteAllText(temporary, contents, new UTF8Encoding(false));
                    token.ThrowIfCancellationRequested();
                    if (File.Exists(path)) { File.Replace(temporary, path, null); } else { File.Move(temporary, path); }
                }
                finally { if (File.Exists(temporary)) { File.Delete(temporary); } }
                return Entry(record, path);
            }
        }
        private static FileStream AcquireLock(string path, CancellationToken token)
        {
            Stopwatch watch = Stopwatch.StartNew();
            while (true)
            {
                token.ThrowIfCancellationRequested();
                try { return new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
                catch (IOException) { if (watch.ElapsedMilliseconds >= 10000) { throw new IOException("服务器配置正在被其他窗口使用，请稍后重试。"); } }
                token.WaitHandle.WaitOne(100);
            }
        }
        internal static List<ConfigSource> DiscoverConfigs(string explicitPath, string userHome, string appData, List<string> warnings)
        {
            List<ConfigSource> sources = new List<ConfigSource>();
            HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (!String.IsNullOrWhiteSpace(explicitPath)) { AddSource(explicitPath, "本机 SSH", null, userHome, true, sources, seen, warnings); return sources; }
            string defaultConfig = String.IsNullOrWhiteSpace(userHome) ? null : Path.Combine(userHome, ".ssh", "config");
            if (defaultConfig != null) { AddSource(defaultConfig, "本机 SSH", null, userHome, false, sources, seen, warnings); }
            if (String.IsNullOrWhiteSpace(appData)) { return sources; }
            foreach (string edition in new string[] { "Code", "Code - Insiders" })
            {
                string settings = Path.Combine(appData, edition, "User", "settings.json");
                if (!File.Exists(settings)) { continue; }
                try
                {
                    if (new FileInfo(settings).Length > MaxBytes) { throw Invalid(); }
                    Dictionary<string, object> parsed = Json().Deserialize<Dictionary<string, object>>(StripJsonComments(File.ReadAllText(settings, Encoding.UTF8)));
                    object value;
                    string configPath = defaultConfig, sshPath = null;
                    if (parsed != null && parsed.TryGetValue("remote.SSH.configFile", out value))
                    {
                        string path = value as string;
                        if (path == null) { throw Invalid(); }
                        if (!String.IsNullOrWhiteSpace(path)) { configPath = path; }
                    }
                    if (parsed != null && parsed.TryGetValue("remote.SSH.path", out value))
                    {
                        sshPath = value as string;
                        if (sshPath == null) { throw Invalid(); }
                        if (!String.IsNullOrWhiteSpace(sshPath)) {
                            try {
                                sshPath = LocalPath(sshPath, userHome);
                                if (!String.Equals(Path.GetExtension(sshPath), ".exe", StringComparison.OrdinalIgnoreCase) || !File.Exists(sshPath)) { throw new ArgumentException(); }
                            }
                            catch (Exception error) {
                                if (!(error is IOException) && !(error is UnauthorizedAccessException) && !(error is ArgumentException) && !(error is NotSupportedException)) { throw; }
                                warnings.Add(edition + " 指定的 remote.SSH.path 无效或不存在，请在 VS Code 中检查 SSH 客户端路径。该来源未回退到其他客户端。");
                                continue;
                            }
                        }
                        else { sshPath = null; }
                    }
                    if (configPath != null) { AddSource(configPath, edition == "Code" ? "VS Code" : "VS Code Insiders", sshPath, userHome, configPath != defaultConfig, sources, seen, warnings); }
                }
                catch (Exception error)
                {
                    if (!(error is IOException) && !(error is UnauthorizedAccessException) && !(error is ArgumentException) && !(error is InvalidOperationException)) { throw; }
                    warnings.Add("无法读取 " + edition + " 的 SSH 配置或客户端设置，其他来源仍可使用。");
                }
            }
            // Prefer VS Code's explicitly configured client for the initial
            // selection. Keep automatic-client sources as visible alternatives,
            // with stable order within both groups.
            List<ConfigSource> ordered = sources.FindAll(delegate(ConfigSource source) { return !String.IsNullOrWhiteSpace(source.SshPath); });
            ordered.AddRange(sources.FindAll(delegate(ConfigSource source) { return String.IsNullOrWhiteSpace(source.SshPath); }));
            return ordered;
        }
        private static string LocalPath(string raw, string userHome)
        {
            string path = raw.Replace("${userHome}", userHome ?? "");
            path = Regex.Replace(path, @"\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}", delegate(Match match) {
                return Environment.GetEnvironmentVariable(match.Groups[1].Value) ?? match.Value;
            });
            path = Environment.ExpandEnvironmentVariables(path);
            if (path.StartsWith("~/", StringComparison.Ordinal) || path.StartsWith("~\\", StringComparison.Ordinal)) { path = Path.Combine(userHome ?? "", path.Substring(2)); }
            if (path.IndexOf("${", StringComparison.Ordinal) >= 0 || path.IndexOf('%') >= 0 || !Path.IsPathRooted(path)) { throw new ArgumentException(); }
            path = Path.GetFullPath(path);
            // Reject network/device paths before File.Exists can trigger SMB.
            if (path.StartsWith("\\\\", StringComparison.Ordinal) || path.StartsWith("//", StringComparison.Ordinal)) { throw new ArgumentException(); }
            return path;
        }
        private static void AddSource(string raw, string label, string sshPath, string userHome, bool warnMissing, List<ConfigSource> sources, HashSet<string> seen, List<string> warnings)
        {
            try
            {
                string path = LocalPath(raw, userHome);
                if (!File.Exists(path)) { if (warnMissing) { warnings.Add("未找到 SSH 配置：" + path); } return; }
                if (seen.Add(path + "|" + (sshPath ?? ""))) { sources.Add(new ConfigSource { Path = path, Label = label, SshPath = sshPath }); }
            }
            catch (Exception error)
            {
                if (!(error is IOException) && !(error is UnauthorizedAccessException) && !(error is ArgumentException) && !(error is NotSupportedException)) { throw; }
                warnings.Add("SSH 配置路径无效，请使用绝对路径或选择文件。");
            }
        }
        // JSONC support is syntax-only: no script execution, settings mutation,
        // interpolation of commands, or recursive VS Code profile discovery.
        internal static string StripJsonComments(string input)
        {
            StringBuilder clean = new StringBuilder();
            bool quoted = false, escape = false;
            for (int index = 0; index < input.Length; index++)
            {
                char current = input[index];
                if (quoted)
                {
                    clean.Append(current);
                    if (escape) { escape = false; } else if (current == '\\') { escape = true; } else if (current == '"') { quoted = false; }
                    continue;
                }
                if (current == '"') { quoted = true; clean.Append(current); continue; }
                if (current == '/' && index + 1 < input.Length && input[index + 1] == '/')
                {
                    while (index < input.Length && input[index] != '\n' && input[index] != '\r') { index++; }
                    clean.Append(' '); if (index < input.Length) { clean.Append(input[index]); } continue;
                }
                if (current == '/' && index + 1 < input.Length && input[index + 1] == '*')
                {
                    index += 2;
                    while (index + 1 < input.Length && !(input[index] == '*' && input[index + 1] == '/')) { index++; }
                    if (index + 1 >= input.Length) { throw new ArgumentException("Unterminated JSONC comment."); }
                    index++; clean.Append(' '); continue;
                }
                clean.Append(current);
            }
            if (quoted) { throw new ArgumentException("Unterminated JSON string."); }
            string noComments = clean.ToString(); clean.Length = 0; quoted = false; escape = false;
            for (int index = 0; index < noComments.Length; index++)
            {
                char current = noComments[index];
                if (quoted)
                {
                    clean.Append(current);
                    if (escape) { escape = false; } else if (current == '\\') { escape = true; } else if (current == '"') { quoted = false; }
                    continue;
                }
                if (current == '"') { quoted = true; }
                if (current == ',')
                {
                    int next = index + 1;
                    while (next < noComments.Length && Char.IsWhiteSpace(noComments[next])) { next++; }
                    if (next < noComments.Length && (noComments[next] == '}' || noComments[next] == ']')) { continue; }
                }
                clean.Append(current);
            }
            return clean.ToString();
        }
    }
}
