// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// The local tempo from the beat times of an analysis (Apple's MusicUnderstanding in the engine):
/// 60 over the median of the intervals around a point. The median ignores a missed or an extra
/// beat; a tempo that moves moves the number. See piani/ricerca-bpm.md.
public struct TempoMap: Sendable, Equatable {
    /// Intervals each side of the point: 9 in all, about 6 s at 90 BPM.
    public static let halfSpan = 4
    /// Tempos outside this are not shown.
    public static let plausible: ClosedRange<Double> = 30...300
    /// Before the first beat and after the last one the nearest tempo still holds for this long.
    public static let margin = 2.0

    /// Seconds, sorted.
    public let beats: [Double]

    public init(beats: [Double]) {
        self.beats = beats.sorted()
    }

    /// Beats per minute at `time` (seconds), or `nil` with fewer than two beats, far from them,
    /// or with an implausible tempo.
    public func bpm(at time: Double) -> Double? {
        guard beats.count >= 2, time >= beats[0] - Self.margin, time <= beats[beats.count - 1] + Self.margin
        else { return nil }
        // The interval [beats[i], beats[i + 1]) that contains `time`, clamped to the existing ones.
        let intervalCount = beats.count - 1
        let index = min(max(firstBeat(after: time) - 1, 0), intervalCount - 1)
        let low = max(0, index - Self.halfSpan)
        let high = min(intervalCount - 1, index + Self.halfSpan)
        return Self.tempo(beats: beats, intervals: low...high)
    }

    /// Index of the first beat after `time` (binary search).
    private func firstBeat(after time: Double) -> Int {
        var low = 0
        var high = beats.count
        while low < high {
            let middle = (low + high) / 2
            if beats[middle] <= time { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func tempo(beats: [Double], intervals: ClosedRange<Int>) -> Double? {
        let sorted = intervals.map { beats[$0 + 1] - beats[$0] }.sorted()
        let count = sorted.count
        let median = count % 2 == 1 ? sorted[count / 2] : (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        guard median > 0 else { return nil }
        let bpm = 60 / median
        return plausible.contains(bpm) ? bpm : nil
    }
}

/// The Live tempo across analyses of a sliding window. Short windows confuse the metric level
/// (measured: 91.5 becomes 183 or 61 now and then), so an estimate that is a metric relative of the
/// current tempo (half, double, a third, three times, two thirds, one and a half) is read at the
/// current level, unless it lasts `confirmations` analyses in a row: then it is the music's.
/// Any other estimate is a real change and is taken at once.
public struct TempoFollower: Sendable, Equatable {
    public static let ratios: [Double] = [1.0 / 3, 0.5, 2.0 / 3, 1.5, 2, 3]
    /// How far an estimate may be from a ratio to count as that ratio (the 4% of the literature,
    /// plus the drift of four seconds of a ramp).
    public static let tolerance = 0.05
    public static let confirmations = 4
    /// Changes smaller than this keep the number shown (one decimal on screen): the jitter of the
    /// estimate on steady music does not flicker.
    public static let deadband = 0.3
    /// The same for an estimate read at another metric level, which is less precise.
    public static let metricDeadband = 1.0

    public private(set) var bpm: Double?
    private var pendingRatio: Double?
    private var pendingCount = 0

    public init() {}

    /// The new estimate (`nil`: silence, or nothing found); returns the tempo to show.
    @discardableResult
    public mutating func observe(_ estimate: Double?) -> Double? {
        guard let estimate, estimate > 0 else {
            reset()
            return nil
        }
        guard let current = bpm else {
            bpm = estimate
            return estimate
        }
        let ratio = estimate / current
        if let metric = Self.ratios.first(where: { abs(ratio / $0 - 1) <= Self.tolerance }) {
            pendingCount = pendingRatio == metric ? pendingCount + 1 : 1
            pendingRatio = metric
            if pendingCount >= Self.confirmations {
                clearPending()
                bpm = estimate
            } else {
                take(estimate / metric, from: current, deadband: Self.metricDeadband)
            }
        } else {
            clearPending()
            take(estimate, from: current, deadband: Self.deadband)
        }
        return bpm
    }

    public mutating func reset() {
        bpm = nil
        clearPending()
    }

    private mutating func take(_ value: Double, from current: Double, deadband: Double) {
        if abs(value - current) >= deadband { bpm = value }
    }

    private mutating func clearPending() {
        pendingRatio = nil
        pendingCount = 0
    }
}

/// Which part of the last `seconds` of the Live is music to analyze: from the last pause on,
/// if it lasts at least `minimumMusic`. The engine passes the peak of each `blockSeconds` block.
public enum LiveTempoWindow {
    public static let seconds = 20.0
    /// One analysis every `hop` seconds.
    public static let hop = 4.0
    public static let blockSeconds = 0.25
    /// Less music than this after a pause gives no estimate yet.
    public static let minimumMusic = 6.0
    /// A silence at least this long is a pause; a shorter one is a rest, part of the music.
    public static let pause = 1.5
    /// The Live idle threshold: -60 dBFS.
    public static let threshold = LiveIdleTimer.threshold

    /// Where to read the tempo in the analyzed music (seconds from its start): where the user listens,
    /// the newest input minus the Live delay, plus half of the `hop` the number stays on screen;
    /// at most the end of the music.
    public static func listeningTime(musicSeconds: Double, delaySeconds: Double) -> Double {
        min(musicSeconds, max(0, musicSeconds - delaySeconds + hop / 2))
    }

    /// Seconds of music at the end of `peaks` (oldest first), or `nil`: silent now, or not enough music.
    public static func musicSeconds(peaks: [Float]) -> Double? {
        let pauseBlocks = Int((pause / blockSeconds).rounded())
        var silentRun = 0
        var start = 0
        for index in stride(from: peaks.count - 1, through: 0, by: -1) {
            if peaks[index] >= threshold {
                silentRun = 0
            } else {
                silentRun += 1
                if silentRun >= pauseBlocks {
                    // A pause at the very end: silent now.
                    if index + silentRun == peaks.count { return nil }
                    start = index + silentRun
                    break
                }
            }
        }
        let music = Double(peaks.count - start) * blockSeconds
        guard peaks[start...].contains(where: { $0 >= threshold }), music >= minimumMusic else { return nil }
        return music
    }
}
