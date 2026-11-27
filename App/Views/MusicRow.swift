// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import StelixCore
import SwiftUI

/// Under the last stem: tempo and key on the left (macOS 27 only, where the analysis exists), the
/// transpose on the right, like a macOS stepper: the name, the value in a field, the two arrows
/// (Gabriele, 25/11). The field takes a typed value too (Gabriele, 26/11): Return or leaving the field
/// applies it; a value the field refuses leaves the transpose as it was and shows the range in place of
/// the name until the next edit. Every change is heard at once; nothing animates.
struct MusicRow: View {
    let bpm: Double?
    /// Already transposed: the key that is heard.
    let key: MusicalKey?
    let showsAnalysis: Bool
    let transpose: Transpose
    let onRaise: () -> Void
    let onLower: () -> Void
    let onSet: (Transpose) -> Void

    @State private var text = ""
    /// What the panel last wrote in the field: only a different text is an edit to apply.
    @State private var shown = ""
    @State private var refused = false
    @FocusState private var editing: Bool

    /// Tempo and key come from MusicUnderstanding, from macOS 27; the transpose works on every macOS.
    static var analysisAvailable: Bool {
        if #available(macOS 27, *) { return true }
        return false
    }

    var body: some View {
        HStack(spacing: Tokens.spaceS) {
            if showsAnalysis {
                TempoLabel(bpm: bpm, key: key)
            }
            Spacer(minLength: Tokens.spaceS)
            Text(refused ? Copy.transposeRange : Copy.transpose)
                .font(.caption)
                .foregroundStyle(refused ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            HStack(spacing: Tokens.spaceXS) {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(Typography.stat)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44)
                    .padding(.horizontal, Tokens.spaceXS)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.background.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                    .focused($editing)
                    .onSubmit(apply)
                    .onExitCommand(perform: cancel)
                    .onChange(of: editing) { _, now in
                        if now { refused = false } else { apply() }
                    }
                    .onChange(of: text) { _, value in
                        if value != shown { refused = false }
                    }
                    .accessibilityLabel(Copy.transpose)
                    .accessibilityValue(Copy.transposeSpoken(transpose))
                // A nil action greys that arrow out: at ±12 it stops.
                Stepper(label: { EmptyView() },
                        onIncrement: transpose.canRaise ? { step(onRaise) } : nil,
                        onDecrement: transpose.canLower ? { step(onLower) } : nil)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Copy.transpose)
                .accessibilityValue(Copy.transposeSpoken(transpose))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: if transpose.canRaise { step(onRaise) }
                    case .decrement: if transpose.canLower { step(onLower) }
                    @unknown default: break
                    }
                }
            }
        }
        .onAppear { show(transpose) }
        // The arrows, a new engine (back to 0), the Studio's own value: the field follows unless typing.
        .onChange(of: transpose) { _, value in
            if !editing || text == shown { show(value) }
        }
    }

    /// The typed value, if the field takes it; otherwise the range in place of the name. Either way
    /// the field shows the transpose again, written the panel's way.
    private func apply() {
        guard text != shown else { return }
        if let typed = Transpose(typed: text) {
            refused = false
            if typed != transpose { onSet(typed) }
            show(typed)
        } else {
            refused = true
            show(transpose)
        }
    }

    /// Escape: the edit is dropped and the value stays.
    private func cancel() {
        show(transpose)
        refused = false
        editing = false
    }

    /// An arrow drops what was being typed: the arrow wins.
    private func step(_ action: () -> Void) {
        text = shown
        refused = false
        editing = false
        action()
    }

    private func show(_ value: Transpose) {
        shown = Copy.transposeValue(value)
        text = shown
    }
}
