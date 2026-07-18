import Foundation

/// Current state of the on-screen controller, updated by the UI and read by
/// the BLE manager's send loop.
@MainActor
final class ControllerState: ObservableObject {
    @Published var buttons: PiControlProtocol.Buttons = []
    @Published var dpadX: Int = 0  // -1 left, 1 right
    @Published var dpadY: Int = 0  // -1 up, 1 down
    @Published var leftStick: CGPoint = .zero   // components in -1...1
    @Published var rightStick: CGPoint = .zero

    func press(_ button: PiControlProtocol.Buttons, _ pressed: Bool) {
        if pressed {
            buttons.insert(button)
        } else {
            buttons.remove(button)
        }
    }

    private static func axis(_ value: CGFloat) -> Int8 {
        Int8(max(-127, min(127, (value * 127).rounded())))
    }

    /// L2/R2 are digital on screen but analog in the protocol.
    private func trigger(_ button: PiControlProtocol.Buttons) -> UInt8 {
        buttons.contains(button) ? 255 : 0
    }

    func encodePacket(seq: UInt8) -> Data {
        PiControlProtocol.encode(
            buttons: buttons.intersection(.allTransmitted),
            hat: PiControlProtocol.Hat(x: dpadX, y: dpadY),
            lx: Self.axis(leftStick.x),
            ly: Self.axis(leftStick.y),
            rx: Self.axis(rightStick.x),
            ry: Self.axis(rightStick.y),
            l2: trigger(.l2Trigger),
            r2: trigger(.r2Trigger),
            seq: seq
        )
    }
}

extension PiControlProtocol.Buttons {
    /// On-screen L2/R2 controls map to the analog trigger bytes, not button
    /// bits; these local-only values track their pressed state and are masked
    /// out of the transmitted bitmask.
    static let l2Trigger = PiControlProtocol.Buttons(rawValue: 1 << 14)
    static let r2Trigger = PiControlProtocol.Buttons(rawValue: 1 << 15)

    /// Bits 0-11 are defined by the protocol and sent over the wire.
    static let allTransmitted = PiControlProtocol.Buttons(rawValue: 0x0FFF)
}
