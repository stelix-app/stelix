// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AppKit
import StelixCore
import SwiftUI

/// The three presets as a single native full-width segmented control: it reads as one
/// choice, not three buttons. With a hand-made mix no segment is lit. Reusable by the Studio.
struct PresetBar: View {
    let selected: Preset?
    let onSelect: (Preset) -> Void

    var body: some View {
        PresetSegments(selected: selected, onSelect: onSelect)
            .frame(maxWidth: .infinity)
    }
}

private struct PresetSegments: NSViewRepresentable {
    let selected: Preset?
    let onSelect: (Preset) -> Void

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: Preset.allCases.map(Copy.name),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fillEqually
        control.controlSize = .small
        control.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.onSelect = onSelect
        control.selectedSegment = selected.flatMap { Preset.allCases.firstIndex(of: $0) } ?? -1
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    @MainActor final class Coordinator: NSObject {
        var onSelect: (Preset) -> Void

        init(onSelect: @escaping (Preset) -> Void) { self.onSelect = onSelect }

        @objc func changed(_ sender: NSSegmentedControl) {
            guard Preset.allCases.indices.contains(sender.selectedSegment) else { return }
            onSelect(Preset.allCases[sender.selectedSegment])
        }
    }
}
