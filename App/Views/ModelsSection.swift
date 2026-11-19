// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AppKit
import StelixCore
import SwiftUI

/// The models in Settings: one row per model with what it's for, its size and Download or Remove,
/// then "Download All Models…" and "Add Model…" side by side. No descriptions here (they're in
/// About): only the notice before a download shows them, in a banner box that takes the place of
/// the row that opened it, or of the whole list for Download All.
struct ModelsSection: View {
    let models: ModelsModel

    private var library: ModelLibrary { models.library }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spaceS) {
            Text(Copy.modelsTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
            if allNoticeOpen, let notice = library.notice {
                // "Download All" turns the whole list into its notice, which lists every model
                // with its use and size: like a row, or the banner in Original, it grows in place.
                ModelNotice(library: library, ids: notice).bannerBox()
            } else {
                ForEach(ModelID.allCases, id: \.self) { id in
                    ModelRow(models: models, id: id)
                }
                HStack(alignment: .firstTextBaseline, spacing: Tokens.spaceS) {
                    // With one model missing its own row is enough.
                    if library.missing(ModelID.allCases).count > 1, library.notice == nil {
                        Button(Copy.modelDownloadAll) { library.requestDownload(ModelID.allCases) }
                            .stelixGlassButton()
                            .controlSize(.small)
                    }
                    Button(Copy.modelAdd) { models.chooseFile() }
                        .stelixGlassButton()
                        .controlSize(.small)
                        .disabled(library.importing)
                    if library.importing {
                        Text(Copy.modelChecking).font(.caption).foregroundStyle(.secondary)
                    } else if case .added(let id) = library.imported {
                        // A model is made of more than one file: one alone does not complete it.
                        let missing = library.store.missingFiles([id]).map(\.name)
                        Text(missing.isEmpty
                             ? Copy.modelAdded(Copy.name(id))
                             : Copy.modelAddedPart(Copy.name(id), missing: missing.formatted(.list(type: .and))))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            // One bar for the whole queue, wherever it was started: the rows only show a spinner.
            if let download = library.download {
                DownloadProgress(library: library, download: download)
            }
            if case .failed(let failure) = library.imported {
                ModelProblem(models: models, failure: failure)
            }
            if !models.canRemove, !library.installed.isEmpty {
                Text(Copy.modelRemoveHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

extension ModelsSection {
    /// The notice of "Download All" is open (more than one model, all the missing ones).
    var allNoticeOpen: Bool {
        guard let notice = library.notice else { return false }
        return notice.count > 1 && notice == library.missing(ModelID.allCases)
    }
}

private struct ModelRow: View {
    let models: ModelsModel
    let id: ModelID
    /// Remove asks first: the model has to be downloaded again to use it.
    @State private var confirmingRemove = false

    private var library: ModelLibrary { models.library }

    var body: some View {
        let installed = library.installed.contains(id)
        let downloading = library.download.map { $0.ids.contains(id) } ?? false
        if library.notice == [id], !downloading {
            // The row grows into its notice, like the banner in Original: one Download, in the box.
            ModelNotice(library: library, ids: [id]).bannerBox()
        } else if confirmingRemove, installed {
            // The same way, the row becomes the question, in a box.
            VStack(alignment: .leading, spacing: Tokens.spaceM) {
                Text(Copy.modelRemoveConfirm(Copy.name(id), size: Copy.bytes(library.store.catalog.package(id).size)))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Tokens.spaceS) {
                    Spacer()
                    Button(Copy.modelCancel) { confirmingRemove = false }
                        .stelixGlassButton()
                    Button(Copy.modelRemove) {
                        confirmingRemove = false
                        library.remove(id)
                    }
                    .stelixGlassButton(prominent: true)
                    .disabled(!models.canRemove)
                }
            }
            .bannerBox()
        } else {
            VStack(alignment: .leading, spacing: Tokens.spaceS) {
                HStack(alignment: .center, spacing: Tokens.spaceS) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Copy.name(id))
                            .font(Typography.body)
                        Text(Copy.modelRow(id, size: size(installed)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if installed {
                        Button(Copy.modelRemove) { confirmingRemove = true }
                            .buttonStyle(.plain)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .disabled(!models.canRemove)
                    } else if downloading {
                        ProgressView().controlSize(.small)
                    } else if library.notice == nil {
                        // While a notice is open, its Download is the only one.
                        Button(Copy.modelDownload) { library.requestDownload([id]) }
                            .stelixGlassButton()
                            .controlSize(.small)
                    }
                }
                if let problem = library.problems.first(where: { $0.ids.contains(id) }) {
                    ModelProblem(models: models, failure: problem.failure)
                }
            }
        }
    }

    /// Installed: the whole model. Missing: what's left to download.
    private func size(_ installed: Bool) -> Int64 {
        installed ? library.store.catalog.package(id).size : library.missingBytes([id])
    }
}
