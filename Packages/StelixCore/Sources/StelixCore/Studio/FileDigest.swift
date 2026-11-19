// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import CryptoKit
import Foundation

public enum FileDigest {
    /// Lowercase hexadecimal SHA-256, read in 1 MB blocks: a 700 MB checkpoint never goes
    /// through memory whole.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let done = try autoreleasepool {
                guard let block = try handle.read(upToCount: 1 << 20), !block.isEmpty else { return true }
                hasher.update(data: block)
                return false
            }
            if done { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
