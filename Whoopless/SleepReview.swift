//
//  SleepReview.swift
//  Whoopless
//
//  In-memory representation of a finished (or canceled) sleep session that
//  the user can preview, edit, and confirm BEFORE we write to Apple Health.
//  Lets the user fix obvious classification errors (auto-stop fired late,
//  awake periods misclassified, etc.) instead of having to delete-and-rewrite
//  in Apple Health.
//

import Foundation
import Combine
import HealthKit

/// A single 5-minute classification bin within a sleep session.
struct SleepReviewBin: Identifiable, Equatable {
    let id: UUID
    let start: Date
    let end: Date
    var classification: HKCategoryValueSleepAnalysis
    let meanHR: Double?      // nil when no HR data covered this bin

    init(start: Date, end: Date,
         classification: HKCategoryValueSleepAnalysis,
         meanHR: Double?) {
        self.id = UUID()
        self.start = start
        self.end = end
        self.classification = classification
        self.meanHR = meanHR
    }

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Editable preview of a sleep session prior to writing to HealthKit.
@MainActor
final class SleepReview: ObservableObject, Identifiable {
    let id = UUID()

    @Published var sessionStart: Date
    @Published var sessionEnd: Date
    @Published var bins: [SleepReviewBin]

    /// HRV summary computed from the session's RR intervals at stop time.
    /// May be nil if RR data was sparse (e.g. BLE dropped); in that case the
    /// confirm path will try a fallback query against Apple Health.
    let sdnnMs: Double?
    let rMSSDMs: Double?
    let rrCount: Int

    init(sessionStart: Date,
         sessionEnd: Date,
         bins: [SleepReviewBin],
         sdnnMs: Double?,
         rMSSDMs: Double?,
         rrCount: Int) {
        self.sessionStart = sessionStart
        self.sessionEnd = sessionEnd
        self.bins = bins
        self.sdnnMs = sdnnMs
        self.rMSSDMs = rMSSDMs
        self.rrCount = rrCount
    }

    // MARK: - Computed stats (recomputed from bins on every read)

    var totalInBed: TimeInterval { sessionEnd.timeIntervalSince(sessionStart) }

    var totalAsleep: TimeInterval {
        binsInRange.filter { Self.isAsleepValue($0.classification) }
            .reduce(0) { $0 + $1.duration }
    }

    var totalAwake: TimeInterval {
        binsInRange.filter { $0.classification == .awake }
            .reduce(0) { $0 + $1.duration }
    }

    /// Sleep efficiency as a 0–1 fraction.
    var efficiency: Double {
        totalInBed > 0 ? totalAsleep / totalInBed : 0
    }

    var asleepBinCount: Int {
        binsInRange.filter { Self.isAsleepValue($0.classification) }.count
    }

    var awakeBinCount: Int {
        binsInRange.filter { $0.classification == .awake }.count
    }

    /// Bins that fall (at least partially) inside the current session window.
    /// As the user drags the start/end times, bins outside that window are
    /// effectively ignored.
    var binsInRange: [SleepReviewBin] {
        bins.filter { $0.end > sessionStart && $0.start < sessionEnd }
    }

    // MARK: - Edit operations

    /// Toggle a bin between asleep and awake. No-op if bin is outside range.
    func toggleAwake(_ bin: SleepReviewBin) {
        guard let idx = bins.firstIndex(of: bin) else { return }
        bins[idx].classification = bins[idx].classification == .awake
            ? .asleepUnspecified
            : .awake
    }

    /// Trim the session bounds to the first and last asleep bin.
    func trimToActualSleep() {
        let asleep = binsInRange.filter { Self.isAsleepValue($0.classification) }
        guard let first = asleep.first, let last = asleep.last else { return }
        sessionStart = first.start
        sessionEnd = last.end
    }

    // MARK: - Helpers

    static func isAsleepValue(_ v: HKCategoryValueSleepAnalysis) -> Bool {
        switch v {
        case .asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM:
            return true
        default:
            return false
        }
    }
}
