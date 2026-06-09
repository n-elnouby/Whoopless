//
//  HealthSnapshotView.swift
//  Whoopless
//
//  Reverse-engineering UI for the WHOOP health-snapshot response packet.
//  The user fires snapshots at known reference SpO2 / skin-temp values
//  (typically using Apple Watch as ground truth), the logger stores all
//  packets received in a 30-second window, and a built-in correlation
//  analyzer surfaces which byte positions track the reference value.
//

import SwiftUI
import Combine

struct HealthSnapshotView: View {
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dismiss) private var dismiss

    @State private var captures: [HealthSnapshotLogger.Capture] = []
    @State private var captureRemaining: Int = 0
    @State private var isCapturing: Bool = false
    /// UUID of the in-flight capture so we can annotate it specifically when
    /// it finishes (rather than guessing via `captures.last`).
    @State private var inflightCaptureID: UUID?

    @State private var pendingAnnotateID: UUID?
    @State private var refSpO2Text: String = ""
    @State private var refTempText: String = ""
    @State private var noteText: String = ""

    @State private var spo2Candidates: [HealthSnapshotLogger.ByteCandidate] = []
    @State private var tempCandidates: [HealthSnapshotLogger.ByteCandidate] = []

    // Pre-heat state. Toggling Realtime HR + IMU on then waiting 60 s before
    // 0x4B forces the strap out of low-power mode so the PPG sensor is
    // already locked when the health-check cycle begins. Avoids the abort
    // that produces sub-type 0x01/0x02 progress events instead of the
    // 52-byte sub-type 0x03 result.
    @State private var preheating: Bool = false
    @State private var preheatRemaining: Int = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    triggerCard
                    if !captures.isEmpty {
                        capturesList
                        analysisCard
                    } else {
                        emptyState
                    }
                }
                .padding()
            }
            .navigationTitle("Health snapshot lab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: annotateBinding) { ann in
                annotateSheet(captureID: ann.id)
            }
            .onAppear { refresh() }
            // Drives the countdown tick — but ONLY while a capture is in
            // flight. `.task(id:)` restarts whenever isCapturing changes,
            // and the loop exits as soon as the capture ends. Outside the
            // 90-second window there's no polling at all, which keeps the
            // parent view from re-rendering on every tick and prevents the
            // annotation form's TextFields from stuttering when the user
            // types. (The auto-finalize is driven by a queue.asyncAfter in
            // the logger itself, not by this poll loop, so we don't need
            // to watch for end conditions when no capture is running.)
            .task(id: isCapturing) {
                while isCapturing && !Task.isCancelled {
                    tickCapture()
                    try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
                }
            }
        }
    }

    // MARK: - Trigger card

    /// User-selectable capture window. 90 s captures one 0x4B response;
    /// longer durations let you watch the strap stream 0x2F packets while
    /// you're doing something physical (warming up the strap on-wrist,
    /// going from fridge to arm, etc) and analyze trends within a single
    /// capture window rather than across multiple separate snapshots.
    @State private var captureWindowSeconds: TimeInterval = 90
    private let windowOptions: [(label: String, seconds: TimeInterval)] = [
        ("90 s", 90),
        ("3 min", 180),
        ("5 min", 300),
        ("10 min", 600),
        ("15 min", 900),
    ]

    private var triggerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "heart.text.square.fill")
                    .foregroundStyle(.teal)
                Text("Trigger snapshot").font(.headline)
                Spacer()
                if isCapturing {
                    Label(formatRemaining(captureRemaining),
                          systemImage: "record.circle.fill")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.red)
                }
            }
            Text("Wear your Apple Watch (or a pulse oximeter). Note its current SpO2. Tap Trigger — Whoopless logs every packet for the chosen window. Use 90 s for a single 0x4B SpO2 result; use 5–15 min if you want to watch 0x2F packets stream while the strap warms up to skin temperature, fridge-to-arm transitions, etc.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Capture window selector. Disabled while capturing so the user
            // can't change the duration mid-run.
            Picker("Window", selection: $captureWindowSeconds) {
                ForEach(windowOptions, id: \.seconds) { opt in
                    Text(opt.label).tag(opt.seconds)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isCapturing)

            // Skin-contact indicator — green when the strap thinks it's on
            // a wrist, orange/gray otherwise. Triggers fired off-wrist
            // produce no SpO2 / temp data because the strap halts those
            // sensors when contact is lost.
            skinContactRow

            // Pre-heat sequence. Wakes the strap's PPG / IMU and waits 60 s
            // for sensors to stabilize before the user fires the trigger.
            // Strongly improves the 0x4B → 0x30 sub-type 0x03 hit rate.
            HStack(spacing: 10) {
                Button {
                    startPreheat()
                } label: {
                    if preheating {
                        Label("Pre-heating \(preheatRemaining)s",
                              systemImage: "flame.fill")
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Pre-heat (60 s)", systemImage: "flame")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(preheating || isCapturing || ble.connectedName == nil)
            }

            HStack(spacing: 10) {
                Button {
                    inflightCaptureID = ble.triggerHealthSnapshot(captureWindow: captureWindowSeconds)
                    isCapturing = true
                    captureRemaining = Int(captureWindowSeconds)
                } label: {
                    Label("Trigger (0x4B)", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .disabled(isCapturing || preheating || ble.connectedName == nil)

                if isCapturing {
                    Button(role: .destructive) {
                        HealthSnapshotLogger.shared.endCaptureNow()
                        // Run a tick immediately so the UI updates without
                        // waiting for the next 0.5s scheduled tick.
                        tickCapture()
                    } label: {
                        Label("Stop now", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    /// Reads the `skinContact` byte from the most recent historical packet.
    /// Per protocol notes, byte 55 of 0x2F: 0 = off-wrist, >0 = on-wrist
    /// (values 1-3 observed; specific grade meaning unknown). We treat any
    /// non-zero value as "on wrist" for practical purposes.
    @ViewBuilder
    private var skinContactRow: some View {
        let contact = ble.latestHistorical?.skinContact
        let isOn = (contact ?? 0) > 0
        let hasData = contact != nil
        HStack(spacing: 6) {
            Image(systemName: hasData
                  ? (isOn ? "hand.raised.fingers.spread.fill" : "hand.raised.slash")
                  : "questionmark.circle")
                .foregroundStyle(hasData ? (isOn ? Color.green : Color.orange) : Color.secondary)
            if hasData {
                Text(isOn
                     ? "On wrist (contact = \(contact!)) — good to capture"
                     : "Off wrist — snapshot will probably return no data")
                    .font(.caption2)
                    .foregroundStyle(isOn ? .green : .orange)
            } else {
                Text("Skin contact unknown — wait for the next 0x2F packet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No captures yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Trigger your first snapshot above.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Capture list

    private var capturesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(.purple)
                Text("Captures (\(captures.count))").font(.headline)
                Spacer()
                ShareLink(
                    item: HealthSnapshotLogger.shared.exportCSV(),
                    preview: SharePreview("health_snapshots_export.csv")
                ) {
                    Label("Export CSV", systemImage: "square.and.arrow.up").font(.caption)
                }
                .buttonStyle(.bordered)
                Button(role: .destructive) {
                    HealthSnapshotLogger.shared.clearAll()
                    refresh()
                } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            ForEach(captures) { cap in
                captureRow(cap)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func captureRow(_ cap: HealthSnapshotLogger.Capture) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(cap.triggeredAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                Spacer()
                Text("\(cap.packetCount) pkt")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                if let s = cap.refSpO2Pct {
                    Label(String(format: "%.1f%%", s), systemImage: "lungs")
                        .font(.caption2)
                        .foregroundStyle(.teal)
                } else {
                    Label("No SpO2", systemImage: "lungs")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let t = cap.refSkinTempC {
                    Label(String(format: "%.1f °C", t), systemImage: "thermometer.medium")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    Label("No temp", systemImage: "thermometer.medium")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                let types = cap.distinctTypes.map { String(format: "0x%02X", $0) }.joined(separator: " ")
                Text(types).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            if !cap.note.isEmpty {
                Text(cap.note).font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    pendingAnnotateID = cap.id
                    refSpO2Text = cap.refSpO2Pct.map { String(format: "%.1f", $0) } ?? ""
                    refTempText = cap.refSkinTempC.map { String(format: "%.1f", $0) } ?? ""
                    noteText = cap.note
                } label: {
                    Label("Annotate", systemImage: "pencil")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .tint(.indigo)
                Spacer()
                Button(role: .destructive) {
                    HealthSnapshotLogger.shared.deleteCapture(id: cap.id)
                    refresh()
                } label: {
                    Image(systemName: "trash").font(.caption2)
                }
                .buttonStyle(.borderless)
                .tint(.red)
            }
            Divider()
        }
    }

    // MARK: - Annotation sheet

    private struct AnnotateRef: Identifiable { let id: UUID }
    private var annotateBinding: Binding<AnnotateRef?> {
        Binding(
            get: { pendingAnnotateID.map { AnnotateRef(id: $0) } },
            set: { newVal in pendingAnnotateID = newVal?.id }
        )
    }

    private func annotateSheet(captureID: UUID) -> some View {
        // Extracted as its own View struct so it doesn't re-evaluate every
        // time the parent (HealthSnapshotView) re-renders. The parent observes
        // BLEManager via @EnvironmentObject, which fires once per second on
        // every HR notification — without isolation, every keystroke in the
        // text fields was competing with constant view recomputation.
        AnnotationSheetView(
            captureID: captureID,
            initialSpO2: refSpO2Text,
            initialTemp: refTempText,
            initialNote: noteText,
            onSave: { spo2, temp, note in
                HealthSnapshotLogger.shared.annotate(
                    id: captureID,
                    refSpO2Pct: spo2,
                    refSkinTempC: temp,
                    note: note
                )
                pendingAnnotateID = nil
                refresh()
            },
            onCancel: {
                pendingAnnotateID = nil
            }
        )
    }

    // MARK: - Analysis card

    private var analysisCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "scope")
                    .foregroundStyle(.cyan)
                Text("Byte-correlation analyzer").font(.headline)
                Spacer()
                Button {
                    let r = HealthSnapshotLogger.shared.analyzeCorrelations()
                    spo2Candidates = r.spo2
                    tempCandidates = r.temp
                } label: {
                    Label("Run", systemImage: "play.fill").font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.cyan)
            }
            Text("Looks for byte positions in the largest 0x30 packet of each capture whose value tracks the reference SpO2 / temp. Needs ≥ 3 captures with reference values across a range. |Pearson r| > 0.7 to be reported.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if spo2Candidates.isEmpty && tempCandidates.isEmpty {
                Text("No analysis yet — run the analyzer once you have a few annotated captures.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if !spo2Candidates.isEmpty {
                Text("SpO2 candidates").font(.caption.bold()).foregroundStyle(.teal)
                ForEach(Array(spo2Candidates.prefix(8).enumerated()), id: \.offset) { _, c in
                    candidateRow(c)
                }
            }
            if !tempCandidates.isEmpty {
                Text("Skin temp candidates").font(.caption.bold()).foregroundStyle(.orange)
                ForEach(Array(tempCandidates.prefix(8).enumerated()), id: \.offset) { _, c in
                    candidateRow(c)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func candidateRow(_ c: HealthSnapshotLogger.ByteCandidate) -> some View {
        let vals = c.sampleValues.prefix(6).map { String(format: "%.0f", $0) }.joined(separator: " ")
        let modeIcon = c.mode == "correlation" ? "function" : "scope"
        let modeColor: Color = c.mode == "correlation" ? .yellow : .cyan
        return HStack {
            Image(systemName: modeIcon)
                .font(.caption2)
                .foregroundStyle(modeColor)
                .frame(width: 14)
            Text("byte \(c.position)")
                .font(.caption2.monospaced())
                .frame(width: 60, alignment: .leading)
            Text(c.interpretation)
                .font(.caption2.monospaced())
                .frame(width: 70, alignment: .leading)
                .foregroundStyle(.secondary)
            if c.mode == "correlation" {
                Text(String(format: "r=%+.2f", c.correlation))
                    .font(.caption2.monospaced())
                    .foregroundStyle(abs(c.correlation) > 0.9 ? .green : .yellow)
            } else {
                Text("stable")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.cyan)
            }
            Spacer()
            Text(vals)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    // MARK: - State plumbing

    private func refresh() {
        captures = HealthSnapshotLogger.shared.captures
            .sorted { $0.triggeredAt > $1.triggeredAt }
    }

    /// Kick off the pre-heat sequence: enable IMU + realtime HR, then run
    /// a 60-second countdown so the user knows when the strap's PPG should
    /// be locked. After the countdown, the Trigger button re-enables.
    private func startPreheat() {
        preheating = true
        preheatRemaining = 60
        // Wake commands. Both are idempotent — safe to fire even if already on.
        ble.enableIMUStream()
        ble.sendR10R11Realtime()
        Task {
            for remaining in stride(from: 60, through: 1, by: -1) {
                preheatRemaining = remaining
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            preheating = false
            preheatRemaining = 0
        }
    }

    /// Format the remaining countdown as either "Ns" (under a minute) or
    /// "Mm Ss" (a minute or longer). Compact enough for the header badge.
    private func formatRemaining(_ secs: Int) -> String {
        if secs < 60 { return "\(secs)s" }
        let m = secs / 60
        let s = secs % 60
        return s == 0 ? "\(m)m" : "\(m)m \(s)s"
    }

    private func tickCapture() {
        let active = HealthSnapshotLogger.shared.isCapturing
        let remaining = HealthSnapshotLogger.shared.captureRemainingSeconds
        if isCapturing && !active {
            isCapturing = false
            captureRemaining = 0
            refresh()
            // Auto-prompt to annotate the just-finished capture (by ID).
            if let id = inflightCaptureID,
               HealthSnapshotLogger.shared.captures.contains(where: { $0.id == id }) {
                pendingAnnotateID = id
                refSpO2Text = ""
                refTempText = ""
                noteText = ""
                inflightCaptureID = nil
            }
        } else {
            isCapturing = active
            captureRemaining = remaining
        }
    }
}

/// Isolated annotation form. Owns its own text-field state via `@State`,
/// doesn't observe any environment objects, doesn't re-render on parent
/// state changes. Typing here is responsive even while BLE is firing
/// notifications at 1 Hz on the underlying ContentView.
private struct AnnotationSheetView: View {
    let captureID: UUID
    let initialSpO2: String
    let initialTemp: String
    let initialNote: String
    let onSave: (Double?, Double?, String) -> Void
    let onCancel: () -> Void

    @State private var spo2Text: String
    @State private var tempText: String
    @State private var noteText: String

    init(captureID: UUID,
         initialSpO2: String,
         initialTemp: String,
         initialNote: String,
         onSave: @escaping (Double?, Double?, String) -> Void,
         onCancel: @escaping () -> Void) {
        self.captureID = captureID
        self.initialSpO2 = initialSpO2
        self.initialTemp = initialTemp
        self.initialNote = initialNote
        self.onSave = onSave
        self.onCancel = onCancel
        _spo2Text = State(initialValue: initialSpO2)
        _tempText = State(initialValue: initialTemp)
        _noteText = State(initialValue: initialNote)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reference values (from Apple Watch / pulse oximeter)") {
                    HStack {
                        Text("SpO2")
                        Spacer()
                        TextField("97.5", text: $spo2Text)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                        Text("%")
                    }
                    HStack {
                        Text("Skin temp")
                        Spacer()
                        TextField("32.0", text: $tempText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                        Text("°C")
                    }
                }
                Section("Note") {
                    // Single-line TextField — multi-line `.vertical` axis
                    // has known stutter issues in SwiftUI Forms.
                    TextField("e.g. on-wrist 10 min, fridge to arm",
                              text: $noteText)
                }
            }
            .navigationTitle("Annotate capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let s = Double(spo2Text.replacingOccurrences(of: ",", with: "."))
                        let t = Double(tempText.replacingOccurrences(of: ",", with: "."))
                        onSave(s, t, noteText)
                    }
                    .bold()
                }
            }
        }
    }
}
