//
//  BPFDevice.swift
//  SiemensIPGiver
//
//  Created by Gregory Maendel on 5/6/26.
//

import Darwin
import Foundation

nonisolated final class BPFDevice {
    private enum IOCTL {
        static let setInterface = UInt(bitPattern: ioctlCode(inoutFlag: 0x80000000, group: 66, number: 108, size: MemoryLayout<ifreq>.size))
        static let immediate = UInt(bitPattern: ioctlCode(inoutFlag: 0x80000000, group: 66, number: 112, size: MemoryLayout<UInt32>.size))
        static let bufferLength = UInt(bitPattern: ioctlCode(inoutFlag: 0x40000000, group: 66, number: 102, size: MemoryLayout<UInt32>.size))
        static let headerComplete = UInt(bitPattern: ioctlCode(inoutFlag: 0x80000000, group: 66, number: 117, size: MemoryLayout<UInt32>.size))
        static let dataLinkType = UInt(bitPattern: ioctlCode(inoutFlag: 0x40000000, group: 66, number: 106, size: MemoryLayout<UInt32>.size))
        static let seeSent = UInt(bitPattern: ioctlCode(inoutFlag: 0x80000000, group: 66, number: 115, size: MemoryLayout<UInt32>.size))

        private static func ioctlCode(inoutFlag: Int, group: Int, number: Int, size: Int) -> Int {
            inoutFlag | (size << 16) | (group << 8) | number
        }
    }

    private var descriptor: Int32 = -1
    private var bufferLength: Int = 0

    init(interfaceName: String) throws {
        var openedDescriptor: Int32 = -1
        for index in 0..<256 {
            openedDescriptor = Darwin.open("/dev/bpf\(index)", O_RDWR)
            if openedDescriptor >= 0 {
                break
            }
            if errno != EBUSY {
                continue
            }
        }

        guard openedDescriptor >= 0 else {
            throw ProfinetDCPError.bpfUnavailable
        }

        self.descriptor = openedDescriptor

        do {
            try configure(interfaceName: interfaceName)
            var length: UInt32 = 0
            guard ioctl(descriptor, IOCTL.bufferLength, &length) >= 0 else {
                throw ProfinetDCPError.bpfConfigureFailed(String(cString: strerror(errno)))
            }
            self.bufferLength = Int(length)
        } catch {
            Darwin.close(openedDescriptor)
            throw error
        }
    }

    func close() {
        Darwin.close(descriptor)
    }

    func write(_ bytes: [UInt8]) throws {
        let written = bytes.withUnsafeBytes { rawBuffer in
            Darwin.write(descriptor, rawBuffer.baseAddress, bytes.count)
        }

        guard written == bytes.count else {
            throw ProfinetDCPError.bpfWriteFailed(String(cString: strerror(errno)))
        }
    }

    func readFrames(timeout: TimeInterval) throws -> [[UInt8]] {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&pollDescriptor, 1, Int32(timeout * 1000))
        guard pollResult >= 0 else {
            throw ProfinetDCPError.bpfReadFailed(String(cString: strerror(errno)))
        }
        guard pollResult > 0 else {
            return []
        }

        let requestedLength = bufferLength
        var buffer = [UInt8](repeating: 0, count: requestedLength)
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(descriptor, rawBuffer.baseAddress, requestedLength)
        }

        guard bytesRead >= 0 else {
            throw ProfinetDCPError.bpfReadFailed(String(cString: strerror(errno)))
        }

        var frames: [[UInt8]] = []
        var offset = 0

        while offset + MemoryLayout<bpf_hdr>.size <= bytesRead {
            let header = buffer.withUnsafeBytes { rawBuffer in
                rawBuffer.baseAddress!
                    .advanced(by: offset)
                    .assumingMemoryBound(to: bpf_hdr.self)
                    .pointee
            }

            let packetStart = offset + Int(header.bh_hdrlen)
            let packetEnd = packetStart + Int(header.bh_caplen)
            guard packetEnd <= bytesRead else { break }

            frames.append(Array(buffer[packetStart..<packetEnd]))
            offset += bpfWordAlign(Int(header.bh_hdrlen) + Int(header.bh_caplen))
        }

        return frames
    }

    private func configure(interfaceName: String) throws {
        var interfaceRequest = ifreq()
        try withCStringBytes(interfaceName, maxCount: Int(IFNAMSIZ)) { nameBytes in
            withUnsafeMutableBytes(of: &interfaceRequest.ifr_name) { destination in
                destination.copyBytes(from: nameBytes.prefix(destination.count))
            }
        }

        guard ioctl(descriptor, IOCTL.setInterface, &interfaceRequest) >= 0 else {
            throw ProfinetDCPError.bpfConfigureFailed(String(cString: strerror(errno)))
        }

        var immediate: UInt32 = 1
        guard ioctl(descriptor, IOCTL.immediate, &immediate) >= 0 else {
            throw ProfinetDCPError.bpfConfigureFailed(String(cString: strerror(errno)))
        }

        var headerComplete: UInt32 = 1
        guard ioctl(descriptor, IOCTL.headerComplete, &headerComplete) >= 0 else {
            throw ProfinetDCPError.bpfConfigureFailed(String(cString: strerror(errno)))
        }

        var seeSent: UInt32 = 0
        _ = ioctl(descriptor, IOCTL.seeSent, &seeSent)

        var dlt: UInt32 = 0
        guard ioctl(descriptor, IOCTL.dataLinkType, &dlt) >= 0, dlt == UInt32(DLT_EN10MB) else {
            throw ProfinetDCPError.bpfConfigureFailed("Selected interface is not an Ethernet link.")
        }
    }

    private func withCStringBytes(_ string: String, maxCount: Int, body: ([UInt8]) throws -> Void) throws {
        var bytes = Array(string.utf8.prefix(maxCount - 1))
        bytes.append(0)
        try body(bytes)
    }

    private func bpfWordAlign(_ value: Int) -> Int {
        let wordSize = MemoryLayout<Int32>.size
        return (value + wordSize - 1) & ~(wordSize - 1)
    }
}
