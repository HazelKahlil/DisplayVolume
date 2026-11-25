import AppKit
import SwiftUI

/// Subclass of NSSlider that jumps cleanly to any clicked point on the track outside the knob
/// and avoids SwiftUI state-echo jitter during dragging.
private final class ClickableNativeSlider: NSSlider {
    var onTrackChange: ((Int, Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let sliderCell = cell as? NSSliderCell else {
            super.mouseDown(with: event)
            return
        }

        let local = convert(event.locationInWindow, from: nil)
        let knobRect = sliderCell.knobRect(flipped: isFlipped)
        var emittedInitialTrack = false
        if !knobRect.contains(local) {
            let track = sliderCell.barRect(flipped: isFlipped)
            let usableWidth = max(1, track.width - knobRect.width)
            let clampedX = min(track.maxX - knobRect.width / 2, max(track.minX + knobRect.width / 2, local.x))
            let fraction = (clampedX - (track.minX + knobRect.width / 2)) / usableWidth
            let newValue = minValue + (maxValue - minValue) * Double(max(0, min(1, fraction)))
            doubleValue = newValue
            onTrackChange?(Int(newValue.rounded()), true)
            emittedInitialTrack = true
        }

        if !emittedInitialTrack {
            onTrackChange?(Int(doubleValue.rounded()), true)
        }
        super.mouseDown(with: event)
        onTrackChange?(Int(doubleValue.rounded()), false)
    }
}

struct SmoothNativeSlider: NSViewRepresentable {
    let value: Int
    let minValue: Int
    let maxValue: Int
    let sessionKey: String
    let accessibilityTitle: String
    let onChange: (Int, Bool) -> Void

    init(
        value: Int,
        minValue: Int,
        maxValue: Int,
        sessionKey: String = "",
        accessibilityTitle: String,
        onChange: @escaping (Int, Bool) -> Void
    ) {
        self.value = value
        self.minValue = minValue
        self.maxValue = maxValue
        self.sessionKey = sessionKey
        self.accessibilityTitle = accessibilityTitle
        self.onChange = onChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionKey: sessionKey, onChange: onChange)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = ClickableNativeSlider(
            value: Double(value),
            minValue: Double(minValue),
            maxValue: Double(maxValue),
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:))
        )
        slider.isContinuous = true
        slider.controlSize = .regular
        slider.trackFillColor = NSColor.labelColor.withAlphaComponent(0.72)
        slider.setAccessibilityLabel(accessibilityTitle)
        slider.onTrackChange = { [weak coordinator = context.coordinator] val, isTracking in
            coordinator?.handleTrack(value: val, isTracking: isTracking)
        }
        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        context.coordinator.onChange = onChange
        nsView.setAccessibilityLabel(accessibilityTitle)

        // If the underlying device/route changed mid-drag, invalidate the active drag session so
        // mouseUp never commits the old device's value onto the newly selected device.
        if context.coordinator.sessionKey != sessionKey {
            context.coordinator.invalidateSession(newKey: sessionKey)
        }

        // Freeze range while actively dragging to prevent thumb jumps mid-gesture.
        if !context.coordinator.isTracking {
            nsView.minValue = Double(minValue)
            nsView.maxValue = Double(maxValue)
            let clamped = Double(min(maxValue, max(minValue, value)))
            let rounded = Int(clamped.rounded())
            if Int(nsView.doubleValue.rounded()) != rounded {
                nsView.doubleValue = clamped
            }
            context.coordinator.syncExternalValue(rounded)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var sessionKey: String
        var onChange: (Int, Bool) -> Void
        var isTracking = false
        private var gestureInvalidated = false
        private var lastSentValue: Int?

        init(sessionKey: String, onChange: @escaping (Int, Bool) -> Void) {
            self.sessionKey = sessionKey
            self.onChange = onChange
        }

        func invalidateSession(newKey: String) {
            sessionKey = newKey
            if isTracking {
                gestureInvalidated = true
            }
            lastSentValue = nil
        }

        func syncExternalValue(_ value: Int) {
            lastSentValue = value
        }

        func handleTrack(value: Int, isTracking: Bool) {
            if isTracking && !self.isTracking {
                gestureInvalidated = false
            }
            self.isTracking = isTracking
            guard !gestureInvalidated else {
                if !isTracking { gestureInvalidated = false }
                return
            }
            if lastSentValue != value || !isTracking {
                lastSentValue = value
                onChange(value, isTracking)
            }
        }

        @objc func valueChanged(_ sender: NSSlider) {
            guard !gestureInvalidated else { return }
            let rounded = Int(sender.doubleValue.rounded())
            if lastSentValue != rounded {
                lastSentValue = rounded
                onChange(rounded, isTracking)
            }
        }
    }
}

struct GlassCapsuleButton<Label: View>: View {
    let selected: Bool
    let disabled: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    init(
        selected: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.selected = selected
        self.disabled = disabled
        self.action = action
        self.label = label
    }

    var body: some View {
        #if LIQUID_GLASS_SDK
        if #available(macOS 26.0, *) {
            Button(action: action, label: label)
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(selected ? Color.primary.opacity(0.24) : nil)
                .fontWeight(selected ? .semibold : .regular)
                .disabled(disabled)
        } else {
            fallbackButton
        }
        #else
        fallbackButton
        #endif
    }

    private var fallbackButton: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(selected ? Color.primary.opacity(0.16) : Color.primary.opacity(0.065), in: Capsule())
                .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(disabled)
    }
}

struct GlassCircleButton<Label: View>: View {
    let active: Bool
    let helpText: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    init(
        active: Bool = false,
        helpText: String,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.active = active
        self.helpText = helpText
        self.action = action
        self.label = label
    }

    var body: some View {
        #if LIQUID_GLASS_SDK
        if #available(macOS 26.0, *) {
            Button(action: action, label: label)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .tint(active ? Color.primary.opacity(0.24) : nil)
                .help(helpText)
        } else {
            fallbackButton
        }
        #else
        fallbackButton
        #endif
    }

    private var fallbackButton: some View {
        Button(action: action) {
            label()
                .frame(width: 26, height: 26)
                .background(active ? Color.primary.opacity(0.18) : Color.primary.opacity(0.075), in: Circle())
                .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(helpText)
    }
}
