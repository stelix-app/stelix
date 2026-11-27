// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AppKit
import StelixCore
import SwiftUI

/// The Live section: model, delay, preset, four stems and statistics.
/// No boxes: groups are separated with space.
struct LiveView: View {
    let live: LiveViewModel

    /// The statistics are for testing: visible only while holding ⌥.
    @State private var optionHeld = NSEvent.modifierFlags.contains(.option)
    @State private var flagsMonitor: Any?
    /// The first solo hides the hint under the stems for good (`SoloHint`).
    @AppStorage(SoloHint.seenKey) private var soloHintSeen = false

    private var phase: LivePhase { live.phase ?? .warming }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spaceM) {
            if live.permissionSuspected {
                PermissionBanner { live.openAudioPrivacySettings() }
            }

            LiveLevelSection(live: live)

            delayBlock

            Divider()

            PresetBar(selected: live.mix.matchingPreset) { live.apply($0) }

            VStack(alignment: .leading, spacing: Tokens.spaceS) {
                ForEach(Stem.live, id: \.self) { stem in
                    if let control = live.mix.controls[stem] {
                        StemRow(
                            stem: stem,
                            control: control,
                            meter: phase == .running ? live.meter(stem) : nil,
                            onToggle: { live.setEnabled(stem, $0) },
                            onSolo: {
                                live.hold(stem)
                                soloHintSeen = true
                            },
                            onVolume: { live.setVolume(stem, $0) })
                    }
                }
                // Directly under the last stem (Gabriele, 13/11): tempo and key on the left where the analysis
                // exists, the transpose on the right everywhere.
                MusicRow(bpm: phase == .running ? live.tempo : nil,
                         key: phase == .running ? live.key?.transposed(by: live.transpose.semitones) : nil,
                         showsAnalysis: MusicRow.analysisAvailable,
                         transpose: live.transpose,
                         onRaise: { live.raiseTranspose() },
                         onLower: { live.lowerTranspose() },
                         onSet: { live.setTranspose($0) })
                SoloHint()
            }

            if let stats = live.stats, optionHeld || stats.outputIsBluetooth {
                VStack(alignment: .leading, spacing: Tokens.spaceS) {
                    if optionHeld {
                        Text(statsLine(stats))
                            .font(Typography.stat)
                            .foregroundStyle(.secondary)
                    }
                    if stats.outputIsBluetooth {
                        HStack(spacing: Tokens.spaceXS) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(Copy.liveBluetooth).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .onAppear {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                let held = event.modifierFlags.contains(.option)
                MainActor.assumeIsolated { optionHeld = held }
                return event
            }
        }
        .onDisappear {
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
            flagsMonitor = nil
        }
    }

    // MARK: - Ritardo

    /// Until the model plays, the row says what it is doing, with the bar below. When it plays,
    /// the delay and the green check. Fixed height: the change moves nothing.
    private var delayBlock: some View {
        Group {
            if let status = phaseStatus {
                VStack(alignment: .leading, spacing: Tokens.spaceS) {
                    Text(status)
                        .font(Typography.liveStatus)
                        .foregroundStyle(.secondary)
                    if case .filling(let fraction) = phase {
                        BufferFill(fraction: min(max(fraction, 0), 1))
                    } else if phase == .waitingForAudio {
                        BufferFill(fraction: 0)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.spaceS) {
                    Text(Copy.liveDelay)
                        .font(Typography.delayLabel)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        // Debug: ⌥ + click measures the real delay, with no visible affordance.
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.option) { live.measureDelay() }
                        }
                    Text(delayText)
                        .font(Typography.delay)
                    Spacer()
                    if phase == .running {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.green)
                            .accessibilityLabel(Copy.liveReady)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.delayBlockHeight, alignment: .leading)
    }

    private static let delayBlockHeight: CGFloat = 40

    private var delayText: String {
        if phase == .running, let stats = live.stats { return Copy.delay(stats.delaySeconds) }
        return Copy.noValue
    }

    /// The sentence in place of the delay, until the model plays.
    private var phaseStatus: String? {
        switch phase {
        case .warming: Copy.liveWarming
        case .filling: Copy.liveFilling
        case .waitingForAudio: Copy.liveWaitingForAudio
        case .rebuilding: Copy.liveRebuilding
        case .running, .stopped, .stoppedForSilence: nil
        }
    }

    // MARK: - Statistiche

    private func statsLine(_ stats: LiveStats) -> String {
        var line = "\(Copy.statLoad) \(Copy.percent(stats.load))"
            + " · \(Copy.statModel) \(Copy.milliseconds(stats.modelMs))"
            + " · \(Copy.count(stats.underruns)) \(Copy.statUnderruns)"
        switch live.measurement {
        case .measuring: line += " · \(Copy.measuring)"
        case .done(let seconds): line += " · \(Copy.measured) \(Copy.delay(seconds))"
        case .failed(let failure): line += " · \(Copy.failure(failure))"
        case nil: break
        }
        return line
    }
}

/// "Model" and the level picker. Also shown alone, under the banner, when the level lacks its model.
struct LiveLevelSection: View {
    let live: LiveViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spaceS) {
            Text(Copy.liveModel)
                .font(.callout)
                .foregroundStyle(.secondary)
            LevelPicker(selected: live.level) { live.selectLevel($0) }
                .frame(maxWidth: .infinity)
        }
    }
}

/// Native full-width segmented control (SwiftUI's segmented Picker does not widen the segments).
private struct LevelPicker: NSViewRepresentable {
    let selected: LiveLevel
    let onSelect: (LiveLevel) -> Void

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: LiveLevel.allCases.map(Copy.name),
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
        control.selectedSegment = LiveLevel.allCases.firstIndex(of: selected) ?? 0
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    @MainActor final class Coordinator: NSObject {
        var onSelect: (LiveLevel) -> Void

        init(onSelect: @escaping (LiveLevel) -> Void) { self.onSelect = onSelect }

        @objc func changed(_ sender: NSSegmentedControl) {
            guard LiveLevel.allCases.indices.contains(sender.selectedSegment) else { return }
            onSelect(LiveLevel.allCases[sender.selectedSegment])
        }
    }
}
