//
//  TextFormatPanel.swift
//  Bitarf RI
//
//  Whole-box text formatting.
//
//  The panel has two targets and one set of controls. Opened from the keyboard
//  while a box is being edited, it acts on the characters that are selected;
//  opened from the bottom bar with a box merely selected, it acts on the whole
//  object. Which one is in force is stated in the panel rather than left for the
//  user to work out from what changed.
//

import CoreGraphics
import CoreText
import SwiftUI
import UIKit

struct TextFormatPanel: View {

    @EnvironmentObject var editor: EditorState

    @Environment(\.dismiss) private var dismiss

    @State private var showsFontPicker = false

    /// Text formatting is two unrelated jobs — how the letters look, and how the
    /// lines sit — and one long Form made you scroll past the first to reach the
    /// second. A tab is cheaper than scrolling on a sheet this short.
    private enum Tab: Hashable {
        case table, font, paragraph
    }

    @State private var tab: Tab = .font

    /// Shape nudges collapse into one undo entry the same way the inspector's do.
    @State private var settleTask: Task<Void, Never>?

    private static let settleDelay: Duration = .milliseconds(700)

    // 此處應插入經典機型硬體衍生的字級上限。

    var body: some View {
        Group {
            if let object = editor.selectedObject, let rich = object.richText {
                textFormatting(object, rich)
            } else if let object = editor.selectedObject,
                      object.isTable,
                      let rich = editor.formattingRichText(for: object.id) {
                // A table's 字體 and 段落 tabs act on the cell being edited, or
                // on every cell when none is — `formattingRichText` is the same
                // answer the keyboard accessory gets.
                textFormatting(object, rich)
            } else if let object = editor.selectedObject, case .shape(let shape) = object.content {
                Form {
                    shapeSection(object, shape)
                }
            } else {
                // A multi-selection lands here too: `selectedObject` is nil for
                // one. Applying a font or a paragraph style to N assorted
                // objects at once is a silent bulk rewrite with nothing to
                // preview, and if it is ever wanted it should be its own
                // decision rather than a side effect of having selected things.
                ContentUnavailableView(
                    editor.selectionCount >= 2 ? "多個物件" : "無選取項目",
                    systemImage: "textformat",
                    description: Text("選擇單一文字框或形狀時，可用格式面板編輯。")
                )
            }
        }
        // Opening 格式 on a table means the table is the question being asked.
        .onAppear {
            if editor.selectedObject?.isTable == true { tab = .table }
        }
        .navigationTitle("格式")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成", systemImage: "checkmark") { dismiss() }
            }
        }
        .onDisappear { finishInteractionNow() }
        // Presented from the panel itself, not from the row inside the Form: a
        // sheet hosted by a list row goes away with the row, and a Form row is
        // free to be rebuilt whenever the editor publishes a change — which
        // read as the picker snapping shut the instant it opened.
        .sheet(isPresented: $showsFontPicker) {
            if let object = editor.selectedObject,
               let rich = object.richText ?? editor.formattingRichText(for: object.id) {
                SystemFontPicker(
                    selected: FontCatalog.familyName(forPostScriptName: currentStyle(rich).fontName)
                ) { descriptor in
                    applyRunStyle(object) { $0.fontName = FontCatalog.postScriptName(for: descriptor) }
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Tabs

    @ViewBuilder
    private func textFormatting(_ object: CanvasObject, _ rich: RichText) -> some View {
        VStack(spacing: 0) {
            Picker("分頁", selection: Binding(
                get: { effectiveTab(for: object) },
                set: { tab = $0 }
            )) {
                // 表格 sits left of 字體 because it is the coarser question:
                // how many cells there are before what is inside one.
                if object.isTable {
                    Text("表格").tag(Tab.table)
                }
                Text("字體").tag(Tab.font)
                Text("段落").tag(Tab.paragraph)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 10)
            // The tab strip sits outside the Form, so it would otherwise draw
            // on the plain sheet background and leave a visible seam where the
            // Form's grouped background starts.
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground))

            Form {
                if editor.formattingRange != nil {
                    Section {
                        Label("只套用到選取的文字。", systemImage: "textformat.abc")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if let range = editor.tableRange(for: object.id) {
                    // Same reason as the note above: 「這幾格」 and 「這張表」 are
                    // different commands, and the panel has to say which one it
                    // is about to run.
                    Section {
                        Label(
                            range.isSingleCell
                                ? "只套用到選取的儲存格。"
                                : "只套用到選取的 \(range.cellCount) 格。",
                            systemImage: "tablecells"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
                switch effectiveTab(for: object) {
                case .table:
                    if let table = object.table {
                        tableStructureSection(object, table)
                        tableColumnSection(object, table)
                        tableRowSection(object, table)
                        tableBorderSection(object, table)
                    }
                case .font:
                    fontSection(object, rich)
                    styleSection(object, rich)
                    languageSection(object, rich)
                case .paragraph:
                    paragraphSection(object, rich)
                }
            }
        }
    }

    /// The tab that is actually showing. A table's tab has to fall back when
    /// the selection moves to a text box, or the panel would come up empty.
    private func effectiveTab(for object: CanvasObject) -> Tab {
        if tab == .table, !object.isTable { return .font }
        return tab
    }

    // MARK: - Table

    /// The block the table commands are aimed at: the cell being edited, the
    /// block picked out on the canvas, or the last cell so the buttons always
    /// mean something even with nothing pointed at.
    private func targetRange(_ object: CanvasObject, _ table: TableContent) -> TableCellRange {
        editor.tableCommandRange(for: object.id)
            ?? TableCellRange(TableCellAddress(row: table.rowCount - 1, column: table.columnCount - 1))
    }

    /// "第 3 列" for one, "第 2–4 列" for several. The commands act on whatever
    /// this says, so it is written out rather than left to be inferred.
    private func label(_ range: ClosedRange<Int>, unit: String) -> String {
        range.count == 1
            ? "第 \(range.lowerBound + 1) \(unit)"
            : "第 \(range.lowerBound + 1)–\(range.upperBound + 1) \(unit)"
    }

    @ViewBuilder
    private func tableStructureSection(_ object: CanvasObject, _ table: TableContent) -> some View {
        let range = targetRange(object, table)
        let rows = range.rowRange
        let columns = range.columnRange

        Section {
            LabeledContent("大小") {
                Text("\(table.rowCount) 列 × \(table.columnCount) 欄")
                    .monospacedDigit()
            }

            LabeledContent("選取") {
                Text("\(rows.count) 列 × \(columns.count) 欄")
                    .monospacedDigit()
            }

            // One row or column per click, whatever the selection spans: the
            // selection says where to insert, not how many.
            Button {
                editor.insertTableRows(object.id, at: rows.lowerBound, count: 1)
            } label: {
                Label("在上方插入列", systemImage: "arrow.up.to.line")
            }
            Button {
                editor.insertTableRows(object.id, at: rows.upperBound + 1, count: 1)
            } label: {
                Label("在下方插入列", systemImage: "arrow.down.to.line")
            }
            Button {
                editor.insertTableColumns(object.id, at: columns.lowerBound, count: 1)
            } label: {
                Label("在左方插入欄", systemImage: "arrow.left.to.line")
            }
            Button {
                editor.insertTableColumns(object.id, at: columns.upperBound + 1, count: 1)
            } label: {
                Label("在右方插入欄", systemImage: "arrow.right.to.line")
            }

            Button(role: .destructive) {
                editor.removeTableRows(object.id, rows)
            } label: {
                Label("刪除\(label(rows, unit: "列"))", systemImage: "trash")
            }
            .disabled(table.rowCount <= rows.count)

            Button(role: .destructive) {
                editor.removeTableColumns(object.id, columns)
            } label: {
                Label("刪除\(label(columns, unit: "欄"))", systemImage: "trash")
            }
            .disabled(table.columnCount <= columns.count)
        } header: {
            Text("結構")
        } footer: {
            Text("以\(label(rows, unit: "列"))、\(label(columns, unit: "欄"))為準；在畫布上點一格即可換基準，拖曳選取範圍兩端的把手可選取整列或整欄。")
        }
    }

    @ViewBuilder
    private func tableColumnSection(_ object: CanvasObject, _ table: TableContent) -> some View {
        let range = targetRange(object, table)
        let columns = range.columnRange
        let widths = TableLayout.columnWidths(table, width: object.size.width)
        let column = min(columns.lowerBound, table.columnCount - 1)

        Section(label(columns, unit: "欄")) {
            Picker("對齊", selection: Binding(
                get: { table.columns[column].alignment },
                set: { editor.setTableColumnsAlignment(object.id, columns: columns, alignment: $0) }
            )) {
                ForEach(TextAlignment.columnChoices, id: \.self) { choice in
                    Label(choice.label, systemImage: choice.symbolName).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            // Widening one column narrows its neighbour: the table's own width
            // is set by the object's box and does not move here. A block of
            // columns has no single width to show, so this stays on the first.
            DotStepperField(title: columns.count == 1 ? "寬" : "第 \(column + 1) 欄寬", value: widths[column]) { newValue in
                editor.setTableColumnWidth(object.id, column: column, width: newValue)
            }
            .disabled(table.columnCount <= 1)

            Button {
                editor.equalizeTableColumns(object.id)
            } label: {
                Label("平均分配欄寬", systemImage: "equal.square")
            }
        }
    }

    @ViewBuilder
    private func tableRowSection(_ object: CanvasObject, _ table: TableContent) -> some View {
        let range = targetRange(object, table)
        let rows = range.rowRange
        let heights = TableLayout.rowHeights(table, width: object.size.width)
        let fitted = TableLayout.fittedRowHeights(table, width: object.size.width)
        let row = min(rows.lowerBound, table.rowCount - 1)
        let isAutomatic = rows.allSatisfy { $0 >= table.rowHeights.count || table.rowHeights[$0] <= 0 }

        Section {
            // A row can be pinned taller than its text but never shorter — the
            // words have nowhere to go — so this field's floor is what the text
            // measures to, and typing less than that means 自動.
            DotStepperField(title: rows.count == 1 ? "高" : "每列高", value: heights[row]) { newValue in
                for index in rows {
                    let floor = index < fitted.count ? fitted[index] : 0
                    editor.setTableRowHeight(object.id, row: index, height: newValue <= floor ? nil : newValue)
                }
            }

            Button {
                for index in rows {
                    editor.setTableRowHeight(object.id, row: index, height: nil)
                }
            } label: {
                Label("依內容自動", systemImage: "arrow.up.and.down.square")
            }
            .disabled(isAutomatic)
        } header: {
            Text(label(rows, unit: "列"))
        } footer: {
            Text(isAutomatic
                 ? "列高依內容決定；拖曳表格左側的把手可加高。"
                 : "已固定列高。縮回內容高度即回到自動。")
        }
    }

    @ViewBuilder
    private func tableBorderSection(_ object: CanvasObject, _ table: TableContent) -> some View {
        Section("外觀") {
            Picker("框線", selection: Binding(
                get: { table.borderStyle },
                set: { editor.setTableBorderStyle(object.id, $0) }
            )) {
                ForEach(TableBorderStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)

            Stepper(value: Binding(
                get: { table.borderWidth },
                set: { editor.setTableBorderWidth(object.id, $0) }
            ), in: 0...12, step: 0.5) {
                HStack {
                    Text("線寬")
                    Spacer()
                    Text("\(Double(table.borderWidth).formatted(.number.precision(.fractionLength(0...1)))) 點")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(table.borderStyle == .none)

            Stepper(value: Binding(
                get: { table.cellPadding },
                set: { editor.setTableCellPadding(object.id, $0) }
            ), in: 0...40, step: 1) {
                HStack {
                    Text("儲存格內距")
                    Spacer()
                    Text("\(Int(table.cellPadding.rounded())) 點")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Shape

    @ViewBuilder
    private func shapeSection(_ object: CanvasObject, _ shape: ShapeContent) -> some View {
        Section("圖形") {
            Picker("形狀", selection: Binding(
                get: { shape.kind },
                set: { newValue in
                    editor.updateObject(object.id) {
                        guard case .shape(var content) = $0.content else { return }
                        content.kind = newValue
                        $0.content = .shape(content)
                    }
                }
            )) {
                Text("矩形").tag(ShapeKind.rectangle)
                Text("圓形").tag(ShapeKind.ellipse)
                Text("線條").tag(ShapeKind.line)
            }

            DotStepperField(
                title: "寬度",
                value: shape.strokeWidth,
                commit: { newValue in
                    editor.updateObject(object.id) {
                        guard case .shape(var content) = $0.content else { return }
                        content.strokeWidth = max(0, newValue)
                        $0.content = .shape(content)
                    }
                },
                nudge: { delta in
                    nudging {
                        editor.updateObject(object.id) {
                            guard case .shape(var content) = $0.content else { return }
                            content.strokeWidth = max(0, content.strokeWidth + delta)
                            $0.content = .shape(content)
                        }
                    }
                }
            )

            Toggle("填滿", isOn: Binding(
                get: { shape.filled },
                set: { newValue in
                    editor.updateObject(object.id) {
                        guard case .shape(var content) = $0.content else { return }
                        content.filled = newValue
                        $0.content = .shape(content)
                    }
                }
            ))

            if shape.kind == .rectangle {
                DotStepperField(
                    title: "圓角",
                    value: shape.cornerRadius,
                    commit: { newValue in
                        editor.updateObject(object.id) {
                            guard case .shape(var content) = $0.content else { return }
                            content.cornerRadius = max(0, newValue)
                            $0.content = .shape(content)
                        }
                    },
                    nudge: { delta in
                        nudging {
                            editor.updateObject(object.id) {
                                guard case .shape(var content) = $0.content else { return }
                                content.cornerRadius = max(0, content.cornerRadius + delta)
                                $0.content = .shape(content)
                            }
                        }
                    }
                )
            }

            Toggle("虛線", isOn: Binding(
                get: { !shape.dashPattern.isEmpty },
                set: { newValue in
                    editor.updateObject(object.id) {
                        guard case .shape(var content) = $0.content else { return }
                        // A dash pattern is a list, but the panel only offers
                        // on/off; a custom pattern editor would be a lot of UI
                        // for something nobody has asked for on 48 mm paper.
                        content.dashPattern = newValue ? [6, 4] : []
                        $0.content = .shape(content)
                    }
                }
            ))
        }
    }

    private func nudging(_ change: () -> Void) {
        editor.beginInteraction()
        change()
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            editor.endInteraction()
        }
    }

    private func finishInteractionNow() {
        settleTask?.cancel()
        settleTask = nil
        editor.endInteraction()
    }

    // MARK: - Font

    @ViewBuilder
    private func fontSection(_ object: CanvasObject, _ rich: RichText) -> some View {
        let style = currentStyle(rich)
        let family = FontCatalog.familyName(forPostScriptName: style.fontName)

        Section("字體") {
            Button {
                showsFontPicker = true
            } label: {
                HStack {
                    Text("字體")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(family)
                        .font(Font(FontCatalog.previewFont(postScriptName: style.fontName, size: 17)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }

            let faces = FontCatalog.faces(inFamily: family)
            if faces.count > 1 {
                Picker("字重", selection: Binding(
                    get: { faces.contains(style.fontName) ? style.fontName : (faces.first ?? style.fontName) },
                    set: { newValue in applyRunStyle(object) { $0.fontName = newValue } }
                )) {
                    ForEach(faces, id: \.self) { name in
                        Text(FontCatalog.faceLabel(postScriptName: name, family: family))
                            .tag(name)
                    }
                }
            }

            sizeRow(object, style)
        }
    }

    @ViewBuilder
    private func sizeRow(_ object: CanvasObject, _ style: RunStyle) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("大小")
                Spacer()
                Text("\(Int(style.fontSize.rounded())) 點")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // The model allows sizes far past anything that fits on 48 mm paper,
            // and stretching the slider to cover them would make every ordinary
            // size a two-pixel move. The track ends where the paper does, and
            // only grows when a document already carries something larger.
            // 此處應插入經典機型硬體衍生的字級上限。
            let upper = style.fontSize.rounded(.up)
            HStack(spacing: 8) {
                Text("4").font(.caption2).foregroundStyle(.tertiary)
                Slider(
                    value: Binding(
                        get: { Double(min(max(style.fontSize, 4), upper)) },
                        set: { raw in
                            let rounded = CGFloat(raw.rounded())
                            applyRunStyle(object) { $0.fontSize = max(4, rounded) }
                        }
                    ),
                    in: 4...Double(upper),
                    onEditingChanged: { editing in
                        // One undo entry per drag, not per pixel of travel.
                        if editing { editor.beginInteraction() } else { editor.endInteraction() }
                    }
                )
                Text("\(Int(upper))").font(.caption2).foregroundStyle(.tertiary)
            }
            // Cap height, not em size, is what the eye measures on paper; the
            // usual Latin/CJK ratio is around 0.7 em, close enough to be useful
            // and honest about being approximate.
            Text("字身約 \(CanvasMetrics.lengthDescription(dots: style.fontSize))，實際字高約 \(CanvasMetrics.lengthDescription(dots: style.fontSize * 0.7))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Style toggles

    @ViewBuilder
    private func styleSection(_ object: CanvasObject, _ rich: RichText) -> some View {
        let style = currentStyle(rich)
        Section("樣式") {
            StyleChoiceBar(options: [
                .init(label: "粗體", systemImage: "bold", isOn: style.bold) { on in
                    applyRunStyle(object) { $0.bold = on }
                },
                .init(label: "斜體", systemImage: "italic", isOn: style.italic) { on in
                    applyRunStyle(object) { $0.italic = on }
                },
                .init(label: "底線", systemImage: "underline", isOn: style.underline) { on in
                    applyRunStyle(object) { $0.underline = on }
                },
                .init(label: "刪除線", systemImage: "strikethrough", isOn: style.strikethrough) { on in
                    applyRunStyle(object) { $0.strikethrough = on }
                },
            ])
        }
    }

    // MARK: - Paragraph

    @ViewBuilder
    private func paragraphSection(_ object: CanvasObject, _ rich: RichText) -> some View {
        let paragraph = rich.leadingParagraphStyle

        Section("段落") {
            Picker("對齊", selection: Binding(
                get: { paragraph.alignment },
                set: { newValue in applyParagraphStyle(object) { $0.alignment = newValue } }
            )) {
                ForEach(TextAlignment.allCases, id: \.self) { choice in
                    Label(choice.label, systemImage: choice.symbolName).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            LineHeightSlider(
                value: paragraph.lineHeightMultiple,
                onChange: { newValue in applyParagraphStyle(object) { $0.lineHeightMultiple = newValue } }
            )

            Stepper(value: Binding(
                get: { paragraph.spacingBefore },
                set: { newValue in applyParagraphStyle(object) { $0.spacingBefore = max(0, newValue) } }
            ), in: 0...400, step: 2) {
                HStack {
                    Text("段落之前")
                    Spacer()
                    Text("\(Int(paragraph.spacingBefore.rounded())) 點")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Stepper(value: Binding(
                get: { paragraph.spacingAfter },
                set: { newValue in applyParagraphStyle(object) { $0.spacingAfter = max(0, newValue) } }
            ), in: 0...400, step: 2) {
                HStack {
                    Text("段落之後")
                    Spacer()
                    Text("\(Int(paragraph.spacingAfter.rounded())) 點")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Language

    @ViewBuilder
    private func languageSection(_ object: CanvasObject, _ rich: RichText) -> some View {
        let style = currentStyle(rich)
        // No GSUB table means no `locl` feature, and the picker would be a
        // control that provably does nothing. Hide it rather than lie.
        if FontCatalog.hasGSUB(postScriptName: style.fontName) {
            Section {
                Picker("地區變體", selection: Binding<String?>(
                    get: { RunStyle.normalizedLanguageTag(style.languageTag) },
                    set: { newValue in applyRunStyle(object) { $0.languageTag = newValue } }
                )) {
                    Text("不指定").tag(String?.none)
                    Text("繁體中文").tag(String?.some("zh-Hant"))
                    Text("簡體中文").tag(String?.some("zh-Hans"))
                    Text("日文").tag(String?.some("ja"))
                    Text("韓文").tag(String?.some("ko"))
                }
            } header: {
                Text("地區變體")
            }
        }
    }

    // MARK: - Applying

    /// Rewrites the selected characters, or every run in the object when there
    /// is no selection to talk about.
    ///
    /// The two cases are one function on purpose: the controls are identical,
    /// and which characters they land on is a property of how the panel was
    /// opened, not of the control the thumb hit.
    private func applyRunStyle(_ object: CanvasObject, _ transform: (inout RunStyle) -> Void) {
        editor.updateFormattingRunStyle(for: object.id, transform)
    }

    private func applyParagraphStyle(_ object: CanvasObject, _ transform: (inout ParagraphStyle) -> Void) {
        editor.updateFormattingParagraphStyle(for: object.id, transform)
    }

    /// The style the controls should show: what the selected characters share,
    /// or the box's leading style when the whole box is the target.
    private func currentStyle(_ rich: RichText) -> RunStyle {
        guard let id = editor.selectedID else { return rich.leadingRunStyle }
        return editor.formattingRunStyle(for: id) ?? rich.leadingRunStyle
    }
}

// MARK: - Style choices

/// Bold and italic are not alternatives to each other, so `Picker` — which can
/// only ever hold one answer — is the wrong shape. A multiple-selection
/// segmented control exists only on AppKit (`NSSegmentedControl` with
/// `trackingMode = .selectAny`); on iOS there is no such thing, and the one in
/// Pages is a private drawing job.
///
/// So this is four `Toggle`s in button style, sized to equal widths. Selected
/// fill, press animation, material, and the VoiceOver "selected" trait all come
/// from the system and keep following it across OS releases — which a hand-drawn
/// row of `Button`s would not.
private struct StyleChoiceBar: View {

    struct Option: Identifiable {
        let label: String
        let systemImage: String
        let isOn: Bool
        let toggle: (Bool) -> Void

        var id: String { label }
    }

    let options: [Option]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options) { option in
                Toggle(isOn: Binding(
                    get: { option.isOn },
                    set: { option.toggle($0) }
                )) {
                    Image(systemName: option.systemImage)
                        .frame(maxWidth: .infinity)
                }
                .toggleStyle(.button)
                .accessibilityLabel(option.label)
            }
        }
        .labelStyle(.iconOnly)
    }
}

// MARK: - Line height

/// 1.0 is the neutral value and the one users overshoot most, so the slider has
/// a detent there: the thumb sticks briefly as it crosses and lands on exactly
/// 1.0. Same behaviour as LOCL's line-spacing wheel.
private struct LineHeightSlider: View {

    let value: CGFloat
    let onChange: (CGFloat) -> Void

    @EnvironmentObject private var editor: EditorState

    private static let detent: CGFloat = 1.0
    private static let detentWidth: CGFloat = 0.06

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("行高")
                Spacer()
                Text(String(format: "%.1f×", value))
                    .monospacedDigit()
                    .foregroundStyle(value == Self.detent ? .secondary : .primary)
            }
            HStack(spacing: 8) {
                Text("0.8").font(.caption2).foregroundStyle(.tertiary)
                Slider(
                    value: Binding(
                        get: { Double(value) },
                        set: { raw in onChange(snap(CGFloat(raw))) }
                    ),
                    in: 0.8...2.0,
                    onEditingChanged: { editing in
                        // One undo entry per drag, not per pixel of travel.
                        if editing { editor.beginInteraction() } else { editor.endInteraction() }
                    }
                )
                Text("2.0").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func snap(_ raw: CGFloat) -> CGFloat {
        if abs(raw - Self.detent) < Self.detentWidth { return Self.detent }
        return (raw * 10).rounded() / 10
    }
}

// MARK: - Font family picker

/// The hand-rolled list could only offer what `UIFont.familyNames` had already
/// handed the process, which leaves out every font the system keeps on demand —
/// most of the CJK families among them. `UIFontPickerViewController` is the
/// system's own catalogue: it lists those, downloads one when it is picked, and
/// comes with its own search field.
private struct SystemFontPicker: UIViewControllerRepresentable {

    let selected: String
    let onPick: (UIFontDescriptor) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIFontPickerViewController {
        let configuration = UIFontPickerViewController.Configuration()
        // Faces stay with the panel's own 字重／字樣 row, so the picker only has
        // to answer which family.
        configuration.includeFaces = false
        configuration.displayUsingSystemFont = false
        let controller = UIFontPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        controller.selectedFontDescriptor = UIFontDescriptor(fontAttributes: [.family: selected])
        controller.title = "選擇字體"
        return controller
    }

    func updateUIViewController(_ controller: UIFontPickerViewController, context: Context) {
        context.coordinator.onPick = onPick
    }

    final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {

        var onPick: (UIFontDescriptor) -> Void

        init(onPick: @escaping (UIFontDescriptor) -> Void) {
            self.onPick = onPick
        }

        func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
            guard let descriptor = viewController.selectedFontDescriptor else { return }
            onPick(descriptor)
            viewController.dismiss(animated: true)
        }

        func fontPickerViewControllerDidCancel(_ viewController: UIFontPickerViewController) {
            viewController.dismiss(animated: true)
        }
    }
}

// MARK: - Font catalog

enum FontCatalog {

    /// A family the system only just downloaded is not always in
    /// `UIFont.fontNames(forFamilyName:)` yet, so fall back to asking CoreText
    /// to match the family rather than showing an empty face list.
    static func faces(inFamily family: String) -> [String] {
        let listed = UIFont.fontNames(forFamilyName: family)
        let names = listed.isEmpty ? matchedFaces(inFamily: family) : listed
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func matchedFaces(inFamily family: String) -> [String] {
        let query = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let matches = CTFontDescriptorCreateMatchingFontDescriptors(query, Set([kCTFontFamilyNameAttribute]) as CFSet)
        guard let matches = matches as? [CTFontDescriptor] else { return [] }
        return matches.compactMap {
            CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String
        }
    }

    /// What the system picker hands back is a family, not a face; the run style
    /// stores PostScript names.
    static func postScriptName(for descriptor: UIFontDescriptor) -> String {
        if let name = descriptor.fontAttributes[.name] as? String, !name.isEmpty {
            return name
        }
        let family = descriptor.fontAttributes[.family] as? String ?? descriptor.postscriptName
        return preferredFace(inFamily: family)
    }

    static func preferredFace(inFamily family: String) -> String {
        let names = faces(inFamily: family)
        if let regular = names.first(where: { $0.localizedCaseInsensitiveContains("Regular") }) {
            return regular
        }
        return names.first ?? family
    }

    static func familyName(forPostScriptName name: String) -> String {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        return CTFontCopyFamilyName(font) as String
    }

    static func faceLabel(postScriptName: String, family: String) -> String {
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        if let style = CTFontCopyName(font, kCTFontStyleNameKey) as String? {
            return style
        }
        return postScriptName
    }

    static func previewFont(family: String, size: CGFloat) -> CTFont {
        CTFontCreateWithName(preferredFace(inFamily: family) as CFString, size, nil)
    }

    static func previewFont(postScriptName: String, size: CGFloat) -> CTFont {
        CTFontCreateWithName(postScriptName as CFString, size, nil)
    }

    /// `locl` lives in GSUB. No GSUB, no regional variants worth offering.
    static func hasGSUB(postScriptName: String) -> Bool {
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        return CTFontCopyTable(font, CTFontTableTag(0x47535542), []) != nil
    }
}

// MARK: - Alignment presentation

extension TextAlignment {

    /// The SF Symbol that *is* the setting. Named alignments read as a word
    /// puzzle at segmented-control width; the glyphs are the same ones every
    /// other text editor on the platform uses, so they need no learning.
    var symbolName: String {
        switch self {
        case .left: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        case .justified: return "text.justify"
        }
    }

    /// Kept for VoiceOver and for menus, where there is room for words.
    var label: String {
        switch self {
        case .left: return "靠左"
        case .center: return "置中"
        case .right: return "靠右"
        case .justified: return "左右對齊"
        }
    }

    /// A table column has no justification: cells are single values, and
    /// stretching one across the column is never what the user meant.
    static var columnChoices: [TextAlignment] { [.left, .center, .right] }

    /// The next setting in the round the toolbar button cycles through.
    var nextInCycle: TextAlignment {
        switch self {
        case .left: return .center
        case .center: return .right
        case .right: return .justified
        case .justified: return .left
        }
    }
}
