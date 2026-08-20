//
//  DocumentStore.swift
//  Bitarf RI
//
//  Local files only. No account, no server, no cloud — the one-pager is explicit
//  about that, and it is also why there is nothing here to fail while offline.
//
//  Documents that stay in the app belong to `DocumentLibrary`. What is left here
//  is the traffic in and out of it: files the user opens from elsewhere, and
//  copies handed to the share sheet.
//

import Foundation

struct DocumentStore {

    // MARK: Import / export

    func read(from url: URL) throws -> BitarfDocument {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try BitarfDocument.decodedAny(from: data)
    }

    /// Write a share-ready copy into the temporary directory. Exports stay JSON
    /// even though the library is binary: a file that leaves the app should be
    /// openable by something other than this app.
    func writeExport(_ document: BitarfDocument) throws -> URL {
        let name = sanitised(document.title)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).\(BitarfDocument.fileExtension)")
        try document.encoded().write(to: url, options: .atomic)
        return url
    }

    func sanitised(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "未命名" : String(cleaned.prefix(60))
    }
}
