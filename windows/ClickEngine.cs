using System.Runtime.InteropServices;

namespace AutoClicker;

/// Performs the actual clicking on a background thread via SendInput.
/// Timing/humanization math mirrors the macOS ClickEngine.
public sealed class ClickEngine
{
    public enum MouseButton { Left, Right, Middle }
    public enum RandomMode { Uniform, Gaussian }
    public enum PauseUnit { Clicks, Seconds, Minutes }

    public sealed class Config
    {
        public int BaseIntervalMs;          // combined h/m/s/ms
        public bool Randomize;              // anti-detection: vary click time
        public int RandomAmountMs;          // ± range
        public RandomMode RandomMode;
        public bool JitterPosition;         // anti-detection: vary click position
        public int JitterPx;
        public bool Pauses;                 // anti-detection: occasional random pauses
        public int PauseEveryMin;           // pause after this many clicks OR secs/mins (random in range)
        public int PauseEveryMax;
        public PauseUnit PauseEveryUnit;    // interpret the range as clicks, seconds, or minutes
        public int PauseLenMinMs;           // pause duration (random in range)
        public int PauseLenMaxMs;
        public bool HumanHold;              // anti-detection: vary press duration (down→up)
        public int HoldMinMs;
        public int HoldMaxMs;
        public MouseButton Button;
        public int ClicksPerAction;         // 1 = single, 2 = double, 3 = triple
        public int Limit;                   // 0 = repeat until stopped
        public bool UseFixedLocation;
        public int FixedX;                  // screen (top-left origin) coordinates
        public int FixedY;

        /// Standard-normal sample (Box-Muller).
        public static double GaussianZ()
        {
            double u1 = Random.Shared.NextDouble() * (1 - 0.000_001) + 0.000_001;
            double u2 = Random.Shared.NextDouble();
            return Math.Sqrt(-2 * Math.Log(u1)) * Math.Cos(2 * Math.PI * u2);
        }

        static double RandomIn(double lo, double hi) => lo + Random.Shared.NextDouble() * (hi - lo);

        /// Next delay in ms, optionally randomized to defeat bot detection.
        /// `drift` is a slow session-level multiplier (see ClickEngine.drift).
        public int NextDelayMs(double drift = 1)
        {
            double baseMs = Math.Max(1, BaseIntervalMs);
            if (!Randomize || RandomAmountMs <= 0) return (int)baseMs;
            double amount = RandomAmountMs;
            switch (RandomMode)
            {
                case RandomMode.Uniform:
                    return (int)Math.Max(1, baseMs + RandomIn(-amount, amount));
                default:
                    // Log-normal around the drifted base: right-skewed like real
                    // inter-click times — clustered near the median with an
                    // occasional slow tail, but no mirror-image "too fast"
                    // outliers below the physical floor.
                    double sigma = Math.Min(0.8, amount / baseMs);
                    double v = baseMs * drift * Math.Exp(GaussianZ() * sigma);
                    return (int)Math.Max(baseMs * drift * 0.55, Math.Min(v, baseMs * drift + 4 * amount));
            }
        }

        /// Random countdown until the next pause: a click count for Clicks,
        /// or a duration in ms for Seconds/Minutes.
        public int NextPauseTarget()
        {
            int lo = Math.Max(1, Math.Min(PauseEveryMin, PauseEveryMax));
            int hi = Math.Max(1, Math.Max(PauseEveryMin, PauseEveryMax));
            int v = Random.Shared.Next(lo, hi + 1);
            return PauseEveryUnit switch
            {
                PauseUnit.Clicks => v,
                PauseUnit.Seconds => v * 1_000,
                _ => v * 60_000,
            };
        }

        /// Random pause duration in ms.
        public int NextPauseMs()
        {
            int lo = Math.Max(1, Math.Min(PauseLenMinMs, PauseLenMaxMs));
            int hi = Math.Max(1, Math.Max(PauseLenMinMs, PauseLenMaxMs));
            return Random.Shared.Next(lo, hi + 1);
        }

        /// Random press duration (mousedown → mouseup) in ms, log-normal
        /// within the range: median in the lower third with a tail toward the
        /// max — real press durations are right-skewed, not bell-shaped.
        /// 0 when disabled (down/up posted back-to-back).
        public int NextHoldMs()
        {
            if (!HumanHold) return 0;
            double lo = Math.Max(1, Math.Min(HoldMinMs, HoldMaxMs));
            double hi = Math.Max(1, Math.Max(HoldMinMs, HoldMaxMs));
            double median = lo + 0.3 * (hi - lo);
            double v = median * Math.Exp(GaussianZ() * 0.22);
            return (int)Math.Min(Math.Max(v, lo), hi);
        }
    }

    public bool IsRunning { get; private set; }
    public int ClickCount { get; private set; }
    public bool IsPausing { get; private set; }

    /// Raised on the UI thread whenever IsRunning/ClickCount/IsPausing change.
    public event Action? StateChanged;

    private CancellationTokenSource? cts;
    // Captured at Start() — the WinForms context isn't installed yet when the
    // form's field initializers construct this object.
    private SynchronizationContext ui = new();

    /// Session-level rhythm multiplier, evolved as a mean-reverting random
    /// walk (only in Human-like mode). Independent per-click randomness fails
    /// autocorrelation tests — real click rhythm drifts over minutes
    /// (warm-up, bursts, fatigue), with fast clicks tending to follow fast
    /// ones. Touched only on the engine thread.
    private double drift = 1.0;

    private void AdvanceDrift()
    {
        drift += RandomInStatic(-0.05, 0.05) - (drift - 1) * 0.015;
        drift = Math.Min(Math.Max(drift, 0.7), 1.4);
    }

    private static double RandomInStatic(double lo, double hi)
        => lo + Random.Shared.NextDouble() * (hi - lo);

    public void Start(Config config)
    {
        if (IsRunning) return;
        ui = SynchronizationContext.Current ?? new SynchronizationContext();
        IsRunning = true;
        ClickCount = 0;
        IsPausing = false;
        StateChanged?.Invoke();
        cts = new CancellationTokenSource();
        var token = cts.Token;
        var thread = new Thread(() => Loop(config, token)) { IsBackground = true };
        thread.Priority = ThreadPriority.AboveNormal;
        thread.Start();
    }

    public void Stop()
    {
        if (!IsRunning) return;
        cts?.Cancel();
        IsRunning = false;
        IsPausing = false;
        StateChanged?.Invoke();
    }

    public void Toggle(Config config)
    {
        if (IsRunning) Stop(); else Start(config);
    }

    // MARK: - Loop

    private void Loop(Config cfg, CancellationToken token)
    {
        drift = RandomInStatic(0.9, 1.1); // each session starts at its own tempo
        int done = 0;
        int untilPause = cfg.Pauses ? cfg.NextPauseTarget() : int.MaxValue;

        while (!token.IsCancellationRequested)
        {
            long clickStart = Environment.TickCount64;
            PerformClick(cfg);
            // Time spent holding the button (and multi-click gaps) counts toward
            // the interval, so the configured click rate stays accurate.
            int clickMs = (int)(Environment.TickCount64 - clickStart);
            done++;
            if (cfg.Limit > 0 && done >= cfg.Limit)
            {
                int finalCount = done;
                ui.Post(_ =>
                {
                    ClickCount = finalCount;
                    Stop();
                }, null);
                return;
            }

            if (cfg.Randomize && cfg.RandomMode == RandomMode.Gaussian) AdvanceDrift();
            int delay = Math.Max(1, cfg.NextDelayMs(drift) - clickMs);
            // Count down in clicks, or in elapsed milliseconds, depending on the unit.
            untilPause = cfg.PauseEveryUnit == PauseUnit.Clicks
                ? untilPause - 1
                : untilPause - delay;
            bool pausing = false;
            if (cfg.Pauses && untilPause <= 0)
            {
                delay += cfg.NextPauseMs();          // random-length pause
                untilPause = cfg.NextPauseTarget();  // random countdown until next pause
                pausing = true;
            }

            int count = done;
            ui.Post(_ =>
            {
                if (!IsRunning) return;
                ClickCount = count;
                IsPausing = pausing;
                StateChanged?.Invoke();
            }, null);

            if (token.WaitHandle.WaitOne(delay)) return; // cancelled mid-sleep
        }
    }

    // MARK: - Clicking

    private static void PerformClick(Config cfg)
    {
        int x, y;
        if (cfg.UseFixedLocation)
        {
            x = cfg.FixedX;
            y = cfg.FixedY;
        }
        else
        {
            GetCursorPos(out var p);
            x = p.X;
            y = p.Y;
        }
        if (cfg.JitterPosition && cfg.JitterPx > 0)
        {
            int r = cfg.JitterPx;
            x += Random.Shared.Next(-r, r + 1);
            y += Random.Shared.Next(-r, r + 1);
        }

        var (downFlag, upFlag) = cfg.Button switch
        {
            MouseButton.Left => (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
            MouseButton.Right => (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
            _ => (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP),
        };

        // SendInput has no "click here without moving" mode, so position the
        // cursor first — the click then lands there like a real one.
        if (cfg.UseFixedLocation || (cfg.JitterPosition && cfg.JitterPx > 0))
            SetCursorPos(x, y);

        int clicks = Math.Max(1, cfg.ClicksPerAction);
        for (int i = 1; i <= clicks; i++)
        {
            SendMouse(downFlag);
            int hold = cfg.NextHoldMs(); // re-rolled per press
            if (hold > 0) Thread.Sleep(hold);
            SendMouse(upFlag);
            if (i < clicks) Thread.Sleep(25); // gap inside double/triple click
        }
    }

    // MARK: - Win32

    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    private const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    private const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
    private const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
    private const uint INPUT_MOUSE = 0;

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public nint dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public MOUSEINPUT mi;
        // Pad to the size of the largest union member (KEYBDINPUT is smaller
        // than MOUSEINPUT on 64-bit, so MOUSEINPUT alone is the full size).
    }

    private static void SendMouse(uint flags)
    {
        var input = new INPUT { type = INPUT_MOUSE, mi = new MOUSEINPUT { dwFlags = flags } };
        SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);
}
