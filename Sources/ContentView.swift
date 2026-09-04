import SwiftUI
import ApplicationServices

struct ContentView: View {

    // All settings persist across sessions via @AppStorage (like OP Auto Clicker v1.0.0.1+)
    @AppStorage("intervalHours") private var hours = 0
    @AppStorage("intervalMins") private var mins = 0
    @AppStorage("intervalSecs") private var secs = 0
    @AppStorage("intervalMs") private var ms = 100

    @AppStorage("randomizeEnabled") private var randomizeEnabled = false
    @AppStorage("randomAmountMs") private var randomAmountMs = 30
    @AppStorage("randomMode") private var randomMode = "uniform"
    @AppStorage("jitterEnabled") private var jitterEnabled = false
    @AppStorage("jitterPx") private var jitterPx = 3
    @AppStorage("holdEnabled") private var holdEnabled = false
    @AppStorage("holdMinMs") private var holdMinMs = 45
    @AppStorage("holdMaxMs") private var holdMaxMs = 130
    @AppStorage("pausesEnabled") private var pausesEnabled = false
    @AppStorage("pauseEveryMin") private var pauseEveryMin = 20
    @AppStorage("pauseEveryMax") private var pauseEveryMax = 60
    @AppStorage("pauseEveryUnit") private var pauseEveryUnit = "clicks"
    @AppStorage("pauseLenMinSec") private var pauseLenMinSec = 1.0
    @AppStorage("pauseLenMaxSec") private var pauseLenMaxSec = 5.0

    @AppStorage("mouseButton") private var mouseButton = "left"
    @AppStorage("clickType") private var clickType = 1

    @AppStorage("repeatMode") private var repeatMode = "forever"
    @AppStorage("repeatCount") private var repeatCount = 100

    @AppStorage("positionMode") private var positionMode = "current"
    @AppStorage("fixedX") private var fixedX = 0.0
    @AppStorage("fixedY") private var fixedY = 0.0

    @StateObject private var engine = ClickEngine()
    @StateObject private var hotkeys = HotKeyManager.shared
    @StateObject private var updater = UpdateManager.shared

    @State private var pickCountdown = 0
    @State private var axTrusted = AXIsProcessTrusted()
    private let axTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            if updater.updateAvailable { updateBanner }
            if !axTrusted { permissionBanner }
            intervalBox
            antiDetectionBox
            HStack(alignment: .top, spacing: 14) {
                clickOptionsBox
                clickRepeatBox
            }
            cursorPositionBox
            controls
            statusBar
        }
        .padding(18)
        .frame(width: 560)
        .background(.background)
        .onAppear {
            hotkeys.activate()
            hotkeys.onToggle = { engine.toggle(config: currentConfig()) }
            updater.checkForUpdates()
        }
        .onReceive(axTimer) { _ in
            axTrusted = AXIsProcessTrusted()
        }
    }

    private var updateBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Version \(updater.latestVersion ?? "?") is available — you have \(updater.currentVersion)")
                    .font(.callout.bold())
                Text(updater.updateError
                     ?? "Updating downloads the new version, relaunches, and asks you to re-grant Accessibility permission.")
                    .font(.caption)
                    .foregroundColor(updater.updateError == nil ? .secondary : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(updater.isUpdating ? "Updating…" : "Update Now") {
                updater.installUpdate()
            }
            .buttonStyle(.borderedProminent)
            .disabled(updater.isUpdating)
            .help("Downloads the latest release from GitHub, replaces /Applications/AutoClicker.app, and relaunches. Your settings are kept — you'll only need to re-grant Accessibility permission (the code signature changes with each release).")
            Button {
                updater.dismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(updater.isUpdating)
            .help("Hide until the next launch.")
        }
        .padding(12)
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.blue.opacity(0.35)))
    }

    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility permission required")
                    .font(.callout.bold())
                Text("macOS silently blocks simulated clicks until AutoClicker is enabled. This banner disappears once granted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            .help("Opens System Settings → Privacy & Security → Accessibility. Enable AutoClicker there — if it's missing, drag build/AutoClicker.app into the list.")
        }
        .padding(12)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.yellow.opacity(0.4)))
    }

    // MARK: - Sections

    private var intervalBox: some View {
        section("Click interval", icon: "timer") {
            HStack(spacing: 10) {
                intervalUnit($hours, "hours",
                             help: "Hours between clicks. All four fields are added together to form the base interval.")
                intervalUnit($mins, "mins",
                             help: "Minutes between clicks. All four fields are added together to form the base interval.")
                intervalUnit($secs, "secs",
                             help: "Seconds between clicks. All four fields are added together to form the base interval.")
                intervalUnit($ms, "ms",
                             help: "Milliseconds between clicks. Example: 100 ms ≈ 10 clicks per second.")
                Spacer()
                Text("= \(formattedBaseInterval) per click")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("The resulting base time between clicks.")
            }
        }
    }

    private var antiDetectionBox: some View {
        section("Anti-detection randomization", icon: "shield.lefthalf.filled") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Toggle("Vary interval by ±", isOn: $randomizeEnabled)
                        .help("Adds a random offset to every click delay so the timing is never constant — perfectly regular intervals are the #1 giveaway of an auto clicker.")
                    numberField($randomAmountMs, min: 1)
                        .disabled(!randomizeEnabled)
                        .help("Maximum random offset in milliseconds. Each click's delay becomes base ± up to this amount.")
                    Text("ms").foregroundStyle(.secondary)
                    Picker("", selection: $randomMode) {
                        Text("Uniform").tag("uniform")
                        Text("Human-like").tag("gaussian")
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .disabled(!randomizeEnabled)
                    .help("Uniform: offsets are evenly spread across the range.\nHuman-like: right-skewed (log-normal) timing — most clicks cluster near your base interval with occasional slower outliers but never impossibly fast ones, and the underlying rhythm drifts slowly across the session (bursts, fatigue) so consecutive delays are correlated the way real clicking is.")
                    Spacer()
                }
                HStack(spacing: 8) {
                    Toggle("Jitter position by ±", isOn: $jitterEnabled)
                        .help("Offsets every click by a random number of pixels so clicks never land on the exact same coordinate — identical pixel positions are easy to detect.")
                    numberField($jitterPx, min: 1)
                        .disabled(!jitterEnabled)
                        .help("Maximum random offset in pixels, applied independently to X and Y for each click.")
                    Text("px").foregroundStyle(.secondary)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Toggle("Hold click for", isOn: $holdEnabled)
                        .help("Keeps the button pressed for a random duration between mousedown and mouseup. Real human clicks last roughly 50–150 ms — without this, the press duration is ~0 ms on every click, an easy giveaway. The events are generated locally, so network latency never masks this.")
                    numberField($holdMinMs, min: 1)
                        .disabled(!holdEnabled)
                        .help("Minimum press duration in milliseconds.")
                    Text("–").foregroundStyle(.secondary)
                    numberField($holdMaxMs, min: 1)
                        .disabled(!holdEnabled)
                        .help("Maximum press duration in milliseconds. Durations follow a bell curve centered between the two values, like natural clicks. Hold time is absorbed into the click interval, so your click rate stays the same.")
                    Text("ms").foregroundStyle(.secondary)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Toggle("Pause every", isOn: $pausesEnabled)
                        .help("Occasionally stops clicking for a while, like a human taking a short break. Both when the pause happens and how long it lasts are randomized, so pauses never occur on a predictable schedule.")
                    numberField($pauseEveryMin, min: 1)
                        .disabled(!pausesEnabled)
                        .help("Minimum amount (in the selected unit) before a pause. The actual trigger is re-rolled randomly within this range after every pause.")
                    Text("–").foregroundStyle(.secondary)
                    numberField($pauseEveryMax, min: 1)
                        .disabled(!pausesEnabled)
                        .help("Maximum amount (in the selected unit) before a pause.")
                    Picker("", selection: $pauseEveryUnit) {
                        Text("clicks").tag("clicks")
                        Text("secs").tag("seconds")
                        Text("mins").tag("minutes")
                    }
                    .labelsHidden()
                    .frame(width: 78)
                    .disabled(!pausesEnabled)
                    .help("What the range counts: pause after a random number of clicks, or after a random amount of elapsed time (seconds or minutes) of clicking.")
                    Text("for").foregroundStyle(.secondary)
                    secondsField($pauseLenMinSec)
                        .disabled(!pausesEnabled)
                        .help("Minimum pause length in seconds. Each pause's length is drawn randomly from this range.")
                    Text("–").foregroundStyle(.secondary)
                    secondsField($pauseLenMaxSec)
                        .disabled(!pausesEnabled)
                        .help("Maximum pause length in seconds.")
                    Text("secs").foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private var clickOptionsBox: some View {
        section("Click options", icon: "cursorarrow.click") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Button:", selection: $mouseButton) {
                    Text("Left").tag("left")
                    Text("Right").tag("right")
                    Text("Middle").tag("middle")
                }
                .help("Which mouse button to press: left, right (context menu), or middle (wheel) click.")
                Picker("Type:", selection: $clickType) {
                    Text("Single").tag(1)
                    Text("Double").tag(2)
                    Text("Triple").tag(3)
                }
                .help("How many clicks each action performs. Double/Triple send proper multi-click events, so apps recognize them as real double/triple clicks (e.g. to open items or select words).")
            }
        }
    }

    private var clickRepeatBox: some View {
        section("Click repeat", icon: "repeat") {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    radio(selected: repeatMode == "count") { repeatMode = "count" }
                        .help("Stop automatically after a set number of clicks.")
                    Text("Repeat")
                    numberField($repeatCount, min: 1)
                        .disabled(repeatMode != "count")
                        .help("Total number of clicks before stopping automatically. Tip: avoid round numbers like 100 or 1000 if you're worried about detection.")
                    Text("times")
                }
                HStack(spacing: 6) {
                    radio(selected: repeatMode == "forever") { repeatMode = "forever" }
                        .help("Keep clicking until you press Stop or the hotkey.")
                    Text("Repeat until stopped")
                }
            }
        }
    }

    private var cursorPositionBox: some View {
        section("Cursor position", icon: "scope") {
            HStack(spacing: 10) {
                radio(selected: positionMode == "current") { positionMode = "current" }
                    .help("Click wherever your mouse cursor currently is — you keep control of the position while it clicks.")
                Text("Current location")
                Divider().frame(height: 18)
                radio(selected: positionMode == "fixed") { positionMode = "fixed" }
                    .help("Always click at one fixed screen coordinate, regardless of where your cursor is.")
                Button {
                    startPickingLocation()
                } label: {
                    Label(pickCountdown > 0 ? "Picking in \(pickCountdown)…" : "Pick location",
                          systemImage: "hand.point.up.left")
                }
                .disabled(pickCountdown > 0)
                .help("Starts a 3-second countdown — move your mouse to the target spot, and its position is captured when the countdown ends.")
                Text("X").foregroundStyle(.secondary)
                doubleField($fixedX)
                    .disabled(positionMode != "fixed")
                    .help("Horizontal screen coordinate in pixels, measured from the left edge.")
                Text("Y").foregroundStyle(.secondary)
                doubleField($fixedY)
                    .disabled(positionMode != "fixed")
                    .help("Vertical screen coordinate in pixels, measured from the top edge.")
                Spacer()
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                engine.start(config: currentConfig())
            } label: {
                Label("Start (\(hotkeys.displayName))", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(engine.isRunning)
            .keyboardShortcut(.defaultAction)
            .help("Start clicking with the current settings. You can also press the global hotkey (\(hotkeys.displayName)) — it works even when this app is in the background.")

            Button {
                engine.stop()
            } label: {
                Label("Stop (\(hotkeys.displayName))", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!engine.isRunning)
            .help("Stop clicking. The global hotkey (\(hotkeys.displayName)) also stops it from any app.")

            Button {
                hotkeys.beginRecording()
            } label: {
                Label(hotkeys.isRecording ? "Press a key…" : "Hotkey",
                      systemImage: "keyboard")
                    .frame(maxWidth: 130)
                    .padding(.vertical, 5)
            }
            .help("Change the global start/stop hotkey. Click, then press any key (optionally with ⌘ ⌥ ⌃ ⇧ modifiers). Press Esc to cancel. The hotkey works system-wide, even when this app isn't focused.")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .shadow(color: statusColor.opacity(engine.isRunning ? 0.6 : 0), radius: 3)
            Text(statusText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Label("Hotkey works in the background", systemImage: "globe")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("The start/stop hotkey is registered system-wide — you can trigger it from any app without switching back to AutoClicker.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusColor: Color {
        if !engine.isRunning { return .secondary.opacity(0.4) }
        return engine.isPausing ? .orange : .green
    }

    private var statusText: String {
        if engine.isRunning {
            return engine.isPausing
                ? "Pausing (humanizing)… — \(engine.clickCount) clicks"
                : "Clicking — \(engine.clickCount) clicks"
        }
        return engine.clickCount > 0 ? "Idle — last run: \(engine.clickCount) clicks" : "Idle"
    }

    private var formattedBaseInterval: String {
        let total = max(1, hours * 3_600_000 + mins * 60_000 + secs * 1_000 + ms)
        if total < 1000 { return "\(total) ms" }
        let s = Double(total) / 1000
        return s < 60 ? String(format: "%.2f s", s) : String(format: "%.1f min", s / 60)
    }

    // MARK: - Config

    private func currentConfig() -> ClickEngine.Config {
        ClickEngine.Config(
            baseIntervalMs: max(1, hours * 3_600_000 + mins * 60_000 + secs * 1_000 + ms),
            randomize: randomizeEnabled,
            randomAmountMs: randomAmountMs,
            randomMode: ClickEngine.RandomMode(rawValue: randomMode) ?? .uniform,
            jitterPosition: jitterEnabled,
            jitterPx: jitterPx,
            pauses: pausesEnabled,
            pauseEveryMin: pauseEveryMin,
            pauseEveryMax: pauseEveryMax,
            pauseEveryUnit: ClickEngine.PauseUnit(rawValue: pauseEveryUnit) ?? .clicks,
            pauseLenMinMs: Int(max(0.1, pauseLenMinSec) * 1000),
            pauseLenMaxMs: Int(max(0.1, pauseLenMaxSec) * 1000),
            humanHold: holdEnabled,
            holdMinMs: holdMinMs,
            holdMaxMs: holdMaxMs,
            button: ClickEngine.MouseButton(rawValue: mouseButton) ?? .left,
            clicksPerAction: clickType,
            limit: repeatMode == "count" ? max(1, repeatCount) : 0,
            useFixedLocation: positionMode == "fixed",
            fixedPoint: CGPoint(x: fixedX, y: fixedY)
        )
    }

    /// 3-second countdown, then captures the mouse position as the fixed target.
    private func startPickingLocation() {
        positionMode = "fixed"
        pickCountdown = 3
        func tick() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                pickCountdown -= 1
                if pickCountdown > 0 {
                    tick()
                } else {
                    let loc = NSEvent.mouseLocation // bottom-left origin
                    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                    fixedX = (loc.x).rounded()
                    fixedY = (primaryHeight - loc.y).rounded() // convert to CG top-left origin
                }
            }
        }
        tick()
    }

    // MARK: - Reusable controls

    private func section<Content: View>(
        _ title: String, icon: String, @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            content()
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.bottom, 2)
        }
    }

    private func intervalUnit(_ value: Binding<Int>, _ label: String, help: String) -> some View {
        HStack(spacing: 4) {
            numberField(value, min: 0)
            Text(label).foregroundStyle(.secondary)
        }
        .help(help)
    }

    private func numberField(_ value: Binding<Int>, min minValue: Int) -> some View {
        TextField("", value: Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = max(minValue, $0) }
        ), format: .number)
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .frame(width: 58)
    }

    private func secondsField(_ value: Binding<Double>) -> some View {
        TextField("", value: Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = max(0.1, $0) }
        ), format: .number.precision(.fractionLength(0...1)))
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .frame(width: 48)
    }

    private func doubleField(_ value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number.precision(.fractionLength(0)))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 58)
    }

    private func radio(selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}
