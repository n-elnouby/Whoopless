//
//  SleepEpochFeatures.swift
//  Whoopless
//
//  Per-30-second sleep-epoch feature extraction for downstream staging.
//
//  Features computed per epoch:
//    - HR mean, HR std, HR slope (trend)
//    - rMSSD, SDNN (time-domain HRV)
//    - HF, LF, LF/HF ratio (frequency-domain HRV via FFT — needs ~5 min of RR)
//    - Motion variance (accelerometer magnitude std)
//    - Mean motion (centered around 1g)
//    - Minutes since session start (circadian/cycle anchor)
//
//  These are exported as CSV during a sleep review so that paired analysis
//  against Apple Watch stage labels can guide a future staging classifier
//  (rule-based or trained). Computed but NOT used to classify yet — current
//  SleepTracker still emits binary asleep/awake until a downstream model is
//  validated.
//
//  Frequency-domain HRV requires ≥ 60 seconds of RR data and is most
//  meaningful over a 5-minute window. Per-epoch HF/LF here is a 5-minute
//  trailing window attributed to the current 30 s epoch. If insufficient
//  data exists, those fields are nil.
//

import Foundation
import Accelerate

struct SleepEpochFeatures: Codable, Equatable {
    let epochStart: Date
    let epochEnd: Date

    // HR features
    let hrMean: Double?
    let hrStd: Double?
    let hrSlope: Double?         // bpm per minute, signed; positive = rising

    // Time-domain HRV (over the 30 s epoch only — small sample size,
    // interpret with caution)
    let rMSSDms: Double?
    let sdnnMs: Double?

    // Frequency-domain HRV (5-min trailing window — more reliable)
    let hfPower: Double?         // 0.15–0.4 Hz integrated power (ms²)
    let lfPower: Double?         // 0.04–0.15 Hz integrated power (ms²)
    let lfHfRatio: Double?

    // Motion (accelerometer magnitude in g, gravity baseline subtracted)
    let motionStd: Double?
    let motionMean: Double?       // mean |accMag − 1g|

    // Circadian / sleep-cycle anchor
    let minutesSinceSessionStart: Double

    // MARK: - Compute from raw windows

    /// Build a feature vector from raw observation windows. All inputs
    /// already filtered for the relevant time range.
    static func compute(
        epochStart: Date,
        epochEnd: Date,
        sessionStart: Date,
        epochHR: [Double],                     // bpm samples in this 30s
        epochHRTimes: [Date],                  // matching timestamps
        epochAccelMag: [Double],               // |accel| in g samples in 30s
        rrFiveMinWindow: [Double]              // RR ms over the trailing 5 min
    ) -> SleepEpochFeatures {

        // --- HR mean / std / slope ---
        let hrMean = epochHR.isEmpty ? nil : epochHR.reduce(0, +) / Double(epochHR.count)
        let hrStd: Double? = {
            guard let m = hrMean, epochHR.count > 1 else { return nil }
            let v = epochHR.reduce(0.0) { $0 + ($1 - m) * ($1 - m) } / Double(epochHR.count - 1)
            return v.squareRoot()
        }()
        let hrSlope: Double? = {
            guard epochHR.count > 1, epochHRTimes.count == epochHR.count else { return nil }
            // Linear regression against time-in-minutes within the epoch.
            let t0 = epochHRTimes[0]
            let xs = epochHRTimes.map { $0.timeIntervalSince(t0) / 60.0 }
            let ys = epochHR
            let xm = xs.reduce(0, +) / Double(xs.count)
            let ym = ys.reduce(0, +) / Double(ys.count)
            var num = 0.0, den = 0.0
            for i in 0..<xs.count {
                num += (xs[i] - xm) * (ys[i] - ym)
                den += (xs[i] - xm) * (xs[i] - xm)
            }
            return den > 0 ? num / den : nil
        }()

        // --- Motion ---
        let motionMean: Double? = {
            guard !epochAccelMag.isEmpty else { return nil }
            return epochAccelMag.map { abs($0 - 1.0) }.reduce(0, +) / Double(epochAccelMag.count)
        }()
        let motionStd: Double? = {
            guard epochAccelMag.count > 1 else { return nil }
            let m = epochAccelMag.reduce(0, +) / Double(epochAccelMag.count)
            let v = epochAccelMag.reduce(0.0) { $0 + ($1 - m) * ($1 - m) } / Double(epochAccelMag.count - 1)
            return v.squareRoot()
        }()

        // --- Time-domain HRV over the 30 s epoch ---
        // NOTE: epoch-level rMSSD/SDNN are noisy with only 30 RRs. They're
        // included for completeness; the trained classifier (when it
        // exists) should weight the 5-min HF/LF features more heavily.
        let epochRRs: [Double] = {
            // Crude approximation: take RRs whose cumulative sum places them
            // inside this epoch. A more rigorous approach would timestamp
            // each RR explicitly. Skipped here for simplicity.
            let totalMs = (epochEnd.timeIntervalSince(epochStart)) * 1000
            var acc = 0.0, out: [Double] = []
            for rr in rrFiveMinWindow.suffix(60).reversed() {
                acc += rr
                if acc > totalMs { break }
                out.append(rr)
            }
            return out.reversed()
        }()
        let rMSSDms: Double? = {
            guard epochRRs.count >= 5 else { return nil }
            let diffs = zip(epochRRs, epochRRs.dropFirst()).map { $1 - $0 }
            let sq = diffs.reduce(0.0) { $0 + $1 * $1 }
            return diffs.isEmpty ? nil : (sq / Double(diffs.count)).squareRoot()
        }()
        let sdnnMs: Double? = {
            guard epochRRs.count >= 5 else { return nil }
            let m = epochRRs.reduce(0, +) / Double(epochRRs.count)
            let v = epochRRs.reduce(0.0) { $0 + ($1 - m) * ($1 - m) } / Double(epochRRs.count - 1)
            return v.squareRoot()
        }()

        // --- Frequency-domain HRV from the trailing 5-min RR window ---
        let (hfPower, lfPower) = computeHFLF(rrMs: rrFiveMinWindow)
        let lfHfRatio: Double? = {
            guard let hf = hfPower, hf > 0, let lf = lfPower else { return nil }
            return lf / hf
        }()

        let minSinceStart = epochStart.timeIntervalSince(sessionStart) / 60.0

        return SleepEpochFeatures(
            epochStart: epochStart,
            epochEnd: epochEnd,
            hrMean: hrMean,
            hrStd: hrStd,
            hrSlope: hrSlope,
            rMSSDms: rMSSDms,
            sdnnMs: sdnnMs,
            hfPower: hfPower,
            lfPower: lfPower,
            lfHfRatio: lfHfRatio,
            motionStd: motionStd,
            motionMean: motionMean,
            minutesSinceSessionStart: minSinceStart
        )
    }

    // MARK: - HF / LF via FFT
    //
    // Standard procedure for frequency-domain HRV:
    //   1. Take RR series (irregular sample rate).
    //   2. Resample to a uniform grid (4 Hz is conventional).
    //   3. Detrend (subtract the mean).
    //   4. FFT → power spectrum.
    //   5. Integrate power in HF (0.15–0.4 Hz) and LF (0.04–0.15 Hz) bands.
    //
    // Needs at least ~60 RRs (1 min) to be meaningful. Returns (HF, LF).
    static func computeHFLF(rrMs: [Double]) -> (Double?, Double?) {
        guard rrMs.count >= 60 else { return (nil, nil) }

        // Step 1: build the uniform 4 Hz timeline.
        // Cumulative RR times in seconds (each RR is the time gap from
        // previous beat).
        var cumT: [Double] = []
        var t = 0.0
        for rr in rrMs {
            t += rr / 1000.0
            cumT.append(t)
        }
        let totalSec = cumT.last ?? 0
        guard totalSec >= 60 else { return (nil, nil) }

        let fs: Double = 4.0   // resample rate Hz
        let n = Int(totalSec * fs)
        guard n >= 64 else { return (nil, nil) }

        // Step 2: linear-interpolate RR series onto 4 Hz grid.
        var resampled = [Double](repeating: 0, count: n)
        var j = 0
        for i in 0..<n {
            let target = Double(i) / fs
            while j + 1 < cumT.count - 1 && cumT[j + 1] < target { j += 1 }
            if j + 1 < cumT.count {
                let t0 = cumT[j], t1 = cumT[j + 1]
                let v0 = rrMs[j], v1 = rrMs[j + 1]
                let frac = (t1 - t0) > 0 ? (target - t0) / (t1 - t0) : 0
                resampled[i] = v0 + (v1 - v0) * frac
            } else {
                resampled[i] = rrMs.last ?? 0
            }
        }

        // Step 3: detrend (subtract mean) and apply Hann window.
        let mean = resampled.reduce(0, +) / Double(n)
        var windowed = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let h = 0.5 * (1 - cos(2 * .pi * Double(i) / Double(n - 1)))
            windowed[i] = (resampled[i] - mean) * h
        }

        // Step 4: FFT. Need power-of-2 length — pad with zeros.
        let log2n = vDSP_Length(ceil(log2(Double(n))))
        let fftN = Int(1 << log2n)
        var padded = windowed + [Double](repeating: 0, count: max(0, fftN - n))
        padded = Array(padded.prefix(fftN))

        guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else {
            return (nil, nil)
        }
        defer { vDSP_destroy_fftsetupD(setup) }

        var realp = [Double](repeating: 0, count: fftN / 2)
        var imagp = [Double](repeating: 0, count: fftN / 2)
        var hf: Double = 0
        var lf: Double = 0

        realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPDoubleSplitComplex(realp: realPtr.baseAddress!,
                                                  imagp: imagPtr.baseAddress!)
                padded.withUnsafeBufferPointer { padPtr in
                    padPtr.baseAddress!.withMemoryRebound(
                        to: DSPDoubleComplex.self, capacity: fftN / 2
                    ) { complexPtr in
                        vDSP_ctozD(complexPtr, 2, &split, 1, vDSP_Length(fftN / 2))
                    }
                }
                vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                // Step 5: integrate band power.
                // Frequency for bin k = k * fs / fftN.
                let df = fs / Double(fftN)
                for k in 1..<(fftN / 2) {
                    let f = Double(k) * df
                    let mag2 = realPtr[k] * realPtr[k] + imagPtr[k] * imagPtr[k]
                    if f >= 0.04 && f < 0.15 { lf += mag2 * df }
                    else if f >= 0.15 && f < 0.40 { hf += mag2 * df }
                }
            }
        }
        return (hf, lf)
    }

    // MARK: - CSV row

    static var csvHeader: String {
        "epoch_start,epoch_end,hr_mean,hr_std,hr_slope,rmssd,sdnn,hf,lf,lf_hf,motion_mean,motion_std,minutes_since_start\n"
    }

    var csvRow: String {
        func f(_ v: Double?) -> String {
            v.map { String(format: "%.4f", $0) } ?? ""
        }
        let s = ISO8601DateFormatter().string(from: epochStart)
        let e = ISO8601DateFormatter().string(from: epochEnd)
        return "\(s),\(e),\(f(hrMean)),\(f(hrStd)),\(f(hrSlope)),\(f(rMSSDms)),\(f(sdnnMs)),\(f(hfPower)),\(f(lfPower)),\(f(lfHfRatio)),\(f(motionMean)),\(f(motionStd)),\(f(minutesSinceSessionStart))\n"
    }
}
