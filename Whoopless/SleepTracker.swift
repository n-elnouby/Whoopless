//
//  SleepTracker.swift
//  Whoopless
//
//  Sleep session tracker. Supports manual Start/Stop and optional
//  automatic detection based on HR pattern + time of day.
//

import Foundation
import Combine
import HealthKit

@MainActor
final class SleepTracker: ObservableObject {

    @Published var isTracking = false
    @Published var sessionStart: Date?
    @Published var elapsedSeconds: TimeInterval = 0
    /// "likely asleep" inferred from HR trend over the last ~5 min.
    @Published var likelyAsleepNow = false

    /// Filled by `stop()` with a previewable summary of the just-finished
    /// session. Setting this triggers the review sheet in the UI; the user
    /// then confirms (writes to Health) or discards.
    @Published var pendingReview: SleepReview?

    /// Most recent confirmed write — shown in the sleep card as a "last night"
    /// summary so MANTIS-style apps aren't the only place to see it.
    @Published var lastWriteSummary: String?

    /// When enabled, the tracker starts/stops sessions automatically from HR
    /// patterns during typical sleep hours. Persisted across launches.
    @Published var autoDetectEnabled: Bool = false {
        didSet { UserDefaults.standard.set(autoDetectEnabled, forKey: defaultsAutoKey) }
    }

    /// Rolling 10th-percentile HR over the last 24h. The "asleep" threshold
    /// is derived from this, so it adapts to the individual user.
    @Published var baselineBPM: Double = 65

    private let defaultsKey     = "whoopless.sleep.sessionStart"
    private let defaultsAutoKey = "whoopless.sleep.autoDetect"
    private weak var health: HealthKitManager?

    /// HR history during an active session.
    private struct HRPoint { let t: Date; let bpm: Int }
    private var hrLog: [HRPoint] = []
    /// Cap at 50,000 entries — at 1 Hz incoming HR that's ~14 hours of history,
    /// enough to cover any reasonable sleep session. Earlier we used 3000,
    /// which only covered ~50 minutes — so multi-hour sessions lost the early
    /// part of the night and most bins got classified as "no data".
    private let hrLogCap = 50_000

    /// Accelerometer magnitude history during an active session — fed in via
    /// `ingestAccelMag` from the historical-packet pipeline. Used for motion
    /// variance per epoch.
    private struct AccelPoint { let t: Date; let mag: Double }
    private var accelLog: [AccelPoint] = []
    private let accelLogCap = 50_000

    /// Per-30-second epoch features computed during the session. Exposed via
    /// CSV export for offline classifier development.
    @Published private(set) var epochFeatures: [SleepEpochFeatures] = []
    private var lastEpochComputedAt: Date = .distantPast
    private let epochSeconds: TimeInterval = 30

    /// Beat-to-beat RR intervals accumulated during this session (from the
    /// historical packets' byte 23-30 RR field). Drives the nightly HRV summary.
    private var sessionRRs: [Double] = []

    /// HR history for the last 24h — used for baseline and auto-detection.
    /// Kept separately because it must persist even when no session is active.
    private var dailyHR: [HRPoint] = []
    private let dailyHRCap = 24 * 60 * 60            // 1 per sec × 24 h = 86400 — but we only save once per 10s so this is way over-allocated
    private let dailyHRWindow: TimeInterval = 24 * 3600

    /// State for the auto-detector's "is HR below threshold for long enough" hysteresis.
    private var lowHRStreakStart: Date?
    private var highHRStreakStart: Date?
    /// When HR rises above the sleep threshold, we wait this long before resetting
    /// the streak — a single over-threshold sample is probably motion artifact.
    private var lastLowHRObservation: Date?
    private var lastBaselineRecompute: Date = .distantPast

    // Diagnostic state for the UI.
    @Published var autoStatus: String = "—"

    init(health: HealthKitManager) {
        self.health = health
        autoDetectEnabled = UserDefaults.standard.bool(forKey: defaultsAutoKey)
        restore()
    }

    // MARK: - Public API

    func start() {
        let now = Date()
        sessionStart = now
        isTracking = true
        hrLog.removeAll()
        UserDefaults.standard.set(now, forKey: defaultsKey)
        updateElapsed()
    }

    /// Stop tracking and build a previewable review of the session. The user
    /// then confirms (writes to Health) or discards via `confirmAndWrite()` /
    /// `discardReview()`. Auto-detect calls this directly; manual stop goes
    /// through the UI which routes to the same place.
    func stop() {
        guard let start = sessionStart else { reset(); return }
        let end = Date()
        let review = buildReview(start: start, end: end)
        // Persist epoch features to a session-tagged CSV before reset() wipes
        // them. The user can export from the review sheet for offline analysis.
        savedEpochFeaturesCSV = exportEpochFeaturesCSV()
        // Snapshot for the master CSV — appended on confirm, dropped on discard.
        pendingEpochFeaturesSnapshot = epochFeatures
        // Tear down the live session state but KEEP `pendingReview` set so the
        // UI can surface the sheet. (reset() doesn't touch pendingReview.)
        pendingReview = review
        reset()
    }

    /// URL of the CSV from the last completed session (after stop()). Lets
    /// the review sheet expose a ShareLink so the data leaves the device.
    @Published var savedEpochFeaturesCSV: URL?

    /// Snapshot of `epochFeatures` taken at stop() time. `reset()` wipes the
    /// live array, but confirmAndWrite() runs LATER when the user taps
    /// Confirm — by which time the live array is empty. Snapshotting here
    /// preserves the data for the master-CSV append on confirm.
    private var pendingEpochFeaturesSnapshot: [SleepEpochFeatures] = []

    /// User confirmed the review — write everything to Health.
    func confirmAndWrite(_ review: SleepReview) async {
        guard let health = health else { return }
        // Write one inBed segment for the whole (possibly trimmed) window…
        health.saveSleep(start: review.sessionStart, end: review.sessionEnd, value: .inBed)
        // …then write each bin as its (possibly user-edited) classification.
        for bin in review.binsInRange {
            // Clamp bin edges to the session window in case the user trimmed.
            let s = max(bin.start, review.sessionStart)
            let e = min(bin.end, review.sessionEnd)
            guard e > s else { continue }
            health.saveSleep(start: s, end: e, value: bin.classification)
        }

        // Nightly HRV summary — try the in-memory rMSSD/SDNN first, fall back
        // to a Health query if the in-memory path was nil.
        let mid = Date(timeIntervalSince1970: (review.sessionStart.timeIntervalSince1970 + review.sessionEnd.timeIntervalSince1970) / 2)
        var summarySDNN: Double?
        var summaryRMSSD: Double?
        if let sdnn = review.sdnnMs, sdnn > 5, sdnn < 200 {
            health.saveHRV(sdnn, rMSSDms: review.rMSSDMs, kind: "nightly", at: mid)
            summarySDNN = sdnn
            summaryRMSSD = review.rMSSDMs
        } else {
            let earlier = await health.fetchOwnHRV(from: review.sessionStart, to: review.sessionEnd)
            if earlier.count >= 3 {
                let sortedSDNN = earlier.map { $0.1 }.sorted()
                let median = sortedSDNN[sortedSDNN.count / 2]
                let medianRMSSD: Double? = {
                    let rms = earlier.compactMap { $0.2 }.sorted()
                    return rms.isEmpty ? nil : rms[rms.count / 2]
                }()
                if median > 5, median < 200 {
                    health.saveHRV(median, rMSSDms: medianRMSSD, kind: "nightly", at: mid)
                    summarySDNN = median
                    summaryRMSSD = medianRMSSD
                }
            }
        }

        // Build the user-facing summary string.
        let asleepHr = review.totalAsleep / 3600
        let awakeMin = Int(review.totalAwake / 60)
        let efficiencyPct = Int(review.efficiency * 100)
        var summary = String(
            format: "Wrote %.1fh asleep · %d min awake · %d%% efficient",
            asleepHr, awakeMin, efficiencyPct
        )
        if let sdnn = summarySDNN {
            summary += String(format: " · SDNN %d ms", Int(sdnn))
        }
        if let r = summaryRMSSD {
            summary += String(format: " · rMSSD %d ms", Int(r))
        }
        lastWriteSummary = summary
        // Append this confirmed session to the multi-night master CSV used
        // for the per-user sleep classifier training dataset.
        appendToMasterEpochFeaturesCSV()
        pendingEpochFeaturesSnapshot = []
        pendingReview = nil
    }

    /// User discarded the review — drop everything, write nothing.
    func discardReview() {
        pendingEpochFeaturesSnapshot = []
        pendingReview = nil
    }

    // MARK: - Review construction

    private func buildReview(start: Date, end: Date) -> SleepReview {
        // Bin classifications (mirrors writeSegmentsToHealth's logic so the
        // user previews the same thing we'd otherwise write).
        let bins = computeBins(start: start, end: end)
        // RR-based SDNN + rMSSD if we have enough samples.
        let (sdnn, rMSSD) = computeRRBasedHRV(rrs: sessionRRs)
        return SleepReview(
            sessionStart: start,
            sessionEnd: end,
            bins: bins,
            sdnnMs: sdnn,
            rMSSDMs: rMSSD,
            rrCount: sessionRRs.count
        )
    }

    private func computeBins(start: Date, end: Date) -> [SleepReviewBin] {
        // Reuse the generic binning over our live hrLog.
        let pts = hrLog.map { (t: $0.t, bpm: Double($0.bpm)) }
        return Self.computeBins(start: start, end: end, hrSamples: pts)
    }

    /// Generic binning routine — used both by the live tracker (with hrLog)
    /// and the manual-review flow (with HR samples fetched from Apple Health).
    static func computeBins(start: Date, end: Date,
                            hrSamples: [(t: Date, bpm: Double)]) -> [SleepReviewBin] {
        // No HR data → one big asleep bin (user opted in to tracking, trust them).
        if hrSamples.isEmpty {
            return [SleepReviewBin(start: start, end: end,
                                   classification: .asleepUnspecified,
                                   meanHR: nil)]
        }
        let sortedBpm = hrSamples.map { $0.bpm }.sorted()
        let p10 = sortedBpm[max(0, sortedBpm.count / 10)]
        let wakeThreshold = p10 * 1.10 + 3

        var out: [SleepReviewBin] = []
        // 2-minute bins. Was 5-minute; tightened so SOL Path A consumers
        // (e.g. recovery scorers reading inBed → first asleep delta) get
        // sub-5-minute resolution. Costs more samples per night but Apple
        // Health dedupes aggressively and 240 samples for 8h sleep is fine.
        let binSeconds: TimeInterval = 2 * 60
        var cursor = start
        while cursor < end {
            let binEnd = min(cursor.addingTimeInterval(binSeconds), end)
            let samples = hrSamples.filter { $0.t >= cursor && $0.t < binEnd }
            let value: HKCategoryValueSleepAnalysis
            var meanHR: Double?
            if samples.isEmpty {
                value = .asleepUnspecified
            } else {
                let m = samples.map { $0.bpm }.reduce(0, +) / Double(samples.count)
                meanHR = m
                value = m < wakeThreshold ? .asleepUnspecified : .awake
            }
            out.append(SleepReviewBin(start: cursor, end: binEnd,
                                      classification: value, meanHR: meanHR))
            cursor = binEnd
        }
        return out
    }

    /// Build a sleep review from data already in Apple Health, without
    /// requiring a live tracking session. Defaults to last night
    /// (yesterday 22:00 → today 07:00, clamped to now). Useful when the user
    /// forgot to start tracking, or to test the review flow.
    func buildManualReview(from customStart: Date? = nil,
                           to customEnd: Date? = nil) async {
        guard let health = health else { return }

        let (start, end) = Self.defaultReviewWindow(start: customStart, end: customEnd)
        let hrRaw = await health.fetchHR(from: start, to: end)
        let hrSamples = hrRaw.map { (t: $0.0, bpm: $0.1) }
        let hrvSamples = await health.fetchOwnHRV(from: start, to: end)

        let bins = Self.computeBins(start: start, end: end, hrSamples: hrSamples)

        // HRV summary from existing Health samples — median SDNN + median rMSSD.
        let sdnn: Double? = {
            let xs = hrvSamples.map { $0.1 }.sorted()
            return xs.isEmpty ? nil : xs[xs.count / 2]
        }()
        let rMSSD: Double? = {
            let xs = hrvSamples.compactMap { $0.2 }.sorted()
            return xs.isEmpty ? nil : xs[xs.count / 2]
        }()

        pendingReview = SleepReview(
            sessionStart: start,
            sessionEnd: end,
            bins: bins,
            sdnnMs: sdnn,
            rMSSDMs: rMSSD,
            rrCount: 0   // no live RRs in manual mode — HRV came from Health
        )
    }

    /// Default "last night" window. If `start` or `end` are provided they
    /// override the defaults.
    static func defaultReviewWindow(start customStart: Date?, end customEnd: Date?)
        -> (Date, Date)
    {
        let cal = Calendar.current
        let now = Date()
        // "Yesterday" relative to "now minus 12 hours" — handles edge cases
        // around midnight (if it's currently 01:00 we still want last night).
        let anchor = now.addingTimeInterval(-12 * 3600)
        var startComps = cal.dateComponents([.year, .month, .day], from: anchor)
        startComps.hour = 22; startComps.minute = 0
        let defaultStart = cal.date(from: startComps) ?? now.addingTimeInterval(-9 * 3600)
        var endComps = cal.dateComponents([.year, .month, .day], from: now)
        endComps.hour = 7; endComps.minute = 0
        let defaultEnd = min(cal.date(from: endComps) ?? now, now)

        return (customStart ?? defaultStart, customEnd ?? defaultEnd)
    }

    private func computeRRBasedHRV(rrs: [Double]) -> (Double?, Double?) {
        guard rrs.count >= 20 else { return (nil, nil) }
        // Malik's rule: drop RRs that differ by >20% from neighbors.
        var clean: [Double] = []
        var prev: Double = 0
        for rr in rrs {
            if prev == 0 || abs(rr - prev) / prev <= 0.20 {
                clean.append(rr)
            }
            prev = rr
        }
        guard clean.count >= 20 else { return (nil, nil) }
        let mean = clean.reduce(0, +) / Double(clean.count)
        let varsum = clean.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
        let sdnn = (varsum / Double(clean.count - 1)).squareRoot()
        let diffs = zip(clean, clean.dropFirst()).map { $1 - $0 }
        let sqSum = diffs.reduce(0.0) { $0 + $1 * $1 }
        let rMSSD = diffs.isEmpty ? 0 : (sqSum / Double(diffs.count)).squareRoot()
        return (sdnn > 0 ? sdnn : nil, rMSSD > 0 ? rMSSD : nil)
    }

    // (Old direct-write paths removed — confirmAndWrite() handles all writes
    // now, fed by the user-previewed SleepReview.)

    func cancel() { reset() }

    /// Feed a beat-to-beat RR interval (from a historical packet). Accumulated
    /// only while a session is active — used for the morning HRV summary.
    func ingestRR(_ rrMs: Double) {
        guard isTracking, rrMs >= 300, rrMs <= 2000 else { return }
        sessionRRs.append(rrMs)
        // Cap at 50k samples (~14 hours at 60 bpm).
        if sessionRRs.count > 50_000 {
            sessionRRs.removeFirst(sessionRRs.count - 50_000)
        }
        maybeComputeEpoch()
    }

    /// Feed accelerometer magnitude (from a historical packet's accX/Y/Z).
    /// Called from the same path that calls `ingestRR`.
    func ingestAccelMag(_ magG: Double) {
        guard isTracking else { return }
        let now = Date()
        accelLog.append(AccelPoint(t: now, mag: magG))
        if accelLog.count > accelLogCap {
            accelLog.removeFirst(accelLog.count - accelLogCap)
        }
    }

    /// Roll a new 30-second epoch's features when enough time has passed.
    /// Called from the RR ingest path (which fires roughly once per second
    /// during active sync).
    private func maybeComputeEpoch() {
        let now = Date()
        guard let start = sessionStart else { return }
        if now.timeIntervalSince(lastEpochComputedAt) < epochSeconds { return }
        let epochEnd = now
        let epochStart = epochEnd.addingTimeInterval(-epochSeconds)

        let epochHR = hrLog
            .filter { $0.t >= epochStart && $0.t < epochEnd }
            .map { (Double($0.bpm), $0.t) }
        let epochAccel = accelLog
            .filter { $0.t >= epochStart && $0.t < epochEnd }
            .map { $0.mag }
        // Last 5 minutes of RR for frequency-domain features.
        let rr5min = Array(sessionRRs.suffix(60 * 5))   // ~5 min at 60 bpm

        let f = SleepEpochFeatures.compute(
            epochStart: epochStart,
            epochEnd: epochEnd,
            sessionStart: start,
            epochHR: epochHR.map { $0.0 },
            epochHRTimes: epochHR.map { $0.1 },
            epochAccelMag: epochAccel,
            rrFiveMinWindow: rr5min
        )
        epochFeatures.append(f)
        lastEpochComputedAt = now
    }

    /// Export accumulated epoch features as CSV for offline classifier work.
    /// Returns the URL to the file. This is the CURRENT-SESSION CSV — it
    /// gets overwritten each time stop() runs. For the multi-night dataset
    /// (14-21 night classifier training), use `masterEpochFeaturesCSVURL`
    /// which accumulates across sessions instead.
    func exportEpochFeaturesCSV() -> URL {
        var s = SleepEpochFeatures.csvHeader
        for f in epochFeatures { s += f.csvRow }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("sleep_epoch_features.csv")
        try? s.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// URL of the long-lived master CSV that accumulates features across
    /// every confirmed sleep session. Append-only — never overwritten.
    /// Each row carries epoch_start so different nights can be split apart
    /// in analysis. Use this for the 14-21 night classifier training dataset.
    var masterEpochFeaturesCSVURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("sleep_epoch_features_all_nights.csv")
    }

    /// Number of feature rows currently in the master CSV (header excluded).
    var masterEpochFeaturesRowCount: Int {
        guard let text = try? String(contentsOf: masterEpochFeaturesCSVURL, encoding: .utf8) else { return 0 }
        return max(0, text.split(separator: "\n", omittingEmptySubsequences: true).count - 1)
    }

    /// Append the snapshotted (pre-reset) session features to the master
    /// CSV. Called from `confirmAndWrite()` so only confirmed sessions land
    /// in the multi-night training dataset.
    private func appendToMasterEpochFeaturesCSV() {
        guard !pendingEpochFeaturesSnapshot.isEmpty else { return }
        let url = masterEpochFeaturesCSVURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        var s = ""
        if !exists {
            s += SleepEpochFeatures.csvHeader
        }
        for f in pendingEpochFeaturesSnapshot {
            s += f.csvRow
        }
        guard !s.isEmpty, let data = s.data(using: .utf8) else { return }
        if exists, let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// Wipe the master features CSV. Useful when starting a fresh training
    /// run or after data has been exported and processed.
    func clearMasterEpochFeaturesCSV() {
        try? FileManager.default.removeItem(at: masterEpochFeaturesCSVURL)
    }

    /// Feed the tracker fresh HR samples as they come in from BLE.
    /// Always called, whether or not we're currently in a session — the
    /// daily HR log drives baseline learning and auto-detection.
    func ingestHR(_ bpm: Int) {
        guard bpm > 0 else { return }
        let now = Date()

        // Always update the daily log.
        dailyHR.append(HRPoint(t: now, bpm: bpm))
        // Trim to last 24h.
        let cutoff = now.addingTimeInterval(-dailyHRWindow)
        if let firstInWindow = dailyHR.firstIndex(where: { $0.t >= cutoff }),
           firstInWindow > 0 {
            dailyHR.removeFirst(firstInWindow)
        }

        if isTracking {
            hrLog.append(HRPoint(t: now, bpm: bpm))
            if hrLog.count > hrLogCap {
                hrLog.removeFirst(hrLog.count - hrLogCap)
            }
            likelyAsleepNow = Self.isAsleep(recent: hrLog.suffix(60))
            updateElapsed()
        }

        // Baseline recompute — once every 10 minutes.
        if now.timeIntervalSince(lastBaselineRecompute) > 600 {
            recomputeBaseline()
            lastBaselineRecompute = now
        }

        if autoDetectEnabled {
            runAutoDetect(now: now, currentBPM: bpm)
        }
    }

    // MARK: - Auto-detect

    /// HR pattern + time-of-day state machine. Calls start()/stop() on SleepTracker
    /// itself, so everything downstream (HealthKit writing, UI, persistence) is
    /// identical to manual operation.
    private func runAutoDetect(now: Date, currentBPM: Int) {
        let hour = Calendar.current.component(.hour, from: now)
        let inBedWindow  = hour >= 21 || hour < 4        // 21:00 – 03:59
        let inWakeWindow = hour >= 5 && hour < 11        // 05:00 – 10:59

        // Sleep HR typically runs ~15% below daytime median; wake HR ~15% above.
        let lowThreshold  = baselineBPM * 0.85
        let highThreshold = baselineBPM * 1.15

        if !isTracking {
            if inBedWindow && Double(currentBPM) < lowThreshold {
                if lowHRStreakStart == nil { lowHRStreakStart = now }
                lastLowHRObservation = now
                if let streak = lowHRStreakStart,
                   now.timeIntervalSince(streak) >= 10 * 60 {
                    start()
                    lowHRStreakStart = nil
                }
            } else if inBedWindow {
                // HR is above threshold — but tolerate short excursions.
                // Only reset the streak if it stays above for 60+ seconds.
                if let lastBelow = lastLowHRObservation,
                   now.timeIntervalSince(lastBelow) > 60 {
                    lowHRStreakStart = nil
                }
            } else {
                lowHRStreakStart = nil
                lastLowHRObservation = nil
            }

            // Diagnostic: show exactly what the detector is doing right now.
            if let s = lowHRStreakStart {
                let elapsed = Int(now.timeIntervalSince(s))
                let m = elapsed / 60, sec = elapsed % 60
                autoStatus = "HR \(currentBPM) < \(Int(lowThreshold)) — streak \(m):\(String(format: "%02d", sec))"
            } else if inBedWindow {
                autoStatus = "HR \(currentBPM) (need < \(Int(lowThreshold)) to start)"
            } else {
                autoStatus = "Outside 21:00–04:00 window"
            }
        } else {
            if inWakeWindow && Double(currentBPM) > highThreshold {
                if highHRStreakStart == nil { highHRStreakStart = now }
                if let streak = highHRStreakStart,
                   now.timeIntervalSince(streak) >= 5 * 60 {
                    stop()
                    highHRStreakStart = nil
                }
            } else {
                highHRStreakStart = nil
            }
            if let s = sessionStart, now.timeIntervalSince(s) > 12 * 3600 {
                stop()
            }
            autoStatus = "Tracking — HR \(currentBPM)"
        }
    }

    private func recomputeBaseline() {
        guard dailyHR.count > 200 else { return }   // need at least ~30 min of data
        let sorted = dailyHR.map { Double($0.bpm) }.sorted()
        // 75th percentile — biased toward active / daytime HR so the sleep
        // threshold (0.85 × baseline) lands comfortably above sleep HR,
        // even when sleep samples make up a large fraction of the 24h window.
        baselineBPM = sorted[min(sorted.count - 1, (sorted.count * 3) / 4)]
    }

    // MARK: - Persistence

    private func restore() {
        if let start = UserDefaults.standard.object(forKey: defaultsKey) as? Date,
           Date().timeIntervalSince(start) < 24 * 3600 {
            sessionStart = start
            isTracking = true
            updateElapsed()
        }
    }

    private func reset() {
        isTracking = false
        sessionStart = nil
        hrLog.removeAll()
        accelLog.removeAll()
        sessionRRs.removeAll()
        epochFeatures.removeAll()
        lastEpochComputedAt = .distantPast
        elapsedSeconds = 0
        likelyAsleepNow = false
        lowHRStreakStart = nil
        highHRStreakStart = nil
        lastLowHRObservation = nil
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private func updateElapsed() {
        guard let start = sessionStart else { elapsedSeconds = 0; return }
        elapsedSeconds = Date().timeIntervalSince(start)
    }

    // MARK: - Segmentation + write

    // (writeSegmentsToHealth removed — bin computation now happens in
    // computeBins() and writes happen in confirmAndWrite() after the user
    // reviews. This makes "review before writing" the only path.)

    private static func isAsleep(recent: ArraySlice<HRPoint>) -> Bool {
        guard recent.count >= 20 else { return false }
        let bpms = recent.map { Double($0.bpm) }
        let sorted = bpms.sorted()
        let p20 = sorted[max(0, sorted.count / 5)]
        let recentMean = bpms.reduce(0, +) / Double(bpms.count)
        return recentMean < p20 * 1.05
    }
}
