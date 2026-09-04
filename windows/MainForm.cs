namespace AutoClicker;

public sealed class MainForm : Form
{
    private readonly Settings s = Settings.Load();
    private readonly ClickEngine engine = new();
    private readonly HotKeyManager hotkeys;
    private readonly UpdateManager updater = new();
    private readonly ToolTip tips = new() { AutoPopDelay = 20000 };

    // Controls that need updating from event handlers
    private readonly Label perClickLabel = new();
    private readonly Label statusDot = new();
    private readonly Label statusLabel = new();
    private Button startButton = null!;
    private Button stopButton = null!;
    private Button hotkeyButton = null!;
    private Button pickButton = null!;
    private Panel updateBanner = null!;
    private Label updateTitle = null!;
    private Label updateSubtitle = null!;
    private Button updateButton = null!;
    private readonly System.Windows.Forms.Timer pickTimer = new() { Interval = 1000 };
    private int pickCountdown;

    private NumericUpDown hoursBox = null!, minsBox = null!, secsBox = null!, msBox = null!;
    private NumericUpDown randomAmountBox = null!, jitterBox = null!;
    private NumericUpDown holdMinBox = null!, holdMaxBox = null!;
    private NumericUpDown pauseEveryMinBox = null!, pauseEveryMaxBox = null!;
    private NumericUpDown pauseLenMinBox = null!, pauseLenMaxBox = null!;
    private NumericUpDown repeatCountBox = null!, fixedXBox = null!, fixedYBox = null!;
    private CheckBox randomizeCheck = null!, jitterCheck = null!, holdCheck = null!, pausesCheck = null!;
    private ComboBox randomModeCombo = null!, pauseUnitCombo = null!;
    private RadioButton repeatCountRadio = null!, repeatForeverRadio = null!;
    private RadioButton posCurrentRadio = null!, posFixedRadio = null!;

    public MainForm()
    {
        Text = "AutoClicker";
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        AutoScaleMode = AutoScaleMode.Dpi;
        StartPosition = FormStartPosition.CenterScreen;
        KeyPreview = true; // for hotkey recording
        Padding = new Padding(14);

        hotkeys = new HotKeyManager(s, Handle);

        var root = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.TopDown,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            WrapContents = false,
            Dock = DockStyle.Fill,
        };
        Controls.Add(root);

        root.Controls.Add(BuildUpdateBanner());
        root.Controls.Add(BuildIntervalBox());
        root.Controls.Add(BuildAntiDetectionBox());
        root.Controls.Add(BuildOptionsRow());
        root.Controls.Add(BuildCursorPositionBox());
        root.Controls.Add(BuildControls());
        root.Controls.Add(BuildStatusBar());
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;

        engine.StateChanged += RefreshStatus;
        hotkeys.Changed += RefreshHotkeyUI;
        updater.StateChanged += RefreshUpdateBanner;
        pickTimer.Tick += PickTick;

        UpdateEnabledStates();
        RefreshStatus();
        RefreshHotkeyUI();
        UpdatePerClickLabel();

        hotkeys.Activate();
        updater.CheckForUpdates();
        FormClosing += (_, _) => { s.Save(); hotkeys.Dispose(); engine.Stop(); };
        KeyDown += (_, e) => { if (hotkeys.HandleKeyDown(e)) e.Handled = e.SuppressKeyPress = true; };
    }

    protected override void WndProc(ref Message m)
    {
        // hotkeys is still null while the constructor creates the window handle
        if (hotkeys is not null && hotkeys.HandlesMessage(ref m))
        {
            engine.Toggle(CurrentConfig());
            return;
        }
        base.WndProc(ref m);
    }

    // MARK: - Sections

    private Panel BuildUpdateBanner()
    {
        updateTitle = new Label { AutoSize = true, Font = new Font(Font, FontStyle.Bold) };
        updateSubtitle = new Label { AutoSize = true, ForeColor = SystemColors.GrayText, MaximumSize = new Size(360, 0) };
        updateButton = new Button { Text = "Update Now", AutoSize = true };
        updateButton.Click += (_, _) => updater.InstallUpdate();
        tips.SetToolTip(updateButton, "Downloads the latest release from GitHub, replaces AutoClicker.exe, and relaunches. Your settings are kept.");
        var dismiss = new Button { Text = "✕", AutoSize = true, FlatStyle = FlatStyle.Flat };
        dismiss.FlatAppearance.BorderSize = 0;
        dismiss.Click += (_, _) => { updater.Dismissed = true; RefreshUpdateBanner(); };
        tips.SetToolTip(dismiss, "Hide until the next launch.");

        var textCol = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false,
        };
        textCol.Controls.Add(updateTitle);
        textCol.Controls.Add(updateSubtitle);

        var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        row.Controls.Add(textCol);
        row.Controls.Add(updateButton);
        row.Controls.Add(dismiss);

        updateBanner = new Panel
        {
            AutoSize = true, BackColor = Color.FromArgb(225, 238, 255),
            Padding = new Padding(8), Visible = false, Margin = new Padding(3, 3, 3, 8),
        };
        updateBanner.Controls.Add(row);
        return updateBanner;
    }

    private GroupBox BuildIntervalBox()
    {
        hoursBox = Num(() => s.IntervalHours, v => s.IntervalHours = v, 0, 99, UpdatePerClickLabel,
            "Hours between clicks. All four fields are added together to form the base interval.");
        minsBox = Num(() => s.IntervalMins, v => s.IntervalMins = v, 0, 59, UpdatePerClickLabel,
            "Minutes between clicks. All four fields are added together to form the base interval.");
        secsBox = Num(() => s.IntervalSecs, v => s.IntervalSecs = v, 0, 59, UpdatePerClickLabel,
            "Seconds between clicks. All four fields are added together to form the base interval.");
        msBox = Num(() => s.IntervalMs, v => s.IntervalMs = v, 0, 999, UpdatePerClickLabel,
            "Milliseconds between clicks. Example: 100 ms ≈ 10 clicks per second.");
        perClickLabel.AutoSize = true;
        perClickLabel.ForeColor = SystemColors.GrayText;
        perClickLabel.Margin = new Padding(12, 6, 3, 3);
        tips.SetToolTip(perClickLabel, "The resulting base time between clicks.");

        var row = Row(
            hoursBox, Lbl("hours"), minsBox, Lbl("mins"),
            secsBox, Lbl("secs"), msBox, Lbl("ms"), perClickLabel);
        return Group("Click interval", row);
    }

    private GroupBox BuildAntiDetectionBox()
    {
        randomizeCheck = Check(() => s.RandomizeEnabled, v => s.RandomizeEnabled = v, "Vary interval by ±",
            "Adds a random offset to every click delay so the timing is never constant — perfectly regular intervals are the #1 giveaway of an auto clicker.");
        randomAmountBox = Num(() => s.RandomAmountMs, v => s.RandomAmountMs = v, 1, 100000, null,
            "Maximum random offset in milliseconds. Each click's delay becomes base ± up to this amount.");
        randomModeCombo = Combo(new[] { "Uniform", "Human-like" },
            () => s.RandomMode == "gaussian" ? 1 : 0,
            i => s.RandomMode = i == 1 ? "gaussian" : "uniform",
            "Uniform: offsets are evenly spread across the range.\nHuman-like: right-skewed (log-normal) timing — most clicks cluster near your base interval with occasional slower outliers but never impossibly fast ones, and the underlying rhythm drifts slowly across the session (bursts, fatigue) so consecutive delays are correlated the way real clicking is.");

        jitterCheck = Check(() => s.JitterEnabled, v => s.JitterEnabled = v, "Jitter position by ±",
            "Offsets every click by a random number of pixels so clicks never land on the exact same coordinate — identical pixel positions are easy to detect.");
        jitterBox = Num(() => s.JitterPx, v => s.JitterPx = v, 1, 10000, null,
            "Maximum random offset in pixels, applied independently to X and Y for each click.");

        holdCheck = Check(() => s.HoldEnabled, v => s.HoldEnabled = v, "Hold click for",
            "Keeps the button pressed for a random duration between mousedown and mouseup. Real human clicks last roughly 50–150 ms — without this, the press duration is ~0 ms on every click, an easy giveaway.");
        holdMinBox = Num(() => s.HoldMinMs, v => s.HoldMinMs = v, 1, 10000, null,
            "Minimum press duration in milliseconds.");
        holdMaxBox = Num(() => s.HoldMaxMs, v => s.HoldMaxMs = v, 1, 10000, null,
            "Maximum press duration in milliseconds. Durations follow a right-skewed curve like natural clicks. Hold time is absorbed into the click interval, so your click rate stays the same.");

        pausesCheck = Check(() => s.PausesEnabled, v => s.PausesEnabled = v, "Pause every",
            "Occasionally stops clicking for a while, like a human taking a short break. Both when the pause happens and how long it lasts are randomized, so pauses never occur on a predictable schedule.");
        pauseEveryMinBox = Num(() => s.PauseEveryMin, v => s.PauseEveryMin = v, 1, 1000000, null,
            "Minimum amount (in the selected unit) before a pause. The actual trigger is re-rolled randomly within this range after every pause.");
        pauseEveryMaxBox = Num(() => s.PauseEveryMax, v => s.PauseEveryMax = v, 1, 1000000, null,
            "Maximum amount (in the selected unit) before a pause.");
        pauseUnitCombo = Combo(new[] { "clicks", "secs", "mins" },
            () => s.PauseEveryUnit switch { "seconds" => 1, "minutes" => 2, _ => 0 },
            i => s.PauseEveryUnit = i switch { 1 => "seconds", 2 => "minutes", _ => "clicks" },
            "What the range counts: pause after a random number of clicks, or after a random amount of elapsed time (seconds or minutes) of clicking.");
        pauseUnitCombo.Width = 70;
        pauseLenMinBox = NumDecimal(() => s.PauseLenMinSec, v => s.PauseLenMinSec = v,
            "Minimum pause length in seconds. Each pause's length is drawn randomly from this range.");
        pauseLenMaxBox = NumDecimal(() => s.PauseLenMaxSec, v => s.PauseLenMaxSec = v,
            "Maximum pause length in seconds.");

        foreach (var c in new[] { randomizeCheck, jitterCheck, holdCheck, pausesCheck })
            c.CheckedChanged += (_, _) => UpdateEnabledStates();

        var col = Column(
            Row(randomizeCheck, randomAmountBox, Lbl("ms"), randomModeCombo),
            Row(jitterCheck, jitterBox, Lbl("px")),
            Row(holdCheck, holdMinBox, Lbl("–"), holdMaxBox, Lbl("ms")),
            Row(pausesCheck, pauseEveryMinBox, Lbl("–"), pauseEveryMaxBox, pauseUnitCombo,
                Lbl("for"), pauseLenMinBox, Lbl("–"), pauseLenMaxBox, Lbl("secs")));
        return Group("Anti-detection randomization", col);
    }

    private Control BuildOptionsRow()
    {
        var buttonCombo = Combo(new[] { "Left", "Right", "Middle" },
            () => s.MouseButton switch { "right" => 1, "middle" => 2, _ => 0 },
            i => s.MouseButton = i switch { 1 => "right", 2 => "middle", _ => "left" },
            "Which mouse button to press: left, right (context menu), or middle (wheel) click.");
        var typeCombo = Combo(new[] { "Single", "Double", "Triple" },
            () => s.ClickType - 1,
            i => s.ClickType = i + 1,
            "How many clicks each action performs. Double/Triple click fast enough that apps recognize them as real double/triple clicks.");
        var optionsBox = Group("Click options", Column(
            Row(Lbl("Button:"), buttonCombo),
            Row(Lbl("Type:"), typeCombo)));

        repeatCountRadio = Radio(() => s.RepeatMode == "count", () => s.RepeatMode = "count",
            "Repeat", "Stop automatically after a set number of clicks.");
        repeatCountBox = Num(() => s.RepeatCount, v => s.RepeatCount = v, 1, 100000000, null,
            "Total number of clicks before stopping automatically. Tip: avoid round numbers like 100 or 1000 if you're worried about detection.");
        repeatForeverRadio = Radio(() => s.RepeatMode == "forever", () => s.RepeatMode = "forever",
            "Repeat until stopped", "Keep clicking until you press Stop or the hotkey.");
        repeatCountRadio.CheckedChanged += (_, _) => UpdateEnabledStates();
        // The two radios live in separate FlowLayoutPanel rows, so WinForms
        // won't group them automatically — enforce mutual exclusion by hand.
        repeatCountRadio.CheckedChanged += (_, _) =>
            { if (repeatCountRadio.Checked) repeatForeverRadio.Checked = false; };
        repeatForeverRadio.CheckedChanged += (_, _) =>
            { if (repeatForeverRadio.Checked) repeatCountRadio.Checked = false; };
        var repeatBox = Group("Click repeat", Column(
            Row(repeatCountRadio, repeatCountBox, Lbl("times")),
            Row(repeatForeverRadio)));

        var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        row.Controls.Add(optionsBox);
        row.Controls.Add(repeatBox);
        return row;
    }

    private GroupBox BuildCursorPositionBox()
    {
        posCurrentRadio = Radio(() => s.PositionMode == "current", () => s.PositionMode = "current",
            "Current location", "Click wherever your mouse cursor currently is — you keep control of the position while it clicks.");
        posFixedRadio = Radio(() => s.PositionMode == "fixed", () => s.PositionMode = "fixed",
            "Fixed:", "Always click at one fixed screen coordinate, regardless of where your cursor is.");
        posFixedRadio.CheckedChanged += (_, _) => UpdateEnabledStates();
        pickButton = new Button { Text = "Pick location", AutoSize = true };
        pickButton.Click += (_, _) => StartPickingLocation();
        tips.SetToolTip(pickButton, "Starts a 3-second countdown — move your mouse to the target spot, and its position is captured when the countdown ends.");
        fixedXBox = Num(() => s.FixedX, v => s.FixedX = v, -100000, 100000, null,
            "Horizontal screen coordinate in pixels, measured from the left edge.");
        fixedYBox = Num(() => s.FixedY, v => s.FixedY = v, -100000, 100000, null,
            "Vertical screen coordinate in pixels, measured from the top edge.");

        return Group("Cursor position", Row(
            posCurrentRadio, posFixedRadio, pickButton,
            Lbl("X"), fixedXBox, Lbl("Y"), fixedYBox));
    }

    private Control BuildControls()
    {
        startButton = new Button
        {
            AutoSize = false, Width = 180, Height = 34,
            BackColor = Color.FromArgb(210, 240, 210),
        };
        startButton.Click += (_, _) => engine.Start(CurrentConfig());
        AcceptButton = startButton;

        stopButton = new Button
        {
            AutoSize = false, Width = 180, Height = 34,
            BackColor = Color.FromArgb(245, 215, 215),
        };
        stopButton.Click += (_, _) => engine.Stop();

        hotkeyButton = new Button { AutoSize = false, Width = 130, Height = 34 };
        hotkeyButton.Click += (_, _) => hotkeys.BeginRecording();
        tips.SetToolTip(hotkeyButton, "Change the global start/stop hotkey. Click, then press any key (optionally with Ctrl/Alt/Shift). Press Esc to cancel. The hotkey works system-wide, even when this app isn't focused.");

        return Row(startButton, stopButton, hotkeyButton);
    }

    private Control BuildStatusBar()
    {
        statusDot.AutoSize = false;
        statusDot.Size = new Size(10, 10);
        statusDot.Margin = new Padding(6, 8, 3, 3);
        statusLabel.AutoSize = true;
        statusLabel.ForeColor = SystemColors.GrayText;
        statusLabel.Margin = new Padding(3, 6, 3, 3);
        var hint = new Label
        {
            Text = "Hotkey works in the background",
            AutoSize = true, ForeColor = SystemColors.GrayText,
            Margin = new Padding(40, 6, 3, 3),
        };
        tips.SetToolTip(hint, "The start/stop hotkey is registered system-wide — you can trigger it from any app without switching back to AutoClicker.");
        var bar = Row(statusDot, statusLabel, hint);
        bar.BackColor = Color.FromArgb(240, 240, 240);
        bar.Padding = new Padding(4);
        return bar;
    }

    // MARK: - State

    private ClickEngine.Config CurrentConfig() => new()
    {
        BaseIntervalMs = Math.Max(1,
            s.IntervalHours * 3_600_000 + s.IntervalMins * 60_000 + s.IntervalSecs * 1_000 + s.IntervalMs),
        Randomize = s.RandomizeEnabled,
        RandomAmountMs = s.RandomAmountMs,
        RandomMode = s.RandomMode == "gaussian"
            ? ClickEngine.RandomMode.Gaussian : ClickEngine.RandomMode.Uniform,
        JitterPosition = s.JitterEnabled,
        JitterPx = s.JitterPx,
        Pauses = s.PausesEnabled,
        PauseEveryMin = s.PauseEveryMin,
        PauseEveryMax = s.PauseEveryMax,
        PauseEveryUnit = s.PauseEveryUnit switch
        {
            "seconds" => ClickEngine.PauseUnit.Seconds,
            "minutes" => ClickEngine.PauseUnit.Minutes,
            _ => ClickEngine.PauseUnit.Clicks,
        },
        PauseLenMinMs = (int)(Math.Max(0.1, s.PauseLenMinSec) * 1000),
        PauseLenMaxMs = (int)(Math.Max(0.1, s.PauseLenMaxSec) * 1000),
        HumanHold = s.HoldEnabled,
        HoldMinMs = s.HoldMinMs,
        HoldMaxMs = s.HoldMaxMs,
        Button = s.MouseButton switch
        {
            "right" => ClickEngine.MouseButton.Right,
            "middle" => ClickEngine.MouseButton.Middle,
            _ => ClickEngine.MouseButton.Left,
        },
        ClicksPerAction = s.ClickType,
        Limit = s.RepeatMode == "count" ? Math.Max(1, s.RepeatCount) : 0,
        UseFixedLocation = s.PositionMode == "fixed",
        FixedX = s.FixedX,
        FixedY = s.FixedY,
    };

    /// 3-second countdown, then captures the mouse position as the fixed target.
    private void StartPickingLocation()
    {
        s.PositionMode = "fixed";
        posFixedRadio.Checked = true;
        pickCountdown = 3;
        pickButton.Text = $"Picking in {pickCountdown}…";
        pickButton.Enabled = false;
        pickTimer.Start();
    }

    private void PickTick(object? sender, EventArgs e)
    {
        pickCountdown--;
        if (pickCountdown > 0)
        {
            pickButton.Text = $"Picking in {pickCountdown}…";
            return;
        }
        pickTimer.Stop();
        var pos = Cursor.Position;
        s.FixedX = pos.X;
        s.FixedY = pos.Y;
        s.Save();
        fixedXBox.Value = pos.X;
        fixedYBox.Value = pos.Y;
        pickButton.Text = "Pick location";
        pickButton.Enabled = true;
    }

    private void RefreshStatus()
    {
        startButton.Enabled = !engine.IsRunning;
        stopButton.Enabled = engine.IsRunning;
        statusDot.BackColor = !engine.IsRunning ? Color.Gray
            : engine.IsPausing ? Color.Orange : Color.LimeGreen;
        statusLabel.Text = engine.IsRunning
            ? engine.IsPausing
                ? $"Pausing (humanizing)… — {engine.ClickCount} clicks"
                : $"Clicking — {engine.ClickCount} clicks"
            : engine.ClickCount > 0 ? $"Idle — last run: {engine.ClickCount} clicks" : "Idle";
    }

    private void RefreshHotkeyUI()
    {
        startButton.Text = $"▶ Start ({hotkeys.DisplayName})";
        stopButton.Text = $"■ Stop ({hotkeys.DisplayName})";
        hotkeyButton.Text = hotkeys.IsRecording ? "Press a key…" : "Hotkey";
        tips.SetToolTip(startButton, $"Start clicking with the current settings. You can also press the global hotkey ({hotkeys.DisplayName}) — it works even when this app is in the background.");
        tips.SetToolTip(stopButton, $"Stop clicking. The global hotkey ({hotkeys.DisplayName}) also stops it from any app.");
    }

    private void RefreshUpdateBanner()
    {
        updateBanner.Visible = updater.UpdateAvailable;
        if (!updater.UpdateAvailable) return;
        updateTitle.Text = $"Version {updater.LatestVersion} is available — you have {updater.CurrentVersion}";
        updateSubtitle.Text = updater.UpdateError
            ?? "Updating downloads the new version and relaunches. Your settings are kept.";
        updateSubtitle.ForeColor = updater.UpdateError == null ? SystemColors.GrayText : Color.Firebrick;
        updateButton.Text = updater.IsUpdating ? "Updating…" : "Update Now";
        updateButton.Enabled = !updater.IsUpdating;
    }

    private void UpdateEnabledStates()
    {
        randomAmountBox.Enabled = randomModeCombo.Enabled = randomizeCheck.Checked;
        jitterBox.Enabled = jitterCheck.Checked;
        holdMinBox.Enabled = holdMaxBox.Enabled = holdCheck.Checked;
        pauseEveryMinBox.Enabled = pauseEveryMaxBox.Enabled = pauseUnitCombo.Enabled =
            pauseLenMinBox.Enabled = pauseLenMaxBox.Enabled = pausesCheck.Checked;
        repeatCountBox.Enabled = repeatCountRadio.Checked;
        fixedXBox.Enabled = fixedYBox.Enabled = posFixedRadio.Checked;
    }

    private void UpdatePerClickLabel()
    {
        int total = Math.Max(1,
            s.IntervalHours * 3_600_000 + s.IntervalMins * 60_000 + s.IntervalSecs * 1_000 + s.IntervalMs);
        perClickLabel.Text = total < 1000
            ? $"= {total} ms per click"
            : total < 60_000
                ? $"= {total / 1000.0:0.##} s per click"
                : $"= {total / 60_000.0:0.#} min per click";
    }

    // MARK: - Reusable controls

    private static GroupBox Group(string title, Control content)
    {
        var box = new GroupBox
        {
            Text = title, AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Padding = new Padding(8, 4, 8, 6),
            Margin = new Padding(3, 3, 3, 8),
        };
        content.Dock = DockStyle.Fill;
        box.Controls.Add(content);
        return box;
    }

    private static FlowLayoutPanel Row(params Control[] controls)
    {
        var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        foreach (var c in controls) row.Controls.Add(c);
        return row;
    }

    private static FlowLayoutPanel Column(params Control[] rows)
    {
        var col = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false,
        };
        foreach (var r in rows) col.Controls.Add(r);
        return col;
    }

    private Label Lbl(string text) => new()
    {
        Text = text, AutoSize = true,
        ForeColor = SystemColors.GrayText,
        Margin = new Padding(2, 6, 2, 3),
    };

    private NumericUpDown Num(Func<int> get, Action<int> set, int min, int max,
        Action? onChange, string tip)
    {
        var box = new NumericUpDown
        {
            Minimum = min, Maximum = max, Width = 62,
            TextAlign = HorizontalAlignment.Right,
        };
        box.Value = Math.Clamp(get(), min, max);
        box.ValueChanged += (_, _) => { set((int)box.Value); s.Save(); onChange?.Invoke(); };
        tips.SetToolTip(box, tip);
        return box;
    }

    private NumericUpDown NumDecimal(Func<double> get, Action<double> set, string tip)
    {
        var box = new NumericUpDown
        {
            Minimum = 0.1m, Maximum = 100000, Width = 56,
            DecimalPlaces = 1, Increment = 0.5m,
            TextAlign = HorizontalAlignment.Right,
        };
        box.Value = Math.Clamp((decimal)get(), box.Minimum, box.Maximum);
        box.ValueChanged += (_, _) => { set((double)box.Value); s.Save(); };
        tips.SetToolTip(box, tip);
        return box;
    }

    private CheckBox Check(Func<bool> get, Action<bool> set, string text, string tip)
    {
        var box = new CheckBox { Text = text, AutoSize = true, Checked = get() };
        box.CheckedChanged += (_, _) => { set(box.Checked); s.Save(); };
        tips.SetToolTip(box, tip);
        return box;
    }

    private ComboBox Combo(string[] items, Func<int> get, Action<int> set, string tip)
    {
        var box = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 100 };
        box.Items.AddRange(items);
        box.SelectedIndex = Math.Clamp(get(), 0, items.Length - 1);
        box.SelectedIndexChanged += (_, _) => { set(box.SelectedIndex); s.Save(); };
        tips.SetToolTip(box, tip);
        return box;
    }

    private RadioButton Radio(Func<bool> get, Action select, string text, string tip)
    {
        var radio = new RadioButton { Text = text, AutoSize = true, Checked = get() };
        radio.CheckedChanged += (_, _) => { if (radio.Checked) { select(); s.Save(); } };
        tips.SetToolTip(radio, tip);
        return radio;
    }
}
