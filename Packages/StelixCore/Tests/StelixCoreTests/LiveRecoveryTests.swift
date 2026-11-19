// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct LiveRecoveryTests {
    @Test func stalledStartRebuildsOnceThenGivesUp() {
        var r = LiveRecovery()
        r.pipelineStarted(at: 0)
        #expect(r.observe(at: 1, written: 0) == .none)
        #expect(r.observe(at: 3.9, written: 0) == .none)
        #expect(r.observe(at: 4.0, written: 0) == .rebuild)
        r.pipelineStarted(at: 4.1)
        #expect(r.observe(at: 8.0, written: 0) == .none)
        #expect(r.observe(at: 8.1, written: 0) == .giveUp)
    }

    @Test func movingFramesNeverAct() {
        var r = LiveRecovery()
        r.pipelineStarted(at: 0)
        var written: Int64 = 0
        for step in 1...1200 {   // 60 s a 20 Hz
            written += 2400
            #expect(r.observe(at: Double(step) * 0.05, written: written) == .none)
        }
    }

    @Test func callbacksStoppingMidSessionRebuild() {
        var r = LiveRecovery()
        r.pipelineStarted(at: 0)
        #expect(r.observe(at: 1, written: 48_000) == .none)
        #expect(r.observe(at: 4.9, written: 48_000) == .none)
        #expect(r.observe(at: 5.0, written: 48_000) == .rebuild)
    }

    @Test func progressRestoresTheStallBudget() {
        var r = LiveRecovery()
        r.pipelineStarted(at: 0)
        #expect(r.observe(at: 4, written: 0) == .rebuild)
        r.pipelineStarted(at: 4)
        #expect(r.observe(at: 5, written: 512) == .none)
        #expect(r.observe(at: 9, written: 512) == .rebuild)       // another rebuild, not the give-up
    }

    @Test func failedBuildRetriesWithBackoffThenGivesUp() {
        var r = LiveRecovery()
        #expect(r.buildFailed(at: 0) == .none)
        #expect(r.observe(at: 0.4, written: 0) == .none)
        #expect(r.observe(at: 0.5, written: 0) == .rebuild)
        #expect(r.buildFailed(at: 0.6) == .none)
        #expect(r.observe(at: 2.5, written: 0) == .none)
        #expect(r.observe(at: 2.6, written: 0) == .rebuild)
        #expect(r.buildFailed(at: 2.7) == .giveUp)
    }

    @Test func workingPipelineForgetsEarlierFailures() {
        var r = LiveRecovery()
        #expect(r.buildFailed(at: 0) == .none)
        #expect(r.observe(at: 0.5, written: 0) == .rebuild)
        r.pipelineStarted(at: 0.6)
        #expect(r.observe(at: 1, written: 4800) == .none)
        // Later another output refuses to open: the attempts start again from scratch.
        #expect(r.buildFailed(at: 100) == .none)
        #expect(r.observe(at: 100.5, written: 0) == .rebuild)
        #expect(r.buildFailed(at: 100.6) == .none)
    }

    /// With the Mac silent the output device does no IO and the tap does not call the callback: it is not a
    /// stall, it waits for the music without rebuilding or giving up.
    @Test func silentMacNeverStalls() {
        var recovery = LiveRecovery()
        recovery.pipelineStarted(at: 0)
        for tick in 0...400 {
            #expect(recovery.observe(at: Double(tick) * 0.05, written: 0, outputRunning: false) == .none)
        }
    }

    /// The music starts after the silence: the stall count starts from there, not from launch.
    @Test func stallCountsFromWhenTheOutputStartsRunning() {
        var recovery = LiveRecovery()
        recovery.pipelineStarted(at: 0)
        _ = recovery.observe(at: 10, written: 0, outputRunning: false)
        #expect(recovery.observe(at: 10.05, written: 0, outputRunning: true) == .none)
        #expect(recovery.observe(at: 13.9, written: 0, outputRunning: true) == .none)
        #expect(recovery.observe(at: 14.1, written: 0, outputRunning: true) == .rebuild)
    }
}
