# WHOOP 4.0 Protocol Notes

Findings from building [Whoopless](./README.md), an iOS HealthKit bridge for WHOOP 4.0. These are additions and corrections to the excellent work already published by [jogolden/whoomp](https://github.com/jogolden/whoomp) and [bWanShiTong/OpenWhoop](https://github.com/bWanShiTong/OpenWhoop). If you're starting a new WHOOP reverse-engineering project, read those first — this doc assumes you already understand the basic packet framing.

All findings verified on WHOOP 4.0 hardware, firmware as of April 2026. YMMV with other hardware revisions.

---

## 1. Packet framing — CRC parameters (confirmed empirically)

The WHOOP frame format is well-documented upstream:

```
AA <len_lo> <len_hi> <crc8> <payload...> <crc32 LE>
 │    └───────┬───────┘  │        │            │
 │    u16 LE length    CRC-8    body    CRC-32 over body
 │
 sync byte
```

What's *not* consistently documented is the CRC parameters. Some writeups suggest a custom XOR or non-standard polynomial. After confirming against captured packets, both CRCs are standard:

### CRC-8
- **Polynomial:** `0x07`
- **Init:** `0x00`
- **Reflect in / out:** no
- **Final XOR:** `0x00`
- **Input bytes:** the two length bytes only (NOT the sync byte, NOT the payload)

Verification: frame `AA 08 00 A8 ...` — length is `0x0008`, CRC-8 byte is `0xA8`.
Computing CRC-8/CCITT over `[0x08, 0x00]` with poly `0x07` and init `0x00` gives `0xA8`. ✓

### CRC-32
- **Polynomial:** `0xEDB88320` (reflected `0x04C11DB7`)
- **Init:** `0xFFFFFFFF`
- **Reflect in / out:** yes
- **Final XOR:** `0xFFFFFFFF`
- **Encoding:** little-endian in the frame
- **Input bytes:** the payload only (not the length, not the CRC-8)

This is **plain zlib CRC-32** (same as Ethernet, PNG, gzip). If a prior writeup says it's a custom XOR scheme, that's wrong — we verified against multiple captured packets using Python's `zlib.crc32` and it matches byte-for-byte.

Swift implementation is in [`WhoopProtocol.swift`](./Whoopless/WhoopProtocol.swift).

---

## 2. Command opcodes (observed on 4.0)

| Opcode | Hex | Name | Notes |
| ---: | --- | --- | --- |
| 3 | 0x03 | `TOGGLE_REALTIME_HR` | payload: 1 byte (0x01 on / 0x00 off). Starts/stops 1 Hz HR notifications on the standard HR service. |
| 10 | 0x0A | `SET_CLOCK` | payload: 4 bytes, Unix timestamp LE. **Send on every connect** — see § 3. |
| 22 | 0x16 | `SEND_HISTORICAL_DATA` | payload: 1 byte (0x01). Triggers a burst of 0x2F packets catching up from the last sync. |
| 75 | 0x4B | `healthMonitorTrigger` | payload: 1 byte. Triggers a "health snapshot" — a single packet with SpO2 + skin temp. Useful for on-demand readings. |
| 79 | 0x4F | `RUN_HAPTICS_PATTERN` | payload: pattern bytes. We use this for the silent alarm. Pattern format not fully decoded; a single byte `0x02` produces a ~500 ms buzz. |
| 81 | 0x51 | `START_RAW_DATA` | payload: 1 byte. Starts raw PPG + IMU stream via 0x2B packets (~12 Hz, heavy). |
| 82 | 0x52 | `STOP_RAW_DATA` | payload: 1 byte. Stops the above. |
| 106 | 0x6A | `TOGGLE_IMU_MODE` | payload: 1 byte on/off. |
| 107 | 0x6B | `ENABLE_OPTICAL_DATA` | payload: 1 byte. Enables a denser PPG sampling in raw data. |

Command packet type is `0x23`; responses come back as `0x24`.

---

## 3. Clock drift (biggest gotcha we hit) — and the 8-byte SET_CLOCK fix

**The strap's internal RTC drifts by hours, sometimes days, if you don't actively sync it.** This bit us hard — HRV samples were landing in Apple Health dated for *yesterday* or *tomorrow* because we trusted the packet's `unix_ts` field.

### The critical SET_CLOCK payload-size bug

**`SET_CLOCK` payload is 8 bytes, not 4.** Layout: `[seconds u32 LE][subseconds u32 LE]`. Subseconds are in 1/32768 s units; zero is fine.

This is the single most important protocol-level discovery we missed. We were sending 4 bytes (just the seconds). Per the [NoopApp/noop](https://github.com/NoopApp/noop) reverse-engineering project: *"A wrong-length `SET_CLOCK` is ack'd but not latched, leaving the RTC 'lost' so the strap won't serve type-47."*

This single bug explains *two* persistent problems we had:
1. Multi-hour clock drift between connect cycles (the clock was never actually being set)
2. Stale historical buffers (the strap reserves type-47 service for clients with a valid RTC sync; without a valid SET_CLOCK we got cached fallback data)

If you read only one section of this document before building a WHOOP client, this is it. Get the payload size right and a lot of mysterious problems disappear.

### What we recommend

1. Send `SET_CLOCK` (opcode 10) with the **8-byte payload** a few seconds after every `didConnect`.
2. Also send it before every `SEND_HISTORICAL_DATA` (every minute during sync) — cheap (12 bytes of BLE) and keeps the RTC fresh against drift.
3. As defense in depth, when decoding 0x2F packets, if the packet timestamp differs from phone time by more than ~10 minutes, treat the clock as drifted and fall back to the phone's current time for HealthKit writes.

See `BLEManager.setStrapClock()` and the `clockFresh` check in `ContentView.wireUp()`.

---

## 4. HISTORICAL_DATA (0x2F) layout additions

OpenWhoop's `whoop_data.rs` documents the v12/24 layout well. A few fields we verified or extended:

### Confirmed

| Byte(s) | Field | Notes |
| --- | --- | --- |
| 21 | HR (bpm) | u8. Confirmed against live HR service. Earlier notes called this SpO2 — **it's HR.** |
| 22 | RR count | u8. Number of valid RR intervals in this packet (usually 0-4). |
| 23-30 | RR intervals | up to 4× u16 LE, milliseconds. **See § 5 — these are noisy.** |
| 40-51 | Accelerometer | 3× float32 LE (x, y, z in g). Verified: `|a|` ≈ 1.007 ± 0.005 g when stationary. |
| 55 | Skin contact | u8. 0 = off-wrist, >0 = on-wrist (values 1-3 seen; grade unknown). |

### Extended / empirically calibrated

| Byte(s) | Field | Notes |
| --- | --- | --- |
| 68-69 | SpO2 red channel (raw) | u16 LE. Goes into ratio-of-ratios. |
| 70-71 | SpO2 IR channel (raw) | u16 LE. Goes into ratio-of-ratios. |
| **72-73** | **Skin thermistor (raw)** | **u16 LE. NO documented scale/offset.** Needs two-point linear calibration — see § 6. |
| 74-75 | Ambient light | u16 LE. Useful for rejecting motion-artifact PPG samples. |
| 76 | LED drive 1 | u8. |
| 77 | LED drive 2 | u8. |
| 78-79 | Respiratory rate (raw) | u16 LE. Already-computed value in strap's own units — we don't use it, prefer RSA extraction. |
| 80 | Signal quality index | u8. Higher = better PPG signal. Useful for gating HRV writes. |

---

## 5. RR intervals from 0x2F — filtering is MANDATORY

The RR intervals in 0x2F packets are *mostly* correct beat-to-beat times, but they occasionally contain:

- Multi-beat averages (e.g. a 500 ms and a 1357 ms interval in the same packet — physiologically impossible between consecutive beats at any realistic HR)
- Single-bad-reading artifacts that skew SDNN
- Values outside 400-1500 ms

If you naively accept all of them and compute SDNN, you get 300+ ms HRV at rest. That's what tipped us off.

### What works (Malik rule)

Keep a rolling buffer of the last 20 accepted RRs. For each incoming RR:

1. **Physiological gate:** reject if < 400 ms or > 1500 ms.
2. **Malik gate:** compute the median of the recent buffer. Reject if the new RR is outside ±25% of that median.
3. **Reset safety:** if you reject many in a row (say, 8), treat it as a genuine HR shift (standing up, getting anxious) and reset the filter.

Then compute SDNN over a 60-RR window. At rest, this produces values in the 20-120 ms range, matching Apple Watch HRV within correlation > 0.6 in our spot checks.

```swift
// Simplified
let recent = histRRBuffer.suffix(20).map { $0.rr }.sorted()
let median = recent[recent.count / 2]
for rr in packet.rrIntervalsMs {
    guard rr >= 400, rr <= 1500 else { continue }
    let ratio = rr / median
    if ratio < 0.75 || ratio > 1.25 { continue }
    histRRBuffer.append(rr)
}
```

### What does NOT work

- **Standard BLE heart-rate broadcast RR values (service 0x180D characteristic 0x2A37) are NOT HRV-grade on WHOOP 4.0.** We tried every filter we could think of (range, Malik, MAD-based, previous-RR deltas, per-interval successive-differences) and the resulting SDNN was consistently implausible (300+ ms at true rest). The values appear to be pre-processed / averaged by the strap in some way we couldn't reverse. **Use 0x2F historical packets for HRV, not the live broadcast.**

### Empirical validation against Apple Watch

After implementing the Malik rule (no other filter), we validated against ~6 years of Apple Watch HRV data exported from HealthKit:

- **Nightly median SDNN, Apple Watch:** 64.9 ms
- **Nightly median SDNN, Whoopless (same window, same wrist, n=55 samples):** 64.6 ms
- **Δ = −0.5 %**

When measured in *equivalent contexts* (passive overnight, no paced breathing), Whoopless's SDNN matches Apple Watch's to well under 1 %. Earlier apparent discrepancies of ~17 % vanished once we stopped comparing Apple Watch *Breathe-session* readings (which capture peak HRV during paced 6-breaths/min) against Whoopless *passive sitting* readings — those measure different physiological states.

### Cautionary note on extra filtering

We tried layering a "successive difference" filter on top of Malik (reject pairs where `|Δr| > max(50, 2.5 × MAD of recent diffs)`). The hypothesis was that the rMSSD/SDNN ratio approaching √2 indicated white-noise contamination in WHOOP's RR data.

**This was wrong, and broke HRV badly for the user it was deployed against.** That user has high vagal tone with true rMSSD ~94 ms, so typical beat-to-beat differences are 90+ ms — exactly the differences the filter rejected. SDNN collapsed to ~29 ms across the day until the filter was removed. The rMSSD/SDNN ratio approaching √2 isn't necessarily noise; for parasympathetic-dominant individuals it's physiologically real.

**Lesson:** trust the Malik rule. Don't add successive-difference rejection without per-user validation against a reference HRV source.

**Per-user calibration is available but should not be applied by default.** [`HRVCalibration.swift`](./Whoopless/HRVCalibration.swift) implements a linear-regression fit against any non-Whoopless HRV source in HealthKit (Apple Watch, Polar, Elite HRV, etc.) and persists the slope/intercept to UserDefaults. Apply only if a user's baseline does drift after several weeks of usage.

---

## 6. Skin temperature — two-point linear calibration

The thermistor raw value at bytes 72-73 of 0x2F has no published scale or offset. It appears to be a linear function of temperature (typical for NTC thermistors in a narrow range), but the slope depends on the strap's ADC reference and the specific thermistor part — i.e. probably varies between units.

### Calibration protocol we use

1. **Cool point:** Take the strap off. Let it sit at ambient room temperature for 5 minutes. Capture the raw value and type in your current room temp (e.g. 22.0 °C).
2. **Warm point:** Put the strap back on your wrist. Wait 10 minutes for skin temp to equilibrate. Capture the raw value and type in a typical skin temp (32.0 °C works well).
3. Fit a line:
   - `slope = (tempWarm − tempCool) / (rawWarm − rawCool)`
   - `offset = tempCool − slope × rawCool`
4. For any future raw value: `celsius = slope × raw + offset`. Reject anything outside 20-42 °C as junk.

Implementation in [`SkinTempCalibration.swift`](./Whoopless/SkinTempCalibration.swift) — ~90 lines, persists to UserDefaults.

---

## 7. REALTIME_RAW_DATA (0x2B) — what we know, what we don't

Starting 0x2B streaming (opcode 81) produces ~12 Hz packets of ~1400 bytes each containing raw PPG + IMU samples. Decoding this fully would enable clinical-grade HRV via PPG peak detection. We made partial progress:

### What we resolved

- **Bytes 520-1290: accelerometer stream.** Confirmed by variance analysis — during jumping jacks the variance in this region spiked 13.5× vs. baseline, while other regions stayed flat. Sample rate appears to be ~256 Hz (matches WHOOP's published accelerometer spec).

### What we didn't resolve

- **PPG channel layout.** Autocorrelation of bytes 46-494 shows periodicity consistent with heartbeat (peaks every 60-90 samples at typical HR), suggesting this region contains the PPG channels. But we couldn't definitively map which bytes are red vs. IR vs. green, or determine the exact sample rate and bit width. Multiple plausible demultiplexings exist and ground truth is hard without a synced reference PPG.
- **Byte 63 is NOT HR.** Initially suspicious (means correlated with live HR), but per-packet values don't match live HR — only the *rolling mean* correlates, which can happen by coincidence with any moderately noisy byte.

### Negative finding: HR is not directly encoded in 0x2B

We built a diagnostic tool (see `BLEManager.hrMatchCommonBytes`) that:

1. Waits for a stable HR reading (via the BLE HR service).
2. Snapshots the 0x2B packet.
3. Records which byte positions match the live HR value (tried: u8, u16 LE, u16 BE, `2×HR`, `HR-40`, `HR/2`).
4. After multiple stable-HR snapshots at different HR values (sitting, post-exercise, cooling down), intersects the sets of matching positions.

After 6 varied-HR snapshots the intersection was **empty**. HR is not directly stored in 0x2B at any of those encodings. It must be computed downstream from PPG peaks — consistent with WHOOP's architecture (the strap does raw acquisition; the HR algorithm lives in software).

This is a useful negative result: future reverse-engineers can skip the "find HR in raw" phase and go straight to PPG peak detection.

---

## 8. SpO2 — the strap can compute it correctly; we just need the right command

Our current SpO2 calculator (`SpO2Calculator.swift`, ported from OpenWhoop) uses ratio-of-ratios on the red/IR raw values from bytes 68-71 of HISTORICAL_DATA, plus the classic Nellcor approximation `SpO2 = 110 − 25·R`. The 110 / 25 constants were calibrated for Nellcor's specific LED wavelengths and clinical-grade signal conditioning — they're systematically wrong for WHOOP's optical sensor. Empirically Whoopless reads ~85-86 % when the user's true SpO2 is ~98 %. **Whoopless SpO2 writes to Apple Health are now disabled by default** (see `whoopless.writeSpO2ToHealth` AppStorage flag) and the HealthKit write guard floors at 92 %.

But there's a much better path forward. Inspecting the user's HealthKit export reveals a *third* SpO2 source — a generic "WHOOP" source distinct from both Apple Watch and Whoopless:

```
Source                  n     mean    median   p5     p95
Apple Watch          7163    97.6     98.0    95.0   100.0
WHOOP                 706    97.6     97.7    96.0    99.0    ← matches Apple
Whoopless            1532    86.5     85.9    82.1   100.0    ← uncalibrated formula
```

The "WHOOP" source samples cluster almost entirely between 05:00 and 09:00 (peak at 06:00) — that's when the official WHOOP app does its morning sync. **Those values match Apple Watch's nocturnal SpO2 to within decimals.**

What this tells us: the strap *internally* computes correct SpO2 using its own (presumably proprietary, factory-calibrated) algorithm. The official app reads it via some BLE command response and writes to Health. We don't need to reproduce that algorithm from raw PPG — we just need to decode the right command response.

### Confirmation from NoopApp/noop's protocol schema

Independently verified by the NoopApp/noop project's [`whoop_protocol.json`](https://github.com/NoopApp/noop/blob/main/Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json). HISTORICAL_DATA V24 bytes 68-69 (`spo2_red`), 70-71 (`spo2_ir`), 72-73 (`skin_temp_raw`), and 80-81 (`resp_rate_raw`) are explicitly annotated:

> *"Raw ADCs (SpO2/temp/resp) are NOT converted client-side; WHOOP computes them in cloud."*

NOOP confirms what we discovered the hard way: these bytes carry raw analog-to-digital converter values, and the conversion to physiological units (% SpO2, °C, breaths/min) is proprietary to WHOOP's server. NOOP itself doesn't attempt to convert SpO2 either — they store the raw values and don't display percentages.

**This makes the 0x4B health-snapshot path the *only* viable route to a SpO2 value Whoopless can write to HealthKit.** Don't waste time on more historical-packet byte-hunting for SpO2; it's not crackable without WHOOP's algorithm. For skin temperature, the two-point user calibration we ship in [`SkinTempCalibration.swift`](./Whoopless/SkinTempCalibration.swift) is the right architectural answer — every WHOOP RE project ends up doing this.

**The candidate command is `healthMonitorTrigger` (opcode 75 / 0x4B).** Whoopless already has a "Health snapshot" button in dev mode that fires this command. The strap then cycles red + IR LEDs for ~15 seconds and emits a large `EVENT` (0x30) packet on characteristic `61080004`. We have not yet decoded the layout of that packet. **First reverse-engineer to crack the 0x30 health-snapshot response will solve SpO2 (and very likely paired skin-temp) for every WHOOP 4.0 user.**

Suggested approach for whoever tackles this:

1. Trigger a health snapshot while the user is at rest with a separate reference pulse oximeter (or while wearing an Apple Watch, taking a manual SpO2 reading at the same moment).
2. Capture the entire 0x30 packet in `HistoricalLogger.shared` or a dedicated logger.
3. Note the reference SpO2 value alongside the packet bytes.
4. Repeat at different SpO2 levels — easiest with brief breath-holds (one captures normal ~98%, another after 30 s breath-hold ~94%).
5. Find the byte (likely u8 in the 92-100 range, possibly a u16 LE in 9200-10000 range) that tracks the reference values.

Until that's done, Whoopless's SpO2 path stays disabled.

---

## 9. Sleep staging — HR + HRV alone are insufficient (for at least some users)

We thought we could approximate Apple Watch's 4-stage staging (Awake / Core / REM / Deep) using HR and HRV thresholds. Apple Watch export data shows this doesn't work for at least some physiologies. For the user who validated this code, paired with Apple Watch stage labels:

| Stage | HR median | HR 10-90% | SDNN median |
|---|---|---|---|
| Asleep Core | 41 bpm | 38-46 | 79 ms |
| Asleep REM | 43 bpm | 39-49 | 68 ms |
| Asleep Deep | 42 bpm | 38-47 | 68 ms |
| Awake (in bed) | 42 bpm | 39-48 | 83 ms |

HR varies by only ~2 bpm across the four stages. SDNN does vary, but in a non-textbook pattern (Core highest, Deep and REM tied, Awake highest of all). For an athletic user with very stable autonomic tone, **HR + HRV thresholds cannot reliably classify Deep vs Core vs REM.** They can probably distinguish broadly Asleep vs Awake, which is what Whoopless currently does.

What's actually needed for finer-grained staging:

- **Accelerometer variance per bin** — REM has unique micro-movement signatures despite atonia; Deep is exceptionally still; Awake-in-bed has gross motion. WHOOP's accel data is available in `HistoricalSample.accX/Y/Z`.
- **Respiratory rate stability** — slows and regularizes in Deep, irregular in REM. We already extract this via RSA; would need per-bin tracking.
- **Time-since-sleep-onset prior** — first Deep block is typically 20-90 min after sleep onset; REM cycles ~90 min apart.
- **Per-user training data** — even with all the above, robust staging probably requires fitting a small classifier against the user's Apple Watch stage labels. Population thresholds will be too loose for athletic / outlier users.

**Whoopless currently writes binary Awake / Asleep classifications.** This is honest — it reflects what we can measure reliably. Anyone who wants to add 4-stage classification should do so per-user with paired Apple Watch labels, not with hardcoded thresholds.

---

## 10. HealthKit write schema — what Whoopless emits, and how to read it

Consumers (recovery apps, sleep scorers, dashboards) reading Whoopless's HealthKit writes should know what's there and filter by metadata to get the right semantics. Whoopless does **not** modify its writes per consumer — every consumer predicates on its side.

### Sleep (`HKCategoryTypeIdentifierSleepAnalysis`)

Per session, on `confirmAndWrite()`:

- **One `HKCategoryValueSleepAnalysisInBed`** sample spanning `sessionStart … sessionEnd`. Use this for Sleep Onset Latency calculations.
- **N `HKCategoryValueSleepAnalysisAsleepUnspecified`** samples, one per 2-minute bin (configurable in `SleepTracker.computeBins`) where mean HR was below the per-night wake threshold. We do **not** emit `.asleepCore`, `.asleepDeep`, or `.asleepREM` — staging beyond binary requires features Whoopless doesn't yet classify (see § 9).
- **M `HKCategoryValueSleepAnalysisAwake`** samples for bins where mean HR exceeded the wake threshold.

Bin granularity is 2 min by default. SOL Path A (inBed → first asleep delta) resolves to ±2 min.

### Heart rate (`HKQuantityTypeIdentifierHeartRate`)

Two-tier throttle:
- **HR < 100 bpm:** one write per 10 s (resting/normal mode).
- **HR ≥ 100 bpm:** one write per 1 s (workout mode). Auto-switches based on each sample's value.

Historical-packet-derived HR samples (from `0x2F` buffered data) are written **only when the live BLE broadcast has been silent for >30 s**, to avoid the strap's buffered HR algorithm losing lock during motion and writing stuck-at-resting values. This keeps overnight HR backfill working when BLE drops, but excludes workout-time motion artifacts from the live stream.

### HRV (`HKQuantityTypeIdentifierHeartRateVariabilitySDNN`)

Three flavors, distinguished by metadata key `com.whoopless.kind`:

| `kind` value | Cadence | Semantics |
|---|---|---|
| `"resting"` | Every 60 s when motion + HR-stability + skin-contact gates all pass | Apple-Watch-comparable resting HRV. Use this for recovery scoring. |
| `"continuous"` | Every 60 s when gates fail | Activity-aware HRV. Higher SDNN during motion is physiologically real — use for stress/load tracking, NOT for resting-HRV trends. |
| `"nightly"` | Once per session at the midpoint timestamp, when `confirmAndWrite()` runs | Whole-night HRV summary. Single value per night — the canonical "recovery" number. |

Each sample also carries metadata key `com.whoopless.rMSSD_ms` (paired rMSSD value), and if a per-user calibration is applied, `com.whoopless.rawSDNN_ms` (pre-calibration value).

**Recommended consumer pattern:**

- *Recovery scoring* (single nightly number): query for `kind == "nightly"` only.
- *Daily resting HRV trend* (Apple-Watch-comparable): query for `kind == "resting"` OR `kind == nil` (the `nil` branch covers Apple Watch and other sources without our metadata).
- *Sleep-window HRV analysis* (e.g. HRV Descent Quality, Deep Sleep Estimator that read overnight HRV): predicate `kind != "continuous"` to exclude motion-inflated samples while keeping resting + nightly.
- *Stress / load tracking*: query all kinds, including `"continuous"`.

The `rMSSD_ms` metadata is more useful than SDNN for parasympathetic-tone work and matches what WHOOP / Polar / most HRV research uses. HealthKit has no native rMSSD type, so it's attached as metadata.

### Respiratory rate (`HKQuantityTypeIdentifierRespiratoryRate`)

Computed via RSA (Respiratory Sinus Arrhythmia) on the rolling RR-interval buffer from the live HR stream. Throttled to one write per 30 s. Most reliable at rest — during motion the algorithm produces noisier values, but the throttle prevents Whoopless from spamming Health with junk.

### Body temperature (`HKQuantityTypeIdentifierBodyTemperature`)

Only written when the user has set up two-point thermistor calibration (see § 6) and the strap is on-wrist. We write absolute °C, not a deviation-from-baseline like Apple's `appleSleepingWristTemperature` (which is Apple-Watch-only and not addressable from third-party code).

### SpO2 (`HKQuantityTypeIdentifierOxygenSaturation`)

**Disabled by default.** Our current ratio-of-ratios algorithm is uncalibrated against WHOOP's specific sensor and produces values ~12% too low. Even when enabled via the `whoopless.writeSpO2ToHealth` UserDefault, a 92% floor in the write guard prevents clinically alarming wrong values. See § 8 for the path to fix this properly (decode the 0x4B response packet).

### Source identification

All Whoopless writes come from `HKSource.default()` for the Whoopless app. Consumers reading from multiple sources can identify Whoopless's writes via `sample.sourceRevision.source.bundleIdentifier.contains("Whoopless")`.

---

## 11. HealthKit integration gotchas (iOS-specific)

Not protocol-level, but might save someone a day:

1. **SpO2 uses `HKUnit.percent()` with a 0-1 fraction**, not `HKUnit.count()` with 0-100. Writing 97 (for 97%) will reject; write 0.97.
2. **HR sample throttling** — HealthKit dedupes aggressively but still accepts spammy writes. Throttle HR writes to one per 10 seconds in the live path; historical (past-timestamped) writes don't need throttling.
3. **Reading back your own writes** — when comparing WHOOP HRV to Apple Watch HRV, you have to exclude samples from your own bundle. Use `HKSource.default()` in your delete predicate and check `sample.sourceRevision.source.bundleIdentifier` when reading.
4. **Background BLE requires `bluetooth-central` in Info.plist UIBackgroundModes**, plus `CBCentralManagerOptionRestoreIdentifierKey` when initializing the central. Without it, iOS will silently drop the connection when the app is backgrounded.
5. **Sleep samples** — HealthKit expects one `HKCategorySample` per stage (awake / core / REM / deep), but you can also write a single `.asleepUnspecified` for the whole duration if you don't have staging.

---

## 12. Open questions

Things we'd love to know, ranked by impact:

- **Layout of the 0x30 EVENT packet emitted in response to `healthMonitorTrigger` (0x4B).** Solving this unlocks correct SpO2 and likely paired skin temperature. See § 8.
- **Exact PPG channel layout in 0x2B.** Solving this unlocks clinical-grade HRV via PPG peak detection. See § 7.
- **Haptics pattern byte format** — single byte 0x02 works, but what's the full format for multi-pulse / variable-intensity patterns?
- **Any authentication handshake that unlocks additional commands?** OpenWhoop notes the official app does some handshake on first pair; we haven't needed it but it may gate commands we haven't discovered (sleep staging, recovery score, etc.).
- Skin thermistor part number (would let us replace two-point calibration with a Steinhart-Hart equation if we knew the β value).

PRs or issues with any of these very welcome.

---

## Contact

File issues at the [Whoopless repo](https://github.com/<you>/Whoopless) — we'll roll any new findings back into this doc.
