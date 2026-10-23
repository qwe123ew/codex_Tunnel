using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;

namespace CodexTunnelGui
{
    internal sealed class ServerEditorWindow : Window
    {
        private const string Ink = "#283444", Muted = "#64748B", Line = "#E3E8EF", Blue = "#285B93", Red = "#B65050";
        private readonly Func<string, string, Task<HostEntry>> _save;
        private readonly bool _fixtureMode;
        private readonly string _continuation;
        private readonly string _saveCaption;
        private readonly Dictionary<string, object> _profile;
        private readonly List<EndpointFields> _jumps = new List<EndpointFields>();
        private readonly Style _fieldStyle = TunnelWindow.CreateFieldStyle();
        private readonly Style _buttonStyle = TunnelWindow.CreateButtonStyle("outline");
        private readonly Style _ghostStyle = TunnelWindow.CreateButtonStyle("ghost");
        private readonly Style _primaryStyle = TunnelWindow.CreateButtonStyle("primary");
        private Grid _layout;
        private StackPanel _form, _jumpList;
        private Field _name;
        private EndpointFields _server;
        private TextBlock _emptyJumps, _error, _saving;
        private Button _addJump, _saveButton, _cancelButton;
        private bool _committing;
        internal HostEntry SavedEntry { get; private set; }

        internal ServerEditorWindow(string name, string json, Func<string, string, Task<HostEntry>> save, bool fixtureMode, string continuation = null)
        {
            _save = save; _fixtureMode = fixtureMode; _continuation = continuation;
            _saveCaption = continuation == "connect" ? "保存并连接" : continuation == "vscode" ? "保存并配置" : "保存服务器";
            _profile = String.IsNullOrWhiteSpace(json) ? new Dictionary<string, object> { { "version", 1 }, { "remotePort", 11082 }, { "checkIntervalSeconds", 60 } } : new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(json);
            Title = (String.IsNullOrWhiteSpace(json) ? "添加服务器" : "编辑服务器") + " · Codex Tunnel";
            Width = 704; Height = 780; MinWidth = 640; MinHeight = 560;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            Background = Brush("#F5F7FA"); Foreground = Brush(Ink); FontSize = 13;
            FontFamily = new FontFamily("Segoe UI, Microsoft YaHei UI");
            UseLayoutRounding = true; SnapsToDevicePixels = true;
            TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
            Resources.Add(typeof(System.Windows.Controls.Primitives.ScrollBar), TunnelWindow.CreateScrollStyle());
            Build(!String.IsNullOrWhiteSpace(continuation) ? "先添加一台服务器" : String.IsNullOrWhiteSpace(json) ? "添加服务器" : "编辑服务器");
            _name.Input.Text = name ?? "";
            object server; if (_profile.TryGetValue("server", out server)) _server.Load(server as Dictionary<string, object>);
            object hops; if (_profile.TryGetValue("jumpHosts", out hops))
            {
                IEnumerable sequence = hops as IEnumerable;
                if (sequence != null) foreach (object hop in sequence) AddJump(hop as Dictionary<string, object>);
            }
            Closing += delegate(object sender, System.ComponentModel.CancelEventArgs e) { if (_committing) e.Cancel = true; };
            Loaded += delegate { if (!_fixtureMode) _name.Input.Focus(); };
        }

        private static SolidColorBrush Brush(string color) { SolidColorBrush result = (SolidColorBrush)new BrushConverter().ConvertFromString(color); result.Freeze(); return result; }
        private static TextBlock Text(string text, double size, string color) { return new TextBlock { Text = text, FontSize = size, Foreground = Brush(color), TextWrapping = TextWrapping.Wrap }; }
        private static void Place(Grid grid, UIElement element, int column) { Grid.SetColumn(element, column); grid.Children.Add(element); }
        private Button Button(string text, string kind, string icon, RoutedEventHandler action)
        {
            Button button = new Button { Content = text, Style = kind == "primary" ? _primaryStyle : kind == "ghost" ? _ghostStyle : _buttonStyle, Height = 38, Padding = new Thickness(12, 6, 12, 6) };
            if (!String.IsNullOrWhiteSpace(icon)) button.Tag = Geometry.Parse(icon);
            AutomationProperties.SetName(button, text); if (action != null) button.Click += action; return button;
        }
        private void Build(string title)
        {
            _layout = new Grid();
            _layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            _layout.RowDefinitions.Add(new RowDefinition());
            _layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Content = _layout;
            StackPanel heading = new StackPanel { Margin = new Thickness(28, 24, 28, 20) };
            TextBlock label = Text(title, 23, Ink); label.FontWeight = FontWeights.SemiBold; heading.Children.Add(label);
            string introduction = _continuation == "connect" ? "尚未发现服务器配置。填写后保存，软件将继续启动隧道。" : _continuation == "vscode" ? "尚未发现服务器配置。填写后保存，软件将继续配置远程 VS Code。" : "保存到软件自己的配置，下次打开即可选择。";
            TextBlock subtitle = Text(introduction, 12, Muted); subtitle.Margin = new Thickness(0, 7, 0, 0); heading.Children.Add(subtitle); _layout.Children.Add(heading);
            ScrollViewer scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Padding = new Thickness(28, 0, 24, 12) };
            _form = new StackPanel(); scroll.Content = _form; Grid.SetRow(scroll, 1); _layout.Children.Add(scroll);
            if (!String.IsNullOrWhiteSpace(_continuation))
            {
                StackPanel guidance = new StackPanel(); TextBlock guidanceTitle = Text("这些信息从哪里来？", 12, Blue); guidanceTitle.FontWeight = FontWeights.SemiBold; guidance.Children.Add(guidanceTitle);
                TextBlock guidanceText = Text("使用管理员提供的 SSH 登录信息：地址填服务器 IP 或域名，用户名填服务器账号，端口通常是 22。若需要先连接另一台机器，再添加跳板机；直连时留空。", 11, Muted); guidanceText.LineHeight = 18; guidanceText.Margin = new Thickness(0, 6, 0, 0); guidance.Children.Add(guidanceText);
                TextBlock existingTip = Text("已有 VS Code 连接？返回主界面点“刷新”自动读取，或用“选择文件”打开该连接的 SSH 配置。", 11, Muted); existingTip.Margin = new Thickness(0, 5, 0, 0); existingTip.LineHeight = 18; guidance.Children.Add(existingTip);
                _form.Children.Add(new Border { Background = Brush("#EFF6FF"), BorderBrush = Brush("#DBEAFE"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(9), Padding = new Thickness(16, 12, 16, 12), Margin = new Thickness(0, 0, 0, 14), Child = guidance });
            }
            StackPanel target = new StackPanel();
            _name = new Field(this, "显示名称", "例如：实验室 GPU，可自行命名", false); target.Children.Add(_name.Panel);
            _server = new EndpointFields(this); _server.Panel.Margin = new Thickness(0, 14, 0, 0); target.Children.Add(_server.Panel);
            _form.Children.Add(new Border { Background = Brushes.White, BorderBrush = Brush(Line), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Padding = new Thickness(20), Child = target });
            Grid jumpTitle = new Grid { Margin = new Thickness(0, 18, 0, 6) }; jumpTitle.ColumnDefinitions.Add(new ColumnDefinition()); jumpTitle.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            StackPanel jumpHeading = new StackPanel(); TextBlock jt = Text("跳板机", 15, Ink); jt.FontWeight = FontWeights.SemiBold; jumpHeading.Children.Add(jt); jumpHeading.Children.Add(Text("可选 · 按从本机到目标服务器的连接顺序填写", 11, Muted)); Place(jumpTitle, jumpHeading, 0);
            _addJump = Button("添加跳板", "outline", "M 7 2 V 12 M 2 7 H 12", delegate { AddJump(null); }); _addJump.Height = 34; _addJump.FontSize = 12; Place(jumpTitle, _addJump, 1); _form.Children.Add(jumpTitle);
            _emptyJumps = Text("直连服务器时，无需添加跳板机。", 12, Muted); _emptyJumps.Margin = new Thickness(2, 10, 0, 12); _form.Children.Add(_emptyJumps);
            _jumpList = new StackPanel(); _form.Children.Add(_jumpList);
            TextBlock note = Text("密码或验证码在随后打开的 SSH 窗口输入，本软件不保存密码。使用密码登录时，私钥文件留空。", 11, Muted); note.Margin = new Thickness(1, 10, 1, 2); note.LineHeight = 18; _form.Children.Add(note);
            StackPanel footer = new StackPanel { Margin = new Thickness(28, 13, 28, 22) };
            _error = Text("", 12, Red); _error.Margin = new Thickness(0, 0, 0, 10); _error.Visibility = Visibility.Collapsed; footer.Children.Add(_error);
            Grid actions = new Grid(); actions.ColumnDefinitions.Add(new ColumnDefinition()); actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _saving = Text("配置仅保存在这台电脑", 11, Muted); _saving.VerticalAlignment = VerticalAlignment.Center; Place(actions, _saving, 0);
            StackPanel buttons = new StackPanel { Orientation = Orientation.Horizontal }; _cancelButton = Button("取消", "outline", null, delegate { Close(); }); _cancelButton.Width = 86; _cancelButton.IsCancel = true; _cancelButton.Margin = new Thickness(0, 0, 8, 0); buttons.Children.Add(_cancelButton);
            _saveButton = Button(_saveCaption, "primary", "M 2 7 L 5.5 10.5 L 12 3.5", async delegate { await SaveAsync(); }); _saveButton.MinWidth = 136; _saveButton.IsDefault = true; buttons.Children.Add(_saveButton); Place(actions, buttons, 1); footer.Children.Add(actions);
            Border footerBorder = new Border { Background = Brushes.White, BorderBrush = Brush(Line), BorderThickness = new Thickness(0, 1, 0, 0), Child = footer }; Grid.SetRow(footerBorder, 2); _layout.Children.Add(footerBorder);
        }

        private void AddJump(Dictionary<string, object> data)
        {
            if (_jumps.Count >= 4) return;
            EndpointFields endpoint = new EndpointFields(this);
            StackPanel panel = new StackPanel(); Grid heading = new Grid { Margin = new Thickness(0, 0, 0, 9) }; heading.ColumnDefinitions.Add(new ColumnDefinition()); heading.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            endpoint.Ordinal = Text("", 12, Blue); endpoint.Ordinal.FontWeight = FontWeights.SemiBold; endpoint.Ordinal.VerticalAlignment = VerticalAlignment.Center; Place(heading, endpoint.Ordinal, 0);
            Button remove = Button("移除", "ghost", "M 3 3 L 11 11 M 11 3 L 3 11", delegate { _jumps.Remove(endpoint); _jumpList.Children.Remove(endpoint.Container); RefreshJumps(); }); remove.FontSize = 11; remove.Height = 28; remove.Padding = new Thickness(5, 2, 5, 2); Place(heading, remove, 1); panel.Children.Add(heading); panel.Children.Add(endpoint.Panel);
            endpoint.Container = new Border { Background = Brushes.White, BorderBrush = Brush(Line), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(9), Padding = new Thickness(18, 10, 18, 16), Margin = new Thickness(0, 6, 0, 3), Child = panel };
            if (data != null) endpoint.Load(data);
            _jumps.Add(endpoint); _jumpList.Children.Add(endpoint.Container); RefreshJumps();
        }
        private void RefreshJumps()
        {
            for (int i = 0; i < _jumps.Count; i++) _jumps[i].Ordinal.Text = "跳板 " + (i + 1).ToString(CultureInfo.InvariantCulture);
            _emptyJumps.Visibility = _jumps.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            _addJump.IsEnabled = _jumps.Count < 4 && !_committing;
            _addJump.Content = _jumps.Count == 4 ? "最多 4 个" : "添加跳板";
        }
        private bool ValidateForm()
        {
            string name = _name.Input.Text.Trim();
            bool nameValid = name.Length > 0 && name.Length <= 64 && !Regex.IsMatch(name, @"[\x00-\x1f\x7f]");
            _name.SetError(nameValid ? null : "请填写 1–64 个字符的名称。");
            bool valid = _server.Validate() & nameValid;
            foreach (EndpointFields hop in _jumps) valid = hop.Validate() & valid;
            return valid;
        }
        private string SerializeProfile()
        {
            _profile["server"] = _server.Read();
            List<Dictionary<string, object>> hops = new List<Dictionary<string, object>>(); foreach (EndpointFields hop in _jumps) hops.Add(hop.Read());
            _profile["jumpHosts"] = hops;
            return new JavaScriptSerializer().Serialize(_profile);
        }
        private async Task SaveAsync()
        {
            if (_committing) return;
            _error.Visibility = Visibility.Collapsed;
            if (!ValidateForm()) { _error.Text = "请检查标出的字段后再保存。"; _error.Visibility = Visibility.Visible; return; }
            _committing = true; _form.IsEnabled = false; _saveButton.IsEnabled = false; _cancelButton.IsEnabled = false; _saveButton.Content = "保存中…"; _saving.Text = "正在写入软件配置…";
            try
            {
                if (_save == null) throw new InvalidOperationException("保存服务不可用。");
                HostEntry entry = await _save(_name.Input.Text.Trim(), SerializeProfile());
                if (entry == null) throw new InvalidOperationException("未收到服务器保存结果。");
                SavedEntry = entry;
            }
            catch (Exception error) { _error.Text = "保存未完成：" + error.Message; _error.Visibility = Visibility.Visible; }
            finally { _committing = false; _form.IsEnabled = true; _saveButton.IsEnabled = true; _cancelButton.IsEnabled = true; _saveButton.Content = _saveCaption; _saving.Text = "配置仅保存在这台电脑"; RefreshJumps(); }
            if (SavedEntry != null && !_fixtureMode) Close();
        }

        private sealed class Field
        {
            internal readonly StackPanel Panel;
            internal readonly TextBox Input;
            private readonly TextBlock _error;
            internal Field(ServerEditorWindow owner, string label, string hint, bool compact)
            {
                Panel = new StackPanel(); TextBlock title = Text(label, 11, Muted); title.Margin = new Thickness(0, 0, 6, 5); Panel.Children.Add(title);
                Input = new TextBox { Style = owner._fieldStyle, ToolTip = hint, MinHeight = 37 }; AutomationProperties.SetName(Input, label); Panel.Children.Add(Input);
                _error = Text("", 10, Red); _error.Margin = new Thickness(1, 4, 0, 0); _error.Visibility = Visibility.Collapsed; Panel.Children.Add(_error);
                Input.TextChanged += delegate { SetError(null); };
            }
            internal void SetError(string error) { _error.Text = error ?? ""; _error.Visibility = error == null ? Visibility.Collapsed : Visibility.Visible; Input.BorderBrush = Brush(error == null ? Line : Red); }
        }
        private sealed class EndpointFields
        {
            internal readonly StackPanel Panel;
            internal readonly Field Host, User, Port, Key;
            internal Border Container;
            internal TextBlock Ordinal;
            internal EndpointFields(ServerEditorWindow owner)
            {
                Panel = new StackPanel(); Grid fields = new Grid(); fields.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(2.1, GridUnitType.Star) }); fields.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.3, GridUnitType.Star) }); fields.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(76) });
                Host = new Field(owner, "服务器地址", "IP 地址或域名，不含用户名和端口", false); Host.Panel.Margin = new Thickness(0, 0, 10, 0); Place(fields, Host.Panel, 0);
                User = new Field(owner, "用户名", "SSH 登录用户名", false); User.Panel.Margin = new Thickness(0, 0, 10, 0); Place(fields, User.Panel, 1);
                Port = new Field(owner, "SSH 端口", "1–65535，默认 22", true); Port.Input.Text = "22"; Place(fields, Port.Panel, 2); Panel.Children.Add(fields);
                Grid keyRow = new Grid { Margin = new Thickness(0, 13, 0, 0) }; keyRow.ColumnDefinitions.Add(new ColumnDefinition()); keyRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                Key = new Field(owner, "私钥文件 · 可选", "选择本机的私钥文件；无需粘贴文件内容", false); Key.Panel.Margin = new Thickness(0, 0, 8, 0); Place(keyRow, Key.Panel, 0);
                Button browse = owner.Button("选择文件", "outline", "M 1.5 4 V 11.5 H 12.5 V 4 H 7 L 5.5 2.5 H 1.5 Z", delegate
                {
                    if (owner._fixtureMode) return;
                    OpenFileDialog picker = new OpenFileDialog { Title = "选择本机私钥文件", CheckFileExists = true, Multiselect = false, Filter = "所有文件|*.*" };
                    // Do not probe a typed path synchronously; unavailable network paths can block the UI.
                    picker.InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                    if (picker.ShowDialog(owner) == true) Key.Input.Text = picker.FileName;
                }); browse.FontSize = 11; browse.Padding = new Thickness(8, 6, 8, 6); browse.Margin = new Thickness(0, 21, 0, 0); browse.VerticalAlignment = VerticalAlignment.Top; browse.Height = 37; Place(keyRow, browse, 1); Panel.Children.Add(keyRow);
            }
            internal void Load(Dictionary<string, object> data)
            {
                if (data == null) return;
                Host.Input.Text = Value(data, "host", ""); User.Input.Text = Value(data, "user", ""); Port.Input.Text = Value(data, "port", "22"); Key.Input.Text = Value(data, "identityFile", "");
            }
            private static string Value(Dictionary<string, object> data, string key, string fallback) { object value; return data.TryGetValue(key, out value) ? Convert.ToString(value, CultureInfo.InvariantCulture) : fallback; }
            internal Dictionary<string, object> Read()
            {
                int port; Int32.TryParse(Port.Input.Text.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out port);
                return new Dictionary<string, object> { { "host", Host.Input.Text.Trim() }, { "user", User.Input.Text.Trim() }, { "port", port }, { "identityFile", Key.Input.Text.Trim() } };
            }
            internal bool Validate()
            {
                string host = Host.Input.Text.Trim(), user = User.Input.Text.Trim(), key = Key.Input.Text.Trim(); IPAddress ip;
                bool hostValid = host.Length <= 253 && !Regex.IsMatch(host, @"[\s\[\]]") && (IPAddress.TryParse(host, out ip) || Regex.IsMatch(host, @"\A[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?\z"));
                bool userValid = Regex.IsMatch(user, @"\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}\z");
                int port; bool portValid = Int32.TryParse(Port.Input.Text.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out port) && port > 0 && port <= 65535;
                // Existence is checked by the bounded backend helper; keep form validation nonblocking.
                bool keyValid = key.Length == 0 || String.Equals(key, "none", StringComparison.OrdinalIgnoreCase) || (!Regex.IsMatch(key, "[\\r\\n\"%\\x00]") && !key.StartsWith(@"\\", StringComparison.Ordinal) && Path.IsPathRooted(key));
                Host.SetError(hostValid ? null : "请输入 IP 或域名，不含端口。"); User.SetError(userValid ? null : "请填写有效的 SSH 用户名。"); Port.SetError(portValid ? null : "1–65535"); Key.SetError(keyValid ? null : "请选择本机文件的完整路径，或留空。");
                return hostValid && userValid && portValid && keyValid;
            }
        }

        internal static ServerEditorWindow Preview(bool withJumps, bool onboarding = false)
        {
            ServerEditorWindow editor = new ServerEditorWindow(onboarding ? "" : "实验室 GPU", null, null, true, onboarding ? "connect" : null);
            if (onboarding) editor.Height = 880;
            else editor._server.Load(new Dictionary<string, object> { { "host", "gpu.example.net" }, { "user", "researcher" }, { "port", 22 } });
            if (withJumps)
            {
                editor.AddJump(new Dictionary<string, object> { { "host", "gateway.example.net" }, { "user", "researcher" }, { "port", 22 } });
                editor.AddJump(new Dictionary<string, object> { { "host", "internal-gateway" }, { "user", "researcher" }, { "port", 2222 } });
                editor.Height = 1000;
            }
            return editor;
        }
        internal FrameworkElement TakePreviewContent() { FrameworkElement content = (FrameworkElement)Content; Content = null; return content; }
        internal static void RunSelfTests(List<Dictionary<string, object>> checks)
        {
            Action<string, bool> check = delegate(string name, bool passed) { checks.Add(new Dictionary<string, object> { { "name", name }, { "passed", passed } }); };
            ServerEditorWindow editor = new ServerEditorWindow("", null, null, true);
            check("editor_empty_fields_rejected", !editor.ValidateForm());
            bool cancelSaved = false;
            ServerEditorWindow onboarding = new ServerEditorWindow("", null, delegate { cancelSaved = true; return Task.FromResult(new HostEntry { Id = "unexpected" }); }, true, "connect");
            check("onboarding_default_port_and_action", onboarding._server.Port.Input.Text == "22" && Convert.ToString(onboarding._saveButton.Content) == "保存并连接" && onboarding._jumps.Count == 0);
            onboarding._cancelButton.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
            check("onboarding_cancel_does_not_save", !cancelSaved && onboarding.SavedEntry == null);
            editor._name.Input.Text = "  实验室 GPU  "; editor._server.Load(new Dictionary<string, object> { { "host", "gpu.example.net" }, { "user", "researcher" }, { "port", 22 } });
            check("editor_direct_valid_without_key", editor.ValidateForm());
            editor._server.Host.Input.Text = "user@host:22"; check("editor_host_rejects_embedded_user_port", !editor.ValidateForm()); editor._server.Host.Input.Text = "2001:db8::1"; check("editor_accepts_ipv6", editor.ValidateForm());
            editor._server.User.Input.Text = "name;whoami"; check("editor_rejects_shell_user", !editor.ValidateForm()); editor._server.User.Input.Text = "researcher";
            editor._server.Port.Input.Text = "65536"; check("editor_rejects_invalid_port", !editor.ValidateForm()); editor._server.Port.Input.Text = "22";
            editor._name.Input.Text = new string('a', 65); check("editor_name_limit_64", !editor.ValidateForm()); editor._name.Input.Text = "test";
            editor._server.Key.Input.Text = @"\\unavailable-host\share\key"; check("editor_rejects_network_key_without_io", !editor.ValidateForm()); editor._server.Key.Input.Text = "";
            for (int i = 0; i < 5; i++) editor.AddJump(new Dictionary<string, object> { { "host", "jump" + i + ".example.net" }, { "user", "hop" + i }, { "port", 2200 + i }, { "identityFile", i % 2 == 0 ? "none" : "" } });
            check("editor_max_four_ordered_jumps", editor._jumps.Count == 4 && !editor._addJump.IsEnabled && editor.ValidateForm());
            editor._profile["remotePort"] = 12082; editor._profile["checkIntervalSeconds"] = 75;
            string json = editor.SerializeProfile(); ServerEditorWindow reopened = new ServerEditorWindow("test", json, null, true);
            check("editor_edit_retains_order_keys_and_options", reopened._jumps.Count == 4 && reopened._jumps[2].Host.Input.Text == "jump2.example.net" && reopened._jumps[2].Key.Input.Text == "none" && Convert.ToInt32(reopened._profile["remotePort"]) == 12082 && Convert.ToInt32(reopened._profile["checkIntervalSeconds"]) == 75 && reopened.SerializeProfile() == json);
            ServerEditorWindow failed = new ServerEditorWindow("test", json, delegate { TaskCompletionSource<HostEntry> task = new TaskCompletionSource<HostEntry>(); task.SetException(new IOException("fixture save failure")); return task.Task; }, true);
            failed.SaveAsync().GetAwaiter().GetResult(); check("editor_save_failure_retains_input_and_recovers", failed.SavedEntry == null && failed._error.Visibility == Visibility.Visible && failed._form.IsEnabled && failed._saveButton.IsEnabled && failed.SerializeProfile() == json);
            ServerEditorWindow success = new ServerEditorWindow("test", json, delegate { return Task.FromResult(new HostEntry { Id = "fixture-saved", Kind = "saved", Alias = "test" }); }, true);
            success.SaveAsync().GetAwaiter().GetResult(); check("editor_save_returns_selection_id", success.SavedEntry != null && success.SavedEntry.Id == "fixture-saved");
            ServerEditorWindow setup = new ServerEditorWindow("test", json, delegate { return Task.FromResult(new HostEntry { Id = "fixture-config", Kind = "saved", Alias = "test" }); }, true, "vscode");
            setup.SaveAsync().GetAwaiter().GetResult(); check("onboarding_config_save_preserves_continuation", setup.SavedEntry != null && Convert.ToString(setup._saveButton.Content) == "保存并配置");
            ServerEditorWindow guarded = null; bool controlsLocked = false, closingBlocked = false;
            guarded = new ServerEditorWindow("test", json, delegate
            {
                controlsLocked = guarded._committing && !guarded._form.IsEnabled && !guarded._saveButton.IsEnabled && !guarded._cancelButton.IsEnabled;
                guarded.Close();
                return Task.FromResult(new HostEntry { Id = "fixture-guard", Kind = "saved", Alias = "test" });
            }, true);
            guarded.Closing += delegate(object sender, System.ComponentModel.CancelEventArgs e) { closingBlocked = e.Cancel; };
            guarded.SaveAsync().GetAwaiter().GetResult();
            check("editor_pending_commit_locks_form_and_close", controlsLocked && closingBlocked);
            editor.Close(); reopened.Close(); failed.Close(); success.Close(); guarded.Close(); setup.Close();
        }
    }
}
