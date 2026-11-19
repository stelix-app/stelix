// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

struct StatusIconStateTests {
    @Test func originalIsIdleWithoutTimer() {
        let state = StatusIconState.make(mode: .original, phase: .active, live: nil, levels: [:], studio: .idle)
        #expect(state == .idle)
        #expect(!StatusIconState.animates(mode: .original, phase: .active, live: nil))
    }

    @Test func anUpdateMarksOnlyTheStillIcon() {
        #expect(StatusIconState.make(mode: .original, phase: .active, live: nil, levels: [:], studio: .idle,
                                     update: true) == .updateAvailable)
        #expect(StatusIconState.make(mode: .original, phase: .active, live: nil, levels: [:], studio: .idle,
                                     download: 0.5, update: true) == .separating(progress: 0.5))
        let levels: [Stem: Float] = [.bass: 1, .drums: 1, .vocals: 1, .other: 1]
        #expect(StatusIconState.make(mode: .live, phase: .active, live: .running, levels: levels, studio: .idle,
                                     update: true) == .live(levels: [1, 1, 1]))
    }

    @Test func timerOnlyWhileLiveRuns() {
        #expect(StatusIconState.animates(mode: .live, phase: .active, live: .running))
        #expect(!StatusIconState.animates(mode: .live, phase: .active, live: .warming))
        #expect(!StatusIconState.animates(mode: .live, phase: .active, live: .filling(fraction: 0.5)))
        #expect(!StatusIconState.animates(mode: .live, phase: .preparing, live: .running))
        #expect(!StatusIconState.animates(mode: .live, phase: .failed(EngineFailure(.unknown)), live: .running))
        #expect(!StatusIconState.animates(mode: .studio, phase: .active, live: .running))
    }

    @Test func liveBarsGoFromLowToHigh() {
        // From the left: bass, drums, voice or other. 0 dB → 1; silence → 0; -60 dB → 0;
        // -20 dB → 2/3, which in eighths is 5/8.
        let levels: [Stem: Float] = [.bass: 1, .drums: 0, .vocals: 0.001, .other: 0.1]
        let state = StatusIconState.make(mode: .live, phase: .active, live: .running, levels: levels, studio: .idle)
        #expect(state == .live(levels: [1, 0, 0.625]))
    }

    @Test func voiceAndOtherTakeTheLouder() {
        let levels: [Stem: Float] = [.bass: 0, .drums: 0, .vocals: 1, .other: 0.1]
        #expect(StatusIconState.liveBars(levels) == [0, 0, 1])
    }

    @Test func tinyLevelChangesKeepTheSameState() {
        let a = StatusIconState.liveBars([.vocals: 0.5, .drums: 0.2, .bass: 0.1, .other: 0])
        let b = StatusIconState.liveBars([.vocals: 0.5001, .drums: 0.2001, .bass: 0.1001, .other: 0])
        #expect(a == b)
    }

    @Test func liveNotRunningIsIdle() {
        let state = StatusIconState.make(mode: .live, phase: .active, live: .warming, levels: [.vocals: 1], studio: .idle)
        #expect(state == .idle)
    }

    @Test func separatingShowsProgressInTwentieths() {
        let state = StatusIconState.make(
            mode: .studio, phase: .active, live: nil, levels: [:],
            studio: .separating(progress: 0.42, step: .separating))
        #expect(state == .separating(progress: 0.4))
        let over = StatusIconState.make(
            mode: .studio, phase: .active, live: nil, levels: [:],
            studio: .separating(progress: 1.7, step: .writingStems))
        #expect(over == .separating(progress: 1))
    }

    @Test func studioOtherStagesAreIdle() {
        for stage: StudioSession.Stage in [.idle, .recording(seconds: 3), .failed(EngineFailure(.unknown))] {
            #expect(StatusIconState.make(mode: .studio, phase: .active, live: nil, levels: [:], studio: stage) == .idle)
        }
    }

    @Test func separatingIgnoredOutsideStudio() {
        let state = StatusIconState.make(
            mode: .original, phase: .active, live: nil, levels: [:],
            studio: .separating(progress: 0.5, step: .readingFile))
        #expect(state == .idle)
    }

    @Test func downloadShowsProgressInTwentieths() {
        let state = StatusIconState.make(mode: .original, phase: .active, live: nil, levels: [:], studio: .idle,
                                         download: 0.33)
        #expect(state == .separating(progress: 0.3))
    }

    @Test func downloadShowsWhileLiveWaitsForItsModel() {
        let waiting = ModePhase.failed(EngineFailure(.missingWeights, detail: "htdemucs"))
        let state = StatusIconState.make(mode: .live, phase: waiting, live: nil, levels: [:], studio: .idle, download: 0.5)
        #expect(state == .separating(progress: 0.5))
    }

    @Test func runningLiveWinsOverDownload() {
        let state = StatusIconState.make(mode: .live, phase: .active, live: .running, levels: [.bass: 1], studio: .idle,
                                         download: 0.5)
        #expect(state == .live(levels: [1, 0, 0]))
    }

    @Test func separationWinsOverDownload() {
        let state = StatusIconState.make(mode: .studio, phase: .active, live: nil, levels: [:],
                                         studio: .separating(progress: 0.8, step: .separating), download: 0.1)
        #expect(state == .separating(progress: 0.8))
    }
}
