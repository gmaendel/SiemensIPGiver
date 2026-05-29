//
//  ProfinetDCPService.swift
//  SiemensIPGiver
//
//  Created by Gregory Maendel on 5/6/26.
//

import Darwin
import Foundation

nonisolated final class ProfinetDCPService: @unchecked Sendable {
    private let dcp = ProfinetDCPPacketBuilder()

    func availableInterfaces() throws -> [NetworkInterface] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let firstAddress = addresses else {
            throw ProfinetDCPError.interfaceLookupFailed(String(cString: strerror(errno)))
        }
        defer { freeifaddrs(addresses) }

        var interfaces: [NetworkInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress

        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }

            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = current.pointee.ifa_addr, Int32(address.pointee.sa_family) == AF_LINK else { continue }

            let name = String(cString: current.pointee.ifa_name)
            guard isPhysicalEthernet(name: name, address: address) else { continue }
            guard let macAddress = macAddress(from: address) else { continue }

            let displayName = friendlyInterfaceName(for: name) ?? name
            interfaces.append(NetworkInterface(name: name, displayName: "\(displayName) (\(name))", macAddress: macAddress))
        }

        return interfaces.sorted { $0.name < $1.name }
    }

    func identifyAll(on networkInterface: NetworkInterface) async throws -> [SiemensPLCDevice] {
        try await Task.detached(priority: .userInitiated) {
            let bpf = try BPFDevice(interfaceName: networkInterface.name)
            defer { bpf.close() }

            let xid = UInt32.random(in: 1...UInt32.max)
            let packet = self.dcp.identifyAllRequest(sourceMAC: networkInterface.macAddress, xid: xid)
            try bpf.write(packet)

            let deadline = Date().addingTimeInterval(3.0)
            var devicesByMAC: [MACAddress: SiemensPLCDevice] = [:]

            while Date() < deadline {
                for frame in try bpf.readFrames(timeout: 0.4) {
                    guard let device = self.dcp.parseIdentifyResponse(frame) else { continue }
                    guard device.macAddress != networkInterface.macAddress else { continue }
                    // The parser already accepts only valid PROFINET DCP Identify responses,
                    // so any source MAC reaching here belongs to a real PROFINET device.
                    devicesByMAC[device.macAddress] = device
                }
            }

            return Array(devicesByMAC.values)
        }.value
    }

    func setIPAddress(
        on networkInterface: NetworkInterface,
        targetMAC: MACAddress,
        ipAddress: IPv4Address,
        subnetMask: IPv4Address,
        gateway: IPv4Address
    ) async throws -> SetIPResult {
        try await Task.detached(priority: .userInitiated) {
            let bpf = try BPFDevice(interfaceName: networkInterface.name)
            defer { bpf.close() }

            let xid = UInt32.random(in: 1...UInt32.max)
            let packet = self.dcp.setIPAddressRequest(
                sourceMAC: networkInterface.macAddress,
                targetMAC: targetMAC,
                ipAddress: ipAddress,
                subnetMask: subnetMask,
                gateway: gateway,
                xid: xid
            )
            try bpf.write(packet)

            let deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline {
                for frame in try bpf.readFrames(timeout: 0.4) {
                    guard let result = self.dcp.parseSetResponse(frame, expectedTargetMAC: targetMAC, expectedXID: xid) else { continue }
                    switch result {
                    case .success:
                        return .acknowledged
                    case .notSupported:
                        throw ProfinetDCPError.setRejected("PLC reports option not supported.")
                    case .notSet:
                        throw ProfinetDCPError.setRejected("PLC could not store the value.")
                    case .unknown(let code):
                        throw ProfinetDCPError.setRejected("PLC returned status 0x\(String(code, radix: 16)).")
                    }
                }
            }
            return .noResponse
        }.value
    }

    private func macAddress(from socketAddress: UnsafeMutablePointer<sockaddr>) -> MACAddress? {
        let linkAddress = socketAddress.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
        guard linkAddress.sdl_alen == 6 else { return nil }

        let nameLength = Int(linkAddress.sdl_nlen)
        let macBytes: [UInt8] = withUnsafeBytes(of: linkAddress.sdl_data) { rawBuffer in
            Array(rawBuffer.dropFirst(nameLength).prefix(6))
        }

        return try? MACAddress(bytes: macBytes)
    }

    private func isPhysicalEthernet(name: String, address: UnsafeMutablePointer<sockaddr>) -> Bool {
        let virtualPrefixes = ["awdl", "llw", "utun", "gif", "stf", "ipsec", "anpi", "pdp_ip", "ap", "p2p", "bridge", "vmnet", "vboxnet", "vnic", "lo"]
        if virtualPrefixes.contains(where: { name.hasPrefix($0) }) {
            return false
        }

        let linkAddress = address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
        return linkAddress.sdl_type == 0x06
    }

    private func friendlyInterfaceName(for bsdName: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        task.arguments = ["-listallhardwareports"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        var currentPort: String?
        for line in output.split(separator: "\n").map(String.init) {
            if line.hasPrefix("Hardware Port: ") {
                currentPort = String(line.dropFirst("Hardware Port: ".count))
            } else if line == "Device: \(bsdName)" {
                return currentPort
            }
        }
        return nil
    }
}

nonisolated enum SetIPResult: Sendable {
    case acknowledged
    case noResponse
}

nonisolated enum ProfinetDCPError: LocalizedError {
    case interfaceLookupFailed(String)
    case bpfUnavailable
    case bpfOpenFailed(String)
    case bpfConfigureFailed(String)
    case bpfWriteFailed(String)
    case bpfReadFailed(String)
    case setRejected(String)

    var errorDescription: String? {
        switch self {
        case .interfaceLookupFailed(let message):
            "Could not list network interfaces: \(message)"
        case .bpfUnavailable:
            "Could not open /dev/bpf*. Run the app with BPF access, and make sure no security policy is blocking raw Ethernet capture."
        case .bpfOpenFailed(let message):
            "Could not open BPF device: \(message)"
        case .bpfConfigureFailed(let message):
            "Could not configure BPF device: \(message)"
        case .bpfWriteFailed(let message):
            "Could not send PROFINET frame: \(message)"
        case .bpfReadFailed(let message):
            "Could not read PROFINET frames: \(message)"
        case .setRejected(let message):
            "PLC rejected Set request: \(message)"
        }
    }
}
