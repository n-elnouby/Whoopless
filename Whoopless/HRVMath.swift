//
//  HRVMath.swift
//  Whoopless
//
//  Pure functions on a buffer of RR-intervals (milliseconds).
//  No actor isolation, no state — the ContentView calls these whenever the
//  RR buffer changes.
//

import Foundation

enum HRVMath {

    // MARK: - SDNN (HRV)

    /// Standard deviation of NN (RR) intervals in milliseconds.
    /// The value Apple Health stores as "Heart Rate Variability".
    nonisolated static func sdnnMs(_ rrs: [Double]) -> Double {
        guard rrs.count > 1 else { return 0 }
        let mean = rrs.reduce(0, +) / Double(rrs.count)
        let varSum = rrs.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
        return (varSum / Double(rrs.count - 1)).squareRoot()
    }

    // MARK: - Respiratory rate from RSA

    /// Estimate respiratory rate (breaths/min) from a window of RR-intervals.
    ///
    /// Uses Respiratory Sinus Arrhythmia: the heart speeds up on inhalation
    /// and slows on exhalation, so the RR-interval time series oscillates at
    /// breathing frequency. We detrend with a moving average, then count
    /// zero-crossings to find the oscillation period.
    ///
    /// Returns nil if the window is too short or the result is outside the
    /// physiological range (6–30 breaths/min).
    nonisolated static func respiratoryRateBpm(_ rrs: [Double]) -> Double? {
        // Need enough beats that several breathing cycles are included.
        // 40 beats @ ~70 bpm ≈ 35 s, which comfortably contains 7–10 breaths.
        guard rrs.count >= 40 else { return nil }

        // Detrend by subtracting a 5-sample moving average — removes slow HR
        // drift so the remaining signal is dominated by respiratory oscillation.
        let smoothed = movingAverage(rrs, window: 5)
        let detrended = zip(rrs, smoothed).map { $0 - $1 }

        // Count zero crossings. Each breathing cycle produces two (up + down).
        var crossings = 0
        for i in 1..<detrended.count {
            let a = detrended[i - 1], b = detrended[i]
            if (a < 0 && b >= 0) || (a >= 0 && b < 0) {
                crossings += 1
            }
        }

        // Window length in minutes: sum of RR intervals.
        let totalMin = rrs.reduce(0, +) / 60_000.0
        guard totalMin > 0.25 else { return nil }   // at least 15 s

        let breathsPerMin = (Double(crossings) / 2.0) / totalMin

        // Reject nonsense — motion artifacts sometimes produce huge values.
        guard breathsPerMin >= 6, breathsPerMin <= 30 else { return nil }
        return breathsPerMin
    }

    // MARK: - Internals

    nonisolated private static func movingAverage(_ xs: [Double], window: Int) -> [Double] {
        guard window > 1, xs.count >= window else { return xs }
        let w = max(1, window)
        var out = [Double](repeating: 0, count: xs.count)
        for i in 0..<xs.count {
            let lo = max(0, i - w / 2)
            let hi = min(xs.count - 1, i + w / 2)
            var sum = 0.0
            for j in lo...hi { sum += xs[j] }
            out[i] = sum / Double(hi - lo + 1)
        }
        return out
    }
}
