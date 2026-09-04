import Cocoa

/// Performs the actual clicking on a background queue.
final class ClickEngine: ObservableObject {

    enum MouseButton: String { case left, right, middle }
    enum RandomMode: String { case uniform, gaussian }
    enum PauseUnit: String { case clicks, seconds, minutes }

    struct Config {
        var baseIntervalMs: Int          // combined h/m/s/ms
        var randomize: Bool              // anti-detection: vary click time
        var randomAmountMs: Int          // ± range
        var randomMode: RandomMode
        var jitterPosition: Bool         // anti-detection: vary click position
        var jitterPx: Int
        var pauses: Bool                 // anti-detection: occasional random pauses
        var pauseEveryMin: Int           // pause after this many clicks OR secs/mins (random in range)
        var pauseEveryMax: Int
        var pauseEveryUnit: PauseUnit    // interpret the range as clicks, seconds, or minutes
        var pauseLenMinMs: Int           // pause duration (random in range)
        var pauseLenMaxMs: Int
        var humanHold: Bool              // anti-detection: vary press duration (down→up)
        var holdMinMs: Int
        var holdMaxMs: Int
        var button: MouseButton
        var clicksPerAction: Int         // 1 = single, 2 = double, 3 = triple
        var limit: Int                   // 0 = repeat until stopped
        var useFixedLocation: Bool
        var fixedPoint: CGPoint          // CG (top-left origin) coordinates

        /// Next delay in ms, optionally randomized to defeat bot detection.
        func nextDelayMs() -> Int {
            let base = Double(max(1, baseIntervalMs))
            guard randomize, randomAmountMs > 0 else { return Int(base) }
            let amount = Double(randomAmountMs)
            let offset: Double
            switch randomMode {
            case .uniform:
                offset = Double.random(in: -amount...amount)
            case .gaussian:
                // Box-Muller, sigma = amount/2, clamped to ±amount
                let u1 = Double.random(in: 0.000_001..<1)
                let u2 = Double.random(in: 0..<1)
                let z = (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
                offset = min(max(z * amount / 2, -amount), amount)
            }
            return Int(max(1, base + offset))
        }

        /// Random countdown until the next pause: a click count for .clicks,
        /// or a duration in ms for .seconds/.minutes.
        func nextPauseTarget() -> Int {
            let lo = max(1, min(pauseEveryMin, pauseEveryMax))
            let hi = max(1, max(pauseEveryMin, pauseEveryMax))
            let v = Int.random(in: lo...hi)
            switch pauseEveryUnit {
            case .clicks:  return v
            case .seconds: return v * 1_000
            case .minutes: return v * 60_000
            }
        }

        /// Random pause duration in ms.
        func nextPauseMs() -> Int {
            let lo = max(1, min(pauseLenMinMs, pauseLenMaxMs))
            let hi = max(1, max(pauseLenMinMs, pauseLenMaxMs))
            return Int.random(in: lo...hi)
        }

        /// Random press duration (mousedown → mouseup) in ms: bell curve within
        /// the range, since human clicks cluster around ~85 ms rather than
        /// spreading evenly. 0 when disabled (down/up posted back-to-back).
        func nextHoldMs() -> Int {
            guard humanHold else { return 0 }
            let lo = Double(max(1, min(holdMinMs, holdMaxMs)))
            let hi = Double(max(1, max(holdMinMs, holdMaxMs)))
            let u1 = Double.random(in: 0.000_001..<1)
            let u2 = Double.random(in: 0..<1)
            let z = (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
            let v = (lo + hi) / 2 + z * (hi - lo) / 4
            return Int(min(max(v, lo), hi))
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var clickCount = 0
    @Published private(set) var isPausing = false

    private var generation = 0
    private let queue = DispatchQueue(label: "autoclicker.engine", qos: .userInteractive)

    func start(config: Config) {
        guard !isRunning else { return }
        isRunning = true
        clickCount = 0
        isPausing = false
        generation += 1
        let gen = generation
        let untilPause = config.pauses ? config.nextPauseTarget() : Int.max
        queue.async { self.step(gen, config, done: 0, untilPause: untilPause) }
    }

    func stop() {
        guard isRunning else { return }
        generation += 1
        isRunning = false
        isPausing = false
    }

    func toggle(config: Config) {
        isRunning ? stop() : start(config: config)
    }

    // MARK: - Loop

    private func step(_ gen: Int, _ cfg: Config, done: Int, untilPause: Int) {
        guard gen == self.generationSnapshot() else { return }
        let clickStart = DispatchTime.now()
        performClick(cfg)
        // Time spent holding the button (and multi-click gaps) counts toward
        // the interval, so the configured click rate stays accurate.
        let clickMs = Int((DispatchTime.now().uptimeNanoseconds - clickStart.uptimeNanoseconds) / 1_000_000)
        let newDone = done + 1
        if cfg.limit > 0 && newDone >= cfg.limit {
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                self.clickCount = newDone
                self.stop()
            }
            return
        }

        var delay = max(1, cfg.nextDelayMs() - clickMs)
        // Count down in clicks, or in elapsed milliseconds, depending on the unit.
        var nextUntilPause = cfg.pauseEveryUnit == .clicks
            ? untilPause - 1
            : untilPause - delay
        var pausing = false
        if cfg.pauses && nextUntilPause <= 0 {
            delay += cfg.nextPauseMs()          // random-length pause
            nextUntilPause = cfg.nextPauseTarget() // random countdown until next pause
            pausing = true
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, gen == self.generation else { return }
            self.clickCount = newDone
            self.isPausing = pausing
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            self?.step(gen, cfg, done: newDone, untilPause: nextUntilPause)
        }
    }

    private func generationSnapshot() -> Int {
        var g = 0
        DispatchQueue.main.sync { g = self.generation }
        return g
    }

    // MARK: - Clicking

    private func performClick(_ cfg: Config) {
        var point: CGPoint
        if cfg.useFixedLocation {
            point = cfg.fixedPoint
        } else {
            point = CGEvent(source: nil)?.location ?? .zero
        }
        if cfg.jitterPosition, cfg.jitterPx > 0 {
            let r = Double(cfg.jitterPx)
            point.x += Double.random(in: -r...r)
            point.y += Double.random(in: -r...r)
        }

        let (downType, upType, button): (CGEventType, CGEventType, CGMouseButton)
        switch cfg.button {
        case .left:   (downType, upType, button) = (.leftMouseDown, .leftMouseUp, .left)
        case .right:  (downType, upType, button) = (.rightMouseDown, .rightMouseUp, .right)
        case .middle: (downType, upType, button) = (.otherMouseDown, .otherMouseUp, .center)
        }

        let source = CGEventSource(stateID: .hidSystemState)
        for i in 1...max(1, cfg.clicksPerAction) {
            let down = CGEvent(mouseEventSource: source, mouseType: downType,
                               mouseCursorPosition: point, mouseButton: button)
            let up = CGEvent(mouseEventSource: source, mouseType: upType,
                             mouseCursorPosition: point, mouseButton: button)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            down?.post(tap: .cghidEventTap)
            let hold = cfg.nextHoldMs() // re-rolled per press
            if hold > 0 { usleep(useconds_t(hold) * 1000) }
            up?.post(tap: .cghidEventTap)
            if i < cfg.clicksPerAction { usleep(25_000) } // gap inside double/triple click
        }
    }
}
