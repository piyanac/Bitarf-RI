//
//  InspectorPanel.swift
//  Bitarf RI
//
//  Type the number when the finger cannot be trusted.
//
//  One dot is 0.125 mm. No amount of drag smoothing makes a fingertip accurate
//  to that, so the inspector is not a convenience panel — it is the precision
//  half of the editor, and every value the canvas can change by dragging must
//  also be reachable here as a typed number and as a ±1 dot nudge that does not
//  require the keyboard at all.
//

import CoreGraphics
import SwiftUI

struct InspectorPanel: View {

    @EnvironmentObject var editor: EditorState

    @Environment(\.dismiss) private var dismiss

    /// Continuous edits (a burst of stepper taps) collapse into one undo entry.
    ///
    /// The rule is deliberately dumb: the first tap opens an interaction, and a
    /// timer closes it once the taps stop. A gesture-accurate begin/end is not
    /// available for discrete button taps, and anything cleverer would only
    /// change *where* the arbitrary boundary sits, not remove it.
    @State private var settleTask: Task<Void, Never>?

    /// A run of rotation nudges, held from its first tap.
    ///
    /// The whole burst behaves like one gesture: the objects and the point they
    /// turn about are captured once, each tap adds to a running total, and the
    /// result is always recomputed from the captured state. Reading the current
    /// objects and pivot on every tap instead would drift twice over — the union
    /// of a tilted set moves as it turns, and origins round to whole dots.
    @State private var rotationBurst: (objects: [CanvasObject], pivot: CGPoint, total: CGFloat)?

    private static let settleDelay: Duration = .milliseconds(700)

    var body: some View {
        Group {
            if let object = editor.selectedObject {
                Form {
                    positionSection(object)
                    sizeSection(object)
                    rotationSection(object)
                    alignmentSection(object)
                    contentSection(object)
                    layerSection(object)
                    stateSection(object)
                }
            } else if editor.selectionCount >= 2 {
                multiSelectionForm
            } else {
                ContentUnavailableView(
                    "沒有選取物件",
                    systemImage: "hand.tap",
                    description: Text("在畫布上點一下任何物件，或從圖層清單挑一個來修改其排列屬性。")
                )
            }
        }
        .navigationTitle("排列")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成", systemImage: "checkmark") { dismiss() }
            }
        }
        .onDisappear { finishInteractionNow() }
    }

    // MARK: - Multiple selection

    /// What a set can be told to do. Everything here reads the union of the
    /// selection, and everything here leaves locked members where they are —
    /// they anchor the operation without joining it, which is usually why they
    /// were locked.
    @ViewBuilder
    private var multiSelectionForm: some View {
        let union = SelectionGeometry.unionBoundingBox(editor.selectedObjects)
        let isPortrait = editor.document.orientation.isPortrait
        Form {
            Section("已選 \(editor.selectionCount) 個物件") {
                DotStepperField(title: "X", value: union.minX, isEditable: false) { _ in }
                DotStepperField(title: "Y", value: union.minY, isEditable: false) { _ in }
                DotStepperField(title: "寬", value: union.width, isEditable: false) { _ in }
                DotStepperField(title: "高", value: union.height, isEditable: false) { _ in }
            }

            Section {
                HStack {
                    alignButton("靠左", "align.horizontal.left", .left)
                    alignButton("水平置中", "align.horizontal.center", .centerX)
                    alignButton("靠右", "align.horizontal.right", .right)
                }
                HStack {
                    alignButton("靠上", "align.vertical.top", .top)
                    alignButton("垂直置中", "align.vertical.center", .centerY)
                    alignButton("靠下", "align.vertical.bottom", .bottom)
                }
            } header: {
                Text("互相對齊")
            } footer: {
                Text("以整個選取範圍為基準。鎖定的物件不會移動，但仍然算進範圍裡。")
            }

            Section {
                Button("水平平均間距") { editor.distributeSelection(.horizontal) }
                Button("垂直平均間距") { editor.distributeSelection(.vertical) }
            } header: {
                Text("平均分佈")
            } footer: {
                if editor.selectionCount < 3 {
                    Text("需要三個以上物件。")
                }
            }
            .disabled(editor.selectionCount < 3)

            Section {
                // Landscape turns the paper a quarter turn: the fixed 48 ㎜ axis
                // becomes vertical and the roll runs to the right. So these
                // three are the cross axis whichever way round it is, and the
                // fourth is always the start of the roll.
                HStack {
                    if isPortrait {
                        paperAlignButton("靠左", "align.horizontal.left", .left)
                        paperAlignButton("置中", "align.horizontal.center", .centerX)
                        paperAlignButton("靠右", "align.horizontal.right", .right)
                    } else {
                        paperAlignButton("靠上", "align.vertical.top", .top)
                        paperAlignButton("置中", "align.vertical.center", .centerY)
                        paperAlignButton("靠下", "align.vertical.bottom", .bottom)
                    }
                }
                Button(isPortrait ? "對齊上緣" : "對齊左緣") {
                    editor.alignSelection(
                        isPortrait ? .top : .left,
                        within: editor.document.contentRect,
                        asGroup: true
                    )
                }
            } header: {
                Text("對齊紙張")
            }

            Section {
                HStack {
                    rotateButton("−1°", by: -1)
                    rotateButton("+1°", by: 1)
                    rotateButton("−90°", by: -90)
                    rotateButton("+90°", by: 90)
                }
            } header: {
                Text("旋轉")
            }

            Section("圖層") {
                Button("最前", systemImage: "square.3.layers.3d.top.filled") {
                    editor.bringSelectionToFront()
                }
                Button("往前", systemImage: "square.2.layers.3d.top.filled") { editor.bringSelectionForward() }
                Button("往後", systemImage: "square.2.layers.3d.bottom.filled") { editor.sendSelectionBackward() }
                Button("最後", systemImage: "square.3.layers.3d.bottom.filled") {
                    editor.sendSelectionToBack()
                }
            }

            Section {
                // A mixed set reads as off, so the first tap turns the whole
                // selection on rather than inverting each member — inverting
                // would leave the set as mixed as it started.
                Toggle("全部鎖定", isOn: Binding(
                    get: { editor.selectedObjects.allSatisfy(\.isLocked) },
                    set: { editor.setSelectionLocked($0) }
                ))
                Toggle("全部隱藏", isOn: Binding(
                    get: { editor.selectedObjects.allSatisfy(\.isHidden) },
                    set: { editor.setSelectionHidden($0) }
                ))
            } header: {
                Text("狀態")
            }
        }
    }

    @ViewBuilder
    private func alignButton(_ title: String, _ symbol: String, _ edge: AlignmentEdge) -> some View {
        Button {
            editor.alignSelection(edge)
        } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private func paperAlignButton(_ title: String, _ symbol: String, _ edge: AlignmentEdge) -> some View {
        Button {
            editor.alignSelection(edge, within: editor.document.contentRect, asGroup: true)
        } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private func rotateButton(_ title: String, by degrees: CGFloat) -> some View {
        Button(title) {
            nudging {
                var burst = rotationBurst ?? {
                    let objects = editor.selectedObjects
                    let union = SelectionGeometry.unionBoundingBox(objects)
                    return (objects: objects, pivot: CGPoint(x: union.midX, y: union.midY), total: 0)
                }()
                burst.total += degrees * .pi / 180
                rotationBurst = burst
                editor.rotateSelection(by: burst.total, about: burst.pivot, from: burst.objects)
            }
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Position

    @ViewBuilder
    private func positionSection(_ object: CanvasObject) -> some View {
        Section("位置") {
            DotStepperField(
                title: "X",
                value: object.origin.x,
                commit: { newValue in
                    editor.updateObject(object.id) { $0.origin.x = newValue }
                },
                nudge: { delta in
                    nudging { editor.updateObject(object.id) { $0.origin.x += delta } }
                }
            )
            DotStepperField(
                title: "Y",
                value: object.origin.y,
                commit: { newValue in
                    editor.updateObject(object.id) { $0.origin.y = newValue }
                },
                nudge: { delta in
                    nudging { editor.updateObject(object.id) { $0.origin.y += delta } }
                }
            )
        }
    }

    // MARK: - Size

    @ViewBuilder
    private func sizeSection(_ object: CanvasObject) -> some View {
        Section {
            DotStepperField(
                title: "寬",
                value: object.size.width,
                commit: { newValue in
                    editor.updateObject(object.id) { $0.size.width = max(1, newValue) }
                },
                nudge: { delta in
                    nudging {
                        editor.updateObject(object.id) { $0.size.width = max(1, $0.size.width + delta) }
                    }
                }
            )

            if object.isText {
                DotStepperField(
                    title: "高",
                    value: object.size.height,
                    isEditable: false,
                    commit: { _ in }
                )
                Text("文字框的高度由內容決定。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("縮到剛好") {
                    editor.shrinkTextToFit(object.id)
                }
            } else {
                DotStepperField(
                    title: "高",
                    value: object.size.height,
                    commit: { newValue in
                        editor.updateObject(object.id) { $0.size.height = max(1, newValue) }
                    },
                    nudge: { delta in
                        nudging {
                            editor.updateObject(object.id) { $0.size.height = max(1, $0.size.height + delta) }
                        }
                    }
                )
            }
        } header: {
            Text("尺寸")
        }
    }

    // MARK: - Rotation

    @ViewBuilder
    private func rotationSection(_ object: CanvasObject) -> some View {
        Section("旋轉") {
            DegreeStepperField(
                degrees: degrees(from: object.rotation),
                commit: { newDegrees in
                    editor.updateObject(object.id) { $0.rotation = radians(from: newDegrees) }
                },
                nudge: { delta in
                    nudging {
                        editor.updateObject(object.id) {
                            $0.rotation = radians(from: degrees(from: $0.rotation) + delta)
                        }
                    }
                }
            )
            HStack {
                ForEach([CGFloat(0), 90, 180, 270], id: \.self) { angle in
                    Button("\(Int(angle))°") {
                        editor.updateObject(object.id) { $0.rotation = radians(from: angle) }
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - Alignment

    @ViewBuilder
    private func alignmentSection(_ object: CanvasObject) -> some View {
        let isPortrait = editor.document.orientation.isPortrait
        Section {
            HStack {
                Button {
                    align(object, .leading)
                } label: {
                    Label("靠左", systemImage: isPortrait ? "align.horizontal.left" : "align.vertical.top")
                        .labelStyle(.iconOnly)
                        .frame(maxWidth: .infinity)
                }
                Button {
                    align(object, .middle)
                } label: {
                    Label("置中", systemImage: isPortrait ? "align.horizontal.center" : "align.vertical.center")
                        .labelStyle(.iconOnly)
                        .frame(maxWidth: .infinity)
                }
                Button {
                    align(object, .trailing)
                } label: {
                    Label("靠右", systemImage: isPortrait ? "align.horizontal.right" : "align.vertical.bottom")
                        .labelStyle(.iconOnly)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)

            Button(isPortrait ? "對齊上緣" : "對齊左緣") { align(object, .contentStart) }
        } header: {
            Text("對齊紙張")
        }
    }

    private enum AlignTarget {
        case leading, middle, trailing, contentStart
    }

    /// Aligns the *rotated* bounding box, not the raw frame — a tilted object
    /// that is flush with the paper edge is what the eye reads as aligned.
    private func align(_ object: CanvasObject, _ target: AlignTarget) {
        let rect = editor.document.contentRect
        let box = object.boundingBox
        let isPortrait = editor.document.orientation.isPortrait

        var deltaX: CGFloat = 0
        var deltaY: CGFloat = 0

        switch target {
        case .leading:
            if isPortrait { deltaX = rect.minX - box.minX } else { deltaY = rect.minY - box.minY }
        case .middle:
            if isPortrait {
                deltaX = rect.midX - box.midX
            } else {
                deltaY = rect.midY - box.midY
            }
        case .trailing:
            if isPortrait { deltaX = rect.maxX - box.maxX } else { deltaY = rect.maxY - box.maxY }
        case .contentStart:
            if isPortrait { deltaY = rect.minY - box.minY } else { deltaX = rect.minX - box.minX }
        }

        editor.updateObject(object.id) {
            $0.origin.x += deltaX
            $0.origin.y += deltaY
        }
    }

    // MARK: - Type-specific content

    @ViewBuilder
    private func contentSection(_ object: CanvasObject) -> some View {
        switch object.content {
        case .image(let image):
            imageSection(object, image)
        case .vector(let vector):
            vectorSection(object, vector)
        // A shape's own look (kind, stroke, fill, corner, dash) lives in the
        // 格式 panel now, next to the text formatting it is the counterpart of —
        // and so does a table's structure, for the same reason.
        case .shape, .text, .table:
            EmptyView()
        }
    }

    /// Vector artwork has nothing to format — it is whatever its author drew —
    /// so this says where it came from and offers the one geometric repair a
    /// free-resize can call for.
    @ViewBuilder
    private func vectorSection(_ object: CanvasObject, _ vector: VectorContent) -> some View {
        Section {
            LabeledContent("來源") {
                Text(vector.sourceKind.displayName)
            }

            Button("還原原始比例") {
                let intrinsic = vector.intrinsicSize
                guard intrinsic.width > 0, intrinsic.height > 0 else { return }
                editor.updateObject(object.id) {
                    $0.size.height = max(1, ($0.size.width * intrinsic.height / intrinsic.width).rounded())
                }
            }
        } header: {
            Text("向量")
        }
    }

    @ViewBuilder
    private func imageSection(_ object: CanvasObject, _ image: ImageContent) -> some View {
        Section {
            Toggle("反相", isOn: Binding(
                get: { image.inverted },
                set: { newValue in
                    editor.updateObject(object.id) {
                        guard case .image(var content) = $0.content else { return }
                        content.inverted = newValue
                        $0.content = .image(content)
                    }
                }
            ))

            Picker("遞色", selection: Binding<DitherAlgorithm?>(
                get: { image.ditherOverride },
                set: { newValue in
                    editor.updateObject(object.id) {
                        guard case .image(var content) = $0.content else { return }
                        content.ditherOverride = newValue
                        $0.content = .image(content)
                    }
                }
            )) {
                Text("跟隨文件（\(editor.document.dither.displayName)）").tag(DitherAlgorithm?.none)
                ForEach(DitherAlgorithm.allCases, id: \.self) { algorithm in
                    Text(algorithm.displayName).tag(DitherAlgorithm?.some(algorithm))
                }
            }

            if let override = image.ditherOverride {
                Text(override.shortDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            toneSlider(
                object,
                image,
                title: "亮度",
                value: image.brightness,
                set: { $0.brightness = $1 }
            )
            toneSlider(
                object,
                image,
                title: "對比",
                value: image.contrast,
                set: { $0.contrast = $1 }
            )

            Button("還原原始比例") {
                let pixels = image.pixelSize
                guard pixels.width > 0, pixels.height > 0 else { return }
                editor.updateObject(object.id) {
                    $0.size.height = max(1, ($0.size.width * pixels.height / pixels.width).rounded())
                }
            }

            if image.hasToneAdjustment {
                Button("重置亮度與對比") {
                    editor.updateObject(object.id) {
                        guard case .image(var content) = $0.content else { return }
                        content.brightness = 0
                        content.contrast = 0
                        $0.content = .image(content)
                    }
                }
            }

            LabeledContent("影像像素") {
                Text("\(Int(image.pixelSize.width)) × \(Int(image.pixelSize.height))")
            }
        } header: {
            Text("圖片")
        } footer: {
            Text("亮度與對比在遞色前套用。")
        }
    }

    /// A -1...1 tone control. Written once because brightness and contrast
    /// differ only in which field they write back to.
    @ViewBuilder
    private func toneSlider(
        _ object: CanvasObject,
        _ image: ImageContent,
        title: String,
        value: Double,
        set: @escaping (inout ImageContent, Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%+.0f%%", value * 100))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { value },
                    set: { newValue in
                        editor.updateObject(object.id) {
                            guard case .image(var content) = $0.content else { return }
                            set(&content, (newValue * 100).rounded() / 100)
                            $0.content = .image(content)
                        }
                    }
                ),
                in: -1...1,
                step: 0.05
            )
        }
    }

    // MARK: - Layers

    @ViewBuilder
    private func layerSection(_ object: CanvasObject) -> some View {
        Section("圖層") {
            Button {
                editor.bringToFront(object.id)
            } label: {
                Label("最前", systemImage: "square.3.layers.3d.top.filled")
            }
            Button {
                editor.bringForward(object.id)
            } label: {
                Label("往前", systemImage: "square.2.layers.3d.top.filled")
            }
            Button {
                editor.sendBackward(object.id)
            } label: {
                Label("往後", systemImage: "square.2.layers.3d.bottom.filled")
            }
            Button {
                editor.sendToBack(object.id)
            } label: {
                Label("最後", systemImage: "square.3.layers.3d.bottom.filled")
            }
        }
    }

    // MARK: - State

    @ViewBuilder
    private func stateSection(_ object: CanvasObject) -> some View {
        Section {
            Toggle("鎖定", isOn: Binding(
                get: { object.isLocked },
                set: { newValue in editor.updateObject(object.id) { $0.isLocked = newValue } }
            ))
            Toggle("隱藏", isOn: Binding(
                get: { object.isHidden },
                set: { newValue in editor.updateObject(object.id) { $0.isHidden = newValue } }
            ))
        }
    }

    // MARK: - Interaction bookkeeping

    private func nudging(_ change: () -> Void) {
        editor.beginInteraction()
        change()
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            // The burst is over, so the next tap starts a fresh capture rather
            // than turning stale objects about a stale point.
            rotationBurst = nil
            editor.endInteraction()
        }
    }

    private func finishInteractionNow() {
        settleTask?.cancel()
        settleTask = nil
        rotationBurst = nil
        editor.endInteraction()
    }

    // MARK: - Angles

    private func degrees(from radians: CGFloat) -> CGFloat {
        let raw = radians * 180 / .pi
        return (raw * 10).rounded() / 10
    }

    private func radians(from degrees: CGFloat) -> CGFloat {
        var normalised = degrees.truncatingRemainder(dividingBy: 360)
        if normalised < 0 { normalised += 360 }
        return normalised * .pi / 180
    }
}

// MARK: - Fields

/// A dot-valued row: typed entry, the millimetre equivalent underneath, and two
/// nudge buttons so a 1-dot correction never needs the keyboard.
struct DotStepperField: View {

    let title: String
    let value: CGFloat
    var isEditable: Bool = true
    let commit: (CGFloat) -> Void
    var nudge: ((CGFloat) -> Void)? = nil

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 34, alignment: .leading)

            VStack(alignment: .trailing, spacing: 0) {
                if isEditable {
                    TextField("0", text: $text)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit { commitText() }
                } else {
                    Text(text)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Text(CanvasMetrics.lengthDescription(dots: value))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if isEditable, let nudge {
                HStack(spacing: 2) {
                    Button { nudge(-1) } label: {
                        Image(systemName: "minus").frame(width: 26, height: 30)
                    }
                    Button { nudge(1) } label: {
                        Image(systemName: "plus").frame(width: 26, height: 30)
                    }
                }
                .buttonStyle(.bordered)
                .buttonRepeatBehavior(.enabled)
            }
        }
        .onAppear { text = DotFormat.string(value) }
        .onChange(of: value) { _, newValue in
            // Do not fight the user's cursor: only mirror model changes back
            // into the field while they are not typing in it.
            if !isFocused { text = DotFormat.string(newValue) }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commitText() }
        }
        // Only the focused field contributes a keyboard accessory; otherwise
        // every row in the form would stack its own "完成" button.
        .toolbar {
            if isFocused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成", systemImage: "checkmark") { isFocused = false }
                }
            }
        }
    }

    private func commitText() {
        guard let parsed = DotFormat.value(text) else {
            text = DotFormat.string(value)
            return
        }
        let rounded = (parsed * 10).rounded() / 10
        text = DotFormat.string(rounded)
        if rounded != value { commit(rounded) }
    }
}

/// Rotation is stored in radians and shown in degrees, because nobody has ever
/// wanted to type 1.5707963.
private struct DegreeStepperField: View {

    let degrees: CGFloat
    let commit: (CGFloat) -> Void
    let nudge: (CGFloat) -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("角度")
                .frame(width: 34, alignment: .leading)

            TextField("0", text: $text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit { commitText() }

            Text("°")
                .foregroundStyle(.secondary)

            HStack(spacing: 2) {
                Button { nudge(-1) } label: {
                    Image(systemName: "minus").frame(width: 26, height: 30)
                }
                Button { nudge(1) } label: {
                    Image(systemName: "plus").frame(width: 26, height: 30)
                }
            }
            .buttonStyle(.bordered)
            .buttonRepeatBehavior(.enabled)
        }
        .onAppear { text = DotFormat.string(degrees) }
        .onChange(of: degrees) { _, newValue in
            if !isFocused { text = DotFormat.string(newValue) }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commitText() }
        }
        .toolbar {
            if isFocused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成", systemImage: "checkmark") { isFocused = false }
                }
            }
        }
    }

    private func commitText() {
        guard let parsed = DotFormat.value(text) else {
            text = DotFormat.string(degrees)
            return
        }
        let rounded = (parsed * 10).rounded() / 10
        text = DotFormat.string(rounded)
        if rounded != degrees { commit(rounded) }
    }
}

private enum DotFormat {

    static func string(_ value: CGFloat) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }

    static func value(_ text: String) -> CGFloat? {
        let trimmed = text
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: ",", with: "")
        guard let number = Double(trimmed) else { return nil }
        guard number.isFinite else { return nil }
        return CGFloat(number)
    }
}
