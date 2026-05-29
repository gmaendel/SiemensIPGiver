//
//  S7DiscoveryService.swift
//  SiemensIPGiver
//
//  Created by Gregory Maendel on 5/6/26.
//

import Darwin
import Foundation

// Layer-3 PLC discovery. PROFINET DCP is Layer 2 and cannot cross routers, VLANs,
// or fiber links between buildings. PLCs that already have an IP, however, can be
// reached over routed IP via S7 communication (ISO-on-TCP, RFC 1006) on TCP port
// 102 — which is how TIA Portal lists remote, already-addressed PLCs. This service
// sweeps a CIDR range, flags hosts with port 102 open as PLCs, and best-effort reads
// their station name / module type / order number over S7comm.
nonisolated final class S7DiscoveryService: @unchecked Sendable {
    private let port: UInt16 = 102
    private let connectTimeout: TimeInterval
    private let identifyTimeout: TimeInterval

    // S7comm partial lists (SZL) we read for identity. 0x001C = Component
    // Identification (names), 0x0011 = Module Identification (order number / MLFB).
    private enum SZL {
        static let componentID: UInt16 = 0x001C
        static let moduleID: UInt16 = 0x0011
    }

    private struct S7Info {
        var stationName = ""
        var moduleType = ""
        var orderNumber = ""
    }

    init(connectTimeout: TimeInterval = 0.4, identifyTimeout: TimeInterval = 0.8) {
        self.connectTimeout = connectTimeout
        self.identifyTimeout = identifyTimeout
    }

    func scan(cidr: String, maxConcurrent: Int = 32) async throws -> [NetworkedPLC] {
        let hosts = try Self.expandHosts(cidr: cidr)
        guard !hosts.isEmpty else { return [] }
        let timeout = connectTimeout

        var found: [NetworkedPLC] = []
        await withTaskGroup(of: NetworkedPLC?.self) { group in
            var next = 0
            let initial = min(maxConcurrent, hosts.count)

            while next < initial {
                let host = hosts[next]
                next += 1
                group.addTask { [self] in
                    await Task.detached(priority: .utility) { self.probe(host, connectTimeout: timeout) }.value
                }
            }

            while let result = await group.next() {
                if let plc = result { found.append(plc) }
                if next < hosts.count {
                    let host = hosts[next]
                    next += 1
                    group.addTask { [self] in
                        await Task.detached(priority: .utility) { self.probe(host, connectTimeout: timeout) }.value
                    }
                }
            }
        }

        return found.sorted { $0.ipAddress.integerValue < $1.ipAddress.integerValue }
    }

    static func expandHosts(cidr: String) throws -> [IPv4Address] {
        let trimmed = cidr.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let prefix = Int(parts[1]), (0...32).contains(prefix),
              let base = try? IPv4Address(String(parts[0])) else {
            throw S7DiscoveryError.invalidCIDR
        }

        let hostBits = 32 - prefix
        let mask: UInt32 = prefix == 0 ? 0 : (~UInt32(0) << UInt32(hostBits))
        let network = base.integerValue & mask
        let total: UInt64 = UInt64(1) << UInt64(hostBits)

        // For prefixes /30 and larger blocks, skip the network and broadcast addresses.
        let firstHost: UInt32
        let lastHost: UInt32
        if prefix >= 31 {
            firstHost = network
            lastHost = network &+ UInt32(total - 1)
        } else {
            firstHost = network &+ 1
            lastHost = network &+ UInt32(total - 2)
        }

        let count = Int(lastHost) - Int(firstHost) + 1
        guard count > 0 else { return [] }
        guard count <= 4096 else { throw S7DiscoveryError.rangeTooLarge(count) }

        return (firstHost...lastHost).map { IPv4Address(packed: $0) }
    }

    private func probe(_ ip: IPv4Address, connectTimeout: TimeInterval) -> NetworkedPLC? {
        guard portOpen(ip, timeout: connectTimeout) else { return nil }
        let info = identify(ip)
        return NetworkedPLC(
            ipAddress: ip,
            stationName: info.stationName,
            moduleType: info.moduleType,
            orderNumber: info.orderNumber
        )
    }

    private func portOpen(_ ip: IPv4Address, timeout: TimeInterval) -> Bool {
        guard let fd = connect(to: ip, timeout: timeout) else { return false }
        close(fd)
        return true
    }

    private func identify(_ ip: IPv4Address) -> S7Info {
        var info = S7Info()
        // S7-1200/1500 typically accept connection-resource TSAP 0x0301/0x0302;
        // S7-300/400 use rack/slot (e.g. 0x0102). Try each until one confirms.
        let destinationTSAPs: [UInt16] = [0x0301, 0x0302, 0x0102]
        for tsap in destinationTSAPs {
            guard let fd = connect(to: ip, timeout: identifyTimeout) else { return info }
            defer { close(fd) }

            guard cotpConnect(fd: fd, destinationTSAP: tsap), s7Setup(fd: fd) else { continue }

            if let component = readSZL(fd: fd, szlID: SZL.componentID) {
                if let value = component[0x0001] { info.stationName = Self.decodeASCII(value) }
                if let value = component[0x0007] { info.moduleType = Self.decodeASCII(value) }
            }
            if let module = readSZL(fd: fd, szlID: SZL.moduleID), let value = module[0x0001] {
                // The order number (MLFB) is the first 20 ASCII bytes of the value.
                info.orderNumber = Self.decodeASCII(Array(value.prefix(20)))
            }
            return info
        }
        return info
    }

    // MARK: - S7comm exchange

    private func cotpConnect(fd: Int32, destinationTSAP: UInt16) -> Bool {
        let request: [UInt8] = [
            0x03, 0x00, 0x00, 0x16,                 // TPKT: version 3, reserved, length 22
            0x11,                                   // COTP header length (17)
            0xE0,                                   // PDU type: Connection Request
            0x00, 0x00,                             // destination reference
            0x00, 0x01,                             // source reference
            0x00,                                   // class / options
            0xC1, 0x02, 0x01, 0x00,                 // parameter: source TSAP = 0x0100
            0xC2, 0x02,                             // parameter: destination TSAP
            UInt8(destinationTSAP >> 8), UInt8(destinationTSAP & 0xFF),
            0xC0, 0x01, 0x0A                        // parameter: TPDU size = 1024
        ]
        guard writeAll(fd: fd, request), let response = readTPKT(fd: fd), response.count >= 6 else { return false }
        // COTP PDU type is the high nibble of byte 5; 0xD0 = Connection Confirm.
        return (response[5] & 0xF0) == 0xD0
    }

    private func s7Setup(fd: Int32) -> Bool {
        let request: [UInt8] = [
            0x03, 0x00, 0x00, 0x19,                 // TPKT: length 25
            0x02, 0xF0, 0x80,                       // COTP: DT data
            0x32, 0x01, 0x00, 0x00,                 // S7: protocol id, ROSCTR = Job, redundancy
            0x00, 0x00,                             // PDU reference
            0x00, 0x08,                             // parameter length 8
            0x00, 0x00,                             // data length 0
            0xF0, 0x00,                             // function: Setup communication
            0x00, 0x01,                             // max AmQ (calling)
            0x00, 0x01,                             // max AmQ (called)
            0x03, 0xC0                              // PDU length 960
        ]
        guard writeAll(fd: fd, request), let response = readTPKT(fd: fd), response.count >= 8 else { return false }
        // A valid ack carries the S7 protocol id 0x32 right after the COTP DT header.
        return response[7] == 0x32
    }

    private func readSZL(fd: Int32, szlID: UInt16) -> [UInt16: [UInt8]]? {
        let request: [UInt8] = [
            0x03, 0x00, 0x00, 0x21,                 // TPKT: length 33
            0x02, 0xF0, 0x80,                       // COTP: DT data
            0x32, 0x07, 0x00, 0x00,                 // S7: protocol id, ROSCTR = Userdata
            0x00, 0x00,                             // PDU reference
            0x00, 0x08,                             // parameter length 8
            0x00, 0x08,                             // data length 8
            0x00, 0x01, 0x12,                       // parameter head
            0x04,                                   // parameter length
            0x11,                                   // request, CPU function group
            0x44,                                   // subfunction: read SZL
            0x01,                                   // sequence number
            0x00,                                   // data unit reference
            0xFF, 0x09,                             // return code OK, transport size: octet string
            0x00, 0x04,                             // SZL data length 4
            UInt8(szlID >> 8), UInt8(szlID & 0xFF), // SZL-ID
            0x00, 0x00                              // SZL-Index
        ]
        guard writeAll(fd: fd, request), let response = readTPKT(fd: fd) else { return nil }
        return parseSZLResponse(response, expectedSZLID: szlID)
    }

    // Maps each SZL record's 2-byte index to its raw value bytes.
    private func parseSZLResponse(_ frame: [UInt8], expectedSZLID: UInt16) -> [UInt16: [UInt8]]? {
        guard frame.count >= 19, frame[7] == 0x32, frame[8] == 0x07 else { return nil }
        let parameterLength = (Int(frame[13]) << 8) | Int(frame[14])
        let dataLength = (Int(frame[15]) << 8) | Int(frame[16])
        let dataStart = 17 + parameterLength
        guard dataLength >= 12, dataStart + dataLength <= frame.count else { return nil }

        let data = Array(frame[dataStart..<(dataStart + dataLength)])
        guard data[0] == 0xFF else { return nil }                       // SZL read return code
        let szlID = (UInt16(data[4]) << 8) | UInt16(data[5])
        guard szlID == expectedSZLID else { return nil }
        let recordLength = (Int(data[8]) << 8) | Int(data[9])
        let recordCount = (Int(data[10]) << 8) | Int(data[11])
        guard recordLength > 2 else { return nil }

        var records: [UInt16: [UInt8]] = [:]
        var offset = 12
        for _ in 0..<recordCount {
            guard offset + recordLength <= data.count else { break }
            let index = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
            records[index] = Array(data[(offset + 2)..<(offset + recordLength)])
            offset += recordLength
        }
        return records.isEmpty ? nil : records
    }

    // MARK: - Socket plumbing

    private func connect(to ip: IPv4Address, timeout: TimeInterval) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        // Non-blocking connect so the attempt can be bounded with poll().
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = ip.integerValue.bigEndian

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result != 0 {
            guard errno == EINPROGRESS else { close(fd); return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(timeout * 1000))
            guard ready > 0, (pfd.revents & Int16(POLLOUT)) != 0 else { close(fd); return nil }

            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
            guard socketError == 0 else { close(fd); return nil }
        }

        // Back to blocking with read/write timeouts for the request/response phase.
        _ = fcntl(fd, F_SETFL, flags)
        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: __darwin_suseconds_t((timeout - floor(timeout)) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private func writeAll(fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while sent < bytes.count {
                let n = send(fd, base.advanced(by: sent), bytes.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
        return sent == bytes.count
    }

    private func readTPKT(fd: Int32) -> [UInt8]? {
        guard let header = readExact(fd: fd, count: 4), header[0] == 0x03 else { return nil }
        let length = (Int(header[2]) << 8) | Int(header[3])
        guard length >= 4, length <= 4096 else { return nil }
        let remaining = length - 4
        guard remaining > 0 else { return header }
        guard let body = readExact(fd: fd, count: remaining) else { return nil }
        return header + body
    }

    private func readExact(fd: Int32, count: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while got < count {
                let n = recv(fd, base.advanced(by: got), count - got, 0)
                if n <= 0 { return false }
                got += n
            }
            return true
        }
        return ok ? buffer : nil
    }

    private static func decodeASCII(_ bytes: [UInt8]) -> String {
        let printable = bytes.prefix { $0 != 0 }
        return String(decoding: printable, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated enum S7DiscoveryError: LocalizedError {
    case invalidCIDR
    case rangeTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .invalidCIDR:
            "Enter a subnet in CIDR form, e.g. 192.168.1.0/24."
        case .rangeTooLarge(let count):
            "That range has \(count) hosts. Narrow it to /20 or smaller (≤ 4096 hosts)."
        }
    }
}
