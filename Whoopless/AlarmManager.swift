//
//  AlarmManager.swift
//  Whoopless
//
//  Silent alarm clock using WHOOP's haptic motor.
//
//  Why we don't use UNUserNotificationCenter / BGTaskScheduler:
//      iOS doesn't guarantee exact-time execution for background tasks.
//      Since we already hold a live BLE connection overnight (for sleep
//      tracking + HR broadcast), we get a free ~1-second heartbeat from
//      every incoming HR packet. We check the alarm condition on each.
//

import Foundation
import Combine

@MainActor
final class AlarmManager: ObservableObject {

    /// When `isArmed` is true and the current time passes `alarmTime`,
    /// we fire the haptic. Re-fires every `repeatIntervalSec` until dismissed
    /// or `maxFires` is reached.
    @Published var isArmed: Bool = false
    @Published var alarmTime: Date = AlarmManager.defaultAlarmTime()
    @Published var lastFiredAt: Date?
    @Published var fireCount: Int = 0

    let repeatIntervalSec: TimeInterval = 30
    let maxFires: Int = 10     // 10 × 30 s = 5 min total buzz window

    private weak var ble: BLEManager?
    private let defaultsArmKey     = "whoopless.alarm.armed"
    private let defaultsTimeKey    = "whoopless.alarm.time"
    private let defaultsFiredKey   = "whoopless.alarm.firedAt"
    private let defaultsFiredCount = "whoopless.alarm.fireCount"

    init(ble: BLEManager) {
        self.ble = ble
        restore()
    }

    // MARK: - Public API

    func arm(at date: Date) {
        alarmTime = date
        isArmed = true
        fireCount = 0
        lastFiredAt = nil
        persist()
    }

    func disarm() {
        isArmed = false
        fireCount = 0
        lastFiredAt = nil
        ble?.stopHaptics()
        persist()
    }

    /// User hit "Dismiss" — stop any in-progress buzz AND disarm.
    func dismissAndClear() {
        disarm()
    }

    /// Fire the haptic once (for the Test button).
    func fireTestBuzz() {
        ble?.buzzStrap()
    }

    // MARK: - The tick

    /// Called on every incoming HR packet. Cheap: just a timestamp comparison.
    func tick(now: Date = Date()) {
        guard isArmed, fireCount < maxFires else {
            if fireCount >= maxFires { disarm() }
            return
        }
        // Not yet time.
        guard now >= alarmTime else { return }
        // First fire, or repeat-interval elapsed since last fire.
        if let last = lastFiredAt, now.timeIntervalSince(last) < repeatIntervalSec {
            return
        }
        ble?.buzzStrap()
        lastFiredAt = now
        fireCount += 1
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        let d = UserDefaults.standard
        d.set(isArmed, forKey: defaultsArmKey)
        d.set(alarmTime, forKey: defaultsTimeKey)
        d.set(lastFiredAt, forKey: defaultsFiredKey)
        d.set(fireCount, forKey: defaultsFiredCount)
    }

    private func restore() {
        let d = UserDefaults.standard
        isArmed = d.bool(forKey: defaultsArmKey)
        if let t = d.object(forKey: defaultsTimeKey) as? Date { alarmTime = t }
        lastFiredAt = d.object(forKey: defaultsFiredKey) as? Date
        fireCount = d.integer(forKey: defaultsFiredCount)
        // If a previously-armed alarm has passed + max-fired, clear it.
        if fireCount >= maxFires { isArmed = false }
    }

    // MARK: - Defaults

    /// Default alarm time = tomorrow at 07:00 local.
    private static func defaultAlarmTime() -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 7
        comps.minute = 0
        var candidate = cal.date(from: comps) ?? Date().addingTimeInterval(8 * 3600)
        if candidate < Date() {
            candidate = cal.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }
}
