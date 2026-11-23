import AppKit
import SwiftUI

@MainActor
private final class OSDModel: ObservableObject {
    @Published var volume: Int = 0
    @Published var limit: Int = 100
    @Published var muted: Bool = false
    @Published var deviceName: String = ""
}

private struct VolumeOSDView: View {
    @ObservedObject var model: OSDModel

    private var effectiveVolume: Int {
        model.muted ? 0 : min(model.volume, model.limit)
    }

    private var iconName: String {
        if model.muted || effectiveVolume == 0 { return "speaker.slash.fill" }
        if effectiveVolume < 34 { return "speaker.wave.1.fill" }
        if effectiveVolume < 68 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private var atCap: Bool {
        !model.muted && model.limit < 100 && model.volume >= model.limit
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(model.muted ? Color.secondary : Color.primary)
                .frame(width: 20)

            GeometryReader { geo in
                let width = geo.size.width
                let fillFraction = CGFloat(max(0, min(100, effectiveVolume))) / 100.0
                let limitFraction = CGFloat(max(1, min(100, model.limit))) / 100.0

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.14))

                    if model.limit < 100 {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Rectangle()
                                .fill(Color.primary.opacity(0.06))
                                .frame(width: max(0, width * (1.0 - limitFraction)))
                        }
                        .clipShape(Capsule())
                    }

                    Capsule()
                        .fill(model.muted ? Color.secondary.opacity(0.45) : Color.primary.opacity(0.88))
                        .frame(width: max(effectiveVolume > 0 ? 6 : 0, width * fillFraction))
                        .animation(.interactiveSpring(response: 0.14, dampingFraction: 0.88), value: effectiveVolume)

                    if model.limit < 100 {
                        Capsule()
                            .fill(Color.primary.opacity(0.42))
                            .frame(width: 2, height: 9)
                            .offset(x: max(0, min(width - 2, width * limitFraction - 1)))
                    }
                }
            }
            .frame(height: 6)

            HStack(spacing: 4) {
                Text(model.muted ? L10n.mutedLabel : "\(effectiveVolume)%")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(model.muted ? .secondary : .primary)
                    .frame(minWidth: 34, alignment: .trailing)

                if atCap {
                    Text(L10n.limitWord)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.10), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 248, height: 42)
        .modifier(OSDLiquidGlassModifier())
    }
}

private struct OSDLiquidGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: Capsule())
                .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        }
    }
}

/// Non-activating top-right Liquid Glass volume HUD with generous transparent margin so shadows never clip.
@MainActor
final class VolumeOSD {
    private static let shadowInset: CGFloat = 24
    private static let pillWidth: CGFloat = 248
    private static let pillHeight: CGFloat = 42

    private let model = OSDModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(volume: Int, limit: Int, muted: Bool, deviceName: String) {
        model.volume = volume
        model.limit = limit
        model.muted = muted
        model.deviceName = deviceName

        let panel = ensurePanel()
        positionTopRight(panel)

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.fadeOut()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: work)
    }

    func hideImmediately() {
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
    }

    private func fadeOut() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.panel?.alphaValue == 0 else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let totalWidth = Self.pillWidth + Self.shadowInset * 2
        let totalHeight = Self.pillHeight + Self.shadowInset * 2

        let hosting = NSHostingView(rootView: VolumeOSDView(model: model).padding(Self.shadowInset))
        hosting.frame = NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
        hosting.autoresizingMask = []

        // Place hosting view inside a layer-less container view (matching AgentGauge) so shadow bloom never clips.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight))
        container.wantsLayer = false
        container.autoresizesSubviews = false
        container.addSubview(hosting)

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        p.contentView = container
        self.panel = p
        return p
    }

    private func positionTopRight(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let x = visible.maxX - Self.pillWidth - Self.shadowInset - 14
        let y = visible.maxY - Self.pillHeight - Self.shadowInset - 10
        panel.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
    }
}
