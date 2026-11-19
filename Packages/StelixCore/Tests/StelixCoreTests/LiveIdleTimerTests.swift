// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct LiveIdleTimerTests {
    /// Runs the timer at 20 Hz from `from` to `to` with the same input, and returns the first
    /// moment it expires (nil if it never does).
    private func run(_ timer: inout LiveIdleTimer, from: Double, to: Double,
                     outputRunning: Bool, peak: Float) -> Double? {
        var t = from
        while t <= to + 1e-9 {
            if timer.observe(at: t, outputRunning: outputRunning, peak: peak) { return t }
            t += 0.05
        }
        return nil
    }

    @Test func fiveMinutesOfStoppedOutputExpire() {
        var timer = LiveIdleTimer(startedAt: 0)
        #expect(run(&timer, from: 0.05, to: 299.9, outputRunning: false, peak: 0) == nil)
        let expired = timer.observe(at: 300, outputRunning: false, peak: 0)
        #expect(expired)
    }

    @Test func soundAtFourFiftyNineRestartsTheCount() {
        var timer = LiveIdleTimer(startedAt: 0)
        #expect(run(&timer, from: 0.05, to: 299, outputRunning: false, peak: 0) == nil)
        let expired = timer.observe(at: 299, outputRunning: true, peak: 0.3)
        #expect(!expired)
        #expect(run(&timer, from: 299.05, to: 598.9, outputRunning: false, peak: 0) == nil)
        let expiredAgain = timer.observe(at: 599, outputRunning: false, peak: 0)
        #expect(expiredAgain)
    }

    @Test func signalBelowThresholdCountsAsSilence() {
        // An app paused with the output still open: the output runs, the samples are zeros or almost.
        var timer = LiveIdleTimer(startedAt: 0)
        let below = Float(0.0005)   // about -66 dBFS
        let expired = run(&timer, from: 0.05, to: 301, outputRunning: true, peak: below)
        #expect(expired.map { abs($0 - 300) < 0.06 } == true)
    }

    @Test func signalAboveThresholdIsSound() {
        var timer = LiveIdleTimer(startedAt: 0)
        let above = Float(0.002)    // about -54 dBFS, a quiet tail of a song
        #expect(run(&timer, from: 0.05, to: 900, outputRunning: true, peak: above) == nil)
    }

    @Test func peakWithoutRunningOutputIsSilence() {
        // The output has just stopped: what arrives without IO does not count as music.
        var timer = LiveIdleTimer(startedAt: 0)
        let expired = run(&timer, from: 0.05, to: 301, outputRunning: false, peak: 0.5)
        #expect(expired != nil)
    }

    @Test func outputChangeDoesNotStopLiveByItself() {
        // Silence, then the output changes (headphones plugged in): the count starts over,
        // because who changes output is about to listen.
        var timer = LiveIdleTimer(startedAt: 0)
        #expect(run(&timer, from: 0.05, to: 250, outputRunning: false, peak: 0) == nil)
        timer.outputChanged(at: 250)
        #expect(run(&timer, from: 250.05, to: 549.9, outputRunning: false, peak: 0) == nil)
        let expired = timer.observe(at: 550, outputRunning: false, peak: 0)
        #expect(expired)
    }

    @Test func fiveMinutesAtMinusSixtyDBFS() {
        #expect(abs(20 * log10(Double(LiveIdleTimer.threshold)) + 60) < 0.01)
        #expect(LiveIdleTimer.limit == 300)
    }
}
