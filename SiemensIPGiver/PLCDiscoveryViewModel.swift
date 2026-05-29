//
//  PLCDiscoveryViewModel.swift
//  SiemensIPGiver
//
//  Created by Gregory Maendel on 5/6/26.
//

import Combine
import Foundation

@MainActor
final class PLCDiscoveryViewModel: ObservableObject {
    @Published var interfaces: [NetworkInterface] = []
    @Published var selectedInterfaceID: String?
    @Published var devices: [SiemensPLCDevice] = []
    @Published var selectedDeviceID: SiemensPLCDevice.ID?
    @Published var networkedPLCs: [NetworkedPLC] = []
    @Published var subnetCIDR = "192.168.1.0/24"
    @Published var targetMAC = ""
    @Published var targetIPAddress = "192.168.0.10"
    @Published var subnetMask = "255.255.255.0"
    @Published var gateway = "192.168.0.1"
    @Published var statusMessage = "Ready."
    @Published var errorMessage: String?
    @Published var isBusy = false

    private let service = ProfinetDCPService()
    private let pinger = PingService()
    private let s7 = S7DiscoveryService()

    var selectedInterface: NetworkInterface? {
        interfaces.first { $0.id == selectedInterfaceID }
    }

    var selectedDevice: SiemensPLCDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    func loadInterfaces() async {
        do {
            interfaces = try service.availableInterfaces()
            selectedInterfaceID = selectedInterfaceID ?? interfaces.first?.id
            statusMessage = interfaces.isEmpty
                ? "No Ethernet interfaces with MAC addresses were found."
                : "Ready. Select the PLC network interface and scan."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func scan() async {
        guard let selectedInterface else { return }
        await runBusyOperation("Scanning \(selectedInterface.name)...") {
            let found = try await self.service.identifyAll(on: selectedInterface)
            self.merge(found)
            self.statusMessage = found.isEmpty
                ? "Scan completed. No PROFINET devices answered."
                : "Scan completed. Found \(found.count) PROFINET device\(found.count == 1 ? "" : "s")."
        }
    }

    func scanIPRange() async {
        await runBusyOperation("Scanning \(subnetCIDR) for PLCs on TCP 102...") {
            let found = try await self.s7.scan(cidr: self.subnetCIDR)
            self.networkedPLCs = found
            self.statusMessage = found.isEmpty
                ? "No devices answered on TCP 102 in \(self.subnetCIDR)."
                : "Found \(found.count) IP-reachable PLC\(found.count == 1 ? "" : "s") in \(self.subnetCIDR)."
        }
    }

    func pingNetworkedPLC(_ plc: NetworkedPLC) async {
        await runBusyOperation("Pinging \(plc.ipAddress.displayString)...") {
            try await self.runPing(ip: plc.ipAddress, macHint: nil)
        }
    }

    func useNetworkedPLC(_ plc: NetworkedPLC) {
        targetIPAddress = plc.ipAddress.displayString
        statusMessage = "Loaded \(plc.ipAddress.displayString) into the New IP field for ping or reference."
    }

    func assignIPAddress() async {
        guard let selectedInterface else { return }

        await runBusyOperation("Assigning IP address...") {
            let macAddress = try MACAddress(self.targetMAC)
            let ipAddress = try IPv4Address(self.targetIPAddress)
            let mask = try IPv4Address(self.subnetMask)
            let router = try IPv4Address(self.gateway)

            let result = try await self.service.setIPAddress(
                on: selectedInterface,
                targetMAC: macAddress,
                ipAddress: ipAddress,
                subnetMask: mask,
                gateway: router
            )

            switch result {
            case .acknowledged:
                if let index = self.devices.firstIndex(where: { $0.macAddress == macAddress }) {
                    self.devices[index].ipAddress = ipAddress
                    self.devices[index].subnetMask = mask
                    self.devices[index].gateway = router
                }
                self.statusMessage = "\(macAddress.displayString) acknowledged. Saved IP \(ipAddress.displayString)/\(mask.displayString) gw \(router.displayString)."
            case .noResponse:
                self.statusMessage = "Set request sent to \(macAddress.displayString) but no reply within 2s. Check the cable, the selected interface, and that the PLC is powered."
            }
        }
    }

    func pingTargetIP() async {
        await runBusyOperation("Pinging \(self.targetIPAddress)...") {
            let ip = try IPv4Address(self.targetIPAddress)
            try await self.runPing(ip: ip, macHint: nil)
        }
    }

    func pingDevice(_ device: SiemensPLCDevice) async {
        guard let ip = device.ipAddress, !ip.isZero else { return }
        await runBusyOperation("Pinging \(ip.displayString) (\(device.macAddress.displayString))...") {
            try await self.runPing(ip: ip, macHint: device.macAddress.displayString)
        }
    }

    private func runPing(ip: IPv4Address, macHint: String?) async throws {
        let result = try await self.pinger.ping(ipAddress: ip)
        let prefix = macHint.map { "\(ip.displayString) [\($0)]" } ?? ip.displayString
        if result.didRespond {
            let latency = result.averageMilliseconds.map { String(format: "%.1f ms avg", $0) } ?? "no latency reported"
            self.statusMessage = "\(prefix) responded \(result.received)/\(result.transmitted) (\(latency))."
        } else {
            self.statusMessage = "\(prefix) did not reply to ICMP echo (\(result.received)/\(result.transmitted))."
        }
    }

    func useSelectedDevice() {
        guard let selectedDevice else { return }
        targetMAC = selectedDevice.macAddress.displayString
        if let ipAddress = selectedDevice.ipAddress, !ipAddress.isZero {
            targetIPAddress = ipAddress.displayString
        }
        if let subnetMask = selectedDevice.subnetMask, !subnetMask.isZero {
            self.subnetMask = subnetMask.displayString
        }
        if let gateway = selectedDevice.gateway, !gateway.isZero {
            self.gateway = gateway.displayString
        }
    }

    func clearDevices() {
        devices.removeAll()
        networkedPLCs.removeAll()
        selectedDeviceID = nil
        statusMessage = "Cleared PLC lists."
    }

    private func runBusyOperation(_ message: String, operation: @escaping () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        statusMessage = message

        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Operation failed."
        }

        isBusy = false
    }

    private func merge(_ found: [SiemensPLCDevice]) {
        for device in found {
            if let index = devices.firstIndex(where: { $0.id == device.id }) {
                devices[index] = device
            } else {
                devices.append(device)
            }
        }
        devices.sort { lhs, rhs in
            lhs.macAddress.normalizedString < rhs.macAddress.normalizedString
        }
    }
}
