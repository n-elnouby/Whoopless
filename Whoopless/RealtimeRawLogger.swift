//
//  RealtimeRawLogger.swift
//  Whoopless
//
//  Captures REALTIME_RAW_DATA packets (type 0x2B) triggered by startRawData.
//  These packets are LARGE (~1900 bytes each, declared length in bytes 1-2)
//  and fragment across multiple BLE notifications. We log each fragment with
//  an "is_header" flag so offline tooling can reassemble.
//
//  Header-fragment byte 16 appears to carry live HR in bpm — verify by
//  correlating with live HR from the standard HR service.
//

import Foundation

final class RealtimeRawLogger: @unchecked Sendable {

    nonisolated(unsafe) static let shared = RealtimeRawLogger()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "whoopless.rawlogger.io", qos: .utility)

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("realtime_raw_log.csv")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? "logged_ms,is_header,declared_len,unix_ts,hr_byte16,raw_hex,tag\n"
                .write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Append any fragment we receive on 61080005. Parses header info if present.
    nonisolated func append(_ data: Data) {
        guard !data.isEmpty else { return }
        let bytes = [UInt8](data)
        let isHeader = bytes.count >= 17 && bytes[0] == 0xAA && bytes.count >= 5 && bytes[4] == 0x2B

        var declaredLen = 0
        var unixTs: UInt32 = 0
        var hr16: UInt8 = 0
        if isHeader {
            declaredLen = Int(bytes[1]) | (Int(bytes[2]) << 8)
            unixTs = UInt32(bytes[11]) | (UInt32(bytes[12]) << 8)
                   | (UInt32(bytes[13]) << 16) | (UInt32(bytes[14]) << 24)
            hr16 = bytes[16]
        }

        let loggedMs = Int64(Date().timeIntervalSince1970 * 1000)
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        let line = "\(loggedMs),\(isHeader ? 1 : 0),\(declaredLen),\(unixTs),\(hr16),\(hex),\n"

        let url = fileURL
        queue.async {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            if let d = line.data(using: .utf8) { try? handle.write(contentsOf: d) }
        }
    }

    /// Write a "tag" marker row into the log — used to bracket known-condition
    /// phases during a structured capture (e.g. "still", "active", "recovery").
    nonisolated func appendTag(_ name: String) {
        let loggedMs = Int64(Date().timeIntervalSince1970 * 1000)
        let safe = name.replacingOccurrences(of: ",", with: "_")
        let line = "\(loggedMs),0,0,0,0,,\(safe)\n"
        let url = fileURL
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

    nonisolated var path: String { fileURL.path }

    nonisolated func clear() {
        queue.async { [self] in
            try? "logged_ms,is_header,declared_len,unix_ts,hr_byte16,raw_hex\n"
                .write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}
