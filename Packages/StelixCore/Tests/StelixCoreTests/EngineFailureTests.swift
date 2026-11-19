// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct EngineFailureTests {
    private let fallback = EngineFailure(.separationFailed)

    @Test func missingStoreErrorBecomesMissingWeights() {
        let failure = EngineFailure(ModelStoreError.missing(.htdemucs6s), fallback: fallback)
        #expect(failure == EngineFailure(.missingWeights, detail: "htdemucs_6s"))
        #expect(failure.code == "weights")
    }

    @Test func engineFailureStaysAsIs() {
        let original = EngineFailure(.musicFolder)
        #expect(EngineFailure(original, fallback: fallback) == original)
    }

    @Test func anythingElseIsTheFallback() {
        #expect(EngineFailure(CocoaError(.fileWriteNoPermission), fallback: fallback) == fallback)
        #expect(EngineFailure(ModelStoreError.write, fallback: fallback) == fallback)
    }

    @Test func failureRoundTripsWithDetail() throws {
        let failure = EngineFailure(.tooLong, detail: "20")
        let data = try JSONEncoder().encode(failure)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["code"] as? String == "tooLong")
        #expect(object["message"] as? String == "tooLong")
        #expect(object["detail"] as? String == "20")
        #expect(try JSONDecoder().decode(EngineFailure.self, from: data) == failure)
        let plain = EngineFailure(.noStems)
        #expect(try JSONDecoder().decode(EngineFailure.self, from: JSONEncoder().encode(plain)) == plain)
    }

    /// An engine newer than the app can send a message the app does not know: the code remains.
    @Test func unknownMessageDecodesAsUnknown() throws {
        let data = Data(#"{"code": "model", "message": "somethingNew", "detail": "x"}"#.utf8)
        let failure = try JSONDecoder().decode(EngineFailure.self, from: data)
        #expect(failure.message == .unknown)
        #expect(failure.code == "model")
        #expect(failure.detail == "x")
    }

    @Test func codesMatchTable() {
        let table: [FailureMessage: String] = [
            .noStems: "noStems", .stemUnreadable: "file", .stemsUnwritable: "file", .recordingUnwritable: "file",
            .outputUnplayable: "output", .separationFailed: "model", .separationIncomplete: "model",
            .modelLoad: "model", .modelNotReady: "model", .modelTooSlow: "model", .modelUnexpected: "model",
            .modelMissingStem: "model", .alreadyRecording: "busy", .alreadySeparating: "busy",
            .recordingCancelled: "cancelled", .separationCancelled: "cancelled", .noAudio: "stall",
            .recordingInterrupted: "overrun", .silentRecording: "empty", .measureNotLive: "measure",
            .measureOutputChanged: "measure", .measureNoSignal: "measure", .missingWeights: "weights",
            .outputSetup: "aggregate", .badCommand: "badCommand", .noOutput: "noOutput", .tap: "tap",
            .audioStart: "start", .sidecarMissing: "sidecar", .musicFolder: "folder", .tempFolder: "folder",
            .unsupported: "unsupported", .tooLong: "tooLong", .engineLaunch: "launch", .engineTimeout: "timeout",
            .engineExited: "exit", .engineStopped: "crash", .unknown: "unknown",
            // Errors found by the app, not by the engine.
            .fileNoAccess: "access", .saveFailed: "save", .saveNoSpace: "save",
        ]
        #expect(table.count == FailureMessage.allCases.count)
        for message in FailureMessage.allCases {
            #expect(message.code == table[message], "\(message)")
            #expect(EngineFailure(message).code == message.code)
        }
    }
}
