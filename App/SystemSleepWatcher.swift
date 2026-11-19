// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import IOKit.pwr_mgt
import os

/// Holds the system sleep until Stelix has let go of its process taps, then lets it go on.
///
/// A tap alive across sleep can deadlock coreaudiod when the output device reconfigures at the wake
/// (13/11, Live on a USB interface: no app could play audio until coreaudiod was killed). The
/// `NSWorkspace` notifications don't wait for anyone; `IORegisterForSystemPower` does, until
/// `IOAllowPowerChange` or about 30 s. Stelix answers within `limit` in any case.
@MainActor final class SystemSleepWatcher {
    private static let log = Logger(subsystem: "io.github.stelix-app.stelix", category: "app")
    /// The `iokit_common_msg` values of IOMessage.h, which Swift does not import (they are macros).
    private static let canSystemSleep: natural_t = 0xE000_0270
    private static let systemWillSleep: natural_t = 0xE000_0280
    private static let systemHasPoweredOn: natural_t = 0xE000_0300
    /// macOS waits about 30 s for an answer: Stelix answers before, even if the shutdown hangs.
    static let limit: Duration = .seconds(10)
    /// The devices come back one by one after the wake: Live restarts when they have settled.
    static let wakeSettle: Duration = .seconds(2)

    private let willSleep: @MainActor () async -> Void
    private let didWake: @MainActor () -> Void
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init(willSleep: @escaping @MainActor () async -> Void, didWake: @escaping @MainActor () -> Void) {
        self.willSleep = willSleep
        self.didWake = didWake
    }

    func start() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, messageType, argument in
            guard let refcon else { return }
            let watcher = Unmanaged<SystemSleepWatcher>.fromOpaque(refcon).takeUnretainedValue()
            let id = Int(bitPattern: argument)
            // The notification port is on the main queue.
            MainActor.assumeIsolated { watcher.handle(messageType, id: id) }
        }, &notifier)
        guard rootPort != 0, let notifyPort else {
            Self.log.error("sleep: IORegisterForSystemPower failed")
            return
        }
        IONotificationPortSetDispatchQueue(notifyPort, .main)
    }

    private func handle(_ message: natural_t, id: Int) {
        switch message {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, id)
        case Self.systemWillSleep:
            Self.log.info("sleep: the system is going to sleep, letting go of the taps")
            let reply = Reply(rootPort: rootPort, id: id)
            Task {
                await willSleep()
                reply.send()
            }
            Task {
                try? await Task.sleep(for: Self.limit)
                if !reply.sent { Self.log.error("sleep: taps still open after \(Self.limit), sleeping anyway") }
                reply.send()
            }
        case Self.systemHasPoweredOn:
            Self.log.info("sleep: the system is awake")
            Task {
                try? await Task.sleep(for: Self.wakeSettle)
                didWake()
            }
        default:
            break
        }
    }

    /// The one answer to a sleep notification: whichever comes first, the shutdown or the limit.
    private final class Reply {
        let rootPort: io_connect_t
        let id: Int
        private(set) var sent = false

        init(rootPort: io_connect_t, id: Int) {
            self.rootPort = rootPort
            self.id = id
        }

        func send() {
            guard !sent else { return }
            sent = true
            IOAllowPowerChange(rootPort, id)
        }
    }
}
