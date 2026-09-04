import Cocoa
import Carbon.HIToolbox

/// Global (background) start/stop hotkey via Carbon RegisterEventHotKey.
/// Works even when the app is not focused, no accessibility needed for the hotkey itself.
final class HotKeyManager: ObservableObject {

    static let shared = HotKeyManager()

    @Published var isRecording = false
    @Published private(set) var displayName = ""

    var onToggle: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false
    private var localMonitor: Any?

    private let keyCodeKey = "hotkeyKeyCode"
    private let modifiersKey = "hotkeyModifiers"

    private var keyCode: UInt32 {
        get {
            let v = UserDefaults.standard.object(forKey: keyCodeKey) as? Int
            return UInt32(v ?? kVK_F6) // default F6, like OP Auto Clicker
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: keyCodeKey) }
    }

    private var carbonModifiers: UInt32 {
        get { UInt32(UserDefaults.standard.integer(forKey: modifiersKey)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: modifiersKey) }
    }

    private init() {
        updateDisplayName()
    }

    // MARK: - Registration

    func activate() {
        installHandlerIfNeeded()
        register()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.onToggle?() }
            return noErr
        }, 1, &spec, selfPtr, nil)
        handlerInstalled = true
    }

    private func register() {
        unregister()
        let hotKeyID = EventHotKeyID(signature: OSType(0x41434C4B) /* 'ACLK' */, id: 1)
        RegisterEventHotKey(keyCode, carbonModifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    // MARK: - Recording a new hotkey

    func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        unregister() // so the current hotkey key can be re-chosen
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) { // Esc cancels
                self.finishRecording()
                return nil
            }
            self.keyCode = UInt32(event.keyCode)
            self.carbonModifiers = Self.carbonModifiers(from: event.modifierFlags)
            self.updateDisplayName()
            self.finishRecording()
            return nil
        }
    }

    private func finishRecording() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        isRecording = false
        register()
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

    private func updateDisplayName() {
        var name = ""
        let mods = carbonModifiers
        if mods & UInt32(controlKey) != 0 { name += "⌃" }
        if mods & UInt32(optionKey) != 0  { name += "⌥" }
        if mods & UInt32(shiftKey) != 0   { name += "⇧" }
        if mods & UInt32(cmdKey) != 0     { name += "⌘" }
        name += Self.keyName(for: Int(keyCode))
        displayName = name
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
    ]

    private static func keyName(for code: Int) -> String {
        keyNames[code] ?? "Key \(code)"
    }
}
