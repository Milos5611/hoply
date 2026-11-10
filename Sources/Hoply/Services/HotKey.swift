import AgentKit
import AppKit
import Carbon.HIToolbox
import Observation

@Observable
final class HotKey {
    enum Status: Equatable {
        case off
        case registered(HotKeyCombo)
        case failed(HotKeyCombo, reason: String)
    }

    private(set) var status: Status = .off
    private(set) var lastFired: Date?
    @ObservationIgnored var onPress: (() -> Void)?

    @ObservationIgnored private let isLive: Bool
    @ObservationIgnored private var wanted: HotKeyCombo?
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var reference: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?

    fileprivate static weak var registered: HotKey?
    fileprivate nonisolated static let signature: OSType = 0x486F_706C
    fileprivate nonisolated static let identifier: UInt32 = 1

    init(live: Bool = true) {
        isLive = live
    }

    var combo: HotKeyCombo? {
        switch status {
        case .off: return nil
        case .registered(let combo), .failed(let combo, _): return combo
        }
    }

    func update(enabled: Bool, combo: HotKeyCombo) {
        let next = enabled ? combo : nil
        guard isLive, next != wanted else { return }
        wanted = next
        lastFired = nil
        register()
    }

    func setSuspended(_ suspended: Bool) {
        guard isLive, suspended != self.suspended else { return }
        self.suspended = suspended
        register()
    }

    fileprivate func fired() {
        guard reference != nil else { return }
        lastFired = Date()
        onPress?()
    }

    private func register() {
        if let reference {
            UnregisterEventHotKey(reference)
            self.reference = nil
        }
        guard let combo = wanted else {
            status = .off
            return
        }
        guard !suspended else { return }
        guard installHandler() else {
            status = .failed(combo, reason: "macOS refused the key handler")
            return
        }
        var created: EventHotKeyRef?
        let result = RegisterEventHotKey(UInt32(combo.keyCode), UInt32(combo.modifiers.rawValue),
                                         EventHotKeyID(signature: Self.signature, id: Self.identifier),
                                         GetApplicationEventTarget(), 0, &created)
        if result == noErr, let created {
            reference = created
            status = .registered(combo)
        } else {
            status = .failed(combo, reason: Self.describe(result))
        }
    }

    private func installHandler() -> Bool {
        if handler != nil { return true }
        Self.registered = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetApplicationEventTarget(), hotKeyPressed, 1, &spec, nil, &handler) == noErr
    }

    private static func describe(_ result: OSStatus) -> String {
        switch Int(result) {
        case eventHotKeyExistsErr: return "another shortcut already uses it"
        case eventHotKeyInvalidErr: return "macOS does not accept this combination"
        default: return "error \(result)"
        }
    }
}

private nonisolated func hotKeyPressed(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                       _ context: UnsafeMutableRawPointer?) -> OSStatus {
    var pressed = EventHotKeyID()
    let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
    guard result == noErr, pressed.signature == HotKey.signature, pressed.id == HotKey.identifier else {
        return OSStatus(eventNotHandledErr)
    }
    Task { @MainActor in HotKey.registered?.fired() }
    return noErr
}

extension HotKey {
    func show(status: Status, lastFired: Date? = nil) {
        self.status = status
        self.lastFired = lastFired
    }
}

@Observable
final class HotKeyRecorder {
    private(set) var isRecording = false
    private(set) var rejection: String?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var completion: ((HotKeyCombo) -> Void)?

    private static let escapeKeyCode = 53

    func start(_ completion: @escaping (HotKeyCombo) -> Void) {
        stop()
        rejection = nil
        self.completion = completion
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, isRecording else { return event }
            handle(event)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        completion = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        let combo = HotKeyCombo(keyCode: Int(event.keyCode), modifiers: Self.modifiers(event.modifierFlags))
        if combo.keyCode == Self.escapeKeyCode, combo.modifiers.isEmpty {
            stop()
            return
        }
        guard combo.isValid else {
            rejection = combo.modifiers.isDisjoint(with: [.command, .option, .control])
                ? "Add ⌘, ⌥ or ⌃: \(combo.displayString) alone would block normal typing."
                : "\(combo.displayString) can't be a global shortcut."
            return
        }
        let completion = completion
        stop()
        completion?(combo)
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> HotKeyModifiers {
        var modifiers: HotKeyModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }
}
