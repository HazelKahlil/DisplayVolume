import AppKit
import SwiftUI

private enum OSDMode: Equatable {
    case output
    case microphone
}

private struct OSDSnapshot: Equatable {
    var mode: OSDMode = .output
    var volume: Int = 0
    var limit: Int = 100
    var muted: Bool = false
    var deviceName: String = ""
}

@MainActor
private final class OSDModel: ObservableObject {
    @Published var snapshot = OSDSnapshot()

    func update(_ next: OSDSnapshot) {
        if snapshot != next {
            snapshot = next
        }
    }
}

private struct VolumeOSDView: View {
    @ObservedObject var model: OSDModel

    private var snap: OSDSnapshot { model.snapshot }

    private var effectiveVolume: Int {
        if snap.mode == .microphone {
            return snap.muted ? 0 : min(100, max(0, snap.volume))
        }
        return snap.muted ? 0 : min(snap.volume, snap.limit)
    }

    private var iconName: String {
        if snap.mode == .microphone {
            return snap.muted ? "mic.slash.fill" : "mic.fill"
        }
        if snap.muted || effectiveVolume == 0 { return "speaker.slash.fill" }
        if effectiveVolume < 34 { return "speaker.wave.1.fill" }
        if effectiveVolume < 68 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private var atCap: Bool {
        snap.mode == .output && !snap.muted && snap.limit < 100 && snap.volume >= snap.limit
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(snap.muted ? Color.secondary : Color.primary)
                .frame(width: 20)

            if snap.mode == .microphone && snap.muted {
                Text(L10n.micMutedOSDLabel)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Text(snap.deviceName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                GeometryReader { geo in
                    let width = geo.size.width
                    let fillFraction = CGFloat(max(0, min(100, effectiveVolume))) / 100.0
                    let limitFraction = CGFloat(max(1, min(100, snap.limit))) / 100.0

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.14))

                        if snap.mode == .output && snap.limit < 100 {
                            HStack(spacing: 0) {
                                Spacer(minLength: 0)
                                Rectangle()
                                    .fill(Color.primary.opacity(0.06))
                                    .frame(width: max(0, width * (1.0 - limitFraction)))
                            }
                            .clipShape(Capsule())
                        }

                        Capsule()
                            .fill(snap.muted ? Color.secondary.opacity(0.45) : Color.primary.opacity(0.88))
                            .frame(width: max(effectiveVolume > 0 ? 6 : 0, width * fillFraction))
                            .animation(.interactiveSpring(response: 0.14, dampingFraction: 0.88), value: effectiveVolume)

                        if snap.mode == .output && snap.limit < 100 {
                            Capsule()
                                .fill(Color.primary.opacity(0.42))
                                .frame(width: 2, height: 9)
                                .offset(x: max(0, min(width - 2, width * limitFraction - 1)))
                        }
                    }
                }
                .frame(height: 6)

                HStack(spacing: 4) {
                    Text(snap.muted ? L10n.mutedLabel : "\(effectiveVolume)%")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(snap.muted ? .secondary : .primary)
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 248, height: 42)
        .modifier(OSDLiquidGlassModifier())
    }
}

private struct OSDLiquidGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if LIQUID_GLASS_SDK
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
        #else
        content
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        #endif
    }
}

/// Non-activating top-right Liquid Glass volume HUD with generous transparent margin so shadows never clip.
/// Uses a monotonic presentation generation token so stale fade-out animations never hide newly triggered HUDs.
@MainActor
final class VolumeOSD {
    private static let shadowInset: CGFloat = 24
    private static let pillWidth: CGFloat = 248
    private static let pillHeight: CGFloat = 42

    private let model = OSDModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var presentationGeneration: UInt64 = 0
    private var lastOrigin: NSPoint?

    func show(volume: Int, limit: Int, muted: Bool, deviceName: String) {
        model.update(OSDSnapshot(mode: .output, volume: volume, limit: limit, muted: muted, deviceName: deviceName))
        present()
    }

    func showMic(volume: Int, muted: Bool, deviceName: String) {
        model.update(OSDSnapshot(mode: .microphone, volume: volume, limit: 100, muted: muted, deviceName: deviceName))
        present()
    }

    private func present() {
        presentationGeneration &+= 1
        let activeGen = presentationGeneration
        let panel = ensurePanel()
        positionTopRightIfNeeded(panel)

        if !panel.isVisible || panel.alphaValue < 0.99 {
            if !panel.isVisible {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.fadeOut(expectedGeneration: activeGen)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: work)
    }

    func hideImmediately() {
        presentationGeneration &+= 1
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
    }

    private func fadeOut(expectedGeneration: UInt64) {
        guard expectedGeneration == presentationGeneration, let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.presentationGeneration == expectedGeneration else { return }
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

        // Place hosting view inside a layer-less container view so shadow bloom never clips.
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

    private func positionTopRightIfNeeded(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: round(visible.maxX - Self.pillWidth - Self.shadowInset - 14),
            y: round(visible.maxY - Self.pillHeight - Self.shadowInset - 10)
        )
        if lastOrigin != origin {
            lastOrigin = origin
            panel.setFrameOrigin(origin)
        }
    }
}
