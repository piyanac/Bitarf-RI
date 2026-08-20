//
//  ObjectListPanel.swift
//  Bitarf RI
//
//  The layer list, and the escape hatch.
//
//  Two jobs in one screen. Normally it is the stacking order. But when several
//  objects sit under one fingertip — which on a 48 mm strip happens constantly —
//  the same list is presented with those objects hoisted to the top and marked,
//  so "which one did you mean" is answered by reading rather than by poking at
//  the canvas until the right thing selects.
//
//  Both jobs are the same table state: edit mode. A tap is membership, the
//  leading circle says what is in the set and the trailing grip reorders it,
//  all drawn by the system. Nothing here is a swipe or a long press any more —
//  every action a row used to hide behind one has a button in the bottom bar,
//  where it can be seen without being discovered.
//

import SwiftUI

struct ObjectListPanel: View {

    @EnvironmentObject var editor: EditorState
    @Environment(\.dismiss) private var dismiss

    /// Objects found under the last tap. Empty for the plain layer list.
    private let highlighting: [UUID]

    init(highlighting: [UUID] = []) {
        self.highlighting = highlighting
    }

    private var isDisambiguating: Bool { !highlighting.isEmpty }

    /// Dragging is off only while picking: there the list is a shortlist of one
    /// tap's worth of candidates, and its order is not the stacking order.
    private var canReorder: Bool { !isDisambiguating }

    /// Topmost layer first — the opposite of the model's draw order.
    private var rows: [CanvasObject] {
        let topFirst = Array(editor.document.objects.reversed())
        guard isDisambiguating else { return topFirst }
        let set = Set(highlighting)
        // A stable partition, not a sort: within each group the layer order is
        // still the truth and reordering it would be disorienting.
        return topFirst.filter { set.contains($0.id) } + topFirst.filter { !set.contains($0.id) }
    }

    private var selection: Binding<Set<UUID>> {
        Binding(
            get: { editor.selectedIDs },
            set: { ids in
                // Ticking a second row is the request for 選取模式: without it
                // the canvas would come back holding a set it has no bar for.
                if ids.count > 1 {
                    editor.enterSelectionMode(with: ids)
                } else {
                    editor.setSelection(ids)
                }
            }
        )
    }

    private var hasSelection: Bool { !editor.selectedIDs.isEmpty }

    var body: some View {
        Group {
            if editor.document.objects.isEmpty {
                Text("畫布空白")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: selection) {
                    Section {
                        ForEach(rows) { object in
                            row(object)
                        }
                        .onMove(perform: canReorder ? move : nil)
                    } header: {
                        Text(isDisambiguating ? "手指下方的物件" : "物件列表")
                    } footer: {
                        if !isDisambiguating {
                            Text("點一下加入或移出選取範圍，拖曳右邊的把手可調整前後順序。")
                        }
                    }
                }
                // A constant binding: the mode is not the user's to leave, it is
                // what this screen is.
                .environment(\.editMode, .constant(.active))
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(role: .confirm) { dismiss() }
            }
            if !editor.document.objects.isEmpty {
                actionBar
            }
        }
    }

    /// In 選取模式 the panel is not showing the stack, it is showing the set —
    /// so it takes the name of the set rather than the name of the stack.
    private var navigationTitle: String {
        if isDisambiguating { return "選擇物件" }
        return editor.isSelectionMode ? "選取物件" : "圖層"
    }

    // MARK: - Actions

    /// The row actions, promoted out of the swipes and the long-press menu.
    ///
    /// They live in this sheet's own bottom bar rather than the canvas's,
    /// because the canvas's is behind the sheet — and because these act on what
    /// is ticked here, which is not always what 選取模式 is holding.
    ///
    /// A mixed set reads as unlocked, so the first tap locks the whole set
    /// rather than inverting each member — inverting would leave the set as
    /// mixed as it started. The glyph shows where the set is, not where the tap
    /// sends it; the label names the errand, for VoiceOver.
    @ToolbarContentBuilder
    private var actionBar: some ToolbarContent {
        // One group, so the glass is one capsule rather than two clumps pinned
        // to opposite corners. The flexible spacers are outside it: they push
        // on the capsule instead of stretching it, which is what centres it.
        ToolbarSpacer(.flexible, placement: .bottomBar)

        ToolbarItemGroup(placement: .bottomBar) {
            // 全選 belongs to a list more than it belongs to a canvas — this is
            // the screen where "all" is something you can actually see.
            Button {
                editor.toggleSelectAll()
            } label: {
                Label(editor.isEverythingSelected ? "取消全選" : "全選",
                      systemImage: editor.selectAllSymbolName)
                    .contentTransition(.symbolEffect(.replace))
            }

            Button {
                editor.setSelectionLocked(!allSelectionLocked)
            } label: {
                Label(allSelectionLocked ? "全部解鎖" : "全部鎖定",
                      systemImage: allSelectionLocked ? "lock" : "lock.open")
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(!hasSelection)

            Button {
                editor.setSelectionHidden(!allSelectionHidden)
            } label: {
                Label(allSelectionHidden ? "全部顯示" : "全部隱藏",
                      systemImage: allSelectionHidden ? "eye.slash" : "eye")
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(!hasSelection)

            Button {
                editor.duplicateSelection()
            } label: {
                Label("複製", systemImage: "plus.square.on.square")
            }
            .disabled(!hasSelection)

            // No confirmation: undo is one tap away on the canvas behind this
            // sheet, the same bargain the canvas's own 刪除 makes.
            Button(role: .destructive) {
                editor.deleteSelection()
            } label: {
                Label("刪除", systemImage: "trash")
            }
            .tint(.red)
            .disabled(!hasSelection)
        }

        ToolbarSpacer(.flexible, placement: .bottomBar)
    }

    private var allSelectionLocked: Bool {
        hasSelection && editor.selectedObjects.allSatisfy(\.isLocked)
    }

    private var allSelectionHidden: Bool {
        hasSelection && editor.selectedObjects.allSatisfy(\.isHidden)
    }

    // MARK: - Row

    private func row(_ object: CanvasObject) -> some View {
        HStack(spacing: 12) {
            Image(systemName: object.symbolName)
                .frame(width: 24)
                .foregroundStyle(object.isHidden ? .tertiary : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(object.displayName)
                    .lineLimit(1)
                    .foregroundStyle(object.isHidden ? .secondary : .primary)
                Text(positionSummary(object))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            // State, not actions. Locked and hidden objects are exactly the ones
            // the canvas will not hand to a tap, so this list is the only place
            // they can be reached — which is why it shows them at all.
            if object.isLocked {
                Image(systemName: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if object.isHidden {
                Image(systemName: "eye.slash.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .listRowBackground(
            highlighting.contains(object.id) ? Color.accentColor.opacity(0.12) : nil
        )
    }

    private func positionSummary(_ object: CanvasObject) -> String {
        let x = Int(object.origin.x.rounded())
        let y = Int(object.origin.y.rounded())
        let width = Int(object.size.width.rounded())
        let height = Int(object.size.height.rounded())
        return "X \(x)　Y \(y)　\(width) × \(height) 點"
    }

    // MARK: - Reordering

    /// The list runs top-layer-first, the model runs bottom-layer-first. Move in
    /// the displayed order, then reverse the whole thing back — cheaper to
    /// reason about than translating index sets across a flipped array.
    private func move(from source: IndexSet, to destination: Int) {
        var ids = rows.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        let modelOrder = Array(ids.reversed())

        editor.apply { document in
            var lookup: [UUID: CanvasObject] = [:]
            for object in document.objects { lookup[object.id] = object }
            document.objects = modelOrder.compactMap { lookup[$0] }
        }
    }
}
