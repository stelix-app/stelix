// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation

/// Remembers, for good, that the audio permission works: Stelix has heard real sound once.
///
/// Exact zeros from the start mean a denied permission, but also an app that keeps the output open with
/// nothing playing (Safari with a paused video, Logic): macOS does not tell the two apart. Once real sound
/// has come in, `.permissionSuspected` is a silent app, and the permission banner no longer shows.
/// The price: a permission removed later in System Settings shows the wait for audio, not the banner.
/// Nothing turns it off but deleting the preferences.
public struct CapturePermissionMemory {
    public static let key = "audioCaptureConfirmed"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var confirmed: Bool { defaults.bool(forKey: Self.key) }

    /// Live: any stem level above zero confirms.
    public func heard(levels: [Stem: Float]) {
        if levels.values.contains(where: { $0 > 0 }) { confirm() }
    }

    /// Studio recording: any peak above zero confirms.
    public func heard(peaks: [Float]) {
        if peaks.contains(where: { $0 > 0 }) { confirm() }
    }

    private func confirm() {
        if !confirmed { defaults.set(true, forKey: Self.key) }
    }
}
