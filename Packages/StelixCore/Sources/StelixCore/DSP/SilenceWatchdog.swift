// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// Watches the tap's input buffers and decides when exact zeros are a fault.
///
/// Exact zeros arrive in three cases: capture permission denied (zeros from the start), tap left
/// mute after a device change (AirPods from A2DP to HFP) and music paused. Only the first two
/// call for action:
/// - `.permissionSuspected` once only, if from the start only zeros arrive for at least 3 s;
/// - `.rebuild` if after a device change zeros arrive for at least 2 s, ending within 5 s
///   of the change; at most 2 times per change;
/// - otherwise `.none`: paused music does nothing.
///
/// Time is counted in observed frames, not wall-clock time: if the aggregate is late giving the
/// first callbacks (seen up to 5 s in early measurements) the watchdog waits without counting.
public struct SilenceWatchdog: Sendable {
    public enum Action: Equatable, Sendable { case none, rebuild, permissionSuspected }

    public let sampleRate: Double
    private let permissionFrames: Int64
    private let rebuildFrames: Int64
    private let windowFrames: Int64
    private static let maxRebuildsPerChange = 2

    private var seenSignal = false
    private var permissionReported = false
    private var zeroRunStart: Int64?
    private var changeFrame: Int64?
    private var rebuildsForChange = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        permissionFrames = Int64((3 * sampleRate).rounded())
        rebuildFrames = Int64((2 * sampleRate).rounded())
        windowFrames = Int64((5 * sampleRate).rounded())
    }

    public mutating func noteDeviceChange(atFrame frame: Int64) {
        changeFrame = frame
        rebuildsForChange = 0
    }

    /// A block of `frames` frames starting at `atFrame`; `allZero` if all samples are 0.
    public mutating func observe(atFrame frame: Int64, frames: Int, allZero: Bool) -> Action {
        let end = frame + Int64(frames)
        guard allZero else {
            seenSignal = true
            zeroRunStart = nil
            changeFrame = nil       // the signal is back: the change is resolved
            return .none
        }
        let runStart = zeroRunStart ?? frame
        zeroRunStart = runStart

        if let change = changeFrame, rebuildsForChange < Self.maxRebuildsPerChange {
            let zerosSinceChange = end - max(runStart, change)
            if end - change <= windowFrames, zerosSinceChange >= rebuildFrames {
                rebuildsForChange += 1
                zeroRunStart = end          // the next rebuild needs another 2 s of zeros
                return .rebuild
            }
        }

        if !seenSignal, !permissionReported, end - runStart >= permissionFrames {
            permissionReported = true
            return .permissionSuspected
        }
        return .none
    }
}
