// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// Live levels. Timings come from measurements on an M3 Max (htdemucs p95 161.7 ms,
/// htdemucs_ft p95 624 ms, rule p95 ≤ 0.6 × hop). Intermediate revised later:
/// lookahead 0.25 and margin 0.25, delay always 1.0 s.
public enum LiveLevel: String, Codable, Sendable, CaseIterable {
    case base, intermediate, pro

    public var modelName: String {
        switch self {
        case .base, .intermediate: "htdemucs"
        case .pro: "htdemucs_ft"
        }
    }

    /// Seconds between one model pass and the next.
    public var hop: Double {
        switch self {
        case .base: 0.30
        case .intermediate: 0.5
        case .pro: 1.05
        }
    }

    /// Distance from the window edge from which the output is taken. Never below 0.1 s.
    public var lookahead: Double {
        switch self {
        case .base: 0.10
        case .intermediate: 0.25
        case .pro: 1.2
        }
    }

    /// Time the ML thread has to finish a pass: a band's edge starts playing
    /// `margin` seconds after the edge. At least 1.5 × the model's p95 (Intermediate: 0.25).
    public var margin: Double {
        switch self {
        case .base: 0.25
        case .intermediate: 0.25
        case .pro: 0.95
        }
    }

    /// Expected delay between the original audio and the stems.
    public var targetDelay: Double { hop + lookahead + margin }

    /// The time a model pass really has: it must finish before the next pass (`hop`)
    /// and before its band is needed (`margin + lookahead`). The load shown is p95 divided by this.
    public var modelBudget: Double { min(hop, margin + lookahead) }
}

/// Studio levels: Base in the engine (htdemucs_6s), Intermediate and Pro with the sidecar.
public enum StudioLevel: String, Codable, Sendable, CaseIterable {
    case base, intermediate, pro
}

extension LiveLevel {
    /// The level a fresh install starts from: Intermediate (same htdemucs as Base, steadier delay).
    public static let defaultLevel: LiveLevel = .intermediate

    /// The saved level, or the default when nothing (or something unknown) is saved.
    public static func initial(stored: String?) -> LiveLevel {
        stored.flatMap(LiveLevel.init(rawValue:)) ?? defaultLevel
    }
}

extension StudioLevel {
    /// The level a fresh install starts from: Base, so the first Studio download is small
    /// (htdemucs_6s, 110 MB, from Meta). A deliberate product choice.
    public static let defaultLevel: StudioLevel = .base

    /// The saved level, or the default when nothing (or something unknown) is saved.
    public static func initial(stored: String?) -> StudioLevel {
        stored.flatMap(StudioLevel.init(rawValue:)) ?? defaultLevel
    }
}
