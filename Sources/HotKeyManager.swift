import Cocoa
import Carbon.HIToolbox

/// Global (background) hotkeys via Carbon RegisterEventHotKey.
/// Works even when the app is not focused, no accessibility needed for the hotkey itself.
final class HotKeyManager: ObservableObject {

    static let shared = HotKeyManager()

    /// Each hotkey-able action. The raw value doubles as the Carbon hotkey ID.
    enum Action: UInt32, CaseIterable {
        case toggleClicker = 1
        case playRoutine = 2

        // toggleClicker keeps the pre-1.6 keys so existing setups migrate untouched.
        var keyCodeKey: String {
            self == .toggleClicker ? "hotkeyKeyCode" : "routineHotkeyKeyCode"
        }
        var modifiersKey: String {
            self == .toggleClicker ? "hotkeyModifiers" : "routineHotkeyModifiers"
        }
        var defaultKeyCode: UInt32 {
            self == .toggleClicker ? UInt32(kVK_F6) : UInt32(kVK_F7)
        }
    }

    /// Which action is currently waiting for a key press (nil = none).
    @Published private(set) var recordingAction: Action?
    @Published private(set) var names: [Action: String] = [:]

    var onToggleClicker: (() -> Void)?
    var onPlayRoutine: (() -> Void)?

    private var hotKeyRefs: [Action: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    private var localMonitor: Any?

    private func keyCode(for action: Action) -> UInt32 {
        let v = UserDefaults.standard.object(forKey: action.keyCodeKey) as? Int
        return UInt32(v ?? Int(action.defaultKeyCode))
    }

    private func carbonModifiers(for action: Action) -> UInt32 {
        UInt32(UserDefaults.standard.integer(forKey: action.modifiersKey))
    }

    private init() {
        Action.allCases.forEach(updateDisplayName)
    }

    func displayName(_ action: Action) -> String {
        names[action] ?? ""
    }

    func isRecording(_ action: Action) -> Bool {
        recordingAction == action
    }

    // MARK: - Registration

    func activate() {
        installHandlerIfNeeded()
        Action.allCases.forEach(register)
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            let action = Action(rawValue: hotKeyID.id)
            DispatchQueue.main.async { manager.handlePress(action) }
            return noErr
        }, 1, &spec, selfPtr, nil)
        handlerInstalled = true
    }

    private func handlePress(_ action: Action?) {
        switch action {
        case .toggleClicker: onToggleClicker?()
        case .playRoutine:   onPlayRoutine?()
        case nil:            break
        }
    }

    private func register(_ action: Action) {
        unregister(action)
        let hotKeyID = EventHotKeyID(signature: OSType(0x41434C4B) /* 'ACLK' */,
                                     id: action.rawValue)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(keyCode(for: action), carbonModifiers(for: action), hotKeyID,
                            GetApplicationEventTarget(), 0, &ref)
        hotKeyRefs[action] = ref
    }

    private func unregister(_ action: Action) {
        if let ref = hotKeyRefs.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
    }

    // MARK: - Recording a new hotkey

    func beginRecording(for action: Action) {
        guard recordingAction == nil else { return }
        recordingAction = action
        unregister(action) // so the current hotkey key can be re-chosen
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.recordingAction else { return event }
            if event.keyCode != UInt16(kVK_Escape) { // Esc cancels
                UserDefaults.standard.set(Int(event.keyCode), forKey: action.keyCodeKey)
                UserDefaults.standard.set(Int(Self.carbonModifiers(from: event.modifierFlags)),
                                          forKey: action.modifiersKey)
                self.updateDisplayName(action)
            }
            self.finishRecording()
            return nil
        }
    }

    private func finishRecording() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let action = recordingAction {
            register(action)
        }
        recordingAction = nil
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        return mods
    }

    // MARK: - Display

    private func updateDisplayName(_ action: Action) {
        var name = ""
        let mods = carbonModifiers(for: action)
        if mods & UInt32(controlKey) != 0 { name += "⌃" }
        if mods & UInt32(optionKey) != 0  { name += "⌥" }
        if mods & UInt32(shiftKey) != 0   { name += "⇧" }
        if mods & UInt32(cmdKey) != 0     { name += "⌘" }
        name += Self.keyName(for: Int(keyCode(for: action)))
        names[action] = name
    }

    private static let keyNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab",
        kVK_Delete: "Delete", kVK_Home: "Home", kVK_End: "End",
        kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_Grave: "`",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Backslash: "\\",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_Escape: "Esc", kVK_ForwardDelete: "⌦", kVK_Help: "Help",
    ]

    private static func keyName(for code: Int) -> String {
        keyNames[code] ?? "Key \(code)"
    }
}
