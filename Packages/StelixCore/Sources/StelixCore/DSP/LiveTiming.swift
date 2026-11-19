// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// The seconds of a Live level on this Mac. The levels were measured on an M3 Max; on a slower
/// Mac a model pass can take longer than the level allows, and the model would fall behind. Then
/// hop and margin grow until the pass fits, and the delay grows with them: Live works later, but works.
public struct LiveSchedule: Equatable, Sendable {
    /// Seconds between one model pass and the next.
    public let hop: Double
    /// Distance from the window edge from which the output is taken.
    public let lookahead: Double
    /// Time after the edge before the band plays.
    public let margin: Double
    /// Hop and margin are longer than the level's, because this Mac's pass is slower.
    public let isStretched: Bool

    /// Expected delay between the original audio and the stems.
    public var delay: Double { hop + lookahead + margin }
    /// The time a model pass really has (see `LiveLevel.modelBudget`).
    public var modelBudget: Double { min(hop, margin + lookahead) }

    /// A measured pass up to this fraction of the level's budget keeps the level as it is
    /// (on the M3 Max, Pro runs at 0.76-0.80).
    public static let keepLoad = 0.85
    /// A stretched schedule gives the pass this load: room for a GPU that slows down as it warms up
    /// (a MacBook Air has no fan) or that another app is using.
    public static let stretchedLoad = 0.7
    /// Beyond this delay the level does not run on this Mac. It also keeps delay plus hop inside
    /// the 10 s timeline and hop plus lookahead inside the 7.8 s window.
    public static let maxDelay = 5.0

    /// The level as it is.
    public init(level: LiveLevel) {
        self.init(hop: level.hop, lookahead: level.lookahead, margin: level.margin, isStretched: false)
    }

    private init(hop: Double, lookahead: Double, margin: Double, isStretched: Bool) {
        self.hop = hop
        self.lookahead = lookahead
        self.margin = margin
        self.isStretched = isStretched
    }

    /// The schedule for a model pass of `passSeconds` on this Mac (`nil`: not measured, the level as it is).
    /// Returns `nil` when even `maxDelay` is not enough.
    public static func fitting(level: LiveLevel, passSeconds: Double?) -> LiveSchedule? {
        let plain = LiveSchedule(level: level)
        guard let pass = passSeconds, pass > keepLoad * plain.modelBudget else { return plain }
        // Rounded up to 50 ms, so the log and the delay read as round numbers.
        let needed = (pass / stretchedLoad * 20).rounded(.up) / 20
        let stretched = LiveSchedule(hop: max(level.hop, needed), lookahead: level.lookahead,
                                     margin: max(level.margin, needed - level.lookahead), isStretched: true)
        return stretched.delay <= maxDelay + 1e-9 ? stretched : nil
    }
}

/// Live timings in device frames. Recomputed at every rebuild, because the rate
/// can change (speakers at 48 kHz, AirPods in HFP at 24 kHz).
public struct LiveTiming: Equatable, Sendable {
    public let level: LiveLevel
    public let deviceRate: Double
    public let hopFrames: Int
    public let lookaheadFrames: Int
    /// Fixed distance between the most recent input frame and the one being played.
    public let delayFrames: Int
    /// Crossfade between one hop and the next: 15 ms.
    public let crossfadeFrames: Int
    /// Seconds a model pass has: the level's, or more on a slower Mac (`LiveSchedule`).
    public let modelBudget: Double
    /// Hop and margin were stretched for a slower Mac.
    public let isStretched: Bool

    public static let crossfadeSeconds = 0.015

    public init(level: LiveLevel, deviceRate: Double) {
        self.init(level: level, schedule: LiveSchedule(level: level), deviceRate: deviceRate)
    }

    public init(level: LiveLevel, schedule: LiveSchedule, deviceRate: Double) {
        self.level = level
        self.deviceRate = deviceRate
        hopFrames = Int((schedule.hop * deviceRate).rounded())
        lookaheadFrames = Int((schedule.lookahead * deviceRate).rounded())
        delayFrames = Int((schedule.delay * deviceRate).rounded())
        crossfadeFrames = Int((Self.crossfadeSeconds * deviceRate).rounded())
        modelBudget = schedule.modelBudget
        isStretched = schedule.isStretched
    }

    public var delaySeconds: Double { Double(delayFrames) / deviceRate }

    /// Seconds beyond the delay that the timeline can lag behind the ring before giving up.
    public static let modelStallSeconds = 3.0

    /// The model cannot keep up, and with the `.mutedWhenTapped` tap the Mac would stay silent:
    /// - it no longer delivers: the timeline (`available`) is behind the input (`written`) by more than the
    ///   delay plus `modelStallSeconds`;
    /// - it delivers too late to start: it does not play after delay plus `modelStallSeconds` of input.
    /// It counts in frames, not wall-clock time, so an aggregate that is late giving callbacks does not
    /// look like a stalled model.
    public func modelIsStalled(written: Int64, available: Int64, playing: Bool) -> Bool {
        let limit = Int64(delayFrames) + Int64((Self.modelStallSeconds * deviceRate).rounded())
        return written - available > limit || (!playing && written > limit)
    }
}
