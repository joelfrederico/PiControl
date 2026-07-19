// Fake PiControl receiver for macOS: advertises the PiControl BLE service
// and prints every decoded input packet, so the iOS app can be tested
// without a Pi. Run with:
//
//     swift mac/fake_receiver.swift
//
// Uses CoreBluetooth directly (no Python/bless layer) so it exercises the
// same stack the real receivers do from the phone's point of view.

import CoreBluetooth
import Foundation

let serviceUUID = CBUUID(string: "b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0001")
let inputCharUUID = CBUUID(string: "b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0002")
let localName = "PiControl-mac"
let packetSize = 11
let protocolVersion: UInt8 = 1

let buttonNames: [(UInt16, String)] = [
    (1 << 0, "cross"), (1 << 1, "circle"), (1 << 2, "square"), (1 << 3, "triangle"),
    (1 << 4, "L1"), (1 << 5, "R1"), (1 << 6, "L3"), (1 << 7, "R3"),
    (1 << 8, "create"), (1 << 9, "options"), (1 << 10, "PS"), (1 << 11, "touchpad"),
]

func describe(packet: Data) -> String {
    guard packet.count == packetSize else {
        return "bad packet size \(packet.count) (expected \(packetSize))"
    }
    let bytes = [UInt8](packet)
    guard bytes[0] == protocolVersion else {
        return "bad protocol version \(bytes[0])"
    }
    let seq = bytes[1]
    let buttons = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
    let hat = bytes[4]
    let lx = Int8(bitPattern: bytes[5]), ly = Int8(bitPattern: bytes[6])
    let rx = Int8(bitPattern: bytes[7]), ry = Int8(bitPattern: bytes[8])
    let l2 = bytes[9], r2 = bytes[10]
    let pressed = buttonNames.filter { buttons & $0.0 != 0 }.map(\.1).joined(separator: "+")
    return String(format: "seq=%3d L=(%4d,%4d) R=(%4d,%4d) L2=%3d R2=%3d hat=%d %@",
                  seq, lx, ly, rx, ry, l2, r2, hat, pressed)
}

final class FakeReceiver: NSObject, CBPeripheralManagerDelegate {
    private var manager: CBPeripheralManager!
    private var packetCount = 0

    func start() {
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            print("Bluetooth powered on; adding service...")
            let characteristic = CBMutableCharacteristic(
                type: inputCharUUID,
                properties: [.write, .writeWithoutResponse],
                value: nil,
                permissions: [.writeable]
            )
            let service = CBMutableService(type: serviceUUID, primary: true)
            service.characteristics = [characteristic]
            peripheral.add(service)
        case .unauthorized:
            print("ERROR: Bluetooth permission denied for this process")
            exit(1)
        case .poweredOff:
            print("ERROR: Bluetooth is off")
            exit(1)
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didAdd service: CBService, error: Error?) {
        if let error {
            print("ERROR adding service: \(error)")
            exit(1)
        }
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: localName,
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager,
                                              error: Error?) {
        if let error {
            print("ERROR starting advertising: \(error)")
            exit(1)
        }
        print("Advertising as \"\(localName)\"; connect from the PiControl iOS app...")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        print("central subscribed: \(central.identifier)")
    }

    private var lastButtons: UInt16 = 0
    private var lastHat: UInt8 = 0
    private var windowStart = Date()
    private var windowCount = 0

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            packetCount += 1
            if let value = request.value, value.count == packetSize {
                let bytes = [UInt8](value)
                let buttons = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
                let hat = bytes[4]
                // Print a timestamped line on every button/d-pad edge, and a
                // packet-rate line once a second, instead of 60 Hz spam.
                if buttons != lastButtons || hat != lastHat {
                    let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
                    print("[\(stamp)] \(describe(packet: value))")
                    lastButtons = buttons
                    lastHat = hat
                }
                windowCount += 1
                let elapsed = Date().timeIntervalSince(windowStart)
                if elapsed >= 1.0 {
                    print(String(format: "rate: %.0f pkt/s", Double(windowCount) / elapsed))
                    windowStart = Date()
                    windowCount = 0
                }
            }
            if request.characteristic.properties.contains(.write) {
                peripheral.respond(to: request, withResult: .success)
            }
        }
    }
}

setbuf(stdout, nil)
let receiver = FakeReceiver()
receiver.start()
RunLoop.main.run()
