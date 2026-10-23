using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;

[assembly: AssemblyTitle("Codex Tunnel")]
[assembly: AssemblyDescription("Desktop workspace connection manager for an isolated SSH proxy tunnel")]
[assembly: AssemblyProduct("Codex Tunnel")]
[assembly: AssemblyVersion("2.4.0.0")]
[assembly: AssemblyFileVersion("2.4.0.0")]

namespace CodexTunnelGui
{
    internal static class Program
    {
        internal const string Version = "2.4.0";

        [STAThread]
        private static int Main(string[] args)
        {
            bool preview = args.Length > 0 && args[0] == "--render-preview";
            bool selfTest = args.Length > 0 && args[0] == "--ui-self-test";
            try
            {
                if (args.Length == 1 && args[0] == "--version") { Console.WriteLine("Codex Tunnel " + Version); return 0; }
                if ((preview && (args.Length < 2 || args.Length > 5)) || (selfTest && args.Length != 2)) { throw new ArgumentException("Use --render-preview PATH.png [WINDOW_WIDTH WINDOW_HEIGHT] [default|advanced|connected|dropdown|buttons|empty|add-server|add-jumps|onboarding|vscode-config], or --ui-self-test PATH.json."); }
                if (args.Length > 0 && !preview && !selfTest) { throw new ArgumentException("Supported options: --render-preview PATH.png, --ui-self-test PATH.json, --version."); }
                if ((preview || selfTest) && !Path.IsPathRooted(args[1])) { throw new ArgumentException("Use an absolute output path."); }
                Application app = new Application();
                app.ShutdownMode = ShutdownMode.OnMainWindowClose;
                TunnelWindow window = new TunnelWindow(preview || selfTest);
                app.MainWindow = window;
                if (selfTest)
                {
                    Dictionary<string, object> report = window.RunSelfTest();
                    SaveText(args[1], new JavaScriptSerializer().Serialize(report));
                    window.Close();
                    return (bool)report["passed"] ? 0 : 1;
                }
                if (preview)
                {
                    if (args.Length >= 4)
                    {
                        int width, height;
                        if (!Int32.TryParse(args[2], out width) || !Int32.TryParse(args[3], out height) || width < 940 || height < 720 || width > 4096 || height > 4096) throw new ArgumentException("Preview window dimensions must be within 940x720 and 4096x4096.");
                        window.Width = width; window.Height = height;
                    }
                    window.LoadPreviewFixture();
                    window.SetPreviewState(args.Length == 3 ? args[2] : args.Length == 5 ? args[4] : "default");
                    window.RenderPreview(args[1]);
                    window.Close();
                    return 0;
                }
                app.DispatcherUnhandledException += delegate(object sender, DispatcherUnhandledExceptionEventArgs e)
                {
                    window.ReportError("界面操作未完成", e.Exception);
                    e.Handled = true;
                };
                app.Run(window);
                return 0;
            }
            catch (Exception error)
            {
                if (preview || selfTest)
                {
                    try { if (args.Length > 1 && Path.IsPathRooted(args[1])) { SaveText(args[1] + ".error.txt", error.ToString()); } } catch { }
                }
                else { MessageBox.Show(error.Message, "Codex Tunnel", MessageBoxButton.OK, MessageBoxImage.Error); }
                return 1;
            }
        }

        internal static void SaveText(string path, string content)
        {
            string directory = Path.GetDirectoryName(Path.GetFullPath(path));
            Directory.CreateDirectory(directory);
            File.WriteAllText(path, content, new UTF8Encoding(false));
        }
    }

    internal sealed class HostChoice
    {
        internal HostEntry Entry;
        public string Name { get { return Entry.Alias; } }
        public string Source { get { return Entry.Kind == "saved" ? "软件保存" : String.IsNullOrWhiteSpace(Entry.SourceLabel) ? "SSH 配置" : Entry.SourceLabel; } }
        public string SourcePath { get { return Entry.ConfigPath ?? Entry.SourceFile ?? Source; } }
    }

    internal sealed class TunnelWindow : Window
    {
        private const string BackgroundHex = "#F5F7FA", CardHex = "#FFFFFF", SecondaryHex = "#F8FAFC";
        private const string BorderHex = "#E3E8EF", TextHex = "#283444", MutedHex = "#64748B";
        private const string AccentHex = "#DBEAFE", AccentInkHex = "#285B93", AccentBorderHex = "#B9D3F0", FocusHex = "#518CCB";
        private const string SuccessHex = "#327A64", OrangeHex = "#956425", RedHex = "#B65050";
        private const string PlayIcon = "M 3 2 L 12 7 L 3 12 Z", StopIcon = "M 3 3 H 11 V 11 H 3 Z";
        private const string RefreshIcon = "M 11.7 4.5 A 5 5 0 1 0 12 9 M 11.7 1.7 V 4.8 H 8.5";
        private const string FolderIcon = "M 1.5 4 V 11.5 H 12.5 V 4 H 7 L 5.5 2.5 H 1.5 Z";
        private const string CopyIcon = "M 5 4 H 12 V 12 H 5 Z M 9 4 V 1.5 H 2 V 9 H 5";
        private const string ClearIcon = "M 2 4 H 12 M 5 4 V 2 H 9 V 4 M 3.5 4 L 4 12 H 10 L 10.5 4 M 6 6.5 V 9.5 M 8 6.5 V 9.5";
        private const string HelpIcon = "M 7 1.5 A 5.5 5.5 0 1 1 6.99 1.5 M 5.3 5.3 C 5.3 3.3 9 3.3 9 5.3 C 9 6.8 7 6.5 7 8 M 7 10 V 10.1";
        private const string AddIcon = "M 7 2 V 12 M 2 7 H 12";
        private const string EditIcon = "M 2 9.5 L 9.5 2 L 12 4.5 L 4.5 12 H 2 Z M 8 3.5 L 10.5 6";
        private const string CodeIcon = "M 4.5 3.5 L 1 7 L 4.5 10.5 M 9.5 3.5 L 13 7 L 9.5 10.5 M 8 2 L 6 12";
        private readonly bool _fixtureMode;
        private TunnelBackend _backend;
        private ProfileInfo _profile;
        private string _sshConfig;
        private string _catalogSummary = "自动读取本机 SSH 配置与软件保存的服务器";
        private bool _busy, _checking, _suppressSelection, _closed, _closing, _starting, _stopping, _configuringVscode, _cancellingVscode;
        private int _resolveGeneration, _vscodeConfiguredPort;
        private bool _vscodeNeedsReconfigure;
        private long _lastStatusSequence;
        private DispatcherTimer _stateTimer;
        private Grid _root;
        private ComboBox _hosts;
        private Button _refreshButton, _browseButton, _startButton, _stopButton, _proxyButton, _addButton, _editButton, _autoButton, _vscodeButton, _vscodeCancelButton;
        private TextBox _remotePort, _localPort, _logs;
        private TextBlock _source, _hostValue, _userValue, _portValue, _routeValue;
        private TextBlock _pillText, _healthTitle, _healthMessage, _healthRoute, _lastVerifiedLabel, _proxyUrl, _proxyHttp, _proxyMessage, _authTip;
        private TextBlock _vscodeMessage;
        private Border _pill, _healthIndicator, _proxyIndicator;
        private Expander _advanced;
        private string _phase = "idle";
        private string _previewState = "default";
        private readonly Style _buttonStyle, _primaryButtonStyle, _ghostButtonStyle, _fieldStyle;

        internal TunnelWindow(bool fixtureMode)
        {
            _fixtureMode = fixtureMode;
            Title = "Codex Tunnel";
            Width = 1100; Height = 780; MinWidth = 940; MinHeight = 720;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Background = Brush(BackgroundHex); Foreground = Brush(TextHex);
            FontFamily = new FontFamily("Segoe UI, Microsoft YaHei UI"); FontSize = 13;
            UseLayoutRounding = true; SnapsToDevicePixels = true;
            TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
            LoadApplicationIcon();
            _buttonStyle = CreateButtonStyle("outline");
            _primaryButtonStyle = CreateButtonStyle("primary");
            _ghostButtonStyle = CreateButtonStyle("ghost");
            _fieldStyle = CreateFieldStyle();
            Resources.Add(typeof(ScrollBar), CreateScrollStyle());
            BuildInterface();
            ApplyStatus(new TunnelStatus { Phase = "idle", Message = "选择服务器后启动连接。远端代理验证通过后，这里会显示就绪。" });
            SetAvailability(false);
            Closing += async delegate(object sender, System.ComponentModel.CancelEventArgs e)
            {
                if (_closed) return;
                e.Cancel = true;
                if (_closing) return;
                _closing = true;
                if (_stateTimer != null) _stateTimer.Stop();
                TunnelBackend backend = _backend;
                _backend = null;
                IsEnabled = false;
                // Owned-process cleanup can wait briefly; keep the dispatcher responsive.
                if (backend != null)
                {
                    try { await Task.Run(delegate { backend.Dispose(); }); }
                    catch (Exception) { /* The backend owns all jobs; OS handle disposal remains fail-closed. */ }
                }
                _closed = true;
                Close();
            };
            if (!_fixtureMode)
            {
                _sshConfig = null;
                _source.Text = "正在自动查找本机服务器配置…";
                _backend = new TunnelBackend();
                _backend.Log += delegate(string line) { OnUi(delegate { AppendLog(line); }); };
                _backend.StatusChanged += delegate(TunnelStatus status) { OnUi(delegate { ApplyStatus(status); UpdateAvailability(); }); };
                _stateTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
                _stateTimer.Tick += delegate { UpdateAvailability(); };
                _stateTimer.Start();
                Loaded += async delegate { await RefreshHostsAsync(); };
            }
        }

        private static SolidColorBrush Brush(string color)
        {
            SolidColorBrush brush = (SolidColorBrush)new BrushConverter().ConvertFromString(color);
            brush.Freeze(); return brush;
        }

        private void LoadApplicationIcon()
        {
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("CodexTunnelGui.Brand.app.ico"))
            {
                if (stream == null) return;
                BitmapDecoder decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
                BitmapFrame best = null;
                foreach (BitmapFrame frame in decoder.Frames) if (best == null || frame.PixelWidth > best.PixelWidth) best = frame;
                if (best != null) { best.Freeze(); Icon = best; }
            }
        }

        internal static Style CreateButtonStyle(string variant)
        {
            bool primary = variant == "primary", ghost = variant == "ghost";
            string background = primary ? AccentHex : ghost ? "Transparent" : CardHex;
            string foreground = primary ? AccentInkHex : TextHex;
            string border = primary ? AccentBorderHex : ghost ? "Transparent" : BorderHex;
            string hover = primary ? "#CFE3FA" : "#F0F4F8";
            string pressed = primary ? "#BBD6F5" : "#E5ECF3";
            string xaml = "<Style xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='{x:Type Button}' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>" +
                "<Setter Property='Background' Value='" + background + "'/><Setter Property='Foreground' Value='" + foreground + "'/>" +
                "<Setter Property='BorderBrush' Value='" + border + "'/><Setter Property='BorderThickness' Value='1'/><Setter Property='Padding' Value='13,8'/>" +
                "<Setter Property='FontSize' Value='13'/><Setter Property='FontWeight' Value='Medium'/><Setter Property='Cursor' Value='Hand'/><Setter Property='FocusVisualStyle' Value='{x:Null}'/>" +
                "<Setter Property='HorizontalContentAlignment' Value='Center'/><Setter Property='VerticalContentAlignment' Value='Center'/>" +
                "<Setter Property='Template'><Setter.Value><ControlTemplate TargetType='{x:Type Button}'>" +
                "<Border x:Name='focus' BorderBrush='Transparent' BorderThickness='2' CornerRadius='10'><Border x:Name='shell' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}' CornerRadius='7'>" +
                "<StackPanel Orientation='Horizontal' Margin='{TemplateBinding Padding}' HorizontalAlignment='{TemplateBinding HorizontalContentAlignment}' VerticalAlignment='{TemplateBinding VerticalContentAlignment}'>" +
                "<Path x:Name='icon' Data='{TemplateBinding Tag}' Width='14' Height='14' Stretch='Uniform' Stroke='{TemplateBinding Foreground}' StrokeThickness='1.4' StrokeStartLineCap='Round' StrokeEndLineCap='Round' StrokeLineJoin='Round' Margin='0,0,8,0' VerticalAlignment='Center'/>" +
                "<ContentPresenter VerticalAlignment='Center' RecognizesAccessKey='True'/></StackPanel></Border></Border>" +
                "<ControlTemplate.Triggers><Trigger Property='Tag' Value='{x:Null}'><Setter TargetName='icon' Property='Visibility' Value='Collapsed'/></Trigger>" +
                "<Trigger Property='IsMouseOver' Value='True'><Setter TargetName='shell' Property='Background' Value='" + hover + "'/></Trigger>" +
                "<Trigger Property='IsPressed' Value='True'><Setter TargetName='shell' Property='Background' Value='" + pressed + "'/></Trigger>" +
                "<Trigger Property='IsKeyboardFocused' Value='True'><Setter TargetName='focus' Property='BorderBrush' Value='" + FocusHex + "'/></Trigger>" +
                "<Trigger Property='IsEnabled' Value='False'><Setter Property='Foreground' Value='#A3ADBB'/><Setter TargetName='shell' Property='Background' Value='" + (ghost ? "Transparent" : "#F3F5F7") + "'/><Setter TargetName='shell' Property='BorderBrush' Value='" + (ghost ? "Transparent" : "#E7EBF0") + "'/><Setter Property='Cursor' Value='Arrow'/></Trigger>" +
                "</ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>";
            return (Style)XamlReader.Parse(xaml);
        }

        internal static Style CreateFieldStyle()
        {
            return (Style)XamlReader.Parse(@"<Style xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' TargetType='{x:Type TextBox}'>
              <Setter Property='Background' Value='#FFFFFF'/><Setter Property='Foreground' Value='#283444'/><Setter Property='BorderBrush' Value='#E3E8EF'/><Setter Property='BorderThickness' Value='1'/><Setter Property='Padding' Value='11,8'/><Setter Property='FontSize' Value='13'/><Setter Property='MinHeight' Value='38'/><Setter Property='VerticalContentAlignment' Value='Center'/><Setter Property='CaretBrush' Value='#285B93'/><Setter Property='SelectionBrush' Value='#B9D3F0'/><Setter Property='FocusVisualStyle' Value='{x:Null}'/>
              <Setter Property='Template'><Setter.Value><ControlTemplate TargetType='{x:Type TextBox}'><Border x:Name='shell' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}' CornerRadius='7'><ScrollViewer x:Name='PART_ContentHost'/></Border>
                <ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='shell' Property='BorderBrush' Value='#B9D3F0'/></Trigger><Trigger Property='IsKeyboardFocusWithin' Value='True'><Setter TargetName='shell' Property='BorderBrush' Value='#518CCB'/></Trigger><Trigger Property='IsEnabled' Value='False'><Setter TargetName='shell' Property='Background' Value='#F3F5F7'/><Setter Property='Foreground' Value='#A3ADBB'/></Trigger></ControlTemplate.Triggers>
              </ControlTemplate></Setter.Value></Setter></Style>");
        }

        private static Style CreateComboStyle()
        {
            return (Style)XamlReader.Parse(@"<Style xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' TargetType='{x:Type ComboBox}'>
              <Setter Property='Background' Value='#FFFFFF'/><Setter Property='Foreground' Value='#283444'/><Setter Property='BorderBrush' Value='#E3E8EF'/><Setter Property='Padding' Value='12,10'/><Setter Property='FocusVisualStyle' Value='{x:Null}'/><Setter Property='ScrollViewer.HorizontalScrollBarVisibility' Value='Disabled'/><Setter Property='ScrollViewer.VerticalScrollBarVisibility' Value='Auto'/>
              <Setter Property='ItemContainerStyle'><Setter.Value><Style TargetType='{x:Type ComboBoxItem}'><Setter Property='Padding' Value='12,10'/><Setter Property='Foreground' Value='#283444'/><Setter Property='Background' Value='#FFFFFF'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='{x:Type ComboBoxItem}'><Border x:Name='item' Background='{TemplateBinding Background}' Padding='{TemplateBinding Padding}' CornerRadius='5' Margin='3,1'><ContentPresenter/></Border><ControlTemplate.Triggers><Trigger Property='IsHighlighted' Value='True'><Setter TargetName='item' Property='Background' Value='#F0F5FB'/></Trigger><Trigger Property='IsSelected' Value='True'><Setter TargetName='item' Property='Background' Value='#DBEAFE'/><Setter Property='Foreground' Value='#285B93'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style></Setter.Value></Setter>
              <Setter Property='Template'><Setter.Value><ControlTemplate TargetType='{x:Type ComboBox}'>
                <Grid><Border x:Name='outline' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='1' CornerRadius='7'>
                <ToggleButton Focusable='False' ClickMode='Press' IsChecked='{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}'><ToggleButton.Template><ControlTemplate TargetType='{x:Type ToggleButton}'><Border Background='Transparent'><Path Data='M 0 0 L 4 4 L 8 0' Stroke='#64748B' StrokeThickness='1.4' StrokeStartLineCap='Round' StrokeEndLineCap='Round' HorizontalAlignment='Right' VerticalAlignment='Center' Margin='0,0,14,0'/></Border></ControlTemplate></ToggleButton.Template></ToggleButton></Border>
                <ContentPresenter IsHitTestVisible='False' Margin='12,10,34,10' VerticalAlignment='Center' Content='{TemplateBinding SelectionBoxItem}' ContentTemplate='{TemplateBinding SelectionBoxItemTemplate}'/>
                <Popup x:Name='PART_Popup' Placement='Bottom' IsOpen='{TemplateBinding IsDropDownOpen}' AllowsTransparency='True' Focusable='False' PopupAnimation='Fade'><Border Background='#FFFFFF' BorderBrush='#E3E8EF' BorderThickness='1' CornerRadius='8' Padding='3' Margin='0,4,0,0' MinWidth='{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}' MaxHeight='260'><ScrollViewer><ItemsPresenter KeyboardNavigation.DirectionalNavigation='Contained'/></ScrollViewer></Border></Popup>
                </Grid><ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='outline' Property='BorderBrush' Value='#B9D3F0'/></Trigger><Trigger Property='IsKeyboardFocusWithin' Value='True'><Setter TargetName='outline' Property='BorderBrush' Value='#518CCB'/></Trigger><Trigger Property='IsDropDownOpen' Value='True'><Setter TargetName='outline' Property='BorderBrush' Value='#518CCB'/></Trigger><Trigger Property='IsEnabled' Value='False'><Setter TargetName='outline' Property='Background' Value='#F3F5F7'/><Setter Property='Foreground' Value='#A3ADBB'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>");
        }

        internal static Style CreateScrollStyle()
        {
            return (Style)XamlReader.Parse(@"<Style xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' TargetType='{x:Type ScrollBar}'>
              <Setter Property='Width' Value='9'/><Setter Property='Background' Value='Transparent'/><Setter Property='Template'><Setter.Value><ControlTemplate TargetType='{x:Type ScrollBar}'>
                <Grid Background='{TemplateBinding Background}'><Track x:Name='PART_Track' IsDirectionReversed='True' Minimum='{TemplateBinding Minimum}' Maximum='{TemplateBinding Maximum}' Value='{TemplateBinding Value}' ViewportSize='{TemplateBinding ViewportSize}'>
                  <Track.DecreaseRepeatButton><RepeatButton Command='{x:Static ScrollBar.PageUpCommand}' Focusable='False' Opacity='0'/></Track.DecreaseRepeatButton>
                  <Track.Thumb><Thumb MinHeight='24'><Thumb.Template><ControlTemplate TargetType='{x:Type Thumb}'><Border x:Name='grip' Background='#D7DFE8' CornerRadius='4' Margin='2,0'/><ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='grip' Property='Background' Value='#A8B7C9'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
                  <Track.IncreaseRepeatButton><RepeatButton Command='{x:Static ScrollBar.PageDownCommand}' Focusable='False' Opacity='0'/></Track.IncreaseRepeatButton>
                </Track></Grid></ControlTemplate></Setter.Value></Setter></Style>");
        }

        private static Style CreateExpanderStyle()
        {
            return (Style)XamlReader.Parse(@"<Style xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' TargetType='{x:Type Expander}'>
              <Setter Property='Template'><Setter.Value><ControlTemplate TargetType='{x:Type Expander}'><StackPanel>
                <ToggleButton Focusable='True' Foreground='{TemplateBinding Foreground}' HorizontalContentAlignment='Left' IsChecked='{Binding IsExpanded, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}'>
                  <ToggleButton.Template><ControlTemplate TargetType='{x:Type ToggleButton}'><Border x:Name='shell' BorderThickness='1' BorderBrush='Transparent' CornerRadius='5' Background='Transparent' Padding='5,5'><ContentPresenter HorizontalAlignment='Left'/></Border><ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='shell' Property='Background' Value='#F0F4F8'/></Trigger><Trigger Property='IsKeyboardFocused' Value='True'><Setter TargetName='shell' Property='BorderBrush' Value='#518CCB'/></Trigger></ControlTemplate.Triggers></ControlTemplate></ToggleButton.Template>
                  <StackPanel Orientation='Horizontal'><Path x:Name='arrow' Data='M 0 0 L 4 4 L 0 8' Width='9' Height='9' Stroke='#64748B' StrokeThickness='1.3' StrokeStartLineCap='Round' StrokeEndLineCap='Round' VerticalAlignment='Center' Margin='1,0,8,0'/><ContentPresenter Content='{TemplateBinding Header}'/></StackPanel>
                </ToggleButton><ContentPresenter x:Name='expanded' Visibility='Collapsed' Content='{TemplateBinding Content}'/></StackPanel>
                <ControlTemplate.Triggers><Trigger Property='IsExpanded' Value='True'><Setter TargetName='expanded' Property='Visibility' Value='Visible'/><Setter TargetName='arrow' Property='Data' Value='M 0 0 L 4 4 L 8 0'/></Trigger></ControlTemplate.Triggers>
              </ControlTemplate></Setter.Value></Setter></Style>");
        }

        private TextBlock Text(string text, double size, string color)
        {
            return new TextBlock { Text = text, FontSize = size, Foreground = Brush(color), TextWrapping = TextWrapping.Wrap };
        }

        private Button Button(string caption, bool primary, RoutedEventHandler action)
        {
            Button button = new Button { Content = caption, Style = primary ? _primaryButtonStyle : _buttonStyle, MinHeight = 34 };
            if (action != null) button.Click += action;
            return button;
        }

        private Button IconButton(string caption, string geometry, string variant, RoutedEventHandler action)
        {
            Button button = Button(caption, variant == "primary", action);
            if (variant == "ghost") button.Style = _ghostButtonStyle;
            button.Tag = Geometry.Parse(geometry);
            AutomationProperties.SetName(button, caption);
            return button;
        }

        private Border Card(UIElement child)
        {
            return new Border { Background = Brush(CardHex), BorderBrush = Brush(BorderHex), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Padding = new Thickness(24, 22, 24, 22), Child = child };
        }

        private static void Place(Grid grid, UIElement child, int row, int column)
        {
            Grid.SetRow(child, row); Grid.SetColumn(child, column); grid.Children.Add(child);
        }

        private void BuildInterface()
        {
            _root = new Grid { Margin = new Thickness(32, 28, 32, 20) };
            _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Content = _root;

            Grid header = new Grid { Margin = new Thickness(0, 0, 0, 24) };
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Border logo = new Border { Width = 30, Height = 30, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 3, 13, 0) };
            logo.Child = new System.Windows.Shapes.Path { Data = Geometry.Parse("M 3 6 L 10 12 L 3 18 M 14 18 H 23"), Stroke = Brush(AccentInkHex), StrokeThickness = 2, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round, Width = 25, Height = 25, Stretch = Stretch.Uniform };
            if (Icon != null) logo.Child = new Image { Source = Icon, Width = 30, Height = 30, Stretch = Stretch.Uniform };
            Place(header, logo, 0, 0);
            StackPanel title = new StackPanel();
            TextBlock heading = Text("Codex Tunnel", 26, TextHex); heading.FontWeight = FontWeights.SemiBold; title.Children.Add(heading);
            TextBlock subtitle = Text("连接服务器，使用本机代理", 12, MutedHex); subtitle.Margin = new Thickness(0, 5, 0, 0); title.Children.Add(subtitle);
            Place(header, title, 0, 1);
            _pillText = Text("●  未连接", 12, MutedHex);
            _pill = new Border { CornerRadius = new CornerRadius(15), Background = Brush(CardHex), BorderBrush = Brush(BorderHex), BorderThickness = new Thickness(1), Padding = new Thickness(13, 7, 13, 7), Child = _pillText, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 7, 0, 0) };
            Place(header, _pill, 0, 2);
            Place(_root, header, 0, 0);

            ScrollViewer pageScroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Padding = new Thickness(0, 0, 4, 0) };
            Grid body = new Grid();
            body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            body.RowDefinitions.Add(new RowDefinition { Height = new GridLength(166) });
            Grid top = new Grid();
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.36, GridUnitType.Star) });
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Place(top, BuildServerCard(), 0, 0);
            Grid right = new Grid();
            right.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            right.RowDefinitions.Add(new RowDefinition { Height = new GridLength(14) });
            right.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            Place(right, BuildProxyCard(), 0, 0);
            Place(right, BuildHealthCard(), 2, 0);
            Place(top, right, 0, 2);
            Place(body, top, 0, 0);
            Border logCard = BuildLogCard(); logCard.Margin = new Thickness(0, 16, 0, 0); Place(body, logCard, 1, 0);
            pageScroll.Content = body; Place(_root, pageScroll, 1, 0);

            Grid footer = new Grid { Margin = new Thickness(0, 10, 4, 0) };
            footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }); footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Place(footer, Text("本机代理  →  SSH 隧道  →  远端工作空间", 11, MutedHex), 0, 0);
            Place(footer, Text("Codex Tunnel  /  v" + Program.Version, 11, MutedHex), 0, 1);
            Place(_root, footer, 2, 0);
        }

        private Border BuildServerCard()
        {
            StackPanel panel = new StackPanel();
            Grid heading = new Grid(); heading.ColumnDefinitions.Add(new ColumnDefinition()); heading.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            TextBlock titleText = Text("服务器", 17, TextHex); titleText.FontWeight = FontWeights.SemiBold; titleText.VerticalAlignment = VerticalAlignment.Center; Place(heading, titleText, 0, 0);
            _addButton = IconButton("添加服务器", AddIcon, "outline", async delegate { await EditServerAsync(false); }); _addButton.Height = 34; _addButton.Padding = new Thickness(9, 5, 9, 5); Place(heading, _addButton, 0, 1); panel.Children.Add(heading);
            TextBlock sub = Text("自动读取本机配置，也可直接添加", 12, MutedHex); sub.Margin = new Thickness(0, 4, 0, 13); panel.Children.Add(sub);
            Grid select = new Grid(); select.ColumnDefinitions.Add(new ColumnDefinition()); select.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _hosts = new ComboBox { Style = CreateComboStyle(), MinHeight = 42, Margin = new Thickness(0, 0, 8, 0), ToolTip = "包括软件保存的服务器，以及从本机 SSH 配置发现的 Host 别名。" };
            _hosts.ItemTemplate = (DataTemplate)XamlReader.Parse(@"<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><DockPanel LastChildFill='True' ToolTip='{Binding SourcePath}'><Border DockPanel.Dock='Right' Background='#F0F5FB' CornerRadius='4' Padding='5,2' Margin='10,0,0,0' VerticalAlignment='Center' MaxWidth='100'><TextBlock Text='{Binding Source}' Foreground='#64748B' FontSize='10' TextTrimming='CharacterEllipsis'/></Border><TextBlock Text='{Binding Name}' VerticalAlignment='Center' TextTrimming='CharacterEllipsis'/></DockPanel></DataTemplate>");
            AutomationProperties.SetName(_hosts, "服务器别名");
            _hosts.SelectionChanged += async delegate
            {
                if (!_suppressSelection) { ResetVscodeSelectionStatus(); await ResolveSelectedAsync(); }
            };
            Place(select, _hosts, 0, 0);
            _refreshButton = IconButton("刷新", RefreshIcon, "ghost", async delegate { await RefreshHostsAsync(); }); _refreshButton.Padding = new Thickness(10, 8, 10, 8); Place(select, _refreshButton, 0, 1); panel.Children.Add(select);
            Grid source = new Grid { Margin = new Thickness(0, 6, 0, 10) }; source.ColumnDefinitions.Add(new ColumnDefinition()); source.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _source = Text("尚未载入配置", 10, MutedHex); _source.TextWrapping = TextWrapping.NoWrap; _source.TextTrimming = TextTrimming.CharacterEllipsis; _source.VerticalAlignment = VerticalAlignment.Center; _source.Margin = new Thickness(0, 0, 8, 0); Place(source, _source, 0, 0);
            StackPanel sourceActions = new StackPanel { Orientation = Orientation.Horizontal };
            _editButton = IconButton("编辑", EditIcon, "ghost", async delegate { await EditServerAsync(true); }); _editButton.FontSize = 11; _editButton.Padding = new Thickness(6, 3, 6, 3); _editButton.MinHeight = 28; _editButton.Visibility = Visibility.Collapsed; sourceActions.Children.Add(_editButton);
            _browseButton = IconButton("选择文件", FolderIcon, "ghost", async delegate { await BrowseConfigAsync(); }); _browseButton.FontSize = 11; _browseButton.Padding = new Thickness(6, 3, 6, 3); _browseButton.MinHeight = 28; sourceActions.Children.Add(_browseButton);
            _autoButton = IconButton("自动读取", RefreshIcon, "ghost", async delegate { _sshConfig = null; await RefreshHostsAsync(); }); _autoButton.FontSize = 11; _autoButton.Padding = new Thickness(6, 3, 6, 3); _autoButton.MinHeight = 28; _autoButton.Visibility = Visibility.Collapsed; sourceActions.Children.Add(_autoButton);
            Place(source, sourceActions, 0, 1); panel.Children.Add(source);
            Grid metadata = new Grid();
            metadata.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.55, GridUnitType.Star) }); metadata.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }); metadata.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(.6, GridUnitType.Star) });
            _hostValue = AddMetadata(metadata, 0, "主机地址", "—"); _userValue = AddMetadata(metadata, 1, "用户名", "—"); _portValue = AddMetadata(metadata, 2, "SSH 端口", "—"); panel.Children.Add(metadata);
            TextBlock routeLabel = Text("连接路径", 11, MutedHex); routeLabel.Margin = new Thickness(0, 12, 0, 4); panel.Children.Add(routeLabel);
            _routeValue = Text("选择主机后显示解析结果", 12, MutedHex); _routeValue.MinHeight = 20; panel.Children.Add(_routeValue);
            Border divider = new Border { Height = 1, Background = Brush(BorderHex), Margin = new Thickness(0, 15, 0, 12) }; panel.Children.Add(divider);
            _advanced = new Expander { Header = "高级设置", Style = CreateExpanderStyle(), Foreground = Brush(MutedHex), FontSize = 12, Margin = new Thickness(-5, 0, 0, 16), IsExpanded = false };
            Grid options = new Grid { Margin = new Thickness(0, 10, 0, 2) }; options.ColumnDefinitions.Add(new ColumnDefinition()); options.ColumnDefinitions.Add(new ColumnDefinition());
            StackPanel remote = new StackPanel { Margin = new Thickness(0, 0, 10, 0) }; remote.Children.Add(Text("远端代理端口", 11, MutedHex));
            _remotePort = new TextBox { Text = "11082", Style = _fieldStyle, Margin = new Thickness(0, 5, 0, 0), ToolTip = "远端回环代理端口，范围 1024–65535。" }; AutomationProperties.SetName(_remotePort, "远端代理端口"); remote.Children.Add(_remotePort); Place(options, remote, 0, 0);
            _remotePort.TextChanged += delegate { UpdateVscodePortStatus(); };
            StackPanel local = new StackPanel(); local.Children.Add(Text("本机代理端口 · 留空自动检测", 11, MutedHex));
            _localPort = new TextBox { Text = "", Style = _fieldStyle, Margin = new Thickness(0, 5, 0, 0), ToolTip = "留空自动检测，也可输入本机 HTTP 代理端口。" }; AutomationProperties.SetName(_localPort, "本机代理端口"); local.Children.Add(_localPort); Place(options, local, 0, 1);
            _advanced.Content = options; panel.Children.Add(_advanced);
            WrapPanel actions = new WrapPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(-2, 0, 0, 0) };
            _startButton = IconButton("启动连接", PlayIcon, "primary", async delegate { await StartConnectionAsync(); }); _startButton.Width = 128; _startButton.Height = 42; _startButton.Margin = new Thickness(0, 0, 8, 0); actions.Children.Add(_startButton);
            _stopButton = IconButton("停止", StopIcon, "outline", async delegate { await StopConnectionAsync(); }); _stopButton.Width = 80; _stopButton.Height = 42; _stopButton.Margin = new Thickness(0, 0, 8, 0); actions.Children.Add(_stopButton); panel.Children.Add(actions);
            _authTip = Text("启动后请在打开的 SSH 窗口中完成认证。", 11, MutedHex); _authTip.Margin = new Thickness(0, 10, 0, 0); panel.Children.Add(_authTip);
            _vscodeButton = IconButton("一键配置 VS Code", CodeIcon, "outline", async delegate { await ConfigureVscodeAsync(); });
            _vscodeButton.Height = 42; _vscodeButton.Width = 178; _vscodeButton.Padding = new Thickness(10, 8, 10, 8); _vscodeButton.Foreground = Brush(AccentInkHex); _vscodeButton.BorderBrush = Brush(AccentBorderHex);
            _vscodeButton.ToolTip = "自动设置所选服务器的 VS Code 代理，保留其他远程设置并备份。可能需要再次完成 SSH 认证。"; actions.Children.Add(_vscodeButton);
            Grid vscodeStatus = new Grid { Margin = new Thickness(0, 7, 0, 0) }; vscodeStatus.ColumnDefinitions.Add(new ColumnDefinition()); vscodeStatus.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _vscodeMessage = Text("自动设置远程代理，保留其他设置。仅影响服务器上的 VS Code。", 11, MutedHex); _vscodeMessage.LineHeight = 17; _vscodeMessage.VerticalAlignment = VerticalAlignment.Center; Place(vscodeStatus, _vscodeMessage, 0, 0);
            _vscodeCancelButton = IconButton("取消配置", StopIcon, "ghost", delegate { CancelVscodeConfiguration(); }); _vscodeCancelButton.Height = 34; _vscodeCancelButton.Margin = new Thickness(8, 0, 0, 0); _vscodeCancelButton.Visibility = Visibility.Collapsed; _vscodeCancelButton.FontSize = 11; _vscodeCancelButton.Padding = new Thickness(6, 4, 6, 4); Place(vscodeStatus, _vscodeCancelButton, 0, 1); panel.Children.Add(vscodeStatus);
            Border card = Card(panel); card.MinHeight = 414; return card;
        }

        private TextBlock AddMetadata(Grid grid, int column, string label, string initial)
        {
            StackPanel stack = new StackPanel { Margin = new Thickness(0, 0, 10, 0) };
            stack.Children.Add(Text(label, 11, MutedHex));
            TextBlock value = Text(initial, 13, TextHex); value.Margin = new Thickness(0, 5, 0, 0); value.TextWrapping = TextWrapping.NoWrap; value.TextTrimming = TextTrimming.CharacterEllipsis; stack.Children.Add(value); Place(grid, stack, 0, column); return value;
        }

        private Border BuildProxyCard()
        {
            StackPanel panel = new StackPanel();
            Grid row = new Grid(); row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            TextBlock title = Text("本机代理", 16, TextHex); title.FontWeight = FontWeights.SemiBold; Place(row, title, 0, 0);
            _proxyIndicator = new Border { Width = 7, Height = 7, CornerRadius = new CornerRadius(4), Background = Brush(MutedHex), VerticalAlignment = VerticalAlignment.Center }; Place(row, _proxyIndicator, 0, 1); panel.Children.Add(row);
            _proxyUrl = Text("尚未检测", 15, MutedHex); _proxyUrl.FontFamily = new FontFamily("Consolas, Microsoft YaHei UI"); _proxyUrl.Margin = new Thickness(0, 15, 0, 5); panel.Children.Add(_proxyUrl);
            _proxyHttp = Text("HTTP  —", 11, MutedHex); panel.Children.Add(_proxyHttp);
            _proxyMessage = Text("检测本机 HTTP 代理的可达性。", 11, MutedHex); _proxyMessage.Margin = new Thickness(0, 8, 0, 12); panel.Children.Add(_proxyMessage);
            _proxyButton = IconButton("检测代理", RefreshIcon, "outline", async delegate { await CheckProxyAsync(); }); _proxyButton.HorizontalAlignment = HorizontalAlignment.Left; _proxyButton.Height = 36; _proxyButton.Padding = new Thickness(12, 5, 12, 5); _proxyButton.Margin = new Thickness(-2, 0, 0, 0); panel.Children.Add(_proxyButton);
            return Card(panel);
        }

        private Border BuildHealthCard()
        {
            StackPanel panel = new StackPanel();
            TextBlock caption = Text("隧道状态", 16, TextHex); caption.FontWeight = FontWeights.SemiBold; panel.Children.Add(caption);
            StackPanel row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 15, 0, 8) };
            _healthIndicator = new Border { Width = 9, Height = 9, CornerRadius = new CornerRadius(5), Background = Brush(MutedHex), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 9, 0) }; row.Children.Add(_healthIndicator);
            _healthTitle = Text("等待连接", 17, TextHex); _healthTitle.FontWeight = FontWeights.Medium; row.Children.Add(_healthTitle); panel.Children.Add(row);
            _healthMessage = Text("", 12, MutedHex); _healthMessage.LineHeight = 19; panel.Children.Add(_healthMessage);
            _healthRoute = Text("远端回环地址  127.0.0.1:11082", 10, MutedHex); _healthRoute.Margin = new Thickness(0, 13, 0, 0); _healthRoute.TextWrapping = TextWrapping.Wrap; panel.Children.Add(_healthRoute);
            _lastVerifiedLabel = Text("尚无远端验证记录", 10, MutedHex); _lastVerifiedLabel.Margin = new Thickness(0, 5, 0, 0); panel.Children.Add(_lastVerifiedLabel);
            return Card(panel);
        }

        private Border BuildLogCard()
        {
            Grid content = new Grid(); content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); content.RowDefinitions.Add(new RowDefinition());
            Grid heading = new Grid { Margin = new Thickness(0, 0, 0, 9) }; heading.ColumnDefinitions.Add(new ColumnDefinition()); heading.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            TextBlock label = Text("连接日志", 14, TextHex); label.FontWeight = FontWeights.SemiBold; label.VerticalAlignment = VerticalAlignment.Center; Place(heading, label, 0, 0);
            StackPanel actions = new StackPanel { Orientation = Orientation.Horizontal };
            Button copy = IconButton("复制", CopyIcon, "ghost", delegate { CopyLogs(); }); copy.Padding = new Thickness(8, 3, 8, 3); copy.MinHeight = 28; copy.FontSize = 11; actions.Children.Add(copy);
            Button clear = IconButton("清空", ClearIcon, "ghost", delegate { _logs.Clear(); }); clear.Margin = new Thickness(2, 0, 2, 0); clear.Padding = new Thickness(8, 3, 8, 3); clear.MinHeight = 28; clear.FontSize = 11; actions.Children.Add(clear);
            Button help = IconButton("帮助", HelpIcon, "ghost", delegate { ShowHelp(); }); help.Padding = new Thickness(8, 3, 8, 3); help.MinHeight = 28; help.FontSize = 11; actions.Children.Add(help); Place(heading, actions, 0, 1); Place(content, heading, 0, 0);
            _logs = new TextBox { IsReadOnly = true, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Background = Brush(SecondaryHex), Foreground = Brush(MutedHex), BorderThickness = new Thickness(0), Padding = new Thickness(12, 9, 12, 9), FontFamily = new FontFamily("Consolas, Microsoft YaHei UI"), FontSize = 11, IsReadOnlyCaretVisible = true, SelectionBrush = Brush(AccentBorderHex), CaretBrush = Brush(AccentInkHex) };
            AutomationProperties.SetName(_logs, "连接日志"); Place(content, _logs, 1, 0);
            Border card = Card(content); card.Padding = new Thickness(18, 12, 18, 12); return card;
        }

        private HostEntry SelectedHost
        {
            get { HostChoice choice = _hosts.SelectedItem as HostChoice; return choice == null ? null : choice.Entry; }
        }

        private static HostChoice[] Choices(HostEntry[] entries)
        {
            if (entries == null) return new HostChoice[0];
            HostChoice[] choices = new HostChoice[entries.Length];
            for (int i = 0; i < entries.Length; i++) choices[i] = new HostChoice { Entry = entries[i] };
            return choices;
        }

        private static int PreferredIndex(HostEntry[] entries, string id)
        {
            if (entries == null || entries.Length == 0) return -1;
            for (int i = 0; i < entries.Length; i++) if (String.Equals(entries[i].Id, id, StringComparison.Ordinal)) return i;
            return 0;
        }

        private async Task RefreshHostsAsync(string preferredId = null)
        {
            if (_fixtureMode || _busy || HasActiveTunnel || HasVscodeAction) return;
            string previous = preferredId ?? (SelectedHost == null ? null : SelectedHost.Id);
            _busy = true; _profile = null; int generation = ++_resolveGeneration; UpdateAvailability();
            try
            {
                _source.Text = String.IsNullOrWhiteSpace(_sshConfig) ? "正在自动查找本机配置…" : "正在读取所选文件…";
                HostCatalog catalog = await _backend.LoadCatalogAsync(_sshConfig);
                if (_closed || _closing || generation != _resolveGeneration) return;
                HostEntry[] entries = catalog.Hosts ?? new HostEntry[0];
                _catalogSummary = String.IsNullOrWhiteSpace(catalog.Summary) ? "本机服务器列表" : catalog.Summary;
                _source.Text = _catalogSummary;
                _source.ToolTip = _catalogSummary + "\n" + String.Join("\n", catalog.ConfigPaths ?? new string[0]);
                _autoButton.Visibility = String.IsNullOrWhiteSpace(_sshConfig) ? Visibility.Collapsed : Visibility.Visible;
                _suppressSelection = true;
                _hosts.ItemsSource = Choices(entries);
                _hosts.SelectedIndex = -1;
                if (entries != null && entries.Length > 0)
                {
                    _hosts.SelectedIndex = PreferredIndex(entries, previous);
                    AppendLog("已载入 " + entries.Length.ToString(CultureInfo.InvariantCulture) + " 个服务器。" + _catalogSummary);
                }
                else { ClearProfile(); _routeValue.Text = "还没有服务器。点击“启动连接”后，将引导你填写连接信息。"; AppendLog("未找到服务器配置。点击启动连接可添加服务器，也可选择已有 SSH 文件。"); }
                foreach (string warning in catalog.Warnings ?? new string[0]) AppendLog("配置提示：" + warning);
                _suppressSelection = false;
            }
            catch (Exception error) { _hosts.ItemsSource = null; ClearProfile(); _routeValue.Text = "读取未完成，仍可点击“添加服务器”手动配置。"; ReportError("读取服务器列表失败", error); }
            finally { _suppressSelection = false; _busy = false; UpdateAvailability(); }
            if (!_closed && _hosts.SelectedItem != null) await ResolveSelectedAsync();
        }

        private async Task BrowseConfigAsync()
        {
            if (_fixtureMode || _busy || HasActiveTunnel || HasVscodeAction) return;
            OpenFileDialog picker = new OpenFileDialog { Title = "选择 SSH 配置文件", Filter = "SSH 配置文件|config;*.conf;*.ssh|所有文件|*.*", CheckFileExists = true, Multiselect = false };
            if (File.Exists(_sshConfig)) { picker.InitialDirectory = Path.GetDirectoryName(_sshConfig); picker.FileName = Path.GetFileName(_sshConfig); }
            if (picker.ShowDialog(this) != true) return;
            _sshConfig = picker.FileName;
            await RefreshHostsAsync();
        }

        private async Task ResolveSelectedAsync()
        {
            if (_fixtureMode || _busy || HasActiveTunnel || HasVscodeAction) return;
            HostEntry selected = SelectedHost;
            ClearProfile(); if (selected == null) return;
            _busy = true; int generation = ++_resolveGeneration; UpdateAvailability();
            _routeValue.Text = "正在解析主机与跳板顺序…";
            _hosts.ToolTip = selected.ConfigPath ?? selected.SourceFile ?? selected.SourceLabel;
            try
            {
                ProfileInfo resolved = await _backend.ResolveEntryAsync(selected);
                if (_closed || _closing || generation != _resolveGeneration || SelectedHost != selected) return;
                if (resolved == null || String.IsNullOrWhiteSpace(resolved.Host)) throw new InvalidOperationException("配置未解析出目标主机地址。");
                _profile = resolved; ShowProfile(resolved);
                _source.Text = selected.Kind == "saved" ? "软件保存 · 独立服务器配置" : (selected.SourceLabel ?? "SSH 配置");
                _source.ToolTip = selected.Kind == "saved" ? _backend.ServersPath : (selected.ConfigPath ?? selected.SourceFile);
                if (!String.IsNullOrWhiteSpace(resolved.NativeAlias)) {
                    AppendLog("已读取服务器 " + selected.Alias + "，保留原 SSH 认证与跳板设置。");
                    AppendLog("SSH 客户端：" + resolved.NativeSshPath);
                    _source.ToolTip = (selected.ConfigPath ?? selected.SourceFile) + "\nSSH: " + resolved.NativeSshPath;
                } else { AppendLog("已解析服务器 " + selected.Alias + "，共 " + resolved.JumpCount.ToString(CultureInfo.InvariantCulture) + " 个跳板。"); }
                ApplyStatus(new TunnelStatus { Phase = "idle", Message = "服务器配置已读取。点击启动后，在 SSH 窗口中完成认证。" });
            }
            catch (Exception error) { ClearProfile(); ReportError("解析服务器失败", error); }
            finally { _busy = false; UpdateAvailability(); }
        }

        private async Task<bool> EditServerAsync(bool edit, string continuation = null)
        {
            if (_fixtureMode || _busy || HasActiveTunnel || HasVscodeAction || _backend == null) return false;
            HostEntry selected = SelectedHost;
            if (edit && (selected == null || selected.Kind != "saved")) return false;
            _busy = true; int generation = ++_resolveGeneration; UpdateAvailability();
            HostEntry saved = null;
            try
            {
                ProfileInfo existing = edit ? await _backend.ReadSavedServerAsync(selected.Id) : null;
                if (_closed || _closing || generation != _resolveGeneration) return false;
                TunnelBackend backend = _backend;
                ServerEditorWindow editor = new ServerEditorWindow(edit ? selected.Alias : "", existing == null ? null : existing.Json,
                    async delegate(string name, string json) { return await backend.SaveServerAsync(name, json, edit ? selected.Id : null); }, false, continuation);
                editor.Owner = this; editor.Icon = Icon;
                editor.ShowDialog(); saved = editor.SavedEntry;
            }
            catch (Exception error) { if (!_closing && !_closed) ReportError(edit ? "打开服务器配置失败" : "添加服务器未完成", error); }
            finally { _busy = false; UpdateAvailability(); }
            if (saved != null && !_closed && !_closing && generation == _resolveGeneration)
            {
                AppendLog("已保存服务器“" + saved.Alias + "”到软件自己的配置。");
                await RefreshHostsAsync(saved.Id);
                return CanContinueAfterSave(saved, SelectedHost, _profile);
            }
            return false;
        }

        private static bool CanContinueAfterSave(HostEntry saved, HostEntry selected, ProfileInfo profile)
        {
            return saved != null && selected != null && profile != null && !String.IsNullOrWhiteSpace(profile.Host) &&
                String.Equals(saved.Id, selected.Id, StringComparison.Ordinal);
        }

        private async Task<bool> EnsureServerAsync(string continuation)
        {
            if (_profile != null) return true;
            // An unresolved existing entry must keep its diagnostic; never replace it silently.
            if (_hosts.Items.Count != 0) return false;
            return await EditServerAsync(false, continuation);
        }

        private void ShowProfile(ProfileInfo profile)
        {
            _hostValue.Text = profile.Host ?? "—"; _hostValue.ToolTip = _hostValue.Text;
            _userValue.Text = String.IsNullOrWhiteSpace(profile.User) ? "默认用户" : profile.User; _userValue.ToolTip = _userValue.Text;
            _portValue.Text = profile.Port.ToString(CultureInfo.InvariantCulture);
            _routeValue.Text = String.IsNullOrWhiteSpace(profile.Route) ? "本机 → " + profile.Host : profile.Route;
            _routeValue.Foreground = Brush(TextHex); _routeValue.ToolTip = _routeValue.Text;
            if (!String.IsNullOrWhiteSpace(profile.Json))
            {
                Dictionary<string, object> json = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(profile.Json);
                object remote; int port;
                if (json.TryGetValue("remotePort", out remote) && TryReadRemotePort(Convert.ToString(remote, CultureInfo.InvariantCulture), out port)) _remotePort.Text = port.ToString(CultureInfo.InvariantCulture);
            }
            if (_vscodeNeedsReconfigure && !HasVscodeAction) ShowVscodeReconfigureHint();
        }

        private void ClearProfile()
        {
            _profile = null; _hostValue.Text = "—"; _userValue.Text = "—"; _portValue.Text = "—";
            _hostValue.ToolTip = null; _userValue.ToolTip = null;
            _routeValue.Text = "选择主机后显示解析结果"; _routeValue.Foreground = Brush(MutedHex); _routeValue.ToolTip = null;
            ResetVscodeSelectionStatus();
            UpdateAvailability();
        }

        private async Task CheckProxyAsync()
        {
            if (_fixtureMode || _checking) return;
            int local;
            if (!TryReadPort(_localPort.Text, true, out local)) { ShowPortError("本机代理端口需留空或填写 1–65535 的整数。"); return; }
            _checking = true; UpdateAvailability(); _proxyButton.Content = "正在检测…";
            _proxyIndicator.Background = Brush(OrangeHex); _proxyMessage.Text = "正在检测本机代理，请稍候…";
            try
            {
                ProxyInfo result = await _backend.CheckProxyAsync(local);
                if (_closed) return;
                ShowProxy(result);
                AppendLog("代理检测：" + result.Message);
            }
            catch (Exception error) { _proxyIndicator.Background = Brush(RedHex); _proxyMessage.Text = error.Message; _proxyUrl.Text = "检测未完成"; _proxyHttp.Text = "HTTP  —"; AppendLog("代理检测失败：" + error.Message); }
            finally { _checking = false; _proxyButton.Content = "检测代理"; UpdateAvailability(); }
        }

        private void ShowProxy(ProxyInfo result)
        {
            _proxyUrl.Text = String.IsNullOrWhiteSpace(result.Url) ? "未找到可用代理" : result.Url;
            _proxyUrl.Foreground = Brush(result.Success ? TextHex : MutedHex);
            _proxyHttp.Text = "HTTP  " + (result.StatusCode > 0 ? result.StatusCode.ToString(CultureInfo.InvariantCulture) : "—");
            _proxyMessage.Text = result.Message ?? "检测完成";
            _proxyIndicator.Background = Brush(result.Success ? SuccessHex : RedHex);
        }

        private async Task StartConnectionAsync()
        {
            if (_fixtureMode || _busy || _checking || HasActiveTunnel || HasVscodeAction) return;
            if (!await EnsureServerAsync("connect") || _closed || _closing || HasActiveTunnel || HasVscodeAction) return;
            int remote, local;
            if (!TryReadRemotePort(_remotePort.Text, out remote)) { ShowPortError("远端代理端口必须为 1024–65535 的整数。"); return; }
            if (!TryReadPort(_localPort.Text, true, out local)) { ShowPortError("本机代理端口需留空或填写 1–65535 的整数。"); return; }
            _starting = true; UpdateAvailability();
            _healthRoute.Text = "远端回环地址  127.0.0.1:" + remote.ToString(CultureInfo.InvariantCulture);
            _lastVerifiedLabel.Text = "尚无远端验证记录";
            _authTip.Text = "请在打开的 SSH 窗口中完成密码或密钥认证。";
            ApplyStatus(new TunnelStatus { Phase = "detecting", Message = "正在检查本机代理，随后将打开 SSH 认证窗口。" });
            try { _backend.Start(_profile, remote, local); }
            catch (Exception error) { ReportError("启动连接失败", error); }
            finally { _starting = false; UpdateAvailability(); }
        }

        private async Task ConfigureVscodeAsync()
        {
            if (_fixtureMode || _busy || HasVscodeAction || _backend == null || _starting || _stopping) return;
            if (!await EnsureServerAsync("vscode") || _closed || _closing || HasVscodeAction) return;
            int remote;
            if (!TryReadRemotePort(_remotePort.Text, out remote)) { ShowPortError("远端代理端口必须为 1024–65535 的整数。"); return; }
            _cancellingVscode = false; _configuringVscode = true; UpdateAvailability();
            SetVscodeMessage("正在配置远程 VS Code… 请在新打开的 SSH 窗口完成认证，可在此取消。", OrangeHex);
            AppendLog("正在为所选服务器配置 VS Code，代理端口 " + remote.ToString(CultureInfo.InvariantCulture) + "。可能需要再次完成 SSH 认证。");
            try
            {
                VscodeConfigResult result = await _backend.ConfigureVscodeAsync(_profile, remote);
                if (_closed || _closing) return;
                ShowVscodeResult(result, remote, HasActiveTunnel);
                AppendLog(_vscodeMessage.Text);
            }
            catch (OperationCanceledException error)
            {
                if (!_closed && !_closing)
                {
                    string message = String.IsNullOrWhiteSpace(error.Message) ? "远程 VS Code 配置已取消或超过 5 分钟。远程设置可能已写入，可再次配置检查结果。" : error.Message;
                    SetVscodeMessage(message, MutedHex); AppendLog(message);
                }
            }
            catch (Exception error)
            {
                if (!_closed && !_closing) { SetVscodeMessage("配置未完成：" + error.Message, RedHex); AppendLog("VS Code 配置未完成：" + error.Message); }
            }
            finally { _configuringVscode = false; _cancellingVscode = false; if (!_closed && !_closing) UpdateAvailability(); }
        }

        private void CancelVscodeConfiguration()
        {
            if (_fixtureMode || !HasVscodeAction || _backend == null || _cancellingVscode) return;
            _cancellingVscode = true;
            _backend.CancelVscodeConfiguration();
            _vscodeCancelButton.IsEnabled = false;
            SetVscodeMessage("正在取消配置并关闭本次配置的 SSH 窗口…", OrangeHex);
        }

        private void SetVscodeMessage(string text, string color)
        {
            _vscodeMessage.Text = text; _vscodeMessage.Foreground = Brush(color);
        }

        private void ResetVscodeSelectionStatus()
        {
            if (HasVscodeAction || _vscodeMessage == null) return;
            if (_vscodeConfiguredPort > 0) _vscodeNeedsReconfigure = true;
            _vscodeConfiguredPort = 0;
            if (_vscodeNeedsReconfigure) ShowVscodeReconfigureHint();
            else SetVscodeMessage("自动设置远程代理，保留其他设置。仅影响服务器上的 VS Code。", MutedHex);
        }

        private void UpdateVscodePortStatus()
        {
            if (HasVscodeAction || _vscodeMessage == null) return;
            int port;
            if (_vscodeConfiguredPort > 0 && (!TryReadRemotePort(_remotePort.Text, out port) || port != _vscodeConfiguredPort))
            {
                _vscodeConfiguredPort = 0; _vscodeNeedsReconfigure = true;
            }
            if (_vscodeNeedsReconfigure) ShowVscodeReconfigureHint();
        }

        private void ShowVscodeReconfigureHint()
        {
            int port;
            string hint = TryReadRemotePort(_remotePort.Text, out port)
                ? "连接信息已改变。请重新点击“一键配置 VS Code”，使用远端代理 127.0.0.1:" + port.ToString(CultureInfo.InvariantCulture) + "。"
                : "连接信息已改变。请填写有效的远端端口，再点击“一键配置 VS Code”。";
            SetVscodeMessage(hint, OrangeHex);
        }

        private void ShowVscodeResult(VscodeConfigResult result, int port, bool tunnelActive)
        {
            if (result == null) throw new InvalidOperationException("未收到远程配置结果。");
            _vscodeConfiguredPort = port; _vscodeNeedsReconfigure = false;
            string prefix = result.Changed ? "已配置远程 VS Code" : "远程 VS Code 已是所需配置";
            string message = prefix + " · 127.0.0.1:" + port.ToString(CultureInfo.InvariantCulture) + "。请在远程 VS Code 重新加载窗口，再安装并登录 Codex。";
            if (!tunnelActive) message += " 使用前请启动隧道。";
            SetVscodeMessage(message, SuccessHex);
        }

        private async Task StopConnectionAsync()
        {
            if (_fixtureMode || !HasActiveTunnel || _backend == null || _stopping) return;
            _stopping = true; UpdateAvailability(); _stopButton.Content = "停止中…";
            try { TunnelBackend backend = _backend; await Task.Run(delegate { backend.Stop(); }); }
            catch (Exception error) { if (!_closed) ReportError("停止连接未完成", error); }
            finally { _stopping = false; if (!_closed) { _stopButton.Content = "停止"; UpdateAvailability(); } }
        }

        private void ShowPortError(string message)
        {
            _advanced.IsExpanded = true;
            AppendLog(message);
            MessageBox.Show(this, message, "检查端口设置", MessageBoxButton.OK, MessageBoxImage.Information);
        }

        private static bool TryReadPort(string value, bool allowAuto, out int port)
        {
            port = 0;
            if (allowAuto && (String.IsNullOrWhiteSpace(value) || String.Equals(value.Trim(), "auto", StringComparison.OrdinalIgnoreCase))) return true;
            return Int32.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out port) && port > 0 && port <= 65535;
        }

        private static bool TryReadRemotePort(string value, out int port)
        {
            return TryReadPort(value, false, out port) && port >= 1024;
        }

        private bool HasActiveTunnel { get { return _starting || _stopping || (_backend != null && _backend.IsRunning); } }
        private bool HasVscodeAction { get { return _configuringVscode || (_backend != null && _backend.IsConfiguringVscode); } }

        private void UpdateAvailability() { if (!_closed && !_closing) SetAvailability(HasActiveTunnel); }

        private void SetAvailability(bool active)
        {
            bool configuring = HasVscodeAction;
            bool canChoose = !active && !_busy && !configuring;
            bool hasServerOrEmpty = _profile != null || _hosts.Items.Count == 0;
            _hosts.IsEnabled = canChoose;
            _refreshButton.IsEnabled = canChoose;
            _browseButton.IsEnabled = canChoose;
            _autoButton.IsEnabled = canChoose;
            _addButton.IsEnabled = canChoose;
            _editButton.Visibility = SelectedHost != null && SelectedHost.Kind == "saved" ? Visibility.Visible : Visibility.Collapsed;
            _editButton.IsEnabled = canChoose && SelectedHost != null && SelectedHost.Kind == "saved";
            _remotePort.IsEnabled = !active && !configuring;
            _localPort.IsEnabled = !active && !_checking && !configuring;
            _startButton.IsEnabled = canChoose && !_checking && hasServerOrEmpty;
            _stopButton.IsEnabled = active && !_stopping;
            _proxyButton.IsEnabled = !_checking && !active && !configuring;
            _vscodeButton.IsEnabled = !_busy && !configuring && !_starting && !_stopping && hasServerOrEmpty;
            _vscodeButton.Content = configuring ? "正在配置 VS Code…" : "一键配置 VS Code";
            _vscodeCancelButton.Visibility = configuring ? Visibility.Visible : Visibility.Collapsed;
            _vscodeCancelButton.IsEnabled = configuring && !_cancellingVscode;
            _refreshButton.Content = _busy ? "读取中…" : "刷新";
        }

        private static string NormalizePhase(string phase)
        {
            string p = (phase ?? "idle").Trim().ToLowerInvariant();
            if (p == "ready" || p == "degraded" || p == "unverified" || p == "error" || p == "stopped" || p == "detecting" || p == "connecting") return p;
            if (p == "starting" || p == "authenticating") return "connecting";
            if (p == "checking") return "detecting";
            return "idle";
        }

        private static string PhaseColor(string phase)
        {
            if (phase == "ready") return SuccessHex;
            if (phase == "error") return RedHex;
            if (phase == "detecting" || phase == "connecting" || phase == "degraded" || phase == "unverified") return OrangeHex;
            return MutedHex;
        }

        private void ApplyStatus(TunnelStatus status)
        {
            if (_closed || _closing || status == null) return;
            if (status.Sequence > 0)
            {
                if (status.Sequence <= _lastStatusSequence) return;
                _lastStatusSequence = status.Sequence;
            }
            if (String.Equals(status.Phase, "bind-warning", StringComparison.OrdinalIgnoreCase))
            {
                AppendLog("绑定提示：" + status.Message);
                return;
            }
            if (!String.IsNullOrWhiteSpace(status.ProxyUrl))
            {
                _proxyUrl.Text = status.ProxyUrl; _proxyUrl.Foreground = Brush(TextHex);
                _proxyHttp.Text = "HTTP  " + (status.ProxyHttpStatus > 0 ? status.ProxyHttpStatus.ToString(CultureInfo.InvariantCulture) : "—");
                _proxyMessage.Text = "本机代理链路已验证；远端状态单独显示。";
                _proxyIndicator.Background = Brush(SuccessHex);
            }
            if (String.Equals(status.Phase, "proxy-ready", StringComparison.OrdinalIgnoreCase)) return;
            _phase = NormalizePhase(status.Phase);
            string name, pill;
            switch (_phase)
            {
                case "detecting": name = "检测代理中"; pill = "正在检测"; break;
                case "connecting": name = "正在建立连接"; pill = "正在连接"; break;
                case "ready": name = "远端代理已就绪"; pill = "已就绪"; break;
                case "degraded": name = "连接需要检查"; pill = "连接异常"; break;
                case "unverified": name = "远端状态未验证"; pill = "尚未验证"; break;
                case "error": name = "连接未完成"; pill = "连接失败"; break;
                case "stopped": name = "连接已停止"; pill = "已停止"; break;
                default: name = "等待连接"; pill = "未连接"; break;
            }
            string color = PhaseColor(_phase);
            _healthTitle.Text = name; _healthTitle.Foreground = Brush(color);
            _healthIndicator.Background = Brush(color); _pillText.Text = "●  " + pill; _pillText.Foreground = Brush(color);
            _healthMessage.Text = String.IsNullOrWhiteSpace(status.Message) ? "等待新的连接状态。" : status.Message;
            if (_phase == "ready") _lastVerifiedLabel.Text = "最近远端验证  " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
        }

        internal void ReportError(string context, Exception error)
        {
            if (_closed || _closing) return;
            AppendLog(context + "：" + error.Message);
            ApplyStatus(new TunnelStatus { Phase = "error", Message = context + "。" + error.Message });
        }

        private void OnUi(Action action)
        {
            if (_closed || _closing || Dispatcher.HasShutdownStarted) return;
            try { Dispatcher.BeginInvoke(new Action(delegate { if (!_closed && !_closing) action(); })); } catch (InvalidOperationException) { }
        }

        private void AppendLog(string message)
        {
            if (_closed || String.IsNullOrWhiteSpace(message)) return;
            // Keep a bounded local display, and do not persist it or inspect SSH password input.
            if (_logs.Text.Length > 180000) { _logs.Text = _logs.Text.Substring(_logs.Text.Length - 120000); }
            _logs.AppendText("[" + DateTime.Now.ToString("HH:mm:ss", CultureInfo.InvariantCulture) + "] " + message.TrimEnd() + Environment.NewLine);
            _logs.ScrollToEnd();
        }

        private void CopyLogs()
        {
            try { if (!String.IsNullOrWhiteSpace(_logs.Text)) Clipboard.SetText(_logs.Text); }
            catch (Exception error) { AppendLog("复制未完成：" + error.Message); }
        }

        internal static string RemoteSettingsJson(int port)
        {
            return "{\r\n  \"http.useLocalProxyConfiguration\": false,\r\n  \"http.proxy\": \"http://127.0.0.1:" + port.ToString(CultureInfo.InvariantCulture) + "\"\r\n}";
        }

        private void ShowHelp()
        {
            int port; if (!TryReadRemotePort(_remotePort.Text, out port)) port = 11082;
            string settings = RemoteSettingsJson(port);
            string help = "一、先启动隧道\n\n" +
                "打开本机代理软件，在本软件选择服务器并点击“启动连接”。已有 SSH 配置会自动读取；无配置时会打开填写向导。保存后继续连接。在弹出的 SSH 窗口完成认证，等待“远端代理已就绪”。\n\n" +
                "二、一键配置远程 VS Code\n\n" +
                "1. 本机安装微软 Remote - SSH 扩展，连接同一台服务器。已有连接可直接使用。\n\n" +
                "2. 回到本软件，点击“一键配置 VS Code”，在新开的 SSH 窗口完成认证。软件会备份并更新服务器上的代理设置，保留其他设置。可用“取消配置”中止等待。\n\n" +
                "3. 显示已配置后，回到远程 VS Code，按 Ctrl+Shift+P，运行 Developer: Reload Window（开发人员：重新加载窗口）。\n\n" +
                "4. 扩展面板搜索 @id:openai.chatgpt，确认发布者 OpenAI，点击安装到 SSH: 当前服务器。打开 Codex 侧栏登录。\n\n" +
                "代理使用远端端口 " + port.ToString(CultureInfo.InvariantCulture) + "。使用期间保持隧道连接；配置完成不等于 Codex 已登录。\n\n" +
                "若扩展市场下载失败：在本机下载匹配服务器 Linux 架构的 VSIX，在远程窗口运行 Extensions: Install from VSIX...。不要复制 Windows 平台扩展文件夹。\n\n" +
                "若浏览器登录卡在 localhost:1455：在 VS Code“端口”面板转发远端 1455，确认本地映射也为 1455 后重试。\n\n" +
                "HTTP 401 仅证明网络已到达服务。地址为空时查看连接日志中的具体解析原因；代理检测失败是独立问题。\n\n" +
                "手动备用方式：在远程窗口运行 Preferences: Open Remote Settings (JSON)，将下面两项合并到现有最外层，保留其他设置。\n\n" + settings;
            Window dialog = new Window { Title = "VS Code 设置指南 · Codex Tunnel", Owner = this, Width = 710, Height = 700, MinWidth = 560, MinHeight = 460, WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Brush(BackgroundHex), Foreground = Brush(TextHex), FontFamily = FontFamily, FontSize = 13 };
            dialog.Icon = Icon;
            Grid layout = new Grid { Margin = new Thickness(24) }; layout.RowDefinitions.Add(new RowDefinition()); layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            TextBox text = new TextBox { Text = help, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Background = Brush(BackgroundHex), Foreground = Brush(TextHex), BorderThickness = new Thickness(0), Padding = new Thickness(0, 0, 12, 0), FontSize = 13 };
            Place(layout, text, 0, 0);
            StackPanel actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 15, 0, 0) };
            Button copy = Button("复制远程设置 JSON", true, delegate { });
            copy.Click += delegate { try { Clipboard.SetText(settings); copy.Content = "已复制"; } catch (Exception error) { AppendLog("复制未完成：" + error.Message); } };
            copy.Margin = new Thickness(0, 0, 10, 0); actions.Children.Add(copy);
            actions.Children.Add(Button("知道了", false, delegate { dialog.Close(); })); Place(layout, actions, 1, 0); dialog.Content = layout; dialog.ShowDialog();
        }

        internal void LoadPreviewFixture()
        {
            if (!_fixtureMode) throw new InvalidOperationException("Preview fixtures are isolated from live connection mode.");
            _source.Text = "自动读取 · 2 个 SSH 主机与 1 个软件配置";
            _hosts.ItemsSource = Choices(new HostEntry[] { new HostEntry { Id = "fixture-ssh-1", Kind = "ssh", Alias = "research-workspace", SourceFile = "C:\\Users\\demo\\.ssh\\config", ConfigPath = "C:\\Users\\demo\\.ssh\\config", SourceLabel = "本机 SSH" }, new HostEntry { Id = "fixture-saved-2", Kind = "saved", Alias = "实验室服务器", SourceLabel = "软件保存" }, new HostEntry { Id = "fixture-ssh-3", Kind = "ssh", Alias = "staging-server", SourceFile = "C:\\Users\\demo\\connections\\config", ConfigPath = "C:\\Users\\demo\\connections\\config", SourceLabel = "VS Code" } });
            _hosts.SelectedIndex = 0;
            _profile = new ProfileInfo { Host = "gpu.example.net", User = "researcher", Port = 22, Route = "本机 → gateway → research-workspace", JumpCount = 1 };
            ShowProfile(_profile);
            ShowProxy(new ProxyInfo { Success = true, Url = "http://127.0.0.1:1082", StatusCode = 401, Message = "代理链路可达；HTTP 401 表示服务要求认证。" });
            ApplyStatus(new TunnelStatus { Phase = "idle", Message = "服务器配置已解析。点击启动后，在 SSH 窗口中完成认证。" });
            _lastVerifiedLabel.Text = "尚无远端验证记录";
            _logs.Text = "[14:32:08] 已载入 3 个服务器，包含本机 SSH 配置与软件保存的服务器。\r\n[14:32:09] 已解析 research-workspace，跳板顺序已保留。\r\n[14:32:12] 本机代理链路可达，等待启动连接。\r\n";
            SetAvailability(false);
        }

        internal void SetPreviewState(string state)
        {
            if (!_fixtureMode) throw new InvalidOperationException("Preview states are available only in isolated fixture mode.");
            _previewState = (state ?? "default").ToLowerInvariant();
            if (_previewState == "default" || _previewState == "dropdown") return;
            if (_previewState == "advanced") { _advanced.IsExpanded = true; return; }
            if (_previewState == "connected")
            {
                ApplyStatus(new TunnelStatus { Phase = "ready", Message = "远端代理链路验证通过，隧道正在运行。" });
                SetAvailability(true); return;
            }
            if (_previewState == "vscode-config")
            {
                ApplyStatus(new TunnelStatus { Phase = "ready", Message = "远端代理链路验证通过，隧道正在运行。" });
                ShowVscodeResult(new VscodeConfigResult { Changed = true, Targets = 1 }, 11082, true);
                _logs.AppendText("[14:33:10] 远程 VS Code 代理已配置，原文件已备份。请重新加载远程窗口。\r\n");
                SetAvailability(true); return;
            }
            if (_previewState == "vscode-configuring")
            {
                ApplyStatus(new TunnelStatus { Phase = "ready", Message = "远端代理链路验证通过，隧道正在运行。" });
                _configuringVscode = true;
                SetVscodeMessage("正在配置远程 VS Code… 请在新打开的 SSH 窗口完成认证，可在此取消。", OrangeHex);
                SetAvailability(true); return;
            }
            if (_previewState == "buttons") { Content = BuildButtonPreview(); return; }
            if (_previewState == "empty")
            {
                _hosts.ItemsSource = Choices(new HostEntry[0]); ClearProfile(); _source.Text = "未发现本机 SSH 配置";
                _routeValue.Text = "还没有服务器。点击“启动连接”后，将引导你填写连接信息。";
                _proxyUrl.Text = "尚未检测"; _proxyHttp.Text = "HTTP  —"; _proxyMessage.Text = "检测本机 HTTP 代理的可达性。"; _proxyIndicator.Background = Brush(MutedHex);
                ApplyStatus(new TunnelStatus { Phase = "idle", Message = "点击启动连接，添加服务器后即可继续。" });
                _logs.Text = "[14:32:08] 未找到本机 SSH 配置。可直接添加服务器，配置只保存在软件中。\r\n";
                SetAvailability(false); return;
            }
            if (_previewState == "add-server" || _previewState == "add-jumps" || _previewState == "onboarding")
            {
                ServerEditorWindow editor = ServerEditorWindow.Preview(_previewState == "add-jumps", _previewState == "onboarding");
                Width = editor.Width; Height = editor.Height; Content = editor.TakePreviewContent(); editor.Close(); return;
            }
            throw new ArgumentException("Unknown preview state. Use default, advanced, connected, dropdown, buttons, empty, add-server, add-jumps, onboarding, vscode-config or vscode-configuring.");
        }

        private FrameworkElement BuildButtonPreview()
        {
            Grid sheet = new Grid { Margin = new Thickness(40), Background = Brush(BackgroundHex) };
            sheet.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            sheet.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            sheet.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            TextBlock heading = Text("按钮与交互状态", 25, TextHex); heading.FontWeight = FontWeights.SemiBold; heading.Margin = new Thickness(0, 0, 0, 12); Place(sheet, heading, 0, 0);
            TextBlock note = Text("使用应用中的实际 WPF 控件模板。悬停、按下和焦点为隔离预览中的输入状态。", 12, MutedHex); note.Margin = new Thickness(0, 0, 0, 26); Place(sheet, note, 1, 0);
            Grid samples = new Grid();
            samples.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(116) });
            samples.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(190) });
            samples.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(160) });
            samples.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(180) });
            string[] states = { "normal", "hover", "pressed", "focus", "disabled", "busy" };
            string[] labels = { "默认", "悬停", "按下", "键盘焦点", "不可用", "进行中" };
            for (int i = 0; i < states.Length; i++)
            {
                samples.RowDefinitions.Add(new RowDefinition { Height = new GridLength(67) });
                TextBlock label = Text(labels[i], 13, MutedHex); label.VerticalAlignment = VerticalAlignment.Center; Place(samples, label, i, 0);
                Button primary = IconButton(states[i] == "busy" ? "连接中…" : "启动连接", PlayIcon, "primary", null); primary.Width = 152; primary.Height = 42;
                Button outline = IconButton(states[i] == "busy" ? "停止中…" : "停止", StopIcon, "outline", null); outline.Width = 104; outline.Height = 42;
                Button ghost = IconButton(states[i] == "busy" ? "读取中…" : "刷新列表", RefreshIcon, "ghost", null); ghost.Height = 38;
                foreach (Button button in new Button[] { primary, outline, ghost })
                {
                    button.HorizontalAlignment = HorizontalAlignment.Left;
                    button.ApplyTemplate(); SetPreviewButtonState(button, states[i]);
                }
                Place(samples, primary, i, 1); Place(samples, outline, i, 2); Place(samples, ghost, i, 3);
            }
            Place(sheet, Card(samples), 2, 0); return sheet;
        }

        private static void SetPreviewButtonState(Button button, string state)
        {
            if (state == "disabled" || state == "busy") { button.IsEnabled = false; return; }
            Type owner = state == "pressed" ? typeof(ButtonBase) : typeof(UIElement);
            string name = state == "hover" ? "IsMouseOverPropertyKey" : state == "pressed" ? "IsPressedPropertyKey" : state == "focus" ? "IsKeyboardFocusedPropertyKey" : null;
            if (name == null) return;
            FieldInfo field = owner.GetField(name, BindingFlags.Static | BindingFlags.NonPublic);
            if (field == null) throw new InvalidOperationException("The WPF preview input flag is unavailable: " + name);
            button.SetValue((DependencyPropertyKey)field.GetValue(null), true);
        }

        internal void RenderPreview(string path)
        {
            if (!_fixtureMode) throw new InvalidOperationException("Preview requires fixture mode.");
            // Render the actual WPF content tree without opening windows, reading user config or networking.
            FrameworkElement content = (FrameworkElement)Content;
            int width = (int)Width, height = (int)Height - 40;
            Grid canvas = new Grid { Width = width, Height = height, Background = Brush(BackgroundHex) };
            canvas.Resources = Resources;
            Content = null; canvas.Children.Add(content);
            canvas.Measure(new Size(width, height)); canvas.Arrange(new Rect(0, 0, width, height)); canvas.UpdateLayout();
            // A Popup normally renders in a separate native window. For this offline preview only,
            // attach its actual styled child to the capture canvas, preserving the real item templates.
            Popup popup = null; UIElement popupChild = null;
            if (_previewState == "dropdown")
            {
                _hosts.ApplyTemplate();
                popup = (Popup)_hosts.Template.FindName("PART_Popup", _hosts);
                popupChild = popup.Child; popup.Child = null;
                FrameworkElement popupElement = (FrameworkElement)popupChild;
                popupElement.Width = _hosts.ActualWidth;
                popupElement.HorizontalAlignment = HorizontalAlignment.Left; popupElement.VerticalAlignment = VerticalAlignment.Top;
                Point origin = _hosts.TranslatePoint(new Point(0, _hosts.ActualHeight), canvas);
                popupElement.Margin = new Thickness(origin.X, origin.Y + 4, 0, 0);
                canvas.Children.Add(popupElement); canvas.UpdateLayout();
            }
            RenderTargetBitmap bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(canvas);
            PngBitmapEncoder encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path)));
            using (FileStream stream = File.Create(path)) { encoder.Save(stream); }
            if (popupChild != null) { canvas.Children.Remove(popupChild); popup.Child = popupChild; }
            canvas.Children.Remove(content); Content = content;
        }

        internal Dictionary<string, object> RunSelfTest()
        {
            if (!_fixtureMode) throw new InvalidOperationException("Self-test requires fixture mode.");
            List<Dictionary<string, object>> checks = new List<Dictionary<string, object>>();
            Record(checks, "packaged_application_icon", Icon is BitmapSource && ((BitmapSource)Icon).PixelWidth >= 32 && Icon.IsFrozen);
            Record(checks, "initial_empty_start_opens_onboarding", _startButton.IsEnabled && _hosts.Items.Count == 0 && _profile == null);
            Record(checks, "initial_stop_disabled", !_stopButton.IsEnabled);
            Record(checks, "empty_catalog_allows_add", _addButton.IsEnabled && _editButton.Visibility == Visibility.Collapsed);
            Record(checks, "empty_catalog_allows_vscode_onboarding", _vscodeButton.IsEnabled && _vscodeCancelButton.Visibility == Visibility.Collapsed);
            Record(checks, "initial_is_neutral", _phase == "idle" && PhaseColor(_phase) == MutedHex && _pillText.Text.Contains("未连接"));
            Record(checks, "initial_no_success_claim", !_healthTitle.Text.Contains("就绪") && _proxyUrl.Text == "尚未检测");
            int port; Record(checks, "remote_port_validation", TryReadRemotePort("11082", out port) && port == 11082 && !TryReadRemotePort("0", out port) && !TryReadRemotePort("65536", out port));
            Record(checks, "remote_port_rejects_privileged", !TryReadRemotePort("1023", out port) && TryReadRemotePort("1024", out port));
            Record(checks, "local_auto_port", TryReadPort("", true, out port) && port == 0 && TryReadPort("Auto", true, out port) && port == 0);
            Record(checks, "port_rejects_shell_text", !TryReadPort("22;whoami", false, out port));
            foreach (string phase in new string[] { "detecting", "connecting", "ready", "degraded", "unverified", "error", "stopped" })
            {
                ApplyStatus(new TunnelStatus { Phase = phase, Message = "fixture " + phase });
                Record(checks, "status_" + phase, _phase == phase && _healthMessage.Text == "fixture " + phase && (phase == "ready" ? PhaseColor(_phase) == SuccessHex : PhaseColor(_phase) != SuccessHex));
            }
            ApplyStatus(new TunnelStatus { Phase = "unexpected", Message = "unknown state" }); Record(checks, "unknown_status_never_green", _phase == "idle" && PhaseColor(_phase) == MutedHex);
            ApplyStatus(new TunnelStatus { Phase = "ready", Message = "newer ready", Sequence = 101 });
            string lastVerified = _lastVerifiedLabel.Text;
            ApplyStatus(new TunnelStatus { Phase = "connecting", Message = "older connecting", Sequence = 100 });
            Record(checks, "ignores_stale_sequence", _phase == "ready" && _healthMessage.Text == "newer ready");
            ApplyStatus(new TunnelStatus { Phase = "bind-warning", Message = "bind fixture", Sequence = 102 });
            Record(checks, "bind_warning_preserves_health", _phase == "ready" && _healthMessage.Text == "newer ready");
            ApplyStatus(new TunnelStatus { Phase = "degraded", Message = "remote failed", Sequence = 103, ProxyUrl = "http://127.0.0.1:1082", ProxyHttpStatus = 401, HttpStatus = 403 });
            Record(checks, "local_http_separate_from_remote", _proxyHttp.Text == "HTTP  401" && _phase == "degraded");
            Record(checks, "last_verified_timestamp_preserved", lastVerified.StartsWith("最近远端验证", StringComparison.Ordinal) && _lastVerifiedLabel.Text == lastVerified);
            LoadPreviewFixture(); Record(checks, "resolved_enables_start", _startButton.IsEnabled && !_stopButton.IsEnabled);
            ProfileInfo fixtureProfile = _profile;
            _profile = null; SetAvailability(false); Record(checks, "unresolved_existing_entry_cannot_start_or_configure", !_startButton.IsEnabled && !_vscodeButton.IsEnabled); _profile = fixtureProfile; SetAvailability(false);
            HostEntry savedFixture = new HostEntry { Id = "saved-fixture" };
            Record(checks, "onboarding_cancel_never_continues", !CanContinueAfterSave(null, savedFixture, fixtureProfile));
            Record(checks, "onboarding_requires_saved_selection_and_resolve", !CanContinueAfterSave(savedFixture, new HostEntry { Id = "other" }, fixtureProfile) && !CanContinueAfterSave(savedFixture, savedFixture, null) && CanContinueAfterSave(savedFixture, savedFixture, fixtureProfile));
            _checking = true; SetAvailability(false); Record(checks, "proxy_check_locks_start_and_port", !_startButton.IsEnabled && !_localPort.IsEnabled && !_proxyButton.IsEnabled); _checking = false; SetAvailability(false);
            Record(checks, "ordered_route_is_visible", _routeValue.Text == "本机 → gateway → research-workspace");
            SetAvailability(true); Record(checks, "active_locks_configuration", !_hosts.IsEnabled && !_refreshButton.IsEnabled && !_browseButton.IsEnabled && !_remotePort.IsEnabled && !_localPort.IsEnabled && !_startButton.IsEnabled && !_addButton.IsEnabled && !_editButton.IsEnabled && !_autoButton.IsEnabled && _stopButton.IsEnabled);
            Record(checks, "active_tunnel_allows_vscode_configuration", _vscodeButton.IsEnabled);
            _configuringVscode = true; SetAvailability(true); Record(checks, "vscode_setup_keeps_tunnel_stop_available", _stopButton.IsEnabled && !_vscodeButton.IsEnabled && _vscodeCancelButton.IsEnabled && _vscodeCancelButton.Visibility == Visibility.Visible && !_hosts.IsEnabled && !_remotePort.IsEnabled);
            SetAvailability(false); Record(checks, "vscode_setup_without_tunnel_locks_start", !_startButton.IsEnabled && !_addButton.IsEnabled && !_localPort.IsEnabled && !_proxyButton.IsEnabled);
            _configuringVscode = false; SetAvailability(false);
            string previousPhase = _phase, previousHealth = _healthMessage.Text;
            _remotePort.Text = "12082";
            ShowVscodeResult(new VscodeConfigResult { Changed = true, Targets = 1 }, 12082, false);
            Record(checks, "vscode_result_uses_port_and_reload_without_login_claim", _vscodeMessage.Text.Contains("127.0.0.1:12082") && _vscodeMessage.Text.Contains("重新加载窗口") && _vscodeMessage.Text.Contains("安装并登录") && _vscodeMessage.Text.Contains("启动隧道") && !_vscodeMessage.Text.Contains("已登录"));
            Record(checks, "vscode_result_does_not_clobber_tunnel_health", _phase == previousPhase && _healthMessage.Text == previousHealth);
            _remotePort.Text = "13082";
            Record(checks, "vscode_port_change_invalidates_success_and_names_new_port", _vscodeConfiguredPort == 0 && _vscodeNeedsReconfigure && _vscodeMessage.Text.Contains("127.0.0.1:13082") && _vscodeMessage.Text.Contains("重新点击") && ((SolidColorBrush)_vscodeMessage.Foreground).Color == Brush(OrangeHex).Color);
            _remotePort.Text = "invalid";
            Record(checks, "vscode_invalid_port_removes_stale_success", _vscodeMessage.Text.Contains("有效的远端端口") && !_vscodeMessage.Text.Contains("invalid") && _vscodeConfiguredPort == 0);
            _remotePort.Text = "12082";
            ShowVscodeResult(new VscodeConfigResult { Changed = false, Targets = 1 }, 12082, false);
            _hosts.SelectedIndex = 1;
            ShowProfile(new ProfileInfo { Host = "second.example.net", User = "second", Port = 22, Json = "{\"remotePort\":14082}" });
            Record(checks, "vscode_server_selection_invalidates_success_and_uses_selected_port", _vscodeConfiguredPort == 0 && _vscodeNeedsReconfigure && _vscodeMessage.Text.Contains("127.0.0.1:14082") && _vscodeMessage.Text.Contains("重新点击") && ((SolidColorBrush)_vscodeMessage.Foreground).Color == Brush(OrangeHex).Color);
            _hosts.SelectedIndex = 0; ShowProfile(fixtureProfile);
            _stopping = true; UpdateAvailability(); Record(checks, "stopping_locks_restart", !_startButton.IsEnabled && !_stopButton.IsEnabled && !_hosts.IsEnabled); _stopping = false;
            SetAvailability(false); Record(checks, "stopped_unlocks_configuration", _hosts.IsEnabled && _refreshButton.IsEnabled && _browseButton.IsEnabled && _remotePort.IsEnabled && _startButton.IsEnabled && !_stopButton.IsEnabled);
            bool iconsRemain = true;
            foreach (Button button in new Button[] { _proxyButton, _stopButton, _refreshButton })
            {
                object caption = button.Content; button.Content = "进行中…"; button.ApplyTemplate();
                System.Windows.Shapes.Path icon = button.Template.FindName("icon", button) as System.Windows.Shapes.Path;
                iconsRemain &= icon != null && icon.Data != null && icon.Data == button.Tag;
                button.Content = caption;
            }
            Record(checks, "busy_captions_preserve_vector_icons", iconsRemain);
            HostEntry[] duplicatedAliases = new HostEntry[] { new HostEntry { Id = "source-a", Alias = "gpu", Kind = "ssh" }, new HostEntry { Id = "saved-b", Alias = "gpu", Kind = "saved" } };
            Record(checks, "catalog_selects_by_id_not_alias", PreferredIndex(duplicatedAliases, "saved-b") == 1 && PreferredIndex(duplicatedAliases, "source-a") == 0);
            HostChoice sourceFixture = new HostChoice { Entry = new HostEntry { Kind = "ssh", Alias = "gpu", SourceLabel = "VS Code", ConfigPath = "C:\\fixture\\config" } };
            Record(checks, "catalog_source_badge_and_path_distinguishable", sourceFixture.Source == "VS Code" && sourceFixture.SourcePath == "C:\\fixture\\config");
            _hosts.ItemsSource = Choices(duplicatedAliases); _hosts.SelectedIndex = 1; SetAvailability(false);
            Record(checks, "saved_entry_edit_enabled", _editButton.Visibility == Visibility.Visible && _editButton.IsEnabled);
            _hosts.SelectedIndex = 0; SetAvailability(false); Record(checks, "ssh_entry_edit_hidden", _editButton.Visibility == Visibility.Collapsed);
            ShowProfile(new ProfileInfo { Host = "fixture.example.net", User = "fixture", Port = 22, Json = "{\"remotePort\":12082}" });
            Record(checks, "selected_saved_profile_port_loaded", _remotePort.Text == "12082");
            Dictionary<string, object> remoteSettings = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(RemoteSettingsJson(12082));
            Record(checks, "vscode_guide_uses_selected_remote_port", remoteSettings.Count == 2 && Convert.ToString(remoteSettings["http.proxy"]) == "http://127.0.0.1:12082" && !(bool)remoteSettings["http.useLocalProxyConfiguration"]);
            ServerEditorWindow.RunSelfTests(checks);
            Record(checks, "fixture_has_no_backend", _backend == null);
            bool passed = true; foreach (Dictionary<string, object> item in checks) if (!(bool)item["passed"]) passed = false;
            return new Dictionary<string, object> { { "application", "Codex Tunnel" }, { "version", Program.Version }, { "passed", passed }, { "checks", checks }, { "networkUsed", false }, { "userConfigRead", false }, { "note", "Control-state self-test only; preview rendering and live SSH authentication are separate checks." } };
        }

        private static void Record(List<Dictionary<string, object>> checks, string name, bool passed)
        {
            checks.Add(new Dictionary<string, object> { { "name", name }, { "passed", passed } });
        }
    }
}
