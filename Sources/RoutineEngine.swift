import Cocoa

// MARK: - Model

/// A recorded routine: an ordered list of steps (click targets and key presses).
struct Routine: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var steps: [Step]

    struct Step: Identifiable, Equatable {
        enum Kind: String, Codable { case click, key }
        var id = UUID()
        var kind: Kind = .click
        var x: Double = 0        // click: CG (top-left origin) coordinates
        var y: Double = 0
        var button: String = "left" // click: "left" / "right"
        var keyCode: Int = 0     // key: virtual key code
        var flags: UInt64 = 0    // CGEventFlags raw value: modifiers (⇧⌘⌥⌃) held during the step
        var delayMs: Int = 0     // recorded gap since the previous step (0 for the first)
    }

    /// Number of click targets (key steps excluded).
    var clickCount: Int { steps.filter { $0.kind == .click }.count }
}

// Codable in extensions so the memberwise initializers survive; decoding
// falls back gracefully for fields added over time and for the legacy
// clicks-only "targets" format.
extension Routine.Step: Codable {
    private enum CodingKeys: String, CodingKey { case id, kind, x, y, button, keyCode, flags, delayMs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .click
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        button = try c.decodeIfPresent(String.self, forKey: .button) ?? "left"
        keyCode = try c.decodeIfPresent(Int.self, forKey: .keyCode) ?? 0
        flags = try c.decodeIfPresent(UInt64.self, forKey: .flags) ?? 0
        delayMs = try c.decodeIfPresent(Int.self, forKey: .delayMs) ?? 0
    }
}

extension Routine: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, steps, targets }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        if let s = try c.decodeIfPresent([Step].self, forKey: .steps) {
            steps = s
        } else {
            // Legacy format: routines saved before key support used "targets".
            steps = try c.decodeIfPresent([Step].self, forKey: .targets) ?? []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(steps, forKey: .steps)
    }
}

// MARK: - Persistence

/// Saved routines, persisted as JSON in UserDefaults.
final class RoutineStore: ObservableObject {
    static let shared = RoutineStore()
    private let key = "savedRoutines"

    @Published var routines: [Routine] = [] { didSet { save() } }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Routine].self, from: data) {
            routines = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(routines) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func nextName() -> String {
        var n = routines.count + 1
        while routines.contains(where: { $0.name == "Routine \(n)" }) { n += 1 }
        return "Routine \(n)"
    }
}

// MARK: - Engine

/// Records global clicks into a routine and replays routines with
/// human-like mouse movement that varies on every run.
final class RoutineEngine: ObservableObject {

    struct ReplayConfig {
        var offsetEnabled: Bool  // randomize the landing point per target per replay
        var offsetPx: Int        // max radius of that offset
        var loops: Int           // 0 = repeat until stopped
    }

    @Published private(set) var isRecording = false
    @Published private(set) var recordedCount = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var currentLoop = 0
    @Published private(set) var currentTarget = 0

    private var monitors: [Any] = []
    private var pendingSteps: [Routine.Step] = []
    private var lastStepAt: Date?

    private let queue = DispatchQueue(label: "autoclicker.routine", qos: .userInteractive)

    /// Thread-safe cancellation flag (checked from the replay queue,
    /// flipped from the main thread).
    private final class Flag {
        private let lock = NSLock()
        private var v = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return v }
            set { lock.lock(); v = newValue; lock.unlock() }
        }
    }
    private let stopFlag = Flag()

    // MARK: Recording

    /// Starts capturing clicks and key presses system-wide. Events inside
    /// this app's own windows (e.g. the Stop button) are not delivered to
    /// the global monitors, so they never pollute the recording.
    func startRecording() {
        guard !isRecording, !isPlaying else { return }
        pendingSteps = []
        recordedCount = 0
        lastStepAt = nil
        if let m = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] event in self?.captureClick(event) }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in self?.captureKey(event) }) {
            monitors.append(m)
        }
        isRecording = true
    }

    /// Milliseconds since the previous recorded step (capped).
    private func consumeGap() -> Int {
        let now = Date()
        let gap = lastStepAt.map { Int($0.distance(to: now) * 1000) } ?? 0
        lastStepAt = now
        return min(max(0, gap), 30_000)
    }

    private func captureClick(_ event: NSEvent) {
        let loc = NSEvent.mouseLocation // bottom-left origin
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        pendingSteps.append(Routine.Step(
            kind: .click,
            x: loc.x.rounded(),
            y: (primaryHeight - loc.y).rounded(), // CG top-left origin
            button: event.type == .rightMouseDown ? "right" : "left",
            flags: Self.cgFlags(from: event.modifierFlags), // ⇧⌘⌥⌃ held while clicking
            delayMs: consumeGap()))
        recordedCount = pendingSteps.count
    }

    private func captureKey(_ event: NSEvent) {
        guard !event.isARepeat else { return } // one step per physical press
        pendingSteps.append(Routine.Step(
            kind: .key,
            keyCode: Int(event.keyCode),
            flags: Self.cgFlags(from: event.modifierFlags),
            delayMs: consumeGap()))
        recordedCount = pendingSteps.count
    }

    /// NSEvent modifier flags → CGEventFlags raw value (only ⇧⌘⌥⌃).
    private static func cgFlags(from flags: NSEvent.ModifierFlags) -> UInt64 {
        var f: CGEventFlags = []
        if flags.contains(.shift)   { f.insert(.maskShift) }
        if flags.contains(.command) { f.insert(.maskCommand) }
        if flags.contains(.option)  { f.insert(.maskAlternate) }
        if flags.contains(.control) { f.insert(.maskControl) }
        return f.rawValue
    }

    /// Stops capturing; saves the routine if any steps were recorded.
    @discardableResult
    func stopRecording(saveAs name: String) -> Routine? {
        guard isRecording else { return nil }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        isRecording = false
        guard !pendingSteps.isEmpty else { return nil }
        let routine = Routine(name: name, steps: pendingSteps)
        pendingSteps = []
        RoutineStore.shared.routines.append(routine)
        return routine
    }

    // MARK: Replay

    func play(_ routine: Routine, config: ReplayConfig) {
        guard !isPlaying, !isRecording, !routine.steps.isEmpty else { return }
        isPlaying = true
        currentLoop = 0
        currentTarget = 0
        stopFlag.value = false
        queue.async { self.replay(routine, config) }
    }

    func stopPlaying() {
        stopFlag.value = true
    }

    private func replay(_ routine: Routine, _ cfg: ReplayConfig) {
        var loop = 0
        while !stopFlag.value {
            loop += 1
            let l = loop
            DispatchQueue.main.async { self.currentLoop = l }

            for (i, step) in routine.steps.enumerated() {
                if stopFlag.value { break }
                let t = i + 1
                DispatchQueue.main.async { self.currentTarget = t }

                // Recorded pacing, scaled randomly so no two replays share a rhythm.
                let gapMs = Int(Double(step.delayMs) * Double.random(in: 0.8...1.35))

                switch step.kind {
                case .click:
                    let dest = destination(for: step, cfg)
                    let from = currentMouseLocation()

                    let moveMs = moveHuman(from: from, to: dest)
                    if stopFlag.value { break }

                    // Human "settle" before pressing (aim verification time).
                    let reactionMs = Int.random(in: 60...200)
                    // Movement + reaction count toward the recorded gap.
                    let remaining = gapMs - moveMs - reactionMs
                    if remaining > 0 { sleepInterruptibly(ms: remaining) }
                    if stopFlag.value { break }
                    sleepMs(reactionMs)
                    click(at: dest, button: step.button, flags: step.flags)

                case .key:
                    // Keystrokes need no mouse travel — just the recorded gap
                    // (never instant; even touch-typists have inter-key delays).
                    sleepInterruptibly(ms: max(gapMs, Int.random(in: 40...110)))
                    if stopFlag.value { break }
                    pressKey(step.keyCode, flags: step.flags)
                }
            }

            if stopFlag.value { break }
            if cfg.loops > 0 && loop >= cfg.loops { break }
            // Breather between loops, also randomized.
            sleepInterruptibly(ms: Int.random(in: 400...1500))
        }
        DispatchQueue.main.async {
            self.isPlaying = false
        }
    }

    /// Landing point for a click step: exact position, or (when enabled) a
    /// uniformly random point inside a disc of `offsetPx` radius, so the
    /// same pixel is never clicked twice across replays.
    private func destination(for target: Routine.Step, _ cfg: ReplayConfig) -> CGPoint {
        var p = CGPoint(x: target.x, y: target.y)
        if cfg.offsetEnabled, cfg.offsetPx > 0 {
            let r = Double(cfg.offsetPx) * Double.random(in: 0...1).squareRoot()
            let a = Double.random(in: 0..<(2 * .pi))
            p.x += r * cos(a)
            p.y += r * sin(a)
        }
        return p
    }

    // MARK: Human-like movement

    /// Moves the cursor to `to` like a person would: a curved path with a
    /// speed profile that accelerates then decelerates, tiny tremor along
    /// the way, and an occasional overshoot-plus-correction on long hops.
    /// Returns the approximate elapsed time in ms.
    @discardableResult
    private func moveHuman(from: CGPoint, to: CGPoint) -> Int {
        var elapsed = 0
        var cur = from
        let dist = hypot(to.x - from.x, to.y - from.y)

        // ~1 in 4 long movements overshoots the target slightly, then corrects
        // — a signature of real ballistic mouse motion.
        if dist > 120, Double.random(in: 0...1) < 0.28 {
            let ux = (to.x - from.x) / dist
            let uy = (to.y - from.y) / dist
            let over = CGPoint(
                x: to.x + ux * Double.random(in: 4...16) + Double.random(in: -3...3),
                y: to.y + uy * Double.random(in: 4...16) + Double.random(in: -3...3))
            elapsed += glide(from: cur, to: over)
            cur = over
            elapsed += sleepMs(Int.random(in: 40...120)) // notice the miss
        }

        elapsed += glide(from: cur, to: to)
        return elapsed
    }

    /// One smooth stroke along a randomized cubic Bézier with a
    /// minimum-jerk velocity profile. Returns elapsed ms.
    private func glide(from: CGPoint, to: CGPoint) -> Int {
        let dist = hypot(to.x - from.x, to.y - from.y)
        guard dist > 1 else { return 0 }

        // Fitts-like duration: longer hops take longer, sublinearly; the
        // multiplier is re-rolled every stroke so replays never match.
        let durationMs = (120 + 2.4 * pow(dist, 0.62)) * Double.random(in: 0.85...1.25)

        // Bow the path perpendicular to the straight line, random side & depth.
        let px = -(to.y - from.y) / dist
        let py = (to.x - from.x) / dist
        let bow = dist * Double.random(in: 0.04...0.18) * (Bool.random() ? 1 : -1)
        let c1 = CGPoint(x: from.x + (to.x - from.x) * 0.3 + px * bow,
                         y: from.y + (to.y - from.y) * 0.3 + py * bow)
        let c2 = CGPoint(x: from.x + (to.x - from.x) * 0.7 + px * bow * Double.random(in: 0.3...0.9),
                         y: from.y + (to.y - from.y) * 0.7 + py * bow * Double.random(in: 0.3...0.9))

        let stepMs = 8 // ~125 Hz, typical pointing-device report rate
        let steps = max(2, Int(durationMs) / stepMs)
        for i in 1...steps {
            if stopFlag.value { break }
            let lin = Double(i) / Double(steps)
            // Minimum-jerk easing: slow-fast-slow, like real reaching motion.
            let t = lin * lin * lin * (10 - 15 * lin + 6 * lin * lin)
            var p = bezier(from, c1, c2, to, t)
            if i < steps { // tiny hand tremor, but land exactly on the point
                p.x += Double.random(in: -0.8...0.8)
                p.y += Double.random(in: -0.8...0.8)
            }
            postMove(p)
            usleep(useconds_t(stepMs) * 1000)
        }
        return Int(durationMs)
    }

    private func bezier(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint,
                        _ t: Double) -> CGPoint {
        let u = 1 - t
        let x = u*u*u * p0.x + 3*u*u*t * p1.x + 3*u*t*t * p2.x + t*t*t * p3.x
        let y = u*u*u * p0.y + 3*u*u*t * p1.y + 3*u*t*t * p2.y + t*t*t * p3.y
        return CGPoint(x: x, y: y)
    }

    // MARK: Events

    private func currentMouseLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func postMove(_ point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private func click(at point: CGPoint, button: String, flags: UInt64 = 0) {
        let (downType, upType, btn): (CGEventType, CGEventType, CGMouseButton) =
            button == "right"
                ? (.rightMouseDown, .rightMouseUp, .right)
                : (.leftMouseDown, .leftMouseUp, .left)
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(mouseEventSource: source, mouseType: downType,
                           mouseCursorPosition: point, mouseButton: btn)
        let up = CGEvent(mouseEventSource: source, mouseType: upType,
                         mouseCursorPosition: point, mouseButton: btn)
        if flags != 0 { // recorded modifiers (⇧⌘⌥⌃) held during the click
            down?.flags = CGEventFlags(rawValue: flags)
            up?.flags = CGEventFlags(rawValue: flags)
        }
        down?.post(tap: .cghidEventTap)
        usleep(useconds_t(Int.random(in: 45...130)) * 1000) // human press duration
        up?.post(tap: .cghidEventTap)
    }

    private func pressKey(_ keyCode: Int, flags: UInt64) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source,
                           virtualKey: CGKeyCode(keyCode), keyDown: true)
        let up = CGEvent(keyboardEventSource: source,
                         virtualKey: CGKeyCode(keyCode), keyDown: false)
        if flags != 0 { // recorded modifiers, e.g. ⇧ for capitals, ⌘ shortcuts
            down?.flags = CGEventFlags(rawValue: flags)
            up?.flags = CGEventFlags(rawValue: flags)
        }
        down?.post(tap: .cghidEventTap)
        usleep(useconds_t(Int.random(in: 40...110)) * 1000) // human key press duration
        up?.post(tap: .cghidEventTap)
    }

    // MARK: Sleeping

    @discardableResult
    private func sleepMs(_ ms: Int) -> Int {
        guard ms > 0 else { return 0 }
        usleep(useconds_t(ms) * 1000)
        return ms
    }

    /// Sleeps in small chunks so Stop reacts quickly even during long waits.
    private func sleepInterruptibly(ms: Int) {
        var remaining = ms
        while remaining > 0 && !stopFlag.value {
            let chunk = min(50, remaining)
            usleep(useconds_t(chunk) * 1000)
            remaining -= chunk
        }
    }
}
