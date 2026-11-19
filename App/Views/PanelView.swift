// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AppKit
import StelixCore
import SwiftUI

/// The panel content: header, mode content, footer.
/// The background is already the panel's glass: no surface is added here.
struct PanelView: View {
    let controller: ModeController
    let live: LiveViewModel
    let studio: StudioViewModel
    /// Settings: the button in the header opens the overlay in place of the content.
    let settings: SettingsModel
    let models: ModelsModel
    /// Nil without a repository (`AppInfo.repositoryURL`): no banner, no settings line.
    let updates: UpdateCenter?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spaceL) {
            VStack(alignment: .leading, spacing: Tokens.spaceM) {
                HStack {
                    Text(Copy.appName).font(Typography.title)
                    Spacer()
                    Button {
                        settings.toggle()
                    } label: {
                        Image(systemName: "gear")
                            .font(Typography.footer)
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Copy.settings)
                }
                ModePicker(controller: controller)
            }

            if liveNeedsModel {
                // With Settings open the model's row says the same: one notice, not two.
                if !settings.isOpen {
                    MissingModelBanner(models: models, needed: ModelCatalog.models(for: live.level)) { _, size in
                        Copy.modelBanner(live: live.level, size: size)
                    }
                }
            } else if case .failed(let failure) = controller.phase, !leftoverLiveMissing {
                ErrorBanner(message: Copy.failure(failure)) { controller.select(controller.selected) }
            }

            // In Settings only after a click on its line there, and without Later or Skip.
            if let updates, settings.isOpen ? updates.showsSettingsBox : updates.showsBanner {
                UpdateBanner(updates: updates, inSettings: settings.isOpen)
            }

            if settings.isOpen {
                if settings.showsAbout {
                    AboutOverlay(settings: settings, catalog: models.library.store.catalog)
                } else {
                    SettingsOverlay(settings: settings, models: models, updates: updates)
                }
            } else {
                content
            }

            footer
        }
        .padding(Tokens.padding)
        // Choosing a section means wanting to see it: settings close.
        // Settings opened or closed: the update details fold (closing and reopening hides them).
        .onChange(of: settings.isOpen) { updates?.fold() }
        .onChange(of: controller.selected) {
            settings.close()
            // Each section looks at the model files again (a few file checks): the Studio then asks
            // for a model removed by hand instead of failing at the first separation.
            models.library.refresh()
        }
    }

    @ViewBuilder private var content: some View {
        switch controller.selected {
        case .original:
            OriginalView(models: models, liveStoppedForSilence: controller.liveStoppedForSilence)
        case .live:
            // On error only the banner speaks, above. Without the model the level stays, to choose another.
            if liveNeedsModel {
                LiveLevelSection(live: live)
            } else if case .failed = controller.phase {
                EmptyView()
            } else {
                LiveView(live: live)
            }
        case .studio:
            if studio.hiddenByFailure {
                EmptyView()
            } else {
                StudioView(studio: studio, models: models)
            }
        }
    }

    /// The Live didn't start (or stopped) because its level lacks a model that is still missing.
    /// If the engine says so but the model is there (removed and put back by hand), the plain
    /// error with Try Again is enough.
    /// Whatever the phase: right after choosing Live it's still the previous section's (`.active`
    /// from Original, `.stopping` from Studio), and showing the Live in between flashed its stems
    /// before the banner. Without the model the Live can't run, so the banner is always right.
    private var liveNeedsModel: Bool {
        guard controller.selected == .live else { return false }
        return !models.library.missing(ModelCatalog.models(for: live.level)).isEmpty
    }

    /// The Live's "missing model" while another section is already chosen: it's the Live's, not
    /// an error to show for a moment in Studio or Original.
    private var leftoverLiveMissing: Bool {
        guard controller.selected != .live, case .failed(let failure) = controller.phase else { return false }
        return failure.message == .missingWeights
    }

    /// Quit is a service command: plain text, no capsule, at the bottom right.
    private var footer: some View {
        HStack(spacing: Tokens.spaceS) {
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: Tokens.spaceXS) {
                    Image(systemName: "power")
                    Text(Copy.quit)
                    Text(Copy.quitShortcut).foregroundStyle(.tertiary)
                }
                .font(Typography.footer)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
    }
}
