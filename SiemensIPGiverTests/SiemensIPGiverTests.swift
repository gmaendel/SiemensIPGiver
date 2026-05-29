//
//  SiemensIPGiverTests.swift
//  SiemensIPGiverTests
//
//  Created by Gregory Maendel on 5/6/26.
//

import Testing
@testable import SiemensIPGiver

struct SiemensIPGiverTests {
    @Test func parsesMACAddressFormats() throws {
        #expect(try MACAddress("00:1B:1B:12:34:56").displayString == "00:1B:1B:12:34:56")
        #expect(try MACAddress("001b1b123456").displayString == "00:1B:1B:12:34:56")
        #expect(try MACAddress("00-1b-1b-12-34-56").displayString == "00:1B:1B:12:34:56")
    }

    @Test func rejectsBadAddresses() {
        #expect(throws: AddressValidationError.invalidMAC) {
            try MACAddress("00:11:22")
        }
        #expect(throws: AddressValidationError.invalidIPv4) {
            try IPv4Address("192.168.0.300")
        }
    }

    @Test func buildsIdentifyAllRequest() throws {
        let source = try MACAddress("AA:BB:CC:DD:EE:FF")
        let frame = ProfinetDCPPacketBuilder().identifyAllRequest(sourceMAC: source, xid: 0x11223344)

        #expect(Array(frame[0..<6]) == [0x01, 0x0E, 0xCF, 0x00, 0x00, 0x00])
        #expect(Array(frame[6..<12]) == source.bytes)
        #expect(frame[12] == 0x88)
        #expect(frame[13] == 0x92)
        #expect(frame[14] == 0xFE)
        #expect(frame[15] == 0xFE)
        #expect(frame[16] == 0x05)
        #expect(frame[17] == 0x00)
        #expect(frame.count == 60)
    }

    @Test func buildsSetIPRequest() throws {
        let source = try MACAddress("AA:BB:CC:DD:EE:FF")
        let target = try MACAddress("00:1B:1B:12:34:56")
        let frame = ProfinetDCPPacketBuilder().setIPAddressRequest(
            sourceMAC: source,
            targetMAC: target,
            ipAddress: try IPv4Address("192.168.0.10"),
            subnetMask: try IPv4Address("255.255.255.0"),
            gateway: try IPv4Address("192.168.0.1"),
            xid: 0x11223344
        )

        #expect(Array(frame[0..<6]) == target.bytes)
        #expect(Array(frame[6..<12]) == source.bytes)
        #expect(frame[14] == 0xFE)
        #expect(frame[15] == 0xFD)
        #expect(frame[16] == 0x04)
        #expect(frame[26] == 0x01)
        #expect(frame[27] == 0x02)
        #expect(frame[30] == 0x00)
        #expect(frame[31] == 0x01)
        #expect(Array(frame[32..<36]) == [192, 168, 0, 10])
        #expect(Array(frame[36..<40]) == [255, 255, 255, 0])
        #expect(Array(frame[40..<44]) == [192, 168, 0, 1])
    }

    @Test func parserRejectsOwnRequestPacket() throws {
        let source = try MACAddress("AA:BB:CC:DD:EE:FF")
        let ownRequest = ProfinetDCPPacketBuilder().identifyAllRequest(sourceMAC: source, xid: 0x11223344)
        #expect(ProfinetDCPPacketBuilder().parseIdentifyResponse(ownRequest) == nil)
    }

    @Test func parserAcceptsValidResponse() throws {
        let response = makeIdentifyResponse(
            sourceMAC: try MACAddress("4C:E7:05:5B:43:66"),
            ip: [192, 168, 0, 50],
            subnet: [255, 255, 255, 0],
            gateway: [192, 168, 0, 1],
            stationName: "plc1",
            vendor: "Siemens",
            roleByte: 0x01
        )

        let device = try #require(ProfinetDCPPacketBuilder().parseIdentifyResponse(response))
        #expect(device.macAddress.displayString == "4C:E7:05:5B:43:66")
        #expect(device.ipAddress?.displayString == "192.168.0.50")
        #expect(device.subnetMask?.displayString == "255.255.255.0")
        #expect(device.gateway?.displayString == "192.168.0.1")
        #expect(device.stationName == "plc1")
        #expect(device.vendorName == "Siemens")
        #expect(device.deviceRole == "IO-Device")
    }

    @Test func parserRejectsNonResponseFrameID() throws {
        var response = makeIdentifyResponse(
            sourceMAC: try MACAddress("4C:E7:05:5B:43:66"),
            ip: [0, 0, 0, 0],
            subnet: [0, 0, 0, 0],
            gateway: [0, 0, 0, 0],
            stationName: "",
            vendor: "",
            roleByte: 0x01
        )
        response[14] = 0xFE
        response[15] = 0xFD
        #expect(ProfinetDCPPacketBuilder().parseIdentifyResponse(response) == nil)
    }

    @Test func parserAcceptsVlanTaggedResponse() throws {
        var response = makeIdentifyResponse(
            sourceMAC: try MACAddress("AC:64:17:11:22:33"),
            ip: [192, 168, 1, 20],
            subnet: [255, 255, 255, 0],
            gateway: [192, 168, 1, 1],
            stationName: "tagged-plc",
            vendor: "Siemens",
            roleByte: 0x02
        )
        // Insert an 802.1Q priority tag (priority 6, VID 0) between src MAC and EtherType.
        response.insert(contentsOf: [0x81, 0x00, 0xC0, 0x00], at: 12)

        let device = try #require(ProfinetDCPPacketBuilder().parseIdentifyResponse(response))
        #expect(device.macAddress.displayString == "AC:64:17:11:22:33")
        #expect(device.ipAddress?.displayString == "192.168.1.20")
        #expect(device.stationName == "tagged-plc")
        #expect(device.deviceRole == "IO-Controller")
    }

    @Test func expandHostsProducesUsableRange() throws {
        let hosts = try S7DiscoveryService.expandHosts(cidr: "192.168.1.0/24")
        #expect(hosts.count == 254)
        #expect(hosts.first?.displayString == "192.168.1.1")
        #expect(hosts.last?.displayString == "192.168.1.254")
    }

    @Test func expandHostsRejectsBadInputAndHugeRanges() {
        #expect(throws: S7DiscoveryError.self) {
            try S7DiscoveryService.expandHosts(cidr: "not-a-subnet")
        }
        #expect(throws: S7DiscoveryError.self) {
            try S7DiscoveryService.expandHosts(cidr: "10.0.0.0/8")
        }
    }

    @Test func siemensOUIRecognizesKnownPrefixes() throws {
        #expect(SiemensOUI.isSiemens(try MACAddress("4C:E7:05:5B:43:66")))
        #expect(SiemensOUI.isSiemens(try MACAddress("00:1B:1B:12:34:56")))
        #expect(SiemensOUI.isSiemens(try MACAddress("00:0E:8C:AA:BB:CC")))
    }

    @Test func siemensOUIRejectsNonSiemens() throws {
        #expect(!SiemensOUI.isSiemens(try MACAddress("36:AA:9F:9F:C6:00")))
        #expect(!SiemensOUI.isSiemens(try MACAddress("AA:BB:CC:DD:EE:FF")))
        #expect(!SiemensOUI.isSiemens(try MACAddress("6C:6E:07:30:60:3D")))
    }

    private func makeIdentifyResponse(
        sourceMAC: MACAddress,
        ip: [UInt8],
        subnet: [UInt8],
        gateway: [UInt8],
        stationName: String,
        vendor: String,
        roleByte: UInt8
    ) -> [UInt8] {
        var blocks: [UInt8] = []

        // IP Parameter block: option 0x01/0x02, BlockInfo + IP + Subnet + Gateway = 14 bytes.
        blocks += [0x01, 0x02, 0x00, 0x0E, 0x00, 0x00]
        blocks += ip + subnet + gateway

        // Name of Station block: option 0x02/0x02, BlockInfo + UTF-8 name.
        if !stationName.isEmpty {
            let nameBytes = Array(stationName.utf8)
            let payloadLen = nameBytes.count + 2
            blocks += [0x02, 0x02]
            blocks += [UInt8((payloadLen >> 8) & 0xFF), UInt8(payloadLen & 0xFF)]
            blocks += [0x00, 0x00]
            blocks += nameBytes
            if payloadLen % 2 != 0 { blocks.append(0x00) }
        }

        // Manufacturer Specific block: option 0x02/0x01, BlockInfo + UTF-8 vendor.
        if !vendor.isEmpty {
            let vendorBytes = Array(vendor.utf8)
            let payloadLen = vendorBytes.count + 2
            blocks += [0x02, 0x01]
            blocks += [UInt8((payloadLen >> 8) & 0xFF), UInt8(payloadLen & 0xFF)]
            blocks += [0x00, 0x00]
            blocks += vendorBytes
            if payloadLen % 2 != 0 { blocks.append(0x00) }
        }

        // Device Role block: option 0x02/0x04, BlockInfo + role byte + padding.
        blocks += [0x02, 0x04, 0x00, 0x04, 0x00, 0x00, roleByte, 0x00]

        let dataLen = UInt16(blocks.count)
        var frame: [UInt8] = []
        frame += [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]            // dst MAC (our PC)
        frame += sourceMAC.bytes                                  // src MAC (PLC)
        frame += [0x88, 0x92]                                     // EtherType
        frame += [0xFE, 0xFF]                                     // FrameID: Identify Response
        frame += [0x05, 0x01]                                     // ServiceID Identify, ServiceType Response
        frame += [0x11, 0x22, 0x33, 0x44]                         // XID
        frame += [0x00, 0x00]                                     // ResponseDelay
        frame += [UInt8((dataLen >> 8) & 0xFF), UInt8(dataLen & 0xFF)]
        frame += blocks
        return frame
    }
}
