// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct SilenceWatchdogTests {
    private let rate = 48_000.0
    private let chunk = 512

    /// Advances the watchdog by `seconds` seconds in 512-frame blocks and collects the actions
    /// other than `.none`, with the second (from the start) at which they arrived.
    private func feed(_ w: inout SilenceWatchdog, from frame: inout Int64, seconds: Double,
                      allZero: Bool) -> [(SilenceWatchdog.Action, Double)] {
        var actions: [(SilenceWatchdog.Action, Double)] = []
        let end = frame + Int64(seconds * rate)
        while frame < end {
            let action = w.observe(atFrame: frame, frames: chunk, allZero: allZero)
            frame += Int64(chunk)
            if action != .none { actions.append((action, Double(frame) / rate)) }
        }
        return actions
    }

    @Test func zerosFromStartSuspectPermissionOnce() {
        var w = SilenceWatchdog(sampleRate: rate)
        var frame: Int64 = 0
        let early = feed(&w, from: &frame, seconds: 2.9, allZero: true)
        #expect(early.isEmpty)
        let later = feed(&w, from: &frame, seconds: 60, allZero: true)
        #expect(later.count == 1)
        #expect(later.first?.0 == .permissionSuspected)
        #expect((later.first?.1 ?? 0) >= 3 && (later.first?.1 ?? 0) < 3.05)
    }

    @Test func zerosAfterDeviceChangeRebuildAtMostTwice() {
        var w = SilenceWatchdog(sampleRate: rate)
        var frame: Int64 = 0
        #expect(feed(&w, from: &frame, seconds: 10, allZero: false).isEmpty)
        w.noteDeviceChange(atFrame: frame)
        let actions = feed(&w, from: &frame, seconds: 30, allZero: true)
        #expect(actions.map(\.0) == [.rebuild, .rebuild])
        #expect(actions.allSatisfy { $0.1 >= 12 && $0.1 <= 15 })      // from 2 s to 5 s after the change
        #expect(actions[1].1 - actions[0].1 >= 2)                        // every rebuild needs 2 s of new zeros

        // A new change entitles it to two rebuilds again.
        w.noteDeviceChange(atFrame: frame)
        #expect(feed(&w, from: &frame, seconds: 30, allZero: true).map(\.0) == [.rebuild, .rebuild])
    }

    @Test func deviceChangeAtStartRebuildsBeforeSuspectingPermission() {
        var w = SilenceWatchdog(sampleRate: rate)
        var frame: Int64 = 0
        w.noteDeviceChange(atFrame: 0)
        let actions = feed(&w, from: &frame, seconds: 2.1, allZero: true)
        #expect(actions.map(\.0) == [.rebuild])
    }

    @Test func pausedMusicNeverTriggersRebuild() {
        var w = SilenceWatchdog(sampleRate: rate)
        var frame: Int64 = 0
        #expect(feed(&w, from: &frame, seconds: 10, allZero: false).isEmpty)
        #expect(feed(&w, from: &frame, seconds: 300, allZero: true).isEmpty)
    }

    @Test func zerosStartingLateAfterChangeDoNothing() {
        var w = SilenceWatchdog(sampleRate: rate)
        var frame: Int64 = 0
        #expect(feed(&w, from: &frame, seconds: 5, allZero: false).isEmpty)
        w.noteDeviceChange(atFrame: frame)
        #expect(feed(&w, from: &frame, seconds: 3.5, allZero: false).isEmpty)
        // The zeros arrive 3.5 s after the change: 2 s of zeros would end beyond the 5 s.
        #expect(feed(&w, from: &frame, seconds: 60, allZero: true).isEmpty)
    }

    @Test func signalResetsCounters() {
        var w = SilenceWatchdog(sampleRate: rate)
        var frame: Int64 = 0
        // 2.5 s of zeros, then signal: the permission is there, no suspicion afterwards.
        #expect(feed(&w, from: &frame, seconds: 2.5, allZero: true).isEmpty)
        #expect(feed(&w, from: &frame, seconds: 0.1, allZero: false).isEmpty)
        #expect(feed(&w, from: &frame, seconds: 10, allZero: true).isEmpty)

        // After a change: 1.5 s of zeros, signal, 1.5 s of zeros. No run reaches 2 s.
        #expect(feed(&w, from: &frame, seconds: 1, allZero: false).isEmpty)
        w.noteDeviceChange(atFrame: frame)
        #expect(feed(&w, from: &frame, seconds: 1.5, allZero: true).isEmpty)
        #expect(feed(&w, from: &frame, seconds: 0.05, allZero: false).isEmpty)
        #expect(feed(&w, from: &frame, seconds: 1.5, allZero: true).isEmpty)
    }
}
