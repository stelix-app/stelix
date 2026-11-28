// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import SwiftUI

/// Like a macOS stepper: the name, the value in a field, the two arrows (Gabriele, 25/11). The transpose and
/// the Studio's speed. The field takes a typed value too (Gabriele, 26/11): Return or leaving the field
/// applies it; a value the field refuses leaves the value as it was and shows the range in place of the
/// name until the next edit. Every change is heard at once; nothing animates.
struct StepperField<Value: Equatable>: View {
    let label: String
    /// In place of the name after a value the field refuses.
    let rangeLabel: String
    let value: Value
    let format: (Value) -> String
    /// What the user typed; `nil` refuses it.
    let parse: (String) -> Value?
    /// For VoiceOver.
    let spoken: (Value) -> String
    let canRaise: Bool
    let canLower: Bool
    let onRaise: () -> Void
    let onLower: () -> Void
    let onSet: (Value) -> Void

    @State private var text = ""
    /// What the panel last wrote in the field: only a different text is an edit to apply.
    @State private var shown = ""
    @State private var refused = false
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: Tokens.spaceS) {
            Text(refused ? rangeLabel : label)
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
                    .accessibilityLabel(label)
                    .accessibilityValue(spoken(value))
                // A nil action greys that arrow out: at the end of the range it stops.
                Stepper(label: { EmptyView() },
                        onIncrement: canRaise ? { step(onRaise) } : nil,
                        onDecrement: canLower ? { step(onLower) } : nil)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue(spoken(value))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: if canRaise { step(onRaise) }
                    case .decrement: if canLower { step(onLower) }
                    @unknown default: break
                    }
                }
            }
        }
        .onAppear { show(value) }
        // The arrows, a new engine, a new clip: the field follows unless typing.
        .onChange(of: value) { _, now in
            if !editing || text == shown { show(now) }
        }
    }

    /// The typed value, if the field takes it; otherwise the range in place of the name. Either way the field
    /// shows the value again, written the panel's way.
    private func apply() {
        guard text != shown else { return }
        if let typed = parse(text) {
            refused = false
            if typed != value { onSet(typed) }
            show(typed)
        } else {
            refused = true
            show(value)
        }
    }

    /// Escape: the edit is dropped and the value stays.
    private func cancel() {
        show(value)
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

    private func show(_ value: Value) {
        shown = format(value)
        text = shown
    }
}
