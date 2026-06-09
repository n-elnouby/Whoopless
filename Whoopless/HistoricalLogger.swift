//
//  HistoricalLogger.swift
//  Whoopless
//
//  Captures the stream of HISTORICAL_DATA packets (type 0x2F) that flows
//  when we send SEND_HISTORICAL_DATA to the WHOOP. Saves the raw hex plus
//  parsed timestamp per packet so we can reverse-engineer the byte layout
//  offline without re-collecting data each session.
//

import Foundation

final class HistoricalLogger: @unchecked Sendable {

    nonisolated(unsafe) static let shared = HistoricalLogger()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "whoopless.histlogger.io", qos: .utility)

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("historical_log.csv")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? "logged_ms,unix_ts,seq,raw_hex\n".write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Append a historical packet. Caller passes the raw bytes as received
    /// from `peripheral(_:didUpdateValueFor:)`. We parse out the fields we
    /// already know (sequence counter + Unix timestamp) for quick inspection;
    /// everything else stays in `raw_hex` for later analysis.
    nonisolated func append(_ data: Data) {
        guard data.count >= 15 else { return }
        let bytes = [UInt8](data)
        guard bytes[0] == 0xAA, bytes[4] == 0x2F else { return }  // must be HISTORICAL_DATA
        let seq = bytes[7]
        let unixTs = UInt32(bytes[11]) | (UInt32(bytes[12]) << 8)
                   | (UInt32(bytes[13]) << 16) | (UInt32(bytes[14]) << 24)
        let loggedMs = Int64(Date().timeIntervalSince1970 * 1000)
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        let line = "\(loggedMs),\(unixTs),\(seq),\(hex)\n"

        let url = self.fileURL
        queue.async {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            if let d = line.data(using: .utf8) { try? handle.write(contentsOf: d) }
        }
    }

    nonisolated var count: Int {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return 0 }
        return max(0, text.split(separator: "\n", omittingEmptySubsequences: true).count - 1)
    }

    nonisolated var latestTimestamp: Date? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let last = lines.last else { return nil }
        let cols = last.split(separator: ",")
        guard cols.count >= 2, let unix = UInt32(cols[1]) else { return nil }
        return Date(timeIntervalSince1970: Double(unix))
    }

    nonisolated var path: String { fileURL.path }

    nonisolated func clear() {
        queue.async { [self] in
            try? "logged_ms,unix_ts,seq,raw_hex\n".write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}
