using System.Drawing;

namespace MiniChroma.Windows;

/// Tray icon and menu. A background loop connects to OpenRGB and sends colours about 20 times a second.
public sealed class TrayApp : ApplicationContext
{
    private readonly NotifyIcon tray;
    private readonly ToolStripMenuItem statusItem;
    private readonly ToolStripMenuItem deviceMenu;
    private readonly Settings settings = Settings.Load();
    private readonly OpenRgbClient openRgb = new();
    private AgentListener? agent;
    private readonly CancellationTokenSource cancel = new();
    private volatile string status = "Starting";
    private int deviceIndex = -1;
    private int ledCount;

    public TrayApp()
    {
        statusItem = new ToolStripMenuItem("Starting…") { Enabled = false };
        deviceMenu = new ToolStripMenuItem("Keyboard in OpenRGB");

        var effectMenu = new ToolStripMenuItem("Effect");
        effectMenu.DropDownItems.Add(EffectItem("Claude agent", "agent"));
        effectMenu.DropDownItems.Add(EffectItem("Static colour", "static"));
        effectMenu.DropDownItems.Add(EffectItem("Off", "off"));
        effectMenu.DropDownItems.Add(new ToolStripSeparator());
        effectMenu.DropDownItems.Add(new ToolStripMenuItem("Choose static colour…", null, (_, _) => PickColour()));

        var menu = new ContextMenuStrip();
        menu.Items.Add(statusItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(effectMenu);
        menu.Items.Add(deviceMenu);
        menu.Items.Add(new ToolStripMenuItem("Reconnect to OpenRGB", null, (_, _) => openRgb.Close()));
        menu.Items.Add(new ToolStripMenuItem("Open OpenRGB", null, (_, _) => OpenOpenRgb()));
        menu.Items.Add(new ToolStripMenuItem("Setup help", null, (_, _) => OpenUrl("https://openrgb.org")));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Quit", null, (_, _) => Quit()));

        tray = new NotifyIcon
        {
            Icon = SystemIcons.Information,
            Text = "MiniChroma",
            Visible = true,
            ContextMenuStrip = menu,
        };
        tray.DoubleClick += (_, _) => statusItem.Text = status;
        try { agent = new AgentListener(); }
        catch (Exception ex) { SetStatus("Claude listener unavailable: " + ex.Message); }
        _ = RunAsync(cancel.Token);
    }

    private ToolStripMenuItem EffectItem(string title, string key)
    {
        var item = new ToolStripMenuItem(title) { Checked = settings.Effect == key };
        item.Click += (_, _) =>
        {
            settings.Effect = key;
            settings.Save();
            foreach (ToolStripMenuItem sibling in ((ToolStripMenuItem)item.OwnerItem!).DropDownItems.OfType<ToolStripMenuItem>())
                sibling.Checked = sibling.Text == title;
        };
        return item;
    }

    private void PickColour()
    {
        using var dialog = new ColorDialog { Color = Color.FromArgb(settings.Red, settings.Green, settings.Blue) };
        if (dialog.ShowDialog() != DialogResult.OK) return;
        settings.Red = dialog.Color.R;
        settings.Green = dialog.Color.G;
        settings.Blue = dialog.Color.B;
        settings.Effect = "static";
        settings.Save();
    }

    private async Task RunAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                if (!openRgb.IsConnected) await ConnectAsync();
                if (deviceIndex < 0) { await Task.Delay(3000, token); continue; }

                double now = DateTime.UtcNow.Subtract(DateTime.UnixEpoch).TotalSeconds;
                var (agentStatus, seconds) = agent?.Current() ?? ("idle", 0.0);
                var (r, g, b) = Effects.Compute(settings, agentStatus, seconds, now);
                var colours = Enumerable.Repeat((r, g, b), ledCount).ToList();
                await openRgb.UpdateLedsAsync(deviceIndex, colours);
                SetStatus($"{settings.Effect} · {ledCount} LEDs");
                await Task.Delay(50, token);
            }
            catch (OperationCanceledException) { return; }
            catch (Exception ex)
            {
                openRgb.Close();
                deviceIndex = -1;
                SetStatus(ex is System.Net.Sockets.SocketException
                    ? "OpenRGB is not running. Open OpenRGB, turn on its SDK Server, then choose Reconnect."
                    : "OpenRGB: " + ex.Message);
                try { await Task.Delay(3000, token); } catch (OperationCanceledException) { return; }
            }
        }
    }

    private async Task ConnectAsync()
    {
        SetStatus("Connecting to OpenRGB…");
        await openRgb.ConnectAsync(settings.Host, settings.Port);
        int count = await openRgb.ControllerCountAsync();
        var devices = new List<DeviceInfo>();
        for (int i = 0; i < count; i++) devices.Add(await openRgb.ControllerDataAsync(i));

        // Prefer the device the user picked before; otherwise the first keyboard, otherwise the first device.
        var chosen = devices.FirstOrDefault(d => d.Name == settings.DeviceName)
            ?? devices.FirstOrDefault(d => d.Name.Contains("Keyboard", StringComparison.OrdinalIgnoreCase))
            ?? devices.FirstOrDefault();
        if (chosen is null) throw new InvalidOperationException("OpenRGB found no devices");

        deviceIndex = chosen.Index;
        ledCount = chosen.LedCount;
        settings.DeviceName = chosen.Name;
        settings.Save();
        await openRgb.SetCustomModeAsync(deviceIndex);
        RebuildDeviceMenu(devices);
    }

    private void RebuildDeviceMenu(List<DeviceInfo> devices)
    {
        if (tray.ContextMenuStrip?.InvokeRequired == true)
        {
            tray.ContextMenuStrip.Invoke(() => RebuildDeviceMenu(devices));
            return;
        }
        deviceMenu.DropDownItems.Clear();
        foreach (var device in devices)
        {
            var item = new ToolStripMenuItem(device.Name) { Checked = device.Index == deviceIndex };
            item.Click += (_, _) => { settings.DeviceName = device.Name; settings.Save(); openRgb.Close(); };
            deviceMenu.DropDownItems.Add(item);
        }
    }

    private void SetStatus(string text)
    {
        status = text;
        tray.Text = text.Length > 60 ? text[..60] : text;
        if (statusItem.GetCurrentParent()?.InvokeRequired == true)
            statusItem.GetCurrentParent().Invoke(() => statusItem.Text = text);
        else
            statusItem.Text = text;
    }

    /// Starts OpenRGB if it is installed; otherwise opens its download page.
    private static void OpenOpenRgb()
    {
        string[] paths =
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "OpenRGB", "OpenRGB.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "OpenRGB", "OpenRGB.exe"),
        };
        var found = paths.FirstOrDefault(File.Exists);
        if (found is not null) System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(found) { UseShellExecute = true });
        else OpenUrl("https://openrgb.org");
    }

    private static void OpenUrl(string url) =>
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });

    private void Quit()
    {
        cancel.Cancel();
        openRgb.Close();
        agent?.Dispose();
        tray.Visible = false;
        Application.Exit();
    }
}
