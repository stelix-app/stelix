// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AppKit
import StelixCore
import SwiftUI

/// The update, in the same box as the model banner. In the sections: "Stelix 1.1 is available."
/// with Download…, Later and Skip This Version; Download… opens the details in place. In Settings,
/// after a click on "Stelix 1.1 available": the details only, with Download, whatever was put off.
/// Then the bar, the check, and the DMG in Downloads with "Quit and Open the DMG".
struct UpdateBanner: View {
    let updates: UpdateCenter
    /// Settings: no Later or Skip This Version, the details at once.
    let inSettings: Bool

    var body: some View {
        if let update = updates.available {
            VStack(alignment: .leading, spacing: Tokens.spaceS) {
                switch updates.stage {
                case .offer:
                    if updates.expanded || inSettings {
                        details(update)
                    } else {
                        offer(update)
                    }
                case .downloading(let fraction):
                    progress(update, fraction: fraction)
                case .verifying:
                    verifying
                case .ready(let dmg):
                    ready(update, dmg: dmg)
                case .failed(let failure):
                    failed(update, failure: failure)
                }
            }
            .bannerBox()
        }
    }

    private func offer(_ update: AvailableUpdate) -> some View {
        VStack(alignment: .leading, spacing: Tokens.spaceS) {
            HStack(alignment: .center, spacing: Tokens.spaceS) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(Copy.updateAvailable(update.version.description))
                    .font(Typography.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(Copy.modelDownloadEllipsis) { updates.showDetails() }
                    .stelixGlassButton()
            }
            putOffButtons
        }
    }

    /// Version, date, size (GitHub's, of the file that will arrive), the notes on GitHub, Download.
    private func details(_ update: AvailableUpdate) -> some View {
        VStack(alignment: .leading, spacing: Tokens.spaceM) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.spaceS) {
                    Text(Copy.updateTitle(update.version.description))
                        .font(Typography.body.weight(.semibold))
                    Spacer(minLength: Tokens.spaceS)
                    Text(Copy.bytes(update.dmg.size))
                        .font(Typography.stat)
                        .foregroundStyle(.secondary)
                }
                Text(published(update))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                notesLink(update)
                    .padding(.top, Tokens.spaceXS)
            }
            Text(Copy.updateSource)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Tokens.spaceS) {
                Spacer()
                Button(Copy.modelDownload) { updates.confirmDownload() }
                    .stelixGlassButton(prominent: true)
            }
            if !inSettings { putOffButtons }
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
            }
        }
    }

    private func failed(_ update: AvailableUpdate, failure: UpdateCenter.Failure) -> some View {
        VStack(alignment: .leading, spacing: Tokens.spaceS) {
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
            notesLink(update)
            if !inSettings { putOffButtons }
        }
    }

    private var putOffButtons: some View {
        HStack(spacing: Tokens.spaceM) {
            Spacer()
            putOffButton(Copy.updateSkip) { updates.skip() }
            putOffButton(Copy.updateLater) { updates.later() }
        }
    }

    /// Later and Skip This Version: quiet text, as the model banner's Not Now.
    private func putOffButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    /// The release page on GitHub, in the browser: what changed, what was fixed.
    private func notesLink(_ update: AvailableUpdate) -> some View {
        Link(destination: update.notesURL) {
            HStack(spacing: 3) {
                Text(Copy.updateNotes)
                Image(systemName: "arrow.up.right").imageScale(.small)
            }
        }
        .font(.caption)
    }

    private func published(_ update: AvailableUpdate) -> String {
        let current = updates.current.description
        guard let date = update.published else { return Copy.updateCurrent(current) }
        return Copy.updatePublished(date.formatted(date: .long, time: .omitted), current: current)
    }
}
