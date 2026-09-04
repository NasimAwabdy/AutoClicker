using System.Text.Json;
using System.Text.Json.Serialization;

namespace AutoClicker;

/// All options persist across sessions, mirroring @AppStorage on macOS.
/// Stored as JSON in %APPDATA%\AutoClicker\settings.json.
public sealed class Settings
{
    public int IntervalHours { get; set; } = 0;
    public int IntervalMins { get; set; } = 0;
    public int IntervalSecs { get; set; } = 0;
    public int IntervalMs { get; set; } = 100;

    public bool RandomizeEnabled { get; set; } = false;
    public int RandomAmountMs { get; set; } = 30;
    public string RandomMode { get; set; } = "uniform";
    public bool JitterEnabled { get; set; } = false;
    public int JitterPx { get; set; } = 3;
    public bool HoldEnabled { get; set; } = false;
    public int HoldMinMs { get; set; } = 45;
    public int HoldMaxMs { get; set; } = 130;
    public bool PausesEnabled { get; set; } = false;
    public int PauseEveryMin { get; set; } = 20;
    public int PauseEveryMax { get; set; } = 60;
    public string PauseEveryUnit { get; set; } = "clicks";
    public double PauseLenMinSec { get; set; } = 1.0;
    public double PauseLenMaxSec { get; set; } = 5.0;

    public string MouseButton { get; set; } = "left";
    public int ClickType { get; set; } = 1;

    public string RepeatMode { get; set; } = "forever";
    public int RepeatCount { get; set; } = 100;

    public string PositionMode { get; set; } = "current";
    public int FixedX { get; set; } = 0;
    public int FixedY { get; set; } = 0;

    public uint HotkeyKey { get; set; } = 0x75;      // VK_F6, like OP Auto Clicker
    public uint HotkeyModifiers { get; set; } = 0;   // MOD_* flags

    [JsonIgnore]
    public static string Path => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "AutoClicker", "settings.json");

    public static Settings Load()
    {
        try
        {
            if (File.Exists(Path))
                return JsonSerializer.Deserialize<Settings>(File.ReadAllText(Path)) ?? new Settings();
        }
        catch { /* corrupted file → fall back to defaults */ }
        return new Settings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
            File.WriteAllText(Path, JsonSerializer.Serialize(
                this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { /* non-fatal: settings just won't persist */ }
    }
}
