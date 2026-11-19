// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

/// The Studio forgets its stems after 10 minutes of closed panel, never with the panel open.
struct StudioExpiryTests {
    @Test func clearsTenMinutesAfterThePanelCloses() {
        var expiry = StudioExpiry()
        expiry.panelClosed(at: 100)
        #expect(expiry.check(at: 100, hasStems: true, busy: false) == .wait(600))
        #expect(expiry.check(at: 699, hasStems: true, busy: false) == .wait(1))
        #expect(expiry.check(at: 700, hasStems: true, busy: false) == .clear)
        // Once cleared there is nothing left to wait for.
        #expect(expiry.check(at: 800, hasStems: true, busy: false) == .stop)
    }

    @Test func openingThePanelStopsTheCount() {
        var expiry = StudioExpiry()
        expiry.panelClosed(at: 0)
        expiry.panelOpened()
        #expect(expiry.check(at: 10_000, hasStems: true, busy: false) == .stop)
        // Closed again: ten new minutes.
        expiry.panelClosed(at: 20_000)
        #expect(expiry.check(at: 20_599, hasStems: true, busy: false) == .wait(1))
    }

    /// Recording, separating, playing or saving with the panel closed: nothing is cleared, and the
    /// ten minutes count again from when it was last seen busy.
    @Test func busyPostponesAndRestartsTheCount() {
        var expiry = StudioExpiry()
        expiry.panelClosed(at: 0)
        #expect(expiry.check(at: 600, hasStems: true, busy: true) == .wait(StudioExpiry.busyRecheck))
        #expect(expiry.check(at: 660, hasStems: true, busy: true) == .wait(StudioExpiry.busyRecheck))
        #expect(expiry.check(at: 720, hasStems: true, busy: false) == .wait(540))
        #expect(expiry.check(at: 1260, hasStems: true, busy: false) == .clear)
    }

    /// Without stems there is nothing to forget: no wake-ups (Original at rest).
    @Test func withoutStemsNothingToWaitFor() {
        var expiry = StudioExpiry()
        expiry.panelClosed(at: 0)
        #expect(expiry.check(at: 0, hasStems: false, busy: false) == .stop)
        #expect(expiry.check(at: 700, hasStems: true, busy: false) == .stop)
    }

    /// A job running with no stems yet: its stems may arrive with the panel closed, the count goes on.
    @Test func busyWithoutStemsKeepsWatching() {
        var expiry = StudioExpiry()
        expiry.panelClosed(at: 0)
        #expect(expiry.check(at: 0, hasStems: false, busy: true) == .wait(StudioExpiry.busyRecheck))
        #expect(expiry.check(at: 60, hasStems: true, busy: false) == .wait(540))
    }

    /// What counts as running. A job or a playback counts only with the Studio engine alive: after a crash,
    /// Original or Live the session still says "playing", but nothing runs and the count must go on.
    @Test func busyNeedsTheStudioEngineAlive() {
        var playing = StudioSession()
        _ = playing.load(path: "/m/a.mp3", level: .base)
        _ = playing.handle(.stemsReady(StemsResult(folder: "/t/a", files: [:], duration: 10, waveforms: [:])),
                           level: .base)
        _ = playing.handle(.player(position: 1, duration: 10, playing: true), level: .base)
        #expect(StudioExpiry.isBusy(session: playing, studioEngineAlive: true, saving: false))
        #expect(!StudioExpiry.isBusy(session: playing, studioEngineAlive: false, saving: false))
        var separating = StudioSession()
        _ = separating.load(path: "/m/b.mp3", level: .base)
        #expect(StudioExpiry.isBusy(session: separating, studioEngineAlive: true, saving: false))
        #expect(!StudioExpiry.isBusy(session: separating, studioEngineAlive: false, saving: false))
        // Save copies with the app alone: it counts in any section.
        #expect(StudioExpiry.isBusy(session: StudioSession(), studioEngineAlive: false, saving: true))
        #expect(!StudioExpiry.isBusy(session: StudioSession(), studioEngineAlive: true, saving: false))
    }

    /// A cancellation the engine did not answer in time (Annulla abandoned after 5 s): Record is free again, but
    /// the engine still works on the job and would ignore `clearStudio`. The stems are forgotten only once it has
    /// answered (Task 10.10).
    @Test func anUnansweredCancelCountsAsBusyUntilTheEngineAnswers() {
        var session = StudioSession()
        _ = session.load(path: "/m/b.mp3", level: .base)
        _ = session.cancel()
        session.abandonCancel()
        #expect(!session.isBusy)
        #expect(StudioExpiry.isBusy(session: session, studioEngineAlive: true, saving: false))
        #expect(!StudioExpiry.isBusy(session: session, studioEngineAlive: false, saving: false))
        _ = session.handle(.failure(EngineFailure(.separationCancelled)), level: .base)
        #expect(!StudioExpiry.isBusy(session: session, studioEngineAlive: true, saving: false))
    }

    /// The engine may answer with the stems (the job was past its last check), or with the recording.
    @Test func anUnansweredCancelEndsWithStemsOrRecording() {
        var separating = StudioSession()
        _ = separating.load(path: "/m/b.mp3", level: .base)
        _ = separating.cancel()
        separating.abandonCancel()
        _ = separating.handle(.stemsReady(StemsResult(folder: "/m/b", files: [:], duration: 1, waveforms: [:])),
                              level: .base)
        #expect(!StudioExpiry.isBusy(session: separating, studioEngineAlive: true, saving: false))

        var recording = StudioSession()
        _ = recording.record()
        _ = recording.cancel()
        recording.abandonCancel()
        #expect(StudioExpiry.isBusy(session: recording, studioEngineAlive: true, saving: false))
        _ = recording.handle(.recorded(path: "/t/r.wav"), level: .base)
        #expect(!StudioExpiry.isBusy(session: recording, studioEngineAlive: true, saving: false))
    }

    /// A player error is not the answer to the cancellation.
    @Test func aPlayerErrorIsNotTheAnswer() {
        var session = StudioSession()
        _ = session.load(path: "/m/b.mp3", level: .base)
        _ = session.cancel()
        session.abandonCancel()
        _ = session.handle(.failure(EngineFailure(.outputUnplayable)), level: .base)
        #expect(StudioExpiry.isBusy(session: session, studioEngineAlive: true, saving: false))
    }

    /// "Busy" answers a new command, not the abandoned cancellation: the old job still runs.
    @Test func busyIsNotTheAnswerToAnAbandonedCancel() {
        var session = StudioSession()
        _ = session.load(path: "/m/b.mp3", level: .base)
        _ = session.cancel()
        session.abandonCancel()
        _ = session.load(path: "/m/c.mp3", level: .base)
        _ = session.handle(.failure(EngineFailure(.alreadySeparating)), level: .base)
        #expect(StudioExpiry.isBusy(session: session, studioEngineAlive: true, saving: false))
    }
}
