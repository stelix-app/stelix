// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import StelixCore
import SwiftUI
import UniformTypeIdentifiers

/// The Studio section: record or load a file, separate into 6 stems, listen again and mix.
/// The whole view accepts the drop of an audio or video file.
struct StudioView: View {
    let studio: StudioViewModel
    let models: ModelsModel

    @State private var drop = DropHighlight()
    /// The first solo hides the hint under the stems for good (`SoloHint`).
    @AppStorage(SoloHint.seenKey) private var soloHintSeen = false
    /// The Studio engine has been preparing for longer than `slowStart`: only then does the sentence below the buttons
    /// say "Preparing…". It usually starts in a few tenths of a second, and changing sentence for so
    /// little caused a flicker when entering the Studio (like the one on Record, `looksAvailable`).
    @State private var slowStart = false
    private static let slowStart: Duration = .seconds(1)

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spaceM) {
            switch studio.stage {
            case .idle, .recording:
                start
            case .separating(let progress, let step):
                separating(progress, Copy.step(step))
            case .ready(let result):
                ready(result)
            case .failed(let failure):
                // The engine's safety net: if the level does lack a model, the banner in `start` says it.
                if !(failure.message == .missingWeights && studio.needsDownload) {
                    ErrorBanner(message: Copy.failure(failure)) { studio.retry() }
                }
                start
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            if drop.accepted && studio.canStart {
                RoundedRectangle(cornerRadius: Tokens.radiusBanner).strokeBorder(.tint, lineWidth: 2)
            }
        }
        .onDrop(of: [.fileURL], delegate: StudioDrop(studio: studio, highlight: drop))
        .task(id: studio.preparing) {
            slowStart = false
            guard studio.preparing else { return }
            try? await Task.sleep(for: Self.slowStart)
            if !Task.isCancelled { slowStart = studio.preparing }
        }
    }

    // MARK: - Start (idle, recording, failed): where the audio comes from, then the level

    private var start: some View {
        VStack(alignment: .leading, spacing: Tokens.spaceL) {
            if studio.permissionSuspected, isRecording {
                PermissionBanner { studio.openAudioPrivacySettings() }
            }
            if isRecording {
                recordingRow
            } else {
                if studio.needsDownload {
                    banner(for: studio.level)
                }
                VStack(alignment: .leading, spacing: Tokens.spaceS) {
                    HStack(spacing: Tokens.spaceS) {
                        Button { studio.record() } label: {
                            Label(Copy.studioRecord, systemImage: "record.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .stelixGlassButton(prominent: true)
                        .tint(.red)
                        Button { studio.chooseFile() } label: {
                            Label(Copy.studioChooseFile, systemImage: "folder")
                                .frame(maxWidth: .infinity)
                        }
                        .stelixGlassButton()
                    }
                    .controlSize(.large)
                    .disabled(!studio.looksAvailable || studio.needsDownload)
                    Text(studio.preparing && slowStart ? Copy.phasePreparing : Copy.studioOrDrop)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                levelSection
            }
        }
    }

    private var isRecording: Bool {
        if case .recording = studio.stage { return true }
        return false
    }

    private var recordingRow: some View {
        let seconds: Double = {
            if case .recording(let s) = studio.stage { return s }
            return 0
        }()
        return HStack(spacing: Tokens.spaceM) {
            Button { studio.stop() } label: {
                Label(Copy.studioStop, systemImage: "stop.fill")
            }
            .stelixGlassButton(prominent: true)
            .tint(.red)
            .controlSize(.large)
            LiveWave(peaks: studio.session.wave)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
            Text(Copy.clock(seconds))
                .font(Typography.stat)
                .monospacedDigit()
        }
    }

    private var levelSection: some View {
        VStack(alignment: .leading, spacing: Tokens.spaceS) {
            Text(Copy.studioLevel)
                .font(.callout)
                .foregroundStyle(.secondary)
            StudioLevelPicker(selected: studio.level, locked: nil, enabled: studio.looksAvailable) { studio.choose($0) }
                .frame(maxWidth: .infinity)
            if studio.level == .base {
                Text(Copy.studioBaseHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Separazione

    private func separating(_ progress: Double, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.spaceS) {
            ProgressView(value: min(max(progress, 0), 1))
            HStack(alignment: .firstTextBaseline, spacing: Tokens.spaceS) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Copy.percent(progress))
                    .font(Typography.stat)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button { studio.cancel() } label: {
                    Text(Copy.studioCancel)
                }
                .stelixGlassButton()
            }
        }
    }

    // MARK: - Stems ready: one row for the track, then the stems block

    private func banner(for level: StudioLevel, onClose: (() -> Void)? = nil) -> some View {
        MissingModelBanner(models: models, needed: ModelCatalog.models(for: level), message: { missing, size in
            Copy.modelBanner(studio: level, missing: missing, size: size)
        }, onClose: onClose)
    }

    private func ready(_ result: StemsResult) -> some View {
        VStack(alignment: .leading, spacing: Tokens.spaceL) {
            if let pending = studio.pendingLevel {
                banner(for: pending) { studio.cancelPendingLevel() }
            }
            sourceRow(result)
            Divider()
            VStack(alignment: .leading, spacing: Tokens.spaceM) {
                PresetBar(selected: studio.mix.matchingPreset) { studio.apply($0) }
                VStack(alignment: .leading, spacing: Tokens.spaceS) {
                    stems(result)
                    // Under the last stem, above play and "to the start", as in Live (Gabriele, 13/11).
                    // The tempo that is heard: the track's times the speed.
                    MusicRow(bpm: result.bpm(at: studio.position).map { $0 * studio.speed.factor },
                             key: result.key(at: studio.position)?.transposed(by: studio.transpose.semitones),
                             showsAnalysis: MusicRow.analysisAvailable,
                             transpose: studio.transpose,
                             onRaise: { studio.raiseTranspose() },
                             onLower: { studio.lowerTranspose() },
                             onSet: { studio.setTranspose($0) })
                    SpeedRow(speed: studio.speed,
                             onRaise: { studio.raiseSpeed() },
                             onLower: { studio.lowerSpeed() },
                             onSet: { studio.setSpeed($0) })
                    AnalysisNotice()
                    SoloHint()
                }
                transport(result)
            }
        }
    }

    private func sourceRow(_ result: StemsResult) -> some View {
        HStack(spacing: Tokens.spaceS) {
            Image(systemName: isFileSource ? "doc" : "waveform")
                .foregroundStyle(.secondary)
            Text(sourceName)
                .font(Typography.body)
                .lineLimit(1)
                .truncationMode(.middle)
            if let level = studio.session.stemsLevel {
                Text(Copy.name(level))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Tokens.spaceS)
            StudioMoreMenu(studio: studio)
        }
    }

    private var isFileSource: Bool {
        if case .file = studio.session.source { return true }
        return false
    }

    private var sourceName: String {
        switch studio.session.source {
        case .file(let path): URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        case .recording, nil: Copy.studioRecordingName
        }
    }

    private func stems(_ result: StemsResult) -> some View {
        VStack(alignment: .leading, spacing: Tokens.spaceS) {
            ForEach(Array(Stem.studio.enumerated()), id: \.element) { index, stem in
                if let control = studio.mix.controls[stem] {
                    VStack(alignment: .leading, spacing: 0) {
                        StemRow(
                            stem: stem,
                            control: control,
                            meter: studio.playing ? studio.meter(stem) : nil,
                            onToggle: { studio.setEnabled(stem, $0) },
                            onSolo: {
                                studio.hold(stem)
                                soloHintSeen = true
                            },
                            onVolume: { studio.setVolume(stem, $0) })
                        StemWaveform(
                            peaks: result.waveforms[stem] ?? [],
                            progress: result.duration > 0 ? studio.position / result.duration : 0,
                            color: stem.color,
                            enabled: control.enabled,
                            onSeek: { studio.seek($0 * result.duration) })
                            .padding(.leading, Tokens.rowHeight + Tokens.spaceS)
                    }
                    .cascadeIn(index: index)
                }
            }
        }
    }

    private func transport(_ result: StemsResult) -> some View {
        VStack(alignment: .leading, spacing: Tokens.spaceS) {
            HStack(spacing: Tokens.spaceS) {
                // "To the start", as in Logic: same glass and size as play, at its left.
                Button { studio.rewind() } label: {
                    Image(systemName: "backward.end.fill")
                        .frame(width: 20)
                }
                .stelixGlassButton()
                .controlSize(.large)
                .accessibilityLabel(Copy.studioToStart)
                Button { studio.playing ? studio.pause() : studio.play() } label: {
                    Image(systemName: studio.playing ? "pause.fill" : "play.fill")
                        .frame(width: 20)
                }
                .stelixGlassButton()
                .controlSize(.large)
                .accessibilityLabel(studio.playing ? Copy.studioPause : Copy.studioPlay)
                Text(Copy.clockPair(studio.position, result.duration))
                    .font(Typography.stat)
                    .foregroundStyle(.secondary)
                Spacer()
                if let progress = studio.saveProgress {
                    // A transposed or stretched save: how far it is, and the way out.
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(width: 72)
                        .accessibilityLabel(Copy.studioSave)
                    Button { studio.cancelSave() } label: {
                        Text(Copy.studioCancel)
                    }
                    .stelixGlassButton()
                    .controlSize(.large)
                } else if studio.session.savedFolder == nil {
                    Button { studio.save() } label: {
                        Label(Copy.studioSave, systemImage: "square.and.arrow.down")
                    }
                    .stelixGlassButton(prominent: true)
                    .controlSize(.large)
                    .disabled(!studio.session.canSave || studio.saving)
                } else {
                    Button { studio.revealInFinder() } label: {
                        Label(Copy.studioShowInFinder, systemImage: "folder")
                    }
                    .stelixGlassButton()
                    .controlSize(.large)
                }
            }
            if let folder = studio.session.savedFolder {
                Text(Copy.savedIn(URL(fileURLWithPath: folder).lastPathComponent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The "⋯" menu of the stems row: new recording, another file, Change Model.
/// A view of its own so that it is not rebuilt with `StudioView`, which during playback updates
/// at every tick of the player: with the menu open, SwiftUI built its items again each time
/// and the Change Model submenu never opened under the pointer.
private struct StudioMoreMenu: View {
    let studio: StudioViewModel

    var body: some View {
        Menu {
            Button { studio.record() } label: {
                Label(Copy.studioNewRecording, systemImage: "record.circle")
            }
            Button { studio.chooseFile() } label: {
                Label(Copy.studioChooseFile, systemImage: "folder")
            }
            Divider()
            Menu {
                ForEach(StudioLevel.allCases.filter { $0 != studio.session.stemsLevel }, id: \.self) { level in
                    Button { changeModel(to: level) } label: {
                        Text(Copy.name(level))
                    }
                }
            } label: {
                Label(Copy.studioChangeModel, systemImage: "arrow.triangle.2.circlepath")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Copy.studioMore)
        .disabled(!studio.canStart)
    }

    private func changeModel(to level: StudioLevel) {
        studio.beginModelChange()
        studio.choose(level)
    }
}

// MARK: - Drop

/// The drop border: it lights up only when the dragged file is one the Studio tries to read
/// (`MediaDrop`). The URL arrives asynchronously: `generation` discards the answers of a finished drag.
@MainActor @Observable final class DropHighlight {
    var accepted = false
    var generation = 0
}

struct StudioDrop: DropDelegate {
    let studio: StudioViewModel
    let highlight: DropHighlight

    func validateDrop(info: DropInfo) -> Bool {
        studio.canStart && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        highlight.generation += 1
        let generation = highlight.generation
        highlight.accepted = false
        guard studio.canStart, let provider = info.itemProviders(for: [.fileURL]).first else { return }
        let highlight = highlight
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            let ok = url.map(MediaDrop.accepts) ?? false
            Task { @MainActor in
                if highlight.generation == generation { highlight.accepted = ok }
            }
        }
    }

    func dropExited(info: DropInfo) {
        highlight.generation += 1
        highlight.accepted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        highlight.generation += 1
        highlight.accepted = false
        guard studio.canStart, let provider = info.itemProviders(for: [.fileURL]).first else { return false }
        let studio = studio
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, MediaDrop.accepts(url) else { return }
            Task { @MainActor in studio.load(url) }
        }
        return true
    }
}

/// Native full-width segmented control for the Studio level
/// (same scheme as the Live's `LevelPicker`, which is private and tied to `LiveLevel`).
private struct StudioLevelPicker: NSViewRepresentable {
    let selected: StudioLevel
    let locked: StudioLevel?
    let enabled: Bool
    let onSelect: (StudioLevel) -> Void

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: StudioLevel.allCases.map(Copy.name),
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
        let shown = locked ?? selected
        control.selectedSegment = StudioLevel.allCases.firstIndex(of: shown) ?? 0
        for (i, level) in StudioLevel.allCases.enumerated() {
            control.setEnabled(locked == nil || level == locked, forSegment: i)
        }
        control.isEnabled = enabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    @MainActor final class Coordinator: NSObject {
        var onSelect: (StudioLevel) -> Void

        init(onSelect: @escaping (StudioLevel) -> Void) { self.onSelect = onSelect }

        @objc func changed(_ sender: NSSegmentedControl) {
            guard StudioLevel.allCases.indices.contains(sender.selectedSegment) else { return }
            onSelect(StudioLevel.allCases[sender.selectedSegment])
        }
    }
}

/// Live waveform of the recording: 2 pt columns (1 of bar, 1 of space),
/// symmetric around the center. It scrolls left when it fills the width.
private struct LiveWave: View {
    let peaks: [Float]

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            guard !peaks.isEmpty else {
                context.fill(
                    Path(CGRect(x: 0, y: midY - 0.5, width: size.width, height: 1)),
                    with: .style(.quaternary))
                return
            }
            let columns = max(Int(size.width / 2), 1)
            let shown = peaks.suffix(columns)
            for (i, peak) in shown.enumerated() {
                let h = max(CGFloat(min(max(peak, 0), 1)) * size.height, 1)
                context.fill(
                    Path(CGRect(x: CGFloat(i) * 2, y: midY - h / 2, width: 1, height: h)),
                    with: .color(.red.opacity(0.8)))
            }
        }
        .accessibilityHidden(true)
    }
}
