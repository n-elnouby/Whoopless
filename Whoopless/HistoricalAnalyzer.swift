//
//  HistoricalAnalyzer.swift
//  Whoopless
//
//  Quick per-byte statistics over the saved HISTORICAL_DATA packets.
//  Point: figure out which byte positions are constants, which vary, and
//  which plausibly hold HR / RR / temperature / battery / strain.
//

import Foundation
import Combine

struct ByteStat: Identifiable {
    let id: Int             // byte position
    let min: UInt8
    let max: UInt8
    let distinct: Int
    let sampleValues: [UInt8]   // first few distinct values, for eyeballing

    var isConstant: Bool { distinct == 1 }

    /// Heuristic tags so the UI can highlight promising fields.
    var hints: String {
        if isConstant { return "const \(String(format: "%02X", min))" }
        var tags: [String] = []
        if min >= 35, max <= 120 { tags.append("hr?") }
        if distinct >= 16 { tags.append("counter?") }
        return tags.joined(separator: " ")
    }
}

@MainActor
final class HistoricalAnalyzer: ObservableObject {

    @Published var stats: [ByteStat] = []
    @Published var packetsAnalyzed: Int = 0
    @Published var isRunning = false

    /// Pair-wise 16-bit LE stats — useful for finding RR intervals,
    /// raw PPG samples, strain counters, etc.
    @Published var pairStats: [(position: Int, min: UInt16, max: UInt16, distinct: Int)] = []

    func run() async {
        isRunning = true
        defer { isRunning = false }

        // Read the CSV off the main thread.
        let rows: [[UInt8]] = await Task.detached {
            let text = (try? String(contentsOf: URL(fileURLWithPath: HistoricalLogger.shared.path),
                                     encoding: .utf8)) ?? ""
            return text.split(separator: "\n").dropFirst().compactMap { line -> [UInt8]? in
                let cols = line.split(separator: ",")
                guard cols.count >= 4 else { return nil }
                return Self.parseHex(String(cols[3]))
            }
        }.value

        guard !rows.isEmpty else {
            stats = []
            pairStats = []
            packetsAnalyzed = 0
            return
        }

        let width = rows.map { $0.count }.min() ?? 0
        packetsAnalyzed = rows.count

        var out: [ByteStat] = []
        out.reserveCapacity(width)
        for pos in 0..<width {
            var mn: UInt8 = 0xFF, mx: UInt8 = 0x00
            var seen: Set<UInt8> = []
            for row in rows {
                let v = row[pos]
                if v < mn { mn = v }
                if v > mx { mx = v }
                if seen.count < 8 { seen.insert(v) }
            }
            let samples = Array(seen).sorted().prefix(6).map { $0 }
            out.append(ByteStat(id: pos, min: mn, max: mx, distinct: seen.count, sampleValues: Array(samples)))
        }
        stats = out

        // 16-bit LE pair analysis starting from offset 5 (skip framing).
        var pairs: [(position: Int, min: UInt16, max: UInt16, distinct: Int)] = []
        for pos in 5..<(width - 1) {
            var mn: UInt16 = 0xFFFF, mx: UInt16 = 0x0000
            var seen: Set<UInt16> = []
            for row in rows {
                let v = UInt16(row[pos]) | (UInt16(row[pos+1]) << 8)
                if v < mn { mn = v }
                if v > mx { mx = v }
                if seen.count < 100 { seen.insert(v) }
            }
            // Only surface pairs that look interesting.
            if seen.count >= 3 && mx > mn + 50 {
                pairs.append((pos, mn, mx, seen.count))
            }
        }
        pairStats = pairs
    }

    nonisolated private static func parseHex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let next = s.index(i, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
            if let b = UInt8(s[i..<next], radix: 16) { out.append(b) }
            i = next
        }
        return out
    }
}
