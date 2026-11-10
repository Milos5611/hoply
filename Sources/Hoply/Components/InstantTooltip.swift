import AppKit
import SwiftUI

extension View {
    // For icon-only controls: shows on hover with no delay and doubles as the accessibility label.
    func tooltip(_ text: String) -> some View {
        modifier(InstantTooltip(text: text))
    }
}

private struct InstantTooltip: ViewModifier {
    let text: String
    @State private var anchor = TooltipAnchor()

    func body(content: Content) -> some View {
        content
            .background(TooltipAnchorView(anchor: anchor))
            .onHover { inside in
                if inside {
                    TooltipWindow.shared.show(text, for: anchor)
                } else {
                    TooltipWindow.shared.hide(for: anchor)
                }
            }
            .onChange(of: text) { _, new in TooltipWindow.shared.update(new, for: anchor) }
            .onDisappear { TooltipWindow.shared.hide(for: anchor) }
            .accessibilityLabel(Text(text))
    }
}

final class TooltipAnchor {
    weak var view: NSView?

    var screenRect: NSRect? {
        guard let view, let window = view.window, window.isVisible else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct TooltipAnchorView: NSViewRepresentable {
    let anchor: TooltipAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}

struct TooltipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(white: 0.12).opacity(0.95)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .fixedSize()
    }
}

private final class TooltipWindow {
    static let shared = TooltipWindow()

    private let panel: NSPanel
    private let host = NSHostingView(rootView: TooltipBubble(text: ""))
    private weak var owner: TooltipAnchor?
    private var watch: Task<Void, Never>?

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        // Above the menu bar popover, which itself sits above normal windows.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = host
    }

    func show(_ text: String, for anchor: TooltipAnchor) {
        guard let rect = anchor.screenRect else { return }
        owner = anchor
        place(text, over: rect)
        panel.orderFrontRegardless()
        watchPointer()
    }

    func update(_ text: String, for anchor: TooltipAnchor) {
        guard owner === anchor, let rect = anchor.screenRect else { return }
        place(text, over: rect)
    }

    func hide(for anchor: TooltipAnchor) {
        guard owner === anchor else { return }
        dismiss()
    }

    private func dismiss() {
        owner = nil
        watch?.cancel()
        watch = nil
        panel.orderOut(nil)
    }

    private func place(_ text: String, over rect: NSRect) {
        host.rootView = TooltipBubble(text: text)
        let size = host.fittingSize
        let gap: CGFloat = 6
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.maxY + gap)
        if let visible = (NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main)?.visibleFrame {
            if origin.y + size.height > visible.maxY { origin.y = rect.minY - gap - size.height }
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()
    }

    // Hover-out is not delivered when the popover closes or the view scrolls away under a still pointer.
    private func watchPointer() {
        watch?.cancel()
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled else { return }
                guard let rect = owner?.screenRect, rect.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation) else {
                    dismiss()
                    return
                }
            }
        }
    }
}
