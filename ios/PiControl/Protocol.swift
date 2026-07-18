import CoreBluetooth
import Foundation

/// PiControl BLE input packet protocol.
///
/// Mirrors the Python decoder in pi5/src/picontrol/protocol.py; the packet
/// layout is documented in the repo's top-level README.md.
enum PiControlProtocol {
    static let version: UInt8 = 1

    static let serviceUUID = CBUUID(string: "b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0001")
    static let inputCharacteristicUUID = CBUUID(string: "b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0002")

    static let packetSize = 11

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

    /// Encode one input packet (little-endian, `<BBHBbbbbBB`).
    static func encode(buttons: Buttons, hat: Hat,
                       lx: Int8, ly: Int8, rx: Int8, ry: Int8,
                       l2: UInt8, r2: UInt8, seq: UInt8) -> Data {
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
        return data
    }
}
