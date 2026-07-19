import SwiftUI

/// Handles touch-down/up with raw `touches*` overrides instead of gesture
/// recognizers. The system gesture gate near physical screen edges delays
/// *recognizer-based* input (SwiftUI gestures included) while it rules out a
/// system swipe — but raw touch delivery is immediate, which is how games get
/// lag-free edge buttons.
private final class RawTouchView: UIView {
    var hitInset: CGFloat = 0
    var onPress: ((Bool) -> Void)?
    private var activeTouches = Set<UITouch>()

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -hitInset, dy: -hitInset).contains(point)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if activeTouches.isEmpty { onPress?(true) }
        activeTouches.formUnion(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches)
    }

    private func endTouches(_ touches: Set<UITouch>) {
        activeTouches.subtract(touches)
        if activeTouches.isEmpty { onPress?(false) }
    }
}

/// Overlay that reports press state (touch-down true, all-touches-up false)
/// via raw UIKit touches. `hitInset` grows the tappable area beyond the
/// overlaid view's bounds.
private struct RawPressHandler: UIViewRepresentable {
    var hitInset: CGFloat = 0
    let onPress: (Bool) -> Void

    func makeUIView(context: Context) -> RawTouchView {
        let view = RawTouchView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        return view
    }

    func updateUIView(_ view: RawTouchView, context: Context) {
        view.hitInset = hitInset
        view.onPress = onPress
    }
}

struct ContentView: View {
    @EnvironmentObject var ble: BLECentralManager
    @EnvironmentObject var state: ControllerState

    var body: some View {
        Group {
            switch ble.state {
            case .initializing:
                SplashView()
            case .connected:
                ControllerView()
            default:
                DevicePickerView()
            }
        }
        .animation(.easeOut(duration: 0.25), value: ble.state)
        // Applied at the root (not on ControllerView) so the preference is
        // active from launch: iOS defers edge touches for Control Center /
        // notification / home-indicator swipes, which made edge buttons feel
        // laggy, and SwiftUI doesn't reliably pick these up from a view that
        // appears later.
        .defersSystemGestures(on: .all)
        .persistentSystemOverlays(.hidden)
    }
}

// MARK: - Splash

/// Mirrors the static system launch screen (same image and background from
/// the asset catalog) and adds a spinner, so launch appears to animate: the
/// OS shows the static image until the app runs, then this takes over
/// seamlessly until Bluetooth reports its first state.
struct SplashView: View {
    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            Image("LaunchLogo")
            ProgressView()
                .controlSize(.large)
                .offset(y: 95)
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

    @State private var pressed = false

    var body: some View {
        Text(label)
            .font(small ? .caption : .body.weight(.semibold))
            .frame(width: small ? 64 : 52, height: small ? 28 : 44)
            .background(pressed ? Color.accentColor : Color(.systemGray5))
            .foregroundStyle(pressed ? .white : .primary)
            .clipShape(Capsule())
            .overlay(RawPressHandler(hitInset: 8) { isDown in
                pressed = isDown
                state.press(button, isDown)
            })
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

    @State private var pressed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.title2.weight(.bold))
            .foregroundStyle(color)
            .frame(width: 52, height: 52)
            .background(pressed ? color.opacity(0.35) : Color(.systemGray5))
            .clipShape(Circle())
            .overlay(RawPressHandler(hitInset: 8) { isDown in
                pressed = isDown
                state.press(button, isDown)
            })
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

    @State private var pressed = false

    var body: some View {
        Image(systemName: symbol)
            .frame(width: 40, height: 40)
            .background(pressed ? Color.accentColor : Color(.systemGray5))
            .foregroundStyle(pressed ? .white : .primary)
            .overlay(RawPressHandler(hitInset: 6) { isDown in
                pressed = isDown
                state.dpadX = isDown ? dx : 0
                state.dpadY = isDown ? dy : 0
            })
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
