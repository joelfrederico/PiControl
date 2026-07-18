import Combine
import CoreBluetooth
import Foundation

/// BLE central: scans for PiControl receivers (Pi 5 / Pico 2 W advertising
/// the PiControl service), connects to one at a time, and streams input
/// packets to the input characteristic at ~60 Hz via write-without-response.
final class BLECentralManager: NSObject, ObservableObject {
    enum ConnectionState: Equatable {
        case bluetoothOff
        case scanning
        case connecting(name: String)
        case connected(name: String)
    }

    struct DiscoveredDevice: Identifiable {
        let id: UUID
        let name: String
        let rssi: Int
        let peripheral: CBPeripheral
    }

    @Published private(set) var state: ConnectionState = .bluetoothOff
    @Published private(set) var devices: [DiscoveredDevice] = []

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var inputCharacteristic: CBCharacteristic?
    private var sendTimer: Timer?
    private var seq: UInt8 = 0

    let controllerState: ControllerState

    init(controllerState: ControllerState) {
        self.controllerState = controllerState
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func connect(_ device: DiscoveredDevice) {
        central.stopScan()
        state = .connecting(name: device.name)
        peripheral = device.peripheral
        device.peripheral.delegate = self
        central.connect(device.peripheral)
    }

    func disconnect() {
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    private func startScanning() {
        devices = []
        state = .scanning
        central.scanForPeripherals(
            withServices: [PiControlProtocol.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func startSending() {
        // 60 Hz input stream; each packet carries the full controller state,
        // so an occasional dropped write-without-response is harmless.
        sendTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.sendPacket()
        }
    }

    private func stopSending() {
        sendTimer?.invalidate()
        sendTimer = nil
    }

    private func sendPacket() {
        guard let peripheral, let inputCharacteristic,
              peripheral.canSendWriteWithoutResponse else { return }
        seq &+= 1
        let packet = MainActor.assumeIsolated {
            controllerState.encodePacket(seq: seq)
        }
        peripheral.writeValue(packet, for: inputCharacteristic, type: .withoutResponse)
    }

    private func cleanupConnection() {
        stopSending()
        peripheral = nil
        inputCharacteristic = nil
    }
}

extension BLECentralManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            startScanning()
        } else {
            cleanupConnection()
            state = .bluetoothOff
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? "Unknown"
        let device = DiscoveredDevice(id: peripheral.identifier, name: name,
                                      rssi: RSSI.intValue, peripheral: peripheral)
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([PiControlProtocol.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        cleanupConnection()
        startScanning()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        cleanupConnection()
        startScanning()
    }
}

extension BLECentralManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?
            .first(where: { $0.uuid == PiControlProtocol.serviceUUID }) else {
            disconnect()
            return
        }
        peripheral.discoverCharacteristics([PiControlProtocol.inputCharacteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?
            .first(where: { $0.uuid == PiControlProtocol.inputCharacteristicUUID }) else {
            disconnect()
            return
        }
        inputCharacteristic = characteristic
        state = .connected(name: peripheral.name ?? "PiControl")
        startSending()
    }
}
