// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// The three sections of Stelix.
public enum Mode: String, Codable, Sendable, CaseIterable {
    case original, live, studio
}
