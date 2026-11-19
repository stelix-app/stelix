// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import StelixCore
import SwiftUI

/// In the Live or Studio panel when the chosen level lacks a model: what it's for and how much it
/// weighs, then, after Download…, the notice in place (who made it, where from, the license), then
/// the progress with Cancel. Same box as `ErrorBanner`.
struct MissingModelBanner: View {
    let models: ModelsModel
    /// Every model the level needs: only the missing ones are fetched.
    let needed: [ModelID]
    /// The sentence for the missing models and their size ("Pro uses a larger model: 672 MB.").
    let message: (_ missing: [ModelID], _ size: String) -> String
    /// Studio "Change Model" towards a level to download, or the offer in Original: it can be closed.
    var onClose: (() -> Void)?
    var closeLabel: String = Copy.modelCancel

    private var library: ModelLibrary { models.library }

    var body: some View {
        let missing = library.missing(needed)
        VStack(alignment: .leading, spacing: Tokens.spaceS) {
            if let download = library.download, !Set(download.ids).isDisjoint(with: needed) {
                DownloadProgress(library: library, download: download)
            } else if let notice = library.notice, notice == missing {
                ModelNotice(library: library, ids: notice)
            } else {
                HStack(alignment: .center, spacing: Tokens.spaceS) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                    Text(message(missing, Copy.bytes(library.missingBytes(needed))))
                        .font(Typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Another download running (Live, then Studio) doesn't stop this one: it queues.
                    Button(Copy.modelDownloadEllipsis) { library.requestDownload(needed) }
                        .stelixGlassButton()
                }
                if let problem = library.problems.first(where: { !Set($0.ids).isDisjoint(with: needed) }) {
                    ModelProblem(models: models, failure: problem.failure)
                }
                if let onClose {
                    HStack {
                        Spacer()
                        Button(closeLabel, action: onClose)
                            .buttonStyle(.plain)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .bannerBox()
    }
}

extension View {
    /// The banner's box (the only box in the panel): `ErrorBanner`, `MissingModelBanner`, the notice.
    func bannerBox() -> some View {
        padding(Tokens.spaceM)
            .stelixGlass(in: RoundedRectangle(cornerRadius: Tokens.radiusBanner))
    }
}

/// The notice before a download: the missing models grouped by who made them, where they come
/// from and their license (the three Demucs are one group), then the terms and the two buttons.
/// It shows up only when downloading, so once per model.
struct ModelNotice: View {
    let library: ModelLibrary
    let ids: [ModelID]

    /// Models with the same author, source and license, in the order of `ids`.
    private var groups: [[ModelID]] {
        var groups: [[ModelID]] = []
        for id in ids {
            let package = library.store.catalog.package(id)
            if let i = groups.firstIndex(where: {
                let other = library.store.catalog.package($0[0])
                return other.author == package.author && other.source == package.source && other.license == package.license
            }) {
                groups[i].append(id)
            } else {
                groups.append([id])
            }
        }
        return groups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spaceM) {
            ForEach(groups, id: \.self) { group in
                let package = library.store.catalog.package(group[0])
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group, id: \.self) { id in
                        HStack(alignment: .firstTextBaseline, spacing: Tokens.spaceS) {
                            Text(Copy.name(id)).font(Typography.body.weight(.semibold))
                            Text(Copy.modelUse(id))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: Tokens.spaceS)
                            Text(Copy.bytes(library.missingBytes([id])))
                                .font(Typography.stat)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Group {
                        Text(Copy.modelAuthor(group[0]))
                        Text(package.source)
                        Text(package.license == .undeclaredUnverified
                             ? "\(Copy.license(package.license)) \(Copy.modelMirrorWarning)"
                             : Copy.license(package.license))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(Copy.modelTerms)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Tokens.spaceS) {
                Spacer()
                Button(Copy.modelCancel) { library.dismissNotice() }
                    .stelixGlassButton()
                Button(Copy.modelDownload) { library.confirmDownload() }
                    .stelixGlassButton(prominent: true)
            }
        }
    }
}

/// The bar of the downloads in progress: one progress over the whole queue, with Cancel for all.
struct DownloadProgress: View {
    let library: ModelLibrary
    let download: ModelLibrary.Download

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spaceS) {
            ProgressView(value: min(max(download.fraction, 0), 1))
            HStack(alignment: .firstTextBaseline, spacing: Tokens.spaceS) {
                Text(Copy.modelProgress(amounts))
                    .font(Typography.stat)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(Copy.modelCancel) { library.cancelDownload() }
                    .stelixGlassButton()
            }
        }
    }

    private var amounts: String {
        let done = Int64(Double(download.total) * download.fraction)
        return "\(Copy.bytes(done)) / \(Copy.bytes(download.total))"
    }
}

/// How the last download or import went wrong. A source that's gone offers "Add Model…".
struct ModelProblem: View {
    let models: ModelsModel
    let failure: ModelLibrary.Failure

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.spaceXS) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(Copy.modelFailure(failure))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if failure == .unavailable {
                Button(Copy.modelAdd) { models.chooseFile() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
        }
        .font(.caption)
    }
}
