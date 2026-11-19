// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Observation

/// The app's login item: `SMAppService.mainApp` in production, a fake in tests.
@MainActor public protocol LoginItemService: AnyObject {
    var isEnabled: Bool { get }
    func register() throws
    func unregister() throws
}

/// "Open Stelix at login". The real state is always the system's: after every attempt it is
/// read again, so an error leaves the toggle where it was and `failed` says so below.
@MainActor @Observable public final class LaunchAtLogin {
    public private(set) var enabled: Bool
    /// The last `set` did not succeed.
    public private(set) var failed = false

    @ObservationIgnored private let service: LoginItemService

    public init(service: LoginItemService) {
        self.service = service
        enabled = service.isEnabled
    }

    public func set(_ on: Bool) {
        guard on != service.isEnabled else {
            enabled = on
            return
        }
        do {
            if on { try service.register() } else { try service.unregister() }
            failed = false
        } catch {
            failed = true
        }
        enabled = service.isEnabled
    }

    /// Reads the system again: it can also be turned on or off from System Settings.
    public func refresh() {
        enabled = service.isEnabled
    }
}
