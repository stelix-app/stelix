// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

/// A stem separated by the model. The raw value is the name used by Demucs and the JSON.
public enum Stem: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
    case vocals, drums, bass, other, piano, guitar

    /// The 4 Live stems (htdemucs), in UI order.
    public static let live: [Stem] = [.vocals, .drums, .bass, .other]
    /// The 6 Studio stems (htdemucs_6s and sidecar), in UI order.
    public static let studio: [Stem] = [.vocals, .piano, .guitar, .bass, .drums, .other]

    /// The file name in the working folders, in English. On Save the app chooses the name
    /// in the language of whoever uses Stelix.
    public var fileName: String { "\(rawValue).wav" }
}
