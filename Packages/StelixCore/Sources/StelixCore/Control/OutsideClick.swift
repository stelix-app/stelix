// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// Decides when a click outside the panel closes it. A left click closes on release, and
/// only if no drag has started in the meantime: dragging a file from Finder to the
/// Studio starts with a click outside, and the panel must stay open to receive the drop.
/// A right click closes at once.
public struct OutsideClick: Sendable {
    public enum Mouse: Sendable {
        case leftDown, leftDragged, leftUp, rightDown
    }

    private var pressed = false
    private var dragged = false

    public init() {}

    /// `true` if the panel is to be closed.
    public mutating func handle(_ mouse: Mouse) -> Bool {
        switch mouse {
        case .leftDown:
            pressed = true
            dragged = false
            return false
        case .leftDragged:
            if pressed { dragged = true }
            return false
        case .leftUp:
            defer { pressed = false; dragged = false }
            return pressed && !dragged
        case .rightDown:
            return true
        }
    }
}
