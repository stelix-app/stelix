// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import StelixCore
import SwiftUI

/// Original: the moon with "Stelix is asleep." and, below, what Live and Studio are for. All still.
/// While some model is missing, an offer to download them all at once (until "Not Now").
/// If Live turned itself off after minutes of silence, a gray line under the subtitle says why,
/// until the panel closes.
struct OriginalView: View {
    let models: ModelsModel
    var liveStoppedForSilence = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spaceL) {
            HStack(spacing: Tokens.spaceM) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Copy.originalTitle)
                        .font(Typography.idle)
                    Text(Copy.originalSubtitle)
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                    if liveStoppedForSilence {
                        Text(Copy.originalLiveStoppedForSilence)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Tokens.spaceXS)
                    }
                }
            }
            VStack(alignment: .leading, spacing: Tokens.spaceS) {
                hint(symbol: "waveform", mode: Copy.modeLive, text: Copy.originalLiveHint)
                hint(symbol: "record.circle", mode: Copy.modeStudio, text: Copy.originalStudioHint)
            }
            if models.showsAllOffer {
                MissingModelBanner(models: models, needed: ModelID.allCases, message: { _, size in
                    Copy.modelAllOffer(size)
                }, onClose: { models.closeAllOffer() }, closeLabel: Copy.modelNotNow)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Tokens.spaceS)
    }

    private func hint(symbol: String, mode: String, text: String) -> some View {
        HStack(spacing: Tokens.spaceS) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(mode).fontWeight(.medium) + Text(verbatim: " ") + Text(text).foregroundStyle(.secondary)
        }
        .font(Typography.body)
    }
}
