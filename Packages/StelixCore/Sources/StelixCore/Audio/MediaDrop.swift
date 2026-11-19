// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import UniformTypeIdentifiers

/// Which files the Studio drop accepts: audio and video yes; known types that are neither (PDF,
/// images, folders, text) no, and the border does not light up. An unknown type (an MP3 without an
/// extension, or with a dot in the name) passes: `AudioFileLoader` decides, with a clear error.
public enum MediaDrop {
    public static func accepts(_ type: UTType?) -> Bool {
        guard let type else { return true }
        if type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return true }
        if type.conforms(to: .directory) || type.conforms(to: .folder) { return false }
        // A dynamic type is an extension the system does not know; `public.data` is what the
        // file system gives a file without a recognized extension.
        return type.isDynamic || [UTType.data, .item, .content].contains(type)
    }

    /// The type from the content declared by the file system, otherwise from the extension.
    public static func accepts(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
        if values?.isDirectory == true { return false }
        let type = values?.contentType ?? (url.pathExtension.isEmpty ? nil : UTType(filenameExtension: url.pathExtension))
        return accepts(type)
    }
}
