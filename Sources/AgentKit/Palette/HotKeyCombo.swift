import Foundation

public struct HotKeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    // Carbon's cmdKey, shiftKey, optionKey and controlKey, so rawValue goes to RegisterEventHotKey as is.
    public static let command = HotKeyModifiers(rawValue: 1 << 8)
    public static let shift = HotKeyModifiers(rawValue: 1 << 9)
    public static let option = HotKeyModifiers(rawValue: 1 << 11)
    public static let control = HotKeyModifiers(rawValue: 1 << 12)

    public static let all: HotKeyModifiers = [.command, .shift, .option, .control]
}

public struct HotKeyCombo: Codable, Equatable, Hashable, Sendable {
    public var keyCode: Int
    public var modifiers: HotKeyModifiers

    public init(keyCode: Int, modifiers: HotKeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let spaceKeyCode = 49
    public static let optionSpace = HotKeyCombo(keyCode: spaceKeyCode, modifiers: .option)
    public static let controlOptionSpace = HotKeyCombo(keyCode: spaceKeyCode, modifiers: [.control, .option])

    public var isValid: Bool {
        (0...127).contains(keyCode) && HotKeyModifiers.all.isSuperset(of: modifiers)
            && !modifiers.isDisjoint(with: [.command, .option, .control])
    }

    public var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    public static func keyName(_ keyCode: Int) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    private static let keyNames: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥",
        49: "Space", 50: "`", 51: "⌫", 53: "⎋", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 109: "F10", 111: "F12", 115: "↖", 116: "⇞", 117: "⌦", 118: "F4", 119: "↘", 120: "F2", 121: "⇟",
        122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}
