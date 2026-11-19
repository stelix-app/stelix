// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Synchronization
import Testing
@testable import StelixCore

/// `SidecarProcess` with `/bin/sh` in place of the Python sidecar: same lines, same signals.
struct SidecarProcessTests {
    private func sh(_ script: String, grace: Double = 1) -> SidecarProcess {
        SidecarProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], grace: grace)
    }

    private func parse(_ text: String) -> SidecarMessage? { SidecarMessage.parse(Data(text.utf8)) }

    /// `run` blocks the thread until the process ends: it runs on a GCD queue, not on the cooperative
    /// pool of the tests (blocking it delays the async tests that measure time, like EngineStopTests).
    private func runOffPool(_ process: SidecarProcess) async throws -> (messages: [SidecarMessage], exit: SidecarProcess.Exit) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                var messages: [SidecarMessage] = []
                continuation.resume(with: Result { () throws -> ([SidecarMessage], SidecarProcess.Exit) in
                    let exit = try process.run { messages.append($0) }
                    return (messages, exit)
                })
            }
        }
    }

    /// Like `runOffPool`, but `terminate()` starts when the first line arrives: the script writes it
    /// after setting its `trap`s, so under load the signal does not reach an `sh` that is not
    /// ready yet. It also returns the instant of `terminate()`.
    private func runTerminatingWhenReady(_ process: SidecarProcess) async throws
        -> (exit: SidecarProcess.Exit, terminatedAt: ContinuousClock.Instant) {
        let terminatedAt = Mutex<ContinuousClock.Instant?>(nil)
        let exit = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SidecarProcess.Exit, Error>) in
            DispatchQueue.global().async {
                continuation.resume(with: Result {
                    try process.run { _ in
                        let first = terminatedAt.withLock { at -> Bool in
                            guard at == nil else { return false }
                            at = ContinuousClock.now
                            return true
                        }
                        if first { DispatchQueue.global().async { process.terminate() } }
                    }
                })
            }
        }
        return (exit, try #require(terminatedAt.withLock { $0 }))
    }

    private static let ready = #"printf '{"progress":0,"step":"readingFile"}\n'"#

    @Test func parsesTheThreeLines() {
        #expect(parse(#"{"progress": 0.35, "step": "separatingVocals"}"#) == .progress(0.35, .separatingVocals))
        #expect(parse(#"{"progress": 1, "step": "writingStems"}"#) == .progress(1, .writingStems))
        #expect(parse(#"{"done": true, "files": {"vocals": "/a/vocals.wav", "guitar": "/a/guitar.wav"}}"#)
            == .done([.vocals: "/a/vocals.wav", .guitar: "/a/guitar.wav"]))
        #expect(parse(#"{"error": "model", "message": "separationFailed"}"#) == .error(EngineFailure(.separationFailed)))
    }

    /// A step the app does not know (or that is missing) is worth "Separating…".
    @Test func sidecarProgressLineReadsStep() {
        #expect(parse(#"{"progress": 0.5, "step": "preparingModel"}"#) == .progress(0.5, .preparingModel))
        #expect(parse(#"{"progress": 0.5, "step": "somethingNew"}"#) == .progress(0.5, .separating))
        #expect(parse(#"{"progress": 0.5}"#) == .progress(0.5, .separating))
    }

    /// Missing weights arrive with the file name; `detail` becomes the model that contains it,
    /// as for engine errors. An unknown message is worth "Separation failed".
    @Test func sidecarErrorLineKeepsMessageAndDetail() {
        #expect(parse(#"{"error": "weights", "message": "missingWeights", "detail": "BS-Roformer-SW.ckpt"}"#)
            == .error(EngineFailure(.missingWeights, detail: "bs_roformer_sw")))
        #expect(parse(#"{"error": "weights", "message": "missingWeights", "detail": "model_bs_roformer_ep_317_sdr_12.9755.yaml"}"#)
            == .error(EngineFailure(.missingWeights, detail: "bs_roformer_ep317")))
        #expect(parse(#"{"error": "unsupported", "message": "unsupported", "detail": null}"#) == .error(EngineFailure(.unsupported)))
        #expect(parse(#"{"error": "model", "message": "somethingNew"}"#) == .error(EngineFailure(.separationFailed)))
        #expect(parse(#"{"error": "model"}"#) == .error(EngineFailure(.separationFailed)))
    }

    @Test func unknownLinesAreIgnored() {
        #expect(parse("ciao") == nil)
        #expect(parse("{}") == nil)
        #expect(parse("[1, 2]") == nil)
        #expect(parse(#"{"done": true, "files": {"flauto": "/a/flauto.wav"}}"#) == nil)
        #expect(parse(#"{"progress": "tanto", "step": "separating"}"#) == nil)
    }

    @Test func deliversLinesInOrderAndExitStatus() async throws {
        // The second line arrives split into two writes, the last without a newline.
        let process = sh(#"""
        printf '{"progress":0.1,"step":"readingFile"}\n'; sleep 0.1
        printf 'rumore\n{"progr'; sleep 0.1
        printf 'ess":0.5,"step":"separating"}\n{"done":true,"files":{"vocals":"/v"}}'
        exit 3
        """#)
        let (got, exit) = try await runOffPool(process)
        #expect(got == [.progress(0.1, .readingFile), .progress(0.5, .separating), .done([.vocals: "/v"])])
        #expect(exit == SidecarProcess.Exit(status: 3, signaled: false))
        #expect(!process.wasCancelled)
    }

    @Test func stdinStaysOpenWhileRunning() async throws {
        // `read` ends only when stdin closes: if it closed at once "done" would arrive.
        let process = sh(#"read -r line; printf '{"done":true,"files":{}}\n'"#)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { process.terminate() }
        let (got, exit) = try await runOffPool(process)
        #expect(got.isEmpty)
        #expect(exit == SidecarProcess.Exit(status: SIGTERM, signaled: true))
        #expect(process.wasCancelled)
    }

    @Test func sigtermEndsAPoliteProcessQuickly() async throws {
        let process = sh("\(Self.ready); while :; do sleep 0.05; done")
        let (exit, terminatedAt) = try await runTerminatingWhenReady(process)
        #expect(ContinuousClock.now - terminatedAt < .milliseconds(800))
        #expect(exit == SidecarProcess.Exit(status: SIGTERM, signaled: true))
    }

    @Test func terminateEscalatesToKillAfterGrace() async throws {
        let process = sh("trap '' TERM; \(Self.ready); while :; do sleep 0.05; done", grace: 0.3)
        let (exit, terminatedAt) = try await runTerminatingWhenReady(process)
        let elapsed = ContinuousClock.now - terminatedAt
        #expect(elapsed >= .milliseconds(250))
        // Without the escalation the process would run forever: the upper bound only has to tell the two
        // apart, and with the Mac under load 2 s was not always enough.
        #expect(elapsed < .seconds(5))
        #expect(exit == SidecarProcess.Exit(status: SIGKILL, signaled: true))
    }

    /// A 3 MB line (over the 1 MiB cap) is thrown away, and the lines after it still arrive.
    @Test func tooLongLineIsSkippedAndTheNextArrives() async throws {
        let process = sh(#"head -c 3000000 /dev/zero | tr '\0' 'a'; printf '\n{"done":true,"files":{}}\n'"#)
        let (messages, exit) = try await runOffPool(process)
        #expect(messages == [parse(#"{"done":true,"files":{}}"#)!])
        #expect(exit == SidecarProcess.Exit(status: 0, signaled: false))
    }

    @Test func terminateBeforeRunDoesNotLaunch() {
        let process = sh(#"printf '{"done":true,"files":{}}\n'"#)
        process.terminate()
        var got: [SidecarMessage] = []
        #expect(throws: SidecarProcess.cancelled) { try process.run { got.append($0) } }
        #expect(got.isEmpty)
    }

    @Test func missingExecutableThrowsSidecarFailure() {
        let process = SidecarProcess(executable: URL(fileURLWithPath: "/nonexistent/python3"), arguments: [])
        #expect(throws: SidecarProcess.notFound) { try process.run { _ in } }
        #expect(SidecarProcess.notFound.code == "sidecar")
    }
}
