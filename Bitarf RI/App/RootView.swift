//
//  RootView.swift
//  Bitarf RI
//
//  The editor shell: canvas in the middle, one bottom bar that swaps between
//  creating and editing, document-level actions at the top. Everything that is
//  not the canvas is a sheet, because the canvas is the product and it should
//  keep the screen.
//

import ImagePlayground
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {

    @EnvironmentObject private var editor: EditorState

    private enum Panel: String, Identifiable {
        case inspector, format, objects, settings, printer
        var id: String { rawValue }
    }

    @State private var panel: Panel?
    @State private var disambiguationIDs: [UUID] = []
    @State private var showsDisambiguation = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isPickingPhoto = false
    @State private var isPresentingImagePlayground = false
    // @State private var isPreparingImagePlayground = false
    @State private var shareItem: ShareItem?
    @State private var isImportingVector = false
    @State private var isConvertingVector = false
    @State private var pendingExport: ExportKind?
    @State private var showsClearConfirmation = false

    private enum ExportKind: String, Identifiable {
        case png, pngTransparent, pdf, dithered, document
        var id: String { rawValue }
    }

    /// Called when the user walks back to the document list, so the shell can
    /// decide what happens to work that was never committed.
    let onLeave: () -> Void

    var body: some View {
        CanvasHostView { ids in
            disambiguationIDs = ids
            showsDisambiguation = true
        }
        // No `ignoresSafeArea(.bottom)`: the canvas still draws to the bottom of
        // the screen, but the scroll view learns how tall the bottom bar is, so
        // the last strip of paper can always be scrolled out from under it.
        // The system bar does that inset for us — it used to be a hand-rolled
        // `safeAreaInset`.
        .overlay(alignment: .top) { statusBanner }
        .overlay { vectorProgress }
        // .overlay { imagePlaygroundPreparingAlert }
        .navigationTitle(editor.document.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar { toolbarContent }
        .toolbar { bottomBarContent }
        // The bottom bar lives in the navigation controller's own toolbar, and
        // that toolbar does not rise for the keyboard — SwiftUI's avoidance only
        // moves view content. So while a box is being edited the bar would sit
        // silently underneath the keyboard; it steps aside instead, and the text
        // view's input accessory is the bar that rides above the keys.
        .toolbar(editor.editingTextID == nil ? .visible : .hidden, for: .bottomBar)
        .sheet(item: $panel, onDismiss: {
            // Whatever borrowed the keyboard has given it back. The canvas
            // watches this and hands the text view its selection again.
            editor.isTextEditingSuspended = false
        }) { panel in
            // Sheets get their own environment; re-injecting the editor keeps
            // every panel talking to the same document instance.
            sheet(for: panel).environmentObject(editor)
        }
        .sheet(isPresented: $showsDisambiguation) {
            NavigationStack {
                ObjectListPanel(highlighting: disambiguationIDs)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
            .environmentObject(editor)
        }
        .alert(
            "清除畫布上的全部物件？",
            isPresented: $showsClearConfirmation
        ) {
            Button("清空全部內容", role: .destructive) { editor.clearAll() }
            Button("取消", role: .cancel) {}
        }
        .photosPicker(isPresented: $isPickingPhoto, selection: $photoItem, matching: .images)
        .imagePlaygroundSheet(
            isPresented: $isPresentingImagePlayground,
            onCompletion: { url in
                insertImagePlaygroundResult(at: url)
            }
        )
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
        .background {
            Color.clear.fileImporter(
                isPresented: $isImportingVector,
                allowedContentTypes: [.svg, .pdf],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task { await loadVector(url) }
                }
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        .onChange(of: pendingExport) { _, kind in
            guard let kind else { return }
            pendingExport = nil
            share(kind)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            if editor.editingTextID != nil {
                // While a box is being edited, leaving the *text* is the only
                // move that makes sense from this corner — walking out to the
                // document list mid-sentence is not something anyone reaches
                // for. So finishing takes the slot, and takes the emphasis
                // with it: it is the way out of the mode.
                Button {
                    editor.editingTextID = nil
                } label: {
                    Label("完成", systemImage: "checkmark")
                }
                .buttonStyle(.glassProminent)
            } else if editor.isSelectionMode {
                // Same bargain for 選取模式, and the same slot. This button is
                // also the only thing that empties the selection, which is what
                // lets a stray tap on empty paper be harmless while picking.
                Button {
                    editor.exitSelectionMode()
                } label: {
                    Label("完成", systemImage: "checkmark")
                }
                .buttonStyle(.glassProminent)
            } else {
                Button(action: onLeave) {
                    // Back, even though the editor is presented rather than
                    // pushed: a downward chevron in a toolbar reads as
                    // collapse, and this tap goes somewhere — to the document
                    // browser.
                    Label("文件", systemImage: "chevron.backward")
                }
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            // Undo is the tap; redo is the long press. Redo is only ever wanted
            // right after an undo, so it does not need to hold a slot of its own
            // in a bar this narrow.
            Menu {
                Button {
                    editor.redo()
                } label: {
                    Label("重做", systemImage: "arrow.uturn.forward")
                }
                .disabled(!editor.canRedo)
            } label: {
                Label("還原", systemImage: "arrow.uturn.backward")
            } primaryAction: {
                editor.undo()
            }
            .disabled(!editor.canUndo && !editor.canRedo)

            Button {
                panel = .objects
            } label: {
                // The same sheet, but in 選取模式 it is read as "what is in my
                // set", not "what is on top of what" — so it says so, and the
                // filled top layer says the stack is no longer the point.
                // The glyph stays put. This button opens the same stack it
                // always did — only what the sheet is *for* changes with the
                // mode, and the title is where that gets said.
                Label(
                    editor.isSelectionMode ? "選取物件" : "圖層",
                    systemImage: "square.3.layers.3d"
                )
            }

            Menu {
                // What the document can become: a file to send somewhere, or a
                // template to start from again. One idea, one section.
                Section {
                    Menu {
                        Button("PNG 影像") { pendingExport = .png }
                        Button("PNG（透明背景）") { pendingExport = .pngTransparent }
                        Button("PDF") { pendingExport = .pdf }
                        Button("網點化 PNG") { pendingExport = .dithered }
                        Button("Bitarf RI 檔案") { pendingExport = .document }
                    } label: {
                        Label("輸出", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        editor.saveAsTemplate()
                    } label: {
                        Label("儲存為範本", systemImage: "square.and.arrow.down")
                    }
                    if editor.canUpdateSourceTemplate {
                        Button {
                            editor.updateSourceTemplate()
                        } label: {
                            Label("更新來源範本", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                }
                // Two toggles, not one: the line and the pull are different
                // promises. Seeing that an edge lines up costs the user nothing,
                // while being moved onto it takes the last dot of control away —
                // so anyone who wants the first and not the second has to be
                // able to say so.
                //
                // The margin guide is not here. It is not something you reach
                // for mid-drag, and a third row would have made this section
                // read as "assorted lines" instead of one idea.
                Section("對齊輔助") {
                    Toggle(isOn: $editor.guidesEnabled) {
                        Label("對齊參考線", systemImage: "align.horizontal.center")
                    }
                    Toggle(isOn: $editor.snapEnabled) {
                        // No `magnet` in the system symbol set, and this one is more
                        // literal anyway: two things being pulled onto one line.
                        Label("吸附對齊", systemImage: "arrow.right.and.line.vertical.and.arrow.left")
                    }
                }
                // What the paper is, and putting it on paper.
                Section {
                    Button {
                        panel = .settings
                    } label: {
                        Label("文件設定", systemImage: "doc.badge.gearshape")
                    }
                }
                Section {
                    Button(role: .destructive) {
                        showsClearConfirmation = true
                    } label: {
                        Label("清空全部內容", systemImage: "trash")
                    }
                }
            } label: {
                Label("更多", systemImage: "ellipsis")
            }
        }

        // Its own group, so the glass draws a gap between "things you do to the
        // document" and the one button that ends the document's life on screen
        // and starts its life on paper.
        ToolbarSpacer(.fixed, placement: .topBarTrailing)

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                panel = .printer
            } label: {
                Label("列印", systemImage: "printer.dotmatrix.inverse")
            }
            .buttonStyle(.glassProminent)
        }
    }

    // MARK: - Bottom bar

    /// One system bottom bar whose contents swap on selection, the way Photos
    /// and Files swap theirs when you enter a mode. Nothing is drawn by hand any
    /// more, so the glass, the scroll-edge behaviour and the safe-area inset all
    /// come from the system.
    ///
    /// While a text box is being edited the bar is hidden altogether (see the
    /// `toolbar(_:for:)` call in `body`) and the text view's own accessory —
    /// which does ride the keyboard — carries the 「完成」 button.
    @ToolbarContentBuilder
    private var bottomBarContent: some ToolbarContent {
        if editor.isSelectionMode {
            multiSelectionBarContent
        } else if let object = editor.selectedObject, editor.editingTextID == nil {
            selectionBarContent(for: object)
        } else {
            creationBarContent
        }
    }

    /// The bar while 選取模式 is open.
    ///
    /// Everything a multi-selection can do has to be reachable from here,
    /// because leaving the mode empties the selection — there is no "pick now,
    /// act later". 排列 is the one that matters: alignment, distribution,
    /// rotation and layer order all live behind it.
    ///
    /// It keeps this shape even when only one object is in the set. A bar that
    /// rearranged itself because the user happened to deselect down to one would
    /// move the button they were reaching for.
    @ToolbarContentBuilder
    private var multiSelectionBarContent: some ToolbarContent {
        ToolbarSpacer(.flexible, placement: .bottomBar)

        ToolbarItemGroup(placement: .bottomBar) {
            // The glyph is the state, not the errand — same rule as 鎖定 and
            // 隱藏 below, so the whole bar can be read one way. The checklist
            // family happens to draw all three: two empty circles, one ticked
            // and one not, both ticked. So it can say 部分 as well.
            Button {
                editor.toggleSelectAll()
            } label: {
                Label(
                    editor.isEverythingSelected ? "取消全選" : "全選",
                    systemImage: editor.selectAllSymbolName
                )
                .contentTransition(.symbolEffect(.replace))
            }

            // 圖層 goes into edit mode while 選取模式 is open, which silences the
            // swipes and the long-press menu that used to be the only way to
            // lock or hide. So the two of them live here for the duration,
            // ahead of 複製 and 刪除.
            //
            // A mixed set reads as unlocked, so the first tap locks the whole
            // set rather than inverting each member — inverting would leave the
            // set as mixed as it started. Same bargain as 排列's toggles.
            //
            // The glyph shows where the set *is*, not where the tap sends it:
            // an open lock and an open eye mean unlocked and visible. The label
            // still names the errand, which is what VoiceOver needs to hear.
            Button {
                editor.setSelectionLocked(!allSelectionLocked)
            } label: {
                Label(allSelectionLocked ? "全部解鎖" : "全部鎖定",
                      systemImage: allSelectionLocked ? "lock" : "lock.open")
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(editor.selectedIDs.isEmpty)

            Button {
                editor.setSelectionHidden(!allSelectionHidden)
            } label: {
                Label(allSelectionHidden ? "全部顯示" : "全部隱藏",
                      systemImage: allSelectionHidden ? "eye.slash" : "eye")
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(editor.selectedIDs.isEmpty)

            Button {
                editor.duplicateSelection()
            } label: {
                Label("複製", systemImage: "plus.square.on.square")
            }
            .disabled(editor.selectedIDs.isEmpty)

            Button {
                panel = .inspector
            } label: {
                Label("排列", systemImage: "rectangle.3.group")
            }
            .disabled(editor.selectedIDs.isEmpty)

            Button(role: .destructive) {
                let count = editor.selectionCount
                editor.deleteSelection()
                editor.statusMessage = "已刪除 \(count) 個物件"
            } label: {
                Label("刪除", systemImage: "trash")
            }
            .tint(.red)
            .disabled(editor.selectedIDs.isEmpty)
        }
    }

    /// An empty set is not "all locked" — with nothing picked both buttons are
    /// disabled anyway, but this keeps the label from reading 全部解鎖.
    private var allSelectionLocked: Bool {
        !editor.selectedIDs.isEmpty && editor.selectedObjects.allSatisfy(\.isLocked)
    }

    private var allSelectionHidden: Bool {
        !editor.selectedIDs.isEmpty && editor.selectedObjects.allSatisfy(\.isHidden)
    }

    /// Actions on the thing that is currently selected.
    ///
    /// Deleting used to live only behind a swipe in the layer list and at the
    /// bottom of the arrange panel, which meant the answer to "how do I get rid
    /// of this photo" was two screens away from the photo. A selection is a
    /// visible state, so its actions belong next to it.
    ///
    /// There is no 「取消選取」 button: tapping empty canvas already does it, and a
    /// button for it would cost a slot that a real action can use.
    @ToolbarContentBuilder
    private func selectionBarContent(for object: CanvasObject) -> some ToolbarContent {
        // Creation does not go away just because something is selected — it
        // folds into one menu so the bar can still be read at a glance.
        //
        // No `buttonStyle` here: the toolbar already draws its own glass behind
        // every item, and a prominent style painted a second background inside
        // the first.
        ToolbarItem(placement: .bottomBar) {
            Menu {
                creationButtons
            } label: {
                Label("新增", systemImage: "plus")
            }
        }

        ToolbarSpacer(.flexible, placement: .bottomBar)

        ToolbarItemGroup(placement: .bottomBar) {
            Button {
                editor.duplicate(object.id)
            } label: {
                Label("複製", systemImage: "plus.square.on.square")
            }

            Button {
                panel = .format
            } label: {
                Label("格式", systemImage: "paintbrush")
            }
            .disabled(!object.isText && !object.isShape)

            Button {
                panel = .inspector
            } label: {
                Label("排列", systemImage: "rectangle.3.group")
            }

            Button(role: .destructive) {
                let name = object.displayName
                editor.delete(object.id)
                // Undo is one tap away in the toolbar, so say so instead of
                // stopping the user with a confirmation they would learn to
                // dismiss without reading.
                editor.statusMessage = "已刪除「\(name)」"
            } label: {
                Label("刪除", systemImage: "trash")
            }
            // `role: .destructive` alone does not colour a toolbar button, and
            // delete is the one item here that cannot be undone by looking away.
            .tint(.red)
        }
    }

    @ToolbarContentBuilder
    private var creationBarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            creationButtons
        }
    }

    /// The four things you can put on the paper. Shared so the selected state's
    /// 「新增」 menu and the unselected state's bar can never drift apart.
    @ViewBuilder
    private var creationButtons: some View {
        Button {
            editor.addTextBox(visibleTop: editor.visibleTopDots)
        } label: {
            Label("文字方塊", systemImage: "character.textbox")
        }

        Menu {
            Button {
                editor.addShape(.rectangle, visibleTop: editor.visibleTopDots)
            } label: {
                Label("矩形", systemImage: "rectangle")
            }
            Button {
                editor.addShape(.ellipse, visibleTop: editor.visibleTopDots)
            } label: {
                Label("圓形", systemImage: "circle")
            }
            Button {
                editor.addShape(.line, visibleTop: editor.visibleTopDots)
            } label: {
                Label("線條", systemImage: "line.diagonal")
            }
        } label: {
            Label("形狀", systemImage: "square.on.circle")
        }

        // A `PhotosPicker` nested in a `Menu` renders but never presents, so the
        // button only raises a flag and the picker is attached to the root view.
        // Same button in both states means the two can never drift apart.
        Button {
            isPickingPhoto = true
        } label: {
            Label("照片", systemImage: "photo")
        }

        // Image Playground needs Apple Intelligence. On a device that does not
        // have it the button is greyed rather than removed: a menu that quietly
        // loses a row reads as a bug, while a dim row reads as "not here".
        Button {
            // isPreparingImagePlayground = true
            isPresentingImagePlayground = true
        } label: {
            Label("影像樂園", systemImage: "apple.image.playground")
        }
        .disabled(!ImagePlaygroundViewController.isAvailable)

        Button {
            isImportingVector = true
        } label: {
            Label("向量", systemImage: "beziercurve")
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusBanner: some View {
        if let message = editor.statusMessage {
            Text(message)
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { editor.statusMessage = nil }
                .task(id: message) {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    if editor.statusMessage == message { editor.statusMessage = nil }
                }
        }
    }

    /// Converting an SVG means laying it out in a web view, which is fast but
    /// not instant. Without this the tap looks like it did nothing.
    @ViewBuilder
    private var vectorProgress: some View {
        if isConvertingVector {
            ProgressView("正在讀取向量…")
                .padding(20)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    /*
     /// Disabled after removing the UIKit presentation bridge. The official
     /// Image Playground sheet owns its complete presentation lifecycle.
     @ViewBuilder
     private var imagePlaygroundPreparingAlert: some View {
         if isPreparingImagePlayground {
             ZStack {
                 Color.black.opacity(0.16)
                     .ignoresSafeArea()

                 VStack(spacing: 12) {
                     ProgressView()
                         .controlSize(.large)
                     Text("準備中⋯")
                 }
                 .padding(.horizontal, 28)
                 .padding(.vertical, 22)
                 .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                 .accessibilityElement(children: .combine)
                 .accessibilityLabel("影像樂園準備中")
             }
             .transition(.opacity)
         }
     }
     */

    // MARK: - Sheets

    @ViewBuilder
    private func sheet(for panel: Panel) -> some View {
        switch panel {
        case .inspector:
            NavigationStack {
                InspectorPanel()
                    .navigationTitle("排列")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])

        case .format:
            NavigationStack {
                TextFormatPanel()
                    .navigationTitle("格式")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])

        case .objects:
            NavigationStack {
                // No title here: the panel names itself, because what it is
                // called depends on whether 選取模式 is open.
                ObjectListPanel()
            }
            .presentationDetents([.medium, .large])

        case .settings:
            NavigationStack {
                DocumentSettingsPanel()
                    .navigationTitle("文件設定")
                    .navigationBarTitleDisplayMode(.inline)
            }

        case .printer:
            PrintView()
        }
    }

    // MARK: - Actions

    private func loadPhoto(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            editor.statusMessage = "無法載入這張圖片"
            return
        }
        editor.addImage(image, visibleTop: editor.visibleTopDots)
    }

    private func insertImagePlaygroundResult(at url: URL) {
        guard let image = UIImage(contentsOfFile: url.path) else {
            editor.statusMessage = "無法載入影像樂園產生的圖片"
            return
        }
        editor.addImage(image, visibleTop: editor.visibleTopDots)
    }

    private func loadVector(_ url: URL) async {
        isConvertingVector = true
        defer { isConvertingVector = false }
        do {
            let content = try await VectorImportService.load(from: url)
            editor.addVector(content, visibleTop: editor.visibleTopDots)
        } catch {
            editor.statusMessage = "無法插入向量：\(error.localizedDescription)"
        }
    }

    private func share(_ kind: ExportKind) {
        let document = editor.document
        let name = DocumentStore().sanitised(document.title)
        do {
            switch kind {
            case .png:
                guard let data = ExportService.pngData(document: document, scale: 2) else { throw ExportFailure() }
                shareItem = ShareItem(url: try ExportService.writeTemporary(data, name: name, ext: "png"))
            case .pngTransparent:
                guard let data = ExportService.pngData(document: document, scale: 2, transparent: true) else { throw ExportFailure() }
                shareItem = ShareItem(url: try ExportService.writeTemporary(data, name: "\(name)-透明", ext: "png"))
            case .pdf:
                guard let data = ExportService.pdfData(document: document) else { throw ExportFailure() }
                shareItem = ShareItem(url: try ExportService.writeTemporary(data, name: name, ext: "pdf"))
            case .dithered:
                guard let data = ExportService.ditheredPNGData(document: document) else { throw ExportFailure() }
                shareItem = ShareItem(url: try ExportService.writeTemporary(data, name: "\(name)-網點", ext: "png"))
            case .document:
                shareItem = ShareItem(url: try editor.exportDocumentFile())
            }
        } catch {
            editor.statusMessage = "輸出失敗：\(error.localizedDescription)"
        }
    }

    private struct ExportFailure: LocalizedError {
        var errorDescription: String? { "無法產生檔案" }
    }
}

// MARK: - Share sheet

/// A wrapper rather than a retroactive `Identifiable` conformance on `URL`,
/// which would collide the moment Foundation adds one.
struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
