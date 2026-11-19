// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation

/// One Stelix per user. At launch the app empties the Studio's temporary folder and `Models/.downloads`:
/// a second instance (the copy in the DMG while the one in Applications runs, or `open -n`) would
/// delete the recording, the unsaved stems and the downloads of the first. It gives way instead.
public enum SingleInstance {
    public struct Instance: Equatable, Sendable {
        public let pid: pid_t
        public let launched: Date?
        public init(pid: pid_t, launched: Date?) {
            self.pid = pid
            self.launched = launched
        }
    }

    /// The instance to give way to, among the running ones (`running` may include this one): the one
    /// launched first, the pid breaking ties (pids wrap around, so they do not say which is older). With
    /// three at once all give way to the same one. `nil`: this one is the one that stays.
    public static func other(among running: [Instance], me: pid_t) -> pid_t? {
        let first = running.min { a, b in
            let da = a.launched ?? .distantFuture, db = b.launched ?? .distantFuture
            return da != db ? da < db : a.pid < b.pid
        }
        guard let first, first.pid != me else { return nil }
        return first.pid
    }

    /// Posted by the instance that gives way: the one that stays opens its panel, so that launching Stelix
    /// again shows something. Derived from the bundle ID, so a rename carries it along.
    public static func openPanelNotification(bundleID: String) -> Notification.Name {
        Notification.Name(bundleID + ".openPanel")
    }
}
