//
//  PrintView.swift
//  Bitarf RI
//
//  Generic print-preview shell. Hardware controls are intentionally absent.
//

import SwiftUI
import UIKit

struct PrintView: View {
    @EnvironmentObject var editor: EditorState
    @ObservedObject private var printer = PrinterService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var raster: PrintRasterResult?
    @State private var previewImage: UIImage?
    @State private var isRendering = false

    private static let previewHeight: CGFloat = 260

    var body: some View {
        NavigationStack {
            List {
                printerSection
                ditherSection

                // 此處應插入經典機型的傳輸估算、濃度、尾端走紙、相容模式、
                // 串流速率、列印送出、進度與維護工具 UI。
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { previewPanel }
            .navigationTitle("列印")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .task(id: renderKey) { await rerender() }
    }

    private var printerSection: some View {
        Section {
            Text(printer.state.displayText)
                .foregroundStyle(.secondary)
        } header: {
            Text("印表機")
        }
    }

    private var ditherSection: some View {
        Section {
            Picker("遞色", selection: Binding(
                get: { editor.document.dither },
                set: { editor.setDither($0) }
            )) {
                ForEach(DitherAlgorithm.allCases, id: \.self) { algorithm in
                    Text(algorithm.displayName).tag(algorithm)
                }
            }
        } header: {
            Text("列印選項")
        } footer: {
            Text(editor.document.dither.shortDescription)
        }
    }

    private var previewPanel: some View {
        ZStack {
            if let previewImage {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: previewImage)
                        .resizable()
                        .interpolation(.none)
                        .antialiased(false)
                        .frame(width: previewImage.size.width, height: previewImage.size.height)
                        .background(Color.white)
                }
            } else if isRendering {
                ProgressView("產生預覽中…")
            } else {
                Text("沒有可列印的內容。")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.previewHeight)
        .background(colorScheme == .dark ? Color(white: 0.17) : Color(white: 0.9))
    }

    private var renderKey: Int {
        var hasher = Hasher()
        hasher.combine(editor.document)
        return hasher.finalize()
    }

    private func rerender() async {
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        isRendering = true
        let result = PrintRasterizer.rasterize(document: editor.document.reflowed)
        raster = result
        previewImage = result.bitmap.makeCGImage().map { UIImage(cgImage: $0) }
        isRendering = false

        // 此處應插入經典機型封包工作大小的背景計算。
    }
}
