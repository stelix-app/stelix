// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Darwin

/// A handler that does nothing, instead of `SIG_IGN`, for signals handled with a
/// `DispatchSource`: the source receives them anyway, and after `exec` a handled signal goes back to
/// default in child processes, while an ignored one stays ignored (StelixEngine and the sidecar
/// answer SIGTERM that way from the very first instant).
///
/// It is a global function and not a closure written in `main.swift` or in a `@MainActor` class:
/// that would inherit MainActor isolation, and a signal arriving on another thread
/// would stop the process through the executor check.
public enum SignalCatch {
    public static func withoutAction(_ signal: Int32) {
        Darwin.signal(signal, noAction)
    }
}

private func noAction(_ signal: Int32) {}
