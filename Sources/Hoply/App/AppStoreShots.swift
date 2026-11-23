import AgentKit
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum AppStoreShots {
    static let pixelWidth = 2_880
    static let pixelHeight = 1_800

    static func render(to directory: URL, now: Date) throws {
        func file(_ number: Int, _ slug: String) -> URL {
            directory.appendingPathComponent("appstore-\(number)-\(slug).png")
        }

        let live = model(now: now)
        live.showPreview(approvals: PreviewData.approvals(now: now), events: PreviewData.approvalEvents(now: now))
        keep(live, [PreviewData.approvalSession, SessionKey(source: .claudeCode, id: "pricing"),
                    SessionKey(source: .codexCLI, id: "hero")])
        try write(Composition(headline: "Your coding agents,\none menu bar",
                              subline: "Live sessions, permission prompts\nand today's spend, one click away.",
                              scale: 2, layout: .captionLeading) {
            PanelFrame {
                PanelHeader()
                PanelSections()
                    .padding(.top, 2)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                PanelFooter()
            }
        }, model: live, to: file(1, "panel"))

        let away = model(now: now)
        away.showPreview(settings: PreviewData.awaySettings)
        away.showPreview(approvals: PreviewData.approvals(now: now), events: PreviewData.approvalEvents(now: now))
        away.showPreview(replies: PreviewData.replies(now: now).filter { $0.key == PreviewData.copilotReplySession },
                         events: PreviewData.replyEvents(now: now))
        keep(away, [PreviewData.approvalSession, PreviewData.copilotReplySession])
        try write(Composition(headline: "Approve and\nanswer without\nswitching windows",
                              subline: "Allow a command or reply to an agent\nfrom the menu bar or a notification.",
                              scale: 2.5, layout: .captionTrailing) {
            PanelFrame {
                PanelHeader()
                WaitingCard(grouping: away.grouping, replyDraft: "Yes, give admin keys 600 a minute")
                    .padding(.top, 2)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }, model: away, to: file(2, "approve"))

        let spending = model(now: now)
        spending.history.show(PreviewData.history(now: now), page: .spending)
        try write(Composition(headline: "See what your coding agents cost",
                              subline: "API-equivalent spend by day, model and project. "
                                  + "Unknown prices are marked, never $0.",
                              scale: 2, layout: .captionTop, fadesBottom: true) {
            WindowFrame { DashboardView(plainSidebar: true).frame(width: 1_180, height: 700) }
        }, model: spending, to: file(3, "spending"))

        let limits = model(now: now)
        var plan = PreviewData.claudeLimits(now: now)
        plan?.scoped = []
        plan?.extraUsage = nil
        plan?.spend = nil
        plan?.unrecognizedKeys = []
        limits.showPreview(claudeLimits: plan)
        limits.history.show(PreviewData.history(now: now), page: .limits)
        try write(Composition(headline: "Know before you hit a limit",
                              subline: "Plan windows with burn rate, pace and a forecast for the reset.",
                              scale: 2, layout: .captionTop) {
            WindowFrame { DashboardView(plainSidebar: true).frame(width: 1_180, height: 700) }
        }, model: limits, to: file(4, "limits"))

        let search = model(now: now)
        search.history.show(PreviewData.history(now: now), page: .sessions)
        search.palette.edition = .appStore
        let liveTitles = Set(search.sessions.compactMap(\.title))
        let recents = PreviewData.paletteSessions(now: now).filter { !liveTitles.contains($0.title ?? "") }
        search.palette.show(query: "core", sessions: recents, projects: PreviewData.paletteProjects(now: now))
        try write(Composition(headline: "Find any session in a keystroke",
                              subline: "Search sessions, projects and pages from anywhere with one shortcut.",
                              scale: 2, layout: .captionTop) {
            ZStack(alignment: .top) {
                WindowFrame(dimmed: true) { DashboardView(plainSidebar: true).frame(width: 1_180, height: 700) }
                PaletteView(plainBackground: true)
                    .background(Floating(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)))
                    .padding(.top, 80)
            }
        }, model: search, to: file(5, "search"))

        let macs = model(now: now)
        macs.history.show(PreviewData.severalMacsHistory(now: now), page: .sessions)
        try write(Composition(headline: "All your Macs in one Dashboard",
                              subline: "Sessions and spend from every Mac on your Apple Account, "
                                  + "or filter to one.",
                              scale: 2, layout: .captionTop, fadesBottom: true) {
            WindowFrame { DashboardView(plainSidebar: true).frame(width: 1_180, height: 700) }
        }, model: macs, to: file(6, "macs"))
    }

    private static func model(now: Date) -> AppModel {
        let model = AppModel.preview(now: now)
        model.connections.show(statuses: PreviewData.storeConnectedStatuses)
        model.connections.show(access: PreviewData.storeConnectedAccess)
        model.setDefaultEditor("com.apple.dt.Xcode")
        return model
    }

    private static func keep(_ model: AppModel, _ keys: Set<SessionKey>) {
        for session in model.sessions where !keys.contains(session.key) {
            model.dismiss(session.key)
        }
    }

    private static func write(_ composition: Composition<some View>, model: AppModel, to file: URL) throws {
        let points = NSSize(width: CGFloat(pixelWidth) / composition.scale,
                            height: CGFloat(pixelHeight) / composition.scale)
        let failed = ShotError.render(file.lastPathComponent)
        // A fractional point size leaves a hairline of the white flattening fill along one edge.
        guard points.width == points.width.rounded(), points.height == points.height.rounded() else { throw failed }
        let host = NSHostingView(rootView: composition
            .frame(width: points.width, height: points.height)
            .environment(model)
            .environment(\.edition, .appStore)
            // An offscreen window is never key, so prominent buttons would draw in their inactive grey.
            .environment(\.controlActiveState, .key))
        host.frame = NSRect(origin: .zero, size: points)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        defer { window.orderOut(nil) }
        guard let space = NSColorSpace.displayP3.cgColorSpace,
              let blank = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bitmap = blank.retagging(with: .displayP3)
        else { throw failed }
        // Not bitmapImageRepForCachingDisplay: it follows the screen's scale, and the store takes exactly 2880×1800.
        bitmap.size = points
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let bounds = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        guard let drawn = bitmap.cgImage,
              let opaque = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw failed }
        opaque.setFillColor(.white)
        opaque.fill(bounds)
        opaque.draw(drawn, in: bounds)
        guard let image = opaque.makeImage(),
              let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString,
                                                                1, nil)
        else { throw failed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw failed }
    }

    private enum ShotError: Error {
        case render(String)
    }
}

private enum Brand {
    static let blue = Color(.displayP3, red: 0.40, green: 0.46, blue: 1.0)
    static let indigo = Color(.displayP3, red: 0.27, green: 0.22, blue: 0.82)
    static let ink = Color(red: 0.078, green: 0.086, blue: 0.110)
    static let muted = Color(red: 0.310, green: 0.341, blue: 0.392)
    static let shadow = Color(red: 0.094, green: 0.102, blue: 0.157)
}

private enum CaptionLayout {
    case captionLeading, captionTrailing, captionTop
}

private struct Composition<Content: View>: View {
    let headline: String
    let subline: String
    let scale: CGFloat
    let layout: CaptionLayout
    var fadesBottom = false
    @ViewBuilder var content: Content

    private var size: CGSize {
        CGSize(width: CGFloat(AppStoreShots.pixelWidth) / scale, height: CGFloat(AppStoreShots.pixelHeight) / scale)
    }

    private func pixels(_ value: CGFloat) -> CGFloat { value / scale }

    var body: some View {
        ZStack {
            Backdrop()
            switch layout {
            case .captionLeading:
                HStack(spacing: pixels(140)) {
                    caption(alignment: .leading)
                    content
                }
                .padding(.horizontal, pixels(220))
            case .captionTrailing:
                HStack(spacing: pixels(140)) {
                    content
                    caption(alignment: .leading)
                }
                .padding(.horizontal, pixels(220))
            case .captionTop:
                VStack(spacing: pixels(96)) {
                    caption(alignment: .center)
                    content
                }
                .padding(.top, pixels(124))
                .frame(width: size.width, height: size.height, alignment: .top)
            }
            if fadesBottom {
                Backdrop()
                    .mask {
                        VStack(spacing: 0) {
                            Color.clear
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: pixels(80))
                        }
                    }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func caption(alignment: HorizontalAlignment) -> some View {
        let text: TextAlignment = alignment == .center ? .center : .leading
        return VStack(alignment: alignment, spacing: pixels(34)) {
            Text(headline)
                .font(.system(size: pixels(116), weight: .semibold))
                .tracking(pixels(-2.5))
                .foregroundStyle(Color.white)
            Text(subline)
                .font(.system(size: pixels(46)))
                .foregroundStyle(Color.white.opacity(0.82))
                .lineSpacing(pixels(8))
        }
        .multilineTextAlignment(text)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: alignment == .center ? .infinity : nil,
               alignment: Alignment(horizontal: alignment, vertical: .center))
    }
}

private struct Backdrop: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: [Brand.blue, Brand.indigo], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0)], center: .top,
                               startRadius: 0, endRadius: max(proxy.size.width, proxy.size.height) * 0.6)
            }
        }
    }
}

private struct WindowFrame<Content: View>: View {
    var dimmed = false
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        content
            .padding(.top, 35)
            .overlay(alignment: .top) {
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(Brand.muted.opacity(0.3))
                            .frame(width: 11, height: 11)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background(Color.white.opacity(0.92))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Brand.ink.opacity(0.08))
                        .frame(height: 1)
                        .offset(y: 1)
                }
            }
            .overlay(shape.fill(Brand.shadow.opacity(dimmed ? 0.12 : 0)))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Brand.ink.opacity(0.10), lineWidth: 1))
            .background(Floating(shape: shape))
    }
}

private struct PanelFrame<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(spacing: 0) { content }
            .frame(width: 448)
            .background(Color(white: 0.925))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Brand.ink.opacity(0.10), lineWidth: 1))
            .background(Floating(shape: shape))
    }
}

private struct Floating: View {
    let shape: RoundedRectangle

    var body: some View {
        shape.fill(Color.white)
            .shadow(color: Brand.shadow.opacity(0.16), radius: 10, y: 4)
            .shadow(color: Brand.shadow.opacity(0.28), radius: 40, y: 28)
    }
}
