// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Security

/// Checks a downloaded update before the user opens it.
public protocol DiskImageVerifying: Sendable {
    /// Throws `DiskImageCheckError` unless the image holds one app signed like this one, at `version`.
    func verify(_ dmg: URL, version: AppVersion) async throws
}

public enum DiskImageCheckError: Error, Equatable, Sendable {
    /// `hdiutil` can't attach it: not a disk image, or a damaged one.
    case mount
    /// Not exactly one app at the top of the image (links don't count).
    case noApp
    /// Something besides the app, the Applications link and Finder's cosmetic files, or a second
    /// volume: a script or a second program would reach the user unchecked, since the image carries
    /// no quarantine.
    case unexpectedContent
    /// The app isn't signed by the same certificate with the same bundle ID, or was changed after.
    case signature
    /// The app is signed right but its version isn't the release's.
    case version
}

/// A DMG that Stelix downloads itself carries no quarantine, so Gatekeeper never looks at it: this
/// check stands in for it, as Sparkle's does. The image is attached read-only and hidden from
/// Finder, it may hold one volume with nothing but the app, a link to /Applications and Finder's
/// cosmetic files, its only app must satisfy the designated requirement of the running Stelix (with a stable
/// certificate: that certificate and the bundle ID), every architecture and nested code included,
/// and its version must be the one the release announced. Then the image is detached.
public struct DiskImageCheck: DiskImageVerifying {
    static let mountPrefix = "StelixUpdateCheck-"

    /// A code-signing requirement in text form, e.g.
    /// `identifier "io.github.stelix-app.stelix" and certificate leaf = H"…"`.
    public let requirement: String

    public init(requirement: String) {
        self.requirement = requirement
    }

    /// The designated requirement of the running app, or nil if it has none (an unsigned build):
    /// then no update can be verified.
    public static func runningApp() -> DiskImageCheck? {
        var me: SecCode?
        var onDisk: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &onDisk) == errSecSuccess, let onDisk,
              SecCodeCopyDesignatedRequirement(onDisk, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text
        else { return nil }
        return DiskImageCheck(requirement: text as String)
    }

    public func verify(_ dmg: URL, version: AppVersion) async throws {
        let requirement = requirement
        // hdiutil and the signature check of a few hundred MB block for seconds: not on an actor.
        try await Task.detached(priority: .utility) {
            try Self.check(dmg, version: version, requirement: requirement)
        }.value
    }

    private static func check(_ dmg: URL, version: AppVersion, requirement: String) throws {
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appending(path: mountPrefix + UUID().uuidString)
        do {
            try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        } catch {
            throw DiskImageCheckError.mount
        }
        guard let attached = hdiutil(["attach", "-plist", "-nobrowse", "-readonly", "-noautoopen",
                                      "-mountpoint", mount.path, dmg.path]) else {
            try? fm.removeItem(at: mount)
            throw DiskImageCheckError.mount
        }
        // Detaching the volume detaches the whole image, with any other volume it holds.
        defer {
            if hdiutil(["detach", mount.path]) == nil { _ = hdiutil(["detach", "-force", mount.path]) }
            try? fm.removeItem(at: mount)
        }

        guard onlyVolume(attachOutput: attached, mount: mount) else { throw DiskImageCheckError.unexpectedContent }
        let app = try onlyApp(in: mount)

        var code: SecStaticCode?
        var required: SecRequirement?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &required) == errSecSuccess, let required,
              SecStaticCodeCheckValidity(code, flags, required) == errSecSuccess
        else { throw DiskImageCheckError.signature }

        // Read only after the signature: Info.plist is sealed by it.
        let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))
        guard let text = info?["CFBundleShortVersionString"] as? String, AppVersion(text) == version else {
            throw DiskImageCheckError.version
        }
    }

    /// From `hdiutil attach -plist`: the image holds one volume, mounted at `mount`. With `-mountpoint`
    /// hdiutil mounts only the first volume and still succeeds, but opening the DMG mounts them all:
    /// a second one, never looked at here, could hold an unsigned app (tried on 2026-11-17).
    static func onlyVolume(attachOutput: Data, mount: URL) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(from: attachOutput, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else { return false }
        let volumes = entities.filter { ($0["potentially-mountable"] as? Bool) == true || $0["mount-point"] != nil }
        guard volumes.count == 1, let point = volumes[0]["mount-point"] as? String else { return false }
        return resolved(point) == resolved(mount.path)
    }

    /// `/var/folders/…` and `/private/var/folders/…` are the same folder: hdiutil answers with the second.
    private static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    /// The one app at the top of the image. Besides it only a link named Applications to
    /// /Applications, `.DS_Store`, `.VolumeIcon.icns`, and `.background`, `.fseventsd` and `.Trashes`
    /// folders of plain, non-executable files. Hidden files are looked at too.
    static func onlyApp(in mount: URL) throws -> URL {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        guard let entries = try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: Array(keys)) else {
            throw DiskImageCheckError.noApp
        }
        var apps: [URL] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: keys)
            let name = entry.lastPathComponent
            let link = values?.isSymbolicLink == true
            let directory = values?.isDirectory == true && !link
            let file = values?.isRegularFile == true && !link
            if directory, entry.pathExtension.lowercased() == "app" {
                apps.append(entry)
            } else if link, name == "Applications",
                      (try? fm.destinationOfSymbolicLink(atPath: entry.path)) == "/Applications" {
                continue
            } else if file, name == ".DS_Store" || name == ".VolumeIcon.icns" {
                continue
            } else if directory, name == ".fseventsd" || name == ".Trashes", onlyPlainFiles(in: entry) {
                continue
            } else if directory, name == ".background", onlyPlainFiles(in: entry) {
                continue
            } else if link, entry.pathExtension.lowercased() == "app" {
                // An app link pointing elsewhere: not in the image, so not an app of it.
                throw DiskImageCheckError.noApp
            } else {
                throw DiskImageCheckError.unexpectedContent
            }
        }
        guard apps.count == 1, let app = apps.first else { throw DiskImageCheckError.noApp }
        return app
    }

    private static func onlyPlainFiles(in folder: URL) -> Bool {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)
        else { return false }
        return entries.allSatisfy { entry in
            let values = try? entry.resourceValues(forKeys: Set(keys))
            let executable = FileManager.default.isExecutableFile(atPath: entry.path)
            return values?.isRegularFile == true && values?.isSymbolicLink != true && !executable
        }
    }

    /// Runs hdiutil without input (an image with a license agreement would wait for an answer:
    /// with no input it fails instead). Its output if it succeeded, nil if not.
    private static func hdiutil(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before waiting: a full pipe would block hdiutil.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
