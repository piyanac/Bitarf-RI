//
//  DocumentSettingsPanel.swift
//  Bitarf RI
//
//  Everything that belongs to the strip of paper rather than to one object.
//
//  The print settings shown here are the *same* settings the print preview
//  shows, using the same words, because they are one value in one document.
//  Two screens describing the same switch differently is how a user ends up
//  believing there are two switches.
//

import CoreGraphics
import SwiftUI

struct DocumentSettingsPanel: View {

    @EnvironmentObject var editor: EditorState

    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        Form {
            titleSection
            DocumentSettingsForm(
                orientation: Binding(
                    get: { editor.document.orientation },
                    set: { editor.setOrientation($0) }
                ),
                fixedAxisDots: Binding(
                    get: { editor.document.fixedAxisDots },
                    set: { editor.setFixedAxis($0) }
                ),
                margin: Binding(
                    get: { editor.document.margin },
                    set: { editor.setMargin($0) }
                ),
                dither: Binding(
                    get: { editor.document.dither },
                    set: { editor.setDither($0) }
                ),
                threshold: Binding(
                    get: { Int(editor.document.threshold) },
                    set: { editor.setThreshold($0) }
                )
                // 此處應插入經典機型的濃度與尾端走紙 bindings。
            )
            summarySection
        }
        .navigationTitle("文件設定")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { title = editor.document.title }
        .onChange(of: editor.document.title) { _, newValue in
            if !titleFocused { title = newValue }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(role: .confirm) { dismiss() }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成", systemImage: "checkmark") { titleFocused = false }
            }
        }
    }

    // MARK: - Title

    private var titleSection: some View {
        Section("名稱") {
            // UIKit's `clearButtonMode` never surfaced in SwiftUI's TextField and
            // there is still no modifier for it, so the button is drawn — but
            // drawn to the system's shape: the same glyph, the same grey, and
            // only while there is something to clear.
            HStack(spacing: 8) {
                TextField("未命名", text: $title)
                    .focused($titleFocused)
                    .submitLabel(.done)
                    .onSubmit { commitTitle() }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused { commitTitle() }
                    }

                if !title.isEmpty {
                    Button {
                        title = ""
                        // Clearing is meant to be the start of typing a new
                        // name, not a rename to 未命名 — so the caret stays and
                        // the document keeps its old title until the field is
                        // committed.
                        titleFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除文字")
                }
            }
        }
    }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = trimmed.isEmpty ? "未命名" : trimmed
        title = final
        if final != editor.document.title { editor.setTitle(final) }
    }

    // MARK: - Summary

    private var summarySection: some View {
        let document = editor.document
        let width = Int(document.canvasWidth.rounded())
        let height = Int(document.canvasHeight.rounded())
        return Section {
            LabeledContent("物件數量") {
                Text("\(document.objects.count)").monospacedDigit()
            }
            LabeledContent("目前長度") {
                Text(document.physicalLengthDescription).monospacedDigit()
            }
            LabeledContent("點陣尺寸") {
                Text("\(width) × \(height) 點").monospacedDigit()
            }
            LabeledContent("每列位元組") {
                Text("\(CanvasMetrics.bytesPerRow(fixedAxisDots: document.fixedAxisDots))")
                    .monospacedDigit()
            }
        } header: {
            Text("摘要")
        }
    }
}

// MARK: - Presets

// 此處應插入經典機型的紙張固定軸 presets 與對應點數。

// MARK: - Shared settings form

/// Every setting that belongs to the strip of paper rather than to one object,
/// as plain bindings.
///
/// It is one view rather than two similar ones because the app now shows these
/// controls twice — once for the document being edited, once for what a new
/// document starts as — and two copies of the same list is how the wording,
/// the ranges and the step sizes drift apart until they read as two features.
struct DocumentSettingsForm: View {

    @Binding var orientation: CanvasOrientation
    @Binding var fixedAxisDots: Int
    @Binding var margin: CGFloat
    @Binding var dither: DitherAlgorithm
    @Binding var threshold: Int
    // 此處應插入經典機型的濃度與尾端走紙 bindings。

    /// True when these bindings describe the *next* document rather than the one
    /// on screen. Only the wording changes — a footer saying 「跟著文件走」 under a
    /// control that has no document yet is the kind of sentence that makes a
    /// user go looking for the document it means.
    var describesDefaults = false

    // 此處應插入經典機型固定軸 preset 的自訂狀態。

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        editorSection
        marginSection
        printSection
    }

    // MARK: - Editor

    private var fixedAxisLabel: String {
        orientation.isPortrait ? "紙寬（固定軸）" : "紙高（固定軸）"
    }

    private var isCustomFixedAxis: Bool {
        prefersCustomFixedAxis || FixedAxisPreset.matching(fixedAxisDots) == .custom
    }

    private var orientationLabel: String {
        orientation.isPortrait ? "直向" : "橫向"
    }

    /// A segmented control pulls the plain `Image` out of each segment and drops
    /// any modifier wrapped around it, so a `rotationEffect` never survives the
    /// trip. Drawing the symbol once and handing over the finished template image
    /// is the only way to get a turned symbol in there; the control still tints it
    /// for the selected state like any other symbol.
    @MainActor
    private func orientationSymbol(_ name: String, rotation: Angle = .zero) -> Image {
        let content = Image(systemName: name)
            .font(.system(size: 17))
            .rotationEffect(rotation)
            .foregroundStyle(.black)

        let renderer = ImageRenderer(content: content)
        renderer.scale = displayScale

        guard let rendered = renderer.uiImage?.withRenderingMode(.alwaysTemplate) else {
            return Image(systemName: name)
        }
        return Image(uiImage: rendered)
    }

    private var editorSection: some View {
        Section {
            LabeledContent("方向") {
                HStack(spacing: 12) {
                    // The row still reads as a value, the way every other row in
                    // this form does; the symbols are only how you change it.
                    Text(orientationLabel)
                    Picker("方向", selection: $orientation) {
                        orientationSymbol("arrow.up.and.person.rectangle.portrait")
                            .accessibilityLabel("直向")
                            .tag(CanvasOrientation.portrait)
                        orientationSymbol("arrow.up.and.person.rectangle.turn.left",
                                          rotation: .degrees(90))
                            .accessibilityLabel("橫向")
                            .tag(CanvasOrientation.landscape)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 108)
                }
            }

            // 此處應插入經典機型的固定軸 preset、自訂範圍與物理寬度 UI。
        } header: {
            Text("編輯器")
        } footer: {
            if isCustomFixedAxis {
                Text("固定軸以 8 點為一個級距，因為列印資料每 8 點打包成 1 個位元組。")
            }
        }
    }

    // MARK: - Margin

    private var marginSection: some View {
        Section {
            Stepper(value: $margin, in: 0...64, step: 1) {
                HStack {
                    Text("邊界")
                    Spacer()
                    Text("\(Int(margin.rounded())) 點")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("換算") {
                Text(CanvasMetrics.lengthDescription(dots: margin))
                    .monospacedDigit()
            }
        } footer: {
            Text("對齊參考用，不會裁切列印內容。")
        }
    }

    // MARK: - Print

    private var printSection: some View {
        Section {
            Picker("遞色", selection: $dither) {
                ForEach(DitherAlgorithm.allCases, id: \.self) { algorithm in
                    Text(algorithm.displayName).tag(algorithm)
                }
            }
            Text(dither.shortDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)

            // Only the two hard-cut modes have a cut point; showing the slider
            // beside a diffusion mode would promise a control that does nothing.
            if dither == .threshold || dither == .none {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("臨界值")
                        Spacer()
                        Text("\(threshold)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(threshold) },
                            set: { threshold = Int($0.rounded()) }
                        ),
                        in: 1...254,
                        step: 1
                    )
                    Text("調高會讓更多灰階變成黑點，線稿變粗；調低則相反。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            // 此處應插入經典機型的濃度、尾端走紙與物理長度控制。
        } header: {
            Text("列印")
        } footer: {
            Text(describesDefaults
                 ? "新增的文件採用這些設定。仍可在編輯畫面的「文件設定」單獨修改。"
                 : "這些設定只影響此文件。")
        }
    }
}
