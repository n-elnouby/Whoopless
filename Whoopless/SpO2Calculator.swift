//
//  SpO2Calculator.swift
//  Whoopless
//
//  Port of OpenWhoop's Rust SpO2 algorithm (bWanShiTong/OpenWhoop,
//  src/openwhoop-algos/src/spo2.rs). Ratio-of-ratios on AC/DC components
//  of the red + IR PPG channels.
//
//  Requires ≥ 30 paired samples to emit a reading. Samples come from
//  HISTORICAL_DATA packets (bytes 68-69 = red raw, 70-71 = IR raw).
//

import Foundation

final class SpO2Calculator {

    private struct Sample { let red: UInt16; let ir: UInt16 }

    /// Rolling window of raw readings. OpenWhoop requires at least 30.
    private var buffer: [Sample] = []
    private let minSamples = 30
    private let maxSamples = 120     // cap so older samples fade out

    /// Last computed SpO2 (in %, 70-100 range), or nil if not enough data.
    private(set) var lastSpO2: Double?

    /// Minimum time between writes to Health, so we don't spam.
    private var lastEmit: Date = .distantPast
    private let emitInterval: TimeInterval = 30

    func ingest(red: UInt16, ir: UInt16) -> Double? {
        // Reject obviously bad readings (both must be > 0, and in a plausible
        // ADC range — WHOOP raw values are typically in the hundreds).
        guard red > 0, ir > 0 else { return nil }
        buffer.append(Sample(red: red, ir: ir))
        if buffer.count > maxSamples { buffer.removeFirst(buffer.count - maxSamples) }
        guard buffer.count >= minSamples else { return nil }

        // Ratio-of-ratios: (AC_red / DC_red) / (AC_ir / DC_ir)
        let reds = buffer.map { Double($0.red) }
        let irs  = buffer.map { Double($0.ir) }
        let meanRed = reds.reduce(0, +) / Double(reds.count)
        let meanIR  = irs.reduce(0, +)  / Double(irs.count)
        guard meanRed > 1.0, meanIR > 1.0 else { return nil }

        let sdRed = (reds.reduce(0.0) { $0 + ($1 - meanRed) * ($1 - meanRed) } / Double(reds.count)).squareRoot()
        let sdIR  = (irs.reduce(0.0)  { $0 + ($1 - meanIR)  * ($1 - meanIR)  } / Double(irs.count)).squareRoot()
        guard sdRed > 0.001, sdIR > 0.001 else { return nil }

        let r = (sdRed / meanRed) / (sdIR / meanIR)
        let spo2 = 110.0 - 25.0 * r
        let clamped = max(70.0, min(100.0, spo2))
        lastSpO2 = clamped
        return clamped
    }

    /// Should we write a fresh sample to Health right now?
    func shouldEmit() -> Bool {
        guard lastSpO2 != nil else { return false }
        return Date().timeIntervalSince(lastEmit) >= emitInterval
    }

    func markEmitted() { lastEmit = Date() }

    func reset() {
        buffer.removeAll()
        lastSpO2 = nil
    }
}
