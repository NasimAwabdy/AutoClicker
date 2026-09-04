using System.Runtime.InteropServices;

namespace AutoClicker;

/// Global (background) start/stop hotkey via Win32 RegisterHotKey.
/// Works even when the app is not focused.
public sealed class HotKeyManager : IDisposable
{
    public const int WM_HOTKEY = 0x0312;
    private const int HOTKEY_ID = 1;

    private const uint MOD_ALT = 0x0001;
    private const uint MOD_CONTROL = 0x0002;
    private const uint MOD_SHIFT = 0x0004;
    private const uint MOD_WIN = 0x0008;
    private const uint MOD_NOREPEAT = 0x4000;

    public bool IsRecording { get; private set; }
    public string DisplayName { get; private set; } = "";

    public event Action? Changed; // hotkey rebound or recording state changed

    private readonly Settings settings;
    private readonly nint hwnd;
    private bool registered;

    public HotKeyManager(Settings settings, nint windowHandle)
    {
        this.settings = settings;
        hwnd = windowHandle;
        UpdateDisplayName();
    }

    public void Activate() => Register();

    private void Register()
    {
        Unregister();
        registered = RegisterHotKey(hwnd, HOTKEY_ID,
            settings.HotkeyModifiers | MOD_NOREPEAT, settings.HotkeyKey);
    }

    private void Unregister()
    {
        if (registered)
        {
            UnregisterHotKey(hwnd, HOTKEY_ID);
            registered = false;
        }
    }

    /// True if this WM_HOTKEY message is ours.
    public bool HandlesMessage(ref Message m)
        => m.Msg == WM_HOTKEY && (int)m.WParam == HOTKEY_ID;

    // MARK: - Recording a new hotkey

    public void BeginRecording()
    {
        if (IsRecording) return;
        IsRecording = true;
        Unregister(); // so the current hotkey key can be re-chosen
        Changed?.Invoke();
    }

    /// Feed key-downs here while recording (form must have KeyPreview).
    /// Returns true when the key was consumed.
    public bool HandleKeyDown(KeyEventArgs e)
    {
        if (!IsRecording) return false;
        var key = e.KeyCode;
        if (key is Keys.ControlKey or Keys.ShiftKey or Keys.Menu or Keys.LWin or Keys.RWin)
            return true; // wait for a non-modifier key
        if (key == Keys.Escape) // Esc cancels
        {
            FinishRecording();
            return true;
        }
        settings.HotkeyKey = (uint)key;
        settings.HotkeyModifiers = ModifiersFrom(e);
        settings.Save();
        UpdateDisplayName();
        FinishRecording();
        return true;
    }

    private void FinishRecording()
    {
        IsRecording = false;
        Register();
        Changed?.Invoke();
    }

    private static uint ModifiersFrom(KeyEventArgs e)
    {
        uint mods = 0;
        if (e.Control) mods |= MOD_CONTROL;
        if (e.Alt) mods |= MOD_ALT;
        if (e.Shift) mods |= MOD_SHIFT;
        return mods;
    }

    // MARK: - Display

    private void UpdateDisplayName()
    {
        string name = "";
        if ((settings.HotkeyModifiers & MOD_CONTROL) != 0) name += "Ctrl+";
        if ((settings.HotkeyModifiers & MOD_ALT) != 0) name += "Alt+";
        if ((settings.HotkeyModifiers & MOD_SHIFT) != 0) name += "Shift+";
        if ((settings.HotkeyModifiers & MOD_WIN) != 0) name += "Win+";
        name += KeyName((Keys)settings.HotkeyKey);
        DisplayName = name;
    }

    private static string KeyName(Keys key) => key switch
    {
        Keys.Space => "Space",
        Keys.Return => "Enter",
        Keys.Left => "←",
        Keys.Right => "→",
        Keys.Up => "↑",
        Keys.Down => "↓",
        Keys.Prior => "Page Up",
        Keys.Next => "Page Down",
        Keys.OemMinus => "-",
        Keys.Oemplus => "=",
        Keys.Oemtilde => "`",
        >= Keys.D0 and <= Keys.D9 => ((char)key).ToString(),
        _ => key.ToString(),
    };

    public void Dispose() => Unregister();

    [DllImport("user32.dll")]
    private static extern bool RegisterHotKey(nint hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(nint hWnd, int id);
}
