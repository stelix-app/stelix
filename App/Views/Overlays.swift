// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import StelixCore
import SwiftUI

/// Error banner inside the panel: the only box allowed.
struct ErrorBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.spaceS) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(Typography.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onRetry) {
                Text(Copy.retry)
            }
            .stelixGlassButton()
        }
        .padding(Tokens.spaceM)
        .stelixGlass(in: RoundedRectangle(cornerRadius: Tokens.radiusBanner))
    }
}

/// Placeholder for Live and Studio until the real views arrive.
struct PhasePlaceholder: View {
    let phase: ModePhase

    var body: some View {
        Text(Copy.phase(phase))
            .font(Typography.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Tokens.spaceS)
    }
}

/// Audio permission banner: the Mac is not sending audio to Stelix. Same box as `ErrorBanner`.
struct PermissionBanner: View {
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.spaceS) {
            VStack(alignment: .leading, spacing: Tokens.spaceXS) {
                Text(Copy.permissionTitle)
                    .font(Typography.body.weight(.semibold))
                Text(Copy.permissionBody)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onOpen) {
                Text(Copy.permissionOpen)
            }
            .stelixGlassButton()
        }
        .padding(Tokens.spaceM)
        .stelixGlass(in: RoundedRectangle(cornerRadius: Tokens.radiusBanner))
    }
}

/// Settings overlay: in place of the mode content.
struct SettingsOverlay: View {
    let settings: SettingsModel
    let models: ModelsModel
    let updates: UpdateCenter?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spaceM) {
            Text(Copy.settings)
                .font(Typography.title)
            Toggle(Copy.settingsLaunchAtLogin, isOn: Binding(
                get: { settings.launchAtLogin },
                set: { settings.launchAtLogin = $0 }
            ))
            .toggleStyle(.switch)
            if settings.launchAtLoginFailed {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.spaceXS) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(Copy.settingsLoginFailed)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
            }
            if let updates {
                Toggle(Copy.settingsUpdates, isOn: Binding(
                    get: { updates.automatic },
                    set: { updates.automatic = $0 }
                ))
                .toggleStyle(.switch)
            }
            Divider()
            ModelsSection(models: models)
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Button { settings.showAbout() } label: {
                    HStack(spacing: Tokens.spaceXS) {
                        Text(Copy.about)
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text(Copy.version(settings.version))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let updates {
                    Text(verbatim: "·").font(.caption).foregroundStyle(.tertiary)
                    UpdateStatus(updates: updates)
                }
            }
        }
        .onAppear { updates?.clearCheckOutcome() }
        // No box: like Live and Studio, groups are set apart by space (no card
        // inside a card). The only box in the panel is a banner.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Next to the version in Settings: Check Now, then how it went; or the newest version found,
/// which opens its details in the box above, with Download, even if Later or Skip This Version
/// put it off in the sections.
struct UpdateStatus: View {
    let updates: UpdateCenter

    var body: some View {
        Group {
            if let update = updates.available {
                Button(Copy.settingsUpdateAvailable(update.version.description)) { updates.showDetails() }
                    .buttonStyle(.link)
            } else {
                switch updates.check {
                case .idle:
                    Button(Copy.settingsCheckNow) { Task { await updates.checkNow() } }
                        .buttonStyle(.link)
                case .checking:
                    Text(Copy.settingsChecking).foregroundStyle(.secondary)
                case .upToDate:
                    Text(Copy.settingsUpToDate).foregroundStyle(.secondary)
                case .failed:
                    Text(Copy.settingsCheckFailed).foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .lineLimit(1)
    }
}
