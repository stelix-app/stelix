// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.
import PackageDescription

let package = Package(
    name: "StelixCore",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "StelixCore", targets: ["StelixCore"])
    ],
    targets: [
        .target(name: "StelixCore"),
        .testTarget(name: "StelixCoreTests", dependencies: ["StelixCore"])
    ]
)
