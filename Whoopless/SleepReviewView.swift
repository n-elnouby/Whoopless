//
//  SleepReviewView.swift
//  Whoopless
//
//  Sheet presented after the user stops a sleep session. Shows:
//   • Summary stats (in bed / asleep / awake / efficiency)
//   • Editable session start + end times
//   • Computed nightly HRV (SDNN + rMSSD) preview
//   • Per-bin awake/asleep toggle (collapsible timeline)
//   • Confirm + Discard buttons
//

import SwiftUI
import HealthKit

struct SleepReviewView: View {
    @ObservedObject var review: SleepReview
    let onConfirm: () -> Void
    let onDiscard: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showTimeline = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    summaryCard
                    hrvCard
                    boundsCard
                    timelineCard
                    actionRow
                }
                .padding()
            }
            .navigationTitle("Review sleep")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Discard", role: .destructive) {
                        onDiscard()
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(.indigo)
                Text("Summary").font(.headline)
                Spacer()
                Text("\(Int(review.efficiency * 100))%")
                    .font(.title3.bold())
                    .monospacedDigit()
                    .foregroundStyle(efficiencyColor)
            }
            Divider()
            statRow(label: "In bed", value: formatHM(review.totalInBed), tint: .secondary)
            statRow(label: "Asleep", value: formatHM(review.totalAsleep), tint: .indigo)
            statRow(label: "Awake",  value: formatHM(review.totalAwake),  tint: .orange)
            statRow(label: "Bins",
                    value: "\(review.asleepBinCount) asleep · \(review.awakeBinCount) awake",
                    tint: .secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var efficiencyColor: Color {
        let e = review.efficiency
        if e >= 0.85 { return .green }
        if e >= 0.70 { return .yellow }
        return .orange
    }

    // MARK: - HRV

    private var hrvCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(.teal)
                Text("Nightly HRV").font(.headline)
                Spacer()
                Text("\(review.rrCount) RRs")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Divider()
            if let sdnn = review.sdnnMs {
                statRow(label: "SDNN",  value: "\(Int(sdnn)) ms", tint: .green)
            } else {
                statRow(label: "SDNN",
                        value: "from Health median (RRs sparse)",
                        tint: .secondary)
            }
            if let r = review.rMSSDMs {
                statRow(label: "rMSSD", value: "\(Int(r)) ms", tint: .teal)
            }
            Text("Will be written tagged kind=\"nightly\" so MANTIS recognizes it as the canonical recovery number.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Editable bounds

    private var boundsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "clock.arrow.2.circlepath")
                    .foregroundStyle(.purple)
                Text("Adjust window").font(.headline)
            }
            DatePicker("Start", selection: $review.sessionStart,
                       in: ...review.sessionEnd,
                       displayedComponents: [.date, .hourAndMinute])
            DatePicker("End", selection: $review.sessionEnd,
                       in: review.sessionStart...,
                       displayedComponents: [.date, .hourAndMinute])
            Button {
                review.trimToActualSleep()
            } label: {
                Label("Trim to actual sleep", systemImage: "scissors")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .tint(.purple)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Per-bin timeline (collapsible)

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $showTimeline) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(review.binsInRange) { bin in
                        binRow(bin)
                    }
                }
                .padding(.top, 6)
            } label: {
                HStack {
                    Image(systemName: "rectangle.split.3x1.fill")
                        .foregroundStyle(.cyan)
                    Text("Timeline (\(review.binsInRange.count) bins)").font(.headline)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func binRow(_ bin: SleepReviewBin) -> some View {
        HStack {
            Circle()
                .fill(bin.classification == .awake ? Color.orange : Color.indigo)
                .frame(width: 8, height: 8)
            Text("\(formatTime(bin.start))–\(formatTime(bin.end))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            if let hr = bin.meanHR {
                Text("\(Int(hr)) bpm")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
            } else {
                Text("no data")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                review.toggleAwake(bin)
            } label: {
                Text(bin.classification == .awake ? "Awake" : "Asleep")
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(bin.classification == .awake
                                       ? Color.orange.opacity(0.25)
                                       : Color.indigo.opacity(0.25))
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Action row

    private var actionRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    onDiscard()
                    dismiss()
                } label: {
                    Label("Discard", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                Button {
                    onConfirm()
                    dismiss()
                } label: {
                    Label("Write to Health", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
            }
            // Export the per-30s feature CSV from the just-finished session.
            // Used for offline classifier development against Apple Watch
            // stage labels.
            if let url = featuresCSV {
                ShareLink(
                    item: url,
                    preview: SharePreview("sleep_epoch_features.csv")
                ) {
                    Label("Export per-30s features (CSV)",
                          systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.cyan)
            }
        }
        .padding(.top, 4)
    }

    /// CSV URL injected from outside — the SleepTracker writes the CSV when
    /// stop() builds the review and exposes the URL via `savedEpochFeaturesCSV`.
    var featuresCSV: URL?

    // MARK: - Helpers

    private func statRow(label: String, value: String, tint: Color) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(tint).monospacedDigit()
        }
        .font(.subheadline)
    }

    private func formatHM(_ s: TimeInterval) -> String {
        let h = Int(s) / 3600
        let m = (Int(s) % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m) min"
    }

    private func formatTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
