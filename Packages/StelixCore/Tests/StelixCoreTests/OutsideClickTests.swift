// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

/// The panel closes on a click outside, but not when a drag starts from outside
/// (a file from Finder toward the Studio): the drop must be able to arrive.
struct OutsideClickTests {
    /// The decisions for a sequence of mouse events, in order.
    private static func decisions(_ events: [OutsideClick.Mouse]) -> [Bool] {
        var tracker = OutsideClick()
        return events.map { tracker.handle($0) }
    }

    @Test func plainClickOutsideCloses() {
        #expect(Self.decisions([.leftDown, .leftUp]) == [false, true])
    }

    @Test func dragFromOutsideKeepsThePanelOpen() {
        // The next click closes again.
        #expect(Self.decisions([.leftDown, .leftDragged, .leftUp, .leftDown, .leftUp])
            == [false, false, false, false, true])
    }

    @Test func rightClickOutsideClosesAtOnce() {
        #expect(Self.decisions([.rightDown]) == [true])
    }

    /// The click that opened the panel (down before the monitor) does not close it again on release.
    @Test func releaseWithoutPressDoesNothing() {
        #expect(Self.decisions([.leftUp]) == [false])
    }
}
