// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

struct StudioSessionTests {
    private static func result(_ folder: String = "/m/a") -> StemsResult {
        StemsResult(folder: folder,
                    files: Dictionary(uniqueKeysWithValues: Stem.studio.map { ($0, $0.fileName) }),
                    duration: 10,
                    waveforms: [:])
    }

    private static let mix = StemMix.allOn(Stem.studio)

    /// A session with the stems of `result()` already in the player.
    private static func ready() -> StudioSession {
        var session = StudioSession()
        _ = session.load(path: "/m/a.mp3", level: .base)
        _ = session.handle(.stemsReady(result()), level: .base)
        return session
    }

    // MARK: Record and load

    @Test func recordStartsWithoutDuration() {
        var session = StudioSession()
        #expect(session.record() == [.startRecording])
        #expect(session.stage == .recording(seconds: 0))
        #expect(session.wave.isEmpty)
    }

    @Test func recordingEventsGrowTheWave() {
        var session = StudioSession()
        _ = session.record()
        #expect(session.handle(.recording(seconds: 0.1, peaks: [0.1, 0.2]), level: .pro).isEmpty)
        _ = session.handle(.recording(seconds: 0.15, peaks: [0.3]), level: .pro)
        #expect(session.wave == [0.1, 0.2, 0.3])
        #expect(session.stage == .recording(seconds: 0.15))
        _ = session.handle(.recording(seconds: 40, peaks: (0..<700).map { Float($0) }), level: .pro)
        #expect(session.wave.count == StudioSession.waveCap)
        #expect(session.wave.last == 699)
        #expect(session.wave.first == Float(700 - StudioSession.waveCap))
    }

    @Test func stopSendsStopRecording() {
        var session = StudioSession()
        _ = session.record()
        _ = session.handle(.recording(seconds: 3, peaks: []), level: .pro)
        #expect(session.stop() == [.stopRecording])
        #expect(session.stage == .recording(seconds: 3))
        #expect(session.handle(.recorded(path: "/m/r.wav"), level: .pro) == [.separateFile(path: "/m/r.wav", level: .pro)])
        #expect(session.stage == .separating(progress: 0, step: .readingFile))
    }

    /// Under a second there is nothing to separate: it is thrown away.
    @Test func stopBeforeOneSecondCancels() {
        var session = Self.ready()
        _ = session.record()
        _ = session.handle(.recording(seconds: 0.6, peaks: []), level: .pro)
        #expect(session.stop() == [.cancelJob])
        #expect(session.stage == .ready(Self.result()))
        #expect(session.handle(.recorded(path: "/m/r.wav"), level: .pro).isEmpty)
        #expect(session.stage == .ready(Self.result()))
    }

    @Test func secondStopSendsNothing() {
        var session = StudioSession()
        _ = session.record()
        _ = session.handle(.recording(seconds: 3, peaks: []), level: .pro)
        _ = session.stop()
        #expect(session.stop().isEmpty)
        var idle = StudioSession()
        #expect(idle.stop().isEmpty)
    }

    /// Stop with the Mac silent: the engine wrote nothing and says so; Retry records again.
    @Test func stopWithNoAudioShowsTheEngineMessage() {
        var session = StudioSession()
        _ = session.record()
        _ = session.handle(.recording(seconds: 3, peaks: []), level: .base)
        _ = session.stop()
        _ = session.handle(.failure(EngineFailure(.silentRecording)), level: .base)
        #expect(session.stage == .failed(EngineFailure(.silentRecording)))
        #expect(!session.isBusy)
        #expect(session.retry(level: .base) == [.startRecording])
        _ = session.handle(.recording(seconds: 2, peaks: []), level: .base)
        #expect(session.stop() == [.stopRecording])
    }

    /// Stop and the 20 minutes arrive together: a single recorded, a single separation.
    @Test func recordedAfterStopSeparatesOnce() {
        var session = StudioSession()
        _ = session.record()
        _ = session.handle(.recording(seconds: 1200, peaks: []), level: .pro)
        _ = session.stop()
        #expect(session.handle(.recorded(path: "/m/r.wav"), level: .pro).count == 1)
        #expect(session.handle(.recorded(path: "/m/r.wav"), level: .pro).isEmpty)
        #expect(session.stop().isEmpty)
    }

    @Test func loadSendsSeparateFileDirectly() {
        var session = StudioSession()
        #expect(session.load(path: "/m/a.mp3", level: .intermediate) == [.separateFile(path: "/m/a.mp3", level: .intermediate)])
        #expect(session.stage == .separating(progress: 0, step: .readingFile))
        _ = session.handle(.job(progress: 0.4, step: .separating), level: .intermediate)
        #expect(session.stage == .separating(progress: 0.4, step: .separating))
    }

    @Test func stemsReadyGoesToReadyAtTheStart() {
        var session = StudioSession()
        _ = session.load(path: "/m/a.mp3", level: .base)
        _ = session.handle(.player(position: 3, duration: 10, playing: true), level: .base)
        _ = session.handle(.stemsReady(Self.result()), level: .base)
        #expect(session.stage == .ready(Self.result()))
        #expect(session.result == Self.result())
        #expect(session.position == 0)
        #expect(!session.playing)
    }

    @Test func noNewJobWhileOneRuns() {
        var session = StudioSession()
        _ = session.record()
        #expect(session.isBusy)
        #expect(session.load(path: "/m/a.mp3", level: .base).isEmpty)
        #expect(session.record().isEmpty)
        #expect(session.stage == .recording(seconds: 0))
    }

    /// Recording while the stems play would record Stelix itself: it pauses first.
    @Test func newJobPausesThePlayerFirst() {
        var session = Self.ready()
        _ = session.handle(.player(position: 2, duration: 10, playing: true), level: .base)
        #expect(session.record() == [.player(.pause), .startRecording])
    }

    @Test func progressOfTheOtherKindIsIgnored() {
        var session = StudioSession()
        _ = session.load(path: "/m/a.mp3", level: .base)
        _ = session.handle(.recording(seconds: 0.7, peaks: [0.5]), level: .base)
        #expect(session.stage == .separating(progress: 0, step: .readingFile))
        var idle = StudioSession()
        _ = idle.handle(.job(progress: 0.3, step: .separating), level: .base)
        #expect(idle.stage == .idle)
    }

    // MARK: Cancel

    @Test func cancelSeparationGoesBackToThePreviousStems() {
        var session = Self.ready()
        _ = session.load(path: "/m/b.mp3", level: .base)
        #expect(session.cancel() == [.cancelJob])
        #expect(session.stage == .ready(Self.result()))
        // In-flight events of the cancelled job do not bring it back.
        _ = session.handle(.job(progress: 0.5, step: .separating), level: .base)
        _ = session.handle(.failure(EngineFailure(.separationCancelled)), level: .base)
        #expect(session.stage == .ready(Self.result()))
        #expect(!session.isBusy)
    }

    @Test func cancelRecordingGoesBackToIdleAndNeverSeparates() {
        var session = StudioSession()
        _ = session.record()
        #expect(session.cancel() == [.cancelJob])
        #expect(session.stage == .idle)
        // The WAV had already finished when the cancellation arrived: no separation.
        #expect(session.handle(.recorded(path: "/m/r.wav"), level: .base).isEmpty)
        #expect(session.stage == .idle)
        #expect(!session.isBusy)
    }

    /// Until the engine answers nothing new starts, otherwise the engine says "busy".
    @Test func noNewJobUntilTheCancelIsAcknowledged() {
        var session = StudioSession()
        _ = session.load(path: "/m/a.mp3", level: .base)
        _ = session.cancel()
        #expect(session.isBusy)
        #expect(session.load(path: "/m/b.mp3", level: .base).isEmpty)
        _ = session.handle(.failure(EngineFailure(.separationCancelled)), level: .base)
        #expect(session.load(path: "/m/b.mp3", level: .base) == [.separateFile(path: "/m/b.mp3", level: .base)])
    }

    /// The job finishes before the cancellation arrives: the engine has already loaded the new stems.
    @Test func stemsReadyAfterCancelStillWins() {
        var session = StudioSession()
        _ = session.load(path: "/m/a.mp3", level: .base)
        _ = session.cancel()
        _ = session.handle(.stemsReady(Self.result("/m/b")), level: .base)
        #expect(session.stage == .ready(Self.result("/m/b")))
        #expect(!session.isBusy)
    }

    /// A player error arriving while waiting for the cancellation is not its answer.
    @Test func playerErrorDuringCancelKeepsWaitingForTheCancel() {
        var session = Self.ready()
        _ = session.load(path: "/m/b.mp3", level: .base)
        _ = session.cancel()
        _ = session.handle(.failure(EngineFailure(.outputUnplayable)), level: .base)
        #expect(session.stage == .failed(EngineFailure(.outputUnplayable)))
        #expect(session.isBusy)
        _ = session.handle(.failure(EngineFailure(.separationCancelled)), level: .base)
        #expect(!session.isBusy)
    }

    /// If the engine never answers the cancellation, the Studio unblocks anyway.
    @Test func abandonedCancelFreesTheSession() {
        var session = StudioSession()
        _ = session.load(path: "/m/a.mp3", level: .base)
        _ = session.cancel()
        #expect(session.isBusy)
        session.abandonCancel()
        #expect(!session.isBusy)
        #expect(session.load(path: "/m/b.mp3", level: .base) == [.separateFile(path: "/m/b.mp3", level: .base)])
    }

    @Test func cancelWithNothingRunningSendsNothing() {
        var session = Self.ready()
        #expect(session.cancel().isEmpty)
        #expect(!session.isBusy)
    }

    // MARK: Errors and Retry

    @Test func failureDuringJobShowsTheEngineMessage() {
        var session = StudioSession()
        _ = session.load(path: "/m/a.pdf", level: .base)
        _ = session.handle(.failure(EngineFailure(.unsupported)), level: .base)
        #expect(session.stage == .failed(EngineFailure(.unsupported)))
        #expect(!session.isBusy)
    }

    @Test func retryRepeatsTheFailedJob() {
        var session = StudioSession()
        _ = session.record()
        _ = session.handle(.failure(EngineFailure(.tap)), level: .base)
        #expect(session.retry(level: .base) == [.startRecording])

        // A file retries at the level it started with, not the one passed.
        var file = StudioSession()
        _ = file.load(path: "/m/a.mp3", level: .base)
        _ = file.handle(.failure(EngineFailure(.sidecarMissing)), level: .base)
        #expect(file.retry(level: .pro) == [.separateFile(path: "/m/a.mp3", level: .base)])
    }

    /// If the recording is finished and the separation is what failed, it retries separating that WAV.
    @Test func retryAfterRecordingSeparatesTheRecordedFile() {
        var session = StudioSession()
        _ = session.record()
        _ = session.handle(.recorded(path: "/m/r.wav"), level: .base)
        _ = session.handle(.failure(EngineFailure(.separationFailed)), level: .base)
        #expect(session.retry(level: .base) == [.separateFile(path: "/m/r.wav", level: .base)])
    }

    /// A player error does not throw away the stems: Retry goes back to listening.
    @Test func playerFailureRetryGoesBackToTheStems() {
        var session = Self.ready()
        _ = session.handle(.failure(EngineFailure(.outputUnplayable)), level: .base)
        #expect(session.stage == .failed(EngineFailure(.outputUnplayable)))
        #expect(session.retry(level: .base).isEmpty)
        #expect(session.stage == .ready(Self.result()))
    }

    /// The player could not open the stems: there is nothing left to listen to.
    @Test func playerLoadFailureForgetsTheStems() {
        var session = Self.ready()
        _ = session.handle(.failure(EngineFailure(.stemUnreadable, detail: "vocals")), level: .base)
        #expect(session.result == nil)
        _ = session.retry(level: .base)
        #expect(session.stage == .idle)
        #expect(session.play().isEmpty)
    }

    /// An error found by the app (unreadable file): nothing to redo, Retry goes back to the stems.
    @Test func appFailureKeepsTheStems() {
        var session = Self.ready()
        session.fail(.fileNoAccess)
        #expect(session.stage == .failed(EngineFailure(.fileNoAccess)))
        #expect(session.retry(level: .base).isEmpty)
        #expect(session.stage == .ready(Self.result()))
    }

    /// A file without audio or too long always fails the same way: Retry goes back to the previous stems.
    @Test func retryAfterAFileThatCannotWorkGoesBackToTheStems() {
        for message in [FailureMessage.unsupported, .tooLong] {
            var session = Self.ready()
            _ = session.load(path: "/m/b.pdf", level: .base)
            _ = session.handle(.failure(EngineFailure(message, detail: message == .tooLong ? "20" : nil)), level: .base)
            #expect(session.retry(level: .base).isEmpty)
            #expect(session.stage == .ready(Self.result()))
        }
    }

    /// Only in Studio, with the engine ready and nothing in progress: a file chosen after switching
    /// to Live must not end up in the Live engine.
    @Test func canStartOnlyInStudioWhenActiveAndIdle() {
        var session = StudioSession()
        #expect(session.canStart(mode: .studio, phase: .active))
        #expect(!session.canStart(mode: .live, phase: .active))
        #expect(!session.canStart(mode: .original, phase: .active))
        #expect(!session.canStart(mode: .studio, phase: .preparing))
        _ = session.record()
        #expect(!session.canStart(mode: .studio, phase: .active))
    }

    @Test func liveOnlyFailuresAreIgnored() {
        var session = Self.ready()
        _ = session.handle(.failure(EngineFailure(.measureNoSignal)), level: .base)
        #expect(session.stage == .ready(Self.result()))
    }

    @Test func permissionSuspectedOnlyWhileRecording() {
        var session = StudioSession()
        _ = session.handle(.permissionSuspected, level: .base)
        #expect(!session.permissionSuspected)
        _ = session.record()
        _ = session.handle(.permissionSuspected, level: .base)
        #expect(session.permissionSuspected)
        _ = session.handle(.recorded(path: "/m/r.wav"), level: .base)
        #expect(!session.permissionSuspected)
    }

    // MARK: Source and Save

    @Test func stemsReadyRemembersTheSource() {
        var file = StudioSession()
        _ = file.load(path: "/m/a.mp3", level: .base)
        #expect(file.source == nil)
        _ = file.handle(.stemsReady(Self.result()), level: .base)
        #expect(file.source == .file(path: "/m/a.mp3"))

        var recorded = StudioSession()
        _ = recorded.record()
        _ = recorded.handle(.recording(seconds: 3, peaks: []), level: .base)
        _ = recorded.handle(.recorded(path: "/t/r/registrazione.wav"), level: .base)
        _ = recorded.handle(.stemsReady(Self.result("/t/r")), level: .base)
        #expect(recorded.source == .recording(path: "/t/r/registrazione.wav"))
        #expect(recorded.source?.path == "/t/r/registrazione.wav")
    }

    @Test func canSaveOnlyOnceAndNeverWhileBusy() {
        var session = StudioSession()
        #expect(!session.canSave)
        _ = session.load(path: "/m/a.mp3", level: .base)
        _ = session.handle(.stemsReady(Self.result()), level: .base)
        #expect(session.canSave)
        session.markSaved("/Music/Stelix/x")
        #expect(session.savedFolder == "/Music/Stelix/x")
        #expect(!session.canSave)
        _ = session.load(path: "/m/b.mp3", level: .base)
        #expect(!session.canSave)
        _ = session.handle(.stemsReady(Self.result("/m/b")), level: .base)
        #expect(session.savedFolder == nil)
        #expect(session.canSave)
        _ = session.load(path: "/m/c.mp3", level: .base)
        #expect(!session.canSave)
    }

    // MARK: Locked level and Change model

    /// A session with the stems of /m/a.mp3 made at Intermediate.
    private static func readyIntermediate() -> StudioSession {
        var session = StudioSession()
        _ = session.load(path: "/m/a.mp3", level: .intermediate)
        _ = session.handle(.stemsReady(result()), level: .base)
        return session
    }

    @Test func stemsLevelIsTheLevelOfTheJob() {
        var file = StudioSession()
        _ = file.load(path: "/m/a.mp3", level: .pro)
        #expect(file.stemsLevel == nil)
        _ = file.handle(.stemsReady(Self.result()), level: .base)
        #expect(file.stemsLevel == .pro)

        var recorded = StudioSession()
        _ = recorded.record()
        _ = recorded.handle(.recording(seconds: 3, peaks: []), level: .pro)
        _ = recorded.handle(.recorded(path: "/t/r/registrazione.wav"), level: .base)
        _ = recorded.handle(.stemsReady(Self.result("/t/r")), level: .pro)
        #expect(recorded.stemsLevel == .base)
    }

    /// Stems that arrived without a session job (the snapshot asks for them at launch): the level is
    /// the one chosen in the picker.
    @Test func stemsWithoutAJobTakeThePickerLevel() {
        var session = StudioSession()
        _ = session.handle(.stemsReady(Self.result()), level: .pro)
        #expect(session.stemsLevel == .pro)
    }

    @Test func changeModelReseparatesTheSameSource() {
        var session = Self.readyIntermediate()
        #expect(session.changeModel(to: .pro) == [.separateFile(path: "/m/a.mp3", level: .pro)])
        _ = session.handle(.stemsReady(Self.result()), level: .base)
        #expect(session.stemsLevel == .pro)
        #expect(session.source == .file(path: "/m/a.mp3"))

        var recorded = StudioSession()
        _ = recorded.record()
        _ = recorded.handle(.recording(seconds: 3, peaks: []), level: .base)
        _ = recorded.handle(.recorded(path: "/t/r/registrazione.wav"), level: .base)
        _ = recorded.handle(.stemsReady(Self.result("/t/r")), level: .base)
        #expect(recorded.changeModel(to: .intermediate) == [.separateFile(path: "/t/r/registrazione.wav", level: .intermediate)])
        _ = recorded.handle(.stemsReady(Self.result("/t/r")), level: .base)
        #expect(recorded.source == .recording(path: "/t/r/registrazione.wav"))
        #expect(recorded.stemsLevel == .intermediate)
    }

    @Test func changeModelToTheSameLevelDoesNothing() {
        var session = Self.readyIntermediate()
        #expect(session.changeModel(to: .intermediate).isEmpty)
        #expect(session.stage == .ready(Self.result()))
    }

    @Test func changeModelWithoutStemsDoesNothing() {
        var session = StudioSession()
        #expect(session.changeModel(to: .pro).isEmpty)
        var busy = Self.readyIntermediate()
        _ = busy.load(path: "/m/b.mp3", level: .base)
        #expect(busy.changeModel(to: .pro).isEmpty)
    }

    /// The file has disappeared: the error shows, Retry redoes the same job, Cancel goes back to the old ones.
    @Test func changeModelFailureKeepsTheOldStemsAndLevel() {
        var session = Self.readyIntermediate()
        _ = session.changeModel(to: .pro)
        _ = session.handle(.failure(EngineFailure(.stemUnreadable)), level: .base)
        #expect(session.stage == .failed(EngineFailure(.stemUnreadable)))
        #expect(session.result == Self.result())
        #expect(session.stemsLevel == .intermediate)
        #expect(session.retry(level: .base) == [.separateFile(path: "/m/a.mp3", level: .pro)])
        _ = session.cancel()
        #expect(session.stage == .ready(Self.result()))
        #expect(session.stemsLevel == .intermediate)
    }

    // MARK: Player

    @Test func transportNeedsStems() {
        var session = StudioSession()
        #expect(session.play().isEmpty)
        #expect(session.seek(to: 3).isEmpty)
        var ready = Self.ready()
        #expect(ready.play() == [.player(.play)])
        #expect(ready.pause() == [.player(.pause)])
    }

    @Test func seekIsClampedAndShownAtOnce() {
        var session = Self.ready()
        #expect(session.seek(to: 42) == [.player(.seek(seconds: 10))])
        #expect(session.position == 10)
        #expect(session.seek(to: -1) == [.player(.seek(seconds: 0))])
    }

    @Test func playerEventsUpdatePositionAndPlaying() {
        var session = Self.ready()
        _ = session.handle(.player(position: 4.2, duration: 10, playing: true), level: .base)
        #expect(session.position == 4.2)
        #expect(session.playing)
    }

    @Test func staleTickAfterSeekIsIgnored() {
        // A .player sent before the seek arrives after it: the cursor does not go back.
        var session = Self.ready()
        _ = session.seek(to: 8)
        _ = session.handle(.player(position: 2, duration: 10, playing: true), level: .base)
        #expect(session.position == 8)
        #expect(session.playing)
        _ = session.handle(.player(position: 8.05, duration: 10, playing: true), level: .base)
        #expect(session.position == 8.05)
        _ = session.handle(.player(position: 2, duration: 10, playing: true), level: .base)
        #expect(session.position == 2)
    }

    @Test func seekStopsIgnoringTicksAfterThree() {
        // If the seek is lost, the cursor follows the engine again after three ticks.
        var session = Self.ready()
        _ = session.seek(to: 8)
        for _ in 0..<3 { _ = session.handle(.player(position: 2, duration: 10, playing: true), level: .base) }
        #expect(session.position == 8)
        _ = session.handle(.player(position: 2.1, duration: 10, playing: true), level: .base)
        #expect(session.position == 2.1)
    }

    // MARK: Space bar and "to the start" (Task 10.8)

    @Test func togglePlaybackPlaysThenPauses() {
        var session = Self.ready()
        #expect(session.togglePlayback() == [.player(.play)])
        _ = session.handle(.player(position: 1, duration: 10, playing: true), level: .base)
        #expect(session.togglePlayback() == [.player(.pause)])
    }

    /// The space bar does something only where the play button is: with the stems ready.
    @Test func togglePlaybackOnlyWithStemsReady() {
        var empty = StudioSession()
        #expect(empty.togglePlayback().isEmpty)
        var session = Self.ready()
        _ = session.load(path: "/m/b.mp3", level: .base)
        #expect(session.togglePlayback().isEmpty)
        var recording = Self.ready()
        _ = recording.record()
        #expect(recording.togglePlayback().isEmpty)
    }

    @Test func rewindSeeksToTheStart() {
        var session = Self.ready()
        _ = session.handle(.player(position: 6, duration: 10, playing: true), level: .base)
        #expect(session.rewind() == [.player(.seek(seconds: 0))])
        #expect(session.position == 0)
        var empty = StudioSession()
        #expect(empty.rewind().isEmpty)
    }

    // MARK: The stems stay across sections (Task 10.8)

    /// The engine goes (Original, Live): the stems, the position and the saved folder stay, and the next Studio
    /// engine gets them back where they were, paused.
    @Test func engineStoppedKeepsTheStems() {
        var session = Self.ready()
        _ = session.handle(.player(position: 4, duration: 10, playing: true), level: .base)
        session.markSaved("/Music/Stelix/x")
        session.engineStopped()
        #expect(session.stage == .ready(Self.result()))
        #expect(session.playing == false)
        #expect(session.position == 4)
        #expect(session.savedFolder == "/Music/Stelix/x")
        #expect(session.stemsLevel == .base)
        #expect(session.source == .file(path: "/m/a.mp3"))
        #expect(session.startCommands(mix: Self.mix, telemetry: false)
                == [.setMix(Self.mix), .loadStems(Self.result(), position: 4)])
    }

    /// A job does not survive its engine: back to the stems that were there before.
    @Test func engineStoppedDropsTheJob() {
        var session = Self.ready()
        _ = session.changeModel(to: .pro)
        session.engineStopped()
        #expect(session.stage == .ready(Self.result()))
        #expect(!session.isBusy)
        #expect(session.stemsLevel == .base)
        // A late event of the old job finds nothing to update.
        _ = session.handle(.job(progress: 0.5, step: .separating), level: .pro)
        #expect(session.stage == .ready(Self.result()))
    }

    @Test func engineStoppedWithoutStemsGoesBackToTheStart() {
        var session = StudioSession()
        _ = session.record()
        _ = session.handle(.recording(seconds: 3, peaks: [0.2]), level: .base)
        session.engineStopped()
        #expect(session.stage == .idle)
        #expect(!session.isBusy)
        #expect(session.wave.isEmpty)
        #expect(session.startCommands(mix: Self.mix, telemetry: true).isEmpty)
        // Record works again on the new engine.
        #expect(session.record() == [.startRecording])
    }

    /// An error on screen does not come back with the new engine; Retry has nothing to redo.
    @Test func engineStoppedClearsAFailure() {
        var session = Self.ready()
        _ = session.load(path: "/m/b.mp3", level: .base)
        _ = session.handle(.failure(EngineFailure(.separationFailed)), level: .base)
        session.engineStopped()
        #expect(session.stage == .ready(Self.result()))
        #expect(session.retry(level: .base).isEmpty)
    }

    /// The beats travel with the stems: a new Studio engine gets them back with `loadStems`.
    @Test func beatsComeBackWithTheStems() {
        var session = StudioSession()
        var result = Self.result()
        result.beats = [0.5, 1, 1.5]
        _ = session.load(path: "/m/a.mp3", level: .base)
        _ = session.handle(.stemsReady(result), level: .base)
        session.engineStopped()
        #expect(session.startCommands(mix: Self.mix, telemetry: false) == [.setMix(Self.mix), .loadStems(result, position: 0)])
    }

    /// With the panel open the new engine also gets the telemetry on (it starts with it off).
    @Test func startCommandsTurnTelemetryOnWithThePanelOpen() {
        var session = Self.ready()
        session.engineStopped()
        #expect(session.startCommands(mix: Self.mix, telemetry: true)
                == [.setMix(Self.mix), .loadStems(Self.result(), position: 0), .setTelemetry(true)])
    }

    // MARK: Play while the Studio engine starts (Task 10.10)

    /// Back in the Studio, Play (or space) pressed while the engine starts is not lost: nothing goes to an
    /// engine that is not there, the button shows Pause at once, and the new engine starts playing.
    @Test func playWhileTheEngineStartsPlaysOnceItIsUp() {
        var session = Self.ready()
        session.engineStopped()
        #expect(session.togglePlayback().isEmpty)
        #expect(session.playing)
        #expect(session.startCommands(mix: Self.mix, telemetry: false)
                == [.setMix(Self.mix), .loadStems(Self.result(), position: 0), .player(.play)])
        // From here on the engine is there: commands go out again.
        _ = session.handle(.player(position: 0, duration: 10, playing: true), level: .base)
        #expect(session.togglePlayback() == [.player(.pause)])
    }

    /// Play then Pause before the engine is up: it starts paused.
    @Test func playThenPauseWhileTheEngineStartsStaysPaused() {
        var session = Self.ready()
        session.engineStopped()
        _ = session.togglePlayback()
        #expect(session.togglePlayback().isEmpty)
        #expect(!session.playing)
        #expect(session.startCommands(mix: Self.mix, telemetry: false)
                == [.setMix(Self.mix), .loadStems(Self.result(), position: 0)])
    }

    /// The Play wish is for one start only: the engine after the next does not play by itself.
    @Test func playWhileStartingIsForOneStartOnly() {
        var session = Self.ready()
        session.engineStopped()
        _ = session.play()
        _ = session.startCommands(mix: Self.mix, telemetry: false)
        session.engineStopped()
        #expect(!session.playing)
        #expect(session.startCommands(mix: Self.mix, telemetry: false)
                == [.setMix(Self.mix), .loadStems(Self.result(), position: 0)])
    }

    // MARK: The held space bar (Task 10.10)

    /// The repeats of a held space bar are swallowed where the first press played (no system beep), and
    /// they do not play and pause again.
    @Test func heldSpaceRepeatsAreSwallowedWithoutCommands() {
        var session = Self.ready()
        #expect(session.spaceKey(isRepeat: false) == [.player(.play)])
        #expect(session.spaceKey(isRepeat: true) == [])
        #expect(session.spaceKey(isRepeat: true) == [])
    }

    /// Where there is no play button the space bar, held or not, goes on to the panel.
    @Test func spaceGoesOnWithoutAPlayButton() {
        var empty = StudioSession()
        #expect(empty.spaceKey(isRepeat: false) == nil)
        #expect(empty.spaceKey(isRepeat: true) == nil)
        var recording = Self.ready()
        _ = recording.record()
        #expect(recording.spaceKey(isRepeat: true) == nil)
    }

    // MARK: Stems after the Studio was left (Task 10.10)

    /// A separation that ended in the last instants of its engine, after the user chose another section:
    /// its stems are taken, with their level, and nothing is sent (the engine is shutting down).
    @Test func stemsArrivingOutsideTheStudioAreKept() {
        var session = Self.ready()
        _ = session.changeModel(to: .pro)
        let fresh = Self.result("/m/a")
        session.handleOutsideStudio(.stemsReady(fresh))
        #expect(session.result == fresh)
        #expect(session.stemsLevel == .pro)
        session.engineStopped()
        #expect(session.stage == .ready(fresh))
        #expect(session.startCommands(mix: Self.mix, telemetry: false) == [.setMix(Self.mix), .loadStems(fresh, position: 0)])
    }

    /// Outside the Studio the rest of what the old engine says changes nothing.
    @Test func otherEventsOutsideTheStudioAreIgnored() {
        var session = Self.ready()
        _ = session.load(path: "/m/b.mp3", level: .base)
        let before = session
        session.handleOutsideStudio(.job(progress: 0.9, step: .writingStems))
        session.handleOutsideStudio(.failure(EngineFailure(.separationCancelled)))
        session.handleOutsideStudio(.player(position: 3, duration: 10, playing: true))
        #expect(session == before)
    }

    /// Back to the Studio while the previous engine still shuts down (the new one is not even made): Play waits
    /// for the new engine as well.
    @Test func playBeforeTheNewEngineIsMadeWaitsForIt() {
        var session = Self.ready()
        session.engineNotReady()
        #expect(session.togglePlayback().isEmpty)
        #expect(session.playing)
        session.engineStopped()   // the new engine is made
        #expect(session.startCommands(mix: Self.mix, telemetry: false)
                == [.setMix(Self.mix), .loadStems(Self.result(), position: 0), .player(.play)])
    }

    /// A Play asked for the Studio does not follow the user into another section: Live's engine drops it.
    @Test func playWhileWaitingIsDroppedForAnotherSectionsEngine() {
        var session = Self.ready()
        session.engineNotReady()
        _ = session.play()
        session.engineStopped(keepingPlayRequest: false)
        #expect(!session.playing)
        #expect(session.startCommands(mix: Self.mix, telemetry: false)
                == [.setMix(Self.mix), .loadStems(Self.result(), position: 0)])
    }

    /// Stems with no job to belong to (it went with its engine, or the stems were forgotten) are not taken.
    @Test func stemsOutsideTheStudioWithoutAJobAreIgnored() {
        var session = Self.ready()
        _ = session.changeModel(to: .pro)
        session.engineStopped()
        let before = session
        session.handleOutsideStudio(.stemsReady(Self.result("/m/late")))
        #expect(session == before)
        var forgotten = StudioSession()
        forgotten.handleOutsideStudio(.stemsReady(Self.result("/m/late")))
        #expect(forgotten.result == nil)
    }

    /// Play while the engine starts: the stems load stopped, and that state must not flip the button back to
    /// Play for an instant before the engine plays (Gabriele, 13/11: the play button glitched).
    @Test func theLoadedStateDoesNotFlipTheButtonBeforeItPlays() {
        var session = Self.ready()
        session.engineStopped()
        _ = session.togglePlayback()
        _ = session.startCommands(mix: Self.mix, telemetry: false)
        _ = session.handle(.player(position: 0, duration: 10, playing: false), level: .base)
        #expect(session.playing)
        _ = session.handle(.player(position: 0.1, duration: 10, playing: true), level: .base)
        _ = session.handle(.player(position: 0.2, duration: 10, playing: false), level: .base)
        #expect(!session.playing)
    }

    /// If the engine never plays (an output that fails), the button does not stay on Pause forever.
    @Test func theWaitForPlayEndsAfterAFewStoppedStates() {
        var session = Self.ready()
        session.engineStopped()
        _ = session.play()
        _ = session.startCommands(mix: Self.mix, telemetry: false)
        for _ in 0...StudioSession.maxStaleTicks {
            _ = session.handle(.player(position: 0, duration: 10, playing: false), level: .base)
        }
        #expect(!session.playing)
    }

    /// Pause pressed before the engine plays: the button follows the engine again at once.
    @Test func pauseBeforeTheEnginePlaysStopsWaiting() {
        var session = Self.ready()
        session.engineStopped()
        _ = session.play()
        _ = session.startCommands(mix: Self.mix, telemetry: false)
        #expect(session.togglePlayback() == [.player(.pause)])
        _ = session.handle(.player(position: 0, duration: 10, playing: false), level: .base)
        #expect(!session.playing)
    }

    // MARK: Transpose

    @Test func transposeStartsOff() {
        #expect(StudioSession().transpose == .off)
    }

    @Test func setTransposeWithoutStemsDoesNothing() {
        var session = StudioSession()
        session.setTranspose(Transpose(semitones: 3))
        #expect(session.transpose == .off)
    }

    @Test func transposeIsKeptWhileTheClipIsOpen() {
        var session = Self.ready()
        session.setTranspose(Transpose(semitones: 3))
        _ = session.togglePlayback()
        _ = session.rewind()
        session.markSaved("/m/x")
        #expect(session.transpose.semitones == 3)
    }

    /// A new clip: back to 0 when its stems arrive. While it separates the old stems play on, transposed.
    @Test func newFileResetsTransposeWhenItsStemsArrive() {
        var session = Self.ready()
        session.setTranspose(Transpose(semitones: 3))
        _ = session.load(path: "/m/b.mp3", level: .base)
        #expect(session.transpose.semitones == 3)
        _ = session.handle(.stemsReady(Self.result("/m/b")), level: .base)
        #expect(session.transpose == .off)
    }

    /// Choose file on the same file again is a new clip too.
    @Test func sameFileLoadedAgainResetsTranspose() {
        var session = Self.ready()
        session.setTranspose(Transpose(semitones: -5))
        _ = session.load(path: "/m/a.mp3", level: .base)
        _ = session.handle(.stemsReady(Self.result()), level: .base)
        #expect(session.transpose == .off)
    }

    @Test func recordingResetsTranspose() {
        var session = Self.ready()
        session.setTranspose(Transpose(semitones: 3))
        _ = session.record()
        _ = session.handle(.recording(seconds: 5, peaks: []), level: .base)
        _ = session.stop()
        _ = session.handle(.recorded(path: "/m/r.wav"), level: .base)
        _ = session.handle(.stemsReady(Self.result("/m/r")), level: .base)
        #expect(session.transpose == .off)
    }

    /// Cancel brings back the previous stems, with their transpose.
    @Test func cancelledNewClipKeepsTranspose() {
        var session = Self.ready()
        session.setTranspose(Transpose(semitones: 3))
        _ = session.load(path: "/m/b.mp3", level: .base)
        _ = session.cancel()
        #expect(session.transpose.semitones == 3)
    }

    @Test func changeModelKeepsTranspose() {
        var session = Self.ready()
        session.setTranspose(Transpose(semitones: 3))
        _ = session.changeModel(to: .intermediate)
        _ = session.handle(.stemsReady(Self.result("/m/a-int")), level: .base)
        #expect(session.transpose.semitones == 3)
    }

    @Test func lostStemsResetTranspose() {
        var session = Self.ready()
        session.setTranspose(Transpose(semitones: 3))
        _ = session.handle(.failure(EngineFailure(.noStems)), level: .base)
        #expect(session.transpose == .off)
    }

    /// Record and Choose file refused while Change model runs do not mark a new clip.
    @Test func refusedNewClipDuringChangeModelKeepsTranspose() {
        var session = Self.ready()
        session.setTranspose(Transpose(semitones: 3))
        _ = session.changeModel(to: .intermediate)
        #expect(session.record().isEmpty)
        #expect(session.load(path: "/m/b.mp3", level: .base).isEmpty)
        _ = session.handle(.stemsReady(Self.result("/m/a-int")), level: .base)
        #expect(session.transpose.semitones == 3)
    }

    @Test func retryOfAFailedNewClipResetsTranspose() {
        var session = Self.ready()
        session.setTranspose(Transpose(semitones: 3))
        _ = session.load(path: "/m/b.mp3", level: .base)
        _ = session.handle(.failure(EngineFailure(.separationFailed)), level: .base)
        #expect(!session.retry(level: .base).isEmpty)
        _ = session.handle(.stemsReady(Self.result("/m/b")), level: .base)
        #expect(session.transpose == .off)
    }

    @Test func retryOfAFailedChangeModelKeepsTranspose() {
        var session = Self.ready()
        session.setTranspose(Transpose(semitones: 3))
        _ = session.changeModel(to: .intermediate)
        _ = session.handle(.failure(EngineFailure(.separationFailed)), level: .base)
        #expect(!session.retry(level: .base).isEmpty)
        _ = session.handle(.stemsReady(Self.result("/m/a-int")), level: .base)
        #expect(session.transpose.semitones == 3)
    }

    /// Leaving the Studio and coming back to the same stems keeps the transpose.
    @Test func leavingTheStudioKeepsTranspose() {
        var session = Self.ready()
        session.setTranspose(Transpose(semitones: -5))
        session.engineStopped()
        _ = session.startCommands(mix: Self.mix, telemetry: false)
        #expect(session.transpose.semitones == -5)
    }

    @Test func unreadableStemsResetTranspose() {
        var session = Self.ready()
        session.setTranspose(Transpose(semitones: 3))
        _ = session.handle(.failure(EngineFailure(.stemUnreadable)), level: .base)
        #expect(session.transpose == .off)
    }

    @Test func setTransposeSendsTheCommand() {
        var session = Self.ready()
        #expect(session.setTranspose(Transpose(semitones: 3)) == [.setTranspose(semitones: 3)])
        #expect(session.setTranspose(Transpose(semitones: 3)) == [])
    }

    @Test func setTransposeWaitsForTheEngine() {
        var session = Self.ready()
        session.engineStopped()
        #expect(session.setTranspose(Transpose(semitones: 3)) == [])
        #expect(session.transpose.semitones == 3)
    }

    // MARK: Transpose and the Studio engine (Task 11.5)

    @Test func savedFolderFollowsTheTranspose() {
        var session = Self.ready()
        session.setTranspose(Transpose(semitones: 3))
        session.markSaved("/m/a +3 st")
        #expect(!session.canSave)
        session.setTranspose(Transpose(semitones: 5))
        #expect(session.canSave && session.savedFolder == nil)
        session.setTranspose(Transpose(semitones: 3))
        #expect(session.savedFolder == "/m/a +3 st")
    }

    @Test func markSavedUsesTheValueTheSaveStartedWith() {
        var session = Self.ready()
        session.setTranspose(Transpose(semitones: 5))
        session.markSaved("/m/a +3 st", transpose: Transpose(semitones: 3))
        #expect(session.savedFolder == nil)
        session.setTranspose(Transpose(semitones: 3))
        #expect(session.savedFolder == "/m/a +3 st")
    }

    @Test func newStemsForgetTheSavedFolders() {
        var session = Self.ready()
        session.setTranspose(Transpose(semitones: 3))
        session.markSaved("/m/a +3 st")
        _ = session.changeModel(to: .intermediate)
        _ = session.handle(.stemsReady(Self.result("/m/a-int")), level: .base)
        #expect(session.savedFolder == nil)
    }

    @Test func startCommandsCarryTheTranspose() {
        var session = Self.ready()
        session.setTranspose(Transpose(semitones: 3))
        session.engineStopped()
        #expect(session.startCommands(mix: Self.mix, telemetry: false).last == .setTranspose(semitones: 3))
    }

    @Test func startCommandsAtZeroHaveNoTranspose() {
        var session = Self.ready()
        session.engineStopped()
        #expect(!session.startCommands(mix: Self.mix, telemetry: false).contains { command in
            if case .setTranspose = command { return true }
            return false
        })
    }

    @Test func changeModelSendsTheKeptTranspose() {
        var session = Self.ready()
        session.setTranspose(Transpose(semitones: 3))
        _ = session.changeModel(to: .intermediate)
        #expect(session.handle(.stemsReady(Self.result("/m/a-int")), level: .base) == [.setTranspose(semitones: 3)])
    }

    @Test func newClipStemsSendNothing() {
        var session = Self.ready()
        session.setTranspose(Transpose(semitones: 3))
        _ = session.load(path: "/m/b.mp3", level: .base)
        #expect(session.handle(.stemsReady(Self.result("/m/b")), level: .base) == [])
        #expect(session.transpose == .off)
    }

    // MARK: Speed (Task 12.1)

    @Test func setSpeedSendsTheCommand() {
        var session = Self.ready()
        #expect(session.speed == .normal)
        #expect(session.setSpeed(Speed(percent: 75)) == [.setSpeed(percent: 75)])
        #expect(session.setSpeed(Speed(percent: 75)) == [])
        var empty = StudioSession()
        #expect(empty.setSpeed(Speed(percent: 75)) == [])
        #expect(empty.speed == .normal)
    }

    @Test func setSpeedWaitsForTheEngine() {
        var session = Self.ready()
        session.engineStopped()
        #expect(session.setSpeed(Speed(percent: 75)) == [])
        #expect(session.speed.percent == 75)
    }

    /// Change Model keeps the speed and sends it again, after the transpose; a new clip goes back to 100%.
    @Test func speedFollowsTheStems() {
        var session = Self.ready()
        session.setTranspose(Transpose(semitones: 3))
        session.setSpeed(Speed(percent: 75))
        _ = session.changeModel(to: .intermediate)
        #expect(session.handle(.stemsReady(Self.result("/m/a-int")), level: .base)
            == [.setTranspose(semitones: 3), .setSpeed(percent: 75)])
        #expect(session.speed.percent == 75)
        _ = session.load(path: "/m/b.mp3", level: .base)
        #expect(session.speed.percent == 75)
        #expect(session.handle(.stemsReady(Self.result("/m/b")), level: .base) == [])
        #expect(session.speed == .normal)
    }

    @Test func changeModelSendsOnlyTheSpeedWithoutTranspose() {
        var session = Self.ready()
        session.setSpeed(Speed(percent: 60))
        _ = session.changeModel(to: .intermediate)
        #expect(session.handle(.stemsReady(Self.result("/m/a-int")), level: .base) == [.setSpeed(percent: 60)])
    }

    @Test func startCommandsCarrySpeed() throws {
        var session = Self.ready()
        session.setTranspose(Transpose(semitones: 3))
        session.setSpeed(Speed(percent: 75))
        session.engineStopped()
        _ = session.play()
        let commands = session.startCommands(mix: Self.mix, telemetry: false)
        let transpose = try #require(commands.firstIndex(of: .setTranspose(semitones: 3)))
        let speed = try #require(commands.firstIndex(of: .setSpeed(percent: 75)))
        let play = try #require(commands.firstIndex(of: .player(.play)))
        #expect(transpose < speed && speed < play)
    }

    @Test func startCommandsAtNormalSpeedHaveNoSpeed() {
        var session = Self.ready()
        session.engineStopped()
        #expect(!session.startCommands(mix: Self.mix, telemetry: false).contains { command in
            if case .setSpeed = command { return true }
            return false
        })
    }

    @Test func otherSpeedIsAnotherSave() {
        var session = Self.ready()
        session.setTranspose(Transpose(semitones: 3))
        session.markSaved("/m/a +3 st", transpose: Transpose(semitones: 3), speed: .normal)
        #expect(!session.canSave)
        session.setSpeed(Speed(percent: 75))
        #expect(session.canSave && session.savedFolder == nil)
        session.markSaved("/m/a +3 st 75%")
        session.setSpeed(.normal)
        #expect(session.savedFolder == "/m/a +3 st")
        session.setSpeed(Speed(percent: 75))
        #expect(session.savedFolder == "/m/a +3 st 75%")
    }

    @Test func markSavedUsesTheSpeedTheSaveStartedWith() {
        var session = Self.ready()
        session.setSpeed(Speed(percent: 80))
        session.markSaved("/m/a 75%", speed: Speed(percent: 75))
        #expect(session.savedFolder == nil)
        session.setSpeed(Speed(percent: 75))
        #expect(session.savedFolder == "/m/a 75%")
    }

    @Test func lostStemsResetSpeed() {
        var session = Self.ready()
        session.setSpeed(Speed(percent: 75))
        _ = session.handle(.failure(EngineFailure(.noStems)), level: .base)
        #expect(session.speed == .normal)
    }

    @Test func leavingTheStudioKeepsSpeed() {
        var session = Self.ready()
        session.setSpeed(Speed(percent: 50))
        session.engineStopped()
        _ = session.startCommands(mix: Self.mix, telemetry: false)
        #expect(session.speed.percent == 50)
    }

    // MARK: Key over the clip

    private static let am = MusicalKey(pitchClass: 9, mode: .minor)

    /// A clip of 60 s: eleven windows.
    private static func longReady() -> StudioSession {
        var session = StudioSession()
        _ = session.load(path: "/m/a.mp3", level: .base)
        var long = result()
        long.duration = 60
        _ = session.handle(.stemsReady(long), level: .base)
        return session
    }

    private static func scan(_ count: Int) -> KeyScan {
        KeyScan(duration: 60, windows: (0..<count).map { KeyWindow(index: $0, key: am) })
    }

    @Test func keyScanReachesTheShownStems() {
        var session = Self.longReady()
        #expect(session.handle(.keyScan(folder: "/m/a", Self.scan(4)), level: .base).isEmpty)
        #expect(session.result?.keyScan == Self.scan(4))
        guard case .ready(let shown) = session.stage else { Issue.record("not ready"); return }
        #expect(shown.keyScan == Self.scan(4))
    }

    /// A scan of other stems (a clip already replaced) is not taken.
    @Test func keyScanOfAnotherFolderIsIgnored() {
        var session = Self.longReady()
        _ = session.handle(.keyScan(folder: "/m/b", Self.scan(4)), level: .base)
        #expect(session.result?.keyScan == nil)
    }

    /// Change Model on the same clip: the new stems keep the key found so far until the engine sends it again.
    @Test func newStemsOfTheSameFolderKeepTheScan() {
        var session = Self.longReady()
        _ = session.handle(.keyScan(folder: "/m/a", Self.scan(4)), level: .base)
        _ = session.changeModel(to: .intermediate)
        var again = Self.result()
        again.duration = 60
        _ = session.handle(.stemsReady(again), level: .base)
        #expect(session.result?.keyScan == Self.scan(4))
    }

    @Test func newStemsOfAnotherFolderStartWithoutAScan() {
        var session = Self.longReady()
        _ = session.handle(.keyScan(folder: "/m/a", Self.scan(4)), level: .base)
        _ = session.load(path: "/m/b.mp3", level: .base)
        var other = Self.result("/m/b")
        other.duration = 60
        _ = session.handle(.stemsReady(other), level: .base)
        #expect(session.result?.keyScan == nil)
    }

    /// A new Studio engine goes on with the windows still missing, from the clip's source.
    @Test func startCommandsResumeAnUnfinishedScan() {
        var session = Self.longReady()
        _ = session.handle(.keyScan(folder: "/m/a", Self.scan(4)), level: .base)
        session.engineStopped()
        let commands = session.startCommands(mix: Self.mix, telemetry: false)
        #expect(commands.last == .scanKeys(path: "/m/a.mp3", folder: "/m/a", done: Self.scan(4)))
    }

    @Test func startCommandsStartAScanThatNeverCame() {
        var session = Self.longReady()
        session.engineStopped()
        #expect(session.startCommands(mix: Self.mix, telemetry: false).last
                == .scanKeys(path: "/m/a.mp3", folder: "/m/a", done: nil))
    }

    @Test func startCommandsLeaveAFinishedScan() {
        var session = Self.longReady()
        var finished = Self.scan(11)
        finished.setTrackKey(Self.am)
        _ = session.handle(.keyScan(folder: "/m/a", finished), level: .base)
        session.engineStopped()
        #expect(!session.startCommands(mix: Self.mix, telemetry: false).contains {
            if case .scanKeys = $0 { return true }
            return false
        })
    }
}
