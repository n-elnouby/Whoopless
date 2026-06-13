# Whoopless

A free, open-source iOS app that bridges WHOOP 4.0 strap data into Apple Health — no WHOOP subscription required.

Whoopless speaks the WHOOP BLE protocol directly, decodes the strap's `HISTORICAL_DATA` packets, and writes heart rate, heart-rate variability, respiratory rate, SpO2, skin temperature, and sleep samples to HealthKit. If you already have a WHOOP 4.0 strap and you'd rather not pay $250/year for the official app, this exists so you can keep using the hardware.

> **Status:** TestFlight-only. This is an independent community project with no affiliation with WHOOP Inc. Use at your own risk.

---

## What you get in Apple Health

| Metric | Source |
| --- | --- |
| Heart rate (live) | BLE heart-rate service (0x180D) + historical 0x2F packets |
| Heart-rate variability (SDNN) | Beat-to-beat RR intervals from 0x2F, Malik-filtered, 60s rolling SDNN |
| Respiratory rate | RSA extraction (zero-crossing on detrended RR) from live RR stream |
| SpO2 | Red/IR raw samples from 0x2F, ratio-of-ratios (ported from OpenWhoop) |
| Skin/body temperature | Thermistor raw from 0x2F, two-point linear calibration |
| Sleep | HR-based auto-detection (baseline × 0.85 threshold, 10-min debounce) |

Plus: **silent alarm** via WHOOP's haptic buzzer, **auto clock sync** on every connect so samples don't land on the wrong date, and a developer mode with packet inspection tools.

---

## Credits — this project stands on the shoulders of

Whoopless would not exist without the reverse-engineering work of:

- **[jogolden/whoomp](https://github.com/jogolden/whoomp)** — initial BLE packet framing, command opcodes, CRC structure. The foundation.
- **[bWanShiTong/OpenWhoop](https://github.com/bWanShiTong/OpenWhoop)** — HISTORICAL_DATA (0x2F) field layout, SpO2 algorithm, raw-data command structure. The Rust implementation we cross-referenced for byte positions.
- **[bWanShiTong/reverse-engineering-whoop-post](https://github.com/bWanShiTong/reverse-engineering-whoop-post)** — writeup of the WHOOP proprietary service + command response flow.

Please star those projects. The WHOOP RE community is small and these people did the hard part first. Our contribution is iOS + HealthKit integration and some incremental protocol findings — see [`PROTOCOL_NOTES.md`](./PROTOCOL_NOTES.md) for what we learned that isn't already documented upstream.

---

## What's new in Whoopless (beyond upstream)

If you're building a different WHOOP client, these are the bits you might want to pull:

1. **Confirmed CRC parameters** — CRC-8 poly 0x07 init 0 over length bytes *only*; CRC-32 is plain zlib (not custom XOR as some writeups claim). Verified against captured packets. See `WhoopProtocol.swift`.
2. **Clock drift handling** — the strap's internal clock drifts hours-to-days without active sync. Whoopless pushes `SET_CLOCK` (opcode 10) with a 4-byte LE Unix timestamp on every connect, and falls back to phone time if a packet's timestamp is >10 minutes off. See `BLEManager.swift`.
3. **HRV filtering for WHOOP RR values** — WHOOP's 0x2F RR field occasionally contains multi-beat averages or artifacts. A Malik-rule filter (±25% from rolling median) over a 5-minute buffer is needed before SDNN is clinically meaningful. See `ContentView.swift → wireUp()`.
4. **Two-point skin temperature calibration** — the thermistor raw at bytes 72-73 of 0x2F has no documented scale/offset. Whoopless fits a line between a cool point (off-wrist, room temp) and a warm point (on-wrist, ~32°C). See `SkinTempCalibration.swift`.
5. **HealthKit integration patterns** — how to throttle writes, use the right HKUnit for SpO2 (fraction, not percent), filter out your own samples when reading back Apple Watch HRV, and bulk-delete when the strap clock misbehaves. See `HealthKitManager.swift`.
6. **Negative findings** — BLE HR broadcast RR values are NOT HRV-grade; HR is NOT directly encoded in REALTIME_RAW_DATA 0x2B. Documented in `PROTOCOL_NOTES.md` so future reverse-engineers don't waste a week chasing them.

---

## Building

Requirements: Xcode 26+, iOS 17+, paid Apple Developer account (HealthKit needs a team ID).

```bash
git clone https://github.com/n-elnouby/Whoopless.git
cd Whoopless
open Whoopless.xcodeproj
```

1. In *Signing & Capabilities*, set your team.
2. Confirm the **HealthKit** and **Background Modes → Uses Bluetooth LE accessories** capabilities are enabled.
3. Build to your device (the simulator can't do BLE).
4. On first launch, grant Bluetooth and HealthKit permissions.
5. Pair: put the WHOOP 4.0 on the charging pod, tap the top button until it broadcasts ("OUBY WHOOP" appears in the device list), then Connect.

The strap advertises as an *OUBY* heart-rate peripheral when in pairing mode. If you don't see it, the strap may need to be de-paired from the official WHOOP app first.

---

## Architecture

```
┌──────────────────┐
│   WHOOP 4.0      │  BLE (HR service 0x180D + proprietary 61080001-...)
│   strap          │
└────────┬─────────┘
         │ notifications
         ▼
┌──────────────────┐    onHeartRate    ┌──────────────────┐
│   BLEManager     │──────────────────▶│  ContentView     │
│  (CoreBluetooth) │                   │  (SwiftUI wiring)│
│                  │ onHistoricalSample│                  │
│  - framing       │──────────────────▶│  - Malik filter  │
│  - CRC-8/32      │                   │  - SDNN rolling  │
│  - cmd encoding  │                   │  - SpO2 R-of-R   │
└──────────────────┘                   └────────┬─────────┘
                                                │
                                                ▼
                                    ┌──────────────────────┐
                                    │   HealthKitManager   │
                                    │   (HKQuantity writes)│
                                    └──────────────────────┘
```

Key files:

- `WhoopProtocol.swift` — packet types, command opcodes, CRC-8 / CRC-32, frame encode
- `BLEManager.swift` — CoreBluetooth central, scan, connect, notify handling, auto-sync timer
- `HistoricalParser.swift` — decode 0x2F packets into typed `HistoricalSample`
- `HealthKitManager.swift` — HKHealthStore wrapper, write throttling, Watch HRV fetch
- `ContentView.swift` — UI + signal-processing pipeline wiring
- `SpO2Calculator.swift` — ratio-of-ratios AC/DC port of OpenWhoop's `spo2.rs`
- `SkinTempCalibration.swift` — two-point linear calibration, persisted to UserDefaults
- `SleepTracker.swift` — HR-baseline sleep detection + HRV nightly summary
- `AlarmManager.swift` — silent alarm via `RUN_HAPTICS_PATTERN`

---

## License

MIT. See [`LICENSE`](./LICENSE).

---

## Contributing

PRs welcome, especially:

- Decoding the remaining unknown regions of `REALTIME_RAW_DATA` (0x2B) — PPG channel layout is partially resolved, full demux would enable clinical-grade HRV.
- Better sleep staging (REM detection) — currently only detects asleep/awake.
- Additional HealthKit metrics (wrist temp, VO2max estimation from HR-activity correlation).

If you're working on a different WHOOP client (Android, Rust, etc.) and anything in `PROTOCOL_NOTES.md` saves you a day, please drop a "credit" link in your README — that's all the payback we need.

---

## Disclaimer

Not a medical device. The values Whoopless writes to Apple Health are estimates derived from a consumer wearable's sensor stream via reverse-engineered protocol. Do not use these for clinical decisions. If you need medical-grade data, use medical-grade hardware.

WHOOP® is a registered trademark of WHOOP, Inc. This project is not affiliated with, endorsed by, or sponsored by WHOOP, Inc.
