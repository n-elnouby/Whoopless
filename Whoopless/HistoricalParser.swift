//
//  HistoricalParser.swift
//  Whoopless
//
//  Decoder for HISTORICAL_DATA (type 0x2F) packets. Field layout confirmed
//  against OpenWhoop's Rust implementation (bWanShiTong/OpenWhoop) which
//  matches our captured data exactly.
//
//  Our packet frame (96 bytes total) breaks down as:
//   [0]       0xAA sync
//   [1-2]     length LE (= payload + CRC-32)
//   [3]       CRC-8 of length
//   [4]       packet type (0x2F)
//   [5-6]     subtype
//   [7-10]    version/flags
//   [11-14]   Unix timestamp LE
//   [21]      HR in bpm
//   [22]      RR count (0–4)
//   [23-30]   up to 4 × u16 LE RR intervals in milliseconds
//   [33-36]   PPG green + PPG red-IR (u16 LE each)
//   [40-51]   Accelerometer gravity X, Y, Z (float32 LE each, in g)
//   [55]      Skin contact signal (u8, 0=no contact, high=strong)
//   [68-83]   Sensor block: 8 × u16 LE =
//               SpO2 red, SpO2 IR, skin temp raw, ambient light,
//               LED drive 1, LED drive 2, respiratory rate raw, signal quality
//   [last 4]  CRC-32 LE
//

import Foundation

struct HistoricalSample: Equatable {
    let unixTs: UInt32
    let seq: UInt8
    let hrBpm: UInt8          // byte 21
    let rrIntervalsMs: [UInt16]  // up to 4, from bytes 23-30
    let accX: Float           // 40-43
    let accY: Float           // 44-47
    let accZ: Float           // 48-51
    let skinContact: UInt8    // 55
    let spo2RedRaw: UInt16    // 68-69
    let spo2IRRaw: UInt16     // 70-71
    let skinTempRaw: UInt16   // 72-73
    let ambientLight: UInt16  // 74-75
    let ledDrive1: UInt16     // 76-77
    let ledDrive2: UInt16     // 78-79
    let respRateRaw: UInt16   // 80-81
    let signalQuality: UInt16 // 82-83
    let raw: [UInt8]

    var accMag: Float { (accX*accX + accY*accY + accZ*accZ).squareRoot() }

    /// SpO2 % estimate via Ratio-of-Ratios (R / IR).
    ///
    /// **WARNING: this approximation is NOT reliable.** Per the NoopApp/noop
    /// reverse-engineering project's `whoop_protocol.json` schema:
    /// *"Raw ADCs (SpO2/temp/resp) are NOT converted client-side; WHOOP
    /// computes them in cloud."* The 110/25 Nellcor constants are from a
    /// different sensor family; our empirical comparison vs Apple Watch
    /// showed Whoopless's output is ~12 % too low (86 % vs true 98 %).
    ///
    /// **Do not write the value of this property to HealthKit.** Kept only
    /// for diagnostic purposes (raw-byte inspection). Real SpO2 requires
    /// either (a) the 0x4B health-snapshot path where the strap computes
    /// it internally, or (b) sampling raw PPG via 0x2B and implementing the
    /// full AC/DC ratio-of-ratios from the optical waveform.
    var spo2Approx: Double? {
        guard spo2IRRaw > 100, spo2RedRaw > 100 else { return nil }
        let r = Double(spo2RedRaw) / Double(spo2IRRaw)
        let s = 110.0 - 25.0 * r
        return (70...100).contains(s) ? s : nil
    }
}

enum HistoricalParser {

    nonisolated static func parse(_ data: Data) -> HistoricalSample? {
        guard data.count >= 92,
              data[0] == 0xAA,
              data[4] == 0x2F else { return nil }
        let b = [UInt8](data)

        let unixTs = UInt32(b[11]) | (UInt32(b[12]) << 8)
                   | (UInt32(b[13]) << 16) | (UInt32(b[14]) << 24)

        // RR intervals — count at byte 22, then up to 4 u16 LE starting at byte 23.
        let rrCount = min(Int(b[22]), 4)
        var rrs: [UInt16] = []
        for i in 0..<rrCount {
            let lo = Int(b[23 + i*2])
            let hi = Int(b[24 + i*2])
            rrs.append(UInt16(lo | (hi << 8)))
        }

        let x = Float(bitPattern: UInt32(b[40]) | (UInt32(b[41]) << 8)
                                | (UInt32(b[42]) << 16) | (UInt32(b[43]) << 24))
        let y = Float(bitPattern: UInt32(b[44]) | (UInt32(b[45]) << 8)
                                | (UInt32(b[46]) << 16) | (UInt32(b[47]) << 24))
        let z = Float(bitPattern: UInt32(b[48]) | (UInt32(b[49]) << 8)
                                | (UInt32(b[50]) << 16) | (UInt32(b[51]) << 24))

        func u16(_ offset: Int) -> UInt16 {
            UInt16(b[offset]) | (UInt16(b[offset+1]) << 8)
        }

        return HistoricalSample(
            unixTs: unixTs,
            seq: b[7],
            hrBpm: b[21],
            rrIntervalsMs: rrs,
            accX: x, accY: y, accZ: z,
            skinContact: b[55],
            spo2RedRaw: u16(68),
            spo2IRRaw: u16(70),
            skinTempRaw: u16(72),
            ambientLight: u16(74),
            ledDrive1: u16(76),
            ledDrive2: u16(78),
            respRateRaw: u16(80),
            signalQuality: u16(82),
            raw: b
        )
    }
}
