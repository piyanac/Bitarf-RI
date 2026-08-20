//
//  DocumentBrowserView.swift
//  Bitarf RI
//
//  The top level: four tabs rather than one scrolling list. 最近, 範本 and
//  列印歷史 are filled by three different things — the user leaving, the user
//  saving, the printer printing — so the tab a document sits in already tells
//  you how it got there. 設定 is not a tab: it is a sheet off the leading end of
//  the toolbar, because it is somewhere you go, do one thing and come back from
//  — not a fourth place documents could be.
//
//  Creating a document is the one thing this screen exists to lead to, so it is
//  a filled button under the list rather than a glyph in the toolbar.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DocumentBrowserView: View {

    /// A one-off message from the launch path, e.g. work rescued after a crash.
    @Binding var notice: String?

    /// Bumped by the shell whenever the library may have changed behind this
    /// view's back. `onAppear` does not fire again when a `NavigationStack` pops
    /// back to its root, so returning from the editor needs its own signal.
    let reloadToken: Int

    /// The shell's namespace for the zoom transition, so a row can hand the
    /// editor the thing it should grow out of.
    let zoomNamespace: Namespace.ID

    /// Open a document in the editor, along with the library row it came out of
    /// — which decides whether 「更新範本」 is available, which row the work goes
    /// back to on the way out, and what the zoom transition grows from.
    let open: (BitarfDocument, LibraryEntry?) -> Void
    /// Start a blank document.
    let openNew: () -> Void
    /// Open a `.bitarf` file that lives outside the library.
    let openFile: (URL) -> Void

    private enum TabSelection: Hashable { case recent, templates, history, new }

    @State private var tab: TabSelection = .recent
    @State private var entries: [LibraryEntry] = []
    @State private var renaming: LibraryEntry?
    @State private var renameText = ""
    @State private var isImportingFile = false
    @State private var isShowingSettings = false

    /// Which tab is currently picking rows, if any. One tab at a time: the
    /// selection is a list of rows in front of the user, and it stops meaning
    /// anything the moment a different list is on screen.
    @State private var editingKind: LibraryKind?
    @State private var selection: Set<UUID> = []
    @State private var shareSelection: ShareItems?
    @State private var isConfirmingBatchDelete = false
    @State private var isConfirmingClearRecent = false
    @State private var pendingClear: ClearScope?
    @State private var exportError: String?

    /// How each library tab draws its rows. Kept per tab rather than app-wide:
    /// 範本 is a wall of pictures the user recognises by sight, 列印歷史 is a
    /// log read by date, and one setting for both would always be wrong for one
    /// of them.
    @AppStorage("libraryLayout.recovered") private var recentLayout = LibraryLayout.list
    @AppStorage("libraryLayout.template") private var templateLayout = LibraryLayout.list
    @AppStorage("libraryLayout.history") private var historyLayout = LibraryLayout.list

    private let library = DocumentLibrary()

    var body: some View {
        TabView(selection: $tab) {
            Tab(value: TabSelection.recent) {
                NavigationStack {
                    libraryTab(.recovered, empty: "沒有編輯中的文件")
                    .navigationTitle("最近")
                }
            } label: {
                tabLabel("最近", "clock", for: .recent)
            }

            Tab(value: TabSelection.templates) {
                NavigationStack {
                    libraryTab(.template, empty: "沒有範本")
                    .navigationTitle("範本")
                }
            } label: {
                tabLabel("範本", "doc.on.doc", for: .templates)
            }

            Tab(value: TabSelection.history) {
                NavigationStack {
                    libraryTab(.history, empty: "沒有已列印的文件")
                    .navigationTitle("列印歷史")
                }
            } label: {
                tabLabel("列印歷史", "printer.dotmatrix", for: .history)
            }

            // The search role is what puts a tab in the detached slot at the
            // trailing end of the bar — the shape this action wants. It is
            // borrowed, not meant: nothing here searches, so the tab never
            // actually becomes the selection (see `onChange`), and the label is
            // spelled out for VoiceOver, which would otherwise announce it by
            // its role.
            Tab(value: TabSelection.new, role: .search) {
                Color.clear
            } label: {
                tabLabel("新增文件", "square.and.pencil")
            }
            .accessibilityLabel("新增文件")
        }
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [.bitarfDocument, .json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                openFile(url)
            }
        }
        .alert("重新命名", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("名稱", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("好") {
                if let renaming {
                    library.rename(renaming.id, to: renameText)
                }
                renaming = nil
                reload()
            }
        }
        .sheet(item: $shareSelection) { item in
            ActivityView(items: item.urls)
        }
        // Settings comes back to exactly the tab it was opened from, which is
        // the whole reason it stopped being a tab of its own.
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack {
                SettingsTab()
                    .navigationTitle("設定")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            // `role: .confirm` is the system's own 完成: it draws
                            // the checkmark and the emphasis without us naming
                            // either, so it matches every other sheet's corner.
                            Button(role: .confirm) { isShowingSettings = false }
                        }
                    }
            }
        }
        .alert("輸出失敗", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("好") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        // Clearing by age is a menu of one-tap deletions, so the confirmation is
        // an alert rather than a sheet morphing out of the trash: the thing to
        // read is how much is about to go, not which button it came from.
        .alert(
            pendingClear?.confirmationTitle ?? "",
            isPresented: Binding(
                get: { pendingClear != nil },
                set: { if !$0 { pendingClear = nil } }
            ),
            presenting: pendingClear
        ) { scope in
            Button("刪除", role: .destructive) { performClear(scope) }
            Button("取消", role: .cancel) {}
        } message: { scope in
            Text(clearMessage(scope))
        }
        .onAppear(perform: reload)
        .onChange(of: reloadToken) { _, _ in reload() }
        .onChange(of: tab) { previous, current in
            endEditing()
            // A button wearing a tab's clothes: bounce the selection back before
            // the empty content behind it can show, then do the thing.
            guard current == .new else { return }
            tab = previous == .new ? .recent : previous
            openNew()
        }
    }

    /// A tab's label: the filled variant while the tab is the selection, the
    /// outline one otherwise, drawn a little smaller than the system default.
    ///
    /// The size has to be baked in, and a symbol image is not enough on its own
    /// — the tab bar re-applies its own symbol configuration and the point size
    /// asked for here is thrown away. Drawing the symbol into a plain bitmap
    /// first leaves nothing left to re-configure, so the size sticks.
    private func tabLabel(_ title: String, _ symbol: String, for value: TabSelection? = nil) -> some View {
        // The three library tabs stay filled whether or not they are selected;
        // only the detached 新增 tab (which passes no value) keeps the outline.
        let name = value != nil ? symbol + ".fill" : symbol
        let glyph = tabGlyph(name) ?? tabGlyph(symbol)
        return Label {
            Text(title)
        } icon: {
            if let glyph {
                Image(uiImage: glyph)
            } else {
                Image(systemName: symbol)
            }
        }
    }

    private func tabGlyph(_ symbol: String) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        guard let symbolImage = UIImage(systemName: symbol, withConfiguration: configuration) else {
            return nil
        }
        let size = symbolImage.size
        let flattened = UIGraphicsImageRenderer(size: size).image { _ in
            symbolImage.draw(in: CGRect(origin: .zero, size: size))
        }
        return flattened.withRenderingMode(.alwaysTemplate)
    }

    /// Bringing a `.bitarf` file in from elsewhere — AirDrop, Files, a mail
    /// attachment. It sits second from the left of every library tab's trailing
    /// group because the answer to 「我這個檔案要怎麼打開」 belongs next to the
    /// list of documents the app already has, not inside 設定 — and it keeps the
    /// same seat on every tab so it never has to be hunted for.
    /// 設定 used to be a tab, which put app-wide preferences on the same shelf as
    /// the three lists of documents. It is a sheet now: the same glyph and the
    /// same word, but somewhere you come back from.
    @ToolbarContentBuilder
    private var settingsButton: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                isShowingSettings = true
            } label: {
                Label("設定", systemImage: "gearshape")
            }
        }
    }

    @ToolbarContentBuilder
    private var importButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isImportingFile = true
            } label: {
                Label("輸入檔案", systemImage: "arrow.down.document")
            }
        }
    }

    // MARK: - Selection and clearing

    /// The trailing side of a library tab's navigation bar, plus the bottom bar
    /// that only exists while rows are being picked.
    ///
    /// Out of edit mode the two glyphs read left to right as「挑幾個」then
    /// 「整批丟掉」. In edit mode both are gone: the only thing left to say at
    /// the top is that the picking is over, and everything that acts on the
    /// picked rows sits at the bottom, next to the thumb doing the picking.
    @ToolbarContentBuilder
    private func libraryToolbar(_ kind: LibraryKind, rows: [LibraryEntry]) -> some ToolbarContent {
        if editingKind == kind {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成", systemImage: "checkmark") { endEditing() }
                    .fontWeight(.semibold)
            }

            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()

                Menu {
                    ForEach(LibraryExportKind.allCases) { format in
                        Button(format.title) { exportSelection(format) }
                    }
                } label: {
                    Label("輸出", systemImage: "square.and.arrow.up")
                }
                .disabled(selection.isEmpty)

                Button(role: .destructive) {
                    isConfirmingBatchDelete = true
                } label: {
                    Label("刪除", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
                // Anchored on the button so the sheet grows out of the trash the
                // user just tapped, rather than appearing from the bottom of the
                // screen with nothing to connect it to.
                .confirmationDialog(
                    "永久刪除 \(selection.count) 個項目？",
                    isPresented: $isConfirmingBatchDelete,
                    titleVisibility: .visible
                ) {
                    Button("刪除 \(selection.count) 個項目", role: .destructive) { deleteSelection() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text(kind == .template
                         ? "這將無法還原。"
                         : "這將無法還原。")
                }
            }
        } else {
            settingsButton

            // The glyph is the layout currently on screen, and a tap swaps it —
            // the button reads as a state, not as a destination. The spoken
            // label still names the action, which is what VoiceOver needs.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.snappy) { setLayout(layout(kind).toggled, for: kind) }
                } label: {
                    let current = layout(kind)
                    Label(current.toggled.actionTitle, systemImage: current.symbol)
                        .contentTransition(.symbolEffect(.replace))
                }
                .disabled(rows.isEmpty)
            }

            importButton

            // 最近 is a holding pen the user is meant to empty one row at a
            // time by opening things, so it keeps the plain list.
            if kind != .recovered {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        beginEditing(kind)
                    } label: {
                        Label("選取", systemImage: "checkmark.circle")
                    }
                    .disabled(rows.isEmpty)
                }
            }

            // 最近 has one thing worth doing to it in bulk — emptying it — so it
            // gets the action itself rather than a menu holding one item.
            if kind == .recovered {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        isConfirmingClearRecent = true
                    } label: {
                        Label("清除", systemImage: "trash")
                    }
                    .disabled(rows.isEmpty)
                    .confirmationDialog(
                        "清除全部編輯中的內容？",
                        isPresented: $isConfirmingClearRecent,
                        titleVisibility: .visible
                    ) {
                        Button("清除全部", role: .destructive) {
                            library.delete(kind: .recovered) { _ in true }
                            reload()
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("\(rows.count) 筆內容會永久刪除，無法還原。")
                    }
                }
            }

            if kind == .history {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) { pendingClear = .lastHour } label: {
                            Label(ClearScope.lastHour.title, systemImage: "clock")
                        }
                        Section {
                            Button(role: .destructive) { pendingClear = .olderThanSixMonths } label: {
                                Label(ClearScope.olderThanSixMonths.title, systemImage: "calendar")
                            }
                            Button(role: .destructive) { pendingClear = .all } label: {
                                Label(ClearScope.all.title, systemImage: "trash")
                            }
                        }
                    } label: {
                        Label("清除", systemImage: "trash")
                    }
                    .disabled(rows.isEmpty)
                }
            }
        }
    }

    /// Which slice of the history a 清除 command takes.
    private enum ClearScope: String, Identifiable, CaseIterable {
        /// Just printed something wrong, or something private — the reason the
        /// menu exists at all.
        case lastHour
        /// The long tail nobody will reprint.
        case olderThanSixMonths
        case all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .lastHour: return "一小時內"
            case .olderThanSixMonths: return "6 個月前"
            case .all: return "全部"
            }
        }

        var confirmationTitle: String {
            switch self {
            case .lastHour: return "清除一小時內的列印紀錄？"
            case .olderThanSixMonths: return "清除 6 個月前的列印紀錄？"
            case .all: return "清除全部列印紀錄？"
            }
        }

        /// Entries are matched on their last activity, which for a history row is
        /// when it came out of the printer.
        func matches(_ entry: LibraryEntry, now: Date) -> Bool {
            switch self {
            case .lastHour:
                return entry.lastActivity >= now.addingTimeInterval(-3600)
            case .olderThanSixMonths:
                let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: now) ?? now
                return entry.lastActivity < cutoff
            case .all:
                return true
            }
        }
    }

    private func clearCount(_ scope: ClearScope) -> Int {
        let now = Date()
        return entries.filter { $0.kind == .history && scope.matches($0, now: now) }.count
    }

    private func clearMessage(_ scope: ClearScope) -> String {
        let count = clearCount(scope)
        guard count > 0 else { return "沒有列印紀錄" }
        return "這將無法還原。"
    }

    private func performClear(_ scope: ClearScope) {
        let now = Date()
        library.delete(kind: .history) { scope.matches($0, now: now) }
        pendingClear = nil
        endEditing()
        reload()
    }

    private func beginEditing(_ kind: LibraryKind) {
        selection = []
        editingKind = kind
    }

    private func endEditing() {
        editingKind = nil
        selection = []
    }

    private func toggleSelection(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    // MARK: - Layout

    private func layout(_ kind: LibraryKind) -> LibraryLayout {
        switch kind {
        case .recovered: return recentLayout
        case .template: return templateLayout
        case .history: return historyLayout
        }
    }

    private func setLayout(_ layout: LibraryLayout, for kind: LibraryKind) {
        switch kind {
        case .recovered: recentLayout = layout
        case .template: templateLayout = layout
        case .history: historyLayout = layout
        }
    }

    private func deleteSelection() {
        library.delete(selection)
        endEditing()
        reload()
    }

    // MARK: - Batch export

    /// Render every picked document in one format and hand the whole lot to the
    /// share sheet at once. Anything that fails to render is skipped rather than
    /// taking the other files down with it; only an empty result is an error
    /// worth stopping for.
    private func exportSelection(_ format: LibraryExportKind) {
        let picked = entries.filter { selection.contains($0.id) }
        let store = DocumentStore()
        var urls: [URL] = []
        var usedNames: Set<String> = []
        var failure: String?

        for entry in picked {
            guard let document = library.document(for: entry.id) else {
                failure = "有些項目已經不在了"
                continue
            }
            do {
                guard let data = try data(for: document, format: format) else {
                    failure = "無法產生檔案"
                    continue
                }
                let base = store.sanitised(document.title) + format.nameSuffix
                urls.append(try ExportService.writeTemporary(
                    data,
                    name: uniqueName(base, used: &usedNames),
                    ext: format.fileExtension
                ))
            } catch {
                failure = error.localizedDescription
            }
        }

        if urls.isEmpty {
            exportError = failure ?? "無法產生檔案"
        } else {
            shareSelection = ShareItems(urls: urls)
        }
    }

    private func data(for document: BitarfDocument, format: LibraryExportKind) throws -> Data? {
        switch format {
        case .png: return ExportService.pngData(document: document, scale: 2)
        case .pngTransparent: return ExportService.pngData(document: document, scale: 2, transparent: true)
        case .pdf: return ExportService.pdfData(document: document)
        case .dithered: return ExportService.ditheredPNGData(document: document)
        case .document: return try document.encoded()
        }
    }

    /// Two documents may well share a title, and `writeTemporary` overwrites by
    /// name — without this the share sheet would silently hand over one file
    /// where the user picked two.
    private func uniqueName(_ base: String, used: inout Set<String>) -> String {
        var name = base
        var suffix = 2
        while used.contains(name) {
            name = "\(base) \(suffix)"
            suffix += 1
        }
        used.insert(name)
        return name
    }

    // MARK: - Library tabs

    private func libraryTab(_ kind: LibraryKind, empty: String) -> some View {
        let rows = entries.filter { $0.kind == kind }
        let isEditing = editingKind == kind
        return Group {
            if layout(kind) == .grid {
                gridBody(rows: rows, isEditing: isEditing)
            } else {
                listBody(rows: rows, isEditing: isEditing)
            }
        }
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .toolbar { libraryToolbar(kind, rows: rows) }
        // The action bar and the tab bar want the same strip of screen, and left
        // to themselves the tab bar wins and the actions sit invisibly behind
        // it. Switching tabs mid-selection would throw the selection away in any
        // case, so the tab bar stands down while rows are being picked.
        .toolbar(isEditing ? .hidden : .automatic, for: .tabBar)
        // Nothing to list is not a row: the explanation sits in the middle of
        // the empty space rather than in a cell pretending to be a document.
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(empty, systemImage: emptyStateImage(for: kind))
                    .allowsHitTesting(false)
            }
        }
    }

    private func emptyStateImage(for kind: LibraryKind) -> String {
        switch kind {
        case .recovered: "clock"
        case .template: "doc.on.doc"
        case .history: "printer.dotmatrix"
        }
    }

    private func listBody(rows: [LibraryEntry], isEditing: Bool) -> some View {
        List(selection: $selection) {
            // A notice is not a document, so it is not something to tick. While
            // picking rows it steps out of the way rather than sit in the list
            // wearing a selection circle it can do nothing with.
            if notice != nil, !isEditing {
                Section { noticeCard }
            }

            if !rows.isEmpty {
                Section {
                    ForEach(rows) { entry in
                        if isEditing {
                            // No button: in edit mode the tap belongs to the
                            // selection, and a row that also opens the document
                            // would make ticking it a gamble.
                            row(entry, isEditing: true)
                        } else {
                            Button {
                                openEntry(entry)
                            } label: {
                                row(entry, isEditing: false)
                            }
                            .buttonStyle(.plain)
                            .matchedTransitionSource(id: entry.id, in: zoomNamespace)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    library.delete(entry.id)
                                    reload()
                                } label: {
                                    Label("刪除", systemImage: "trash")
                                }
                            }
                            .contextMenu { rowMenu(entry) }
                        }
                    }
                }
            }
        }
    }

    /// The same rows as a wall of paper. Nothing here is a `List`: the point of
    /// this layout is the picture, and a list cell wide enough to show one would
    /// fit three documents on a screen.
    private func gridBody(rows: [LibraryEntry], isEditing: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if notice != nil, !isEditing {
                    noticeCard
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 104), spacing: 16)],
                    alignment: .leading,
                    spacing: 20
                ) {
                    ForEach(rows) { entry in
                        gridCell(entry, isEditing: isEditing)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func gridCell(_ entry: LibraryEntry, isEditing: Bool) -> some View {
        let cell = VStack(alignment: .leading, spacing: 5) {
            gridThumbnail(entry, isEditing: isEditing)
            Text(entry.title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            // Only the date: a tile is a third of a row wide, and the length
            // wrapping onto a second line pushes the tiles below out of step.
            Text(gridDetail(entry))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())

        if isEditing {
            // Same rule as the list: while picking, the tap is the tick.
            cell.onTapGesture { toggleSelection(entry.id) }
        } else {
            cell
                .onTapGesture { openEntry(entry) }
                .matchedTransitionSource(id: entry.id, in: zoomNamespace)
                .contextMenu { rowMenu(entry) }
        }
    }

    /// A grid tile's picture: the paper at the top of a fixed portrait box, so
    /// the tiles line up in rows whatever length the documents are.
    private func gridThumbnail(_ entry: LibraryEntry, isEditing: Bool) -> some View {
        let isSelected = selection.contains(entry.id)
        return RoundedRectangle(cornerRadius: 6)
            .fill(Color(.systemBackground))
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                if let image = UIImage(contentsOfFile: library.thumbnailURL(entry.id).path) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isEditing && isSelected ? Color.accentColor : Color(uiColor: .quaternaryLabel),
                            lineWidth: isEditing && isSelected ? 2 : 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if isEditing {
                    // The unticked circle sits on white paper as often as not,
                    // so it is drawn in a label colour over a filled disc rather
                    // than in white over a photo the way Photos can afford to.
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isSelected ? Color.white : Color(uiColor: .secondaryLabel),
                                         isSelected ? Color.accentColor : Color.clear)
                        .background(Circle().fill(Color(.systemBackground)).padding(2))
                        .padding(5)
                }
            }
    }

    /// The one-off launch message. Shared by both layouts so the wording and the
    /// dismiss button cannot drift apart.
    @ViewBuilder
    private var noticeCard: some View {
        if let notice {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .foregroundStyle(.tint)
                Text(notice)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    self.notice = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ entry: LibraryEntry) -> some View {
        Button {
            renameText = entry.title
            renaming = entry
        } label: {
            Label("重新命名", systemImage: "pencil")
        }
        if entry.kind == .template {
            // Only templates: a copy is for a thing you will edit and print
            // again, and 最近/列印歷史 rows are records rather than stock.
            Button {
                if library.duplicate(entry.id) != nil { reload() }
            } label: {
                Label("複製", systemImage: "doc.on.doc")
            }
        }
        Button(role: .destructive) {
            library.delete(entry.id)
            reload()
        } label: {
            Label("刪除", systemImage: "trash")
        }
    }

    private func row(_ entry: LibraryEntry, isEditing: Bool) -> some View {
        HStack(spacing: 12) {
            thumbnail(entry)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // The chevron promises the row opens something. While picking rows
            // it does not, so it goes.
            if !isEditing {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func thumbnail(_ entry: LibraryEntry) -> some View {
        let size = CGSize(width: 40, height: 52)
        if let image = UIImage(contentsOfFile: library.thumbnailURL(entry.id).path) {
            Image(uiImage: image)
                .resizable()
                // Fit rather than fill: the strip is usually much wider than
                // this box is, and cropping the sides off turns the one line of
                // text that identifies the document into a fragment.
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(Color(.systemBackground))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary))
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(.quaternary)
                .frame(width: size.width, height: size.height)
        }
    }

    private func detail(_ entry: LibraryEntry) -> String {
        var parts: [String] = []
        if let printed = entry.lastPrintedAt {
            let count = entry.printedDates.count
            parts.append(count > 1
                         ? "列印 \(count) 次・\(Self.dateText(printed))"
                         : "\(Self.dateText(printed)) 列印")
        } else {
            parts.append("\(Self.dateText(entry.updatedAt)) 儲存")
        }
        parts.append(entry.lengthDescription)
        return parts.joined(separator: "　")
    }

    /// The same first half of `detail`, without the physical length.
    private func gridDetail(_ entry: LibraryEntry) -> String {
        if let printed = entry.lastPrintedAt {
            let count = entry.printedDates.count
            return count > 1
                ? "列印 \(count) 次・\(Self.dateText(printed))"
                : "\(Self.dateText(printed)) 列印"
        }
        return "\(Self.dateText(entry.updatedAt)) 儲存"
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh-Hant-TW")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Actions

    private func openEntry(_ entry: LibraryEntry) {
        guard let document = library.document(for: entry.id) else { return }
        open(document, entry)
    }

    private func reload() {
        entries = library.entries()
    }
}

// MARK: - Library layout

/// How a library tab draws its documents: a line each, or a picture each.
private enum LibraryLayout: String {
    case list, grid

    var toggled: LibraryLayout { self == .list ? .grid : .list }

    /// The glyph the toolbar shows while this layout is the one on screen.
    var symbol: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        }
    }

    /// Spoken, and shown in menus: the layout a tap switches *to*.
    var actionTitle: String {
        switch self {
        case .list: return "以清單顯示"
        case .grid: return "以格狀顯示"
        }
    }
}

// MARK: - Batch export formats

/// The same five formats the editor's 匯出 menu offers, in the same order and
/// with the same words: a document exported from the list must not come out
/// different from the one exported from the editor.
private enum LibraryExportKind: String, CaseIterable, Identifiable {
    case png, pngTransparent, pdf, dithered, document

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png: return "PNG 影像"
        case .pngTransparent: return "PNG（透明背景）"
        case .pdf: return "PDF"
        case .dithered: return "網點化 PNG"
        case .document: return "Bitarf RI 檔案"
        }
    }

    var fileExtension: String {
        switch self {
        case .png, .pngTransparent, .dithered: return "png"
        case .pdf: return "pdf"
        case .document: return BitarfDocument.fileExtension
        }
    }

    /// Appended to the document title so the variants of one document stay
    /// distinguishable in the share sheet.
    var nameSuffix: String {
        switch self {
        case .pngTransparent: return "-透明"
        case .dithered: return "-網點"
        case .png, .pdf, .document: return ""
        }
    }
}

extension UTType {

    /// The app's own document. Nothing declares this type in `Info.plist`, so
    /// it resolves to the dynamic type for the extension — enough for the file
    /// picker to stop greying out `.bitarf` files, which is all it is for.
    /// `.json` is offered alongside it because exports leave the app as JSON.
    static var bitarfDocument: UTType {
        UTType(filenameExtension: BitarfDocument.fileExtension) ?? .json
    }
}

/// Several files handed to one share sheet.
struct ShareItems: Identifiable {
    let urls: [URL]
    var id: String { urls.map(\.absoluteString).joined(separator: "|") }
}

// MARK: - Settings tab

/// App-level preferences: what happens on launch, and what a brand new document
/// starts out as. The launch choice used to hide in a toolbar menu, where a
/// setting that changes every future launch had the same weight as 「關於」.
private struct SettingsTab: View {

    @AppStorage(LaunchBehaviour.storageKey) private var launchBehaviour = LaunchBehaviour.newDocument
    @AppStorage(EditorState.marginGuideKey) private var showsMarginGuide = true

    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                ForEach(LaunchBehaviour.allCases) { behaviour in
                    Button {
                        launchBehaviour = behaviour
                    } label: {
                        HStack {
                            Text(behaviour.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            if launchBehaviour == behaviour {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("打開 App 時")
            }

            Section {
                Toggle("邊界虛線", isOn: $showsMarginGuide)
            } header: {
                Text("畫布")
            } footer: {
                Text("在編輯畫面標出可列印範圍的邊界。不會印出來。")
            }

            Section {
                NavigationLink("預設文件設定") {
                    DefaultDocumentSettingsView()
                }
            }

            // The machine, not the document. Everything here outlives whatever
            // is being printed, which is why it stopped being part of the print
            // sheet.
            PrinterConfigurationSection()

            // 照片、本地網路這類權限只有系統設定改得動，App 自己給不了開關。
            // 這一列的箭頭就是在說「按下去會離開 Bitarf RI」，免得使用者以為
            // 裡面還有一頁可以調。
            Section {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    HStack {
                        Text("權限設定")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.forward.square")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text("系統")
            }
        }
    }
}

// MARK: - Default document settings

/// The same controls as 「文件設定」, bound to `UserDefaults` instead of to a
/// document. Sharing `DocumentSettingsForm` is the point: the promise this page
/// makes is that a new document comes out looking like what is set here, and
/// that only holds while both screens offer the same settings.
struct DefaultDocumentSettingsView: View {

    @State private var isConfirmingReset = false

    @AppStorage(DocumentDefaults.orientationKey) private var orientation = CanvasOrientation.portrait
    // 此處應插入經典機型固定軸的 @AppStorage 預設值。
    @AppStorage(DocumentDefaults.marginKey) private var margin = DocumentDefaults.fallbackMargin
    @AppStorage(DocumentDefaults.ditherKey) private var dither = DitherAlgorithm.floydSteinberg
    @AppStorage(DocumentDefaults.thresholdKey) private var threshold = DocumentDefaults.fallbackThreshold
    // 此處應插入經典機型濃度與尾端走紙的 @AppStorage 預設值。

    var body: some View {
        Form {
            DocumentSettingsForm(
                orientation: $orientation,
                // 此處應插入經典機型的 fixedAxisDots binding。
                margin: Binding(
                    get: { CGFloat(margin) },
                    set: { margin = Double($0) }
                ),
                dither: $dither,
                threshold: $threshold,
                // 此處應插入經典機型濃度與尾端走紙 bindings。
                describesDefaults: true
            )

            Section {
                Button {
                    isConfirmingReset = true
                } label: {
                    Label("回復預設值", systemImage: "arrow.counterclockwise")
                }
                .tint(.accentColor)
                // Anchored on the button rather than on the Form: without a row
                // to point at, the sheet has nothing to come out of and lands at
                // the top of the screen.
                .confirmationDialog(
                    "回復預設值",
                    isPresented: $isConfirmingReset,
                    titleVisibility: .visible
                ) {
                    Button("回復預設值", role: .destructive) { DocumentDefaults.reset() }
                    Button("取消", role: .cancel) {}
                }
            }
        }
        .navigationTitle("預設文件設定")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Document defaults

/// What a brand new document starts out as. Stored in `UserDefaults` rather than
/// on the document, because it describes the next document, not any existing one.
///
/// The fallbacks deliberately repeat `BitarfDocument`'s own defaults: with
/// nothing stored, a new document must come out exactly as it did before this
/// screen existed.
enum DocumentDefaults {
    static let orientationKey = "defaultOrientation"
    static let fixedAxisKey = "defaultFixedAxisDots"
    static let marginKey = "defaultMargin"
    static let ditherKey = "defaultDither"
    static let thresholdKey = "defaultThreshold"
    // 此處應插入經典機型濃度與尾端走紙的 defaults keys。

    static let fallbackMargin = 8.0
    static let fallbackThreshold = 128
    // 此處應插入經典機型濃度與尾端走紙的 fallback。

    private static let allKeys = [
        orientationKey, fixedAxisKey, marginKey,
        ditherKey, thresholdKey
    ]

    /// Apply the stored defaults to a freshly created document.
    static func applied(to document: BitarfDocument) -> BitarfDocument {
        let defaults = UserDefaults.standard
        var copy = document
        if let raw = defaults.string(forKey: orientationKey),
           let orientation = CanvasOrientation(rawValue: raw) {
            copy.orientation = orientation
        }
        // 此處應插入經典機型固定軸 defaults 的套用與範圍檢查。
        if defaults.object(forKey: marginKey) != nil {
            copy.margin = CGFloat(min(max(defaults.double(forKey: marginKey), 0), 64))
        }
        if let raw = defaults.string(forKey: ditherKey),
           let dither = DitherAlgorithm(rawValue: raw) {
            copy.dither = dither
        }
        if defaults.object(forKey: thresholdKey) != nil {
            let value = defaults.integer(forKey: thresholdKey)
            if (1...254).contains(value) { copy.threshold = UInt8(value) }
        }
        // 此處應插入經典機型濃度與尾端走紙 defaults 的套用與範圍檢查。
        return copy
    }

    /// Forget every stored default, so new documents go back to stock.
    static func reset() {
        let defaults = UserDefaults.standard
        allKeys.forEach { defaults.removeObject(forKey: $0) }
    }
}

// MARK: - Launch behaviour

enum LaunchBehaviour: String, CaseIterable, Identifiable {
    case newDocument
    case browser

    static let storageKey = "launchBehaviour"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newDocument: return "開啟空白文件"
        case .browser: return "顯示首頁"
        }
    }
}
