// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

/// A second Stelix (the copy in the DMG while the one in Applications runs, or `open -n`) would empty the
/// temporary folder and the downloads of the first at launch: it gives way to the one already running.
struct SingleInstanceTests {
    private func at(_ pid: pid_t, _ seconds: Double?) -> SingleInstance.Instance {
        SingleInstance.Instance(pid: pid, launched: seconds.map { Date(timeIntervalSince1970: $0) })
    }

    @Test func aloneKeepsRunning() {
        #expect(SingleInstance.other(among: [], me: 500) == nil)
        #expect(SingleInstance.other(among: [at(500, 10)], me: 500) == nil)
    }

    @Test func givesWayToTheOneLaunchedFirst() {
        #expect(SingleInstance.other(among: [at(500, 20), at(412, 10)], me: 500) == 412)
        #expect(SingleInstance.other(among: [at(500, 20), at(412, 10)], me: 412) == nil)
        // Pids wrap around: the older one can have the higher pid.
        #expect(SingleInstance.other(among: [at(90_000, 10), at(300, 20)], me: 300) == 90_000)
        // Three at once: all give way to the same one, which stays.
        let three = [at(700, 30), at(412, 10), at(500, 20)]
        #expect(SingleInstance.other(among: three, me: 500) == 412)
        #expect(SingleInstance.other(among: three, me: 700) == 412)
        #expect(SingleInstance.other(among: three, me: 412) == nil)
        // Same launch time (or unknown): the pid breaks the tie, the same way for everyone.
        #expect(SingleInstance.other(among: [at(600, 10), at(601, 10)], me: 601) == 600)
        #expect(SingleInstance.other(among: [at(600, nil), at(601, nil)], me: 600) == nil)
    }

    @Test func notificationFollowsTheBundleID() {
        #expect(SingleInstance.openPanelNotification(bundleID: "io.example.App").rawValue == "io.example.App.openPanel")
    }
}
