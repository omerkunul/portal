using System.Buffers.Text;
using System.Buffers.Binary;
using System.Diagnostics;
using System.Drawing.Imaging;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Threading;
using System.Text;
using System.Text.Json;
using System.Globalization;

namespace PortalWindows;

internal static class PortalTheme
{
    public static readonly Color Window = Color.FromArgb(18, 19, 23);
    public static readonly Color Panel = Color.FromArgb(30, 31, 36);
    public static readonly Color PanelAlt = Color.FromArgb(24, 25, 30);
    public static readonly Color PanelHigh = Color.FromArgb(41, 42, 48);
    public static readonly Color Border = Color.FromArgb(65, 71, 85);
    public static readonly Color Grid = Color.FromArgb(48, 53, 64);
    public static readonly Color Text = Color.FromArgb(227, 226, 231);
    public static readonly Color Muted = Color.FromArgb(193, 198, 215);
    public static readonly Color Accent = Color.FromArgb(0, 122, 255);
    public static readonly Color Success = Color.FromArgb(50, 215, 75);
    public static readonly Color Danger = Color.FromArgb(255, 69, 58);
    public static readonly Color Mac = Color.FromArgb(38, 166, 91);
    public static readonly Color Windows = Color.FromArgb(204, 118, 38);
    public static readonly Color WindowsSecondary = Color.FromArgb(180, 67, 199);
}

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        using var singleInstance = new SingleInstanceGate();
        if (!singleInstance.IsPrimaryInstance)
        {
            singleInstance.SignalPrimaryInstance();
            return;
        }

        try { Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.High; } catch { }
        ApplicationConfiguration.Initialize();
        using var form = new MainForm();
        singleInstance.Attach(form);
        Application.Run(form);
    }
}

internal sealed class SingleInstanceGate : IDisposable
{
    private const string MutexName = @"Local\PortalWindows.Instance";
    private const string ActivateEventName = @"Local\PortalWindows.Activate";

    private readonly Mutex _mutex;
    private readonly EventWaitHandle? _activateEvent;
    private RegisteredWaitHandle? _activationWait;
    private volatile bool _pendingActivation;

    public bool IsPrimaryInstance { get; }

    public SingleInstanceGate()
    {
        _mutex = new Mutex(initiallyOwned: true, name: MutexName, createdNew: out var createdNew);
        IsPrimaryInstance = createdNew;
        if (IsPrimaryInstance)
        {
            _activateEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ActivateEventName);
        }
    }

    public void Attach(MainForm form)
    {
        if (!IsPrimaryInstance || _activateEvent == null) return;

        form.HandleCreated += (_, _) =>
        {
            if (_pendingActivation)
            {
                _pendingActivation = false;
                form.HandleActivationSignal();
            }
        };

        _activationWait = ThreadPool.RegisterWaitForSingleObject(
            _activateEvent,
            (_, _) =>
            {
                try
                {
                    if (form.IsDisposed) return;
                    if (form.IsHandleCreated)
                    {
                        form.BeginInvoke((MethodInvoker)form.HandleActivationSignal);
                    }
                    else
                    {
                        _pendingActivation = true;
                    }
                }
                catch { }
            },
            null,
            Timeout.Infinite,
            executeOnlyOnce: false
        );
    }

    public void SignalPrimaryInstance()
    {
        if (IsPrimaryInstance) return;
        try
        {
            using var activateEvent = EventWaitHandle.OpenExisting(ActivateEventName);
            activateEvent.Set();
        }
        catch { }
    }

    public void Dispose()
    {
        _activationWait?.Unregister(null);
        _activateEvent?.Dispose();
        if (IsPrimaryInstance)
        {
            try { _mutex.ReleaseMutex(); } catch { }
        }
        _mutex.Dispose();
    }
}

public sealed class MainForm : Form
{
    private static readonly string InputLogPath = Path.Combine(Path.GetTempPath(), "portal-windows-input.log");
    private const int DiscoveryPort = 45878;
    private readonly Panel _contentHost = new() { Dock = DockStyle.Fill };
    private readonly Panel _controlTab = new() { Dock = DockStyle.Fill };
    private readonly Label _pageTitle = new() { AutoSize = true, Text = "Control" };
    private readonly TextBox _ipBox = new() { Text = "", Width = 180, ReadOnly = true };
    private readonly NumericUpDown _portBox = new() { Minimum = 1, Maximum = 65535, Value = 45877, Width = 90, ReadOnly = true, Increment = 0 };
    private readonly ComboBox _edgeBox = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 90 };
    private readonly Label _status = new() { AutoSize = true, Text = "Stopped" };
    private readonly Label _stats = new() { AutoSize = true, Text = "Stats: idle" };
    private readonly Label _clipboardStatus = new() { AutoSize = false, Text = "Clipboard: starting...", Width = 620, Height = 28 };
    private readonly DisplayArrangementControl _arrangementView = new() { Dock = DockStyle.Fill };
    private readonly Button _start = new() { Text = "Start", Width = 110 };
    private readonly System.Windows.Forms.Timer _clipboardTimer = new() { Interval = 700 };
    private readonly NotifyIcon _trayIcon = new();
    private readonly ContextMenuStrip _trayMenu = new();
    private readonly ToolStripMenuItem _trayStatus = new("Status: Stopped") { Enabled = false };
    private readonly ToolStripMenuItem _trayStartStop = new("Start");
    private readonly ToolStripMenuItem _trayQuit = new("Quit Portal");
    private readonly MacBeaconListener _beaconListener = new(DiscoveryPort);
    private PortalHost? _host;
    private bool _autoStarted;
    private bool _allowExit;
    private string? _lastClipboardSignature;
    private string? _lastAppliedClipboardSignature;
    private bool _applyingClipboard;
    private string? _discoveredMacIp;

    public MainForm()
    {
        Text = "Portal";
        ClientSize = new Size(360, 248);
        MinimumSize = new Size(340, 220);
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        Font = new Font("Segoe UI", 9F, FontStyle.Regular);
        BackColor = PortalTheme.Window;
        ForeColor = PortalTheme.Text;
        ApplyTheme(this);
        ConfigureShell();
        ConfigureTray();

        _edgeBox.Items.AddRange(["right", "left", "top", "bottom"]);
        _edgeBox.SelectedItem = "left";
        LoadSettings();

        BuildControlTab();
        _clipboardStatus.Text = "Clipboard: text and images ready";
        RefreshDisplayInfo();

        ShowPage(_controlTab, "Control");
        ApplyTheme(this);

        _beaconListener.BeaconReceived += OnMacBeaconReceived;
        Load += (_, _) =>
        {
            ShowInTaskbar = false;
            Opacity = 0;
            AutoStartOnce();
            Hide();
        };
        _clipboardTimer.Tick += (_, _) => PublishLocalClipboardIfChanged();
        _clipboardTimer.Start();
    }

    private void ConfigureTray()
    {
        _trayIcon.Text = "Portal";
        _trayIcon.Icon = SystemIcons.Application;
        _trayIcon.Visible = true;
        _trayStartStop.Click += Toggle;
        _trayQuit.Click += (_, _) =>
        {
            _allowExit = true;
            Close();
        };

        _trayMenu.Items.Add(_trayStatus);
        _trayMenu.Items.Add(new ToolStripSeparator());
        _trayMenu.Items.Add(_trayStartStop);
        _trayMenu.Items.Add(new ToolStripSeparator());
        _trayMenu.Items.Add(_trayQuit);
        _trayIcon.ContextMenuStrip = _trayMenu;
        UpdateTrayItems();
    }

    private void ConfigureShell()
    {
        var shell = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 2,
            BackColor = PortalTheme.Window
        };
        shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 86));
        shell.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        Controls.Add(shell);

        var header = new Panel
        {
            Dock = DockStyle.Fill,
            BackColor = PortalTheme.Window,
            Padding = new Padding(24, 18, 24, 12)
        };
        shell.Controls.Add(header, 0, 0);

        _pageTitle.Font = new Font(Font.FontFamily, 20F, FontStyle.Bold);
        _pageTitle.ForeColor = PortalTheme.Text;
        _pageTitle.Location = new Point(0, 2);
        header.Controls.Add(_pageTitle);

        _status.AutoSize = false;
        _status.Width = 260;
        _status.Height = 26;
        _status.Location = new Point(140, 6);
        _status.Font = new Font(Font.FontFamily, 8.6F, FontStyle.Bold);
        _status.ForeColor = PortalTheme.Muted;
        header.Controls.Add(_status);

        _start.Click += Toggle;
        _start.Width = 112;
        _start.Height = 34;
        _start.Font = new Font(Font.FontFamily, 9.5F, FontStyle.Bold);
        _start.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        header.Controls.Add(_start);
        header.Resize += (_, _) => _start.Location = new Point(header.Width - _start.Width, 2);

        _contentHost.BackColor = PortalTheme.Window;
        _contentHost.Padding = new Padding(24, 12, 24, 24);
        shell.Controls.Add(_contentHost, 0, 1);
    }

    private void ShowPage(Control page, string title)
    {
        _contentHost.Controls.Clear();
        _contentHost.Controls.Add(page);
        page.Dock = DockStyle.Fill;
        _pageTitle.Text = title;
    }

    private void BuildControlTab()
    {
        var shell = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 2,
            BackColor = PortalTheme.Window,
            Padding = new Padding(0)
        };
        shell.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 118));
        shell.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        _controlTab.Controls.Add(shell);

        var networkCard = Card("Client", "Auto-connects to the Mac on your network");
        AddField(networkCard, "Mac", _ipBox);
        AddField(networkCard, "Exit edge", _edgeBox);

        var statusCard = Card("Status", "Current bridge and clipboard state");
        _status.Font = new Font(Font.FontFamily, 16F, FontStyle.Bold);
        _status.ForeColor = PortalTheme.Muted;
        _status.AutoSize = false;
        _status.Height = 34;
        _status.Dock = DockStyle.Top;
        _stats.AutoSize = false;
        _stats.Height = 28;
        _stats.Dock = DockStyle.Top;
        _stats.ForeColor = PortalTheme.Muted;
        _clipboardStatus.Dock = DockStyle.Top;
        _clipboardStatus.Height = 28;
        _clipboardStatus.ForeColor = PortalTheme.Muted;
        statusCard.Controls.Add(_clipboardStatus);
        statusCard.Controls.Add(_stats);
        statusCard.Controls.Add(_status);

        shell.Controls.Add(networkCard, 0, 0);
        shell.Controls.Add(statusCard, 0, 1);
    }

    private Panel Card(string title, string subtitle)
    {
        var panel = new Panel
        {
            Dock = DockStyle.Fill,
            BackColor = PortalTheme.Panel,
            Padding = new Padding(18),
            Margin = new Padding(0, 0, 14, 14)
        };
        var titleLabel = new Label
        {
            Text = title,
            Dock = DockStyle.Top,
            Height = 26,
            Font = new Font(Font.FontFamily, 12F, FontStyle.Bold),
            ForeColor = PortalTheme.Text
        };
        var subtitleLabel = new Label
        {
            Text = subtitle,
            Dock = DockStyle.Top,
            Height = 24,
            Font = new Font(Font.FontFamily, 8.6F, FontStyle.Regular),
            ForeColor = PortalTheme.Muted
        };
        panel.Controls.Add(subtitleLabel);
        panel.Controls.Add(titleLabel);
        return panel;
    }

    private void AddField(Panel panel, string label, Control control)
    {
        var row = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            Height = 42,
            ColumnCount = 2,
            BackColor = PortalTheme.Panel,
            Padding = new Padding(0, 4, 0, 4)
        };
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 38));
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 62));
        var labelView = new Label
        {
            Text = label,
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft,
            ForeColor = PortalTheme.Muted
        };
        control.Dock = DockStyle.Fill;
        control.Margin = new Padding(0, 3, 0, 3);
        row.Controls.Add(labelView, 0, 0);
        row.Controls.Add(control, 1, 0);
        panel.Controls.Add(row);
        row.BringToFront();
    }

    private static void ApplyTheme(Control root)
    {
        StyleControl(root);
        foreach (Control control in root.Controls)
        {
            ApplyTheme(control);
        }
    }

    private static void StyleControl(Control control)
    {
        control.ForeColor = PortalTheme.Text;
        switch (control)
        {
            case TabPage page:
                page.BackColor = PortalTheme.Window;
                page.ForeColor = PortalTheme.Text;
                break;
            case Button button:
                button.FlatStyle = FlatStyle.Flat;
                button.FlatAppearance.BorderColor = PortalTheme.Border;
                button.FlatAppearance.BorderSize = 1;
                button.BackColor = PortalTheme.Panel;
                button.ForeColor = PortalTheme.Text;
                button.Height = Math.Max(button.Height, 30);
                break;
            case TextBox textBox:
                textBox.BorderStyle = BorderStyle.FixedSingle;
                textBox.BackColor = PortalTheme.PanelAlt;
                textBox.ForeColor = PortalTheme.Text;
                break;
            case NumericUpDown numeric:
                numeric.BackColor = PortalTheme.PanelAlt;
                numeric.ForeColor = PortalTheme.Text;
                break;
            case ComboBox combo:
                combo.BackColor = PortalTheme.PanelAlt;
                combo.ForeColor = PortalTheme.Text;
                break;
            case Label label:
                label.BackColor = Color.Transparent;
                label.ForeColor = label.Font.Bold || label.Font.Size >= 12 ? PortalTheme.Text : PortalTheme.Muted;
                break;
            default:
                control.BackColor = PortalTheme.Window;
                break;
        }
    }

    private void AddRow(string label, Control control, int top)
    {
        _controlTab.Controls.Add(new Label { Text = label, Left = 24, Top = top + 4, Width = 100 });
        control.Left = 134;
        control.Top = top;
        _controlTab.Controls.Add(control);
    }

    private void Toggle(object? sender, EventArgs e)
    {
        if (_host != null)
        {
            _host.Stop();
            _host = null;
            SetStatus("Stopped");
            UpdateTrayItems();
            return;
        }

        if (string.IsNullOrWhiteSpace(_ipBox.Text))
        {
            SetStatus("Waiting for Mac");
            return;
        }

        _host = new PortalHost(_ipBox.Text.Trim(), (int)_portBox.Value, _edgeBox.Text);
        SaveSettings();
        _host.StatusChanged += text => BeginInvoke((MethodInvoker)(() => SetStatus(text)));
        _host.StatsChanged += text => BeginInvoke((MethodInvoker)(() => _stats.Text = text));
        _host.ClipboardReceived += packet => BeginInvoke((MethodInvoker)(() => ApplyRemoteClipboard(packet)));
        _host.ArrangementOffsetsChanged += offsets => BeginInvoke((MethodInvoker)(() =>
        {
            _arrangementView.MachineOffsets = offsets;
        }));
        _host.RemoteDisplaysChanged += displays => BeginInvoke((MethodInvoker)(() =>
        {
            _arrangementView.MacDisplays = displays;
        }));
        _host.Stopped += () => BeginInvoke((MethodInvoker)(() =>
        {
            _host = null;
            UpdateTrayItems();
            if (!string.IsNullOrWhiteSpace(_discoveredMacIp))
            {
                BeginInvoke((MethodInvoker)(() => Toggle(this, EventArgs.Empty)));
            }
        }));
        try
        {
            _host.Start(this);
            UpdateTrayItems();
        }
        catch (Exception ex)
        {
            SetStatus(ex.Message);
            _host = null;
            UpdateTrayItems();
        }
    }

    internal void HandleActivationSignal()
    {
    }

    internal void ShowPortalWindow()
    {
        Opacity = 1;
        Show();
        WindowState = FormWindowState.Normal;
        ShowInTaskbar = true;
        Activate();
        BringToFront();
    }

    private void SetStatus(string text)
    {
        _status.Text = text;
        _trayStatus.Text = $"Status: {text}";
        var trayText = $"Portal - {text}";
        _trayIcon.Text = trayText.Length <= 63 ? trayText : trayText[..63];
    }

    private void UpdateTrayItems()
    {
        var running = _host != null;
        _start.Text = running ? "Stop" : "Start";
        _start.BackColor = running ? PortalTheme.Danger : PortalTheme.Accent;
        _start.ForeColor = Color.White;
        _trayStartStop.Text = running ? "Stop" : "Start";
    }

    private void AutoStartOnce()
    {
        RefreshDisplayInfo();
        if (_autoStarted) return;
        _autoStarted = true;
        _beaconListener.Start();
        if (_host == null && !string.IsNullOrWhiteSpace(_ipBox.Text))
        {
            Toggle(this, EventArgs.Empty);
        }
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!_allowExit && e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Opacity = 0;
            Hide();
            ShowInTaskbar = false;
            return;
        }

        _clipboardTimer.Stop();
        _beaconListener.Dispose();
        SaveSettings();
        _host?.Stop();
        _trayIcon.Visible = false;
        _trayIcon.Dispose();
        base.OnFormClosing(e);
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        if (WindowState == FormWindowState.Minimized)
        {
            Opacity = 0;
            Hide();
            ShowInTaskbar = false;
        }
    }

    private void PublishLocalClipboardIfChanged()
    {
        if (_applyingClipboard || _host == null) return;

        ClipboardPacket? packet;
        string? signature;
        string? status;
        try
        {
            packet = PortalClipboard.ReadLocalClipboard(out signature, out status);
        }
        catch (ExternalException)
        {
            return;
        }
        catch
        {
            return;
        }

        if (packet == null)
        {
            if (signature != null && signature != _lastClipboardSignature)
            {
                _lastClipboardSignature = signature;
                if (!string.IsNullOrWhiteSpace(status)) _clipboardStatus.Text = status;
            }
            return;
        }

        if (signature == _lastClipboardSignature || signature == _lastAppliedClipboardSignature) return;
        if (_host.SendClipboard(packet))
        {
            _lastClipboardSignature = signature;
            _clipboardStatus.Text = packet.ContentType == "text/plain" ? "Clipboard: sent text" : "Clipboard: sent image";
        }
    }

    private void ApplyRemoteClipboard(ClipboardPacket packet)
    {
        var signature = PortalClipboard.Signature(packet);
        if (signature == _lastClipboardSignature || signature == _lastAppliedClipboardSignature) return;

        _applyingClipboard = true;
        try
        {
            if (packet.ContentType == "text/plain" && packet.Text != null)
            {
                Clipboard.SetText(packet.Text, TextDataFormat.UnicodeText);
                DebugLog($"clipboard applied text bytes={packet.Text.Length}");
                _clipboardStatus.Text = "Clipboard: received text";
            }
            else if (packet.ContentType == "image/png" && packet.DataBase64 != null)
            {
                var bytes = Convert.FromBase64String(packet.DataBase64);
                if (bytes.Length > PortalClipboard.MaxImageBytes)
                {
                    _clipboardStatus.Text = "Clipboard: image too large";
                    return;
                }

                using var stream = new MemoryStream(bytes);
                using var image = Image.FromStream(stream);
                Clipboard.SetImage(new Bitmap(image));
                DebugLog($"clipboard applied image bytes={bytes.Length}");
                _clipboardStatus.Text = "Clipboard: received image";
            }
            else
            {
                return;
            }

            _lastAppliedClipboardSignature = signature;
            _lastClipboardSignature = signature;
        }
        catch (Exception ex)
        {
            DebugLog($"clipboard apply failed {ex.GetType().Name}: {ex.Message}");
            _clipboardStatus.Text = "Clipboard: update failed";
        }
        finally
        {
            _applyingClipboard = false;
        }
    }

    private static void DebugLog(string message)
    {
        try
        {
            File.AppendAllText(InputLogPath, $"{DateTimeOffset.Now:O} {message}{Environment.NewLine}");
        }
        catch { }
    }

    private void LoadSettings()
    {
        try
        {
            var settings = AppSettings.Load();
            _ipBox.Text = settings.MacIp?.Trim() ?? "";
            _portBox.Value = Math.Clamp(settings.Port <= 0 ? 45877 : settings.Port, 1, 65535);
            _edgeBox.SelectedItem = _edgeBox.Items.Contains(settings.Edge) ? settings.Edge : "left";
        }
        catch
        {
            _ipBox.Text = "";
            _portBox.Value = 45877;
            _edgeBox.SelectedItem = "left";
        }
    }

    private void SaveSettings()
    {
        try
        {
            AppSettings.Save(new AppSettings
            {
                MacIp = _ipBox.Text.Trim(),
                Port = (int)_portBox.Value,
                Edge = _edgeBox.Text
            });
        }
        catch { }
    }

    private void OnMacBeaconReceived(MacBeacon beacon)
    {
        if (InvokeRequired)
        {
            BeginInvoke((MethodInvoker)(() => OnMacBeaconReceived(beacon)));
            return;
        }

        if (string.IsNullOrWhiteSpace(beacon.IpAddress)) return;
        _discoveredMacIp = beacon.IpAddress;
        var settingsChanged = false;
        if (beacon.Port is >= 1 and <= 65535 && _portBox.Value != beacon.Port)
        {
            _portBox.Value = beacon.Port;
            settingsChanged = true;
        }
        if (_ipBox.Text != beacon.IpAddress)
        {
            _ipBox.Text = beacon.IpAddress;
            settingsChanged = true;
        }
        if (settingsChanged)
        {
            SaveSettings();
        }
        if (_host == null)
        {
            Toggle(this, EventArgs.Empty);
        }
    }

    private static List<DisplayBox> LocalDisplays()
    {
        var screens = Screen.AllScreens;
        return screens
            .Select((screen, index) => new DisplayBox(
                $"{index + 1}{(screen.Primary ? "*" : "")} {screen.DeviceName}",
                screen.Bounds,
                screen.Primary
            ))
            .ToList();
    }

    private static string DisplaySummary(string label, IReadOnlyList<DisplayBox> displays)
    {
        if (displays.Count == 0) return $"{label}: waiting";
        var parts = displays
            .Select((display, index) =>
            {
                var bounds = display.Bounds;
                var primary = display.Primary ? "*" : "";
                return $"{index + 1}{primary}: {bounds.Width}x{bounds.Height} @ {bounds.X},{bounds.Y}";
            });
        return $"{label}: {displays.Count} - {string.Join(" | ", parts)}";
    }

    private void RefreshDisplayInfo()
    {
        var displays = LocalDisplays();
        _arrangementView.WindowsDisplays = displays;
    }

}

public sealed class AppSettings
{
    public string MacIp { get; set; } = "";
    public int Port { get; set; } = 45877;
    public string Edge { get; set; } = "left";

    private static string SettingsPath
    {
        get
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "Portal"
            );
            Directory.CreateDirectory(dir);
            return Path.Combine(dir, "windows-settings.json");
        }
    }

    public static AppSettings Load()
    {
        if (!File.Exists(SettingsPath)) return new AppSettings();
        var json = File.ReadAllText(SettingsPath);
        return JsonSerializer.Deserialize<AppSettings>(json) ?? new AppSettings();
    }

    public static void Save(AppSettings settings)
    {
        var json = JsonSerializer.Serialize(settings, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(SettingsPath, json);
    }
}

public sealed record DisplayBox(string Name, Rectangle Bounds, bool Primary);

public sealed record ClipboardPacket(string Id, string ContentType, string? Text, string? DataBase64);

internal sealed record MacBeacon(string IpAddress, int Port);

internal sealed class MacBeaconListener : IDisposable
{
    private readonly int _port;
    private readonly CancellationTokenSource _cts = new();
    private UdpClient? _client;
    private Task? _task;

    public event Action<MacBeacon>? BeaconReceived;

    public MacBeaconListener(int port)
    {
        _port = port;
    }

    public void Start()
    {
        if (_task != null) return;

        var client = new UdpClient();
        client.ExclusiveAddressUse = false;
        client.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        client.Client.Bind(new IPEndPoint(IPAddress.Any, _port));
        _client = client;
        _task = Task.Run(() => ReceiveLoopAsync(client, _cts.Token));
    }

    public void Dispose()
    {
        _cts.Cancel();
        try { _client?.Close(); } catch { }
        try { _task?.Wait(500); } catch { }
        _client?.Dispose();
        _cts.Dispose();
    }

    private async Task ReceiveLoopAsync(UdpClient client, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            UdpReceiveResult packet;
            try
            {
                packet = await client.ReceiveAsync(cancellationToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (ObjectDisposedException)
            {
                break;
            }
            catch
            {
                continue;
            }

            try
            {
                using var json = JsonDocument.Parse(packet.Buffer);
                var root = json.RootElement;
                if (!root.TryGetProperty("type", out var typeNode) ||
                    !string.Equals(typeNode.GetString(), "portalMacBeacon", StringComparison.Ordinal))
                {
                    continue;
                }

                var ipAddress = root.TryGetProperty("ip", out var ipNode) ? ipNode.GetString() : null;
                var port = root.TryGetProperty("port", out var portNode) && portNode.TryGetInt32(out var parsedPort)
                    ? parsedPort
                    : 45877;
                if (string.IsNullOrWhiteSpace(ipAddress)) continue;
                BeaconReceived?.Invoke(new MacBeacon(ipAddress.Trim(), port));
            }
            catch
            {
            }
        }
    }
}

internal static class PortalClipboard
{
    public const int MaxImageBytes = 8 * 1024 * 1024;

    public static ClipboardPacket? ReadLocalClipboard(out string? signature, out string? status)
    {
        signature = null;
        status = null;

        if (Clipboard.ContainsImage())
        {
            using var image = Clipboard.GetImage();
            if (image == null) return null;

            using var stream = new MemoryStream();
            image.Save(stream, ImageFormat.Png);
            var bytes = stream.ToArray();
            var dataBase64 = Convert.ToBase64String(bytes);
            signature = Signature("image/png", null, dataBase64);
            if (bytes.Length > MaxImageBytes)
            {
                status = "Clipboard: image too large";
                return null;
            }

            return new ClipboardPacket(Guid.NewGuid().ToString("N"), "image/png", null, dataBase64);
        }

        if (Clipboard.ContainsText(TextDataFormat.UnicodeText))
        {
            var text = Clipboard.GetText(TextDataFormat.UnicodeText);
            if (string.IsNullOrEmpty(text)) return null;
            signature = Signature("text/plain", text, null);
            return new ClipboardPacket(Guid.NewGuid().ToString("N"), "text/plain", text, null);
        }

        return null;
    }

    public static ClipboardPacket? FromJson(JsonElement root)
    {
        var id = ReadString(root, "id") ?? Guid.NewGuid().ToString("N");
        var contentType = ReadString(root, "contentType");
        if (contentType is not ("text/plain" or "image/png")) return null;
        return new ClipboardPacket(
            id,
            contentType,
            ReadString(root, "text"),
            ReadString(root, "data")
        );
    }

    public static string Signature(ClipboardPacket packet)
    {
        return Signature(packet.ContentType, packet.Text, packet.DataBase64);
    }

    public static string Signature(string contentType, string? text, string? dataBase64)
    {
        using var sha = SHA256.Create();
        using var stream = new MemoryStream();
        WriteUtf8(stream, contentType);
        stream.WriteByte(0);
        if (text != null) WriteUtf8(stream, text);
        if (dataBase64 != null) WriteUtf8(stream, dataBase64);
        return Convert.ToHexString(sha.ComputeHash(stream.ToArray()));
    }

    private static string? ReadString(JsonElement root, string name)
    {
        return root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;
    }

    private static void WriteUtf8(Stream stream, string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        stream.Write(bytes, 0, bytes.Length);
    }
}

internal sealed class DisplayArrangementControl : Control
{
    private const float CanvasPadding = 24f;
    private const float FitScalePadding = 0.86f;
    private List<DisplayBox> _windowsDisplays = [];
    private List<DisplayBox> _macDisplays = [];
    private Dictionary<string, PointF> _machineOffsets = new(StringComparer.OrdinalIgnoreCase);
    private float _scale;
    private PointF _pan;

    public List<DisplayBox> WindowsDisplays
    {
        get => _windowsDisplays;
        set
        {
            _windowsDisplays = value;
            Invalidate();
        }
    }

    public List<DisplayBox> MacDisplays
    {
        get => _macDisplays;
        set
        {
            _macDisplays = value;
            Invalidate();
        }
    }

    public Dictionary<string, PointF> MachineOffsets
    {
        get => _machineOffsets;
        set
        {
            _machineOffsets = value;
            Invalidate();
        }
    }

    public DisplayArrangementControl()
    {
        DoubleBuffered = true;
        ResizeRedraw = true;
        BackColor = PortalTheme.PanelAlt;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        g.Clear(PortalTheme.Window);
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;

        var canvas = ClientCanvas();
        using var panelFill = new SolidBrush(PortalTheme.PanelAlt);
        using var panelPen = new Pen(PortalTheme.Border);
        g.FillRectangle(panelFill, canvas);
        g.DrawRectangle(panelPen, canvas.X, canvas.Y, canvas.Width, canvas.Height);

        var boxes = ArrangementBoxes();
        if (boxes.Count == 0)
        {
            TextRenderer.DrawText(
                g,
                "Waiting for display layout",
                Font,
                Rectangle.Round(canvas),
                PortalTheme.Muted,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter
            );
            return;
        }

        var union = VirtualUnion(boxes);
        var drawing = DrawingArea(canvas);
        if (drawing.Width <= 1 || drawing.Height <= 1) return;

        FitViewport(boxes, drawing);

        var visible = Map(union, _scale, _pan);

        DrawGrid(g, visible);
        using var outline = new Pen(Color.FromArgb(90, PortalTheme.Border));
        g.DrawRectangle(outline, visible.X, visible.Y, visible.Width, visible.Height);

        using var labelFont = new Font(Font.FontFamily, 7.8f, FontStyle.Regular);
        using var numberFont = new Font(Font.FontFamily, 18f, FontStyle.Bold);
        var centerFormat = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };

        foreach (var box in boxes)
        {
            var rect = Map(box.VirtualBounds, _scale, _pan);
            var accent = box.Machine == "mac"
                ? (box.Primary ? PortalTheme.Accent : PortalTheme.Mac)
                : (box.Primary ? PortalTheme.Windows : PortalTheme.WindowsSecondary);
            using var fill = new SolidBrush(Color.FromArgb(48, accent));
            using var pen = new Pen(accent, box.Primary ? 3f : 2f);
            g.FillRectangle(fill, rect);
            g.DrawRectangle(pen, rect.X, rect.Y, rect.Width, rect.Height);

            using var numberBrush = new SolidBrush(PortalTheme.Text);
            var prefix = box.Machine == "mac" ? "M" : "W";
            g.DrawString($"{prefix}{box.Index + 1}{(box.Primary ? "*" : "")}", numberFont, numberBrush, rect, centerFormat);

            if (rect.Width >= 92 && rect.Height >= 58)
            {
                var label = $"{box.Name}\n{box.NativeBounds.Width}x{box.NativeBounds.Height}";
                var labelHeight = Math.Min(38, Math.Max(22, rect.Height * 0.35f));
                var labelRect = new RectangleF(rect.Left + 5, rect.Bottom - labelHeight - 5, Math.Max(1, rect.Width - 10), labelHeight);
                using var labelBrush = new SolidBrush(PortalTheme.Muted);
                g.DrawString(label, labelFont, labelBrush, labelRect, centerFormat);
            }
        }
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        Invalidate();
    }

    private void FitViewport(IReadOnlyList<ArrangementBox> boxes, RectangleF drawing)
    {
        var union = VirtualUnion(boxes);
        var fitScale = Math.Min(drawing.Width / Math.Max(1, union.Width), drawing.Height / Math.Max(1, union.Height));
        _scale = Math.Max(0.02f, fitScale * FitScalePadding);
        CenterDisplays(boxes, drawing, _scale);
        ClampPanToUnion(union, drawing, _scale);
    }

    private void CenterDisplays(IReadOnlyList<ArrangementBox> boxes, RectangleF drawing, float scale)
    {
        var totalArea = 0f;
        var centerX = 0f;
        var centerY = 0f;
        foreach (var box in boxes)
        {
            var area = Math.Max(1f, box.VirtualBounds.Width * box.VirtualBounds.Height);
            totalArea += area;
            centerX += (box.VirtualBounds.Left + box.VirtualBounds.Width / 2f) * area;
            centerY += (box.VirtualBounds.Top + box.VirtualBounds.Height / 2f) * area;
        }

        if (totalArea <= 0)
        {
            CenterUnion(VirtualUnion(boxes), drawing, scale);
            return;
        }

        centerX /= totalArea;
        centerY /= totalArea;
        _pan = new PointF(
            drawing.Left + drawing.Width / 2f - centerX * scale,
            drawing.Top + drawing.Height / 2f - centerY * scale
        );
    }

    private void CenterUnion(RectangleF union, RectangleF drawing, float scale)
    {
        var drawnWidth = union.Width * scale;
        var drawnHeight = union.Height * scale;
        _pan = new PointF(
            drawing.Left + (drawing.Width - drawnWidth) / 2f - union.Left * scale,
            drawing.Top + (drawing.Height - drawnHeight) / 2f - union.Top * scale
        );
    }

    private void ClampPanToUnion(RectangleF union, RectangleF drawing, float scale)
    {
        const float margin = 18f;
        var minPanX = drawing.Right - margin - union.Right * scale;
        var maxPanX = drawing.Left + margin - union.Left * scale;
        var minPanY = drawing.Bottom - margin - union.Bottom * scale;
        var maxPanY = drawing.Top + margin - union.Top * scale;

        _pan = new PointF(
            minPanX <= maxPanX ? Math.Clamp(_pan.X, minPanX, maxPanX) : drawing.Left - union.Left * scale,
            minPanY <= maxPanY ? Math.Clamp(_pan.Y, minPanY, maxPanY) : drawing.Top - union.Top * scale
        );
    }

    private RectangleF ClientCanvas()
    {
        var scale = DeviceDpi <= 96 ? 1f : DeviceDpi / 96f;
        return new RectangleF(
            0,
            0,
            Math.Max(1, (ClientSize.Width - 1) / scale),
            Math.Max(1, (ClientSize.Height - 1) / scale)
        );
    }

    private static RectangleF DrawingArea(RectangleF canvas)
    {
        return RectangleF.Inflate(canvas, -CanvasPadding, -CanvasPadding);
    }

    private static RectangleF VirtualUnion(IReadOnlyList<ArrangementBox> boxes)
    {
        return boxes.Skip(1).Aggregate(boxes[0].VirtualBounds, (acc, box) => RectangleF.Union(acc, box.VirtualBounds));
    }

    private List<ArrangementBox> ArrangementBoxes()
    {
        var windowsWidth = GroupWidth(_windowsDisplays, fallback: 2560);
        var boxes = new List<ArrangementBox>();
        boxes.AddRange(DefaultFrames(_macDisplays, "mac", 0));
        boxes.AddRange(DefaultFrames(_windowsDisplays, "windows", -(windowsWidth + 220)));
        return boxes.Select(ApplyMachineOffset).ToList();
    }

    private ArrangementBox ApplyMachineOffset(ArrangementBox box)
    {
        if (!_machineOffsets.TryGetValue(box.Machine, out var offset)) return box;
        return box with
        {
            VirtualBounds = new RectangleF(
                box.VirtualBounds.Left + offset.X,
                box.VirtualBounds.Top - offset.Y,
                box.VirtualBounds.Width,
                box.VirtualBounds.Height
            )
        };
    }

    private static IEnumerable<ArrangementBox> DefaultFrames(IReadOnlyList<DisplayBox> displays, string machine, float xOffset)
    {
        if (displays.Count == 0) yield break;

        var union = displays.Skip(1).Aggregate(displays[0].Bounds, (acc, display) => Rectangle.Union(acc, display.Bounds));
        for (var index = 0; index < displays.Count; index++)
        {
            var display = displays[index];
            var frame = new RectangleF(
                display.Bounds.Left - union.Left + xOffset,
                display.Bounds.Top - union.Top,
                display.Bounds.Width,
                display.Bounds.Height
            );
            yield return new ArrangementBox(machine, index, display.Name, display.Bounds, frame, display.Primary);
        }
    }

    private static float GroupWidth(IReadOnlyList<DisplayBox> displays, float fallback)
    {
        if (displays.Count == 0) return fallback;
        return displays.Skip(1).Aggregate(displays[0].Bounds, (acc, display) => Rectangle.Union(acc, display.Bounds)).Width;
    }

    private static RectangleF Map(RectangleF bounds, float scale, PointF pan)
    {
        return new RectangleF(
            pan.X + bounds.Left * scale,
            pan.Y + bounds.Top * scale,
            Math.Max(8, bounds.Width * scale),
            Math.Max(8, bounds.Height * scale)
        );
    }

    private static void DrawGrid(Graphics g, RectangleF rect)
    {
        using var pen = new Pen(PortalTheme.Grid);
        const float step = 48;
        for (var x = rect.Left; x <= rect.Right; x += step)
        {
            g.DrawLine(pen, x, rect.Top, x, rect.Bottom);
        }
        for (var y = rect.Top; y <= rect.Bottom; y += step)
        {
            g.DrawLine(pen, rect.Left, y, rect.Right, y);
        }
    }

    private sealed record ArrangementBox(
        string Machine,
        int Index,
        string Name,
        Rectangle NativeBounds,
        RectangleF VirtualBounds,
        bool Primary
    );
}

public sealed class PortalHost
{
    private static readonly string InputLogPath = Path.Combine(Path.GetTempPath(), "portal-windows-input.log");
    private const int WH_MOUSE_LL = 14;
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_MOUSEMOVE = 0x0200;
    private const int WM_LBUTTONDOWN = 0x0201;
    private const int WM_LBUTTONUP = 0x0202;
    private const int WM_RBUTTONDOWN = 0x0204;
    private const int WM_RBUTTONUP = 0x0205;
    private const int WM_MBUTTONDOWN = 0x0207;
    private const int WM_MBUTTONUP = 0x0208;
    private const int WM_MOUSEWHEEL = 0x020A;
    private const int WM_XBUTTONDOWN = 0x020B;
    private const int WM_XBUTTONUP = 0x020C;
    private const int WM_MOUSEHWHEEL = 0x020E;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;
    private const int XBUTTON1 = 1;
    private const int XBUTTON2 = 2;
    private const int LLMHF_INJECTED = 0x00000001;
    private const int LLKHF_INJECTED = 0x00000010;
    private const long PinIntervalMs = 16;
    private const double MouseFlushIntervalMs = 1.0;
    private static readonly bool LiveStatsEnabled = false;

    private readonly string _macIp;
    private readonly int _port;
    private readonly string _edge;
    private string _activeEdge;
    private readonly object _gate = new();
    private readonly object _sendLock = new();
    private readonly LowLevelMouseProc _mouseProc;
    private readonly LowLevelKeyboardProc _keyboardProc;
    private TcpClient? _client;
    private NetworkStream? _stream;
    private UdpClient? _udp;
    private Thread? _worker;
    private Control? _uiThread;
    private RawMousePump? _rawMousePump;
    private readonly AutoResetEvent _sendSignal = new(false);
    private Thread? _senderThread;
    private Thread? _edgeMonitorThread;
    private IntPtr _mouseHook;
    private IntPtr _keyboardHook;
    private bool _running;
    private bool _remoteActive;
    private bool _controlledByMac;
    private bool _activationPending;
    private DateTime _suppressActivationUntil = DateTime.MinValue;
    private Point? _lastPos;
    private bool _ctrl;
    private bool _alt;
    private Rectangle _activeScreenBounds;
    private Rectangle _targetScreenBounds;
    private string _targetReturnEdge = "left";
    private List<DisplayBox> _remoteDisplays = [];
    private Dictionary<string, PointF> _machineOffsets = new(StringComparer.OrdinalIgnoreCase);
    private int _pendingDx;
    private int _pendingDy;
    private int _pendingRawCount;
    private long _rawMoves;
    private long _sentMoves;
    private long _clicks;
    private long _keys;
    private long _statsWindowRawMoves;
    private long _statsWindowSentMoves;
    private DateTime _lastStatsAt = DateTime.UtcNow;
    private long _lastPinAt;
    private int _moveSequence;
    private long _lastMoveSendTimestamp;

    public event Action<string>? StatusChanged;
    public event Action<string>? StatsChanged;
    public event Action<List<DisplayBox>>? RemoteDisplaysChanged;
    public event Action<Dictionary<string, PointF>>? ArrangementOffsetsChanged;
    public event Action<ClipboardPacket>? ClipboardReceived;
    public event Action? Stopped;

    public PortalHost(string macIp, int port, string edge)
    {
        _macIp = macIp;
        _port = port;
        _edge = edge;
        _activeEdge = edge;
        _mouseProc = MouseHook;
        _keyboardProc = KeyboardHook;
    }

    public void Start(Control uiThread)
    {
        _uiThread = uiThread;
        _running = true;
        StatsChanged?.Invoke("Performance mode: live stats paused");
        timeBeginPeriod(1);
        _senderThread = new Thread(SenderLoop)
        {
            IsBackground = true,
            Priority = ThreadPriority.Highest,
            Name = "Portal mouse sender"
        };
        _senderThread.Start();
        _edgeMonitorThread = new Thread(EdgeMonitorLoop)
        {
            IsBackground = true,
            Priority = ThreadPriority.AboveNormal,
            Name = "Portal edge monitor"
        };
        _edgeMonitorThread.Start();
        _worker = new Thread(ConnectLoop) { IsBackground = true };
        _worker.Start();
    }

    public void Stop()
    {
        _running = false;
        _sendSignal.Set();
        DisableRemoteCapture();
        try { _client?.Close(); } catch { }
        try { _udp?.Dispose(); } catch { }
        _udp = null;
        timeEndPeriod(1);
        StatusChanged?.Invoke("Stopped");
    }

    private void ConnectLoop()
    {
        while (_running)
        {
            try
            {
                StatusChanged?.Invoke("Connecting...");
                _client = new TcpClient { NoDelay = true };
                _client.Connect(_macIp, _port);
                ConfigureLowLatencySocket(_client.Client);
                _stream = _client.GetStream();
                _udp?.Dispose();
                _udp = new UdpClient();
                _udp.Client.Blocking = false;
                _udp.Client.SendBufferSize = 256 * 1024;
                ConfigureLowLatencySocket(_udp.Client);
                _udp.Connect(_macIp, _port);
                StatusChanged?.Invoke("Connected");
                SendDisplayLayout();
                _uiThread?.BeginInvoke((MethodInvoker)(() =>
                {
                    if (InstallKeyboardHook())
                    {
                        DebugLog("keyboard hook ready");
                        StatusChanged?.Invoke("Running");
                    }
                }));
                Task.Run(ReadLoop);
                return;
            }
            catch
            {
                lock (_gate) _remoteActive = false;
                _uiThread?.BeginInvoke((MethodInvoker)DisableRemoteCapture);
                Thread.Sleep(1500);
            }
        }
        Stopped?.Invoke();
    }

    private async Task ReadLoop()
    {
        var buffer = new byte[65536];
        var pending = "";
        while (_running && _stream != null)
        {
            int read;
            try
            {
                read = await _stream.ReadAsync(buffer);
                if (read == 0) throw new IOException("Disconnected");
            }
            catch
            {
                lock (_gate) _remoteActive = false;
                _uiThread?.BeginInvoke((MethodInvoker)DisableRemoteCapture);
                ConnectLoop();
                return;
            }

            pending += Encoding.UTF8.GetString(buffer, 0, read);
            int newline;
            while ((newline = pending.IndexOf('\n')) >= 0)
            {
                var line = pending[..newline];
                pending = pending[(newline + 1)..];
                HandleControlLine(line);
            }
        }
    }

    private void HandleControlLine(string line)
    {
        if (line.Length > 0 && line[0] == 'm')
        {
            var move = ParseIncomingMoveLine(line);
            if (move.HasValue && _controlledByMac)
            {
                ApplyRemoteMove(move.Value.dx, move.Value.dy);
            }
            return;
        }

        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (!root.TryGetProperty("type", out var typeElement) || typeElement.ValueKind != JsonValueKind.String) return;

            switch (typeElement.GetString())
            {
                case "activate":
                    var edgeName = root.TryGetProperty("edge", out var edgeValue) && edgeValue.ValueKind == JsonValueKind.String
                        ? edgeValue.GetString()
                        : null;
                    var sourceDisplay = root.TryGetProperty("screen", out var screenValue) && screenValue.ValueKind == JsonValueKind.Object
                        ? ParseDisplayInfo(screenValue)
                        : null;
                    if (!string.IsNullOrWhiteSpace(edgeName))
                    {
                        var activateX = root.TryGetProperty("xRatio", out var activateXValue) && activateXValue.ValueKind == JsonValueKind.Number
                            ? Math.Clamp(activateXValue.GetDouble(), 0.0, 1.0)
                            : 0.5;
                        var activateY = root.TryGetProperty("yRatio", out var activateYValue) && activateYValue.ValueKind == JsonValueKind.Number
                            ? Math.Clamp(activateYValue.GetDouble(), 0.0, 1.0)
                            : 0.5;
                        ActivateFromMac(edgeName!, activateX, activateY, sourceDisplay);
                    }
                    break;
                case "release":
                    var (xRatio, yRatio) = ParseReleaseRatios(root);
                    ReleaseToWindows(xRatio, yRatio);
                    break;
                case "move":
                    if (_controlledByMac)
                    {
                        var moveDx = root.TryGetProperty("dx", out var moveDxValue) && moveDxValue.ValueKind == JsonValueKind.Number
                            ? (int)Math.Round(moveDxValue.GetDouble())
                            : 0;
                        var moveDy = root.TryGetProperty("dy", out var moveDyValue) && moveDyValue.ValueKind == JsonValueKind.Number
                            ? (int)Math.Round(moveDyValue.GetDouble())
                            : 0;
                        ApplyRemoteMove(moveDx, moveDy);
                    }
                    break;
                case "button":
                    if (_controlledByMac)
                    {
                        var buttonName = root.TryGetProperty("button", out var buttonValue) && buttonValue.ValueKind == JsonValueKind.String
                            ? buttonValue.GetString() ?? "left"
                            : "left";
                        var buttonDown = root.TryGetProperty("down", out var downValue) &&
                                         (downValue.ValueKind == JsonValueKind.True || downValue.ValueKind == JsonValueKind.False) &&
                                         downValue.GetBoolean();
                        InjectMouseButton(buttonName, buttonDown);
                    }
                    break;
                case "scroll":
                    if (_controlledByMac)
                    {
                        var scrollDx = root.TryGetProperty("dx", out var scrollDxValue) && scrollDxValue.ValueKind == JsonValueKind.Number
                            ? (int)Math.Round(scrollDxValue.GetDouble())
                            : 0;
                        var scrollDy = root.TryGetProperty("dy", out var scrollDyValue) && scrollDyValue.ValueKind == JsonValueKind.Number
                            ? (int)Math.Round(scrollDyValue.GetDouble())
                            : 0;
                        InjectScroll(scrollDx, scrollDy);
                    }
                    break;
                case "key":
                    if (_controlledByMac)
                    {
                        var keyName = root.TryGetProperty("key", out var keyValue) && keyValue.ValueKind == JsonValueKind.String
                            ? keyValue.GetString()
                            : null;
                        var keyDown = root.TryGetProperty("down", out var keyDownValue) &&
                                      (keyDownValue.ValueKind == JsonValueKind.True || keyDownValue.ValueKind == JsonValueKind.False) &&
                                      keyDownValue.GetBoolean();
                        if (!string.IsNullOrWhiteSpace(keyName))
                        {
                            InjectKey(keyName!, keyDown);
                        }
                    }
                    break;
                case "displayLayout":
                    var displays = ParseDisplayLayout(root);
                    var offsets = ParseMachineOffsets(root);
                    lock (_gate)
                    {
                        if (displays.Count > 0) _remoteDisplays = displays;
                        if (root.TryGetProperty("machineOffsets", out _)) _machineOffsets = offsets;
                    }
                    if (displays.Count > 0) RemoteDisplaysChanged?.Invoke(displays);
                    if (root.TryGetProperty("machineOffsets", out _)) ArrangementOffsetsChanged?.Invoke(offsets);
                    break;
                case "clipboard":
                    var clipboardPacket = PortalClipboard.FromJson(root);
                    if (clipboardPacket != null)
                    {
                        DebugLog($"clipboard received {clipboardPacket.ContentType} textBytes={clipboardPacket.Text?.Length ?? 0} dataBytes={clipboardPacket.DataBase64?.Length ?? 0}");
                        ClipboardReceived?.Invoke(clipboardPacket);
                    }
                    break;
            }
        }
        catch { }
    }

    private static (int dx, int dy, int raw)? ParseIncomingMoveLine(string line)
    {
        var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 4 || parts[0] != "m") return null;
        if (!int.TryParse(parts[1], out var dx)) return null;
        if (!int.TryParse(parts[2], out var dy)) return null;
        if (!int.TryParse(parts[3], out var raw)) raw = 1;
        return (dx, dy, raw);
    }

    private static (double? xRatio, double? yRatio) ParseReleaseRatios(JsonElement root)
    {
        double? xRatio = root.TryGetProperty("xRatio", out var x) && x.ValueKind == JsonValueKind.Number
            ? Math.Clamp(x.GetDouble(), 0.0, 1.0)
            : null;
        double? yRatio = root.TryGetProperty("yRatio", out var y) && y.ValueKind == JsonValueKind.Number
            ? Math.Clamp(y.GetDouble(), 0.0, 1.0)
            : null;
        return (xRatio, yRatio);
    }

    private static List<DisplayBox> ParseDisplayLayout(JsonElement root)
    {
        var displays = new List<DisplayBox>();
        if (!root.TryGetProperty("displays", out var array) || array.ValueKind != JsonValueKind.Array) return displays;

        var index = 0;
        foreach (var item in array.EnumerateArray())
        {
            var width = ReadInt(item, "width");
            var height = ReadInt(item, "height");
            if (width <= 0 || height <= 0) continue;

            var name = item.TryGetProperty("name", out var nameElement) && nameElement.ValueKind == JsonValueKind.String
                ? nameElement.GetString() ?? $"Display {index + 1}"
                : $"Display {index + 1}";
            var x = ReadInt(item, "x");
            var y = ReadInt(item, "y");
            var primary = item.TryGetProperty("primary", out var primaryElement) &&
                          primaryElement.ValueKind == JsonValueKind.True;
            displays.Add(new DisplayBox(name, new Rectangle(x, y, width, height), primary));
            index++;
        }

        return displays;
    }

    private static DisplayBox? ParseDisplayInfo(JsonElement item)
    {
        var width = ReadInt(item, "width");
        var height = ReadInt(item, "height");
        if (width <= 0 || height <= 0) return null;
        var name = item.TryGetProperty("name", out var nameElement) && nameElement.ValueKind == JsonValueKind.String
            ? nameElement.GetString() ?? "Display 1"
            : "Display 1";
        var x = ReadInt(item, "x");
        var y = ReadInt(item, "y");
        var primary = item.TryGetProperty("primary", out var primaryElement) &&
                      primaryElement.ValueKind == JsonValueKind.True;
        return new DisplayBox(name, new Rectangle(x, y, width, height), primary);
    }

    private static Dictionary<string, PointF> ParseMachineOffsets(JsonElement root)
    {
        var offsets = new Dictionary<string, PointF>(StringComparer.OrdinalIgnoreCase);
        if (!root.TryGetProperty("machineOffsets", out var machineOffsets) ||
            machineOffsets.ValueKind != JsonValueKind.Object)
        {
            return offsets;
        }

        foreach (var item in machineOffsets.EnumerateObject())
        {
            if (item.Name is not ("mac" or "windows") || item.Value.ValueKind != JsonValueKind.Object) continue;
            var x = ReadFloat(item.Value, "x");
            var y = ReadFloat(item.Value, "y");
            offsets[item.Name] = new PointF(x, y);
        }

        return offsets;
    }

    private static int ReadInt(JsonElement item, string property)
    {
        if (!item.TryGetProperty(property, out var value) || value.ValueKind != JsonValueKind.Number) return 0;
        return (int)Math.Round(value.GetDouble());
    }

    private static float ReadFloat(JsonElement item, string property)
    {
        if (!item.TryGetProperty(property, out var value) || value.ValueKind != JsonValueKind.Number) return 0;
        return (float)value.GetDouble();
    }

    private void SendDisplayLayout()
    {
        Send(new
        {
            type = "displayLayout",
            platform = "windows",
            displays = Screen.AllScreens.Select(ScreenPayload).ToArray()
        });
    }

    private static object ScreenPayload(Screen screen)
    {
        return new
        {
            name = ScreenName(screen),
            x = screen.Bounds.X,
            y = screen.Bounds.Y,
            width = screen.Bounds.Width,
            height = screen.Bounds.Height,
            primary = screen.Primary
        };
    }

    private static string ScreenName(Screen screen)
    {
        var screens = Screen.AllScreens;
        var index = Array.FindIndex(screens, item =>
            item.DeviceName == screen.DeviceName &&
            item.Bounds == screen.Bounds
        );
        if (index < 0) index = 0;
        return $"{index + 1}{(screen.Primary ? "*" : "")} {screen.DeviceName}";
    }

    public bool SendClipboard(ClipboardPacket packet)
    {
        return Send(new
        {
            type = "clipboard",
            id = packet.Id,
            contentType = packet.ContentType,
            text = packet.Text,
            data = packet.DataBase64
        });
    }

    private bool Send(object payload)
    {
        if (_stream == null || _client?.Connected != true) return false;
        try
        {
            var json = JsonSerializer.Serialize(payload) + "\n";
            var bytes = Encoding.UTF8.GetBytes(json);
            lock (_sendLock)
            {
                _stream?.Write(bytes, 0, bytes.Length);
            }
            return true;
        }
        catch { return false; }
    }

    public void HandleRawMouseDelta(int dx, int dy)
    {
        if (dx == 0 && dy == 0) return;
        lock (_gate)
        {
            if (!_remoteActive || _stream == null || _client?.Connected != true) return;
            _rawMoves++;
            _statsWindowRawMoves++;
            _pendingDx += dx;
            _pendingDy += dy;
            _pendingRawCount++;
        }
        _sendSignal.Set();
    }

    private void SenderLoop()
    {
        var intervalTicks = Math.Max(1L, (long)(Stopwatch.Frequency * MouseFlushIntervalMs / 1000.0));
        var nextFlush = Stopwatch.GetTimestamp();

        while (_running)
        {
            var now = Stopwatch.GetTimestamp();
            if (now >= nextFlush)
            {
                FlushMouseDeltas();
                nextFlush = now + intervalTicks;
                continue;
            }

            var waitMs = Math.Max(1, (int)((nextFlush - now) * 1000 / Stopwatch.Frequency));
            _sendSignal.WaitOne(waitMs);
        }
    }

    private void FlushMouseDeltas()
    {
        int dx;
        int dy;
        int rawCount;
        lock (_gate)
        {
            if (!_running || !_remoteActive || _stream == null || _client?.Connected != true) return;
            dx = _pendingDx;
            dy = _pendingDy;
            if (dx == 0 && dy == 0) return;
            rawCount = _pendingRawCount;
            _pendingDx = 0;
            _pendingDy = 0;
            _pendingRawCount = 0;
            _sentMoves++;
            _statsWindowSentMoves++;
        }

        SendMove(dx, dy, rawCount);
        PublishStatsIfNeeded();
    }

    private void SendMove(int dx, int dy, int rawCount)
    {
        var udp = _udp;
        if (udp != null)
        {
            var now = Stopwatch.GetTimestamp();
            var senderGapUs = 0;
            if (_lastMoveSendTimestamp != 0)
            {
                senderGapUs = (int)Math.Clamp(
                    (now - _lastMoveSendTimestamp) * 1_000_000.0 / Stopwatch.Frequency,
                    0,
                    int.MaxValue
                );
            }
            _lastMoveSendTimestamp = now;
            var sequence = unchecked(++_moveSequence);

            Span<byte> packet = stackalloc byte[21];
            packet[0] = (byte)'M';
            BinaryPrimitives.WriteInt32LittleEndian(packet.Slice(1, 4), dx);
            BinaryPrimitives.WriteInt32LittleEndian(packet.Slice(5, 4), dy);
            BinaryPrimitives.WriteInt32LittleEndian(packet.Slice(9, 4), rawCount);
            BinaryPrimitives.WriteInt32LittleEndian(packet.Slice(13, 4), sequence);
            BinaryPrimitives.WriteInt32LittleEndian(packet.Slice(17, 4), senderGapUs);
            try
            {
                udp.Client.Send(packet);
                return;
            }
            catch { }
        }

        SendMoveLine(dx, dy, rawCount);
    }

    private static void ConfigureLowLatencySocket(Socket socket)
    {
        try { socket.NoDelay = true; } catch { }
        try { socket.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.TypeOfService, 0x10); } catch { }
        try { socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.DontLinger, true); } catch { }
    }

    private void SendMoveLine(int dx, int dy, int rawCount)
    {
        if (_stream == null || _client?.Connected != true) return;

        Span<byte> buffer = stackalloc byte[64];
        var offset = 0;
        AppendByte(buffer, ref offset, (byte)'m');
        AppendByte(buffer, ref offset, (byte)' ');
        AppendInt(buffer, ref offset, dx);
        AppendByte(buffer, ref offset, (byte)' ');
        AppendInt(buffer, ref offset, dy);
        AppendByte(buffer, ref offset, (byte)' ');
        AppendInt(buffer, ref offset, rawCount);
        AppendByte(buffer, ref offset, (byte)'\n');

        try
        {
            lock (_sendLock)
            {
                _stream?.Write(buffer[..offset]);
            }
        }
        catch { }
    }

    private static void AppendByte(Span<byte> buffer, ref int offset, byte value)
    {
        buffer[offset++] = value;
    }

    private static void AppendInt(Span<byte> buffer, ref int offset, int value)
    {
        if (Utf8Formatter.TryFormat(value, buffer[offset..], out var written))
        {
            offset += written;
        }
    }

    private void PublishStatsIfNeeded()
    {
        if (!LiveStatsEnabled) return;
        var now = DateTime.UtcNow;
        if ((now - _lastStatsAt).TotalMilliseconds < 1000) return;

        long raw;
        long sent;
        long clicks;
        long keys;
        long totalRaw;
        long totalSent;
        lock (_gate)
        {
            raw = _statsWindowRawMoves;
            sent = _statsWindowSentMoves;
            clicks = _clicks;
            keys = _keys;
            totalRaw = _rawMoves;
            totalSent = _sentMoves;
            _statsWindowRawMoves = 0;
            _statsWindowSentMoves = 0;
            _lastStatsAt = now;
        }

        StatsChanged?.Invoke($"Stats: raw {raw}/s, sent {sent}/s, total {totalRaw}/{totalSent}, clicks {clicks}, keys {keys}");
    }

    private void EdgeMonitorLoop()
    {
        while (_running)
        {
            try
            {
                string? reachedEdge;
                Point pos;
                lock (_gate)
                {
                    pos = Cursor.Position;
                    reachedEdge = !_remoteActive &&
                        !_controlledByMac &&
                        !_activationPending &&
                        DateTime.UtcNow >= _suppressActivationUntil &&
                        _stream != null &&
                        _client?.Connected == true
                            ? ReachedConfiguredEdge(pos.X, pos.Y)
                            : null;
                    if (reachedEdge != null) _activationPending = true;
                }

                if (reachedEdge != null)
                {
                    _uiThread?.BeginInvoke((MethodInvoker)(() => ActivateRemote(pos.X, pos.Y, reachedEdge)));
                    Thread.Sleep(120);
                }
                else
                {
                    Thread.Sleep(5);
                }
            }
            catch
            {
                Thread.Sleep(50);
            }
        }
    }

    private bool EdgeReached(int x, int y)
    {
        return ReachedOuterEdge(x, y) == _edge;
    }

    private string? ReachedConfiguredEdge(int x, int y)
    {
        var screen = Screen.FromPoint(new Point(x, y));
        var reached = ReachedOuterEdge(screen, x, y);
        if (reached != _edge) return null;
        return ArrangementAllowsExit(screen, reached) ? reached : null;
    }

    private static string? ReachedOuterEdge(int x, int y)
    {
        return ReachedOuterEdge(Screen.FromPoint(new Point(x, y)), x, y);
    }

    private static string? ReachedOuterEdge(Screen screen, int x, int y)
    {
        var bounds = screen.Bounds;
        if (x >= bounds.Right - 2 && !PointInsideAnyScreen(new Point(bounds.Right + 1, y))) return "right";
        if (x <= bounds.Left + 1 && !PointInsideAnyScreen(new Point(bounds.Left - 2, y))) return "left";
        if (y <= bounds.Top + 1 && !PointInsideAnyScreen(new Point(x, bounds.Top - 2))) return "top";
        if (y >= bounds.Bottom - 2 && !PointInsideAnyScreen(new Point(x, bounds.Bottom + 1))) return "bottom";
        return null;
    }

    private static bool PointInsideAnyScreen(Point point)
    {
        return Screen.AllScreens.Any(screen => screen.Bounds.Contains(point));
    }

    private bool ArrangementAllowsExit(Screen screen, string edge)
    {
        var windowsDisplays = Screen.AllScreens.Select(ScreenDisplayBox).ToList();
        var sourceDisplay = ScreenDisplayBox(screen);
        if (_remoteDisplays.Count == 0)
        {
            DebugLog($"arrangement fallback no-remote-displays edge={edge}");
            return true;
        }
        var boxes = ArrangementBoxes(windowsDisplays, _remoteDisplays, _machineOffsets);
        var source = boxes.FirstOrDefault(box =>
            box.Machine == "windows" &&
            box.Name == sourceDisplay.Name &&
            box.NativeBounds == sourceDisplay.Bounds
        );
        if (source == null)
        {
            DebugLog($"arrangement fallback no-source-match edge={edge} screen={sourceDisplay.Name}");
            return true;
        }

        var allowed = boxes.Any(box =>
            box.Machine == "mac" &&
            EdgeCandidate(box.VirtualBounds, edge, source.VirtualBounds)
        );
        if (!allowed)
        {
            var hasAnyAdjacent = boxes.Any(box =>
                box.Machine == "mac" &&
                HasAnyAdjacentEdge(box.VirtualBounds, source.VirtualBounds)
            );
            if (!hasAnyAdjacent)
            {
                DebugLog($"arrangement fallback invalid-adjacency edge={edge} screen={sourceDisplay.Name} macDisplays={_remoteDisplays.Count}");
                return true;
            }
            DebugLog($"arrangement blocked edge={edge} screen={sourceDisplay.Name} macDisplays={_remoteDisplays.Count}");
        }
        return allowed;
    }

    private static DisplayBox ScreenDisplayBox(Screen screen)
    {
        return new DisplayBox(ScreenName(screen), screen.Bounds, screen.Primary);
    }

    private static List<HostArrangementBox> ArrangementBoxes(
        IReadOnlyList<DisplayBox> windowsDisplays,
        IReadOnlyList<DisplayBox> macDisplays,
        IReadOnlyDictionary<string, PointF> machineOffsets
    )
    {
        var windowsWidth = GroupWidth(windowsDisplays, fallback: 2560);
        var boxes = new List<HostArrangementBox>();
        boxes.AddRange(DefaultFrames(macDisplays, "mac", 0));
        boxes.AddRange(DefaultFrames(windowsDisplays, "windows", -(windowsWidth + 220)));
        return boxes.Select(box => ApplyMachineOffset(box, machineOffsets)).ToList();
    }

    private static HostArrangementBox ApplyMachineOffset(
        HostArrangementBox box,
        IReadOnlyDictionary<string, PointF> machineOffsets
    )
    {
        if (!machineOffsets.TryGetValue(box.Machine, out var offset)) return box;
        return box with
        {
            VirtualBounds = new RectangleF(
                box.VirtualBounds.Left + offset.X,
                box.VirtualBounds.Top - offset.Y,
                box.VirtualBounds.Width,
                box.VirtualBounds.Height
            )
        };
    }

    private static IEnumerable<HostArrangementBox> DefaultFrames(
        IReadOnlyList<DisplayBox> displays,
        string machine,
        float xOffset
    )
    {
        if (displays.Count == 0) yield break;

        var union = displays.Skip(1).Aggregate(displays[0].Bounds, (acc, display) => Rectangle.Union(acc, display.Bounds));
        foreach (var display in displays)
        {
            var frame = new RectangleF(
                display.Bounds.Left - union.Left + xOffset,
                display.Bounds.Top - union.Top,
                display.Bounds.Width,
                display.Bounds.Height
            );
            yield return new HostArrangementBox(machine, display.Name, display.Bounds, frame);
        }
    }

    private static float GroupWidth(IReadOnlyList<DisplayBox> displays, float fallback)
    {
        if (displays.Count == 0) return fallback;
        return displays.Skip(1).Aggregate(displays[0].Bounds, (acc, display) => Rectangle.Union(acc, display.Bounds)).Width;
    }

    private static bool EdgeCandidate(RectangleF target, string edge, RectangleF source)
    {
        const float adjacencyTolerance = 24f;
        return edge switch
        {
            "left" => Math.Abs(source.Left - target.Right) <= adjacencyTolerance &&
                RangesOverlap(source.Top, source.Bottom, target.Top, target.Bottom),
            "right" => Math.Abs(target.Left - source.Right) <= adjacencyTolerance &&
                RangesOverlap(source.Top, source.Bottom, target.Top, target.Bottom),
            "top" => Math.Abs(source.Top - target.Bottom) <= adjacencyTolerance &&
                RangesOverlap(source.Left, source.Right, target.Left, target.Right),
            "bottom" => Math.Abs(target.Top - source.Bottom) <= adjacencyTolerance &&
                RangesOverlap(source.Left, source.Right, target.Left, target.Right),
            _ => false
        };
    }

    private static bool HasAnyAdjacentEdge(RectangleF target, RectangleF source)
    {
        return EdgeCandidate(target, "left", source) ||
            EdgeCandidate(target, "right", source) ||
            EdgeCandidate(target, "top", source) ||
            EdgeCandidate(target, "bottom", source);
    }

    private static bool RangesOverlap(float aMin, float aMax, float bMin, float bMax)
    {
        return Math.Min(aMax, bMax) - Math.Max(aMin, bMin) > 1f;
    }

    private sealed record HostArrangementBox(
        string Machine,
        string Name,
        Rectangle NativeBounds,
        RectangleF VirtualBounds
    );

    private void PinToEdge(bool force = false, double? xRatio = null, double? yRatio = null)
    {
        var now = Environment.TickCount64;
        if (!force && now - _lastPinAt < PinIntervalMs) return;

        var bounds = _activeScreenBounds.IsEmpty ? Screen.FromPoint(Cursor.Position).Bounds : _activeScreenBounds;
        var pos = Cursor.Position;
        if (xRatio.HasValue)
        {
            pos.X = bounds.Left + (int)Math.Round((bounds.Width - 1) * xRatio.Value);
        }
        if (yRatio.HasValue)
        {
            pos.Y = bounds.Top + (int)Math.Round((bounds.Height - 1) * yRatio.Value);
        }
        pos = _activeEdge switch
        {
            "right" => new Point(bounds.Right - 3, pos.Y),
            "left" => new Point(bounds.Left + 2, pos.Y),
            "top" => new Point(pos.X, bounds.Top + 2),
            "bottom" => new Point(pos.X, bounds.Bottom - 3),
            _ => pos
        };
        if (Cursor.Position != pos)
        {
            Cursor.Position = pos;
        }
        _lastPinAt = now;
        _lastPos = pos;
    }

    private void ActivateRemote(int x, int y, string edge)
    {
        if (_remoteActive || _controlledByMac || _stream == null || _client?.Connected != true)
        {
            lock (_gate) _activationPending = false;
            return;
        }
        if (!EnableRemoteCapture())
        {
            lock (_gate) _activationPending = false;
            return;
        }
        _activeEdge = edge;
        var screen = Screen.FromPoint(new Point(x, y));
        var bounds = screen.Bounds;
        var xRatio = bounds.Width <= 1 ? 0.5 : Math.Clamp((double)(x - bounds.Left) / bounds.Width, 0.0, 1.0);
        var yRatio = bounds.Height <= 1 ? 0.5 : Math.Clamp((double)(y - bounds.Top) / bounds.Height, 0.0, 1.0);
        _activeScreenBounds = bounds;
        _remoteActive = true;
        _activationPending = false;
        _lastPos = new Point(x, y);
        DebugLog($"remote active edge={_activeEdge} x={x} y={y}");
        Send(new { type = "activate", edge = _activeEdge, xRatio, yRatio, screen = ScreenPayload(screen) });
        PinToEdge(force: true);
        StatusChanged?.Invoke("Mac control");
    }

    private void ReleaseToWindows(double? xRatio = null, double? yRatio = null)
    {
        lock (_gate)
        {
            _remoteActive = false;
            _activationPending = false;
            _suppressActivationUntil = DateTime.UtcNow.AddMilliseconds(350);
            _lastPos = null;
            PinToEdge(force: true, xRatio: xRatio, yRatio: yRatio);
            _activeScreenBounds = Rectangle.Empty;
            _activeEdge = _edge;
        }
        DisableRemoteCapture();
        DebugLog("windows control");
        StatusChanged?.Invoke("Windows control");
    }

    private void ActivateFromMac(string edge, double xRatio, double yRatio, DisplayBox? sourceDisplay)
    {
        if (_remoteActive) return;

        var targetScreen = ResolveWindowsTargetScreen(edge, sourceDisplay);
        var bounds = targetScreen.Bounds;
        var entryPoint = EntryPoint(bounds, edge, xRatio, yRatio);
        _controlledByMac = true;
        _targetReturnEdge = OppositeEdge(edge);
        _targetScreenBounds = bounds;
        _suppressActivationUntil = DateTime.UtcNow.AddMilliseconds(350);
        Cursor.Position = entryPoint;
        DebugLog($"windows target active edge={edge} return={_targetReturnEdge} x={entryPoint.X} y={entryPoint.Y}");
        StatusChanged?.Invoke("Controlled from Mac");
    }

    private Screen ResolveWindowsTargetScreen(string edge, DisplayBox? sourceDisplay)
    {
        var screens = Screen.AllScreens;
        if (screens.Length == 1) return screens[0];
        if (sourceDisplay == null || _remoteDisplays.Count == 0) return screens.FirstOrDefault(screen => screen.Primary) ?? screens[0];

        var localDisplays = screens.Select(ScreenDisplayBox).ToList();
        var boxes = ArrangementBoxes(localDisplays, _remoteDisplays, _machineOffsets);
        var source = boxes.FirstOrDefault(box =>
            box.Machine == "mac" &&
            box.Name == sourceDisplay.Name &&
            box.NativeBounds == sourceDisplay.Bounds
        );
        if (source == null) return screens.FirstOrDefault(screen => screen.Primary) ?? screens[0];

        var target = boxes
            .Where(box => box.Machine == "windows" && EdgeCandidate(box.VirtualBounds, edge, source.VirtualBounds))
            .OrderBy(box => box.NativeBounds.Width * box.NativeBounds.Height)
            .LastOrDefault();
        if (target == null) return screens.FirstOrDefault(screen => screen.Primary) ?? screens[0];

        return screens.FirstOrDefault(screen =>
            ScreenName(screen) == target.Name &&
            screen.Bounds == target.NativeBounds
        ) ?? screens.FirstOrDefault(screen => screen.Primary) ?? screens[0];
    }

    private static Point EntryPoint(Rectangle bounds, string edge, double xRatio, double yRatio)
    {
        const int inset = 24;
        return edge switch
        {
            "left" => new Point(bounds.Left + inset, bounds.Top + (int)Math.Round((bounds.Height - 1) * yRatio)),
            "right" => new Point(bounds.Right - inset, bounds.Top + (int)Math.Round((bounds.Height - 1) * yRatio)),
            "top" => new Point(bounds.Left + (int)Math.Round((bounds.Width - 1) * xRatio), bounds.Top + inset),
            "bottom" => new Point(bounds.Left + (int)Math.Round((bounds.Width - 1) * xRatio), bounds.Bottom - inset),
            _ => new Point(bounds.Left + inset, bounds.Top + inset)
        };
    }

    private static string OppositeEdge(string edge) => edge switch
    {
        "left" => "right",
        "right" => "left",
        "top" => "bottom",
        "bottom" => "top",
        _ => edge
    };

    private void ApplyRemoteMove(int dx, int dy)
    {
        if (!_controlledByMac) return;
        var bounds = _targetScreenBounds.IsEmpty ? Screen.FromPoint(Cursor.Position).Bounds : _targetScreenBounds;
        var current = Cursor.Position;
        var next = new Point(
            Math.Clamp(current.X + dx, bounds.Left, bounds.Right - 1),
            Math.Clamp(current.Y + dy, bounds.Top, bounds.Bottom - 1)
        );
        Cursor.Position = next;
        if (TargetReachedReturnEdge(next, bounds, _targetReturnEdge))
        {
            var xRatio = bounds.Width <= 1 ? 0.5 : Math.Clamp((double)(next.X - bounds.Left) / bounds.Width, 0.0, 1.0);
            var yRatio = bounds.Height <= 1 ? 0.5 : Math.Clamp((double)(next.Y - bounds.Top) / bounds.Height, 0.0, 1.0);
            _controlledByMac = false;
            _targetScreenBounds = Rectangle.Empty;
            DebugLog($"release to mac edge={_targetReturnEdge} x={next.X} y={next.Y}");
            Send(new { type = "release", edge = _targetReturnEdge, xRatio, yRatio });
            StatusChanged?.Invoke("Windows control");
        }
    }

    private static bool TargetReachedReturnEdge(Point point, Rectangle bounds, string edge)
    {
        return edge switch
        {
            "left" => point.X <= bounds.Left + 1,
            "right" => point.X >= bounds.Right - 2,
            "top" => point.Y <= bounds.Top + 1,
            "bottom" => point.Y >= bounds.Bottom - 2,
            _ => false
        };
    }

    private static void InjectMouseButton(string button, bool down)
    {
        var flags = button switch
        {
            "left" => down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP,
            "right" => down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP,
            "middle" => down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP,
            "back" => down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP,
            "forward" => down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP,
            _ => 0u
        };
        if (flags == 0) return;
        var data = button switch
        {
            "back" => XBUTTON1,
            "forward" => XBUTTON2,
            _ => 0
        };
        var inputs = new[] { INPUT.Mouse(flags, data, 0, 0) };
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    private static void InjectScroll(int dx, int dy)
    {
        var count = (dx != 0 && dy != 0) ? 2 : 1;
        var inputs = new INPUT[2];
        var index = 0;
        if (dy != 0)
        {
            inputs[index++] = INPUT.Mouse(MOUSEEVENTF_WHEEL, dy * 120, 0, 0);
        }
        if (dx != 0)
        {
            inputs[index++] = INPUT.Mouse(MOUSEEVENTF_HWHEEL, dx * 120, 0, 0);
        }
        SendInput((uint)count, inputs, Marshal.SizeOf<INPUT>());
    }

    private static void InjectKey(string name, bool down)
    {
        if (!VirtualKey(name, out var vk)) return;
        var flags = down ? 0u : KEYEVENTF_KEYUP;
        var inputs = new[] { INPUT.Keyboard(vk, 0, flags) };
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    private IntPtr MouseHook(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < 0) return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
        var info = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam);
        var x = info.pt.x;
        var y = info.pt.y;
        var message = wParam.ToInt32();
        var injected = (info.flags & LLMHF_INJECTED) != 0;

        lock (_gate)
        {
            if (!_remoteActive)
            {
                _lastPos = new Point(x, y);
                return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
            }

            if (message == WM_MOUSEMOVE)
            {
                if (injected) return 1;
                _lastPos = new Point(x, y);
            }
            else if (message is WM_LBUTTONDOWN or WM_LBUTTONUP)
            {
                Send(new { type = "button", button = "left", down = message == WM_LBUTTONDOWN });
                if (message == WM_LBUTTONDOWN) _clicks++;
            }
            else if (message is WM_RBUTTONDOWN or WM_RBUTTONUP)
            {
                Send(new { type = "button", button = "right", down = message == WM_RBUTTONDOWN });
                if (message == WM_RBUTTONDOWN) _clicks++;
            }
            else if (message is WM_MBUTTONDOWN or WM_MBUTTONUP)
            {
                Send(new { type = "button", button = "middle", down = message == WM_MBUTTONDOWN });
                if (message == WM_MBUTTONDOWN) _clicks++;
            }
            else if (message is WM_XBUTTONDOWN or WM_XBUTTONUP)
            {
                var button = HighWordSigned(info.mouseData) == XBUTTON2 ? "forward" : "back";
                Send(new { type = "button", button, down = message == WM_XBUTTONDOWN });
                if (message == WM_XBUTTONDOWN) _clicks++;
            }
            else if (message == WM_MOUSEWHEEL)
            {
                Send(new { type = "scroll", dx = 0, dy = HighWordSigned(info.mouseData) / 120 });
            }
            else if (message == WM_MOUSEHWHEEL)
            {
                Send(new { type = "scroll", dx = HighWordSigned(info.mouseData) / 120, dy = 0 });
            }
        }
        return 1;
    }

    private IntPtr KeyboardHook(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < 0) return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
        var info = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
        var message = wParam.ToInt32();
        var down = message is WM_KEYDOWN or WM_SYSKEYDOWN;
        var up = message is WM_KEYUP or WM_SYSKEYUP;
        if (!down && !up) return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);

        if (info.vkCode is 0x11 or 0xA2 or 0xA3) _ctrl = down;
        if (info.vkCode is 0x12 or 0xA4 or 0xA5) _alt = down;
        if (down && _ctrl && _alt && info.vkCode == 0x08)
        {
            Stop();
            return 1;
        }

        lock (_gate)
        {
            if (_remoteActive)
            {
                var name = KeyName(info.vkCode);
                DebugLog($"key hook remote vk={info.vkCode} name={name ?? "-"} down={down} up={up}");
                if (name != null)
                {
                    var text = down ? KeyboardText.FromKey(info.vkCode, info.scanCode) : null;
                    var layout = KeyboardText.CurrentLayoutName();
                    Send(new {
                        type = "key",
                        key = name,
                        down,
                        text,
                        vk = info.vkCode,
                        scan = info.scanCode,
                        layout,
                        shift = IsKeyDown(0x10),
                        ctrl = IsKeyDown(0x11),
                        alt = IsKeyDown(0x12),
                        caps = IsKeyToggled(0x14)
                    });
                    DebugLog($"key sent name={name} down={down} text={text ?? "-"}");
                    if (down) _keys++;
                    PublishStatsIfNeeded();
                }
                return 1;
            }
        }
        return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
    }

    private void InstallHooks()
    {
        if (_mouseHook != IntPtr.Zero && _keyboardHook != IntPtr.Zero) return;
        InstallMouseHook();
        if (!InstallKeyboardHook())
        {
            throw new InvalidOperationException("Could not install input hooks. Run as Administrator.");
        }
    }

    private void InstallMouseHook()
    {
        if (_mouseHook != IntPtr.Zero) return;
        _mouseHook = SetWindowsHookEx(WH_MOUSE_LL, _mouseProc, GetModuleHandle(null), 0);
        if (_mouseHook == IntPtr.Zero)
        {
            throw new InvalidOperationException("Could not install mouse hook. Run as Administrator.");
        }
    }

    private bool InstallKeyboardHook()
    {
        if (_keyboardHook != IntPtr.Zero) return true;
        _keyboardHook = SetWindowsHookEx(WH_KEYBOARD_LL, _keyboardProc, GetModuleHandle(null), 0);
        if (_keyboardHook != IntPtr.Zero)
        {
            DebugLog("keyboard hook installed");
            return true;
        }
        var error = Marshal.GetLastWin32Error();
        DebugLog($"keyboard hook failed error={error}");
        StatusChanged?.Invoke("Could not install keyboard hook. Run as Administrator.");
        return false;
    }

    private bool EnableRemoteCapture()
    {
        try
        {
            InstallMouseHook();
            if (!InstallKeyboardHook()) return false;
            _rawMousePump ??= new RawMousePump(HandleRawMouseDelta);
            _rawMousePump.Start();
            return true;
        }
        catch (Exception ex)
        {
            StatusChanged?.Invoke(ex.Message);
            DisableRemoteCapture();
            return false;
        }
    }

    private void DisableRemoteCapture()
    {
        UninstallMouseHook();
        _rawMousePump?.Dispose();
        _rawMousePump = null;
    }

    private void UninstallHooks()
    {
        UninstallMouseHook();
        if (_keyboardHook != IntPtr.Zero) UnhookWindowsHookEx(_keyboardHook);
        _keyboardHook = IntPtr.Zero;
    }

    private void UninstallMouseHook()
    {
        if (_mouseHook != IntPtr.Zero) UnhookWindowsHookEx(_mouseHook);
        _mouseHook = IntPtr.Zero;
    }

    private static void DebugLog(string message)
    {
        try
        {
            File.AppendAllText(InputLogPath, $"{DateTimeOffset.Now:O} {message}{Environment.NewLine}");
        }
        catch { }
    }

    private static short HighWordSigned(uint value) => unchecked((short)((value >> 16) & 0xffff));

    private static string? KeyName(uint vk)
    {
        if (vk is >= 0x30 and <= 0x39) return ((char)vk).ToString().ToLowerInvariant();
        if (vk is >= 0x41 and <= 0x5A) return ((char)vk).ToString().ToLowerInvariant();
        return vk switch
        {
            0x08 => "backspace", 0x09 => "tab", 0x0D => "enter", 0x1B => "escape",
            0x20 => "space", 0x21 => "page_up", 0x22 => "page_down", 0x23 => "end",
            0x24 => "home", 0x25 => "left", 0x26 => "up", 0x27 => "right",
            0x28 => "down", 0x2E => "delete", 0x10 or 0xA0 => "shift",
            0xA1 => "right_shift", 0x11 or 0xA2 => "ctrl", 0xA3 => "right_ctrl",
            0x12 or 0xA4 => "alt", 0xA5 => "right_alt",
            0x14 => "caps_lock", 0x5B or 0x5C => "cmd",
            0x70 => "f1", 0x71 => "f2", 0x72 => "f3", 0x73 => "f4",
            0x74 => "f5", 0x75 => "f6", 0x76 => "f7", 0x77 => "f8",
            0x78 => "f9", 0x79 => "f10", 0x7A => "f11", 0x7B => "f12",
            0xBA => ";", 0xBB => "=", 0xBC => ",", 0xBD => "-",
            0xBE => ".", 0xBF => "/", 0xC0 => "`", 0xDB => "[", 0xDC => "\\",
            0xDD => "]", 0xDE => "'", _ => null
        };
    }

    private static bool VirtualKey(string name, out ushort vk)
    {
        vk = name switch
        {
            "a" => 0x41, "b" => 0x42, "c" => 0x43, "d" => 0x44, "e" => 0x45, "f" => 0x46,
            "g" => 0x47, "h" => 0x48, "i" => 0x49, "j" => 0x4A, "k" => 0x4B, "l" => 0x4C,
            "m" => 0x4D, "n" => 0x4E, "o" => 0x4F, "p" => 0x50, "q" => 0x51, "r" => 0x52,
            "s" => 0x53, "t" => 0x54, "u" => 0x55, "v" => 0x56, "w" => 0x57, "x" => 0x58,
            "y" => 0x59, "z" => 0x5A,
            "0" => 0x30, "1" => 0x31, "2" => 0x32, "3" => 0x33, "4" => 0x34,
            "5" => 0x35, "6" => 0x36, "7" => 0x37, "8" => 0x38, "9" => 0x39,
            "backspace" => 0x08, "tab" => 0x09, "enter" => 0x0D, "escape" => 0x1B,
            "space" => 0x20, "page_up" => 0x21, "page_down" => 0x22, "end" => 0x23,
            "home" => 0x24, "left" => 0x25, "up" => 0x26, "right" => 0x27,
            "down" => 0x28, "delete" => 0x2E, "shift" => 0x10, "right_shift" => 0xA1,
            "ctrl" => 0x11, "right_ctrl" => 0xA3, "alt" => 0x12, "right_alt" => 0xA5,
            "caps_lock" => 0x14, "cmd" => 0x5B, "f1" => 0x70, "f2" => 0x71,
            "f3" => 0x72, "f4" => 0x73, "f5" => 0x74, "f6" => 0x75, "f7" => 0x76,
            "f8" => 0x77, "f9" => 0x78, "f10" => 0x79, "f11" => 0x7A, "f12" => 0x7B,
            ";" => 0xBA, "=" => 0xBB, "," => 0xBC, "-" => 0xBD, "." => 0xBE,
            "/" => 0xBF, "`" => 0xC0, "[" => 0xDB, "\\" => 0xDC, "]" => 0xDD, "'" => 0xDE,
            _ => 0
        };
        return vk != 0;
    }

    private delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);
    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int x; public int y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSLLHOOKSTRUCT
    {
        public POINT pt;
        public uint mouseData;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public INPUTUNION U;

        public static INPUT Mouse(uint flags, int mouseData, uint time, nuint extraInfo)
        {
            return new INPUT
            {
                type = 0,
                U = new INPUTUNION
                {
                    mi = new MOUSEINPUT
                    {
                        dx = 0,
                        dy = 0,
                        mouseData = mouseData,
                        dwFlags = flags,
                        time = time,
                        dwExtraInfo = extraInfo
                    }
                }
            };
        }

        public static INPUT Keyboard(ushort vk, ushort scan, uint flags)
        {
            return new INPUT
            {
                type = 1,
                U = new INPUTUNION
                {
                    ki = new KEYBDINPUT
                    {
                        wVk = vk,
                        wScan = scan,
                        dwFlags = flags,
                        time = 0,
                        dwExtraInfo = 0
                    }
                }
            };
        }
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct INPUTUNION
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public int mouseData;
        public uint dwFlags;
        public uint time;
        public nuint dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public nuint dwExtraInfo;
    }

    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    private const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    private const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
    private const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
    private const uint MOUSEEVENTF_WHEEL = 0x0800;
    private const uint MOUSEEVENTF_HWHEEL = 0x1000;
    private const uint MOUSEEVENTF_XDOWN = 0x0080;
    private const uint MOUSEEVENTF_XUP = 0x0100;
    private const uint KEYEVENTF_KEYUP = 0x0002;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, Delegate lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string? lpModuleName);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(
        uint cInputs,
        [MarshalAs(UnmanagedType.LPArray), In] INPUT[] pInputs,
        int cbSize
    );

    [DllImport("winmm.dll")]
    private static extern uint timeBeginPeriod(uint uPeriod);

    [DllImport("winmm.dll")]
    private static extern uint timeEndPeriod(uint uPeriod);

    private static bool IsKeyDown(int vk) => (GetKeyState(vk) & 0x8000) != 0;

    private static bool IsKeyToggled(int vk) => (GetKeyState(vk) & 0x0001) != 0;

    [DllImport("user32.dll")]
    private static extern short GetKeyState(int nVirtKey);
}

internal static class KeyboardText
{
    public static string? FromKey(uint vk, uint scanCode)
    {
        if (IsControlLike(vk)) return null;

        var keyboardState = new byte[256];
        if (!GetKeyboardState(keyboardState)) return null;

        var buffer = new StringBuilder(8);
        var layout = GetKeyboardLayout(0);
        var result = ToUnicodeEx(vk, scanCode, keyboardState, buffer, buffer.Capacity, 0, layout);
        if (result <= 0) return null;

        return buffer.ToString(0, Math.Min(result, buffer.Length));
    }

    public static string CurrentLayoutName()
    {
        var layout = GetKeyboardLayout(0);
        var lowWord = ((long)layout) & 0xffff;
        try
        {
            return new CultureInfo((int)lowWord).Name;
        }
        catch
        {
            return $"hkl:{layout.ToInt64():x}";
        }
    }

    private static bool IsControlLike(uint vk)
    {
        return vk switch
        {
            0x08 or 0x09 or 0x0D or 0x10 or 0x11 or 0x12 or 0x14 or 0x1B or 0x21 or 0x22 or 0x23 or 0x24 or
            0x25 or 0x26 or 0x27 or 0x28 or 0x2E or 0x5B or 0x5C or >= 0x70 and <= 0x7B => true,
            _ => false
        };
    }

    [DllImport("user32.dll")]
    private static extern bool GetKeyboardState(byte[] lpKeyState);

    [DllImport("user32.dll")]
    private static extern IntPtr GetKeyboardLayout(uint idThread);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int ToUnicodeEx(
        uint wVirtKey,
        uint wScanCode,
        byte[] lpKeyState,
        [Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pwszBuff,
        int cchBuff,
        uint wFlags,
        IntPtr dwhkl
    );
}

internal sealed class RawMousePump : IDisposable
{
    private readonly Action<int, int> _onDelta;
    private readonly ManualResetEventSlim _ready = new(false);
    private Thread? _thread;
    private RawMouseWindow? _window;
    private volatile bool _disposed;

    public RawMousePump(Action<int, int> onDelta)
    {
        _onDelta = onDelta;
    }

    public void Start()
    {
        _thread = new Thread(Run)
        {
            IsBackground = true,
            Priority = ThreadPriority.Highest,
            Name = "Portal raw mouse input"
        };
        _thread.SetApartmentState(ApartmentState.STA);
        _thread.Start();
        _ready.Wait(TimeSpan.FromSeconds(2));
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        try
        {
            var window = _window;
            if (window != null && window.IsHandleCreated)
            {
                window.BeginInvoke((MethodInvoker)(() => window.Close()));
            }
        }
        catch { }
        try { _thread?.Join(1500); } catch { }
        _ready.Dispose();
    }

    private void Run()
    {
        try
        {
            Application.SetHighDpiMode(HighDpiMode.SystemAware);
        }
        catch { }

        var window = new RawMouseWindow(_onDelta);
        _window = window;
        _ready.Set();
        Application.Run(window);
    }

    private sealed class RawMouseWindow : Form
    {
        private const int WM_INPUT = 0x00FF;
        private readonly Action<int, int> _onDelta;

        public RawMouseWindow(Action<int, int> onDelta)
        {
            _onDelta = onDelta;
            Text = "Portal Raw Input";
            ShowInTaskbar = false;
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            Location = new Point(-32000, -32000);
            Size = new Size(1, 1);
            Opacity = 0;
            Load += (_, _) => Hide();
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            RawMouseInput.Register(Handle);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_INPUT && RawMouseInput.TryGetDelta(m.LParam, out var dx, out var dy))
            {
                _onDelta(dx, dy);
            }
            base.WndProc(ref m);
        }
    }
}

internal static class RawMouseInput
{
    private const int RIM_TYPEMOUSE = 0;
    private const int RID_INPUT = 0x10000003;
    private const int RIDEV_INPUTSINK = 0x00000100;
    private const ushort HID_USAGE_PAGE_GENERIC = 0x01;
    private const ushort HID_USAGE_GENERIC_MOUSE = 0x02;

    public static void Register(IntPtr hwnd)
    {
        var device = new RAWINPUTDEVICE
        {
            usUsagePage = HID_USAGE_PAGE_GENERIC,
            usUsage = HID_USAGE_GENERIC_MOUSE,
            dwFlags = RIDEV_INPUTSINK,
            hwndTarget = hwnd
        };

        if (!RegisterRawInputDevices([device], 1, Marshal.SizeOf<RAWINPUTDEVICE>()))
        {
            throw new InvalidOperationException("Could not register raw mouse input.");
        }
    }

    public static bool TryGetDelta(IntPtr lParam, out int dx, out int dy)
    {
        dx = 0;
        dy = 0;

        uint size = 0;
        GetRawInputData(lParam, RID_INPUT, IntPtr.Zero, ref size, (uint)Marshal.SizeOf<RAWINPUTHEADER>());
        if (size == 0) return false;

        var buffer = Marshal.AllocHGlobal((int)size);
        try
        {
            var read = GetRawInputData(lParam, RID_INPUT, buffer, ref size, (uint)Marshal.SizeOf<RAWINPUTHEADER>());
            if (read == 0 || read == uint.MaxValue) return false;

            var input = Marshal.PtrToStructure<RAWINPUT>(buffer);
            if (input.header.dwType != RIM_TYPEMOUSE) return false;

            dx = input.mouse.lLastX;
            dy = input.mouse.lLastY;
            return dx != 0 || dy != 0;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RAWINPUTDEVICE
    {
        public ushort usUsagePage;
        public ushort usUsage;
        public int dwFlags;
        public IntPtr hwndTarget;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RAWINPUTHEADER
    {
        public int dwType;
        public int dwSize;
        public IntPtr hDevice;
        public IntPtr wParam;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RAWMOUSE
    {
        public ushort usFlags;
        public uint ulButtons;
        public uint ulRawButtons;
        public int lLastX;
        public int lLastY;
        public uint ulExtraInformation;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RAWINPUT
    {
        public RAWINPUTHEADER header;
        public RAWMOUSE mouse;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterRawInputDevices(
        [MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] RAWINPUTDEVICE[] pRawInputDevices,
        uint uiNumDevices,
        int cbSize
    );

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetRawInputData(
        IntPtr hRawInput,
        uint uiCommand,
        IntPtr pData,
        ref uint pcbSize,
        uint cbSizeHeader
    );
}
