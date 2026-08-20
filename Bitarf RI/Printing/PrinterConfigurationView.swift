//
//  PrinterConfigurationView.swift
//  Bitarf RI
//
//  Generic printer configuration UI with hardware reconstruction boundaries.
//

import SwiftUI

struct PrinterStatusRow: View {
    @ObservedObject var printer: PrinterService

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: printer.state.isConnected ? "printer.dotmatrix.fill" : "printer.dotmatrix")
                .foregroundStyle(printer.state.isConnected ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(printer.state.displayText)
                if let device = printer.connectedPrinter {
                    Text(device.signalDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct PrinterConfigurationSection: View {
    @ObservedObject private var printer = PrinterService.shared

    var body: some View {
        Section {
            PrinterStatusRow(printer: printer)

            // 此處應插入通用掃描、連線、記住與中斷連線控制。
        } header: {
            Text("印表機組態")
        }
    }
}

struct PrinterDiscoverySheet: View {
    @ObservedObject var printer: PrinterService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                PrinterStatusRow(printer: printer)
                // 此處應插入通用 BLE discovery 結果與連線操作。
                // 此處應插入經典機型的 CRC 狀態排障說明。
            }
            .navigationTitle("搜尋印表機")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }
}

struct PrinterDetailView: View {
    @ObservedObject var printer: PrinterService
    var showsMaintenance: Bool

    var body: some View {
        Form {
            PrinterStatusRow(printer: printer)

            // 此處應插入經典機型的韌體、電量、熱感濃度、串流能力、
            // 自我測試、走紙、查詢 trace 與 GATT 診斷。
        }
        .navigationTitle(printer.connectedPrinter?.name ?? "印表機")
    }
}
