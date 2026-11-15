using System.Text.Json;

namespace MiniChroma.Windows;

/// Saved in %APPDATA%\MiniChroma\settings.json.
public sealed class Settings
{
    public string Host { get; set; } = "127.0.0.1";
    public int Port { get; set; } = 6742;
    public string DeviceName { get; set; } = "";
    public string Effect { get; set; } = "agent";
    public int Red { get; set; } = 0;
    public int Green { get; set; } = 255;
    public int Blue { get; set; } = 0;
    public double Brightness { get; set; } = 1.0;

    private static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MiniChroma");
    private static readonly string FilePath = Path.Combine(Folder, "settings.json");

    public static Settings Load()
    {
        try
        {
            if (File.Exists(FilePath)) return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new Settings();
        }
        catch { /* a damaged file falls back to defaults */ }
        return new Settings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Folder);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { /* settings are a convenience; the app keeps running */ }
    }
}
