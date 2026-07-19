import CoreBluetooth
import Foundation

/// PiControl BLE input packet protocol.
///
/// Mirrors the Python decoder in pi5/src/picontrol/protocol.py; the packet
/// layout is documented in the repo's top-level README.md.
enum PiControlProtocol {
    static let version: UInt8 = 2

    static let serviceUUID = CBUUID(string: "b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0001")
    static let inputCharacteristicUUID = CBUUID(string: "b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0002")
    static let configCharacteristicUUID = CBUUID(string: "b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0003")

    static let packetSize = 17

    /// Attitude fields are radians scaled to int16: ±π maps to ±32767.
    static let attitudeScale = 32767.0 / Double.pi

    struct Buttons: OptionSet {
        let rawValue: UInt16

        static let cross = Buttons(rawValue: 1 << 0)
        static let circle = Buttons(rawValue: 1 << 1)
        static let square = Buttons(rawValue: 1 << 2)
        static let triangle = Buttons(rawValue: 1 << 3)
        static let l1 = Buttons(rawValue: 1 << 4)
        static let r1 = Buttons(rawValue: 1 << 5)
        static let l3 = Buttons(rawValue: 1 << 6)
        static let r3 = Buttons(rawValue: 1 << 7)
        static let create = Buttons(rawValue: 1 << 8)
        static let options = Buttons(rawValue: 1 << 9)
        static let ps = Buttons(rawValue: 1 << 10)
        static let touchpad = Buttons(rawValue: 1 << 11)
    }

    /// D-pad hat: 0 = centered, then clockwise from north.
    enum Hat: UInt8 {
        case centered = 0
        case n = 1, ne = 2, e = 3, se = 4, s = 5, sw = 6, w = 7, nw = 8

        init(x: Int, y: Int) {
            switch (x, y) {
            case (0, -1): self = .n
            case (1, -1): self = .ne
            case (1, 0): self = .e
            case (1, 1): self = .se
            case (0, 1): self = .s
            case (-1, 1): self = .sw
            case (-1, 0): self = .w
            case (-1, -1): self = .nw
            default: self = .centered
            }
        }
    }

    /// Encode one input packet (little-endian, `<BBHBbbbbBBhhh`).
    /// Attitude is in radians (portrait device frame, fused gyro+accel).
    static func encode(buttons: Buttons, hat: Hat,
                       lx: Int8, ly: Int8, rx: Int8, ry: Int8,
                       l2: UInt8, r2: UInt8, seq: UInt8,
                       pitch: Double, roll: Double, yaw: Double) -> Data {
        var data = Data(capacity: packetSize)
        data.append(version)
        data.append(seq)
        data.append(UInt8(buttons.rawValue & 0xFF))
        data.append(UInt8(buttons.rawValue >> 8))
        data.append(hat.rawValue)
        data.append(UInt8(bitPattern: lx))
        data.append(UInt8(bitPattern: ly))
        data.append(UInt8(bitPattern: rx))
        data.append(UInt8(bitPattern: ry))
        data.append(l2)
        data.append(r2)
        appendAttitude(pitch, to: &data)
        appendAttitude(roll, to: &data)
        appendAttitude(yaw, to: &data)
        return data
    }

    private static func appendAttitude(_ radians: Double, to data: inout Data) {
        let value = Int16(max(-32767, min(32767, (radians * attitudeScale).rounded())))
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    /// What the receiver wants from us, served on the config characteristic
    /// (struct `<BBB`: version, flags, rate_hz). Receivers may update it
    /// mid-connection via notify.
    struct ReceiverConfig: Equatable {
        var wantsMotion = true
        var wantsAnalog = true
        var rateHz = 60

        static let version: UInt8 = 1
        static let wantMotionFlag: UInt8 = 1 << 0
        static let wantAnalogFlag: UInt8 = 1 << 1

        /// Lenient: anything unparseable (missing characteristic, wrong
        /// size, unknown version) yields the defaults, so the phone works
        /// against any receiver.
        static func decode(_ data: Data?) -> ReceiverConfig {
            guard let data, data.count == 3 else { return ReceiverConfig() }
            let bytes = [UInt8](data)
            guard bytes[0] == version else { return ReceiverConfig() }
            return ReceiverConfig(
                wantsMotion: bytes[1] & wantMotionFlag != 0,
                wantsAnalog: bytes[1] & wantAnalogFlag != 0,
                rateHz: max(1, min(120, Int(bytes[2])))
            )
        }
    }
}
