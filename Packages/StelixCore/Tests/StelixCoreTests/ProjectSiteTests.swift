// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct ProjectSiteTests {
    @Test func theHomeIsTheSite() {
        #expect(ProjectSite.home.absoluteString == "https://getstelix.com/")
    }

    @Test func italianOpensTheItalianPrivacy() {
        for language in ["it", "it-IT", "it_IT", "IT"] {
            #expect(ProjectSite.privacy(language: language).absoluteString == "https://getstelix.com/it/privacy/", "\(language)")
        }
    }

    @Test func everyOtherLanguageOpensTheEnglishPrivacy() {
        for language in ["en", "en-IT", "de", "", nil] as [String?] {
            #expect(ProjectSite.privacy(language: language).absoluteString == "https://getstelix.com/privacy/", "\(language ?? "nil")")
        }
    }
}
