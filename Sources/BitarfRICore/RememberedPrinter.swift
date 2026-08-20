//
//  RememberedPrinter.swift
//  Bitarf RI
//
//  The record deliberately contains only the identity CoreBluetooth can restore
//  and presentation data. A GATT layout is session state: it must be discovered
//  again after every connection, rather than trusted from an old session.
//

import Foundation

public struct RememberedPrinter: Codable, Equatable, Identifiable {

    public let id: UUID
    public let name: String
    public let lastConnectedAt: Date

    public init(id: UUID, name: String, lastConnectedAt: Date) {
        self.id = id
        self.name = name
        self.lastConnectedAt = lastConnectedAt
    }
}

/// Persistence for printers which have completed Bitarf RI's connection and GATT
/// checks. Keeping it separate from `PrinterService` makes the storage policy
/// testable without turning on Bluetooth.
public final class RememberedPrinterStore {

    public static let storageKey = "printer.rememberedPrinters"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [RememberedPrinter] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let printers = try? JSONDecoder().decode([RememberedPrinter].self, from: data) else {
            return []
        }
        return printers.sorted { $0.lastConnectedAt > $1.lastConnectedAt }
    }

    @discardableResult
    public func record(id: UUID, name: String, at date: Date = .now) -> [RememberedPrinter] {
        var printers = load().filter { $0.id != id }
        printers.append(RememberedPrinter(id: id, name: name, lastConnectedAt: date))
        printers.sort { $0.lastConnectedAt > $1.lastConnectedAt }
        save(printers)
        return printers
    }

    @discardableResult
    public func forget(id: UUID) -> [RememberedPrinter] {
        let printers = load().filter { $0.id != id }
        save(printers)
        return printers
    }

    private func save(_ printers: [RememberedPrinter]) {
        guard let data = try? JSONEncoder().encode(printers) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
