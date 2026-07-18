# PiControl (iOS)

SwiftUI iPhone app that acts as the controller: it scans for PiControl
receivers (a Pi 5 or Pico 2 W advertising the PiControl BLE service), connects
to the one you pick, and streams controller input at ~60 Hz using
write-without-response. Landscape layout with two thumbsticks, d-pad, face
buttons, shoulders/triggers, and Create/PS/Options.

## Creating the Xcode project

The Swift sources are complete; only the `.xcodeproj` needs generating.

**Option A — XcodeGen** (easiest):

```sh
brew install xcodegen
cd ios && xcodegen generate
open PiControl.xcodeproj
```

[`project.yml`](project.yml) defines the target, including the required
`NSBluetoothAlwaysUsageDescription` Info.plist key and landscape-only
orientation.

**Option B — manually in Xcode**:

1. File → New → Project → iOS App, product name `PiControl`, interface
   SwiftUI. Create it inside `ios/` (Xcode will make `PiControl.xcodeproj`).
2. Delete the template's generated Swift files and add the files in
   [`PiControl/`](PiControl/) to the target.
3. In the target's Info tab add **Privacy - Bluetooth Always Usage
   Description** (`NSBluetoothAlwaysUsageDescription`) — required or the app
   crashes on first Bluetooth use.
4. Under Deployment Info, restrict orientation to landscape.

Then select your iPhone as the run destination and build. BLE does not work
in the simulator — test on a real device. You'll need your personal team
selected under Signing & Capabilities.

## Files

| File | Purpose |
|---|---|
| `PiControlApp.swift` | App entry point, wires up shared state |
| `ContentView.swift` | Device picker + on-screen controller UI |
| `ControllerState.swift` | Observable input state, packet assembly |
| `BLECentralManager.swift` | Scanning, connection lifecycle, 60 Hz send loop |
| `Protocol.swift` | Packet encoder + UUIDs (mirrors the Python decoder) |
