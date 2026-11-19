// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

/// Real disk images with a tiny app inside, signed ad-hoc: the designated requirement of an
/// ad-hoc signature is its cdhash, so "the same signer" means exactly these bytes.
@Suite(.serialized) struct DiskImageCheckTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "DiskImageCheckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: tool, code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output])
        }
        return output
    }

    /// `<dir>/Fake.app`, signed ad-hoc. `extra` changes the bytes, so the cdhash changes too.
    private func makeApp(in dir: URL, version: String, extra: String = "", sign: Bool = true) throws -> URL {
        let app = dir.appending(path: "Fake.app")
        let contents = app.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.stelix-update-test", "CFBundleExecutable": "Fake",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": "1",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: contents.appending(path: "MacOS/Fake"))
        try Data("resource\(extra)".utf8).write(to: contents.appending(path: "Resources/file.txt"))
        if sign {
            try Self.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "com.example.stelix-update-test", app.path])
        }
        return app
    }

    private static func requirement(of app: URL) throws -> String {
        let output = try run("/usr/bin/codesign", ["-d", "-r-", app.path])
        // "# designated => cdhash H"…" or cdhash H"…"" for an ad-hoc signature.
        let line = try #require(output.split(separator: "\n").first { $0.contains("designated => ") })
        return String(try #require(line.split(separator: "designated => ", maxSplits: 1).last))
    }

    private func makeDMG(_ name: String, from source: URL) throws -> URL {
        let dmg = folder.appending(path: "\(name).dmg")
        try Self.run("/usr/bin/hdiutil", ["create", "-volname", name, "-srcfolder", source.path,
                                          "-format", "UDZO", "-ov", dmg.path])
        return dmg
    }

    private func staging(_ name: String) throws -> URL {
        let dir = folder.appending(path: name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func acceptsTheSameSignerAndVersion() async throws {
        let dir = try staging("good")
        let app = try makeApp(in: dir, version: "1.1")
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "Applications"),
                                                   withDestinationURL: URL(fileURLWithPath: "/Applications"))
        let check = DiskImageCheck(requirement: try Self.requirement(of: app))
        try await check.verify(try makeDMG("good", from: dir), version: AppVersion("1.1")!)
    }

    @Test func rejectsAnotherSigner() async throws {
        let mine = try makeApp(in: try staging("mine"), version: "1.1")
        let other = try staging("other")
        try makeApp(in: other, version: "1.1", extra: "!")
        let check = DiskImageCheck(requirement: try Self.requirement(of: mine))
        await #expect(throws: DiskImageCheckError.signature) {
            try await check.verify(try makeDMG("other", from: other), version: AppVersion("1.1")!)
        }
    }

    @Test func rejectsAnUnsignedApp() async throws {
        let mine = try makeApp(in: try staging("mine"), version: "1.1")
        let unsigned = try staging("unsigned")
        try makeApp(in: unsigned, version: "1.1", sign: false)
        let check = DiskImageCheck(requirement: try Self.requirement(of: mine))
        await #expect(throws: DiskImageCheckError.signature) {
            try await check.verify(try makeDMG("unsigned", from: unsigned), version: AppVersion("1.1")!)
        }
    }

    @Test func rejectsAnAppChangedAfterSigning() async throws {
        let dir = try staging("changed")
        let app = try makeApp(in: dir, version: "1.1")
        let check = DiskImageCheck(requirement: try Self.requirement(of: app))
        try Data("changed".utf8).write(to: app.appending(path: "Contents/Resources/file.txt"))
        await #expect(throws: DiskImageCheckError.signature) {
            try await check.verify(try makeDMG("changed", from: dir), version: AppVersion("1.1")!)
        }
    }

    @Test func rejectsAnotherVersion() async throws {
        let dir = try staging("old")
        let app = try makeApp(in: dir, version: "1.0")
        let check = DiskImageCheck(requirement: try Self.requirement(of: app))
        await #expect(throws: DiskImageCheckError.version) {
            try await check.verify(try makeDMG("old", from: dir), version: AppVersion("1.1")!)
        }
    }

    @Test func rejectsAnImageWithoutApp() async throws {
        let dir = try staging("empty")
        // An app link pointing at a genuine app elsewhere doesn't count: it isn't in the image.
        let elsewhere = try makeApp(in: try staging("elsewhere"), version: "1.1")
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "Stelix.app"), withDestinationURL: elsewhere)
        let check = DiskImageCheck(requirement: try Self.requirement(of: elsewhere))
        await #expect(throws: DiskImageCheckError.noApp) {
            try await check.verify(try makeDMG("empty", from: dir), version: AppVersion("1.1")!)
        }
    }

    @Test func rejectsAnythingBesideTheApp() async throws {
        let cases: [(String, (URL) throws -> Void)] = [
            ("script", { try Data("#!/bin/sh\n".utf8).write(to: $0.appending(path: "Install.command")) }),
            ("hidden", { try Data("x".utf8).write(to: $0.appending(path: ".payload")) }),
            ("link", { try FileManager.default.createSymbolicLink(
                at: $0.appending(path: "Applications"), withDestinationURL: URL(fileURLWithPath: "/tmp")) }),
            ("folder", { try FileManager.default.createDirectory(at: $0.appending(path: "Extras"),
                                                                 withIntermediateDirectories: true) }),
        ]
        // The rule on folders, then once through a real image.
        for (name, add) in cases {
            let dir = try staging("extra-\(name)")
            try makeApp(in: dir, version: "1.1")
            try add(dir)
            #expect(throws: DiskImageCheckError.unexpectedContent, "\(name)") { try DiskImageCheck.onlyApp(in: dir) }
        }
        let dir = folder.appending(path: "extra-script")
        let check = DiskImageCheck(requirement: try Self.requirement(of: dir.appending(path: "Fake.app")))
        await #expect(throws: DiskImageCheckError.unexpectedContent) {
            try await check.verify(try makeDMG("extra-script", from: dir), version: AppVersion("1.1")!)
        }
    }

    @Test func cosmeticFilesAreAllowed() throws {
        let dir = try staging("cosmetic")
        try makeApp(in: dir, version: "1.1")
        try Data().write(to: dir.appending(path: ".DS_Store"))
        try Data().write(to: dir.appending(path: ".VolumeIcon.icns"))
        try FileManager.default.createDirectory(at: dir.appending(path: ".background"), withIntermediateDirectories: true)
        try Data().write(to: dir.appending(path: ".background/back.png"))
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "Applications"),
                                                   withDestinationURL: URL(fileURLWithPath: "/Applications"))
        #expect(try DiskImageCheck.onlyApp(in: dir).lastPathComponent == "Fake.app")
        try Data("#!/bin/sh\n".utf8).write(to: dir.appending(path: ".background/run.sh"))
        chmod(dir.appending(path: ".background/run.sh").path, 0o755)
        #expect(throws: DiskImageCheckError.unexpectedContent) { try DiskImageCheck.onlyApp(in: dir) }
    }

    /// The volume folders hold plain files only: a program there would reach the user unchecked.
    @Test func volumeFoldersHoldPlainFilesOnly() throws {
        for name in [".fseventsd", ".Trashes"] {
            let dir = try staging("volume\(name)")
            try makeApp(in: dir, version: "1.1")
            let folder = dir.appending(path: name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appending(path: "fseventsd-uuid"))
            #expect(try DiskImageCheck.onlyApp(in: dir).lastPathComponent == "Fake.app", "\(name)")
            try FileManager.default.createDirectory(at: folder.appending(path: "Hidden.app"), withIntermediateDirectories: true)
            #expect(throws: DiskImageCheckError.unexpectedContent, "\(name)") { try DiskImageCheck.onlyApp(in: dir) }
        }
    }

    /// `hdiutil attach -plist` of an image (`system-entities`): one entry per device, `mount-point` on the
    /// mounted volumes, `potentially-mountable` on every volume, mounted or not.
    private static func attachOutput(_ volumes: [(mountable: Bool, mountPoint: String?)]) throws -> Data {
        var entities: [[String: Any]] = [
            ["dev-entry": "/dev/disk6", "content-hint": "GUID_partition_scheme", "potentially-mountable": false],
            ["dev-entry": "/dev/disk6s1", "content-hint": "Apple_APFS", "potentially-mountable": false],
            ["dev-entry": "/dev/disk7", "content-hint": "EF57347C-0000-11AA-AA11-00306543ECAC", "potentially-mountable": false],
        ]
        for (index, volume) in volumes.enumerated() {
            var entity: [String: Any] = ["dev-entry": "/dev/disk7s\(index + 1)", "potentially-mountable": volume.mountable,
                                         "volume-kind": "apfs"]
            entity["mount-point"] = volume.mountPoint
            entities.append(entity)
        }
        return try PropertyListSerialization.data(fromPropertyList: ["system-entities": entities], format: .xml, options: 0)
    }

    /// An image with a second volume: `hdiutil attach -mountpoint` mounts only the first and succeeds,
    /// but opening the DMG mounts both (tried on 2026-11-17 with an APFS image of volumes A and B).
    @Test func onlyOneVolumeMountedWhereAsked() throws {
        let mount = folder.appending(path: DiskImageCheck.mountPrefix + "1")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        #expect(mount.path.hasPrefix("/var/"))
        #expect(DiskImageCheck.onlyVolume(attachOutput: try Self.attachOutput([(true, mount.path)]), mount: mount))
        // The temporary folder is reached through the /var link, and hdiutil answers with /private/var.
        #expect(DiskImageCheck.onlyVolume(attachOutput: try Self.attachOutput([(true, "/private" + mount.path)]), mount: mount))
        #expect(!DiskImageCheck.onlyVolume(attachOutput: try Self.attachOutput([(true, mount.path), (true, nil)]), mount: mount))
        #expect(!DiskImageCheck.onlyVolume(attachOutput: try Self.attachOutput([(true, mount.path), (true, "/Volumes/B")]),
                                           mount: mount))
        #expect(!DiskImageCheck.onlyVolume(attachOutput: try Self.attachOutput([(true, "/Volumes/A")]), mount: mount))
        #expect(!DiskImageCheck.onlyVolume(attachOutput: try Self.attachOutput([]), mount: mount))
        #expect(!DiskImageCheck.onlyVolume(attachOutput: Data("not a plist".utf8), mount: mount))
    }

    @Test func rejectsWhatIsNotADiskImage() async throws {
        let file = folder.appending(path: "fake.dmg")
        try Data("not a disk image".utf8).write(to: file)
        let check = DiskImageCheck(requirement: "anchor apple")
        await #expect(throws: DiskImageCheckError.mount) {
            try await check.verify(file, version: AppVersion("1.1")!)
        }
    }

    @Test func leavesNothingMounted() async throws {
        let dir = try staging("mounts")
        let app = try makeApp(in: dir, version: "1.1")
        let check = DiskImageCheck(requirement: try Self.requirement(of: app))
        try await check.verify(try makeDMG("mounts", from: dir), version: AppVersion("1.1")!)
        let info = try Self.run("/usr/bin/hdiutil", ["info"])
        #expect(!info.contains(folder.lastPathComponent))
        #expect(!info.contains(DiskImageCheck.mountPrefix))
    }
}
