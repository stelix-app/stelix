// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AppKit
import StelixCore
import SwiftUI

/// A stem row: instrument icon (click turns on/off, hold solos), name, meter, slider and percentage.
/// `meter` is nil when there is no level to show. Reusable by the Studio.
struct StemRow: View {
    let stem: Stem
    let control: StemControl
    let meter: Double?
    let onToggle: (Bool) -> Void
    /// Holding the icon: this stem alone, or back to the mix from before its solo.
    let onSolo: () -> Void
    let onVolume: (Float) -> Void

    /// How long the icon is held before the solo starts (Gabriele, 18/11).
    static let holdToSolo = 0.4
    private static let nameWidth: CGFloat = 76
    private static let percentWidth: CGFloat = 40

    var body: some View {
        HStack(spacing: Tokens.spaceS) {
            // Not a Button: a click turns the stem on or off, holding it solos it. The long press comes first,
            // so it wins over the tap: the solo starts after 0.4 s with the button still down, and releasing
            // it then does not also toggle (measured in a key non-activating panel like Stelix's, 18/11).
            StemIcon(stem: stem)
                .foregroundStyle(control.enabled ? AnyShapeStyle(stem.color) : AnyShapeStyle(.tertiary))
                .frame(width: Tokens.rowHeight, height: Tokens.rowHeight)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: Self.holdToSolo) { onSolo() }
                .onTapGesture { onToggle(!control.enabled) }
                .help(control.enabled ? Copy.stemHelpOn : Copy.stemHelpOff)
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Copy.name(stem))
                .accessibilityValue(control.enabled ? Copy.stemOn : Copy.stemOff)
                .accessibilityAction { onToggle(!control.enabled) }
                .accessibilityAction(named: Copy.stemSolo) { onSolo() }

            // VoiceOver hears the name on the button and on the slider: the text beside them would be a third time.
            Text(Copy.name(stem))
                .font(Typography.body)
                .foregroundStyle(control.enabled ? .primary : .tertiary)
                .frame(width: Self.nameWidth, alignment: .leading)
                .accessibilityHidden(true)

            StemLevelMeter(value: control.enabled ? meter : nil, color: stem.color.opacity(0.6))

            if control.enabled {
                StemSlider(value: Double(control.volume), color: stem.color, label: Copy.name(stem)) {
                    onVolume(Float($0))
                }
            } else {
                // Stem off: in place of the slider a gray bar like the buffer's,
                // full up to the volume that will return when the stem is turned on again.
                CapsuleBar(fraction: Double(control.volume))
                    .frame(maxWidth: .infinity)
            }

            Text(Copy.percent(Double(control.volume)))
                .font(Typography.stat)
                .foregroundStyle(control.enabled ? .secondary : .tertiary)
                .frame(width: Self.percentWidth, alignment: .trailing)
                .accessibilityHidden(control.enabled)
        }
        .frame(height: Tokens.rowHeight)
    }
}

/// The volume slider of a stem: an `NSSlider` filled with the stem color. SwiftUI's `Slider` with `.tint`,
/// on the panel's Liquid Glass, draws the fill vibrant: pink came out light pink and orange came out yellow
/// (measured on macOS 27, 18/11). On the same glass the AppKit slider with `trackFillColor` keeps the color.
struct StemSlider: NSViewRepresentable {
    let value: Double
    let color: Color
    let label: String
    let onChange: (Double) -> Void

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: value, minValue: 0, maxValue: 1,
            target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.isContinuous = true
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.onChange = onChange
        // The volume comes back as a Float: a tiny difference while dragging must not move the knob.
        if abs(slider.doubleValue - value) > 0.001 { slider.doubleValue = value }
        slider.trackFillColor = NSColor(color)
        slider.setAccessibilityLabel(label)
        slider.setAccessibilityValueDescription(Copy.percent(value))
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    @MainActor final class Coordinator: NSObject {
        var onChange: (Double) -> Void

        init(onChange: @escaping (Double) -> Void) { self.onChange = onChange }

        @objc func changed(_ sender: NSSlider) { onChange(sender.doubleValue) }
    }
}

/// Thin gray capsule filled to `fraction`: the buffer bar and the slider of a stem that is off.
struct CapsuleBar: View {
    let fraction: Double
    static let height: CGFloat = 4

    var body: some View {
        Capsule().fill(.quaternary)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule().fill(.secondary)
                        .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: Self.height)
    }
}
