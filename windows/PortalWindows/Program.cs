using System.Buffers.Text;
using System.Buffers.Binary;
using System.Diagnostics;
using System.Drawing.Imaging;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Globalization;

namespace PortalWindows;

internal static class PortalTheme
{
    public static readonly Color Window = Color.FromArgb(24, 27, 25);
    public static readonly Color Panel = Color.FromArgb(30, 34, 31);
    public static readonly Color PanelAlt = Color.FromArgb(22, 24, 23);
    public static readonly Color Border = Color.FromArgb(64, 72, 66);
    public static readonly Color Grid = Color.FromArgb(44, 54, 49);
    public static readonly Color Text = Color.FromArgb(232, 235, 231);
    public static readonly Color Muted = Color.FromArgb(154, 162, 154);
    public static readonly Color Accent = Color.FromArgb(72, 139, 255);
    public static readonly Color Mac = Color.FromArgb(38, 166, 91);
    public static readonly Color Windows = Color.FromArgb(204, 118, 38);
    public static readonly Color WindowsSecondary = Color.FromArgb(180, 67, 199);
}

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        try { Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.High; } catch { }
        ApplicationConfiguration.Initialize();
        Application.Run(new MainForm());
    }
}

public sealed class MainForm : Form
{
    private readonly TabControl _tabs = new() { Dock = DockStyle.Fill };
    private readonly TabPage _controlTab = new("Control");
    private readonly TabPage _arrangementTab = new("Arrangement");
    private readonly TextBox _ipBox = new() { Text = "192.168.1.12", Width = 180 };
    private readonly NumericUpDown _portBox = new() { Minimum = 1, Maximum = 65535, Value = 45877, Width = 90 };
    private readonly ComboBox _edgeBox = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 90 };
    private readonly Label _status = new() { AutoSize = true, Text = "Stopped" };
    private readonly Label _stats = new() { AutoSize = true, Text = "Stats: idle" };
    private readonly Label _displayInfo = new() { AutoSize = false, Text = "Displays: checking...", Width = 620, Height = 48 };
    private readonly Label _clipboardStatus = new() { AutoSize = false, Text = "Clipboard: starting...", Width = 620, Height = 28 };
    private readonly Label _arrangementInfo = new() { AutoSize = false, Text = "Arrangement: checking...", Left = 24, Top = 58, Width = 900, Height = 42, Anchor = AnchorStyles.Left | AnchorStyles.Top | AnchorStyles.Right };
    private readonly Button _fitArrangement = new() { Text = "Fit", Left = 24, Top = 108, Width = 72 };
    private readonly Button _zoomOutArrangement = new() { Text = "-", Left = 104, Top = 108, Width = 40 };
    private readonly Button _zoomInArrangement = new() { Text = "+", Left = 152, Top = 108, Width = 40 };
    private readonly Button _actualArrangement = new() { Text = "100%", Left = 200, Top = 108, Width = 64 };
    private readonly DisplayArrangementControl _arrangementView = new() { Left = 24, Top = 148, Width = 900, Height = 492, Anchor = AnchorStyles.Left | AnchorStyles.Top | AnchorStyles.Right | AnchorStyles.Bottom };
    private readonly Button _start = new() { Text = "Start", Width = 110 };
    private readonly System.Windows.Forms.Timer _clipboardTimer = new() { Interval = 700 };
    private readonly NotifyIcon _trayIcon = new();
    private readonly ContextMenuStrip _trayMenu = new();
    private readonly ToolStripMenuItem _trayStatus = new("Status: Stopped") { Enabled = false };
    private readonly ToolStripMenuItem _trayShow = new("Show Portal");
    private readonly ToolStripMenuItem _trayStartStop = new("Start");
    private readonly ToolStripMenuItem _trayQuit = new("Quit Portal");
    private PortalHost? _host;
    private bool _autoStarted;
    private bool _allowExit;
    private string? _lastClipboardSignature;
    private string? _lastAppliedClipboardSignature;
    private bool _applyingClipboard;

    public MainForm()
    {
        Text = "Portal";
        ClientSize = new Size(960, 700);
        MinimumSize = new Size(760, 560);
        FormBorderStyle = FormBorderStyle.Sizable;
        MaximizeBox = true;
        Font = new Font("Segoe UI", 9F, FontStyle.Regular);
        BackColor = PortalTheme.Window;
        ForeColor = PortalTheme.Text;
        ApplyTheme(this);
        ConfigureTabs();
        _tabs.TabPages.Add(_controlTab);
        _tabs.TabPages.Add(_arrangementTab);
        Controls.Add(_tabs);
        ConfigureTray();

        _edgeBox.Items.AddRange(["right", "left", "top", "bottom"]);
        _edgeBox.SelectedItem = "left";
        LoadSettings();

        var title = new Label { Text = "Windows Host", AutoSize = true, Font = new Font(Font.FontFamily, 16F, FontStyle.Bold), Top = 24, Left = 24 };
        _controlTab.Controls.Add(title);
        AddRow("Mac IP", _ipBox, 62);
        AddRow("Port", _portBox, 96);
        AddRow("Exit edge", _edgeBox, 130);

        _start.Left = 134;
        _start.Top = 164;
        _start.Click += Toggle;
        _controlTab.Controls.Add(_start);

        _status.Left = 254;
        _status.Top = 170;
        _controlTab.Controls.Add(_status);

        _stats.Left = 24;
        _stats.Top = 210;
        _stats.Width = 450;
        _controlTab.Controls.Add(_stats);

        _displayInfo.Left = 24;
        _displayInfo.Top = 250;
        RefreshDisplayInfo();
        _controlTab.Controls.Add(_displayInfo);

        _clipboardStatus.Left = 24;
        _clipboardStatus.Top = 306;
        _clipboardStatus.Text = "Clipboard: text and images ready";
        _controlTab.Controls.Add(_clipboardStatus);

        var arrangementTitle = new Label { Text = "Monitor Arrangement", AutoSize = true, Font = new Font(Font.FontFamily, 15F, FontStyle.Bold), Left = 24, Top = 26 };
        _arrangementTab.Controls.Add(arrangementTitle);
        _arrangementTab.Controls.Add(_arrangementInfo);
        _fitArrangement.Click += (_, _) => _arrangementView.FitToContent();
        _zoomOutArrangement.Click += (_, _) => _arrangementView.ZoomOut();
        _zoomInArrangement.Click += (_, _) => _arrangementView.ZoomIn();
        _actualArrangement.Click += (_, _) => _arrangementView.ActualSize();
        _arrangementTab.Controls.Add(_fitArrangement);
        _arrangementTab.Controls.Add(_zoomOutArrangement);
        _arrangementTab.Controls.Add(_zoomInArrangement);
        _arrangementTab.Controls.Add(_actualArrangement);
        _arrangementTab.Controls.Add(_arrangementView);

        ApplyTheme(this);

        Shown += (_, _) => AutoStartOnce();
        _clipboardTimer.Tick += (_, _) => PublishLocalClipboardIfChanged();
        _clipboardTimer.Start();
    }

    private void ConfigureTray()
    {
        _trayIcon.Text = "Portal";
        _trayIcon.Icon = SystemIcons.Application;
        _trayIcon.Visible = true;
        _trayIcon.DoubleClick += (_, _) => ShowPortalWindow();

        _trayShow.Click += (_, _) => ShowPortalWindow();
        _trayStartStop.Click += Toggle;
        _trayQuit.Click += (_, _) =>
        {
            _allowExit = true;
            Close();
        };

        _trayMenu.Items.Add(_trayStatus);
        _trayMenu.Items.Add(new ToolStripSeparator());
        _trayMenu.Items.Add(_trayShow);
        _trayMenu.Items.Add(_trayStartStop);
        _trayMenu.Items.Add(new ToolStripSeparator());
        _trayMenu.Items.Add(_trayQuit);
        _trayIcon.ContextMenuStrip = _trayMenu;
        UpdateTrayItems();
    }

    private void ConfigureTabs()
    {
        _tabs.DrawMode = TabDrawMode.OwnerDrawFixed;
        _tabs.ItemSize = new Size(128, 34);
        _tabs.SizeMode = TabSizeMode.Fixed;
        _tabs.Appearance = TabAppearance.Normal;
        _tabs.DrawItem += (_, e) =>
        {
            var selected = e.Index == _tabs.SelectedIndex;
            var rect = e.Bounds;
            rect.Inflate(-5, -5);
            using var fill = new SolidBrush(selected ? PortalTheme.Accent : PortalTheme.Panel);
            using var tabFont = new Font(Font.FontFamily, 9F, FontStyle.Bold);
            e.Graphics.FillRectangle(fill, rect);
            TextRenderer.DrawText(
                e.Graphics,
                _tabs.TabPages[e.Index].Text,
                tabFont,
                rect,
                selected ? Color.White : PortalTheme.Muted,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter
            );
        };
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

        _host = new PortalHost(_ipBox.Text.Trim(), (int)_portBox.Value, _edgeBox.Text);
        SaveSettings();
        _host.StatusChanged += text => BeginInvoke((MethodInvoker)(() => SetStatus(text)));
        _host.StatsChanged += text => BeginInvoke((MethodInvoker)(() => _stats.Text = text));
        _host.ClipboardReceived += packet => BeginInvoke((MethodInvoker)(() => ApplyRemoteClipboard(packet)));
        _host.ArrangementOffsetsChanged += offsets => BeginInvoke((MethodInvoker)(() =>
        {
            _arrangementView.MachineOffsets = offsets;
            UpdateArrangementInfo();
        }));
        _host.RemoteDisplaysChanged += displays => BeginInvoke((MethodInvoker)(() =>
        {
            _arrangementView.MacDisplays = displays;
            UpdateArrangementInfo();
        }));
        _host.Stopped += () => BeginInvoke((MethodInvoker)(() =>
        {
            _host = null;
            UpdateTrayItems();
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

    private void ShowPortalWindow()
    {
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
        _trayStartStop.Text = running ? "Stop" : "Start";
    }

    private void AutoStartOnce()
    {
        RefreshDisplayInfo();
        if (_autoStarted) return;
        _autoStarted = true;
        if (_host == null)
        {
            Toggle(this, EventArgs.Empty);
        }
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!_allowExit && e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Hide();
            ShowInTaskbar = false;
            return;
        }

        _clipboardTimer.Stop();
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
                _clipboardStatus.Text = "Clipboard: received image";
            }
            else
            {
                return;
            }

            _lastAppliedClipboardSignature = signature;
            _lastClipboardSignature = signature;
        }
        catch
        {
            _clipboardStatus.Text = "Clipboard: update failed";
        }
        finally
        {
            _applyingClipboard = false;
        }
    }

    private void LoadSettings()
    {
        try
        {
            var settings = AppSettings.Load();
            _ipBox.Text = string.IsNullOrWhiteSpace(settings.MacIp) ? "192.168.1.12" : settings.MacIp;
            _portBox.Value = Math.Clamp(settings.Port <= 0 ? 45877 : settings.Port, 1, 65535);
            _edgeBox.SelectedItem = "left";
        }
        catch
        {
            _ipBox.Text = "192.168.1.12";
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
        _displayInfo.Text = DisplaySummary("Displays", displays);
        _arrangementView.WindowsDisplays = displays;
        UpdateArrangementInfo();
    }

    private void UpdateArrangementInfo()
    {
        _arrangementInfo.Text =
            $"{DisplaySummary("Mac", _arrangementView.MacDisplays)}{Environment.NewLine}" +
            $"{DisplaySummary("Windows", _arrangementView.WindowsDisplays)}";
    }

}

public sealed class AppSettings
{
    public string MacIp { get; set; } = "192.168.1.12";
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
    private const float ActualSizeScale = 0.12f;
    private const float MinScale = 0.01f;
    private const float MaxScale = 0.80f;
    private List<DisplayBox> _windowsDisplays = [];
    private List<DisplayBox> _macDisplays = [];
    private Dictionary<string, PointF> _machineOffsets = new(StringComparer.OrdinalIgnoreCase);
    private bool _manualViewport;
    private float _scale;
    private PointF _pan;
    private RectangleF _lastUnion;
    private bool _dragging;
    private Point _dragStart;
    private PointF _dragStartPan;

    public List<DisplayBox> WindowsDisplays
    {
        get => _windowsDisplays;
        set
        {
            _windowsDisplays = value;
            _manualViewport = false;
            Invalidate();
        }
    }

    public List<DisplayBox> MacDisplays
    {
        get => _macDisplays;
        set
        {
            _macDisplays = value;
            _manualViewport = false;
            Invalidate();
        }
    }

    public Dictionary<string, PointF> MachineOffsets
    {
        get => _machineOffsets;
        set
        {
            _machineOffsets = value;
            _manualViewport = false;
            Invalidate();
        }
    }

    public DisplayArrangementControl()
    {
        DoubleBuffered = true;
        ResizeRedraw = true;
        TabStop = true;
        BackColor = PortalTheme.PanelAlt;
        SetStyle(ControlStyles.Selectable, true);
        SetStyle(ControlStyles.UserMouse, true);
    }

    public void FitToContent()
    {
        var boxes = ArrangementBoxes();
        if (boxes.Count == 0)
        {
            _manualViewport = false;
            Invalidate();
            return;
        }

        FitViewport(boxes, DrawingArea(ClientCanvas()));
        _manualViewport = true;
        Invalidate();
    }

    public void ActualSize()
    {
        var canvas = ClientCanvas();
        var boxes = ArrangementBoxes();
        if (boxes.Count == 0) return;
        var union = VirtualUnion(boxes);
        _scale = ActualSizeScale;
        CenterUnion(union, DrawingArea(canvas), _scale);
        _manualViewport = true;
        Invalidate();
    }

    public void ZoomIn()
    {
        var canvas = ClientCanvas();
        ZoomAt(new PointF(canvas.Width / 2f, canvas.Height / 2f), 1.2f);
    }

    public void ZoomOut()
    {
        var canvas = ClientCanvas();
        ZoomAt(new PointF(canvas.Width / 2f, canvas.Height / 2f), 1f / 1.2f);
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

        if (!_manualViewport || _scale <= 0 || UnionChanged(union))
        {
            FitViewport(boxes, drawing);
        }

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
        _manualViewport = false;
        Invalidate();
    }

    protected override void OnMouseEnter(EventArgs e)
    {
        base.OnMouseEnter(e);
        Focus();
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        Focus();
        if (e.Button != MouseButtons.Left) return;
        _dragging = true;
        _dragStart = e.Location;
        _dragStartPan = _pan;
        Cursor = Cursors.SizeAll;
        Capture = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (!_dragging) return;
        _manualViewport = true;
        _pan = new PointF(
            _dragStartPan.X + e.X - _dragStart.X,
            _dragStartPan.Y + e.Y - _dragStart.Y
        );
        Invalidate();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (e.Button != MouseButtons.Left) return;
        _dragging = false;
        Cursor = Cursors.Default;
        Capture = false;
    }

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        base.OnMouseWheel(e);
        ZoomAt(e.Location, e.Delta > 0 ? 1.15f : 1f / 1.15f);
    }

    protected override void OnDoubleClick(EventArgs e)
    {
        base.OnDoubleClick(e);
        FitToContent();
    }

    private void ZoomAt(PointF anchor, float factor)
    {
        if (_scale <= 0)
        {
            var boxes = ArrangementBoxes();
            if (boxes.Count == 0) return;
            FitViewport(boxes, DrawingArea(ClientCanvas()));
        }

        var before = new PointF(
            (anchor.X - _pan.X) / _scale,
            (anchor.Y - _pan.Y) / _scale
        );
        _scale = Math.Clamp(_scale * factor, MinScale, MaxScale);
        _pan = new PointF(
            anchor.X - before.X * _scale,
            anchor.Y - before.Y * _scale
        );
        _manualViewport = true;
        Invalidate();
    }

    private void FitViewport(IReadOnlyList<ArrangementBox> boxes, RectangleF drawing)
    {
        var union = VirtualUnion(boxes);
        var fitScale = Math.Min(drawing.Width / Math.Max(1, union.Width), drawing.Height / Math.Max(1, union.Height));
        _scale = Math.Clamp(fitScale * FitScalePadding, MinScale, MaxScale);
        CenterDisplays(boxes, drawing, _scale);
        ClampPanToUnion(union, drawing, _scale);
        _lastUnion = union;
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

    private bool UnionChanged(RectangleF union)
    {
        return Math.Abs(union.Left - _lastUnion.Left) > 0.5f ||
               Math.Abs(union.Top - _lastUnion.Top) > 0.5f ||
               Math.Abs(union.Width - _lastUnion.Width) > 0.5f ||
               Math.Abs(union.Height - _lastUnion.Height) > 0.5f;
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
    private const long PinIntervalMs = 16;
    private const double MouseFlushIntervalMs = 4.0;
    private static readonly bool LiveStatsEnabled = false;

    private readonly string _macIp;
    private readonly int _port;
    private readonly string _edge;
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
    private IntPtr _mouseHook;
    private IntPtr _keyboardHook;
    private bool _running;
    private bool _remoteActive;
    private Point? _lastPos;
    private bool _ctrl;
    private bool _alt;
    private Rectangle _activeScreenBounds;
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
        _rawMousePump = new RawMousePump(HandleRawMouseDelta);
        _rawMousePump.Start();
        _worker = new Thread(ConnectLoop) { IsBackground = true };
        _worker.Start();
    }

    public void Stop()
    {
        _running = false;
        _sendSignal.Set();
        UninstallHooks();
        _rawMousePump?.Dispose();
        _rawMousePump = null;
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
                _stream = _client.GetStream();
                _udp?.Dispose();
                _udp = new UdpClient();
                _udp.Client.Blocking = false;
                _udp.Client.SendBufferSize = 256 * 1024;
                _udp.Connect(_macIp, _port);
                StatusChanged?.Invoke("Connected");
                SendDisplayLayout();
                _uiThread?.BeginInvoke((MethodInvoker)(() =>
                {
                    try
                    {
                        InstallHooks();
                        StatusChanged?.Invoke("Running");
                    }
                    catch (Exception ex)
                    {
                        StatusChanged?.Invoke(ex.Message);
                        Stop();
                    }
                }));
                Task.Run(ReadLoop);
                return;
            }
            catch
            {
                lock (_gate) _remoteActive = false;
                UninstallHooks();
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
                UninstallHooks();
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
        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (!root.TryGetProperty("type", out var typeElement) || typeElement.ValueKind != JsonValueKind.String) return;

            switch (typeElement.GetString())
            {
                case "release":
                    var (xRatio, yRatio) = ParseReleaseRatios(root);
                    ReleaseToWindows(xRatio, yRatio);
                    break;
                case "displayLayout":
                    var displays = ParseDisplayLayout(root);
                    if (displays.Count > 0) RemoteDisplaysChanged?.Invoke(displays);
                    var offsets = ParseMachineOffsets(root);
                    if (root.TryGetProperty("machineOffsets", out _)) ArrangementOffsetsChanged?.Invoke(offsets);
                    break;
                case "clipboard":
                    var clipboardPacket = PortalClipboard.FromJson(root);
                    if (clipboardPacket != null) ClipboardReceived?.Invoke(clipboardPacket);
                    break;
            }
        }
        catch { }
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

    private bool EdgeReached(int x, int y)
    {
        var bounds = Screen.FromPoint(new Point(x, y)).Bounds;
        return _edge switch
        {
            "right" => x >= bounds.Right - 2 && !PointInsideAnyScreen(new Point(bounds.Right + 1, y)),
            "left" => x <= bounds.Left + 1 && !PointInsideAnyScreen(new Point(bounds.Left - 2, y)),
            "top" => y <= bounds.Top + 1 && !PointInsideAnyScreen(new Point(x, bounds.Top - 2)),
            "bottom" => y >= bounds.Bottom - 2 && !PointInsideAnyScreen(new Point(x, bounds.Bottom + 1)),
            _ => false
        };
    }

    private static bool PointInsideAnyScreen(Point point)
    {
        return Screen.AllScreens.Any(screen => screen.Bounds.Contains(point));
    }

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
        pos = _edge switch
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

    private void ActivateRemote(int x, int y)
    {
        if (_remoteActive || _stream == null || _client?.Connected != true) return;
        var screen = Screen.FromPoint(new Point(x, y));
        var bounds = screen.Bounds;
        var xRatio = bounds.Width <= 1 ? 0.5 : Math.Clamp((double)(x - bounds.Left) / bounds.Width, 0.0, 1.0);
        var yRatio = bounds.Height <= 1 ? 0.5 : Math.Clamp((double)(y - bounds.Top) / bounds.Height, 0.0, 1.0);
        _activeScreenBounds = bounds;
        _remoteActive = true;
        _lastPos = new Point(x, y);
        Send(new { type = "activate", edge = _edge, xRatio, yRatio, screen = ScreenPayload(screen) });
        PinToEdge(force: true);
        StatusChanged?.Invoke("Mac control");
    }

    private void ReleaseToWindows(double? xRatio = null, double? yRatio = null)
    {
        lock (_gate)
        {
            _remoteActive = false;
            _lastPos = null;
            PinToEdge(force: true, xRatio: xRatio, yRatio: yRatio);
            _activeScreenBounds = Rectangle.Empty;
        }
        StatusChanged?.Invoke("Windows control");
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
                if (_stream != null && _client?.Connected == true && message == WM_MOUSEMOVE && EdgeReached(x, y))
                {
                    ActivateRemote(x, y);
                    return 1;
                }
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
        _mouseHook = SetWindowsHookEx(WH_MOUSE_LL, _mouseProc, GetModuleHandle(null), 0);
        _keyboardHook = SetWindowsHookEx(WH_KEYBOARD_LL, _keyboardProc, GetModuleHandle(null), 0);
        if (_mouseHook == IntPtr.Zero || _keyboardHook == IntPtr.Zero)
        {
            throw new InvalidOperationException("Could not install input hooks. Run as Administrator.");
        }
    }

    private void UninstallHooks()
    {
        if (_mouseHook != IntPtr.Zero) UnhookWindowsHookEx(_mouseHook);
        if (_keyboardHook != IntPtr.Zero) UnhookWindowsHookEx(_keyboardHook);
        _mouseHook = IntPtr.Zero;
        _keyboardHook = IntPtr.Zero;
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

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, Delegate lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string? lpModuleName);

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
