// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation

/// What must not reach the system log in clear: the names of the user's files and devices, and the
/// home folder. The engine writes its log on stderr and the app copies it into the system log, where
/// it stays readable after the fact and ends up in whatever the user pastes into a bug report.
///
/// The engine wraps a private value with `mark`; the app passes every line through `redact` (see
/// `LogRelay`). In a terminal (`scripts/engine-repl.sh`) the values stay readable.
public enum LogPrivacy {
    static let open: Unicode.Scalar = "\u{1}"
    static let close: Unicode.Scalar = "\u{2}"
    static let placeholder = "<private>"

    /// Wraps a value that `redact` will hide.
    public static func mark(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(open)
        scalars.append(contentsOf: value.unicodeScalars.filter { $0 != open && $0 != close })
        scalars.append(close)
        return String(scalars)
    }

    /// An error as the log may show it: its domain and code, never its text or `userInfo`, where
    /// AVFoundation and MusicUnderstanding put the URL of the user's file. The engine's own failures
    /// keep their code, message and detail, which is a model or stem name.
    public static func describe(error: any Error) -> String {
        if let failure = error as? EngineFailure {
            return [failure.code, failure.message.rawValue, failure.detail].compactMap(\.self).joined(separator: " ")
        }
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }

    /// A file the user gave to the app, as the log may name it: its type, never its name or folder.
    public static func describe(file url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let plain = !ext.isEmpty && ext.count <= 5 && ext.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0)
        }
        return plain ? "\(ext) file" : "file"
    }

    /// The text for the system log: every marked value becomes `<private>` and the home folder `~`.
    /// A mark left open hides everything after it.
    public static func redact(_ text: String, home: String = NSHomeDirectory()) -> String {
        var hidden = false
        return redact(text, home: home, hidden: &hidden)
    }

    /// `hidden` says whether the text starts inside a marked value, and on return whether it ends inside one.
    /// By scalars, not characters: a value that starts with a combining mark would join the opening
    /// into one character and pass unseen.
    static func redact(_ text: String, home: String, hidden: inout Bool) -> String {
        var scalars = String.UnicodeScalarView()
        if hidden { scalars.append(contentsOf: placeholder.unicodeScalars) }
        for scalar in text.unicodeScalars {
            if hidden {
                if scalar == close { hidden = false }
            } else if scalar == open {
                hidden = true
                scalars.append(contentsOf: placeholder.unicodeScalars)
            } else if scalar != close {
                scalars.append(scalar)
            }
        }
        let shown = String(scalars)
        guard !home.isEmpty else { return shown }
        // Only the whole folder name: /Users/ann must not match inside /Users/anna.
        let pattern = NSRegularExpression.escapedPattern(for: home) + "(?![A-Za-z0-9._-])"
        return shown.replacingOccurrences(of: pattern, with: "~", options: .regularExpression)
    }
}

/// Turns the bytes of the engine's stderr into the lines for the system log, already redacted.
/// Lines come out whole, because a marked value cut between two chunks could not be hidden.
public struct LogRelay: Sendable {
    /// A line longer than this comes out in pieces: output that never ends a line must not pile up.
    public static let maxLineBytes = 16 * 1024

    private let home: String
    private var buffer = Data()
    /// The piece just sent ended inside a marked value: the rest of the line starts hidden.
    private var hidden = false

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    public mutating func feed(_ chunk: Data) -> [String] {
        var lines: [String] = []
        var rest = chunk[...]
        while !rest.isEmpty {
            let window = rest.prefix(Self.maxLineBytes - buffer.count)
            if let newline = window.firstIndex(of: 0x0A) {
                buffer.append(rest[..<newline])
                rest = rest[rest.index(after: newline)...]
                flush(endOfLine: true, into: &lines)
            } else {
                buffer.append(window)
                rest = rest.dropFirst(window.count)
                if buffer.count >= Self.maxLineBytes { flush(endOfLine: false, into: &lines) }
            }
        }
        return lines
    }

    /// The pipe closed: what is left without a newline.
    public mutating func finish() -> [String] {
        var lines: [String] = []
        flush(endOfLine: true, into: &lines)
        return lines
    }

    private mutating func flush(endOfLine: Bool, into lines: inout [String]) {
        let text = String(decoding: buffer, as: UTF8.self)
        buffer = Data()
        defer { if endOfLine { hidden = false } }
        guard !text.allSatisfy(\.isWhitespace) else { return }
        let line = LogPrivacy.redact(text, home: home, hidden: &hidden)
        lines.append(line.hasSuffix("\r") ? String(line.dropLast()) : line)
    }
}
