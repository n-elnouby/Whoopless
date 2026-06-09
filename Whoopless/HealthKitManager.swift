//
//  HealthKitManager.swift
//  Whoopless
//

import Foundation
import Combine
import HealthKit

/// Wraps HealthKit for writing heart-rate / HRV / respiratory-rate / sleep.
@MainActor
final class HealthKitManager: ObservableObject {

    private let store = HKHealthStore()

    @Published var isAuthorized = false
    @Published var lastError: String?

    private let hrType    = HKQuantityType(.heartRate)
    private let hrvType   = HKQuantityType(.heartRateVariabilitySDNN)
    private let respType  = HKQuantityType(.respiratoryRate)
    private let spo2Type  = HKQuantityType(.oxygenSaturation)
    private let tempType  = HKQuantityType(.bodyTemperature)
    private let sleepType = HKCategoryType(.sleepAnalysis)
    private let energyType = HKQuantityType(.activeEnergyBurned)
    private let exerciseTimeType = HKQuantityType(.appleExerciseTime)
    private let restingHRType = HKQuantityType(.restingHeartRate)
    private let bodyMassType = HKQuantityType(.bodyMass)

    // Throttle HR + HRV writes. HR uses a TWO-TIER throttle:
    //   - Resting / normal HR (< elevatedHRThreshold): 1 sample per 10 s.
    //     Plenty of resolution for everyday tracking, doesn't flood Health.
    //   - Elevated HR (≥ elevatedHRThreshold): 1 sample per 1 s.
    //     Captures workout intensity at near-continuous resolution so workout
    //     metrics (peak HR, time-in-zone) computed downstream are accurate.
    private var lastHRWrite  = Date.distantPast
    private var lastHRVWrite = Date.distantPast
    private let writeInterval: TimeInterval = 10
    private let elevatedWriteInterval: TimeInterval = 1
    private let elevatedHRThreshold: Double = 100  // bpm

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            lastError = "HealthKit not available on this device."
            return
        }
        let share: Set<HKSampleType> = [hrType, hrvType, respType, spo2Type, tempType, sleepType, energyType, exerciseTimeType]
        let read:  Set<HKObjectType> = [
            hrType, hrvType, respType, spo2Type, tempType, sleepType,
            restingHRType, bodyMassType,
            HKCharacteristicType(.dateOfBirth),
            HKCharacteristicType(.biologicalSex)
        ]
        do {
            try await store.requestAuthorization(toShare: share, read: read)
            isAuthorized = store.authorizationStatus(for: hrType) == .sharingAuthorized
        } catch {
            lastError = "HealthKit auth failed: \(error.localizedDescription)"
        }
    }

    func saveHeartRate(_ bpm: Double, at date: Date = Date()) {
        // Pick the throttle interval based on the current HR. During workouts
        // (HR ≥ elevatedHRThreshold) we write every 1 s; at rest, every 10 s.
        let interval = bpm >= elevatedHRThreshold ? elevatedWriteInterval : writeInterval
        guard bpm > 0,
              store.authorizationStatus(for: hrType) == .sharingAuthorized,
              Date().timeIntervalSince(lastHRWrite) >= interval else { return }
        lastHRWrite = Date()
        let unit = HKUnit.count().unitDivided(by: .minute())
        let q = HKQuantity(unit: unit, doubleValue: bpm)
        let sample = HKQuantitySample(
            type: hrType, quantity: q, start: date, end: date,
            metadata: [HKMetadataKeyWasUserEntered: false]
        )
        store.save(sample) { [weak self] _, err in
            if let err { Task { @MainActor in self?.lastError = "HR save: \(err.localizedDescription)" } }
        }
    }

    /// Write an SDNN HRV sample with paired rMSSD as metadata.
    ///
    /// HealthKit has no native rMSSD type, so we attach it under
    /// `com.whoopless.rMSSD_ms`. Apple Health's HRV UI ignores the extra key;
    /// rMSSD-aware readers (e.g. MANTIS) can pick it up via `HKSampleQuery`.
    ///
    /// `kind` distinguishes two streams so consumers can filter:
    ///   - `"resting"`  — gated reading, motion + HR stable (Apple-Watch-style).
    ///                    MANTIS should use these for recovery calculations.
    ///   - `"continuous"` — all-day trend reading, written regardless of motion.
    ///                    Useful for stress/activity visualization; physiologically
    ///                    higher SDNN during activity is expected.
    ///
    /// If the user has saved a calibration via HRVCalibration, the SDNN value
    /// is transformed via the linear fit (slope × raw + intercept) before being
    /// written. The raw uncalibrated value is preserved in metadata for review.
    ///
    /// Metadata keys:
    ///   - `com.whoopless.rMSSD_ms`   — paired rMSSD
    ///   - `com.whoopless.kind`       — "resting" / "continuous" / "nightly"
    ///   - `com.whoopless.rawSDNN_ms` — pre-calibration value (only if calibration applied)
    func saveHRV(_ sdnnMs: Double,
                 rMSSDms: Double? = nil,
                 kind: String? = nil,
                 at date: Date = Date()) {
        guard sdnnMs > 0,
              store.authorizationStatus(for: hrvType) == .sharingAuthorized,
              Date().timeIntervalSince(lastHRVWrite) >= writeInterval else { return }
        lastHRVWrite = Date()

        let calibrated = HRVCalibration.calibrateSDNN(sdnnMs)
        let didCalibrate = abs(calibrated - sdnnMs) > 0.001

        let q = HKQuantity(unit: .secondUnit(with: .milli), doubleValue: calibrated)
        var metadata: [String: Any] = [:]
        if let r = rMSSDms, r > 0 {
            metadata["com.whoopless.rMSSD_ms"] = r
        }
        if let k = kind {
            metadata["com.whoopless.kind"] = k
        }
        if didCalibrate {
            metadata["com.whoopless.rawSDNN_ms"] = sdnnMs
        }
        let sample = HKQuantitySample(
            type: hrvType, quantity: q, start: date, end: date,
            metadata: metadata.isEmpty ? nil : metadata
        )
        store.save(sample) { [weak self] _, err in
            if let err { Task { @MainActor in self?.lastError = "HRV save: \(err.localizedDescription)" } }
        }
    }

    /// Save SpO2 (blood oxygen saturation). `fraction` in 0.0–1.0 (so 97% = 0.97).
    /// HealthKit expects a unitless fraction (`HKUnit.percent()` uses 0–1 range).
    ///
    /// Sanity range tightened to 92–100%. Below 92% is implausible for a
    /// non-medical situation in a normal user, and almost always reflects an
    /// uncalibrated-sensor artifact rather than real desaturation. We'd rather
    /// drop the sample than write something clinically alarming and wrong.
    func saveSpO2(fraction: Double, at date: Date = Date()) {
        guard fraction >= 0.92, fraction <= 1.0,
              store.authorizationStatus(for: spo2Type) == .sharingAuthorized else { return }
        let q = HKQuantity(unit: .percent(), doubleValue: fraction)
        let sample = HKQuantitySample(type: spo2Type, quantity: q, start: date, end: date)
        store.save(sample) { [weak self] _, err in
            if let err { Task { @MainActor in self?.lastError = "SpO2 save: \(err.localizedDescription)" } }
        }
    }

    /// Save HR from a historical packet with a past timestamp (not throttled —
    /// each historical sample is 1 sec apart).
    func saveHistoricalHeartRate(_ bpm: Double, at date: Date) {
        guard bpm > 30, bpm < 220,
              store.authorizationStatus(for: hrType) == .sharingAuthorized else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let q = HKQuantity(unit: unit, doubleValue: bpm)
        let sample = HKQuantitySample(
            type: hrType, quantity: q, start: date, end: date,
            metadata: [HKMetadataKeyWasUserEntered: false]
        )
        store.save(sample) { [weak self] _, err in
            if let err { Task { @MainActor in self?.lastError = "HR(hist) save: \(err.localizedDescription)" } }
        }
    }

    /// Save skin/body temperature in °C.
    func saveBodyTemperature(_ celsius: Double, at date: Date = Date()) {
        guard celsius >= 20, celsius <= 42,
              store.authorizationStatus(for: tempType) == .sharingAuthorized else { return }
        let q = HKQuantity(unit: .degreeCelsius(), doubleValue: celsius)
        let sample = HKQuantitySample(type: tempType, quantity: q, start: date, end: date)
        store.save(sample) { [weak self] _, err in
            if let err { Task { @MainActor in self?.lastError = "Temp save: \(err.localizedDescription)" } }
        }
    }

    /// Write a slice of active calories (above-resting) for a time interval.
    /// Apple Fitness's Move ring reads from `activeEnergyBurned`. Caller is
    /// responsible for making sure the interval doesn't overlap previous
    /// writes to avoid double-counting.
    func saveActiveEnergy(kcal: Double, start: Date, end: Date) {
        guard kcal > 0,
              end > start,
              store.authorizationStatus(for: energyType) == .sharingAuthorized else { return }
        let q = HKQuantity(unit: .kilocalorie(), doubleValue: kcal)
        let sample = HKQuantitySample(type: energyType, quantity: q, start: start, end: end)
        store.save(sample) { [weak self] _, err in
            if let err { Task { @MainActor in self?.lastError = "Energy save: \(err.localizedDescription)" } }
        }
    }

    /// Write a slice of exercise time for a minute window. Apple Fitness's
    /// Exercise ring reads from `appleExerciseTime`. Standard pattern is one
    /// 1-minute sample per minute where HR (or activity) crossed an exercise
    /// threshold. Apple Watch uses a more sophisticated algorithm involving
    /// motion + HR + gait; this is the HR-only approximation.
    func saveExerciseTime(minutes: Double, start: Date, end: Date) {
        guard minutes > 0,
              end > start,
              store.authorizationStatus(for: exerciseTimeType) == .sharingAuthorized else { return }
        let q = HKQuantity(unit: .minute(), doubleValue: minutes)
        let sample = HKQuantitySample(type: exerciseTimeType, quantity: q, start: start, end: end)
        store.save(sample) { [weak self] _, err in
            if let err { Task { @MainActor in self?.lastError = "Exercise save: \(err.localizedDescription)" } }
        }
    }

    /// Read the user's age from their HealthKit-stored date of birth. Returns
    /// nil if they haven't set one or haven't granted read permission.
    func fetchUserAge() -> Int? {
        do {
            let dob = try store.dateOfBirthComponents()
            guard let year = dob.year else { return nil }
            let nowYear = Calendar.current.component(.year, from: Date())
            return max(0, nowYear - year)
        } catch {
            return nil
        }
    }

    /// Read the user's biological sex from HealthKit. Defaults to .male if
    /// not set or not authorized — Keytel for males is the more common
    /// fallback in clinical literature.
    func fetchUserBiologicalSex() -> CalorieEstimator.BiologicalSex {
        do {
            let s = try store.biologicalSex().biologicalSex
            return s == .female ? .female : .male
        } catch {
            return .male
        }
    }

    /// Read the user's most recent body weight in kg from HealthKit.
    func fetchUserWeightKg() async -> Double? {
        return await withCheckedContinuation { cont in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let q = HKSampleQuery(
                sampleType: bodyMassType,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                guard let s = samples?.first as? HKQuantitySample else {
                    cont.resume(returning: nil); return
                }
                cont.resume(returning: s.quantity.doubleValue(for: .gramUnit(with: .kilo)))
            }
            store.execute(q)
        }
    }

    /// Read the user's latest restingHeartRate sample from HealthKit (Apple
    /// Watch typically writes one per day). Falls back to nil if absent.
    func fetchRestingHR() async -> Double? {
        return await withCheckedContinuation { cont in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let q = HKSampleQuery(
                sampleType: restingHRType,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                guard let s = samples?.first as? HKQuantitySample else {
                    cont.resume(returning: nil); return
                }
                let unit = HKUnit.count().unitDivided(by: .minute())
                cont.resume(returning: s.quantity.doubleValue(for: unit))
            }
            store.execute(q)
        }
    }

    func saveRespiratoryRate(_ bpm: Double, at date: Date = Date()) {
        guard bpm > 0,
              store.authorizationStatus(for: respType) == .sharingAuthorized else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let q = HKQuantity(unit: unit, doubleValue: bpm)
        let sample = HKQuantitySample(type: respType, quantity: q, start: date, end: date)
        store.save(sample) { [weak self] _, err in
            if let err { Task { @MainActor in self?.lastError = "Resp save: \(err.localizedDescription)" } }
        }
    }

    /// Fetch HRV samples written by Whoopless in a time range. Returns
    /// `(timestamp, SDNN ms, rMSSD ms?)` tuples — rMSSD is read from the
    /// `com.whoopless.rMSSD_ms` metadata key we attach when writing.
    func fetchOwnHRV(from start: Date, to end: Date) async -> [(Date, Double, Double?)] {
        let timePred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sourcePred = HKQuery.predicateForObjects(from: HKSource.default())
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [timePred, sourcePred])
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(
                sampleType: hrvType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, _ in
                let unit = HKUnit.secondUnit(with: .milli)
                let ms = (samples ?? []).compactMap { sample -> (Date, Double, Double?)? in
                    guard let s = sample as? HKQuantitySample else { return nil }
                    let sdnn = s.quantity.doubleValue(for: unit)
                    let rmssd = s.metadata?["com.whoopless.rMSSD_ms"] as? Double
                    return (s.startDate, sdnn, rmssd)
                }
                cont.resume(returning: ms)
            }
            store.execute(q)
        }
    }

    /// Fetch heart-rate samples in a time range (any source — Apple Watch,
    /// Whoopless, etc.). Used by the manual sleep review flow to reconstruct
    /// HR-based sleep classification when no live session was running.
    func fetchHR(from start: Date, to end: Date) async -> [(Date, Double)] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(
                sampleType: hrType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, _ in
                let unit = HKUnit.count().unitDivided(by: .minute())
                let bpms = (samples ?? []).compactMap { sample -> (Date, Double)? in
                    guard let s = sample as? HKQuantitySample else { return nil }
                    return (s.startDate, s.quantity.doubleValue(for: unit))
                }
                cont.resume(returning: bpms)
            }
            store.execute(q)
        }
    }

    /// Delete Whoopless-written HR samples in a time range. Used to clean up
    /// bad data after we identify a regression (e.g. the historical-HR motion
    /// artifact that wrote stuck-at-resting values during workouts).
    func deleteOwnHeartRateSamples(from start: Date, to end: Date) async -> Int {
        let timePred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sourcePred = HKQuery.predicateForObjects(from: HKSource.default())
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [timePred, sourcePred])
        return await withCheckedContinuation { cont in
            store.deleteObjects(of: hrType, predicate: predicate) { _, count, err in
                if let err {
                    Task { @MainActor in self.lastError = "HR delete: \(err.localizedDescription)" }
                }
                cont.resume(returning: count)
            }
        }
    }

    /// Delete Whoopless-written HRV samples in a time range. Mirrors the
    /// equivalent `deleteOwnHeartRateSamples(from:to:)` for targeted cleanup.
    func deleteOwnHRVSamples(from start: Date, to end: Date) async -> Int {
        let timePred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sourcePred = HKQuery.predicateForObjects(from: HKSource.default())
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [timePred, sourcePred])
        return await withCheckedContinuation { cont in
            store.deleteObjects(of: hrvType, predicate: predicate) { _, count, err in
                if let err {
                    Task { @MainActor in self.lastError = "HRV delete: \(err.localizedDescription)" }
                }
                cont.resume(returning: count)
            }
        }
    }

    /// Delete every HRV sample ever written by Whoopless. Returns the count
    /// removed so the caller can confirm. Nuclear option — usually you want
    /// the date-ranged variant above instead.
    func deleteOwnHRVSamples() async -> Int {
        let predicate = HKQuery.predicateForObjects(from: HKSource.default())
        return await withCheckedContinuation { cont in
            store.deleteObjects(of: hrvType, predicate: predicate) { _, count, err in
                if let err { Task { @MainActor in self.lastError = "HRV delete: \(err.localizedDescription)" } }
                cont.resume(returning: count)
            }
        }
    }

    /// Fetch Apple-Watch-sourced HRV samples in a time range. Filters out
    /// samples written by Whoopless itself so we compare against ground truth.
    func fetchWatchHRV(from start: Date, to end: Date) async -> [(Date, Double)] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(
                sampleType: hrvType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, _ in
                let ms = (samples ?? []).compactMap { sample -> (Date, Double)? in
                    guard let s = sample as? HKQuantitySample else { return nil }
                    // Skip our own writes (if any sneak back in).
                    if s.sourceRevision.source.bundleIdentifier.contains("Whoopless") { return nil }
                    let unit = HKUnit.secondUnit(with: .milli)
                    return (s.startDate, s.quantity.doubleValue(for: unit))
                }
                cont.resume(returning: ms)
            }
            store.execute(q)
        }
    }

    /// Save a single sleep segment. For a full night, call this once per
    /// detected stage or once for the whole duration with `.asleepUnspecified`.
    func saveSleep(start: Date, end: Date,
                    value: HKCategoryValueSleepAnalysis = .asleepUnspecified) {
        guard end > start,
              store.authorizationStatus(for: sleepType) == .sharingAuthorized else { return }
        let sample = HKCategorySample(
            type: sleepType,
            value: value.rawValue,
            start: start,
            end: end
        )
        store.save(sample) { [weak self] _, err in
            if let err { Task { @MainActor in self?.lastError = "Sleep save: \(err.localizedDescription)" } }
        }
    }
}
