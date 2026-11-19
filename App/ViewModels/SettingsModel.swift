// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import ServiceManagement
import StelixCore

/// Stelix's settings: for now "Open Stelix at login" and the version. An overlay shows them
/// inside the panel, opened and closed by the gear button in the header (or closed by Esc).
@MainActor @Observable final class SettingsModel {
    /// The settings overlay is open.
    private(set) var isOpen = false
    /// About replaces Settings inside the same overlay; Back returns.
    private(set) var showsAbout = false

    @ObservationIgnored private let login: LaunchAtLogin

    init(service: LoginItemService = MainAppLoginItem()) {
        login = LaunchAtLogin(service: service)
    }

    /// Read from `SMAppService.mainApp.status == .enabled`; writing it calls `register()` or `unregister()`.
    var launchAtLogin: Bool {
        get { login.enabled }
        set { login.set(newValue) }
    }

    /// The last change did not succeed: the overlay says so under the toggle.
    var launchAtLoginFailed: Bool { login.failed }

    /// "0.1 (1)"
    let version: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }()

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        // It can also be changed from System Settings: it is read again every time.
        login.refresh()
        showsAbout = false
        isOpen = true
    }

    func close() {
        isOpen = false
        showsAbout = false
    }

    func showAbout() {
        showsAbout = true
    }

    func showMain() {
        showsAbout = false
    }
}

/// `SMAppService.mainApp`, the login item of the app itself.
@MainActor final class MainAppLoginItem: LoginItemService {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}
