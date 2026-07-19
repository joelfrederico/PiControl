// Fake PiControl receiver for macOS: advertises the PiControl BLE service
// and shows the controller input it receives in a window, so the iOS app
// can be tested without a Pi. Run with:
//
//     mac/fake-receiver
//
// (the wrapper compiles this file and runs the binary; plain
// `swift fake_receiver.swift` script mode dies on a JIT limitation —
// see the wrapper for details).
//
// Uses CoreBluetooth directly (no Python/bless layer) so it exercises the
// same stack the real receivers do from the phone's point of view. Button
// and d-pad edges are also printed to the console for logging.

import AppKit
import CoreBluetooth
import SwiftUI

let serviceUUID = CBUUID(string: "b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0001")
let inputCharUUID = CBUUID(string: "b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0002")
let configCharUUID = CBUUID(string: "b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0003")
let configVersion: UInt8 = 1
let hapticsCharUUID = CBUUID(string: "b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0004")
let hapticsVersion: UInt8 = 1
let localName = "PiControl-mac"
let packetSize = 17
let protocolVersion: UInt8 = 2
let attitudeScale = 32767.0 / Double.pi

// MARK: - Protocol decoding

struct Snapshot: Equatable {
    var buttons: UInt16 = 0
    var hat: UInt8 = 0
    var lx: Int8 = 0, ly: Int8 = 0, rx: Int8 = 0, ry: Int8 = 0
    var l2: UInt8 = 0, r2: UInt8 = 0
    var seq: UInt8 = 0
    /// Attitude in radians (portrait device frame).
    var pitch = 0.0, roll = 0.0, yaw = 0.0

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
        pitch = Self.attitude(bytes[11], bytes[12])
        roll = Self.attitude(bytes[13], bytes[14])
        yaw = Self.attitude(bytes[15], bytes[16])
    }

    private static func attitude(_ lo: UInt8, _ hi: UInt8) -> Double {
        Double(Int16(bitPattern: UInt16(lo) | (UInt16(hi) << 8))) / attitudeScale
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

    // Served config: what this receiver asks the phone for. Changing these
    // notifies a connected phone, which applies them live.
    @Published var wantMotion = true { didSet { pushConfig() } }
    @Published var wantAnalog = true { didSet { pushConfig() } }
    @Published var rateHz = 60 { didSet { pushConfig() } }
    /// Both 0...1; pushed to the phone as rumble intensity/sharpness.
    @Published var hapticIntensity = 0.0 { didSet { pushHaptics() } }
    @Published var hapticSharpness = 0.5 { didSet { pushHaptics() } }

    private var manager: CBPeripheralManager!
    private var configCharacteristic: CBMutableCharacteristic?
    private var hapticsCharacteristic: CBMutableCharacteristic?
    private var lastEdge = Snapshot()
    private var lastPacket: Date?
    private var windowStart = Date()
    private var windowCount = 0
    /// Most recent decoded packet. Kept out of @Published deliberately:
    /// attitude noise makes every 60 Hz packet unique, and publishing each
    /// one made SwiftUI re-render per packet on the same main queue that
    /// CoreBluetooth delivers on — the backlog showed up as input lag.
    /// A 30 Hz timer below forwards it to the published `snapshot` instead.
    private var latest = Snapshot()

    func start() {
        manager = CBPeripheralManager(delegate: self, queue: .main)
        // Display refresh, decoupled from packet arrival.
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.latest != self.snapshot {
                self.snapshot = self.latest
            }
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
            let input = CBMutableCharacteristic(
                type: inputCharUUID,
                properties: [.write, .writeWithoutResponse],
                value: nil,
                permissions: [.writeable]
            )
            // value: nil makes it dynamic — served via didReceiveRead and
            // updatable via updateValue (a static value could never change).
            let config = CBMutableCharacteristic(
                type: configCharUUID,
                properties: [.read, .notify],
                value: nil,
                permissions: [.readable]
            )
            configCharacteristic = config
            let hapticsChar = CBMutableCharacteristic(
                type: hapticsCharUUID,
                properties: [.read, .notify],
                value: nil,
                permissions: [.readable]
            )
            hapticsCharacteristic = hapticsChar
            let service = CBMutableService(type: serviceUUID, primary: true)
            service.characteristics = [input, config, hapticsChar]
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

    private var configData: Data {
        var flags: UInt8 = 0
        if wantMotion { flags |= 1 << 0 }
        if wantAnalog { flags |= 1 << 1 }
        return Data([configVersion, flags, UInt8(clamping: rateHz)])
    }

    private func pushConfig() {
        guard let configCharacteristic, manager != nil else { return }
        manager.updateValue(configData, for: configCharacteristic,
                            onSubscribedCentrals: nil)
    }

    private var hapticsData: Data {
        Data([hapticsVersion,
              UInt8(clamping: Int(hapticIntensity * 255)),
              UInt8(clamping: Int(hapticSharpness * 255))])
    }

    private func pushHaptics() {
        guard let hapticsCharacteristic, manager != nil else { return }
        manager.updateValue(hapticsData, for: hapticsCharacteristic,
                            onSubscribedCentrals: nil)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveRead request: CBATTRequest) {
        let data: Data
        switch request.characteristic.uuid {
        case configCharUUID: data = configData
        case hapticsCharUUID: data = hapticsData
        default:
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        guard request.offset <= data.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = data.subdata(in: request.offset..<data.count)
        peripheral.respond(to: request, withResult: .success)
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
                latest = snap
                lastPacket = Date()
                if status != "Receiving from PiControl app" {
                    status = "Receiving from PiControl app"
                }

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

struct AttitudeDial: View {
    let label: String
    let radians: Double

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1.5)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 20)
                    .offset(y: -10)
                    .rotationEffect(.radians(radians))
            }
            .frame(width: 44, height: 44)
            Text(String(format: "%@ %+.0f°", label, radians * 180 / .pi))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
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

            HStack(spacing: 22) {
                AttitudeDial(label: "pitch", radians: model.snapshot.pitch)
                AttitudeDial(label: "roll", radians: model.snapshot.roll)
                AttitudeDial(label: "yaw", radians: model.snapshot.yaw)
            }
            .opacity(model.stale ? 0.35 : 1)

            Divider()

            // What this receiver asks of the phone; changes notify the
            // phone live so its behavior can be watched above.
            HStack(spacing: 16) {
                Text("Request:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Motion", isOn: $model.wantMotion)
                    .toggleStyle(.checkbox)
                Toggle("Analog", isOn: $model.wantAnalog)
                    .toggleStyle(.checkbox)
                Picker("Rate", selection: $model.rateHz) {
                    Text("15 Hz").tag(15)
                    Text("30 Hz").tag(30)
                    Text("60 Hz").tag(60)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                Spacer()
            }
            .font(.caption)

            HStack(spacing: 12) {
                Text("Vibration:")
                    .foregroundStyle(.secondary)
                Text("intensity")
                    .foregroundStyle(.secondary)
                Slider(value: $model.hapticIntensity, in: 0...1)
                    .frame(width: 130)
                Text("\(Int(model.hapticIntensity * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
                Text("sharpness")
                    .foregroundStyle(.secondary)
                Slider(value: $model.hapticSharpness, in: 0...1)
                    .frame(width: 130)
                Text("\(Int(model.hapticSharpness * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
                Spacer()
            }
            .font(.caption)
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
