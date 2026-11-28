// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Observation
import SwiftUI

/// Under the transpose, before macOS 27: tempo and key need macOS 27 (MusicUnderstanding), and the line
/// says so. The × hides it until Stelix quits; at the next launch it is there again (Gabriele,
/// 28/11). Nothing animates.
struct AnalysisNotice: View {
    /// Before macOS 27; on macOS 27 too with `STELIX_SHOW_MACOS27_NOTICE=1`, to see it.
    static var applies: Bool {
        if ProcessInfo.processInfo.environment["STELIX_SHOW_MACOS27_NOTICE"] == "1" { return true }
        return !MusicRow.analysisAvailable
    }

    var body: some View {
        if Self.applies && !Session.shared.closed {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.spaceS) {
                Text(Copy.analysisNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    Session.shared.closed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Copy.close)
                .accessibilityLabel(Copy.close)
            }
        }
    }

    /// Closed in this run of the app, in Live and Studio alike; never saved.
    @MainActor @Observable
    final class Session {
        static let shared = Session()
        var closed = false
    }
}
