// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import os
import StelixCore

/// Routes the engine's events to whoever uses them: the Live view model and the Studio one.
/// Levels, permission suspicion and errors go to the one of the chosen mode: Live and Studio
/// never live in the same engine. The mode state is kept by ModeController.
@MainActor final class EventRouter {
    private static let log = Logger(subsystem: "io.github.stelix-app.stelix", category: "events")

    weak var live: LiveViewModel?
    weak var studio: StudioViewModel?
    /// The chosen mode, read on every shared event.
    var mode: () -> Mode = { .original }
    /// The permission suspicion always gets through: the permission can be taken away in System Settings,
    /// and only zeros can also mean a paused player. The banner says both, and goes when audio arrives.
    func route(_ event: Event) {
        switch event {
        case .ready:
            break
        case .live, .liveStats, .measuredDelay, .tempo, .key:
            live?.handle(event)
        case .recording, .recorded, .job, .stemsReady, .player, .keyScan:
            studio?.handle(event)
        case .levels, .permissionSuspected:
            routeByMode(event)
        case .failure(let failure):
            Self.log.error("engine: \(failure.code, privacy: .public) \(failure.message.rawValue, privacy: .public) \(failure.detail ?? "", privacy: .public)")
            routeByMode(event)
        }
    }

    private func routeByMode(_ event: Event) {
        switch mode() {
        case .live: live?.handle(event)
        case .studio: studio?.handle(event)
        case .original: break
        }
    }
}
