// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AppKit
import StelixCore
import SwiftUI

/// About, opened from Settings: name and version, copyright, the GPL, the third-party notices, the
/// repository, the website's privacy policy and the credits of every model from `ModelCatalog`. GPLv3 §5(d) asks interactive
/// interfaces for these notices, and NOTICE asks modified versions to keep the author attribution.
struct AboutOverlay: View {
    let settings: SettingsModel
    let catalog: ModelCatalog

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spaceM) {
            Button { settings.showMain() } label: {
                Label(Copy.aboutBack, systemImage: "chevron.left")
                    .font(Typography.footer)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: Tokens.spaceM) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Copy.appName).font(.title3.weight(.semibold))
                    Text(Copy.version(settings.version))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !AppInfo.copyrightHolder.isEmpty {
                        Text(Copy.copyright(AppInfo.copyrightHolder))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text(Copy.aboutFreeSoftware)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Tokens.spaceM) {
                Button(Copy.aboutLicense) { AppInfo.open(.license) }
                    .buttonStyle(.link)
                if let repository = AppInfo.repositoryURL {
                    Link(Copy.aboutSource, destination: repository)
                }
                // The website's privacy policy, in the app's language (GDPR Art. 13; WP260 par. 11).
                Link(Copy.aboutPrivacy, destination: ProjectSite.privacy(language: Bundle.main.preferredLocalizations.first))
            }
            .font(.callout)
            if AppInfo.url(of: .notices) != nil {
                VStack(alignment: .leading, spacing: Tokens.spaceS) {
                    Button(Copy.aboutNotices) { AppInfo.open(.notices) }
                        .buttonStyle(.link)
                        .font(.callout)
                    Text(Copy.aboutLGPL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            Text(Copy.aboutCredits)
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(catalog.packages, id: \.id) { package in
                VStack(alignment: .leading, spacing: 0) {
                    Text(Copy.name(package.id)).font(.callout.weight(.semibold))
                    Group {
                        Text(Copy.modelAuthor(package.id))
                        Text(package.source)
                        Text(Copy.license(package.license))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(Copy.aboutCreditsNote)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
