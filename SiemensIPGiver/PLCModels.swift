//
//  PLCModels.swift
//  SiemensIPGiver
//
//  Created by Gregory Maendel on 5/6/26.
//

import Foundation

nonisolated struct MACAddress: Hashable, Identifiable, Sendable {
    let bytes: [UInt8]

    var id: String { normalizedString }

    var normalizedString: String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    var displayString: String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    init(bytes: [UInt8]) throws {
        guard bytes.count == 6 else {
            throw AddressValidationError.invalidMAC
        }
        self.bytes = bytes
    }

    init(_ string: String) throws {
        let compact = string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: ":")

        let parts = compact.contains(":")
            ? compact.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            : stride(from: 0, to: compact.count, by: 2).map { offset -> String in
                let start = compact.index(compact.startIndex, offsetBy: offset)
                let end = compact.index(start, offsetBy: min(2, compact.distance(from: start, to: compact.endIndex)))
                return String(compact[start..<end])
            }

        guard parts.count == 6 else {
            throw AddressValidationError.invalidMAC
        }

        let parsed = parts.compactMap { UInt8($0, radix: 16) }
        guard parsed.count == 6 else {
            throw AddressValidationError.invalidMAC
        }

        try self.init(bytes: parsed)
    }
}

nonisolated struct IPv4Address: Hashable, Sendable {
    let bytes: [UInt8]

    var displayString: String {
        bytes.map(String.init).joined(separator: ".")
    }

    var isZero: Bool {
        bytes.allSatisfy { $0 == 0 }
    }

    var integerValue: UInt32 {
        bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    init(bytes: [UInt8]) throws {
        guard bytes.count == 4 else {
            throw AddressValidationError.invalidIPv4
        }
        self.bytes = bytes
    }

    init(packed value: UInt32) {
        bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }

    init(_ string: String) throws {
        let parts = string.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            throw AddressValidationError.invalidIPv4
        }

        let parsed = parts.compactMap { UInt8($0) }
        guard parsed.count == 4 else {
            throw AddressValidationError.invalidIPv4
        }

        try self.init(bytes: parsed)
    }
}

nonisolated enum AddressValidationError: LocalizedError, Equatable {
    case invalidMAC
    case invalidIPv4

    var errorDescription: String? {
        switch self {
        case .invalidMAC:
            "Enter a valid 6-byte MAC address."
        case .invalidIPv4:
            "Enter a valid IPv4 address."
        }
    }
}

nonisolated struct NetworkInterface: Identifiable, Hashable, Sendable {
    let name: String
    let displayName: String
    let macAddress: MACAddress

    var id: String { name }

    var isWireless: Bool {
        let needles = ["wi-fi", "wireless", "airport", "wlan"]
        let lower = displayName.lowercased()
        return needles.contains { lower.contains($0) }
    }
}

nonisolated struct SiemensPLCDevice: Identifiable, Hashable, Sendable {
    let macAddress: MACAddress
    var ipAddress: IPv4Address?
    var subnetMask: IPv4Address?
    var gateway: IPv4Address?
    var stationName: String
    var vendorName: String
    var deviceRole: String

    var id: String { macAddress.id }

    var hasIPAddress: Bool {
        guard let ipAddress else { return false }
        return !ipAddress.isZero
    }
}

// A PLC discovered over routed IP (Layer 3) by probing TCP 102 and reading its
// identity over S7comm. Unlike SiemensPLCDevice (found via Layer-2 DCP, keyed by
// MAC), these can live behind routers/VLANs and in other buildings, so they are
// identified by IP address. We may not learn their MAC, so DCP IP assignment does
// not apply — these are for visibility, ping, and reference.
nonisolated struct NetworkedPLC: Identifiable, Hashable, Sendable {
    let ipAddress: IPv4Address
    var stationName: String
    var moduleType: String
    var orderNumber: String

    var id: String { ipAddress.displayString }

    var displayTitle: String {
        if !stationName.isEmpty { return stationName }
        if !moduleType.isEmpty { return moduleType }
        return ipAddress.displayString
    }

    var subtitle: String {
        [moduleType, orderNumber].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
