//
//  ContentView.swift
//  SiemensIPGiver
//
//  Created by Gregory Maendel on 5/6/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = PLCDiscoveryViewModel()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 310, ideal: 360)
        } detail: {
            detail
        }
        .frame(minWidth: 980, minHeight: 620)
        .task {
            await viewModel.loadInterfaces()
        }
    }

    private var sidebar: some View {
        List(selection: $viewModel.selectedDeviceID) {
            Section {
                interfacePicker
            }

            Section {
                ipScanBar
            }

            Section("Local PROFINET Devices (Layer 2)") {
                if viewModel.devices.isEmpty {
                    Text("No local PROFINET devices yet. Select a wired interface and press Scan.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.devices) { device in
                        PLCRow(device: device, isBusy: viewModel.isBusy) {
                            Task { await viewModel.pingDevice(device) }
                        }
                        .tag(device.id)
                    }
                }
            }

            if !viewModel.networkedPLCs.isEmpty {
                Section("IP-Reachable PLCs (Layer 3)") {
                    ForEach(viewModel.networkedPLCs) { plc in
                        NetworkedPLCRow(plc: plc, isBusy: viewModel.isBusy) {
                            Task { await viewModel.pingNetworkedPLC(plc) }
                        } onUse: {
                            viewModel.useNetworkedPLC(plc)
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await viewModel.scan() }
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .disabled(viewModel.isBusy || viewModel.selectedInterface == nil)

                Button {
                    viewModel.clearDevices()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled((viewModel.devices.isEmpty && viewModel.networkedPLCs.isEmpty) || viewModel.isBusy)
            }
        }
    }

    private var ipScanBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("IP Range Scan (Layer 3)", systemImage: "globe")
                .font(.headline)

            Text("Finds PLCs that already have an IP. Works across routers, VLANs, and other buildings — DCP cannot.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("192.168.1.0/24", text: $viewModel.subnetCIDR)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.isBusy)

                Button {
                    Task { await viewModel.scanIPRange() }
                } label: {
                    Label("Scan IPs", systemImage: "magnifyingglass")
                }
                .disabled(viewModel.isBusy || viewModel.subnetCIDR.isEmpty)
            }
        }
    }

    private var interfacePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Network Interface", systemImage: "network")
                    .font(.headline)
                Spacer()
                if viewModel.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Picker("Interface", selection: $viewModel.selectedInterfaceID) {
                ForEach(viewModel.interfaces) { networkInterface in
                    Text(networkInterface.displayName)
                        .tag(Optional(networkInterface.id))
                }
            }
            .labelsHidden()
            .disabled(viewModel.isBusy)

            if let selectedInterface = viewModel.selectedInterface {
                Text("MAC \(selectedInterface.macAddress.displayString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if selectedInterface.isWireless {
                    Label("PROFINET DCP needs a wired Ethernet adapter on the same L2 segment. Wi-Fi will miss most PLC replies.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Divider()

            form

            Spacer()

            status
        }
        .padding(24)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Siemens PLC IP Assignment")
                .font(.largeTitle.weight(.semibold))
            Text("Find Siemens PLCs with PROFINET DCP and assign an IP address, subnet mask, and gateway by MAC address.")
                .foregroundStyle(.secondary)
        }
    }

    private var form: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow {
                Text("Target MAC")
                    .foregroundStyle(.secondary)
                TextField("00:1B:1B:12:34:56", text: $viewModel.targetMAC)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }

            GridRow {
                Text("New IP")
                    .foregroundStyle(.secondary)
                TextField("192.168.0.10", text: $viewModel.targetIPAddress)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }

            GridRow {
                Text("Subnet")
                    .foregroundStyle(.secondary)
                TextField("255.255.255.0", text: $viewModel.subnetMask)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }

            GridRow {
                Text("Gateway")
                    .foregroundStyle(.secondary)
                TextField("192.168.0.1", text: $viewModel.gateway)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }

            GridRow {
                Text("")
                HStack(spacing: 10) {
                    Button {
                        Task { await viewModel.assignIPAddress() }
                    } label: {
                        Label("Assign IP", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isBusy || viewModel.selectedInterface == nil)

                    Button {
                        Task { await viewModel.pingTargetIP() }
                    } label: {
                        Label("Ping", systemImage: "wave.3.right")
                    }
                    .disabled(viewModel.isBusy || viewModel.targetIPAddress.isEmpty)

                    Button {
                        viewModel.useSelectedDevice()
                    } label: {
                        Label("Use Selected PLC", systemImage: "cursorarrow.click")
                    }
                    .disabled(viewModel.selectedDevice == nil || viewModel.isBusy)
                }
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Text(viewModel.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("PROFINET DCP uses raw Ethernet frames. Run the app with permission to open /dev/bpf* and use a local Ethernet adapter on the PLC network.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct PLCRow: View {
    let device: SiemensPLCDevice
    let isBusy: Bool
    let onPing: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(device.stationName.isEmpty ? "Unnamed PLC" : device.stationName)
                        .font(.headline)
                        .foregroundStyle(device.hasIPAddress ? Color.primary : Color.red)
                    Spacer()
                    if !device.hasIPAddress {
                        Text("No IP")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }

                Text(device.macAddress.displayString)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)

                if let ip = device.ipAddress, let subnet = device.subnetMask {
                    Text("\(ip.displayString) / \(subnet.displayString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !device.deviceRole.isEmpty || !device.vendorName.isEmpty {
                    Text([device.vendorName, device.deviceRole].filter { !$0.isEmpty }.joined(separator: " - "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if device.hasIPAddress, let ip = device.ipAddress {
                Button(action: onPing) {
                    Image(systemName: "wave.3.right")
                }
                .buttonStyle(.borderless)
                .help("Ping \(ip.displayString)")
                .disabled(isBusy)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct NetworkedPLCRow: View {
    let plc: NetworkedPLC
    let isBusy: Bool
    let onPing: () -> Void
    let onUse: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(plc.displayTitle)
                    .font(.headline)

                Text(plc.ipAddress.displayString)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(plc.subtitle.isEmpty ? "TCP 102 open" : plc.subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            HStack(spacing: 4) {
                Button(action: onUse) {
                    Image(systemName: "arrow.up.doc.on.clipboard")
                }
                .buttonStyle(.borderless)
                .help("Load \(plc.ipAddress.displayString) into the New IP field")
                .disabled(isBusy)

                Button(action: onPing) {
                    Image(systemName: "wave.3.right")
                }
                .buttonStyle(.borderless)
                .help("Ping \(plc.ipAddress.displayString)")
                .disabled(isBusy)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ContentView()
}
