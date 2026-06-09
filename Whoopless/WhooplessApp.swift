//
//  WhooplessApp.swift
//  Whoopless
//

import SwiftUI
import BackgroundTasks

@main
struct WhooplessApp: App {
    @StateObject private var ble: BLEManager
    @StateObject private var health: HealthKitManager
    @StateObject private var sleep: SleepTracker
    @StateObject private var alarm: AlarmManager
    @StateObject private var calibration: HRVCalibration
    @StateObject private var analyzer = HistoricalAnalyzer()
    @StateObject private var skinTempCal = SkinTempCalibration()

    @Environment(\.scenePhase) private var scenePhase

    /// Identifier for the periodic background-refresh task. Must also be
    /// listed under `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    private static let refreshTaskID = "com.whoopless.bgsync"

    init() {
        // Most sub-objects need references to their siblings; we construct the
        // roots here and hand shared instances to each.
        let b = BLEManager()
        let h = HealthKitManager()
        _ble         = StateObject(wrappedValue: b)
        _health      = StateObject(wrappedValue: h)
        _sleep       = StateObject(wrappedValue: SleepTracker(health: h))
        _alarm       = StateObject(wrappedValue: AlarmManager(ble: b))
        _calibration = StateObject(wrappedValue: HRVCalibration(health: h))

        // Register the BG refresh task handler. iOS calls this when it decides
        // to wake us — typically every 6–12 hours for an actively used app.
        // We use the slot to drain any historical packets the strap
        // accumulated while we were suspended.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskID,
            using: nil
        ) { task in
            Self.handleBackgroundRefresh(task as! BGAppRefreshTask, ble: b)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ble)
                .environmentObject(health)
                .environmentObject(sleep)
                .environmentObject(alarm)
                .environmentObject(calibration)
                .environmentObject(analyzer)
                .environmentObject(skinTempCal)
                .task {
                    await health.requestAuthorization()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        // Foreground — drain any packets that piled up while
                        // we were backgrounded. The strap buffers internally,
                        // so a long suspension is recoverable as long as we
                        // sync when iOS lets us run again.
                        if ble.connectedName != nil {
                            ble.syncHistoricalData()
                        }
                    case .background:
                        // Schedule the next BG refresh as we leave foreground.
                        Self.scheduleBackgroundRefresh()
                    default:
                        break
                    }
                }
        }
    }

    // MARK: - Background refresh

    private static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        // Earliest possible: 1 hour from now. iOS schedules the actual run
        // based on usage patterns, battery, network — typically further out.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Common failure modes: app not in BG-modes plist, or running on
            // the simulator (BGTaskScheduler is unavailable there).
            print("BGTaskScheduler submit failed: \(error)")
        }
    }

    private static func handleBackgroundRefresh(_ task: BGAppRefreshTask,
                                                ble: BLEManager) {
        // Always reschedule so future windows keep coming.
        scheduleBackgroundRefresh()

        task.expirationHandler = {
            // iOS is reclaiming us — let it complete cleanly.
            task.setTaskCompleted(success: false)
        }

        // Brief drain attempt. We have ~30 seconds of CPU before iOS suspends
        // us again. If we're already connected, just send the historical-sync
        // command. If not, there's not much we can do in this slot — BLE
        // discovery from cold is too slow for a BG task to complete reliably.
        Task { @MainActor in
            if ble.connectedName != nil {
                ble.syncHistoricalData()
            }
            // Give the strap ~10 seconds to push packets back, then complete.
            try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            task.setTaskCompleted(success: true)
        }
    }
}
