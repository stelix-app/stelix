// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Darwin
import Foundation
import Testing
@testable import StelixCore

struct SignalCatchTests {
    @Test func handlerIsInstalledAndSurvivesAnyThread() async {
        SignalCatch.withoutAction(SIGUSR2)
        var action = sigaction()
        sigaction(SIGUSR2, nil, &action)
        let handler = unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self)
        #expect(handler != unsafeBitCast(SIG_IGN, to: Int.self))
        #expect(handler != unsafeBitCast(SIG_DFL, to: Int.self))
        // Delivered to any thread, the process keeps going.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                pthread_kill(pthread_self(), SIGUSR2)
                done.resume()
            }
        }
        signal(SIGUSR2, SIG_DFL)
    }
}
