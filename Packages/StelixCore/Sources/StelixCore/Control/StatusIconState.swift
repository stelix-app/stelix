// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation

/// What the menu bar icon draws. Values are already quantized: two equal states give the
/// same image, and the drawer redraws only when the state changes.
public enum StatusIconState: Equatable, Sendable {
    /// Still: Original, and every moment when there is nothing to show.
    case idle
    /// Three bars from 0 to 1, in eighths, from low to high: bass, drums, voice or other (the loudest).
    case live(levels: [Float])
    /// Studio separation progress, in twentieths.
    case separating(progress: Double)
    /// Still, with a dot: a newer version of Stelix is available (only where it would be `idle`).
    case updateAvailable

    static let barSteps: Float = 8
    static let progressSteps = 20.0

    /// The menu bar timer exists only here: Live chosen, ready, and the separator playing.
    public static func animates(mode: Mode, phase: ModePhase, live: LivePhase?) -> Bool {
        mode == .live && phase == .active && live == .running
    }

    /// `download` is the fraction of a model download in progress (nil without one). It fills the
    /// icon like a separation, in twentieths, unless the Live is playing or the Studio separating:
    /// those keep their icon. No timer: it redraws only when the twentieth changes.
    /// `update`: a newer version waits (`UpdateCenter.showsDot`); it marks only the still icon.
    public static func make(
        mode: Mode, phase: ModePhase, live: LivePhase?, levels: [Stem: Float], studio: StudioSession.Stage,
        download: Double? = nil, update: Bool = false
    ) -> StatusIconState {
        if mode == .live, animates(mode: mode, phase: phase, live: live) {
            return .live(levels: liveBars(levels))
        }
        if mode == .studio, case .separating(let progress, _) = studio {
            return .separating(progress: twentieths(progress))
        }
        if let download { return .separating(progress: twentieths(download)) }
        return update ? .updateAvailable : .idle
    }

    private static func twentieths(_ fraction: Double) -> Double {
        (min(max(fraction, 0), 1) * progressSteps).rounded(.down) / progressSteps
    }

    /// Bass, drums and the louder of voice and other, each from 0 to 1 in eighths: like a
    /// spectrum analyzer, lows on the left (chosen after hands-on testing).
    public static func liveBars(_ levels: [Stem: Float]) -> [Float] {
        func bar(_ stems: Stem...) -> Float {
            let value = stems.map { meter(levels[$0] ?? 0) }.max() ?? 0
            return (value * barSteps).rounded() / barSteps
        }
        return [bar(.bass), bar(.drums), bar(.vocals, .other)]
    }

    /// RMS → 0...1 on the dB scale between -60 and 0, the same as the panel meters.
    public static func meter(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(max((db + 60) / 60, 0), 1)
    }
}
