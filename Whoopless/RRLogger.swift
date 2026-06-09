//
//  RRLogger.swift
//  Whoopless
//
//  Persistently log every accepted RR interval so we can reconstruct the
//  R-wave timeline later for HRV analysis / calibration vs Apple Watch.
//
//  Format: one CSV row per RR, `unix_ms,rr_ms\n`. Appended to disk on every
//  write so overnight data survives app relaunch.
//

import Foundation

@MainActor
final class RRLogger {

    static let shared = RRLogger()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "whoopless.rrlogger.io", qos: .utility)

    /// In-memory cap so the file doesn't grow forever. After rotation, last N
    /// entries are kept. 50k ≈ 14 hours of RRs at 60 bpm.
    private let maxEntries = 50_000

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("rr_log.csv")
        // Touch the file so read-before-write doesn't fail.
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? "timestamp_ms,rr_ms\n".write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Append a single RR interval to the log.
    nonisolated func append(_ rrMs: Double, at date: Date = Date()) {
        let ts = Int64(date.timeIntervalSince1970 * 1000)
        let line = "\(ts),\(Int(rrMs))\n"
        let url = self.fileURL
        queue.async {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
    }

    /// Read the whole log back as (Date, rrMs) pairs. Synchronous — call off the main actor.
    nonisolated func readAll() -> [(Date, Double)] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        var out: [(Date, Double)] = []
        for line in text.split(separator: "\n").dropFirst() {   // drop header
            let parts = line.split(separator: ",")
            guard parts.count == 2,
                  let ms = Int64(parts[0]),
                  let rr = Double(parts[1]) else { continue }
            out.append((Date(timeIntervalSince1970: Double(ms) / 1000), rr))
        }
        return out
    }

    /// Trim the log to the last `maxEntries` rows. Call periodically.
    nonisolated func trimIfNeeded() {
        queue.async { [self] in
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count > maxEntries + 1 else { return }
            let trimmed = ["timestamp_ms,rr_ms"] + lines.suffix(maxEntries).map(String.init)
            let newText = trimmed.joined(separator: "\n") + "\n"
            try? newText.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Full path — useful for sharing the file via AirDrop / Files.
    nonisolated var path: String { fileURL.path }

    /// Count of RR samples currently in the log (cheap — uses newline count).
    nonisolated var count: Int {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return 0 }
        // Minus 1 for the header line.
        return max(0, text.split(separator: "\n", omittingEmptySubsequences: true).count - 1)
    }

    /// Clear the log entirely.
    nonisolated func clear() {
        queue.async { [self] in
            try? "timestamp_ms,rr_ms\n".write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}
