// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import StelixCore

// StelixEngine: reads Command from stdin, one JSON line per command, and writes Event to stdout.
// Exits at EOF on stdin (Stelix closed or dead), at .shutdown and at SIGTERM.

signal(SIGPIPE, SIG_IGN)
// A handler that does nothing, not SIG_IGN: the sidecar starts with SIGTERM at default.
SignalCatch.withoutAction(SIGTERM)

let host = EngineHost()
let sigterm = host.installSigterm()

Thread.detachNewThread { [host] in
    var decoder = LineDecoder<Command>()
    while true {
        let data = FileHandle.standardInput.availableData
        if data.isEmpty { break }
        for result in decoder.feed(data) {
            switch result {
            case .success(let command): host.handle(command)
            case .failure: host.reportBadLine()
            }
        }
    }
    host.exitOnce(endOfInput: true)
}

host.emit(.ready)
dispatchMain()
