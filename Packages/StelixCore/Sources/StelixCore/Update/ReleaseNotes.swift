// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation

/// What's new in a release, read from the `body` of its GitHub page, for the update window.
/// English is what comes before the first heading (requirements, install and checksums follow it
/// and stay on GitHub); Italian is the collapsed section at the bottom:
///
///     <details>
///     <summary>Italiano</summary>
///
///     …
///     </details>
///
/// The text comes from the network: links and images become plain text and other HTML goes, so
/// nothing in the window opens or loads anything. Only inline bold, italic and code stay, as Markdown.
public struct ReleaseNotes: Equatable, Sendable {
    public enum Block: Equatable, Sendable {
        /// The text keeps inline Markdown (`**bold**`, `*italic*`, `` `code` ``).
        case paragraph(String)
        case heading(String)
        case bullet(String)
        /// The marker as written ("1."), then the text.
        case numbered(String, String)
    }

    /// A longer body is cut before it is read.
    public static let maxLength = 20_000

    public let english: [Block]
    public let italian: [Block]

    /// Nil when neither language has anything to show.
    public init?(body: String) {
        let text = String(body.prefix(Self.maxLength))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        english = Self.blocks(Self.englishPart(of: text))
        italian = Self.italianPart(of: text).map(Self.blocks) ?? []
        if english.isEmpty && italian.isEmpty { return nil }
    }

    /// Italian for an Italian app ("it", "it-IT") when there is some, English otherwise.
    public func blocks(for language: String?) -> [Block] {
        if let language, language.lowercased().hasPrefix("it"), !italian.isEmpty { return italian }
        return english
    }

    // MARK: - Sections

    private static let headingLine = regex(#"^ {0,3}#"#, options: .anchorsMatchLines)
    private static let detailsOpen = regex(#"<details\b[^>]*>"#)
    private static let detailsClose = regex(#"</details\s*>"#)
    private static let summary = regex(#"<summary\b[^>]*>([\s\S]*?)</summary\s*>"#)

    private static func englishPart(of text: String) -> String {
        let ends = [headingLine, detailsOpen].compactMap { firstRange(of: $0, in: text)?.lowerBound }
        guard let end = ends.min() else { return text }
        return String(text[..<end])
    }

    /// The content of the first closed `<details>` whose summary is "Italiano".
    private static func italianPart(of text: String) -> String? {
        var start = text.startIndex
        while let open = firstRange(of: detailsOpen, in: text, from: start) {
            guard let close = firstRange(of: detailsClose, in: text, from: open.upperBound) else { return nil }
            let inside = String(text[open.upperBound..<close.lowerBound])
            if let match = summary.firstMatch(in: inside, range: NSRange(inside.startIndex..., in: inside)),
               let label = Range(match.range(at: 1), in: inside),
               inside[label].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "italiano",
               let all = Range(match.range, in: inside) {
                return String(inside[all.upperBound...])
            }
            start = close.upperBound
        }
        return nil
    }

    // MARK: - Blocks

    /// HTML comments, images, links and tags, in this order: an image is a link with a "!".
    private static let cleanups: [(NSRegularExpression, String)] = [
        (regex(#"<!--[\s\S]*?-->"#), ""),
        (regex(#"!\[[^\]]*\]\([^)]*\)"#), ""),
        (regex(#"\[([^\]]*)\]\([^)]*\)"#), "$1"),
        (regex(#"<(https?://[^>\s]+)>"#), "$1"),
        // A tag starts with a letter (or "/" and a letter) and ends on its line: "latency < 10 ms" stays.
        (regex(#"</?[a-z][^<>\n]*>"#), ""),
    ]
    private static let heading = regex(#"^#{1,6}\s+(.*)$"#)
    private static let bullet = regex(#"^[-*+]\s+(.*)$"#)
    private static let numbered = regex(#"^(\d{1,3}\.)\s+(.*)$"#)

    private static func blocks(_ markdown: String) -> [Block] {
        var text = markdown
        for (pattern, template) in cleanups {
            text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                    withTemplate: template)
        }
        var result: [Block] = []
        var current: Block?
        func close() {
            if let block = current.map(tidy), !isEmpty(block) { result.append(block) }
            current = nil
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                close()
            } else if let groups = match(heading, line) {
                close()
                current = .heading(groups[0])
                close()
            } else if let groups = match(bullet, line) {
                close()
                current = .bullet(groups[0])
            } else if let groups = match(numbered, line) {
                close()
                current = .numbered(groups[0], groups[1])
            } else if let block = current {
                current = append(line, to: block)
            } else {
                current = .paragraph(line)
            }
        }
        close()
        return result
    }

    /// A line that starts no block continues the one before it.
    private static func append(_ line: String, to block: Block) -> Block {
        switch block {
        case .paragraph(let text): .paragraph(text + " " + line)
        case .heading(let text): .heading(text + " " + line)
        case .bullet(let text): .bullet(text + " " + line)
        case .numbered(let marker, let text): .numbered(marker, text + " " + line)
        }
    }

    /// Runs of spaces (left by a removed tag or image) become one.
    private static func tidy(_ block: Block) -> Block {
        func squeeze(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        switch block {
        case .paragraph(let text): return .paragraph(squeeze(text))
        case .heading(let text): return .heading(squeeze(text))
        case .bullet(let text): return .bullet(squeeze(text))
        case .numbered(let marker, let text): return .numbered(marker, squeeze(text))
        }
    }

    private static func isEmpty(_ block: Block) -> Bool {
        switch block {
        case .paragraph(let text), .heading(let text), .bullet(let text), .numbered(_, let text): text.isEmpty
        }
    }

    // MARK: - Regular expressions

    private static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // The patterns are constants of this file: a bad one is a programming error.
        try! NSRegularExpression(pattern: pattern, options: options.union(.caseInsensitive))
    }

    private static func firstRange(of pattern: NSRegularExpression, in text: String,
                                   from start: String.Index? = nil) -> Range<String.Index>? {
        let range = NSRange((start ?? text.startIndex)..., in: text)
        return pattern.firstMatch(in: text, range: range).flatMap { Range($0.range, in: text) }
    }

    /// The capture groups of a whole-line match.
    private static func match(_ pattern: NSRegularExpression, _ line: String) -> [String]? {
        guard let found = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (1..<found.numberOfRanges).map { index in
            Range(found.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
    }
}
