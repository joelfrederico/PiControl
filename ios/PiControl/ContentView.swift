import SwiftUI

struct ContentView: View {
    @EnvironmentObject var ble: BLECentralManager
    @EnvironmentObject var state: ControllerState

    var body: some View {
        switch ble.state {
        case .connected:
            ControllerView()
        default:
            DevicePickerView()
        }
    }
}

// MARK: - Scan / connect

struct DevicePickerView: View {
    @EnvironmentObject var ble: BLECentralManager

    var body: some View {
        NavigationStack {
            List {
                switch ble.state {
                case .bluetoothOff:
                    Text("Turn on Bluetooth to scan for receivers.")
                case .connecting(let name):
                    HStack {
                        ProgressView()
                        Text("Connecting to \(name)…").padding(.leading, 8)
                    }
                default:
                    if ble.devices.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Scanning for PiControl receivers…").padding(.leading, 8)
                        }
                    }
                    ForEach(ble.devices) { device in
                        Button {
                            ble.connect(device)
                        } label: {
                            HStack {
                                Text(device.name)
                                Spacer()
                                Text("\(device.rssi) dBm")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("PiControl")
        }
    }
}

// MARK: - Controller

struct ControllerView: View {
    @EnvironmentObject var ble: BLECentralManager
    @EnvironmentObject var state: ControllerState

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                HoldButton(label: "L2", button: .l2Trigger)
                HoldButton(label: "L1", button: .l1)
                Spacer()
                Button("Disconnect") { ble.disconnect() }
                    .font(.caption)
                Spacer()
                HoldButton(label: "R1", button: .r1)
                HoldButton(label: "R2", button: .r2Trigger)
            }

            HStack(alignment: .center) {
                DPadView()
                Spacer()
                VStack(spacing: 8) {
                    HoldButton(label: "Create", button: .create, small: true)
                    HoldButton(label: "PS", button: .ps, small: true)
                    HoldButton(label: "Options", button: .options, small: true)
                }
                Spacer()
                FaceButtonsView()
            }

            HStack {
                ThumbstickView(stick: \.leftStick, thumbButton: .l3)
                Spacer()
                ThumbstickView(stick: \.rightStick, thumbButton: .r3)
            }
        }
        .padding(.vertical)
        .padding(.horizontal, 8)
    }
}

/// A button that reports pressed state on touch-down / touch-up.
struct HoldButton: View {
    @EnvironmentObject var state: ControllerState
    let label: String
    let button: PiControlProtocol.Buttons
    var small = false

    @GestureState private var pressed = false

    var body: some View {
        Text(label)
            .font(small ? .caption : .body.weight(.semibold))
            .frame(width: small ? 64 : 52, height: small ? 28 : 44)
            .background(pressed ? Color.accentColor : Color(.systemGray5))
            .foregroundStyle(pressed ? .white : .primary)
            .clipShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, isPressed, _ in isPressed = true }
            )
            .onChange(of: pressed) { _, isPressed in
                state.press(button, isPressed)
            }
    }
}

struct FaceButtonsView: View {
    var body: some View {
        VStack(spacing: 4) {
            FaceButton(symbol: "triangle", button: .triangle, color: .green)
            HStack(spacing: 36) {
                FaceButton(symbol: "square", button: .square, color: .pink)
                FaceButton(symbol: "circle", button: .circle, color: .red)
            }
            FaceButton(symbol: "xmark", button: .cross, color: .blue)
        }
    }
}

struct FaceButton: View {
    @EnvironmentObject var state: ControllerState
    let symbol: String
    let button: PiControlProtocol.Buttons
    let color: Color

    @GestureState private var pressed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.title2.weight(.bold))
            .foregroundStyle(color)
            .frame(width: 52, height: 52)
            .background(pressed ? color.opacity(0.35) : Color(.systemGray5))
            .clipShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, isPressed, _ in isPressed = true }
            )
            .onChange(of: pressed) { _, isPressed in
                state.press(button, isPressed)
            }
    }
}

struct DPadView: View {
    @EnvironmentObject var state: ControllerState

    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                DPadButton(symbol: "arrowtriangle.up.fill", dx: 0, dy: -1)
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
            GridRow {
                DPadButton(symbol: "arrowtriangle.left.fill", dx: -1, dy: 0)
                Color(.systemGray5).frame(width: 40, height: 40)
                DPadButton(symbol: "arrowtriangle.right.fill", dx: 1, dy: 0)
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                DPadButton(symbol: "arrowtriangle.down.fill", dx: 0, dy: 1)
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
        }
    }
}

struct DPadButton: View {
    @EnvironmentObject var state: ControllerState
    let symbol: String
    let dx: Int
    let dy: Int

    @GestureState private var pressed = false

    var body: some View {
        Image(systemName: symbol)
            .frame(width: 40, height: 40)
            .background(pressed ? Color.accentColor : Color(.systemGray5))
            .foregroundStyle(pressed ? .white : .primary)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, isPressed, _ in isPressed = true }
            )
            .onChange(of: pressed) { _, isPressed in
                state.dpadX = isPressed ? dx : 0
                state.dpadY = isPressed ? dy : 0
            }
    }
}

struct ThumbstickView: View {
    @EnvironmentObject var state: ControllerState
    let stick: ReferenceWritableKeyPath<ControllerState, CGPoint>
    let thumbButton: PiControlProtocol.Buttons

    private let radius: CGFloat = 60

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(.systemGray5))
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 44, height: 44)
                .offset(x: state[keyPath: stick].x * (radius - 22),
                        y: state[keyPath: stick].y * (radius - 22))
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let dx = value.translation.width / radius
                    let dy = value.translation.height / radius
                    let magnitude = max(1, sqrt(dx * dx + dy * dy))
                    state[keyPath: stick] = CGPoint(x: dx / magnitude, y: dy / magnitude)
                }
                .onEnded { _ in
                    state[keyPath: stick] = .zero
                }
        )
        .onLongPressGesture(minimumDuration: 0.4) {
            // Long-press the stick for L3/R3 click.
            state.press(thumbButton, true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                state.press(thumbButton, false)
            }
        }
    }
}
