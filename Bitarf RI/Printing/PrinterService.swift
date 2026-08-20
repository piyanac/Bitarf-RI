//
//  PrinterService.swift
//  Bitarf RI
//
//  Generic Bluetooth printer state and the reconstruction boundary.
//

import CoreBluetooth
import Combine
import Foundation

enum PrinterConnectionState: Equatable {
    case poweredOff
    case unauthorized
    case unsupported
    case idle
    case scanning
    case connecting(String)
    case connected(String)
    case failed(String)

    var displayText: String {
        switch self {
        case .poweredOff: return "藍牙已關閉，請在設定 → 藍牙開啟。"
        case .unauthorized: return "尚未允許 Bitarf RI 使用藍牙。請在權限設定 → 藍牙開啟。"
        case .unsupported: return "這台裝置不支援低功耗藍牙（BLE）。"
        case .idle: return "尚未連線。"
        case .scanning: return "搜尋印表機中…"
        case .connecting(let name): return "連線中：\(name)"
        case .connected(let name): return "已連線：\(name)"
        case .failed(let message): return message
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isScanning: Bool { self == .scanning }

    var isBluetoothBlocked: Bool {
        switch self {
        case .poweredOff, .unauthorized, .unsupported: return true
        default: return false
        }
    }
}

struct DiscoveredPrinter: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int?
    let advertisedServices: [String]
    let looksLikeAPrinter: Bool

    var signalDescription: String {
        var text = "訊號：" + (rssi.map { "\($0) dBm" } ?? "—")
        if !advertisedServices.isEmpty {
            text += " " + advertisedServices.joined(separator: " ")
        }
        return text
    }
}

enum PrintProgress: Equatable {
    case idle
    case preparing
    case sending(sent: Int, total: Int)
    case finishing
    case done
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .preparing, .sending, .finishing: return true
        default: return false
        }
    }
}

@MainActor
final class PrinterService: NSObject, ObservableObject {
    static let shared = PrinterService()

    @Published private(set) var state: PrinterConnectionState = .idle
    @Published private(set) var discovered: [DiscoveredPrinter] = []
    @Published private(set) var rememberedPrinters: [RememberedPrinter] = []
    @Published private(set) var connectedPrinter: DiscoveredPrinter?
    @Published private(set) var progress: PrintProgress = .idle

    // 此處應插入經典機型的服務辨識、協定 adapter、CRC 交握、封包回覆解析、
    // 寫入策略、實測串流節流、狀態查詢、列印、自我測試與走紙實作。
    //
    // 通用 CoreBluetooth 掃描、連線、GATT discovery、characteristic 選擇、
    // remembered-device 與診斷 UI 的整合邊界亦應在此接回。
}
