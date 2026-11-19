// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

@MainActor final class FakeLoginItem: LoginItemService {
    var isEnabled: Bool
    var failNext = false
    private(set) var calls: [String] = []

    init(enabled: Bool = false) { isEnabled = enabled }

    struct Failure: Error {}

    func register() throws {
        calls.append("register")
        if failNext { failNext = false; throw Failure() }
        isEnabled = true
    }

    func unregister() throws {
        calls.append("unregister")
        if failNext { failNext = false; throw Failure() }
        isEnabled = false
    }
}

@MainActor struct LaunchAtLoginTests {
    @Test func readsTheServiceAtStart() {
        #expect(LaunchAtLogin(service: FakeLoginItem(enabled: true)).enabled)
        #expect(!LaunchAtLogin(service: FakeLoginItem(enabled: false)).enabled)
    }

    @Test func turningOnRegisters() {
        let service = FakeLoginItem()
        let login = LaunchAtLogin(service: service)
        login.set(true)
        #expect(service.calls == ["register"])
        #expect(login.enabled)
        #expect(!login.failed)
    }

    @Test func turningOffUnregisters() {
        let service = FakeLoginItem(enabled: true)
        let login = LaunchAtLogin(service: service)
        login.set(false)
        #expect(service.calls == ["unregister"])
        #expect(!login.enabled)
    }

    @Test func sameValueDoesNothing() {
        let service = FakeLoginItem(enabled: true)
        let login = LaunchAtLogin(service: service)
        login.set(true)
        #expect(service.calls.isEmpty)
    }

    @Test func failureKeepsTheRealStateAndSaysSo() {
        let service = FakeLoginItem()
        service.failNext = true
        let login = LaunchAtLogin(service: service)
        login.set(true)
        #expect(!login.enabled)
        #expect(login.failed)
        // The next attempt, successful, clears the error.
        login.set(true)
        #expect(login.enabled)
        #expect(!login.failed)
    }

    @Test func refreshFollowsSystemSettings() {
        let service = FakeLoginItem()
        let login = LaunchAtLogin(service: service)
        service.isEnabled = true  // turned on from System Settings
        login.refresh()
        #expect(login.enabled)
    }
}
