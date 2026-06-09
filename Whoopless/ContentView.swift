//
//  ContentView.swift
//  Whoopless
//

import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var health: HealthKitManager
    @EnvironmentObject var sleep: SleepTracker
    @EnvironmentObject var alarm: AlarmManager
    @EnvironmentObject var calibration: HRVCalibration
    @EnvironmentObject var analyzer: HistoricalAnalyzer
    @EnvironmentObject var skinTempCal: SkinTempCalibration

    // Rolling RR-interval buffer. Big enough to contain ~90 s at resting HR —
    // enough for respiratory-rate estimation via RSA.
    @State private var rrBuffer: [Double] = []
    private let rrWindow = 120
    // SDNN is computed over a smaller subset so it behaves like Apple Health's
    // 1-minute HRV snapshot instead of drifting as the buffer fills.
    private let hrvSubWindow = 60
    // Running tally of consecutive rejections — once we hit 5, the filter
    // resets so a genuine HR shift doesn't lock us out.
    @State private var consecutiveRejects: Int = 0

    // Write decoded fields from historical packets into Apple Health.
    @AppStorage("whoopless.writeHistoricalToHealth") private var writeHistoricalToHealth: Bool = true
    // SpO2 writes are off by default — our current ratio-of-ratios algorithm
    // is uncalibrated against WHOOP's specific sensor and produces values
    // that don't match clinical pulse oximeters or Apple Watch.
    @AppStorage("whoopless.writeSpO2ToHealth") private var writeSpO2ToHealth: Bool = false

    /// Calorie estimation toggle. When on, Whoopless writes
    /// `activeEnergyBurned` samples derived from live HR via the Keytel
    /// formula. Drives Apple Fitness's Move ring without WHOOP's subscription.
    /// The same path also tracks exercise minutes for the Exercise ring —
    /// every minute where HR exceeded the exercise threshold for at least
    /// 30 seconds gets written as 1 minute of `appleExerciseTime`.
    @AppStorage("whoopless.estimateCalories") private var estimateCalories: Bool = false
    @State private var caloriesBuffer: Double = 0
    @State private var caloriesWindowStart: Date = Date()
    @State private var elevatedHRSecondsInWindow: Int = 0
    @State private var profileAgeYears: Int = 30
    @State private var profileWeightKg: Double = 75
    @State private var profileSex: CalorieEstimator.BiologicalSex = .male
    @State private var profileRestingHR: Int = 60
    @State private var lastShownKcalPerMin: Double = 0
    /// HR threshold above which a second counts toward exercise time. 100 bpm
    /// is the practical floor for "doing something deliberate" across most
    /// physiologies; Apple's algorithm uses a similar effective threshold.
    private let exerciseHRThreshold: Int = 100

    @State private var showSnapshotLab: Bool = false

    // Cleanup tool state — date range pickers default to "today" and drive
    // both the HR-delete and HRV-delete buttons.
    @State private var cleanupFrom: Date = Calendar.current.startOfDay(for: Date())
    @State private var cleanupTo: Date = Date()
    @State private var cleanupStatus: String = ""
    // Developer / lab UI toggle. When off, we show only the daily-driver cards.
    @AppStorage("whoopless.devMode") private var devMode: Bool = false
    // Sub-toggles for the heaviest dev-mode views. Both default OFF because
    // they re-render on every BLE notification (multiple times per second
    // during historical sync), which makes the entire main view laggy. The
    // user enables only the one they're actively using.
    @AppStorage("whoopless.devMode.showPacketInspector") private var showPacketInspector: Bool = false
    @AppStorage("whoopless.devMode.showBLELog") private var showBLELog: Bool = false
    @State private var lastHistoricalWrittenSeq: UInt8 = 0
    @State private var lastHistoricalWrittenTs: UInt32 = 0

    // Rolling buffer of beat-to-beat RR intervals accumulated across historical
    // packets. Lets us compute HRV (SDNN) over proper ~1-minute windows even
    // when each packet only carries a handful of RRs.
    @State private var histRRBuffer: [(Date, Double)] = []
    @State private var lastHistHRVWrite: Date = .distantPast

    // Motion-gating buffers. SDNN during activity is physiologically higher
    // (HR swings with demand) and not comparable to Apple Watch resting HRV,
    // which is specifically measured during stillness. We gate SDNN writes to
    // Health on a combination of low acceleration + stable HR + skin contact.
    @State private var recentAccelMags: [Double] = []   // last ~10 samples
    @State private var recentHRsForStability: [Int] = [] // last ~30 samples

    // Continuous rMSSD for on-screen display. rMSSD captures beat-to-beat
    // variability (parasympathetic tone) and DROPS during activity — the
    // opposite of SDNN — making it a more useful live metric. Not written to
    // Health (no HKQuantityType for it).
    @State private var currentRMSSD: Double?
    @State private var currentSDNN: Double?
    @State private var hrvGatePassed: Bool = false

    // Proper SpO2 calculator (ported from OpenWhoop) — ratio-of-ratios over
    // a rolling window of red + IR raw samples from historical packets.
    @State private var spo2Calc = SpO2Calculator()

    // Skin temp calibration UI state.
    @State private var coolTempInput: Double = 22.0
    @State private var warmTempInput: Double = 32.0

    // Respiratory rate is expensive to compute and Health doesn't want a
    // sample every second — throttle to once per 30 s.
    @State private var lastRespSave = Date.distantPast
    @State private var lastRespBpm: Double?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    statusCard
                    heartCard
                    sleepCard
                    alarmCard
                    skinTempCard
                    if devMode {
                        calibrationCard
                        calorieCard
                        sleepFeaturesCard
                        // Heavy views off by default — toggle row lets the
                        // user enable them one at a time when needed. Without
                        // this gate, the 96-byte packet grid + per-byte stats
                        // re-render on every BLE notification (many per sec
                        // during historical sync), making the whole view laggy.
                        devModePerfToggles
                        if showPacketInspector { historicalCard }
                    }
                    deviceList
                    controls
                    if let err = health.lastError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                    developerToggle
                    if devMode && showBLELog { bleLog }
                }
                .padding()
            }
            .navigationTitle("Whoopless")
            .onAppear(perform: wireUp)
            .task { await loadUserProfile() }
            // Auto-enable raw data streaming during sleep tracking so the
            // accelerometer + IMU samples flow live rather than depending on
            // historical 0x2F packets (which are sparse overnight). Without
            // this the per-epoch motion features in the classifier dataset
            // are completely empty. Battery cost of raw streaming is real
            // but acceptable on a phone+strap left charging overnight.
            .onChange(of: sleep.isTracking) { _, nowTracking in
                guard ble.connectedName != nil else { return }
                if nowTracking {
                    ble.startRawData()
                } else {
                    ble.stopRawData()
                }
            }
            .sheet(item: $sleep.pendingReview) { review in
                SleepReviewView(
                    review: review,
                    onConfirm: {
                        Task { await sleep.confirmAndWrite(review) }
                    },
                    onDiscard: { sleep.discardReview() },
                    featuresCSV: sleep.savedEpochFeaturesCSV
                )
                .interactiveDismissDisabled()  // force explicit Confirm/Discard
            }
            .sheet(isPresented: $showSnapshotLab) {
                HealthSnapshotView()
                    .environmentObject(ble)
            }
        }
    }

    // MARK: - Wiring

    /// Pull the user's age, sex, weight, and resting HR from HealthKit on
    /// launch so the Keytel formula produces personalized calorie values
    /// without us having to ask the user to type any of these in again.
    /// Falls back to reasonable defaults if any field isn't available.
    private func loadUserProfile() async {
        if let age = health.fetchUserAge() { profileAgeYears = age }
        profileSex = health.fetchUserBiologicalSex()
        if let w = await health.fetchUserWeightKg() { profileWeightKg = w }
        if let rhr = await health.fetchRestingHR() { profileRestingHR = Int(rhr) }
    }

    private func wireUp() {
        // Route decoded historical samples into HealthKit when opted in.
        ble.onHistoricalSample = { s in
            guard writeHistoricalToHealth else { return }
            // Dedup: skip if we already wrote this seq/ts.
            if s.seq == lastHistoricalWrittenSeq && s.unixTs == lastHistoricalWrittenTs { return }
            lastHistoricalWrittenSeq = s.seq
            lastHistoricalWrittenTs = s.unixTs

            // Use the phone's current time by default. The strap's internal
            // clock drifts (hours, sometimes days) unless we actively sync it,
            // so blindly trusting `unix_ts` scatters samples onto wrong dates.
            // Only use the packet timestamp if it's within 10 MINUTES of now —
            // that window is tight enough that we know the clock is fresh.
            let now = Date()
            let packetDate = Date(timeIntervalSince1970: TimeInterval(s.unixTs))
            let clockFresh = abs(packetDate.timeIntervalSince(now)) < 600
            let stamp = clockFresh ? packetDate : now

            // HR — historical packets carry the strap's BUFFERED HR algorithm
            // output, which loses lock during motion and reports the cached
            // resting value (40s during a workout, despite real HR of 90+).
            // The live BLE broadcast (0x2A37) handles motion much better.
            //
            // Strategy: only write historical HR when the live stream is
            // STALE (>30s without a fresh notification). That keeps us
            // covered overnight when BLE drops, but during active workouts
            // and normal use the cleaner live stream is the only HR source
            // hitting Apple Health.
            if s.hrBpm > 30, s.hrBpm < 220 {
                let liveStaleSec = Date().timeIntervalSince(ble.lastUpdate ?? .distantPast)
                if liveStaleSec > 30 {
                    health.saveHistoricalHeartRate(Double(s.hrBpm), at: stamp)
                }
            }
            // SpO2 — accumulate red+IR samples, compute proper ratio-of-ratios
            // once we have 30+ paired readings (OpenWhoop's algorithm).
            if let s2 = spo2Calc.ingest(red: s.spo2RedRaw, ir: s.spo2IRRaw),
               spo2Calc.shouldEmit() {
                // Hard floor at 92% — anything lower is almost certainly an
                // uncalibrated-sensor artifact rather than real desaturation.
                // SpO2 writes are also gated behind an opt-in toggle since
                // our algorithm isn't reliably calibrated yet.
                if writeSpO2ToHealth, s2 >= 92 {
                    health.saveSpO2(fraction: s2 / 100.0, at: stamp)
                }
                spo2Calc.markEmitted()
            }
            // Skin temp — only write if the user has set up two-point cal.
            if let celsius = skinTempCal.celsius(for: s.skinTempRaw) {
                health.saveBodyTemperature(celsius, at: stamp)
            }
            // Track accelerometer + HR for motion gating. SDNN writes to Health
            // are gated on stillness so values are comparable to Apple Watch
            // (which only measures HRV during low-motion windows).
            recentAccelMags.append(Double(s.accMag))
            if recentAccelMags.count > 10 {
                recentAccelMags.removeFirst(recentAccelMags.count - 10)
            }
            if s.hrBpm > 30 {
                recentHRsForStability.append(Int(s.hrBpm))
                if recentHRsForStability.count > 30 {
                    recentHRsForStability.removeFirst(recentHRsForStability.count - 30)
                }
            }

            // HRV: accumulate RRs with the Malik rule — each RR must be within
            // ±25% of the rolling median. WHOOP's RR field occasionally
            // contains multi-beat averages or hard artifacts (we saw 500 ms
            // and 1357 ms in the same packet). Malik catches those without
            // suppressing legitimate beat-to-beat variability.
            //
            // We previously layered a "successive difference" filter on top
            // (reject pairs where |Δr| > max(50, 2.5×MAD)). That was based on
            // a wrong hypothesis: the rMSSD/SDNN ratio approaching √2 in our
            // data was interpreted as white-noise contamination, but for this
            // user it actually reflects high vagal tone with rMSSD ~94 ms.
            // The filter rejected most legitimate beats, collapsing SDNN to
            // ~29 ms regardless of actual HRV. Removed.
            let recent = histRRBuffer.suffix(20).map { $0.1 }.sorted()
            let median: Double = recent.isEmpty ? 0 : recent[recent.count / 2]
            for rr in s.rrIntervalsMs {
                let msRR = Double(rr)
                guard msRR >= 400, msRR <= 1500 else { continue }       // physiological
                if median > 0 {
                    let ratio = msRR / median
                    if ratio < 0.75 || ratio > 1.25 { continue }       // Malik
                }
                histRRBuffer.append((stamp, msRR))
                sleep.ingestRR(msRR)
            }
            // Feed accelerometer magnitude for per-epoch motion variance.
            sleep.ingestAccelMag(Double(s.accMag))
            // Keep at most last 5 minutes of beats (~300 at 60 bpm).
            let cutoff = stamp.addingTimeInterval(-300)
            histRRBuffer.removeAll { $0.0 < cutoff }

            // Compute HRV every 60s. rMSSD is always computed for display
            // (motion-resistant, Helio-style continuous metric). SDNN is only
            // written to Health when motion + HR + skin-contact gates pass,
            // which matches Apple Watch's passive-HRV behavior.
            if histRRBuffer.count >= 20,
               stamp.timeIntervalSince(lastHistHRVWrite) >= 60 {
                let rrs = Array(histRRBuffer.suffix(60).map { $0.1 })

                // rMSSD: sqrt of mean squared successive differences. This is
                // what WHOOP and most HRV research actually use. Parasympathetic
                // tone — drops during stress/activity, rises during recovery.
                let diffs = zip(rrs, rrs.dropFirst()).map { $1 - $0 }
                let sqSum = diffs.reduce(0.0) { $0 + $1 * $1 }
                let rMSSD = diffs.isEmpty ? 0 : (sqSum / Double(diffs.count)).squareRoot()
                if rMSSD > 0 { currentRMSSD = rMSSD }

                // SDNN: standard deviation of all RRs. What HealthKit expects
                // as `heartRateVariabilitySDNN`.
                let mean = rrs.reduce(0, +) / Double(rrs.count)
                let varsum = rrs.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
                let sdnn = (varsum / Double(rrs.count - 1)).squareRoot()
                if sdnn > 0 { currentSDNN = sdnn }

                // Motion + HR stability + skin-contact gate.
                let stillAccel = recentAccelMags.count >= 5 &&
                    recentAccelMags.allSatisfy { abs($0 - 1.0) < 0.05 }
                let recentWin = recentHRsForStability.suffix(10)
                let hrStable = recentWin.count < 5 ||
                    ((recentWin.max() ?? 0) - (recentWin.min() ?? 0) < 5)
                let onWrist = s.skinContact > 0
                hrvGatePassed = stillAccel && hrStable && onWrist

                // Always write a sample. `kind` metadata distinguishes:
                //   - "resting"    → motion + HR gate passed, comparable to
                //                    Apple Watch passive HRV (MANTIS should
                //                    use these for recovery).
                //   - "continuous" → all-day trend, written regardless of
                //                    motion so rMSSD has full coverage.
                // rMSSD is attached as metadata (HealthKit has no rMSSD type).
                if sdnn > 0 {
                    health.saveHRV(
                        sdnn,
                        rMSSDms: rMSSD,
                        kind: hrvGatePassed ? "resting" : "continuous",
                        at: stamp
                    )
                }
                lastHistHRVWrite = stamp
            }
        }

        ble.onHeartRate = { bpm, rrs in
            // 1 Hz heartbeat — free alarm tick.
            alarm.tick()
            if bpm > 0 {
                health.saveHeartRate(Double(bpm))
                sleep.ingestHR(bpm)

                // Active calorie estimation. Keytel formula gives kcal/min
                // at the current HR; subtract resting kcal/min to get
                // above-baseline "active" calories. Each HR notification
                // covers ~1 second, so contribute (kcal/min)/60. Flush a
                // single accumulated sample to Health every minute to keep
                // Apple Fitness's Move ring updated without spamming Health.
                if estimateCalories {
                    let kcalPerMin = CalorieEstimator.activeKcalPerMin(
                        hr: bpm,
                        restingHR: profileRestingHR,
                        weightKg: profileWeightKg,
                        ageYears: profileAgeYears,
                        sex: profileSex
                    )
                    lastShownKcalPerMin = kcalPerMin
                    caloriesBuffer += kcalPerMin / 60.0
                    // Tally seconds where HR crossed the exercise threshold
                    // — at minute-flush time, if at least 30s qualified, we
                    // credit 1 minute toward the Apple Health Exercise ring.
                    if bpm >= exerciseHRThreshold {
                        elevatedHRSecondsInWindow += 1
                    }
                    let now = Date()
                    if now.timeIntervalSince(caloriesWindowStart) >= 60 {
                        if caloriesBuffer > 0 {
                            health.saveActiveEnergy(
                                kcal: caloriesBuffer,
                                start: caloriesWindowStart,
                                end: now
                            )
                        }
                        if elevatedHRSecondsInWindow >= 30 {
                            health.saveExerciseTime(
                                minutes: 1.0,
                                start: caloriesWindowStart,
                                end: now
                            )
                        }
                        caloriesBuffer = 0
                        elevatedHRSecondsInWindow = 0
                        caloriesWindowStart = now
                    }
                }
            }

            // MAD-based outlier rejection. For each incoming RR:
            //   1. Must be in physiological range (300–2000 ms ≈ HR 30–200 bpm).
            //   2. Must be within 2.5 × MAD of the median of the last 20 accepted
            //      RRs. MAD is robust — one bad sample can't poison it the way
            //      standard deviation can.
            //   3. Must be within 150 ms of the PREVIOUS accepted RR (belt-and-
            //      braces against sudden motion-artifact jumps).
            // After 8 rejects the filter resets (genuine HR shift, e.g. standing up).
            var accepted: [Double] = []
            let recent = Array(rrBuffer.suffix(20)).sorted()
            let median: Double = recent.isEmpty ? 0 : recent[recent.count / 2]
            let mad: Double = {
                guard !recent.isEmpty, median > 0 else { return 0 }
                let deviations = recent.map { abs($0 - median) }.sorted()
                return deviations[deviations.count / 2]
            }()
            let madThreshold = max(60, mad * 2.5)     // floor: 60 ms, allow natural HRV
            let lastAccepted: Double = rrBuffer.last ?? 0

            for rr in rrs {
                guard rr >= 300, rr <= 2000 else { continue }
                if consecutiveRejects < 8 {
                    if median > 0, abs(rr - median) > madThreshold {
                        consecutiveRejects += 1
                        continue
                    }
                    if lastAccepted > 0, abs(rr - lastAccepted) > 150 {
                        consecutiveRejects += 1
                        continue
                    }
                }
                accepted.append(rr)
                consecutiveRejects = 0
            }
            guard !accepted.isEmpty else { return }

            // Persist each accepted RR to disk for post-hoc HRV analysis.
            for rr in accepted { RRLogger.shared.append(rr) }

            rrBuffer.append(contentsOf: accepted)
            if rrBuffer.count > rrWindow {
                rrBuffer.removeFirst(rrBuffer.count - rrWindow)
            }

            // Feed accepted live RRs into SleepTracker too. Historical RRs
            // (fed via onHistoricalSample) are sparse during sleep because
            // the strap goes idle, leaving the per-epoch HRV features in the
            // classifier dataset essentially constant. Live RRs come at 1 Hz
            // whenever BLE is alive, which is most of overnight, so feeding
            // them keeps the rolling 5-min HRV window updating across the
            // night. Live RRs are noisier than historical for SDNN-grade
            // measurement — but for classifier training we need VARIATION
            // across epochs more than absolute accuracy.
            for rr in accepted { sleep.ingestRR(rr) }

            // HRV write is DISABLED on purpose.
            //
            // WHOOP's BLE heart-rate broadcast sends RR intervals that are not
            // suitable for SDNN-grade HRV — the values are processed/averaged in
            // a way we can't reverse from the outside, and every filter we tried
            // (range, Malik, median-based, MAD) still produced implausibly high
            // SDNN (300+ ms at resting HR). Respiratory rate extraction works
            // because it only cares about the oscillation PATTERN, not absolute
            // RR magnitudes.
            //
            // If WHOOP's proprietary sensor stream ever becomes accessible
            // (via RE of their auth handshake), we can revisit.

            // Respiratory rate: throttle to 30 s cadence.
            if let resp = HRVMath.respiratoryRateBpm(rrBuffer) {
                lastRespBpm = resp
                if Date().timeIntervalSince(lastRespSave) >= 30 {
                    health.saveRespiratoryRate(resp)
                    lastRespSave = Date()
                }
            }
        }
    }

    // MARK: - Sub-views

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(ble.heartRate > 0 ? .green : .gray)
                    .frame(width: 10, height: 10)
                Text(ble.state).font(.subheadline)
                Spacer()
                if let batt = ble.batteryLevel {
                    Label("\(batt)%", systemImage: "battery.100")
                        .font(.caption)
                }
            }
            if let name = ble.connectedName {
                Text(name).font(.footnote).foregroundStyle(.secondary)
            }
            // Watchdog visibility — how long since ANY packet arrived. Green
            // if fresh (<30s), orange if concerning (30-60s), red if
            // the watchdog is about to force-reconnect (>60s).
            if ble.connectedName != nil, let last = ble.lastPacketAt {
                let age = Date().timeIntervalSince(last)
                let color: Color = age < 30 ? .green : (age < 60 ? .orange : .red)
                Text("Last packet \(Int(age))s ago")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(color)
            }
            Text(health.isAuthorized ? "HealthKit: authorized" : "HealthKit: awaiting permission")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var heartCard: some View {
        VStack(spacing: 6) {
            Image(systemName: "heart.fill")
                .font(.system(size: 44))
                .foregroundStyle(.pink)
                .symbolEffect(.pulse, options: .repeating, value: ble.heartRate)
            Text("\(ble.heartRate)")
                .font(.system(size: 84, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text("bpm").foregroundStyle(.secondary)

            // Continuous HRV from historical 0x2F packets. rMSSD is shown as
            // the primary live metric (motion-resistant, tracks recovery/stress
            // in real time). SDNN is displayed when the motion gate passes —
            // those are the only values written to Apple Health.
            if let r = currentRMSSD {
                HStack(spacing: 12) {
                    Text("rMSSD \(Int(r)) ms")
                        .font(.caption)
                        .foregroundStyle(.teal)
                    if let sd = currentSDNN {
                        Text("SDNN \(Int(sd)) ms")
                            .font(.caption)
                            .foregroundStyle(hrvGatePassed ? Color.green : Color.secondary)
                        Image(systemName: hrvGatePassed ? "checkmark.circle.fill" : "figure.walk")
                            .font(.caption2)
                            .foregroundStyle(hrvGatePassed ? Color.green : Color.orange)
                    }
                }
            }
            if let resp = lastRespBpm {
                Text("Respiratory rate: \(String(format: "%.1f", resp)) breaths/min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let last = ble.lastUpdate {
                Text("Updated \(last.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var deviceList: some View {
        if !ble.discoveredDevices.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nearby heart-rate devices").font(.headline)
                ForEach(ble.discoveredDevices, id: \.identifier) { p in
                    Button { ble.connect(p) } label: {
                        HStack {
                            Image(systemName: "heart.text.square")
                            Text(p.name ?? "Unknown device")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var hrFinderCard: some View {
        // Only relevant while connected and raw streaming is on.
        if ble.connectedName != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "scope").foregroundStyle(.cyan)
                    Text("HR byte finder").font(.headline)
                    Spacer()
                    if !ble.hrMatchFirstSnapshot {
                        Text("\(ble.hrMatchSnapshotCount) snaps · \(ble.hrMatchCommonBytes.count) common")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Tap Snapshot while your HR is stable at different values (sitting vs. after 20 jumping jacks vs. sitting). After a few taps, the common byte(s) = real HR.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button { ble.snapshotHRMatch() } label: {
                        Label("Snapshot (live HR \(ble.heartRate))", systemImage: "camera")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .disabled(ble.heartRate < 30)

                    Button(role: .destructive) { ble.resetHRMatch() } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .font(.caption)

                if !ble.hrMatchCommonBytes.isEmpty {
                    Text("Candidate HR byte positions: \(ble.hrMatchCommonBytes.sorted().map(String.init).joined(separator: ", "))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.green)
                }
                if !ble.hrMatchHistory.isEmpty {
                    DisclosureGroup("History") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(ble.hrMatchHistory.suffix(20).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var skinTempCard: some View {
        // Two-point calibration + live raw → °C readout.
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "thermometer.medium")
                    .foregroundStyle(.orange)
                Text("Skin temperature").font(.headline)
                Spacer()
                if let raw = ble.latestHistorical?.skinTempRaw {
                    if let c = skinTempCal.celsius(for: raw) {
                        Text(String(format: "%.1f °C", c))
                            .font(.caption.monospaced())
                            .foregroundStyle(.orange)
                    } else {
                        Text("raw \(raw)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Text(skinTempCal.isCalibrated
                 ? "Calibrated. Writing °C to Health."
                 : "Calibrate to enable body-temperature writes.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    if let raw = ble.latestHistorical?.skinTempRaw {
                        skinTempCal.setCool(raw: raw, celsius: coolTempInput)
                    }
                } label: {
                    Label(skinTempCal.rawCool == nil ? "Capture cool" : "Cool ✓",
                          systemImage: "snowflake")
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                Spacer()
                Text(String(format: "%.1f °C", coolTempInput))
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 60, alignment: .trailing)
                Stepper("", value: $coolTempInput, in: 15...30, step: 0.5)
                    .labelsHidden()
            }

            HStack(spacing: 8) {
                Button {
                    if let raw = ble.latestHistorical?.skinTempRaw {
                        skinTempCal.setWarm(raw: raw, celsius: warmTempInput)
                    }
                } label: {
                    Label(skinTempCal.rawWarm == nil ? "Capture warm" : "Warm ✓",
                          systemImage: "flame")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                Spacer()
                Text(String(format: "%.1f °C", warmTempInput))
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 60, alignment: .trailing)
                Stepper("", value: $warmTempInput, in: 28...40, step: 0.1)
                    .labelsHidden()
            }

            if skinTempCal.isCalibrated {
                Button(role: .destructive) { skinTempCal.clear() } label: {
                    Label("Reset calibration", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .font(.caption2)
            }

            Text("How to calibrate: (1) take WHOOP off, let it cool to room temp for 5 min, dial the °C field to your room temp, tap Capture cool. (2) Put WHOOP back on wrist, wait 10 min for skin temp to equilibrate (~32°C), tap Capture warm. Writes body-temp samples to Health after.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var sleepCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: sleep.isTracking
                      ? (sleep.likelyAsleepNow ? "moon.zzz.fill" : "bed.double.fill")
                      : "bed.double")
                    .font(.title2)
                    .foregroundStyle(sleep.isTracking ? .indigo : .secondary)
                Text(sleep.isTracking ? "Sleep tracking" : "Sleep")
                    .font(.headline)
                Spacer()
                if sleep.isTracking {
                    Text(sleep.likelyAsleepNow ? "Likely asleep" : "Awake")
                        .font(.caption)
                        .foregroundStyle(sleep.likelyAsleepNow ? .indigo : .secondary)
                }
            }

            Toggle(isOn: $sleep.autoDetectEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-detect").font(.subheadline)
                    Text("Baseline: \(Int(sleep.baselineBPM)) bpm · threshold \(Int(sleep.baselineBPM * 0.85)) bpm")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.indigo)
            if sleep.autoDetectEnabled {
                Text(sleep.autoStatus)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if sleep.isTracking, let start = sleep.sessionStart {
                VStack(spacing: 2) {
                    Text(formatElapsed(sleep.elapsedSeconds))
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("Started \(start.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 12) {
                if sleep.isTracking {
                    Button(role: .destructive) { sleep.stop() } label: {
                        Label("Stop & review", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    Button("Cancel") { sleep.cancel() }
                        .buttonStyle(.bordered)
                } else {
                    Button {
                        sleep.start()
                    } label: {
                        Label("Start sleep tracking", systemImage: "moon.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                }
            }

            // Manual review — build a SleepReview from data already in Apple
            // Health. Defaults to last night 22:00–07:00. Useful when the user
            // forgot to start tracking, when reviewing a previous night, or
            // to test the review flow on demand.
            if !sleep.isTracking {
                Button {
                    Task { await sleep.buildManualReview() }
                } label: {
                    Label("Review last night from Health", systemImage: "calendar.badge.clock")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.indigo)
            }

            // Most-recent write — shows the user what got written to Health
            // after they confirmed the review. Persists until next session.
            if let summary = sleep.lastWriteSummary, !sleep.isTracking {
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var alarmCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: alarm.isArmed ? "alarm.fill" : "alarm")
                    .font(.title2)
                    .foregroundStyle(alarm.isArmed ? .orange : .secondary)
                Text("Silent alarm").font(.headline)
                Spacer()
                if alarm.isArmed {
                    Text(alarm.alarmTime.formatted(date: .omitted, time: .shortened))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                }
            }

            if !alarm.isArmed {
                DatePicker(
                    "Wake me at",
                    selection: $alarm.alarmTime,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
            } else {
                if let last = alarm.lastFiredAt {
                    Text("Buzzed \(alarm.fireCount)× (last at \(last.formatted(date: .omitted, time: .standard)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                if alarm.isArmed {
                    Button(role: .destructive) {
                        alarm.dismissAndClear()
                    } label: {
                        Label("Dismiss alarm", systemImage: "alarm.slash.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button {
                        alarm.arm(at: alarm.alarmTime)
                    } label: {
                        Label("Arm alarm", systemImage: "alarm")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }

                Button {
                    alarm.fireTestBuzz()
                } label: {
                    Label("Test buzz", systemImage: "waveform")
                }
                .buttonStyle(.bordered)
                .disabled(ble.connectedName == nil)
            }

            if ble.connectedName == nil {
                Text("Connect to WHOOP to use the alarm.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var historicalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "tray.full")
                    .font(.title3)
                    .foregroundStyle(.purple)
                Text("Historical data lab").font(.headline)
                Spacer()
                Text("\(HistoricalLogger.shared.count) packets")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text("Analyze byte positions in the saved HISTORICAL_DATA packets to find HR, RR, temperature, and other fields.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle(isOn: $writeHistoricalToHealth) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Write historical → Apple Health").font(.subheadline)
                    Text("HR + SpO2 (approx) + HRV from decoded 0x2F packets with packet-real timestamps.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.purple)

            if let s = ble.latestHistorical {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Latest packet (seq \(s.seq), ts \(s.unixTs))")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        Label("HR \(s.hrBpm)", systemImage: "heart.fill")
                            .foregroundStyle(.pink)
                        if let spo2 = spo2Calc.lastSpO2 {
                            Label("SpO2 \(Int(spo2))%", systemImage: "lungs")
                                .foregroundStyle(.teal)
                        }
                        Label("|acc| \(String(format: "%.3f", s.accMag))g",
                              systemImage: "figure.walk")
                    }
                    .font(.caption)
                    HStack(spacing: 14) {
                        Label("RR×\(s.rrIntervalsMs.count)", systemImage: "waveform.path.ecg")
                            .foregroundStyle(s.rrIntervalsMs.isEmpty ? Color.secondary : Color.green)
                        Label("skin \(s.skinContact)", systemImage: "circle.hexagonpath")
                        Label("temp_raw \(s.skinTempRaw)", systemImage: "thermometer.medium")
                        Label("SQI \(s.signalQuality)", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)

                DisclosureGroup("All 96 bytes (tap to find HR position)") {
                    packetGrid(s.raw)
                        .padding(.top, 4)
                }
                .font(.caption)
            }

            // RAW stream is live but contains pure sensor samples — HR/HRV/SpO2
            // must be computed via signal processing on the PPG channels.
            HStack(spacing: 10) {
                Label("RAW pkts: \(RealtimeRawLogger.shared.count)", systemImage: "waveform")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                ShareLink(
                    item: URL(fileURLWithPath: RealtimeRawLogger.shared.path),
                    preview: SharePreview("realtime_raw_log.csv")
                ) {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
                Button(role: .destructive) {
                    RealtimeRawLogger.shared.clear()
                    ble.currentCaptureTag = nil
                } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.caption)
                }
            }
            .padding(.vertical, 4)

            // Structured-capture phase tags. Tap the active phase's button at the
            // start of that phase; the log gets a marker row so offline analysis
            // knows which bytes correspond to motion vs. rest.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Capture phase").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let tag = ble.currentCaptureTag, let at = ble.captureTagAt {
                        Text("\(tag) · \(at.formatted(date: .omitted, time: .standard))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(tagColor(tag))
                    } else {
                        Text("none").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 8) {
                    Button { ble.tagCapture("still") } label: {
                        Label("Still", systemImage: "figure.seated.side").font(.caption)
                    }
                    .tint(.blue)
                    Button { ble.tagCapture("active") } label: {
                        Label("Active", systemImage: "figure.run").font(.caption)
                    }
                    .tint(.red)
                    Button { ble.tagCapture("recovery") } label: {
                        Label("Recovery", systemImage: "figure.mind.and.body").font(.caption)
                    }
                    .tint(.green)
                }
                .buttonStyle(.bordered)

                Text("Capture protocol: still 3m → active 2m → recovery 5m, then Export RAW.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)

            HStack(spacing: 8) {
                Button {
                    Task { await analyzer.run() }
                } label: {
                    Label(analyzer.isRunning ? "Analyzing…" : "Analyze bytes",
                          systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(analyzer.isRunning)

                ShareLink(
                    item: URL(fileURLWithPath: HistoricalLogger.shared.path),
                    preview: SharePreview("Whoopless historical_log.csv")
                ) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }

            if analyzer.packetsAnalyzed > 0 {
                Text("Analyzed \(analyzer.packetsAnalyzed) packets").font(.caption)

                DisclosureGroup("Per-byte stats") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("pos  min-max  distinct  hints")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        ForEach(analyzer.stats.prefix(96)) { s in
                            Text(formatStat(s))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(statColor(s))
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption)

                if !analyzer.pairStats.isEmpty {
                    DisclosureGroup("16-bit pair candidates (RR / counters)") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("offset  min-max (LE u16)  distinct")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            ForEach(analyzer.pairStats.prefix(40), id: \.position) { p in
                                Text("\(String(format: "%3d", p.position))   \(String(format: "%5d-%5d", p.min, p.max))   \(p.distinct)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(looksLikeRR(min: p.min, max: p.max) ? Color.green : Color.secondary)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func formatStat(_ s: ByteStat) -> String {
        let samples = s.sampleValues.map { String(format: "%02X", $0) }.joined(separator: " ")
        return "\(String(format: "%3d", s.id))  \(String(format: "%02X-%02X", s.min, s.max))  \(String(format: "%3d", s.distinct))  \(s.hints.isEmpty ? samples : s.hints)"
    }

    private func tagColor(_ tag: String) -> Color {
        switch tag.lowercased() {
        case "still":    return .blue
        case "active":   return .red
        case "recovery": return .green
        default:         return .secondary
        }
    }

    private func statColor(_ s: ByteStat) -> Color {
        if s.isConstant { return .secondary.opacity(0.5) }
        if s.hints.contains("hr?") { return .green }
        return .secondary
    }

    /// RR in 1/1024 s units for HR 40–120 bpm = roughly 512–1536.
    private func looksLikeRR(min: UInt16, max: UInt16) -> Bool {
        return min >= 400 && max <= 1800 && (max - min) > 30
    }

    /// 96-byte grid, 8 bytes per row. Highlights bytes matching the live HR
    /// value from the standard HR service so we can visually spot HR position.
    @ViewBuilder
    private func packetGrid(_ bytes: [UInt8]) -> some View {
        let liveHR = UInt8(min(255, max(0, ble.heartRate)))
        VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<12, id: \.self) { row in
                HStack(spacing: 4) {
                    Text(String(format: "%02d:", row * 8))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, alignment: .trailing)
                    ForEach(0..<8, id: \.self) { col in
                        let idx = row * 8 + col
                        if idx < bytes.count {
                            let b = bytes[idx]
                            Text(String(format: "%02X", b))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(b == liveHR && ble.heartRate > 30 ? Color.green : Color.secondary)
                                .frame(width: 22)
                        }
                    }
                }
            }
            if ble.heartRate > 30 {
                Text("Bytes matching live HR (\(ble.heartRate)) highlighted green")
                    .font(.caption2).foregroundStyle(.green)
            }
        }
    }

    private var calibrationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.title3)
                    .foregroundStyle(.teal)
                Text("HRV calibration vs Apple Watch").font(.headline)
                Spacer()
            }
            Text("Pairs Apple Watch HRV samples with WHOOP RR windows over the same time to check whether WHOOP's data can be corrected.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    Task { await calibration.runComparison(lookbackHours: 24) }
                } label: {
                    Label(calibration.isRunning ? "Analyzing…" : "Analyze last 24h",
                          systemImage: "chart.xyaxis.line")
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .disabled(calibration.isRunning)

                Spacer()
                Text("RR log: \(RRLogger.shared.count)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            Button {
                Task {
                    let n = await health.deleteOwnHRVSamples()
                    calibration.statusMessage = "Deleted \(n) HRV sample(s) from Health."
                }
            } label: {
                Label("Delete old Whoopless HRV samples from Health",
                      systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .font(.caption)

            // Ranged data cleanup — for cases where bad HR or HRV data got
            // written during a regression (e.g. the historical-HR motion
            // artifact, the broken successive-difference HRV filter).
            // Single date range drives both delete buttons. Defaults to
            // "today" so the most recent regression is one tap away.
            VStack(alignment: .leading, spacing: 6) {
                Text("Cleanup Whoopless writes in range")
                    .font(.caption.bold())
                    .padding(.top, 6)
                DatePicker("From", selection: $cleanupFrom,
                           displayedComponents: [.date, .hourAndMinute])
                    .font(.caption2)
                DatePicker("To", selection: $cleanupTo,
                           in: cleanupFrom...,
                           displayedComponents: [.date, .hourAndMinute])
                    .font(.caption2)
                HStack(spacing: 8) {
                    Button(role: .destructive) {
                        Task {
                            let n = await health.deleteOwnHeartRateSamples(
                                from: cleanupFrom, to: cleanupTo)
                            cleanupStatus = "Deleted \(n) HR sample(s)."
                        }
                    } label: {
                        Label("Delete HR", systemImage: "heart.slash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    Button(role: .destructive) {
                        Task {
                            let n = await health.deleteOwnHRVSamples(
                                from: cleanupFrom, to: cleanupTo)
                            cleanupStatus = "Deleted \(n) HRV sample(s)."
                        }
                    } label: {
                        Label("Delete HRV", systemImage: "waveform.path")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                if !cleanupStatus.isEmpty {
                    Text(cleanupStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if !calibration.statusMessage.isEmpty {
                Text(calibration.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let s = calibration.stats {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Paired: \(s.n) windows")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Correlation (Pearson r): \(String(format: "%.2f", s.correlation))")
                        .font(.caption.monospaced())
                        .foregroundStyle(abs(s.correlation) > 0.5 ? .green : (abs(s.correlation) > 0.3 ? .orange : .red))
                    Text("Watch  mean: \(Int(s.watchMean)) ms ±\(Int(s.watchSD))")
                        .font(.caption.monospaced())
                    Text("WHOOP  mean: \(Int(s.whoopMean)) ms ±\(Int(s.whoopSD))")
                        .font(.caption.monospaced())
                    if abs(s.correlation) > 0.3 {
                        Text("Fit: Watch ≈ \(String(format: "%.3f", s.slope)) × WHOOP + \(Int(s.intercept))")
                            .font(.caption.monospaced())
                        Button {
                            calibration.saveCurrentFit()
                        } label: {
                            Label("Apply this calibration to future writes",
                                  systemImage: "arrow.down.to.line.compact")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)
                        .font(.caption)
                    }
                }
                .padding(.top, 4)
            }

            // Saved calibration state — current applied transform + clear.
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: calibration.calibrationEnabled
                          ? "checkmark.seal.fill" : "seal")
                        .foregroundStyle(calibration.calibrationEnabled ? Color.green : Color.secondary)
                    Text(calibration.calibrationEnabled
                         ? "Calibration ON" : "Calibration OFF")
                        .font(.caption.bold())
                    Spacer()
                    if calibration.calibrationEnabled {
                        Button {
                            calibration.clearSavedFit()
                        } label: {
                            Label("Clear", systemImage: "xmark.circle")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
                if calibration.calibrationEnabled, calibration.savedAt != nil {
                    Text(String(format: "SDNN_out = %.2f × raw + %.0f  (n=%d, r=%.2f)",
                                calibration.savedSlope, calibration.savedIntercept,
                                calibration.savedN, calibration.savedR))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)

            if !calibration.pairs.isEmpty {
                DisclosureGroup("Show \(calibration.pairs.count) paired values") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(calibration.pairs.prefix(50)) { p in
                            Text("\(p.time.formatted(date: .omitted, time: .shortened))  Watch \(Int(p.watchMs)) ms  ·  WHOOP \(Int(p.whoopMs)) ms")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func formatElapsed(_ s: TimeInterval) -> String {
        let h = Int(s) / 3600
        let m = (Int(s) % 3600) / 60
        let sec = Int(s) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    private var developerToggle: some View {
        HStack {
            Spacer()
            Toggle(isOn: $devMode) {
                Label("Developer mode", systemImage: "hammer")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .controlSize(.mini)
        }
        .padding(.top, 4)
    }

    /// Multi-night sleep-features dataset for the per-user classifier
    /// training. Each confirmed sleep session appends its 30-second-epoch
    /// feature rows to a long-lived CSV — the user shares the whole file
    /// once at the end of the 14-21 night calibration period.
    private var sleepFeaturesCard: some View {
        let rowCount = sleep.masterEpochFeaturesRowCount
        let fileExists = FileManager.default.fileExists(atPath: sleep.masterEpochFeaturesCSVURL.path)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "chart.dots.scatter")
                    .foregroundStyle(.cyan)
                Text("Sleep features dataset").font(.headline)
                Spacer()
                Text("\(rowCount) rows")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Text("Per-30-second feature vectors from every confirmed sleep session, accumulated into one CSV. Pair with an Apple Health export.zip from the same window for classifier training.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if fileExists && rowCount > 0 {
                HStack(spacing: 8) {
                    ShareLink(
                        item: sleep.masterEpochFeaturesCSVURL,
                        preview: SharePreview("sleep_epoch_features_all_nights.csv")
                    ) {
                        Label("Export master CSV", systemImage: "square.and.arrow.up")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.cyan)
                    Button(role: .destructive) {
                        sleep.clearMasterEpochFeaturesCSV()
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            } else {
                // No file yet — explain why and prevent the ShareLink "unable
                // to prepare attachment" error that fires on a missing file.
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.orange)
                    Text("No data yet. The master CSV starts accumulating after you tap \"Write to Health\" on a sleep review (Discard or Cancel won't add rows).")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    /// Active-calorie estimation toggle. Reads age/sex/weight/restingHR from
    /// HealthKit on first launch (no manual entry), applies the Keytel
    /// formula every second of HR data, accumulates over 60-second windows
    /// and writes one `activeEnergyBurned` sample per minute. Apple Fitness's
    /// Move ring picks it up automatically.
    private var calorieCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "flame.fill").foregroundStyle(.orange)
                Text("Calorie estimation").font(.headline)
                Spacer()
                if estimateCalories, lastShownKcalPerMin > 0 {
                    Text(String(format: "%.1f kcal/min", lastShownKcalPerMin))
                        .font(.caption.monospaced())
                        .foregroundStyle(.orange)
                }
            }
            Toggle("Write Active Energy to Health", isOn: $estimateCalories)
                .tint(.orange)
                .font(.caption)
            Text("Profile (read from HealthKit on launch):")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("\(profileAgeYears) y · \(profileSex == .female ? "female" : "male") · \(Int(profileWeightKg)) kg · resting HR \(profileRestingHR)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Text("Keytel et al. 2005 regression. Drives Apple Fitness's Move ring. Accuracy is typical for any HR-based estimate (±15-20 % vs. metabolic-cart reference).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    /// Compact row of toggles for the heaviest dev-mode views. Both default
    /// off — the user enables only what they're actively using. Each toggle
    /// is described next to it so it's clear what the cost is.
    private var devModePerfToggles: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "tortoise")
                    .foregroundStyle(.orange)
                Text("Heavy dev panels (off for snappy UI)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Toggle("Packet inspector", isOn: $showPacketInspector)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption2)
                Toggle("BLE log", isOn: $showBLELog)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var bleLog: some View {
        if !ble.serviceLog.isEmpty {
            DisclosureGroup("BLE services (\(ble.serviceLog.count) lines)") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(ble.serviceLog.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption)
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if ble.isScanning {
                    Button("Stop") { ble.stopScan() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Scan for WHOOP") { ble.startScan() }
                        .buttonStyle(.borderedProminent)
                }
                if ble.connectedName != nil {
                    Button("Disconnect") { ble.disconnect() }
                        .buttonStyle(.bordered)
                        .tint(.red)
                }
            }
            if ble.connectedName != nil, devMode {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Button { ble.enableIMUStream() } label: {
                            Label("IMU on", systemImage: "figure.walk.motion")
                        }
                        Button { ble.disableIMUStream() } label: {
                            Label("IMU off", systemImage: "figure.stand")
                        }
                    }
                    HStack(spacing: 8) {
                        Button { ble.enableOpticalData() } label: {
                            Label("Optical on", systemImage: "waveform.path.ecg")
                        }
                        Button { ble.disableOpticalData() } label: {
                            Label("Optical off", systemImage: "waveform.path")
                        }
                    }
                    Button { ble.syncHistoricalData() } label: {
                        Label("Sync historical data (\(HistoricalLogger.shared.count) saved)",
                              systemImage: "arrow.down.doc")
                    }
                    .tint(.purple)
                    HStack(spacing: 8) {
                        Button { ble.setStrapClock() } label: {
                            Label("Set clock", systemImage: "clock.arrow.circlepath")
                        }
                        Button { ble.startRawData() } label: {
                            Label("Start raw", systemImage: "waveform.badge.plus")
                        }
                        Button { ble.stopRawData() } label: {
                            Label("Stop raw", systemImage: "waveform.slash")
                        }
                    }
                    Button { ble.sendR10R11Realtime() } label: {
                        Label("Try realtime HR stream (cmd 63)", systemImage: "dot.radiowaves.left.and.right")
                    }
                    Button { showSnapshotLab = true } label: {
                        Label("Health snapshot lab (0x4B reverse-engineering)",
                              systemImage: "heart.text.square.fill")
                    }
                    .tint(.teal)
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
        }
    }
}

#Preview {
    let b = BLEManager()
    let h = HealthKitManager()
    ContentView()
        .environmentObject(b)
        .environmentObject(h)
        .environmentObject(SleepTracker(health: h))
        .environmentObject(AlarmManager(ble: b))
        .environmentObject(HRVCalibration(health: h))
        .environmentObject(HistoricalAnalyzer())
        .environmentObject(SkinTempCalibration())
}
