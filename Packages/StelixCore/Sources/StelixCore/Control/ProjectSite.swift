// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation

/// The project's website, getstelix.com. About links its privacy policy, in the app's language:
/// the site has English at the root and Italian under /it/.
public enum ProjectSite {
    public static let home = URL(string: "https://getstelix.com/")!

    /// The privacy policy for a language code such as "it", "it-IT" or "en" (the app's first
    /// localization): Italian for Italian, English for everything else.
    public static func privacy(language: String?) -> URL {
        let italian = language?.lowercased().hasPrefix("it") ?? false
        return URL(string: italian ? "it/privacy/" : "privacy/", relativeTo: home)!.absoluteURL
    }
}
