//
//  WhoopProtocol.swift
//  Whoopless
//
//  Encoder/decoder for WHOOP 4.0's proprietary BLE framing.
//  Framing (reverse-engineered by jogolden/whoomp and bWanShiTong, verified
//  against our own captures):
//
//      [0]     0xAA            sync
//      [1-2]   length (LE)     = bytes from [4] to end of CRC-32 inclusive
//      [3]     CRC-8           of bytes [1..2] only (poly 0x07, init 0, no refl)
//      [4]     packet type     (WhoopPacketType)
//      [5..]   payload
//      [last 4] CRC-32 LE      standard CRC-32 (poly 0xEDB88320, init 0xFFFFFFFF,
//                              xor 0xFFFFFFFF, reflected I/O), over [4..before CRC]
//

import Foundation

enum WhoopPacketType: UInt8 {
    case command             = 0x23  // 35 — app → strap
    case commandResponse     = 0x24  // 36 — strap → app
    case realtimeData        = 0x28  // 40 — HR/RR stream
    case realtimeRawData     = 0x2B  // 43 — raw PPG optical
    case historicalData      = 0x2F  // 47 — stored data sync
    case event               = 0x30  // 48 — what we currently receive
    case metadata            = 0x31  // 49
    case consoleLogs         = 0x32  // 50
    case realtimeIMUStream   = 0x33  // 51 — accelerometer (sleep!)
    case historicalIMUStream = 0x34  // 52

    var name: String {
        switch self {
        case .command:             return "COMMAND"
        case .commandResponse:     return "COMMAND_RESPONSE"
        case .realtimeData:        return "REALTIME_DATA"
        case .realtimeRawData:     return "REALTIME_RAW_DATA"
        case .historicalData:      return "HISTORICAL_DATA"
        case .event:               return "EVENT"
        case .metadata:            return "METADATA"
        case .consoleLogs:         return "CONSOLE_LOGS"
        case .realtimeIMUStream:   return "REALTIME_IMU"
        case .historicalIMUStream: return "HISTORICAL_IMU"
        }
    }
}

enum WhoopCommand: UInt8 {
    // All opcodes below are from jogolden/whoomp's published source — verified.
    case toggleRealtimeHR        = 3
    case reportVersionInfo       = 7
    case setClock                = 10
    case getClock                = 11
    case sendHistoricalData      = 22
    case getBatteryLevel         = 26
    case sendR10R11Realtime      = 63
    case setAlarmTime            = 66
    case getAlarmTime            = 67
    case runAlarm                = 68
    case disableAlarm            = 69
    case runHapticsPattern       = 79
    case getAllHapticsPattern    = 80
    case startRawData            = 81
    case stopRawData             = 82
    case healthMonitorTrigger    = 75   // 0x4B — one-shot SpO2 + skin temp snapshot
    case stopHaptics             = 122
    case toggleIMUModeHistorical = 105
    case toggleIMUMode           = 106
    case enableOpticalData       = 107
    case toggleOpticalMode       = 108
    // High-frequency sync mode — a previous app may have parked the strap in
    // it. Sending EXIT defensively on connect releases the strap so plain
    // SEND_HISTORICAL_DATA returns the type-47 store normally. Documented
    // by the NoopApp/noop reverse-engineering project.
    case enterHighFreqSync       = 96
    case exitHighFreqSync        = 97
    // Historical-data chunk ack — write back to the strap's trim cursor
    // after we've durably stored a chunk so it can advance and stop
    // re-sending the same buffer. This is the missing piece that explains
    // why our historical packets keep replaying the same 38 seconds of data.
    case historicalDataResult    = 23
}

enum WhoopProtocol {

    /// CRC-8 with polynomial 0x07, init 0, no reflection.
    /// Computed over the 2 length bytes only. Matches our observed packets:
    /// length `24 00` → CRC-8 = 0xFA, length `08 00` → CRC-8 = 0xA8.
    nonisolated static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for b in bytes {
            crc ^= b
            for _ in 0..<8 {
                if (crc & 0x80) != 0 {
                    crc = (crc &<< 1) ^ 0x07
                } else {
                    crc &<<= 1
                }
            }
        }
        return crc
    }

    /// Standard CRC-32 — polynomial 0xEDB88320 reflected, init 0xFFFFFFFF,
    /// xor-out 0xFFFFFFFF (a.k.a. the polynomial of zlib / Ethernet / PNG).
    nonisolated static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 {
                if (crc & 1) != 0 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    /// Build a command packet ready to write to characteristic 61080002.
    ///
    /// - Parameters:
    ///   - counter: per-session rolling counter; the strap matches responses by this.
    ///   - command: the opcode (WhoopCommand raw value).
    ///   - payload: command-specific bytes (e.g., `[0x01]` to enable, `[0x00]` for haptic
    ///              pattern index 0, or a 4-byte Unix timestamp for SET_ALARM_TIME).
    nonisolated static func encodeCommand(counter: UInt8,
                                          command: UInt8,
                                          payload: [UInt8] = [0x00]) -> Data {
        let body: [UInt8] = [
            WhoopPacketType.command.rawValue,
            counter,
            command
        ] + payload
        let c32 = crc32(body)
        let bodyWithCRC: [UInt8] = body + [
            UInt8( c32        & 0xFF),
            UInt8((c32 >>  8) & 0xFF),
            UInt8((c32 >> 16) & 0xFF),
            UInt8((c32 >> 24) & 0xFF)
        ]
        let len = UInt16(bodyWithCRC.count)
        let lenBytes: [UInt8] = [UInt8(len & 0xFF), UInt8(len >> 8)]
        let headerCRC = crc8(lenBytes)

        return Data([0xAA] + lenBytes + [headerCRC] + bodyWithCRC)
    }

    /// Decode a received packet's framing fields. Returns nil on malformed input.
    nonisolated static func parsePacket(_ data: Data) -> (type: WhoopPacketType, payload: Data)? {
        guard data.count >= 9, data[0] == 0xAA else { return nil }
        let len = Int(data[1]) | (Int(data[2]) << 8)
        guard data.count == len + 4 else { return nil }
        let typeByte = data[4]
        guard let type = WhoopPacketType(rawValue: typeByte) else { return nil }
        // Payload excludes the type byte and the trailing CRC-32.
        let payload = data.subdata(in: 5..<(5 + len - 1 - 4))
        return (type, payload)
    }
}
