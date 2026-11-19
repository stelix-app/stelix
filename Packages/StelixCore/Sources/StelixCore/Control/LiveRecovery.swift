// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// Decides when Live must be rebuilt or abandoned for reasons the silence watchdog
/// does not see, because it only counts the frames that arrive:
/// - **stall**: the aggregate gives no callbacks (seen once for 5 s at startup in early
///   measurements) or stops giving them. After `stallSeconds` without new frames it rebuilds once; if the new
///   pipeline also stays still, it gives up.
/// - **failed rebuild** (tap or aggregate that cannot be created): retry after each of the
///   `retryDelays`, then give up.
/// Giving up means `.failure` plus `.live(.stopped)`: the tap goes away, the audio returns to normal and
/// the section goes to error. A new frame resets all the counters.
///
/// Times are monotonic-clock seconds, passed in by the caller.
public struct LiveRecovery: Sendable {
    public enum Action: Equatable, Sendable { case none, rebuild, giveUp }

    public let stallSeconds: Double
    public let retryDelays: [Double]
    private static let maxStallRebuilds = 1

    private var lastWritten: Int64 = 0
    private var lastProgress: Double = 0
    private var stallRebuilds = 0
    private var failures = 0
    private var retryAt: Double?

    public init(stallSeconds: Double = 4, retryDelays: [Double] = [0.5, 2]) {
        self.stallSeconds = stallSeconds
        self.retryDelays = retryDelays
    }

    /// A new pipeline has started: its frames count from 0.
    public mutating func pipelineStarted(at now: Double) {
        lastWritten = 0
        lastProgress = now
        retryAt = nil
    }

    /// Creating the pipeline failed. `.none` if there is still an attempt (it will arrive as
    /// `.rebuild` from `observe`), `.giveUp` if they ran out.
    public mutating func buildFailed(at now: Double) -> Action {
        failures += 1
        guard failures <= retryDelays.count else { return .giveUp }
        retryAt = now + retryDelays[failures - 1]
        return .none
    }

    /// To be called at regular intervals with the frames written by the current pipeline. `outputRunning`:
    /// whether the output device does IO (`kAudioDevicePropertyDeviceIsRunningSomewhere`); with the Mac
    /// silent it is false, the tap gives no frames and it waits without counting the stall.
    public mutating func observe(at now: Double, written: Int64, outputRunning: Bool = true) -> Action {
        if let retry = retryAt {
            guard now >= retry else { return .none }
            retryAt = nil
            return .rebuild
        }
        if written != lastWritten {
            lastWritten = written
            lastProgress = now
            stallRebuilds = 0
            failures = 0
            return .none
        }
        if !outputRunning {
            // Mac silent: the output does no IO and the tap does not call the callback. It is not a stall.
            lastProgress = now
            return .none
        }
        guard now - lastProgress >= stallSeconds else { return .none }
        guard stallRebuilds < Self.maxStallRebuilds else { return .giveUp }
        stallRebuilds += 1
        lastProgress = now
        return .rebuild
    }
}
