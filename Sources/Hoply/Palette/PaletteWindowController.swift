import AppKit
import SwiftUI

final class PalettePanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }

    // ⌘↩ is offered here first and never reaches sendEvent when something claims it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, onKeyDown?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class PaletteWindowController: NSObject, NSWindowDelegate {
    static let margin: CGFloat = 28

    private let model: AppModel
    private var panel: PalettePanel?
    private var hosting: NSHostingView<AnyView>?
    private var generation = 0

    private enum Key {
        static let returnKey = 36
        static let keypadEnter = 76
        static let escape = 53
        static let down = 125
        static let up = 126
    }

    init(model: AppModel) {
        self.model = model
        super.init()
        model.palette.dismiss = { [weak self] in self?.close() }
    }

    func toggle() {
        if model.palette.isOpen {
            close()
        } else {
            show()
        }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.palette.open()
        generation += 1
        // A new identity per opening: the field starts empty and focused, the list at the top.
        hosting?.rootView = AnyView(PaletteView().padding(Self.margin).id(generation).environment(model))
        place(panel)
        panel.makeKeyAndOrderFront(nil)
        focusSearchField()
    }

    // @FocusState set in onAppear is dropped when the view appears before its window is key.
    private func focusSearchField(retry: Bool = true) {
        guard let panel, let hosting, model.palette.isOpen else { return }
        hosting.layoutSubtreeIfNeeded()
        if let field = Self.textField(in: hosting) {
            panel.makeFirstResponder(field)
        } else if retry {
            DispatchQueue.main.async { [weak self] in self?.focusSearchField(retry: false) }
        }
    }

    private static func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let found = textField(in: subview) { return found }
        }
        return nil
    }

    func close() {
        // orderOut resigns key, which calls back in here.
        guard model.palette.isOpen else { return }
        model.palette.close()
        panel?.orderOut(nil)
        hosting?.rootView = AnyView(EmptyView())
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func makePanel() -> PalettePanel {
        let size = NSSize(width: PaletteView.size.width + 2 * Self.margin,
                          height: PaletteView.size.height + 2 * Self.margin)
        let panel = PalettePanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        // NSPanel hides itself when its app is not active, which is the normal case for a hotkey.
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.delegate = self
        panel.onKeyDown = { [weak self] event in self?.handle(event) ?? false }
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.hosting = hosting
        return panel
    }

    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let top = visible.maxY - max(visible.height * 0.18 - Self.margin, 0)
        panel.setFrameOrigin(NSPoint(x: (visible.midX - size.width / 2).rounded(),
                                     y: max(top - size.height, visible.minY).rounded()))
    }

    private func handle(_ event: NSEvent) -> Bool {
        // An input method composing text owns Return, Esc and the arrows until it commits.
        if let editor = panel?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let palette = model.palette
        switch (Int(event.keyCode), modifiers) {
        case (Key.escape, []):
            close()
        case (Key.down, []):
            palette.move(by: 1)
        case (Key.up, []):
            palette.move(by: -1)
        case (Key.returnKey, []), (Key.keypadEnter, []):
            palette.runSelection(secondary: false)
        case (Key.returnKey, .command), (Key.keypadEnter, .command):
            palette.runSelection(secondary: true)
        case (_, .control) where event.charactersIgnoringModifiers == "n":
            palette.move(by: 1)
        case (_, .control) where event.charactersIgnoringModifiers == "p":
            palette.move(by: -1)
        default:
            return false
        }
        return true
    }
}
