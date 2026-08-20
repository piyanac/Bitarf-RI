//
//  DocumentLibrary.swift
//  Bitarf RI
//
//  Where documents live once they are worth keeping.
//
//  Nothing lands here just because the user opened the app and typed. A file is
//  written at the two moments the user actually commits to something: printing
//  it, or saving it as a template to print again. Everything else is scratch,
//  and scratch is allowed to evaporate.
//
//  The list is backed by a small index rather than by reading the documents
//  themselves — a document carries its images inlined, and browsing a hundred of
//  them must not mean decoding a hundred PNGs.
//

import Foundation
import UIKit

// MARK: - Model

enum LibraryKind: String, Codable, Hashable, CaseIterable {
    /// Written automatically when the document was sent to a printer.
    case history
    /// Kept deliberately by the user, to print again later.
    case template
    /// Work that was interrupted — the app died before the user committed to
    /// anything. Offered back once, then it is theirs to keep or throw away.
    case recovered
}

struct LibraryEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var kind: LibraryKind
    var title: String
    var createdAt: Date
    var updatedAt: Date
    /// Every time this document went to the paper. A document is one file with
    /// many print dates, not one file per print: "print that thing again" is the
    /// request, never "go back to the version from three weeks ago".
    var printedDates: [Date]
    /// Physical length as it was when written, e.g. "12.4 cm".
    var lengthDescription: String
    var objectCount: Int

    var lastPrintedAt: Date? { printedDates.last }

    /// What the list sorts on: the last thing that happened to this document,
    /// whichever kind of thing it was.
    var lastActivity: Date { max(updatedAt, lastPrintedAt ?? .distantPast) }
}

// MARK: - Store

/// Everything on disk. Deliberately not an `ObservableObject`: the browser reads
/// a snapshot when it appears, and the editor writes at the few commit points.
struct DocumentLibrary {

    // MARK: Layout

    private var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Bitarf RI", isDirectory: true)
    }

    private var documentsDirectory: URL { root.appendingPathComponent("Documents", isDirectory: true) }
    private var thumbnailsDirectory: URL { root.appendingPathComponent("Thumbnails", isDirectory: true) }
    private var indexURL: URL { root.appendingPathComponent("index.json") }

    /// The one document currently being edited. Rewritten on every autosave and
    /// never listed anywhere.
    private var scratchURL: URL { root.appendingPathComponent("scratch.\(BitarfDocument.fileExtension)") }
    private var scratchStateURL: URL { root.appendingPathComponent("scratch-state.json") }

    /// Pre-library autosave slot. Read once, then moved into scratch.
    private var legacyAutosaveURL: URL { root.appendingPathComponent("current.\(BitarfDocument.fileExtension)") }

    private func documentURL(_ id: UUID) -> URL {
        documentsDirectory.appendingPathComponent("\(id.uuidString).\(BitarfDocument.fileExtension)")
    }

    func thumbnailURL(_ id: UUID) -> URL {
        thumbnailsDirectory.appendingPathComponent("\(id.uuidString).png")
    }

    private func prepareDirectories() {
        for directory in [root, documentsDirectory, thumbnailsDirectory] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    // MARK: Index

    /// The whole list, newest activity first. A missing or corrupt index is an
    /// empty library rather than a crash; the documents themselves survive and
    /// nothing here is the user's only copy of anything.
    func entries() -> [LibraryEntry] {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([LibraryEntry].self, from: data) else { return [] }
        return decoded.sorted { $0.lastActivity > $1.lastActivity }
    }

    func entries(of kind: LibraryKind) -> [LibraryEntry] {
        entries().filter { $0.kind == kind }
    }

    private func writeIndex(_ entries: [LibraryEntry]) {
        prepareDirectories()
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func upsert(_ entry: LibraryEntry) {
        var all = entries()
        all.removeAll { $0.id == entry.id }
        all.append(entry)
        writeIndex(all)
    }

    // MARK: Reading

    func document(for id: UUID) -> BitarfDocument? {
        guard let data = try? Data(contentsOf: documentURL(id)) else { return nil }
        return try? BitarfDocument.decodedAny(from: data)
    }

    // MARK: Writing

    /// Store `document` under `id`, creating or updating its index entry.
    @discardableResult
    private func write(
        _ document: BitarfDocument,
        id: UUID,
        kind: LibraryKind,
        printedAt: Date?,
        now: Date
    ) throws -> LibraryEntry {
        prepareDirectories()
        try document.encodedCompact().write(to: documentURL(id), options: .atomic)
        writeThumbnail(for: document, id: id)

        let existing = entries().first { $0.id == id }
        var printedDates = existing?.printedDates ?? []
        if let printedAt { printedDates.append(printedAt) }

        let entry = LibraryEntry(
            id: id,
            kind: kind,
            title: document.title,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            printedDates: printedDates,
            lengthDescription: document.physicalLengthDescription,
            objectCount: document.objects.count
        )
        upsert(entry)
        return entry
    }

    /// Record a print. Always a new entry: the history is a log of things that
    /// came out of the printer, so reprinting an edited document is a second
    /// event, not an amendment to the first.
    @discardableResult
    func recordPrint(_ document: BitarfDocument, at date: Date = Date()) throws -> LibraryEntry {
        try write(document, id: UUID(), kind: .history, printedAt: date, now: date)
    }

    @discardableResult
    func saveTemplate(_ document: BitarfDocument, id: UUID = UUID(), now: Date = Date()) throws -> LibraryEntry {
        try write(document, id: id, kind: .template, printedAt: nil, now: now)
    }

    /// File unfinished work. Passing the id of a row this content already
    /// occupies updates that row rather than adding a near-identical one.
    @discardableResult
    func saveRecovered(_ document: BitarfDocument, id: UUID = UUID(), now: Date = Date()) throws -> LibraryEntry {
        try write(document, id: id, kind: .recovered, printedAt: nil, now: now)
    }

    /// Copy a stored document into a brand-new row of the same kind.
    ///
    /// The copy is a separate document from the first moment: a new id, a new
    /// file, its own thumbnail. Print dates are deliberately not carried over —
    /// the copy has never been printed, whatever its original did.
    @discardableResult
    func duplicate(_ id: UUID, now: Date = Date()) -> LibraryEntry? {
        guard let entry = entries().first(where: { $0.id == id }),
              var document = document(for: id) else { return nil }
        document.title = Self.copyTitle(of: entry.title)
        return try? write(document, id: UUID(), kind: entry.kind, printedAt: nil, now: now)
    }

    /// 「講義」→「講義 副本」→「講義 副本 2」: the second copy numbers itself
    /// rather than growing another 「副本」 on the end.
    static func copyTitle(of title: String) -> String {
        let suffix = " 副本"
        if title.hasSuffix(suffix) { return title + " 2" }
        if let range = title.range(of: suffix + " ", options: .backwards),
           range.upperBound < title.endIndex,
           let number = Int(title[range.upperBound...]) {
            return title[..<range.lowerBound] + suffix + " \(number + 1)"
        }
        return title + suffix
    }

    func rename(_ id: UUID, to title: String) {
        guard var document = document(for: id) else { return }
        document.title = title
        var all = entries()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        try? document.encodedCompact().write(to: documentURL(id), options: .atomic)
        all[index].title = title
        all[index].updatedAt = Date()
        writeIndex(all)
    }

    func delete(_ id: UUID) {
        delete([id])
    }

    /// Delete many at once. One index rewrite rather than one per document —
    /// clearing a few hundred rows should not mean a few hundred writes of the
    /// same file, and a crash halfway through would otherwise leave the index
    /// listing documents whose files are already gone.
    func delete<IDs: Sequence>(_ ids: IDs) where IDs.Element == UUID {
        let doomed = Set(ids)
        guard !doomed.isEmpty else { return }
        for id in doomed {
            try? FileManager.default.removeItem(at: documentURL(id))
            try? FileManager.default.removeItem(at: thumbnailURL(id))
        }
        var all = entries()
        all.removeAll { doomed.contains($0.id) }
        writeIndex(all)
    }

    /// Delete every entry of `kind` the predicate accepts, and say how many went.
    @discardableResult
    func delete(kind: LibraryKind, where matches: (LibraryEntry) -> Bool) -> Int {
        let doomed = entries().filter { $0.kind == kind && matches($0) }.map(\.id)
        delete(doomed)
        return doomed.count
    }

    // MARK: Thumbnails

    /// Widest a thumbnail gets, in pixels.
    private static let thumbnailWidth: CGFloat = 240
    /// A two-metre strip shrunk to fit would be an illegible grey smear, so the
    /// thumbnail is the top of the paper at a readable scale instead — which is
    /// also the part the user recognises the document by.
    private static let thumbnailMaxHeight: CGFloat = 320

    private func writeThumbnail(for document: BitarfDocument, id: UUID) {
        guard let image = Self.thumbnail(for: document), let data = image.pngData() else { return }
        try? data.write(to: thumbnailURL(id), options: .atomic)
    }

    static func thumbnail(for document: BitarfDocument) -> UIImage? {
        let source = document.reflowed
        let size = source.canvasSize
        guard size.width >= 1, size.height >= 1, size.width.isFinite, size.height.isFinite else { return nil }

        let scale = min(1, thumbnailWidth / size.width)
        guard let full = ExportService.previewImage(document: source, scale: scale) else { return nil }
        guard full.size.height * full.scale > thumbnailMaxHeight else { return full }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let cropped = CGSize(width: full.size.width * full.scale, height: thumbnailMaxHeight)
        return UIGraphicsImageRenderer(size: cropped, format: format).image { _ in
            full.draw(in: CGRect(origin: .zero, size: CGSize(
                width: cropped.width,
                height: full.size.height * full.scale
            )))
        }
    }

    // MARK: Scratch

    struct ScratchState: Codable {
        /// True once the content has been printed or saved, so an interrupted
        /// launch knows there is nothing left to rescue.
        var isCommitted: Bool
        /// Whether the user ever changed anything. An untouched blank canvas is
        /// not work, and must never come back as a row in a list.
        var hasBeenEdited: Bool
        /// The template this content was opened from, if any — the only reason
        /// the editor can offer 「更新範本」.
        var sourceTemplateID: UUID?
        /// The 最近 row this content already occupies, so filing it again
        /// updates that row instead of adding another.
        var recoveredID: UUID?
        /// Launches in a row that have found this scratch unclean. See
        /// `EditorState.uncleanLaunches`.
        var uncleanLaunches: Int
        /// Set by the migration so the first launch after upgrading resumes the
        /// old autosave instead of dropping the user on a blank canvas.
        var resumesOnNextLaunch: Bool

        init(
            isCommitted: Bool = false,
            hasBeenEdited: Bool = false,
            sourceTemplateID: UUID? = nil,
            recoveredID: UUID? = nil,
            uncleanLaunches: Int = 0,
            resumesOnNextLaunch: Bool = false
        ) {
            self.isCommitted = isCommitted
            self.hasBeenEdited = hasBeenEdited
            self.sourceTemplateID = sourceTemplateID
            self.recoveredID = recoveredID
            self.uncleanLaunches = uncleanLaunches
            self.resumesOnNextLaunch = resumesOnNextLaunch
        }

        /// Hand-written so that a state file from an older build still decodes.
        /// The synthesised version throws on the first key it does not find, and
        /// an unreadable state file reads as "nothing was in progress" — which
        /// would drop the one document the upgrading user had open.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isCommitted = try container.decodeIfPresent(Bool.self, forKey: .isCommitted) ?? false
            hasBeenEdited = try container.decodeIfPresent(Bool.self, forKey: .hasBeenEdited) ?? false
            sourceTemplateID = try container.decodeIfPresent(UUID.self, forKey: .sourceTemplateID)
            recoveredID = try container.decodeIfPresent(UUID.self, forKey: .recoveredID)
            uncleanLaunches = try container.decodeIfPresent(Int.self, forKey: .uncleanLaunches) ?? 0
            resumesOnNextLaunch = try container.decodeIfPresent(Bool.self, forKey: .resumesOnNextLaunch) ?? false
        }
    }

    func scratchDocument() -> BitarfDocument? {
        guard let data = try? Data(contentsOf: scratchURL) else { return nil }
        return try? BitarfDocument.decodedAny(from: data)
    }

    func scratchState() -> ScratchState {
        guard let data = try? Data(contentsOf: scratchStateURL),
              let state = try? JSONDecoder().decode(ScratchState.self, from: data) else { return ScratchState() }
        return state
    }

    func writeScratch(_ document: BitarfDocument, state: ScratchState) throws {
        prepareDirectories()
        try document.encodedCompact().write(to: scratchURL, options: .atomic)
        try JSONEncoder().encode(state).write(to: scratchStateURL, options: .atomic)
    }

    func clearScratch() {
        try? FileManager.default.removeItem(at: scratchURL)
        try? FileManager.default.removeItem(at: scratchStateURL)
    }

    // MARK: Migration

    /// Move the pre-library autosave into the scratch slot, once.
    ///
    /// It is not filed as history (it was never printed) and not as a template
    /// (the user never asked to keep it). It is simply what they had open, so it
    /// goes back where they left it and the next launch hands it straight back.
    func migrateLegacyAutosaveIfNeeded() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacyAutosaveURL.path) else { return }
        defer { try? fileManager.removeItem(at: legacyAutosaveURL) }

        guard let data = try? Data(contentsOf: legacyAutosaveURL),
              let document = try? BitarfDocument.decodedAny(from: data) else { return }
        try? writeScratch(document, state: ScratchState(hasBeenEdited: true, resumesOnNextLaunch: true))
    }
}
