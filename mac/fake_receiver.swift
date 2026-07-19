// Fake PiControl receiver for macOS: advertises the PiControl BLE service
// and shows the controller input it receives in a window, so the iOS app
// can be tested without a Pi. Run with:
//
//     swift mac/fake_receiver.swift
//
// Uses CoreBluetooth directly (no Python/bless layer) so it exercises the
// same stack the real receivers do from the phone's point of view. Button
// and d-pad edges are also printed to the console for logging.

import AppKit
import CoreBluetooth
import SwiftUI

let serviceUUID = CBUUID(string: "b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0001")
let inputCharUUID = CBUUID(string: "b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0002")
let localName = "PiControl-mac"
let packetSize = 11
let protocolVersion: UInt8 = 1

// MARK: - Protocol decoding

struct Snapshot: Equatable {
    var buttons: UInt16 = 0
    var hat: UInt8 = 0
    var lx: Int8 = 0, ly: Int8 = 0, rx: Int8 = 0, ry: Int8 = 0
    var l2: UInt8 = 0, r2: UInt8 = 0
    var seq: UInt8 = 0

    static let buttonNames: [(UInt16, String)] = [
        (1 << 0, "cross"), (1 << 1, "circle"), (1 << 2, "square"), (1 << 3, "triangle"),
        (1 << 4, "L1"), (1 << 5, "R1"), (1 << 6, "L3"), (1 << 7, "R3"),
        (1 << 8, "create"), (1 << 9, "options"), (1 << 10, "PS"), (1 << 11, "touchpad"),
    ]

    init?(packet: Data) {
        guard packet.count == packetSize else { return nil }
        let bytes = [UInt8](packet)
        guard bytes[0] == protocolVersion, bytes[4] <= 8 else { return nil }
        seq = bytes[1]
        buttons = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        hat = bytes[4]
        lx = Int8(bitPattern: bytes[5]); ly = Int8(bitPattern: bytes[6])
        rx = Int8(bitPattern: bytes[7]); ry = Int8(bitPattern: bytes[8])
        l2 = bytes[9]; r2 = bytes[10]
    }

    init() {}

    func pressed(_ name: String) -> Bool {
        guard let mask = Self.buttonNames.first(where: { $0.1 == name })?.0 else { return false }
        return buttons & mask != 0
    }

    /// D-pad direction: 0 = centered, then clockwise from north.
    var dpad: (x: Int, y: Int) {
        let table: [(Int, Int)] = [(0, 0), (0, -1), (1, -1), (1, 0), (1, 1),
                                   (0, 1), (-1, 1), (-1, 0), (-1, -1)]
        return hat <= 8 ? table[Int(hat)] : (0, 0)
    }

    var pressedNames: String {
        Self.buttonNames.filter { buttons & $0.0 != 0 }.map(\.1).joined(separator: "+")
    }
}

// MARK: - BLE peripheral

final class ReceiverModel: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    @Published var status = "Starting Bluetooth…"
    @Published var advertising = false
    @Published var snapshot = Snapshot()
    @Published var rate = 0.0
    @Published var stale = true

    private var manager: CBPeripheralManager!
    private var lastEdge = Snapshot()
    private var lastPacket: Date?
    private var windowStart = Date()
    private var windowCount = 0

    func start() {
        manager = CBPeripheralManager(delegate: self, queue: .main)
        // Mark the display stale (grayed out) when packets stop arriving.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let stale = (self.lastPacket.map { Date().timeIntervalSince($0) } ?? .infinity) > 1.0
            if stale != self.stale {
                self.stale = stale
                if stale { self.rate = 0 }
            }
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
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
            status = "Bluetooth permission denied — allow it in System Settings"
        case .poweredOff:
            status = "Bluetooth is off"
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didAdd service: CBService, error: Error?) {
        if let error {
            status = "Failed to add service: \(error.localizedDescription)"
            return
        }
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: localName,
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager,
                                              error: Error?) {
        if let error {
            status = "Failed to advertise: \(error.localizedDescription)"
            return
        }
        advertising = true
        status = "Advertising as \"\(localName)\" — connect from the PiControl iOS app"
        print("Advertising as \"\(localName)\"; connect from the PiControl iOS app...")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if let value = request.value, let snap = Snapshot(packet: value) {
                if snap.buttons != lastEdge.buttons || snap.hat != lastEdge.hat {
                    let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
                    print("[\(stamp)] buttons=[\(snap.pressedNames)] dpad=\(snap.dpad)")
                    lastEdge = snap
                }
                snapshot = snap
                lastPacket = Date()
                status = "Receiving from PiControl app"

                windowCount += 1
                let elapsed = Date().timeIntervalSince(windowStart)
                if elapsed >= 1.0 {
                    rate = Double(windowCount) / elapsed
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

// MARK: - UI widgets

struct PillLabel: View {
    let label: String
    let on: Bool

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(on ? Color.accentColor : Color(nsColor: .quaternaryLabelColor))
            .foregroundStyle(on ? .white : .primary)
            .clipShape(Capsule())
    }
}

struct StickView: View {
    let label: String
    let x: Int8
    let y: Int8
    let clicked: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(clicked ? Color.accentColor : Color.secondary.opacity(0.4),
                            lineWidth: clicked ? 3 : 1.5)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 16, height: 16)
                    .offset(x: CGFloat(x) / 127 * 30, y: CGFloat(y) / 127 * 30)
            }
            .frame(width: 76, height: 76)
            Text("\(label) (\(x), \(y))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

struct TriggerGauge: View {
    let label: String
    let value: UInt8

    var body: some View {
        VStack(spacing: 3) {
            ProgressView(value: Double(value) / 255)
                .frame(width: 72)
            Text("\(label) \(value)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

struct FaceDiamond: View {
    let snapshot: Snapshot

    var body: some View {
        VStack(spacing: 2) {
            face("triangle", .green)
            HStack(spacing: 26) {
                face("square", .pink)
                face("circle", .red)
            }
            face("cross", .blue)
        }
    }

    private func face(_ name: String, _ color: Color) -> some View {
        let symbol = name == "cross" ? "xmark" : name
        return Image(systemName: symbol)
            .font(.callout.weight(.bold))
            .foregroundStyle(snapshot.pressed(name) ? Color.white : color)
            .frame(width: 30, height: 30)
            .background(snapshot.pressed(name) ? color : Color(nsColor: .quaternaryLabelColor))
            .clipShape(Circle())
    }
}

struct DPadCross: View {
    let dpad: (x: Int, y: Int)

    var body: some View {
        VStack(spacing: 2) {
            arrow("arrowtriangle.up.fill", on: dpad.y == -1)
            HStack(spacing: 2) {
                arrow("arrowtriangle.left.fill", on: dpad.x == -1)
                Color.clear.frame(width: 26, height: 26)
                arrow("arrowtriangle.right.fill", on: dpad.x == 1)
            }
            arrow("arrowtriangle.down.fill", on: dpad.y == 1)
        }
    }

    private func arrow(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol)
            .font(.footnote)
            .frame(width: 26, height: 26)
            .background(on ? Color.accentColor : Color(nsColor: .quaternaryLabelColor))
            .foregroundStyle(on ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Main view

struct ReceiverView: View {
    @ObservedObject var model: ReceiverModel

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Circle()
                    .fill(model.stale ? (model.advertising ? Color.orange : Color.red)
                                      : Color.green)
                    .frame(width: 10, height: 10)
                Text(model.status)
                    .font(.callout)
                Spacer()
                if !model.stale {
                    Text(String(format: "%.0f pkt/s · seq %d", model.rate, model.snapshot.seq))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                TriggerGauge(label: "L2", value: model.snapshot.l2)
                PillLabel(label: "L1", on: model.snapshot.pressed("L1"))
                Spacer()
                PillLabel(label: "Create", on: model.snapshot.pressed("create"))
                PillLabel(label: "PS", on: model.snapshot.pressed("PS"))
                PillLabel(label: "Pad", on: model.snapshot.pressed("touchpad"))
                PillLabel(label: "Options", on: model.snapshot.pressed("options"))
                Spacer()
                PillLabel(label: "R1", on: model.snapshot.pressed("R1"))
                TriggerGauge(label: "R2", value: model.snapshot.r2)
            }

            HStack(spacing: 28) {
                DPadCross(dpad: model.snapshot.dpad)
                StickView(label: "L", x: model.snapshot.lx, y: model.snapshot.ly,
                          clicked: model.snapshot.pressed("L3"))
                FaceDiamond(snapshot: model.snapshot)
                StickView(label: "R", x: model.snapshot.rx, y: model.snapshot.ry,
                          clicked: model.snapshot.pressed("R3"))
            }
            .opacity(model.stale ? 0.35 : 1)
        }
        .padding(16)
        .frame(minWidth: 540)
    }
}

// MARK: - App bootstrap (script mode: no bundle, window built by hand)

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        true
    }
}

setbuf(stdout, nil)

let model = ReceiverModel()
model.start()

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
    styleMask: [.titled, .closable, .miniaturizable],
    backing: .buffered,
    defer: false
)
window.title = "PiControl Fake Receiver"
window.contentView = NSHostingView(rootView: ReceiverView(model: model))
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

app.run()
