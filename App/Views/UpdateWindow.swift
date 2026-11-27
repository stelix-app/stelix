// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AppKit
import StelixCore
import SwiftUI

/// The update window: icon, "Stelix 1.2.0 is available", date and size, what's new in the app's
/// language (`ReleaseNotes`), the link to the full notes on GitHub, then Skip This Version, Later
/// and Download. Then the bar, the check, and the DMG in Downloads with "Quit and Open the DMG".
struct UpdateWindow: View {
    static let width: CGFloat = 520
    static let notesMaxHeight: CGFloat = 250
    static let iconSize: CGFloat = 52

    let updates: UpdateCenter
    /// The app's language ("it", "en"): picks the notes.
    let language: String?
    /// Hides the window without counting as its close button (Later and Skip already put it off).
    let close: () -> Void

    /// The notes' own height: the box is that tall, up to `notesMaxHeight`, then it scrolls.
    @State private var notesHeight: CGFloat = 0

    var body: some View {
        content
            .onChange(of: updates.available == nil) { _, gone in if gone { close() } }
    }

    @ViewBuilder
    private var content: some View {
        if let update = updates.available {
            VStack(alignment: .leading, spacing: Tokens.spaceM) {
                header(update)
                let blocks = update.notes?.blocks(for: language) ?? []
                if !blocks.isEmpty { notes(blocks) }
                VStack(alignment: .leading, spacing: Tokens.spaceXS) {
                    Link(destination: update.notesURL) {
                        HStack(spacing: 3) {
                            Text(Copy.updateFullNotes)
                            Image(systemName: "arrow.up.right").imageScale(.small)
                        }
                    }
                    Text(Copy.updateSource)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                footer(update)
            }
        }
    }

    private func header(_ update: AvailableUpdate) -> some View {
        HStack(alignment: .center, spacing: Tokens.spaceL) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: Self.iconSize, height: Self.iconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.spaceXS) {
                Text(Copy.updateAvailable(update.version.description))
                    .font(.title3.weight(.semibold))
                Text(subtitle(update))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The notes, scrolling past `notesMaxHeight`: plain text with inline bold, italic and code.
    private func notes(_ blocks: [ReleaseNotes.Block]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.spaceS) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    row(block)
                }
            }
            .padding(Tokens.spaceM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { notesHeight = $0 }
        }
        .frame(height: min(notesHeight, Self.notesMaxHeight))
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: Tokens.radiusBanner, style: .continuous))
    }

    @ViewBuilder
    private func row(_ block: ReleaseNotes.Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
        case .heading(let text):
            Text(Self.inline(text)).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            item(Text(verbatim: "•"), text)
        case .numbered(let marker, let text):
            item(Text(verbatim: marker).monospacedDigit(), text)
        }
    }

    private func item(_ marker: Text, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.spaceS) {
            marker.foregroundStyle(.secondary)
            Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, Tokens.spaceXS)
    }

    /// Inline Markdown, with any link left as plain text: nothing from the network opens anything.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var string = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in string.runs where run.link != nil {
            string[run.range].link = nil
        }
        return string
    }

    private func subtitle(_ update: AvailableUpdate) -> String {
        let size = Copy.bytes(update.dmg.size)
        guard let date = update.published else { return size }
        return Copy.updateSubtitle(date.formatted(date: .long, time: .omitted), size: size)
    }

    // MARK: - Buttons, download

    @ViewBuilder
    private func footer(_ update: AvailableUpdate) -> some View {
        switch updates.stage {
        case .offer:
            HStack(spacing: Tokens.spaceS) {
                Button(Copy.updateSkip) {
                    updates.skip()
                    close()
                }
                .stelixGlassButton()
                Spacer(minLength: Tokens.spaceS)
                Button(Copy.updateLater) {
                    updates.later()
                    close()
                }
                .stelixGlassButton()
                Button(Copy.modelDownload) { updates.confirmDownload() }
                    .stelixGlassButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
            }
        case .downloading(let fraction):
            progress(update, fraction: fraction)
        case .verifying:
            verifying
        case .ready(let dmg):
            ready(update, dmg: dmg)
        case .failed(let failure):
            failed(failure)
        }
    }

    private func progress(_ update: AvailableUpdate, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: Tokens.spaceS) {
            ProgressView(value: min(max(fraction, 0), 1))
            HStack(alignment: .firstTextBaseline, spacing: Tokens.spaceS) {
                let done = Int64(Double(update.dmg.size) * fraction)
                Text(Copy.modelProgress("\(Copy.bytes(done)) / \(Copy.bytes(update.dmg.size))"))
                    .font(Typography.stat)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(Copy.modelCancel) { updates.cancelDownload() }
                    .stelixGlassButton()
            }
        }
    }

    private var verifying: some View {
        HStack(alignment: .center, spacing: Tokens.spaceS) {
            ProgressView().controlSize(.small)
            Text(Copy.modelChecking)
                .font(Typography.stat)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(Copy.modelCancel) { updates.cancelDownload() }
                .stelixGlassButton()
        }
    }

    private func ready(_ update: AvailableUpdate, dmg: URL) -> some View {
        VStack(alignment: .leading, spacing: Tokens.spaceM) {
            HStack(alignment: .top, spacing: Tokens.spaceS) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Copy.updateReady(update.version.description))
                        .font(Typography.body)
                    Text(Copy.updateReadyHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: Tokens.spaceS) {
                Spacer()
                Button(Copy.studioShowInFinder) { NSWorkspace.shared.activateFileViewerSelecting([dmg]) }
                    .stelixGlassButton()
                // An AppKit action, not a Task: `NSApp.terminate` must not run inside one (StelixApp).
                Button(Copy.updateQuitAndOpen) {
                    NSWorkspace.shared.open(dmg)
                    NSApp.terminate(nil)
                }
                .stelixGlassButton(prominent: true)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ failure: UpdateCenter.Failure) -> some View {
        HStack(alignment: .center, spacing: Tokens.spaceS) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(Copy.updateFailure(failure))
                .font(Typography.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(Copy.retry) { updates.confirmDownload() }
                .stelixGlassButton()
        }
    }
}
