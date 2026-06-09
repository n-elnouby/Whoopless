//
//  SkinTempCalibration.swift
//  Whoopless
//
//  Two-point linear calibration for the WHOOP thermistor raw value (bytes 72-73
//  of a HISTORICAL_DATA packet). The scale and offset aren't documented, so the
//  user provides two known (raw, °C) points and we fit a line.
//
//  Typical protocol:
//    • Capture a "cool" point with the strap off-wrist at ambient room temp.
//    • Capture a "warm" point with the strap on-wrist after 10 min of wear.
//  Slope = (tempWarm − tempCool) / (rawWarm − rawCool)
//  °C    = slope × rawValue + (tempCool − slope × rawCool)
//

import Foundation
import Combine

@MainActor
final class SkinTempCalibration: ObservableObject {

    @Published private(set) var rawCool: UInt16?
    @Published private(set) var tempCoolC: Double?
    @Published private(set) var rawWarm: UInt16?
    @Published private(set) var tempWarmC: Double?

    /// If both points are set, this returns a valid linear mapping.
    var isCalibrated: Bool { slope != nil && offset != nil }

    var slope: Double? {
        guard let rc = rawCool, let tc = tempCoolC,
              let rw = rawWarm, let tw = tempWarmC,
              rw != rc else { return nil }
        return (tw - tc) / Double(Int(rw) - Int(rc))
    }

    var offset: Double? {
        guard let slope = slope, let rc = rawCool, let tc = tempCoolC else { return nil }
        return tc - slope * Double(rc)
    }

    /// Convert a raw thermistor value to °C using the calibration. Returns nil
    /// if not yet calibrated or if the result falls outside a sane physiological
    /// range (won't write junk to Health).
    func celsius(for raw: UInt16) -> Double? {
        guard let slope = slope, let offset = offset else { return nil }
        let c = slope * Double(raw) + offset
        guard c >= 20, c <= 42 else { return nil }
        return c
    }

    // MARK: - Persistence (UserDefaults)

    private let key = "whoopless.skintempcal"

    init() { load() }

    func setCool(raw: UInt16, celsius: Double) {
        rawCool = raw; tempCoolC = celsius
        save()
    }

    func setWarm(raw: UInt16, celsius: Double) {
        rawWarm = raw; tempWarmC = celsius
        save()
    }

    func clear() {
        rawCool = nil; tempCoolC = nil
        rawWarm = nil; tempWarmC = nil
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func save() {
        let d: [String: Any?] = [
            "rawCool": rawCool.map { Int($0) },
            "tempCoolC": tempCoolC,
            "rawWarm": rawWarm.map { Int($0) },
            "tempWarmC": tempWarmC
        ]
        UserDefaults.standard.set(d.compactMapValues { $0 }, forKey: key)
    }

    private func load() {
        guard let dict = UserDefaults.standard.dictionary(forKey: key) else { return }
        if let r = dict["rawCool"] as? Int { rawCool = UInt16(r) }
        if let t = dict["tempCoolC"] as? Double { tempCoolC = t }
        if let r = dict["rawWarm"] as? Int { rawWarm = UInt16(r) }
        if let t = dict["tempWarmC"] as? Double { tempWarmC = t }
    }
}
