//
//  PingService.swift
//  SiemensIPGiver
//
//  Created by Gregory Maendel on 5/6/26.
//

import Foundation

nonisolated struct PingResult: Sendable {
    let transmitted: Int
    let received: Int
    let averageMilliseconds: Double?

    var didRespond: Bool { received > 0 }
}

nonisolated final class PingService: @unchecked Sendable {
    func ping(ipAddress: IPv4Address, count: Int = 3) async throws -> PingResult {
        try await Task.detached(priority: .userInitiated) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/sbin/ping")
            task.arguments = ["-c", "\(count)", "-W", "1000", ipAddress.displayString]

            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()

            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return PingResult(
                transmitted: count,
                received: Self.parseReceived(output),
                averageMilliseconds: Self.parseAverage(output)
            )
        }.value
    }

    private static func parseReceived(_ output: String) -> Int {
        for line in output.split(separator: "\n") where line.contains("packets received") {
            for part in line.split(separator: ",") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.hasSuffix("packets received"),
                   let value = trimmed.split(separator: " ").first,
                   let n = Int(value) {
                    return n
                }
            }
        }
        return 0
    }

    private static func parseAverage(_ output: String) -> Double? {
        for line in output.split(separator: "\n") where line.contains("min/avg/max") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let after = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            let numbers = after.split(separator: " ").first ?? ""
            let components = numbers.split(separator: "/")
            if components.count >= 2, let avg = Double(components[1]) {
                return avg
            }
        }
        return nil
    }
}
