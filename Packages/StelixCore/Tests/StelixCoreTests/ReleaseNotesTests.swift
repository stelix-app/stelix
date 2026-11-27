// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct ReleaseNotesTests {
    static let english = "Stelix 1.2.0 adds a thing.\n\n- **Transpose**: up and down.\n- **Key**: shown.\n\n## Requirements\n- A Mac"
    static let italian = "\n\n## Known issues\nNone.\n\n<details>\n<summary>Italiano</summary>\n\nStelix 1.2.0 aggiunge.\n\n- **Trasponi**: su e giù.\n\n</details>\n"
    static let englishBlocks: [ReleaseNotes.Block] = [
        .paragraph("Stelix 1.2.0 adds a thing."), .bullet("**Transpose**: up and down."), .bullet("**Key**: shown."),
    ]

    static func italianSection(_ content: String, summary: String = "<summary>Italiano</summary>") -> String {
        "Intro.\n\n<details>\n\(summary)\n\n\(content)\n\n</details>\n"
    }

    @Test func englishIsWhatComesBeforeTheFirstHeading() {
        let notes = ReleaseNotes(body: Self.english)
        #expect(notes?.english == Self.englishBlocks)
        #expect(notes?.italian == [])
    }

    @Test func italianIsTheDetailsSection() {
        let notes = ReleaseNotes(body: Self.english + Self.italian)
        #expect(notes?.italian == [.paragraph("Stelix 1.2.0 aggiunge."), .bullet("**Trasponi**: su e giù.")])
        #expect(notes?.english == Self.englishBlocks)
    }

    @Test func summaryIgnoresCaseAndSpaces() {
        for summary in ["<summary> italiano </summary>", "<SUMMARY>ITALIANO</SUMMARY>"] {
            let notes = ReleaseNotes(body: Self.italianSection("Ciao.", summary: summary))
            #expect(notes?.italian == [.paragraph("Ciao.")], "\(summary)")
        }
    }

    @Test func detailsStopsTheEnglishToo() {
        let notes = ReleaseNotes(body: "Intro.\n<details>\n<summary>Italiano</summary>\n\nCiao.\n</details>")
        #expect(notes?.english == [.paragraph("Intro.")])
        #expect(notes?.italian == [.paragraph("Ciao.")])
    }

    @Test func brokenOrOtherDetailsLeaveNoItalian() {
        let bodies = [
            "Intro.\n\n<details>\n<summary>Italiano</summary>\n\nCiao, senza chiusura.",
            Self.italianSection("Hallo.", summary: "<summary>Deutsch</summary>"),
            Self.italianSection("Hello.", summary: "<summary>English</summary>"),
        ]
        for body in bodies {
            let notes = ReleaseNotes(body: body)
            #expect(notes?.english == [.paragraph("Intro.")], "\(body)")
            #expect(notes?.italian == [], "\(body)")
            #expect(notes?.blocks(for: "it") == [.paragraph("Intro.")], "\(body)")
        }
    }

    @Test func languagePicksItalianOnlyForIt() throws {
        let notes = try #require(ReleaseNotes(body: Self.english + Self.italian))
        for language in ["it", "it-IT"] {
            #expect(notes.blocks(for: language) == notes.italian, "\(language)")
        }
        for language in ["en", nil, "de"] as [String?] {
            #expect(notes.blocks(for: language) == Self.englishBlocks, "\(String(describing: language))")
        }
    }

    @Test func linksAndImagesBecomePlainText() {
        let body = "See [the README](https://x.y) and <https://a.b>. ![shot](https://i.png)<img src=\"x\"> <b>Bold</b>"
        #expect(ReleaseNotes(body: body)?.english == [.paragraph("See the README and https://a.b. Bold")])
    }

    /// A "<" that opens no tag is text: only the line's real tags go.
    @Test func aStrayLessThanKeepsTheText() {
        let body = "Latency < 10 ms on an M3.\n\n- Faster > before.\n- Still <b>bold</b> > 2."
        #expect(ReleaseNotes(body: body)?.english == [
            .paragraph("Latency < 10 ms on an M3."), .bullet("Faster > before."), .bullet("Still bold > 2."),
        ])
    }

    @Test func listsHeadingsAndContinuations() {
        let content = "### Fixes\n1. One\n2. Two\n   still two\n* Star\n+ Plus\n\nPara\nline two"
        #expect(ReleaseNotes(body: Self.italianSection(content))?.italian == [
            .heading("Fixes"), .numbered("1.", "One"), .numbered("2.", "Two still two"),
            .bullet("Star"), .bullet("Plus"), .paragraph("Para line two"),
        ])
    }

    @Test func windowsLineEndingsAndComments() {
        #expect(ReleaseNotes(body: "A\r\n\r\n<!-- note -->\r\n- B\r\n")?.english == [.paragraph("A"), .bullet("B")])
    }

    @Test func nothingUsefulIsNil() {
        for body in ["", "## Requirements\n- Mac", "   \n", "<!-- only a comment -->"] {
            #expect(ReleaseNotes(body: body) == nil, "\(body)")
        }
    }

    @Test func aHugeBodyIsCut() throws {
        let notes = try #require(ReleaseNotes(body: String(repeating: "a", count: 100_000)))
        let length = notes.english.reduce(0) { total, block in
            switch block {
            case .paragraph(let text), .heading(let text), .bullet(let text): total + text.count
            case .numbered(let marker, let text): total + marker.count + text.count
            }
        }
        #expect(length > 0)
        #expect(length <= ReleaseNotes.maxLength)
    }
}
