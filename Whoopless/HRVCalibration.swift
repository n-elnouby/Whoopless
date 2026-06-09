//
//  HRVCalibration.swift
//  Whoopless
//
//  Pairs Apple Watch HRV samples with WHOOP-derived SDNN over matching
//  time windows, then reports how well (or badly) they correlate.
//

import Foundation
import Combine

struct HRVPair: Identifiable {
    let id = UUID()
    let time: Date
    let watchMs: Double
    let whoopMs: Double
}

struct HRVStats {
    let n: Int
    let correlation: Double       // Pearson r
    let watchMean: Double
    let whoopMean: Double
    let watchSD: Double
    let whoopSD: Double
    /// Linear fit watch ≈ slope * whoop + intercept (if useful).
    let slope: Double
    let intercept: Double
}

@MainActor
final class HRVCalibration: ObservableObject {

    @Published var pairs: [HRVPair] = []
    @Published var stats: HRVStats?
    @Published var isRunning = false
    @Published var statusMessage: String = ""

    // MARK: - Saved per-user calibration
    //
    // After running comparison and seeing a usable correlation, the user can
    // save the linear fit. Future SDNN writes are then transformed via:
    //   calibratedSDNN = savedSlope * rawSDNN + savedIntercept
    //
    // This corrects the systematic gap between WHOOP-derived SDNN and the
    // user's specific Apple Watch baseline.

    private static let slopeKey     = "whoopless.cal.sdnnSlope"
    private static let interceptKey = "whoopless.cal.sdnnIntercept"
    private static let enabledKey   = "whoopless.cal.enabled"
    private static let savedAtKey   = "whoopless.cal.savedAt"
    private static let savedNKey    = "whoopless.cal.savedN"
    private static let savedRKey    = "whoopless.cal.savedR"

    @Published var calibrationEnabled: Bool {
        didSet { UserDefaults.standard.set(calibrationEnabled, forKey: Self.enabledKey) }
    }
    @Published var savedSlope: Double = 1.0
    @Published var savedIntercept: Double = 0.0
    @Published var savedAt: Date?
    @Published var savedN: Int = 0
    @Published var savedR: Double = 0.0

    private weak var health: HealthKitManager?

    init(health: HealthKitManager) {
        self.health = health
        let d = UserDefaults.standard
        self.calibrationEnabled = d.bool(forKey: Self.enabledKey)
        self.savedSlope     = d.object(forKey: Self.slopeKey) as? Double ?? 1.0
        self.savedIntercept = d.object(forKey: Self.interceptKey) as? Double ?? 0.0
        self.savedAt        = d.object(forKey: Self.savedAtKey) as? Date
        self.savedN         = d.integer(forKey: Self.savedNKey)
        self.savedR         = d.object(forKey: Self.savedRKey) as? Double ?? 0.0
    }

    /// Persist the current `stats` linear fit and turn calibration on.
    func saveCurrentFit() {
        guard let s = stats, s.n >= 5, abs(s.correlation) >= 0.3, s.slope > 0 else {
            statusMessage = "Need at least 5 paired samples and r ≥ 0.3 to save."
            return
        }
        savedSlope = s.slope
        savedIntercept = s.intercept
        savedAt = Date()
        savedN = s.n
        savedR = s.correlation
        calibrationEnabled = true
        let d = UserDefaults.standard
        d.set(savedSlope, forKey: Self.slopeKey)
        d.set(savedIntercept, forKey: Self.interceptKey)
        d.set(savedAt, forKey: Self.savedAtKey)
        d.set(savedN, forKey: Self.savedNKey)
        d.set(savedR, forKey: Self.savedRKey)
        statusMessage = String(format:
            "Saved: SDNN_calibrated = %.2f × raw + %.0f (n=%d, r=%.2f)",
            savedSlope, savedIntercept, savedN, savedR)
    }

    /// Drop calibration — future writes use raw values again.
    func clearSavedFit() {
        savedSlope = 1.0
        savedIntercept = 0.0
        savedAt = nil
        savedN = 0
        savedR = 0
        calibrationEnabled = false
        let d = UserDefaults.standard
        d.removeObject(forKey: Self.slopeKey)
        d.removeObject(forKey: Self.interceptKey)
        d.removeObject(forKey: Self.savedAtKey)
        d.removeObject(forKey: Self.savedNKey)
        d.removeObject(forKey: Self.savedRKey)
        d.set(false, forKey: Self.enabledKey)
        statusMessage = "Calibration cleared."
    }

    /// Apply the saved calibration to a raw SDNN value. Safe to call from any
    /// actor — reads UserDefaults only. Returns the input unchanged if calibration
    /// is disabled or has obviously wrong parameters.
    nonisolated static func calibrateSDNN(_ raw: Double) -> Double {
        let d = UserDefaults.standard
        guard d.bool(forKey: enabledKey) else { return raw }
        let slope     = d.object(forKey: slopeKey) as? Double ?? 1.0
        let intercept = d.object(forKey: interceptKey) as? Double ?? 0.0
        guard slope > 0 else { return raw }
        let calibrated = slope * raw + intercept
        // Clamp to a sane physiological range so a bad fit can't write garbage.
        return max(5, min(200, calibrated))
    }

    /// Run the comparison over the last 24 hours.
    func runComparison(lookbackHours: Double = 24) async {
        guard let health = health else { return }
        isRunning = true
        defer { isRunning = false }

        statusMessage = "Loading Apple Watch HRV…"
        let end = Date()
        let start = end.addingTimeInterval(-lookbackHours * 3600)
        let watchSamples = await health.fetchWatchHRV(from: start, to: end)
        guard !watchSamples.isEmpty else {
            statusMessage = "No Apple Watch HRV samples in the last \(Int(lookbackHours))h."
            pairs = []
            stats = nil
            return
        }

        statusMessage = "Loading WHOOP RR log…"
        let rrs = RRLogger.shared.readAll()
            .filter { $0.0 >= start && $0.0 <= end }
        guard rrs.count > 50 else {
            statusMessage = "Not enough WHOOP RR data yet (\(rrs.count) samples)."
            pairs = []
            stats = nil
            return
        }

        statusMessage = "Pairing \(watchSamples.count) Watch samples with WHOOP windows…"

        // Watch HRV samples typically represent a 1-minute window. For each
        // Watch sample, compute WHOOP SDNN over a ±30-second window around it.
        var out: [HRVPair] = []
        for (t, watchMs) in watchSamples {
            let windowStart = t.addingTimeInterval(-30)
            let windowEnd   = t.addingTimeInterval(30)
            let whoopRRs = rrs.filter { $0.0 >= windowStart && $0.0 <= windowEnd }.map { $0.1 }
            guard whoopRRs.count >= 10 else { continue }
            let sdnn = HRVMath.sdnnMs(whoopRRs)
            out.append(HRVPair(time: t, watchMs: watchMs, whoopMs: sdnn))
        }
        pairs = out.sorted { $0.time < $1.time }

        if pairs.count >= 5 {
            stats = Self.computeStats(pairs)
            statusMessage = "Paired \(pairs.count) windows."
        } else {
            stats = nil
            statusMessage = "Only \(pairs.count) matched windows — need more overnight data."
        }
    }

    // MARK: - Stats

    private static func computeStats(_ pairs: [HRVPair]) -> HRVStats {
        let n = pairs.count
        let xs = pairs.map { $0.whoopMs }
        let ys = pairs.map { $0.watchMs }
        let xMean = xs.reduce(0, +) / Double(n)
        let yMean = ys.reduce(0, +) / Double(n)
        var num = 0.0, xVar = 0.0, yVar = 0.0
        for i in 0..<n {
            let dx = xs[i] - xMean
            let dy = ys[i] - yMean
            num  += dx * dy
            xVar += dx * dx
            yVar += dy * dy
        }
        let xSD = (xVar / Double(n - 1)).squareRoot()
        let ySD = (yVar / Double(n - 1)).squareRoot()
        let r = (xVar > 0 && yVar > 0) ? num / (xVar.squareRoot() * yVar.squareRoot()) : 0
        // Linear fit: y (watch) = slope * x (whoop) + intercept
        let slope = xVar > 0 ? num / xVar : 0
        let intercept = yMean - slope * xMean

        return HRVStats(
            n: n,
            correlation: r,
            watchMean: yMean,
            whoopMean: xMean,
            watchSD: ySD,
            whoopSD: xSD,
            slope: slope,
            intercept: intercept
        )
    }
}
