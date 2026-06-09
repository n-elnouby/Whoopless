//
//  BLEManager.swift
//  Whoopless
//

import Foundation
import Combine
import CoreBluetooth

// MARK: - GATT constants (nonisolated so the CB delegate methods can read them)
//
// Swift 6 / "Member Import Visibility" + SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
// means plain `let` properties on a @MainActor class are MainActor-isolated and
// therefore unreachable from `nonisolated` delegate methods. We put the UUIDs
// in a nonisolated enum so both sides can see them.
private enum GATT {
    nonisolated(unsafe) static let hrService      = CBUUID(string: "180D")
    nonisolated(unsafe) static let hrMeasurement  = CBUUID(string: "2A37")
    nonisolated(unsafe) static let batteryService = CBUUID(string: "180F")
    nonisolated(unsafe) static let batteryLevel   = CBUUID(string: "2A19")
}

/// Scans for BLE devices advertising the standard Heart Rate Service (0x180D),
/// subscribes to Heart Rate Measurement (0x2A37) notifications, and parses
/// BPM + RR-intervals out of each packet.
///
/// WHOOP 4.0 broadcasts using this standard profile when "Broadcast HR"
/// is enabled in the WHOOP app.
@MainActor
final class BLEManager: NSObject, ObservableObject {

    // WHOOP's proprietary command/data service (found via discoverServices(nil)).
    nonisolated(unsafe) private static let whoopServiceUUID    = CBUUID(string: "61080001-8D6D-82B8-614A-1C8CB0F8DCC6")
    nonisolated(unsafe) private static let whoopCmdToStrapUUID = CBUUID(string: "61080002-8D6D-82B8-614A-1C8CB0F8DCC6")

    // MARK: - State
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cmdCharacteristic: CBCharacteristic?
    private var cmdCounter: UInt8 = 0

    @Published var state: String = "Idle"
    @Published var isScanning = false
    @Published var discoveredDevices: [CBPeripheral] = []
    @Published var connectedName: String?
    @Published var heartRate: Int = 0
    @Published var rrIntervalsMs: [Double] = []
    @Published var batteryLevel: Int?
    @Published var lastUpdate: Date?
    /// Timestamp of the most recently received BLE packet of ANY kind. Used by
    /// the watchdog to detect silent disconnects — iOS's BLE stack sometimes
    /// reports "connected" while the actual radio link has been gone for
    /// minutes. If no packets arrive for >60s, we force a teardown + reconnect.
    @Published var lastPacketAt: Date?
    /// Most recently parsed historical packet — used by the inspector UI to
    /// show all 96 bytes of the latest sample so we can finish field discovery.
    @Published var latestHistorical: HistoricalSample?
    /// Rolling smoothed HR extracted from byte 63 of REALTIME_RAW_DATA packets.
    /// Per tagged-capture analysis: individual packets often have 0/255 sentinel
    /// values; valid HR samples are in the 30–200 range. We average across a
    /// short window to get a usable live number.
    @Published var latestRawHR: UInt8?
    @Published var latestRawTs: UInt32?
    private var rawHRBuffer: [UInt8] = []
    /// Last tag written to the raw log (e.g. "still", "active", "recovery").
    /// Used to mark phases during a structured 10-minute capture.
    @Published var currentCaptureTag: String?
    @Published var captureTagAt: Date?

    /// HR-match narrowing tool: each "snapshot" intersects the set of byte
    /// positions whose value matches live HR at that instant. After a few
    /// snapshots with different HR values, only the real HR byte(s) remain.
    @Published var hrMatchCommonBytes: Set<Int> = []
    @Published var hrMatchFirstSnapshot: Bool = true
    @Published var hrMatchSnapshotCount: Int = 0
    @Published var hrMatchHistory: [String] = []   // readable log lines
    private var awaitingHRMatchTarget: UInt8?      // HR value to match in next RAW packet
    /// Debug log — service/characteristic tree + sample payloads from unknown
    /// characteristics. Rendered in the UI so you can screenshot/share it.
    @Published var serviceLog: [String] = []

    /// Callback fired every time we parse a new HR measurement.
    var onHeartRate: ((_ bpm: Int, _ rrs: [Double]) -> Void)?
    /// Callback fired when a HISTORICAL_DATA packet is parsed. Lets the UI /
    /// HealthKit layer decide what to do with the decoded sample.
    var onHistoricalSample: ((HistoricalSample) -> Void)?

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: true,
                CBCentralManagerOptionRestoreIdentifierKey: "com.whoopless.central"
            ]
        )
    }

    // MARK: - Public API

    func startScan() {
        guard central.state == .poweredOn else {
            state = "Bluetooth not ready"
            return
        }
        discoveredDevices.removeAll()
        central.scanForPeripherals(
            withServices: [GATT.hrService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        isScanning = true
        state = "Scanning for HR devices…"
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        state = "Stopped"
    }

    func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        central.stopScan()
        isScanning = false
        central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        state = "Connecting to \(p.name ?? "device")…"
    }

    func disconnect() {
        guard let p = peripheral else { return }
        central.cancelPeripheralConnection(p)
    }

    /// Write a command packet to WHOOP's proprietary CMD_TO_STRAP characteristic.
    /// Used for haptics / IMU / optical / alarm / etc.
    func sendCommand(_ command: WhoopCommand, value: UInt8 = 0x01) {
        sendCommand(command, payload: [value])
    }

    func sendCommand(_ command: WhoopCommand, payload: [UInt8]) {
        guard let ch = cmdCharacteristic, let p = peripheral else {
            state = "Command channel not ready"
            return
        }
        let packet = WhoopProtocol.encodeCommand(
            counter: cmdCounter,
            command: command.rawValue,
            payload: payload
        )
        cmdCounter &+= 1
        p.writeValue(packet, for: ch, type: .withResponse)
        let hex = packet.map { String(format: "%02X", $0) }.joined(separator: " ")
        let payloadHex = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
        serviceLog.append("> CMD \(command) [\(payloadHex)]: \(hex)")
    }

    /// Fire the strap's haptic motor once (pattern index 0).
    /// This is your silent alarm buzz.
    func buzzStrap() {
        sendCommand(.runHapticsPattern, value: 0x00)
    }

    /// Stop any in-progress haptic pattern.
    func stopHaptics() {
        sendCommand(.stopHaptics, payload: [])
    }

    /// Enable the raw accelerometer stream. If the command channel works,
    /// type-0x33 packets start appearing on 61080004/05 within a second.
    func enableIMUStream() {
        sendCommand(.toggleIMUMode, value: 0x01)
    }

    func disableIMUStream() {
        sendCommand(.toggleIMUMode, value: 0x00)
    }

    /// Turn on the raw optical (PPG) data broadcast. In the whoomp source this
    /// is the pairing command that actually pushes sensor data over BLE; it
    /// may double as the "start broadcasting" trigger for IMU too.
    func enableOpticalData() {
        sendCommand(.enableOpticalData, value: 0x01)
    }

    func disableOpticalData() {
        sendCommand(.enableOpticalData, value: 0x00)
    }

    /// Send arbitrary pre-baked bytes to CMD_TO_STRAP. Lets us try hex strings
    /// from external reverse-engineering sources verbatim, bypassing our encoder.
    /// Example: "AA 08 00 A8 23 0E 16 00 11 47 C5 85"
    func sendRawHex(_ hex: String) {
        let clean = hex.replacingOccurrences(of: " ", with: "")
        var bytes: [UInt8] = []
        var i = clean.startIndex
        while i < clean.endIndex {
            let end = clean.index(i, offsetBy: 2, limitedBy: clean.endIndex) ?? clean.endIndex
            if let b = UInt8(String(clean[i..<end]), radix: 16) { bytes.append(b) }
            i = end
        }
        guard let ch = cmdCharacteristic, let p = peripheral else {
            state = "Command channel not ready"
            return
        }
        let data = Data(bytes)
        p.writeValue(data, for: ch, type: .withResponse)
        let display = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        serviceLog.append("> RAW: \(display)")
    }

    /// Ask the strap to dump its buffered historical data. Sends
    /// SEND_HISTORICAL_DATA (cmd 0x16) and the strap replies with a flood of
    /// 96-byte HISTORICAL_DATA packets (type 0x2F) on characteristic 61080005.
    /// Each packet ≈ 1 second of stored sensor readings.
    func syncHistoricalData() {
        // Send SET_CLOCK on EVERY drain. The strap's internal clock drifts
        // aggressively when it enters low-power "tick counting" mode after
        // periods of inactivity — drifts of 4+ hours have been observed
        // after a single backgrounding cycle. The previous 5-minute throttle
        // wasn't tight enough to catch up; firing on every drain is the
        // cheapest reliable fix (12 bytes of BLE traffic per minute).
        setStrapClock()
        sendRawHex("AA 08 00 A8 23 0E 16 00 11 47 C5 85")
        lastHistoricalSyncAt = Date()
    }

    private var autoSyncTimer: Timer?
    /// Last time we fired SEND_HISTORICAL_DATA, regardless of trigger source
    /// (timer or BLE-event tickle). Used to throttle the BLE-event path.
    private var lastHistoricalSyncAt: Date = .distantPast
    private let historicalSyncInterval: TimeInterval = 60

    /// Fire SEND_HISTORICAL_DATA on a repeating timer so the strap's buffer
    /// drains into HealthKit automatically. Called from `didConnect`.
    ///
    /// **Important caveat:** `Timer.scheduledTimer` is paused when iOS suspends
    /// the app in the background — even though incoming BLE notifications keep
    /// flowing. So overnight, when the screen is off and the app is suspended,
    /// this timer doesn't fire and historical packets stop draining (which
    /// means HRV writes stop, even though live HR keeps coming through).
    ///
    /// As a backstop, `tickleHistoricalSyncFromHRNotification()` is called
    /// from within the BLE HR-notification handler. iOS DOES wake us briefly
    /// for incoming BLE notifications, so that gives us a reliable heartbeat
    /// to drive historical sync requests overnight.
    func startAutoSyncHistorical(every seconds: TimeInterval = 60) {
        autoSyncTimer?.invalidate()
        autoSyncTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncHistoricalData() }
        }
        // Also trigger immediately.
        syncHistoricalData()
    }
    func stopAutoSyncHistorical() {
        autoSyncTimer?.invalidate()
        autoSyncTimer = nil
    }

    /// Called from the live HR notification handler. If 60+ seconds have
    /// passed since the last historical sync, fire one. Survives iOS
    /// background suspension because BLE notifications wake the app.
    private func tickleHistoricalSyncFromHRNotification() {
        let now = Date()
        if now.timeIntervalSince(lastHistoricalSyncAt) >= historicalSyncInterval {
            lastHistoricalSyncAt = now
            syncHistoricalData()
        }
    }

    // MARK: - Connection watchdog
    //
    // iOS's BLE stack has a known edge case where a CBCentralManager reports a
    // peripheral as "connected" long after the actual radio link has gone
    // silent (strap out of range, OS suspended our app briefly, etc). The
    // `didDisconnect` delegate fires eventually, but it can take minutes —
    // during which we're losing data.
    //
    // The watchdog polls every 30s. If no packet of ANY kind has arrived for
    // >60s while we believe we're connected, we explicitly tear down the
    // connection. That forces `didDisconnect` to fire NOW, which in turn
    // triggers our auto-reconnect path.
    private var watchdogTimer: Timer?
    private let watchdogTimeout: TimeInterval = 60
    private let watchdogCheckInterval: TimeInterval = 30

    func startWatchdog() {
        watchdogTimer?.invalidate()
        lastPacketAt = Date()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: watchdogCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self,
                      let last = self.lastPacketAt,
                      let p = self.peripheral,
                      self.connectedName != nil else { return }
                if Date().timeIntervalSince(last) > self.watchdogTimeout {
                    self.state = "Silent disconnect — forcing reconnect"
                    self.central.cancelPeripheralConnection(p)
                    // didDisconnect will then call central.connect() for us.
                }
            }
        }
    }

    func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    /// Set the strap's internal clock to the iPhone's current Unix time.
    /// Payload = **8 bytes**: `[seconds u32 LE][subseconds u32 LE]`. NoopApp
    /// documents: "A wrong-length `SET_CLOCK` is ack'd but not latched,
    /// leaving the RTC 'lost' so the strap won't serve type-47." We were
    /// previously sending 4 bytes — this likely explains both our chronic
    /// 4+ hour clock drift and the stale-historical-buffer problem.
    /// Subseconds are in 1/32768 s units; zero is fine.
    func setStrapClock() {
        let now = UInt32(Date().timeIntervalSince1970)
        let secs: [UInt8] = [
            UInt8(now & 0xFF),
            UInt8((now >> 8) & 0xFF),
            UInt8((now >> 16) & 0xFF),
            UInt8((now >> 24) & 0xFF)
        ]
        let subsecs: [UInt8] = [0, 0, 0, 0]
        sendCommand(.setClock, payload: secs + subsecs)
    }

    /// Start raw live sensor streaming. Per NoopApp's reverse-engineering:
    /// `SEND_R10_R11_REALTIME` (cmd 63) is "the **real** type-43 raw-stream
    /// switch." `START_RAW_DATA` (81/82) does not actually control the
    /// ~2/s type-43 raw flood despite the name. We've been calling the
    /// wrong command.
    func startRawData() {
        sendCommand(.sendR10R11Realtime, value: 0x01)
    }

    func stopRawData() {
        sendCommand(.sendR10R11Realtime, value: 0x00)
    }

    /// Try SEND_R10_R11_REALTIME — actually the live raw stream switch.
    func sendR10R11Realtime() {
        sendCommand(.sendR10R11Realtime, value: 0x01)
    }

    /// Defensive — release the strap from high-frequency sync mode in case
    /// a previous app session left it parked there. Plain
    /// SEND_HISTORICAL_DATA returns the type-47 store normally after this.
    /// Safe to fire blindly on every connect.
    func exitHighFreqSync() {
        sendCommand(.exitHighFreqSync, value: 0x00)
    }

    /// Fire a one-shot Health Monitor snapshot (cmd 0x4B). The strap should
    /// cycle Red + IR LEDs for ~15 seconds and deliver results as a large
    /// EVENT (0x30) packet on `61080004`. Watch the BLE log.
    ///
    /// Returns the capture ID used by `HealthSnapshotLogger` so the caller
    /// can later annotate it with reference SpO2 / skin-temp values.
    @discardableResult
    func triggerHealthSnapshot(captureWindow: TimeInterval = 30) -> UUID {
        let id = HealthSnapshotLogger.shared.beginCapture(window: captureWindow)
        sendCommand(.healthMonitorTrigger, value: 0x01)
        return id
    }

    /// Snapshot: on the next incoming REALTIME_RAW_DATA header packet, find all
    /// byte positions whose value equals the current live HR. Intersect with
    /// prior snapshots so the set narrows after each tap.
    func snapshotHRMatch() {
        let targetHR = UInt8(min(255, max(0, heartRate)))
        guard targetHR >= 30 else {
            hrMatchHistory.append("⚠︎ live HR not valid, skipped")
            return
        }
        awaitingHRMatchTarget = targetHR
        hrMatchHistory.append("... waiting for packet (target HR \(targetHR))")
    }

    /// Reset the narrowing state so the next snapshot starts fresh.
    func resetHRMatch() {
        hrMatchCommonBytes = []
        hrMatchFirstSnapshot = true
        hrMatchSnapshotCount = 0
        hrMatchHistory.removeAll()
        awaitingHRMatchTarget = nil
    }

    /// Write a phase marker into the raw log — use during a structured capture
    /// to bracket known-condition windows for offline decoding.
    func tagCapture(_ name: String) {
        RealtimeRawLogger.shared.appendTag(name)
        currentCaptureTag = name
        captureTagAt = Date()
        serviceLog.append("⌘ TAG: \(name)")
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let newState = central.state
        Task { @MainActor in
            switch newState {
            case .poweredOn:     self.state = "Ready"
            case .poweredOff:    self.state = "Bluetooth is off"
            case .unauthorized:  self.state = "Bluetooth unauthorized"
            case .unsupported:   self.state = "Bluetooth unsupported"
            case .resetting:     self.state = "Bluetooth resetting…"
            case .unknown:       self.state = "Bluetooth unknown"
            @unknown default:    self.state = "Bluetooth unavailable"
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    willRestoreState dict: [String : Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let first = peripherals.first else { return }
        Task { @MainActor in
            self.peripheral = first
            first.delegate = self
            // If iOS handed us back an already-connected peripheral, re-discover
            // services so we re-subscribe to HR + WHOOP notifications. Without
            // this, the peripheral object exists but no packets flow — which
            // produces exactly the silent-overnight-disconnect symptom.
            if first.state == .connected {
                self.connectedName = first.name
                self.state = "Restored — rediscovering services"
                first.discoverServices(nil)
                self.startWatchdog()

                // Belt-and-braces: iOS sometimes hands the peripheral back
                // with services already cached and skips firing
                // didDiscoverServices, leaving cmdCharacteristic nil. After
                // 3s, if we still don't have the cmd characteristic, walk the
                // already-discovered services and force re-discovery of
                // characteristics on each.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self = self,
                          self.cmdCharacteristic == nil,
                          let p = self.peripheral else { return }
                    if let services = p.services, !services.isEmpty {
                        for s in services {
                            p.discoverCharacteristics(nil, for: s)
                        }
                    } else {
                        p.discoverServices(nil)
                    }
                }
            } else {
                // Not connected — ask iOS to reconnect.
                self.state = "Restored — reconnecting"
                central.connect(first, options: nil)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String : Any],
                                    rssi RSSI: NSNumber) {
        Task { @MainActor in
            if !self.discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
                self.discoveredDevices.append(peripheral)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.connectedName = peripheral.name
            self.state = "Connected. Discovering services…"
            // Connect handshake based on the NoopApp/noop reverse-engineering
            // notes — three commands fired in sequence with small delays so
            // each lands cleanly:
            //
            // t+2 s: SET_CLOCK (8 bytes — see setStrapClock comment for why
            //        wrong-length writes silently fail and leave RTC "lost").
            // t+3 s: EXIT_HIGH_FREQ_SYNC — defensive release in case a
            //        previous app session left the strap parked in
            //        high-frequency offload mode. Plain
            //        SEND_HISTORICAL_DATA only returns the type-47 store
            //        normally after this.
            // t+5 s: begin periodic historical sync.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.setStrapClock()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.exitHighFreqSync()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.startAutoSyncHistorical(every: 60)
            }
            // Start the watchdog — if packets stop flowing we force-reconnect.
            self.startWatchdog()
        }
        peripheral.discoverServices(nil)
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        let message = error?.localizedDescription ?? "unknown"
        Task { @MainActor in
            self.state = "Failed to connect: \(message)"
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.connectedName = nil
            self.state = "Disconnected"
            self.stopAutoSyncHistorical()
            self.stopWatchdog()
            central.connect(peripheral, options: nil)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        // Log every service — then ask for every characteristic under it.
        print("=== WHOOP advertised services ===")
        for service in services {
            print("service \(service.uuid) (\(Self.describe(service.uuid)))")
            peripheral.discoverCharacteristics(nil, for: service)
            // Also surface it in the UI log.
            Task { @MainActor in
                self.serviceLog.append("S \(service.uuid) \(Self.describe(service.uuid))")
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        let chars = service.characteristics ?? []
        print("  characteristics under \(service.uuid):")
        for ch in chars {
            let props = Self.propertyList(ch.properties)
            print("    char \(ch.uuid) [\(props)] (\(Self.describe(ch.uuid)))")
            Task { @MainActor in
                self.serviceLog.append("  C \(ch.uuid) [\(props)] \(Self.describe(ch.uuid))")
            }

            // Subscribe to the known, useful ones.
            if ch.uuid == GATT.hrMeasurement {
                peripheral.setNotifyValue(true, for: ch)
                Task { @MainActor in self.state = "Receiving heart rate" }
            } else if ch.uuid == GATT.batteryLevel {
                peripheral.readValue(for: ch)
                peripheral.setNotifyValue(true, for: ch)
            } else if ch.uuid == Self.whoopCmdToStrapUUID {
                // Keep a reference so we can write commands later, and clear
                // any stale "Command channel not ready" state string so the
                // status card doesn't keep claiming the channel is dead once
                // it actually came up.
                Task { @MainActor in
                    self.cmdCharacteristic = ch
                    if self.state == "Command channel not ready" {
                        self.state = "Connected"
                    }
                }
            } else if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                // Subscribe to any other notifying characteristic so we can see
                // what kind of payloads WHOOP is pushing out.
                peripheral.setNotifyValue(true, for: ch)
            } else if ch.properties.contains(.read) {
                peripheral.readValue(for: ch)
            }
        }
    }

    // MARK: - Debug helpers

    nonisolated static func propertyList(_ p: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if p.contains(.read)       { parts.append("read") }
        if p.contains(.write)      { parts.append("write") }
        if p.contains(.writeWithoutResponse) { parts.append("writeNR") }
        if p.contains(.notify)     { parts.append("notify") }
        if p.contains(.indicate)   { parts.append("indicate") }
        return parts.joined(separator: "|")
    }

    /// Human-readable hint for well-known Bluetooth SIG UUIDs; returns "" for
    /// standard UUIDs (since CBUUID.description already names them) and a
    /// custom marker for WHOOP's proprietary UUIDs so they stand out in the log.
    nonisolated static func describe(_ uuid: CBUUID) -> String {
        let s = uuid.uuidString.uppercased()
        // 4-char strings are 16-bit assigned-number UUIDs — Apple already names them.
        if s.count == 4 { return "" }
        return "[custom]"
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let data = characteristic.value else { return }

        // Mark the watchdog — any packet of any kind means the radio link is alive.
        Task { @MainActor in self.lastPacketAt = Date() }

        // If a health-snapshot capture window is active, log EVERY packet that
        // arrives — we don't yet know which characteristic the SpO2 / temp
        // payload comes back on, so we capture the lot for offline analysis.
        // Use the FIRST 8 hex chars (e.g. "61080004") because all WHOOP
        // characteristics share the same `...8D6D-82B8-614A-1C8CB0F8DCC6`
        // suffix — using the suffix would collapse them all into "DCC6".
        let uuidStr = characteristic.uuid.uuidString
        let charID = uuidStr.count >= 8 ? String(uuidStr.prefix(8)) : uuidStr
        HealthSnapshotLogger.shared.observe(data: data, characteristic: charID)

        if characteristic.uuid == GATT.hrMeasurement {
            let (bpm, rrs) = Self.parseHRM(data)
            Task { @MainActor in
                self.heartRate = bpm
                self.rrIntervalsMs = rrs
                self.lastUpdate = Date()
                self.onHeartRate?(bpm, rrs)
                // Backstop for iOS background timer suspension: each HR
                // notification is an opportunity to fire SEND_HISTORICAL_DATA
                // if we haven't done so in 60+ seconds. iOS wakes us briefly
                // for incoming BLE notifications even when the app is
                // suspended, so this path keeps HRV flowing overnight.
                self.tickleHistoricalSyncFromHRNotification()
            }
        } else if characteristic.uuid == GATT.batteryLevel, let byte = data.first {
            Task { @MainActor in self.batteryLevel = Int(byte) }
        } else {
            // If this looks like a HISTORICAL_DATA packet (type 0x2F), persist
            // the full bytes to disk + parse known fields into the live UI.
            if data.count >= 5, data[0] == 0xAA, data[4] == 0x2F {
                HistoricalLogger.shared.append(data)
                if let sample = HistoricalParser.parse(data) {
                    Task { @MainActor in
                        self.latestHistorical = sample
                        self.onHistoricalSample?(sample)
                    }
                }
            }

            // REALTIME_RAW_DATA (type 0x2B) — fragments of a large multi-channel
            // sensor dump. Header fragments (those starting with AA) carry HR
            // at byte 63 (confirmed via tagged capture) with sporadic sentinel
            // errors; we smooth across a ~10-packet rolling window.
            if characteristic.uuid.uuidString.contains("61080005") {
                RealtimeRawLogger.shared.append(data)
                if data.count >= 64, data[0] == 0xAA, data[4] == 0x2B {
                    let bytes = [UInt8](data)
                    let ts = UInt32(bytes[11]) | (UInt32(bytes[12]) << 8)
                          | (UInt32(bytes[13]) << 16) | (UInt32(bytes[14]) << 24)
                    let rawHR = bytes[63]
                    Task { @MainActor in
                        self.latestRawTs = ts
                        if rawHR >= 30, rawHR <= 200 {
                            self.rawHRBuffer.append(rawHR)
                            if self.rawHRBuffer.count > 10 {
                                self.rawHRBuffer.removeFirst(self.rawHRBuffer.count - 10)
                            }
                            let sorted = self.rawHRBuffer.sorted()
                            self.latestRawHR = sorted[sorted.count / 2]
                        }

                        // HR-match snapshot: find every byte, u16 LE, u16 BE, and
                        // common scaled-byte transform (2×HR, HR+offset) that equals
                        // the target. Wide net so we don't miss an encoding.
                        if let target = self.awaitingHRMatchTarget {
                            let t = Int(target)
                            var matches: Set<Int> = []
                            var tagsAt: [Int: String] = [:]
                            let maxIdx = min(1928, bytes.count)
                            for i in 0..<maxIdx {
                                if Int(bytes[i]) == t { matches.insert(i); tagsAt[i, default: ""] += "u8 " }
                                if Int(bytes[i]) == 2*t { matches.insert(i); tagsAt[i, default: ""] += "2×u8 " }
                                if Int(bytes[i]) == t - 40 { matches.insert(i); tagsAt[i, default: ""] += "u8-40 " }
                                if i + 1 < maxIdx {
                                    let le = Int(bytes[i]) | (Int(bytes[i+1]) << 8)
                                    let be = (Int(bytes[i]) << 8) | Int(bytes[i+1])
                                    if le == t   { matches.insert(i); tagsAt[i, default: ""] += "u16LE " }
                                    if be == t   { matches.insert(i); tagsAt[i, default: ""] += "u16BE " }
                                    if le == 2*t { matches.insert(i); tagsAt[i, default: ""] += "2×u16LE " }
                                }
                            }
                            if self.hrMatchFirstSnapshot {
                                self.hrMatchCommonBytes = matches
                                self.hrMatchFirstSnapshot = false
                            } else {
                                self.hrMatchCommonBytes = self.hrMatchCommonBytes.intersection(matches)
                            }
                            self.hrMatchSnapshotCount += 1
                            let remaining = self.hrMatchCommonBytes.sorted()
                                .map { "\($0)(\(tagsAt[$0]?.trimmingCharacters(in: .whitespaces) ?? "?"))" }
                                .joined(separator: ", ")
                            self.hrMatchHistory.append("#\(self.hrMatchSnapshotCount) HR=\(target): \(matches.count) matches → \(self.hrMatchCommonBytes.count) common [\(remaining)]")
                            self.awaitingHRMatchTarget = nil
                        }
                    }
                }
            }

            // Unknown characteristic — log the first packet so we can see what
            // kind of payload WHOOP pushes. Limits to first 32 bytes to keep
            // the UI log readable.
            let hex = data.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
            let uuid = characteristic.uuid
            let name = Self.describe(uuid)
            let size = data.count
            Task { @MainActor in
                let line = "  V \(uuid) (\(size)B): \(hex) — \(name)"
                // Don't spam: only keep the first observation per characteristic,
                // plus the latest 2 updates.
                let priorFor = self.serviceLog.filter { $0.contains("\(uuid)") && $0.hasPrefix("  V ") }
                if priorFor.count < 10 {
                    self.serviceLog.append(line)
                }
            }
        }
    }

    // MARK: - Heart Rate Measurement parser (characteristic 0x2A37)
    //
    // Packet layout per Bluetooth SIG spec:
    //   byte 0: flags
    //       bit 0  -> HR value format (0 = uint8, 1 = uint16)
    //       bit 3  -> energy expended present (2 bytes, after HR)
    //       bit 4  -> RR-interval values present (0..N pairs of uint16, each 1/1024 s)
    //   byte 1..:  HR value (1 or 2 bytes)
    //   then:      optional energy expended (2 bytes)
    //   then:      zero or more RR intervals (uint16 little endian, 1/1024 s)
    nonisolated static func parseHRM(_ data: Data) -> (Int, [Double]) {
        guard data.count >= 2 else { return (0, []) }
        let bytes = [UInt8](data)
        let flags = bytes[0]
        let hr16  = (flags & 0x01) != 0
        let eePresent = (flags & 0x08) != 0
        let rrPresent = (flags & 0x10) != 0

        var i = 1
        var bpm = 0
        if hr16 {
            guard bytes.count >= i + 2 else { return (0, []) }
            bpm = Int(bytes[i]) | (Int(bytes[i+1]) << 8)
            i += 2
        } else {
            bpm = Int(bytes[i])
            i += 1
        }
        if eePresent { i += 2 }

        var rrs: [Double] = []
        if rrPresent {
            while i + 1 < bytes.count {
                let raw = Int(bytes[i]) | (Int(bytes[i+1]) << 8)
                rrs.append(Double(raw) * 1000.0 / 1024.0)
                i += 2
            }
        }
        return (bpm, rrs)
    }
}
