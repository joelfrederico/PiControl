import SwiftUI

@main
struct PiControlApp: App {
    @StateObject private var controllerState: ControllerState
    @StateObject private var ble: BLECentralManager

    init() {
        let state = ControllerState()
        _controllerState = StateObject(wrappedValue: state)
        _ble = StateObject(wrappedValue: BLECentralManager(controllerState: state))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controllerState)
                .environmentObject(ble)
        }
    }
}
