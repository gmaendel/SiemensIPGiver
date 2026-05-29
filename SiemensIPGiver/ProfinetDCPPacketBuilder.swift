//
//  ProfinetDCPPacketBuilder.swift
//  SiemensIPGiver
//
//  Created by Gregory Maendel on 5/6/26.
//

import Foundation

nonisolated struct ProfinetDCPPacketBuilder: Sendable {
    private enum Constants {
        static let etherType: UInt16 = 0x8892
        static let vlanTPID: UInt16 = 0x8100
        static let identifyRequestFrameID: UInt16 = 0xFEFE
        static let identifyResponseFrameID: UInt16 = 0xFEFF
        static let dcpRequestFrameID: UInt16 = 0xFEFD
        static let serviceIdentify: UInt8 = 0x05
        static let serviceSet: UInt8 = 0x04
        static let requestType: UInt8 = 0x00
        static let responseSuccessType: UInt8 = 0x01
        static let multicastMAC = [UInt8](arrayLiteral: 0x01, 0x0E, 0xCF, 0x00, 0x00, 0x00)
    }

    func identifyAllRequest(sourceMAC: MACAddress, xid: UInt32) -> [UInt8] {
        var dcpData: [UInt8] = []
        dcpData.append(0xFF)
        dcpData.append(0xFF)
        dcpData.appendUInt16(0)

        var payload: [UInt8] = []
        payload.appendUInt16(Constants.identifyRequestFrameID)
        appendDCPHeader(
            to: &payload,
            serviceID: Constants.serviceIdentify,
            serviceType: Constants.requestType,
            xid: xid,
            // Factor * 10 ms = max random response delay; 32 ≈ 320 ms scatter,
            // enough room for ~10 PLCs to reply without colliding.
            responseDelay: 32,
            dataLength: UInt16(dcpData.count)
        )
        payload.append(contentsOf: dcpData)

        return ethernetFrame(destinationMAC: Constants.multicastMAC, sourceMAC: sourceMAC.bytes, payload: payload)
    }

    func setIPAddressRequest(
        sourceMAC: MACAddress,
        targetMAC: MACAddress,
        ipAddress: IPv4Address,
        subnetMask: IPv4Address,
        gateway: IPv4Address,
        xid: UInt32
    ) -> [UInt8] {
        var dcpData: [UInt8] = []
        dcpData.append(0x01)
        dcpData.append(0x02)
        dcpData.appendUInt16(14)
        dcpData.appendUInt16(0x0001)
        dcpData.append(contentsOf: ipAddress.bytes)
        dcpData.append(contentsOf: subnetMask.bytes)
        dcpData.append(contentsOf: gateway.bytes)

        var payload: [UInt8] = []
        payload.appendUInt16(Constants.dcpRequestFrameID)
        appendDCPHeader(
            to: &payload,
            serviceID: Constants.serviceSet,
            serviceType: Constants.requestType,
            xid: xid,
            responseDelay: 0,
            dataLength: UInt16(dcpData.count)
        )
        payload.append(contentsOf: dcpData)

        return ethernetFrame(destinationMAC: targetMAC.bytes, sourceMAC: sourceMAC.bytes, payload: payload)
    }

    enum SetResult: Equatable {
        case success
        case notSupported
        case notSet
        case unknown(UInt8)
    }

    func parseSetResponse(_ frame: [UInt8], expectedTargetMAC: MACAddress, expectedXID: UInt32) -> SetResult? {
        guard let base = dcpPayloadOffset(in: frame), frame.count >= base + 8 else { return nil }
        guard frame.readUInt16(at: base) == Constants.dcpRequestFrameID else { return nil }
        guard frame[base + 2] == Constants.serviceSet else { return nil }
        guard Array(frame[6..<12]) == expectedTargetMAC.bytes else { return nil }
        guard frame.readUInt32(at: base + 4) == expectedXID else { return nil }

        switch frame[base + 3] {
        case 0x01: return .success
        case 0x05: return .notSupported
        case 0x06: return .notSet
        case let other: return .unknown(other)
        }
    }

    func parseIdentifyResponse(_ frame: [UInt8]) -> SiemensPLCDevice? {
        guard let base = dcpPayloadOffset(in: frame), frame.count >= base + 12 else { return nil }
        guard frame.readUInt16(at: base) == Constants.identifyResponseFrameID else { return nil }
        guard frame[base + 2] == Constants.serviceIdentify else { return nil }
        guard frame[base + 3] == Constants.responseSuccessType else { return nil }

        guard let macAddress = try? MACAddress(bytes: Array(frame[6..<12])) else { return nil }
        let dataLength = Int(frame.readUInt16(at: base + 10) ?? 0)
        let blockStart = base + 12
        guard dataLength > 0, blockStart + dataLength <= frame.count else {
            return SiemensPLCDevice(macAddress: macAddress, ipAddress: nil, subnetMask: nil, gateway: nil, stationName: "", vendorName: "", deviceRole: "")
        }

        var device = SiemensPLCDevice(macAddress: macAddress, ipAddress: nil, subnetMask: nil, gateway: nil, stationName: "", vendorName: "", deviceRole: "")
        parseBlocks(Array(frame[blockStart..<(blockStart + dataLength)]), into: &device)
        return device
    }

    // PROFINET DCP frames are frequently 802.1Q priority-tagged. A VLAN tag inserts
    // 4 bytes between the source MAC and the EtherType, shifting the DCP payload from
    // offset 14 to 18. Returns the offset of the DCP FrameID, or nil if this is not a
    // PROFINET DCP frame. Without this, every tagged responder is silently dropped.
    private func dcpPayloadOffset(in frame: [UInt8]) -> Int? {
        guard frame.count >= 16 else { return nil }
        if frame.readUInt16(at: 12) == Constants.vlanTPID {
            guard frame.readUInt16(at: 16) == Constants.etherType else { return nil }
            return 18
        }
        guard frame.readUInt16(at: 12) == Constants.etherType else { return nil }
        return 14
    }

    private func ethernetFrame(destinationMAC: [UInt8], sourceMAC: [UInt8], payload: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = []
        frame.append(contentsOf: destinationMAC)
        frame.append(contentsOf: sourceMAC)
        frame.appendUInt16(Constants.etherType)
        frame.append(contentsOf: payload)

        if frame.count < 60 {
            frame.append(contentsOf: repeatElement(UInt8(0), count: 60 - frame.count))
        }

        return frame
    }

    private func appendDCPHeader(to payload: inout [UInt8], serviceID: UInt8, serviceType: UInt8, xid: UInt32, responseDelay: UInt16, dataLength: UInt16) {
        payload.append(serviceID)
        payload.append(serviceType)
        payload.appendUInt32(xid)
        payload.appendUInt16(responseDelay)
        payload.appendUInt16(dataLength)
    }

    private func parseBlocks(_ data: [UInt8], into device: inout SiemensPLCDevice) {
        var offset = 0
        while offset + 4 <= data.count {
            let option = data[offset]
            let suboption = data[offset + 1]
            let length = Int(data.readUInt16(at: offset + 2) ?? 0)
            let valueStart = offset + 4
            let valueEnd = valueStart + length
            guard valueEnd <= data.count else { break }

            let value = Array(data[valueStart..<valueEnd])
            applyBlock(option: option, suboption: suboption, value: value, to: &device)

            offset = valueEnd + (length.isMultiple(of: 2) ? 0 : 1)
        }
    }

    private func applyBlock(option: UInt8, suboption: UInt8, value: [UInt8], to device: inout SiemensPLCDevice) {
        guard value.count >= 2 else { return }
        let payload = Array(value.dropFirst(2))

        switch (option, suboption) {
        case (0x01, 0x02):
            guard payload.count >= 12 else { return }
            device.ipAddress = try? IPv4Address(bytes: Array(payload[0..<4]))
            device.subnetMask = try? IPv4Address(bytes: Array(payload[4..<8]))
            device.gateway = try? IPv4Address(bytes: Array(payload[8..<12]))
        case (0x02, 0x01):
            device.vendorName = decodedString(from: payload)
        case (0x02, 0x02):
            device.stationName = decodedString(from: payload)
        case (0x02, 0x04):
            guard let roleByte = payload.first else { return }
            device.deviceRole = decodedRole(from: roleByte)
        default:
            break
        }
    }

    private func decodedString(from value: [UInt8]) -> String {
        var trimmed = value
        while trimmed.last == 0 {
            trimmed.removeLast()
        }
        return String(decoding: trimmed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodedRole(from byte: UInt8) -> String {
        var roles: [String] = []
        if byte & 0x01 != 0 { roles.append("IO-Device") }
        if byte & 0x02 != 0 { roles.append("IO-Controller") }
        if byte & 0x04 != 0 { roles.append("IO-Multidevice") }
        if byte & 0x08 != 0 { roles.append("Supervisor") }
        return roles.joined(separator: ", ")
    }
}

nonisolated private extension Array where Element == UInt8 {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    func readUInt16(at offset: Int) -> UInt16? {
        guard offset + 1 < count else { return nil }
        return (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func readUInt32(at offset: Int) -> UInt32? {
        guard offset + 3 < count else { return nil }
        return (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }
}
