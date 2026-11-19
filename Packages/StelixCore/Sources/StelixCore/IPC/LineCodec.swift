// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation

/// One `Codable` value per line: compact JSON plus "\n". JSONEncoder escapes "\n" in
/// strings, so the only 0x0A of the line is the final one.
public enum LineCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }
}

/// A line longer than `LineDecoder.maxLineBytes`.
public struct LineTooLong: Error, Equatable, Sendable {
    public init() {}
}

/// Splits the bytes that arrive from a pipe into lines, without the "\n". A line over `maxLineBytes`
/// gives `.failure(LineTooLong())` as soon as it passes the cap, and the rest of it is thrown away as it
/// arrives: a line that never ends cannot grow in memory. Used by `LineDecoder` and by `SidecarProcess`.
public struct LineSplitter {
    public let maxLineBytes: Int
    private var buffer = Data()
    /// Inside a line already refused as too long, up to its newline.
    private var discarding = false

    public init(maxLineBytes: Int = 1 << 20) {
        self.maxLineBytes = maxLineBytes
    }

    public mutating func feed(_ chunk: Data) -> [Result<Data, LineTooLong>] {
        var results: [Result<Data, LineTooLong>] = []
        var rest = chunk[...]
        while !rest.isEmpty {
            let newline = rest.firstIndex(of: 0x0A)
            let piece = rest[..<(newline ?? rest.endIndex)]
            rest = rest[(newline.map { rest.index(after: $0) } ?? rest.endIndex)...]
            if !discarding {
                if buffer.count + piece.count > maxLineBytes {
                    results.append(.failure(LineTooLong()))
                    buffer = Data()
                    discarding = true
                } else {
                    buffer.append(piece)
                }
            }
            guard newline != nil else { break }
            if discarding {
                discarding = false
                continue
            }
            results.append(.success(buffer))
            buffer = Data()
        }
        return results
    }

    /// What is left after the last newline, when the pipe closes: `nil` if empty or refused.
    public mutating func finish() -> Data? {
        defer { buffer = Data(); discarding = false }
        return discarding || buffer.isEmpty ? nil : buffer
    }
}

/// Accumulates the bytes that arrive from the pipe and returns one entry for every complete line.
/// A line that does not decode gives a `.failure` and does not stop the following ones. Empty lines are skipped.
///
/// A line over `maxLineBytes` gives `.failure(LineTooLong())` as soon as it passes the cap, and the
/// rest of it is thrown away as it arrives: a line that never ends cannot grow in memory.
public struct LineDecoder<T: Decodable> {
    /// The largest real line is `stemsReady` (6 stems with 600 peaks each), under 100 KB.
    public static var maxLineBytes: Int { 1 << 20 }

    private var lines = LineSplitter(maxLineBytes: maxLineBytes)
    private let decoder = JSONDecoder()

    public init() {}

    public mutating func feed(_ chunk: Data) -> [Result<T, Error>] {
        var results: [Result<T, Error>] = []
        for result in lines.feed(chunk) {
            switch result {
            case .failure(let tooLong):
                results.append(.failure(tooLong))
            case .success(let line):
                if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { continue }
                results.append(Result { try decoder.decode(T.self, from: line) })
            }
        }
        return results
    }
}
