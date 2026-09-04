using System.Diagnostics;
using System.IO.Compression;
using System.Reflection;
using System.Text.Json;

namespace AutoClicker;

/// Checks GitHub Releases for a newer version and performs one-click updates.
public sealed class UpdateManager
{
    private const string Repo = "NasimAwabdy/AutoClicker";
    private const string AssetName = "AutoClicker-windows.zip";

    public string? LatestVersion { get; private set; } // set only when newer than current
    public bool IsUpdating { get; private set; }
    public string? UpdateError { get; private set; }
    public bool Dismissed { get; set; }

    public event Action? StateChanged; // raised on the UI thread

    public readonly string CurrentVersion =
        Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "0";

    private string? downloadUrl;

    public bool UpdateAvailable => LatestVersion != null && !Dismissed;

    /// Queries the latest GitHub release; fails silently (offline, rate limit)
    /// and simply retries on the next launch.
    public async void CheckForUpdates()
    {
        try
        {
            using var http = new HttpClient();
            http.DefaultRequestHeaders.UserAgent.ParseAdd("AutoClicker");
            var json = await http.GetStringAsync(
                $"https://api.github.com/repos/{Repo}/releases/latest");
            using var doc = JsonDocument.Parse(json);
            string tag = doc.RootElement.GetProperty("tag_name").GetString() ?? "";
            string latest = tag.StartsWith('v') ? tag[1..] : tag;
            if (!IsNewer(latest, CurrentVersion)) return;
            foreach (var asset in doc.RootElement.GetProperty("assets").EnumerateArray())
            {
                if (asset.GetProperty("name").GetString() == AssetName)
                {
                    downloadUrl = asset.GetProperty("browser_download_url").GetString();
                    break;
                }
            }
            if (downloadUrl == null) return;
            // async void called from the UI thread — the continuation after
            // await already resumed on the WinForms context.
            LatestVersion = latest;
            StateChanged?.Invoke();
        }
        catch { /* silent — retry next launch */ }
    }

    /// Downloads and extracts the new exe, then swaps it in from a detached
    /// cmd script — the running exe can't overwrite itself — and relaunches.
    /// The old exe stays untouched unless download and extraction fully succeed.
    public async void InstallUpdate()
    {
        if (downloadUrl == null || IsUpdating) return;
        IsUpdating = true;
        UpdateError = null;
        StateChanged?.Invoke();
        try
        {
            string tmp = Path.Combine(Path.GetTempPath(), "AutoClickerUpdate-" + Guid.NewGuid());
            Directory.CreateDirectory(tmp);
            using var http = new HttpClient();
            http.DefaultRequestHeaders.UserAgent.ParseAdd("AutoClicker");
            byte[] zip = await http.GetByteArrayAsync(downloadUrl);
            string zipPath = Path.Combine(tmp, AssetName);
            await File.WriteAllBytesAsync(zipPath, zip);
            ZipFile.ExtractToDirectory(zipPath, tmp);
            string staged = Path.Combine(tmp, "AutoClicker.exe");
            if (!File.Exists(staged))
                throw new InvalidOperationException(
                    "Downloaded archive did not contain AutoClicker.exe");

            string target = Environment.ProcessPath
                ?? throw new InvalidOperationException("Cannot determine own path");
            string script = Path.Combine(tmp, "swap.cmd");
            int pid = Environment.ProcessId;
            // Wait for this process to exit, replace the exe, relaunch, clean up.
            await File.WriteAllTextAsync(script, $"""
                @echo off
                :wait
                tasklist /fi "PID eq {pid}" 2>nul | find "{pid}" >nul && (
                    timeout /t 1 /nobreak >nul
                    goto wait
                )
                copy /y "{staged}" "{target}" >nul
                start "" "{target}"
                rd /s /q "{tmp}"
                """);
            Process.Start(new ProcessStartInfo
            {
                FileName = "cmd.exe",
                Arguments = $"/c \"{script}\"",
                WindowStyle = ProcessWindowStyle.Hidden,
                UseShellExecute = true,
            });
            Application.Exit();
        }
        catch (Exception e)
        {
            UpdateError = e.Message;
            IsUpdating = false;
            StateChanged?.Invoke();
        }
    }

    /// True if a is a higher version than b, comparing numeric components.
    public static bool IsNewer(string a, string b)
    {
        var av = a.Split('.').Select(s => int.TryParse(s, out int n) ? n : 0).ToArray();
        var bv = b.Split('.').Select(s => int.TryParse(s, out int n) ? n : 0).ToArray();
        for (int i = 0; i < Math.Max(av.Length, bv.Length); i++)
        {
            int x = i < av.Length ? av[i] : 0;
            int y = i < bv.Length ? bv[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }
}
