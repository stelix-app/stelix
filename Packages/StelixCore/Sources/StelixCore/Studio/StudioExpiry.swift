// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// When the Studio forgets its stems: after `delay` seconds of closed panel, never with the panel
/// open, never while something runs (recording, separation, playback, Save). Pure: the time comes from
/// outside, and every `check` says when to look again, so the app sleeps between two looks and does not
/// wake at all when there are no stems (Original at rest).
public struct StudioExpiry: Sendable, Equatable {
    /// 10 minutes, asked by Gabriele on 13/11.
    public static let delay = 600.0
    /// While something runs with the panel closed, the next look: then the count restarts from there.
    public static let busyRecheck = 60.0

    public enum Step: Equatable, Sendable {
        /// Forget the stems now.
        case clear
        /// Look again in these seconds.
        case wait(Double)
        /// Nothing to wait for: panel open, no stems, or already cleared.
        case stop
    }

    /// When the stems go, if nothing runs until then; `nil` with the panel open.
    private var deadline: Double?

    public init() {}

    /// Something runs with the panel closed: recording, separating, playing, saving. A job or a playback
    /// counts only with the Studio engine alive: after a crash, Original or Live the session may still say
    /// "playing", but nothing runs. Save copies with the app alone, in any section. An abandoned cancellation
    /// counts until the engine answers: before, it would ignore `clearStudio` (Task 10.10).
    public static func isBusy(session: StudioSession, studioEngineAlive: Bool, saving: Bool) -> Bool {
        if saving { return true }
        return studioEngineAlive && (session.isBusy || session.playing || session.cancelUnanswered)
    }

    public mutating func panelClosed(at now: Double) {
        deadline = now + Self.delay
    }

    public mutating func panelOpened() {
        deadline = nil
    }

    public mutating func check(at now: Double, hasStems: Bool, busy: Bool) -> Step {
        guard let current = deadline else { return .stop }
        if busy {
            deadline = max(current, now + Self.delay)
            return .wait(Self.busyRecheck)
        }
        guard hasStems else {
            deadline = nil
            return .stop
        }
        guard now >= current else { return .wait(current - now) }
        deadline = nil
        return .clear
    }
}
