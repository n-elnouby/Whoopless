//
//  HealthSnapshotLogger.swift
//  Whoopless
//
//  Captures BLE packets received in a window after we fire the
//  `healthMonitorTrigger` (0x4B) command, and pairs them with user-provided
//  reference values for SpO2 and skin temperature. Used to reverse-engineer
//  the layout of the EVENT (0x30) response packet so we can write correctly
//  calibrated SpO2 + body temperature to Apple Health.
//
//  Capture protocol:
//    1. User provides a reference SpO2 (e.g. take an Apple Watch reading at
//       the same moment, or wear a clinical pulse oximeter).
//    2. User taps "Trigger snapshot" — Whoopless fires 0x4B and opens a
//       30-second capture window. ALL incoming BLE packets during the window
//       are logged with their characteristic UUID, type byte, and full hex.
//    3. After the window, the user is prompted for the reference SpO2 / temp
//       values, plus a free-text note (e.g. "normal breathing", "30s breath
//       hold", "off-wrist room temp 22 °C").
//    4. Repeat at different SpO2 levels (normal ~98%, post-breath-hold ~94%,
//       recovery ~98%) and at different skin temps. After ~5 captures across
//       a range, byte-by-byte correlation analysis can pinpoint the SpO2 and
//       skin-temp byte positions.
//

import Foundation

final class HealthSnapshotLogger: @unchecked Sendable {

    nonisolated(unsafe) static let shared = HealthSnapshotLogger()

    /// One captured snapshot session — packets received in a 30s window plus
    /// any user-provided reference values for offline correlation analysis.
    struct Capture: Codable, Identifiable, Equatable {
        let id: UUID
        let triggeredAt: Date
        var packets: [PacketEntry]
        var refSpO2Pct: Double?      // 0–100 % (e.g. 97.5)
        var refSkinTempC: Double?    // °C
        var note: String

        var packetCount: Int { packets.count }
        var distinctTypes: [UInt8] {
            Array(Set(packets.compactMap { $0.packetType })).sorted()
        }
    }

    struct PacketEntry: Codable, Equatable {
        let receivedAt: Date
        /// Last 4 hex digits of the characteristic UUID (e.g. "0005" for
        /// 61080005-...). Lets us know where the bytes arrived.
        let characteristic: String
        /// Full bytes received in this notification. Multi-fragment payloads
        /// (large EVENT packets) are stored as separate entries — caller
        /// reassembles offline.
        let bytes: Data

        var packetType: UInt8? {
            // WHOOP frame: AA <len_lo> <len_hi> <crc8> <type> ...
            bytes.count >= 5 && bytes[0] == 0xAA ? bytes[4] : nil
        }
        var hex: String {
            bytes.map { String(format: "%02X", $0) }.joined()
        }
    }

    // MARK: - State (guarded by `queue`)

    private let queue = DispatchQueue(label: "whoopless.snaplogger", qos: .utility)
    private var _captures: [Capture] = []
    private var _activeCapture: Capture?
    private var _captureUntil: Date?

    private let fileURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("health_snapshots.json")
        load()
    }

    // MARK: - Public API (all nonisolated, internally serialized)

    /// Begin a capture window. Any packets observed via `observe(...)` for
    /// the next `window` seconds will be added to the current capture.
    /// Returns the capture ID so the caller can later annotate it.
    @discardableResult
    nonisolated func beginCapture(window: TimeInterval = 30) -> UUID {
        let id = UUID()
        queue.sync {
            // Finalize any in-flight capture first.
            self._finalizeLocked()
            self._activeCapture = Capture(
                id: id,
                triggeredAt: Date(),
                packets: [],
                refSpO2Pct: nil,
                refSkinTempC: nil,
                note: ""
            )
            self._captureUntil = Date().addingTimeInterval(window)
        }
        // Auto-finalize at the exact moment the window expires. Late-arriving
        // packets are filtered out by the `now < until` check in `observe`,
        // so there's no need for a buffer.
        queue.asyncAfter(deadline: .now() + window) { [weak self] in
            self?._finalizeLocked()
        }
        return id
    }

    /// Feed every received BLE packet here. Logger filters by capture window.
    nonisolated func observe(data: Data, characteristic: String) {
        let now = Date()
        queue.async {
            guard self._activeCapture != nil,
                  let until = self._captureUntil,
                  now < until else { return }
            let entry = PacketEntry(
                receivedAt: now,
                characteristic: characteristic,
                bytes: data
            )
            self._activeCapture?.packets.append(entry)
        }
    }

    /// Update reference values + note on a previously captured snapshot.
    nonisolated func annotate(id: UUID,
                              refSpO2Pct: Double?,
                              refSkinTempC: Double?,
                              note: String) {
        queue.sync {
            // The capture might still be the active one; finalize first.
            self._finalizeLocked()
            if let idx = self._captures.firstIndex(where: { $0.id == id }) {
                if let s = refSpO2Pct { self._captures[idx].refSpO2Pct = s }
                if let t = refSkinTempC { self._captures[idx].refSkinTempC = t }
                self._captures[idx].note = note
                self._save()
            }
        }
    }

    /// Stop the active capture immediately (manual cancel). Whatever packets
    /// have been collected so far are saved as the capture.
    nonisolated func endCaptureNow() {
        queue.sync {
            self._finalizeLocked()
        }
    }

    nonisolated func deleteCapture(id: UUID) {
        queue.sync {
            self._captures.removeAll { $0.id == id }
            self._save()
        }
    }

    nonisolated func clearAll() {
        queue.sync {
            self._captures.removeAll()
            self._activeCapture = nil
            self._captureUntil = nil
            try? FileManager.default.removeItem(at: self.fileURL)
        }
    }

    nonisolated var captures: [Capture] {
        queue.sync { self._captures }
    }

    nonisolated var isCapturing: Bool {
        queue.sync {
            guard let until = self._captureUntil else { return false }
            if Date() >= until {
                // Window expired — finalize on read so callers see a
                // consistent state (capture in `captures` list, isCapturing
                // returns false). Avoids a UI race where the timer fires
                // between window-expiry and the asyncAfter finalize.
                self._finalizeLocked()
                return false
            }
            return true
        }
    }

    nonisolated var captureRemainingSeconds: Int {
        queue.sync {
            guard let until = self._captureUntil else { return 0 }
            return max(0, Int(until.timeIntervalSinceNow))
        }
    }

    nonisolated var path: String { fileURL.path }

    /// Export all captures as a flat CSV of every packet across every capture.
    /// One row per packet — easy to load into Python/numpy for analysis.
    nonisolated func exportCSV() -> URL {
        let csv = generateCSV()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("health_snapshots_export.csv")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func generateCSV() -> String {
        var s = "capture_id,triggered_at,ref_spo2,ref_temp_c,note,packet_idx,received_at,characteristic,packet_type_hex,length,hex_bytes\n"
        let snapshot = queue.sync { self._captures }
        for cap in snapshot {
            let trig = ISO8601DateFormatter().string(from: cap.triggeredAt)
            let refS = cap.refSpO2Pct.map { String(format: "%.1f", $0) } ?? ""
            let refT = cap.refSkinTempC.map { String(format: "%.2f", $0) } ?? ""
            let note = cap.note.replacingOccurrences(of: ",", with: ";")
            for (i, p) in cap.packets.enumerated() {
                let recv = ISO8601DateFormatter().string(from: p.receivedAt)
                let typeHex = p.packetType.map { String(format: "%02X", $0) } ?? ""
                s += "\(cap.id.uuidString),\(trig),\(refS),\(refT),\(note),\(i),\(recv),\(p.characteristic),\(typeHex),\(p.bytes.count),\(p.hex)\n"
            }
        }
        return s
    }

    // MARK: - Internal (must be called inside `queue`)

    private func _finalizeLocked() {
        guard let cap = _activeCapture else { return }
        if !cap.packets.isEmpty {
            _captures.append(cap)
            _save()
        }
        _activeCapture = nil
        _captureUntil = nil
    }

    private func _save() {
        do {
            let data = try JSONEncoder().encode(_captures)
            try data.write(to: fileURL)
        } catch {
            print("HealthSnapshotLogger save failed: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([Capture].self, from: data) {
            _captures = decoded
        }
    }

    // MARK: - Byte-level correlation analysis
    //
    // Given a set of captures with reference values, find which byte
    // positions in the (largest, presumably-EVENT-0x30) packet of each
    // capture correlate with the reference value. The byte position with
    // highest |Pearson r| against ref_spo2 is the SpO2 byte. Same for temp.

    struct ByteCandidate: Equatable {
        let position: Int
        let interpretation: String   // "u8", "u16LE", "u8 / 2"
        /// Pearson r against reference, or `.nan` for stability candidates
        /// where we couldn't compute a correlation due to insufficient variation.
        let correlation: Double
        let n: Int                   // pairs used
        let sampleValues: [Double]
        /// "correlation" or "stability" — explains how this candidate was found.
        let mode: String
    }

    /// Find byte positions correlated with `ref_spo2` and `ref_temp_c` across
    /// all captures that have both: a reference value AND a 0x30 EVENT packet.
    ///
    /// Two complementary modes are run:
    ///   - **Correlation** (Pearson r > 0.7) — best when reference values vary.
    ///     Skin temp is easy to vary (off-wrist vs on-wrist gives 10 °C+ swing).
    ///   - **Stability** — bytes whose values are consistently in the plausible
    ///     range across ALL captures. SpO2 is hard to vary (Apple Watch isn't
    ///     sensitive enough to register 30 s breath-holds in healthy adults),
    ///     so we instead look for bytes that always read 92-100 (u8) or
    ///     9200-10000 (u16 fixed-point). Nothing else in a 0x30 packet
    ///     randomly happens to fit that pattern across multiple captures.
    nonisolated func analyzeCorrelations() -> (spo2: [ByteCandidate], temp: [ByteCandidate]) {
        let snapshot = queue.sync { self._captures }
        // Pull the largest **52-byte** 0x30 packet from each capture.
        //
        // The 0x30 EVENT type comes in multiple sub-types — a 52-byte "full
        // snapshot result" packet plus shorter status/intermediate packets
        // (24, 20, etc.). They have different byte layouts, so correlating
        // across mixed sub-types finds spurious candidates. We only consider
        // 52-byte packets here, which is the SpO2/temp result family.
        var rows: [(spo2: Double?, temp: Double?, bytes: [UInt8])] = []
        for cap in snapshot {
            guard let largest = cap.packets
                .filter({ $0.packetType == 0x30 && $0.bytes.count == 52 })
                .max(by: { $0.bytes.count < $1.bytes.count })
            else { continue }
            rows.append((cap.refSpO2Pct, cap.refSkinTempC, [UInt8](largest.bytes)))
        }
        guard rows.count >= 3 else { return ([], []) }

        let maxLen = rows.map { $0.bytes.count }.min() ?? 0
        var spo2Cands: [ByteCandidate] = []
        var tempCands: [ByteCandidate] = []

        // Skip the packet header + timestamp + sequence area when scanning
        // for candidates. Bytes 0-3 are AA + length + CRC8, byte 4 is type
        // (0x30), bytes 5 + 8-11 carry sub-type / sequence / Unix timestamp
        // — all guaranteed to vary across captures for non-physiological
        // reasons. Those bytes will appear as high-correlation candidates
        // when they correlate with capture order, which is misleading.
        let skipHeaderUpTo = 16

        // Helper to compute Pearson r given xs, ys.
        func pearson(_ xs: [Double], _ ys: [Double]) -> Double {
            guard xs.count == ys.count, xs.count > 1 else { return 0 }
            let n = Double(xs.count)
            let xm = xs.reduce(0, +) / n
            let ym = ys.reduce(0, +) / n
            var num = 0.0, xv = 0.0, yv = 0.0
            for i in 0..<xs.count {
                let dx = xs[i] - xm, dy = ys[i] - ym
                num += dx*dy; xv += dx*dx; yv += dy*dy
            }
            return (xv > 0 && yv > 0) ? num / (xv.squareRoot() * yv.squareRoot()) : 0
        }

        // Captures with reference values
        let spo2Rows = rows.compactMap { row -> (Double, [UInt8])? in
            guard let s = row.spo2 else { return nil }
            return (s, row.bytes)
        }
        let tempRows = rows.compactMap { row -> (Double, [UInt8])? in
            guard let t = row.temp else { return nil }
            return (t, row.bytes)
        }

        for pos in skipHeaderUpTo..<maxLen {
            // ---- u8 ----
            if spo2Rows.count >= 3 {
                let xs = spo2Rows.map { Double($0.1[pos]) }
                let ys = spo2Rows.map { $0.0 }
                let r = pearson(xs, ys)
                // Correlation candidate
                if abs(r) > 0.7 {
                    spo2Cands.append(ByteCandidate(
                        position: pos, interpretation: "u8",
                        correlation: r, n: xs.count,
                        sampleValues: xs, mode: "correlation"))
                }
                // Stability candidate: every byte value in [92, 100] AND
                // its mean within ±2 of the mean reference SpO2.
                let allInRange = xs.allSatisfy { $0 >= 92 && $0 <= 100 }
                let meanX = xs.reduce(0, +) / Double(xs.count)
                let meanY = ys.reduce(0, +) / Double(ys.count)
                if allInRange, abs(meanX - meanY) < 2.0 {
                    spo2Cands.append(ByteCandidate(
                        position: pos, interpretation: "u8",
                        correlation: r, n: xs.count,
                        sampleValues: xs, mode: "stability"))
                }
            }
            if tempRows.count >= 3 {
                let xs = tempRows.map { Double($0.1[pos]) }
                let ys = tempRows.map { $0.0 }
                let r = pearson(xs, ys)
                if abs(r) > 0.7 {
                    tempCands.append(ByteCandidate(
                        position: pos, interpretation: "u8",
                        correlation: r, n: xs.count,
                        sampleValues: xs, mode: "correlation"))
                }
                // Temp stability: byte directly in degrees C range [20, 42]
                let allInRange = xs.allSatisfy { $0 >= 20 && $0 <= 42 }
                let meanX = xs.reduce(0, +) / Double(xs.count)
                let meanY = ys.reduce(0, +) / Double(ys.count)
                if allInRange, abs(meanX - meanY) < 2.0 {
                    tempCands.append(ByteCandidate(
                        position: pos, interpretation: "u8",
                        correlation: r, n: xs.count,
                        sampleValues: xs, mode: "stability"))
                }
            }
            // ---- u16 LE ----
            if pos + 1 < maxLen {
                if spo2Rows.count >= 3 {
                    let xs = spo2Rows.map { row -> Double in
                        Double(UInt16(row.1[pos]) | (UInt16(row.1[pos+1]) << 8))
                    }
                    let ys = spo2Rows.map { $0.0 }
                    let r = pearson(xs, ys)
                    if abs(r) > 0.7 {
                        spo2Cands.append(ByteCandidate(
                            position: pos, interpretation: "u16LE",
                            correlation: r, n: xs.count,
                            sampleValues: xs, mode: "correlation"))
                    }
                    // u16 fixed-point %×100 stability: values in [9200, 10000]
                    // and mean within ±200 of (refSpO2 × 100)
                    let inRange = xs.allSatisfy { $0 >= 9200 && $0 <= 10000 }
                    let meanX = xs.reduce(0, +) / Double(xs.count)
                    let meanY100 = (ys.reduce(0, +) / Double(ys.count)) * 100
                    if inRange, abs(meanX - meanY100) < 200 {
                        spo2Cands.append(ByteCandidate(
                            position: pos, interpretation: "u16LE×100",
                            correlation: r, n: xs.count,
                            sampleValues: xs, mode: "stability"))
                    }
                    // u16 raw fixed-point %×10: values in [920, 1000]
                    let inRange10 = xs.allSatisfy { $0 >= 920 && $0 <= 1000 }
                    let meanY10 = (ys.reduce(0, +) / Double(ys.count)) * 10
                    if inRange10, abs(meanX - meanY10) < 20 {
                        spo2Cands.append(ByteCandidate(
                            position: pos, interpretation: "u16LE×10",
                            correlation: r, n: xs.count,
                            sampleValues: xs, mode: "stability"))
                    }
                }
                if tempRows.count >= 3 {
                    let xs = tempRows.map { row -> Double in
                        Double(UInt16(row.1[pos]) | (UInt16(row.1[pos+1]) << 8))
                    }
                    let ys = tempRows.map { $0.0 }
                    let r = pearson(xs, ys)
                    if abs(r) > 0.7 {
                        tempCands.append(ByteCandidate(
                            position: pos, interpretation: "u16LE",
                            correlation: r, n: xs.count,
                            sampleValues: xs, mode: "correlation"))
                    }
                    // u16 fixed-point °C×100 stability: values in [2000, 4200]
                    let inRange = xs.allSatisfy { $0 >= 2000 && $0 <= 4200 }
                    let meanX = xs.reduce(0, +) / Double(xs.count)
                    let meanY100 = (ys.reduce(0, +) / Double(ys.count)) * 100
                    if inRange, abs(meanX - meanY100) < 200 {
                        tempCands.append(ByteCandidate(
                            position: pos, interpretation: "u16LE×100",
                            correlation: r, n: xs.count,
                            sampleValues: xs, mode: "stability"))
                    }
                }
            }
        }

        // Sort: correlation candidates first (by |r|), then stability candidates.
        func sortKey(_ c: ByteCandidate) -> Double {
            c.mode == "correlation" ? -abs(c.correlation) - 100 : -1
        }
        spo2Cands.sort { sortKey($0) < sortKey($1) }
        tempCands.sort { sortKey($0) < sortKey($1) }
        return (spo2Cands, tempCands)
    }
}
