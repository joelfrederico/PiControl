import Combine
import CoreBluetooth
import Foundation

/// BLE central: scans for PiControl receivers (Pi 5 / Pico 2 W advertising
/// the PiControl service), connects to one at a time, and streams input
/// packets to the input characteristic at ~60 Hz via write-without-response.
final class BLECentralManager: NSObject, ObservableObject {
    enum ConnectionState: Equatable {
        /// Waiting for the first CoreBluetooth state callback after launch.
        case initializing
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

    @Published private(set) var state: ConnectionState = .initializing
    @Published private(set) var devices: [DiscoveredDevice] = []
    /// What the connected receiver wants from us; defaults until (and
    /// unless) its config characteristic says otherwise, and may change
    /// mid-connection via notify.
    @Published private(set) var receiverConfig = PiControlProtocol.ReceiverConfig()

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var inputCharacteristic: CBCharacteristic?
    private var configCharacteristic: CBCharacteristic?
    private var hapticsCharacteristic: CBCharacteristic?
    private let haptics = HapticsManager()
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
        // Rate per the receiver's config (default 60 Hz); each packet
        // carries the full controller state, so an occasional dropped
        // write-without-response is harmless.
        let interval = 1.0 / Double(receiverConfig.rateHz)
        sendTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
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
            controllerState.encodePacket(seq: seq,
                                         includeAnalog: receiverConfig.wantsAnalog)
        }
        peripheral.writeValue(packet, for: inputCharacteristic, type: .withoutResponse)
    }

    private func cleanupConnection() {
        stopSending()
        MainActor.assumeIsolated { haptics.stop() }
        peripheral = nil
        inputCharacteristic = nil
        configCharacteristic = nil
        hapticsCharacteristic = nil
        receiverConfig = PiControlProtocol.ReceiverConfig()
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
        peripheral.discoverCharacteristics([PiControlProtocol.inputCharacteristicUUID,
                                            PiControlProtocol.configCharacteristicUUID,
                                            PiControlProtocol.hapticsCharacteristicUUID],
                                           for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?
            .first(where: { $0.uuid == PiControlProtocol.inputCharacteristicUUID }) else {
            disconnect()
            return
        }
        inputCharacteristic = characteristic

        // Config characteristic is optional: read the initial value and
        // subscribe for mid-connection changes. Both arrive through
        // didUpdateValueFor. The send loop starts immediately with defaults;
        // a config that arrives later just retunes it.
        if let config = service.characteristics?
            .first(where: { $0.uuid == PiControlProtocol.configCharacteristicUUID }) {
            configCharacteristic = config
            peripheral.readValue(for: config)
            peripheral.setNotifyValue(true, for: config)
        }

        // Haptics characteristic is likewise optional: subscribe so the
        // receiver can drive vibration like console-to-controller rumble.
        if let hapticsChar = service.characteristics?
            .first(where: { $0.uuid == PiControlProtocol.hapticsCharacteristicUUID }) {
            hapticsCharacteristic = hapticsChar
            peripheral.readValue(for: hapticsChar)
            peripheral.setNotifyValue(true, for: hapticsChar)
        }

        state = .connected(name: peripheral.name ?? "PiControl")
        startSending()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else { return }
        switch characteristic.uuid {
        case PiControlProtocol.configCharacteristicUUID:
            let config = PiControlProtocol.ReceiverConfig.decode(characteristic.value)
            guard config != receiverConfig else { return }
            receiverConfig = config
            if sendTimer != nil {
                stopSending()
                startSending()
            }
        case PiControlProtocol.hapticsCharacteristicUUID:
            let command = PiControlProtocol.HapticsCommand.decode(characteristic.value)
            MainActor.assumeIsolated {
                haptics.set(intensity: command.intensity, sharpness: command.sharpness)
            }
        default:
            break
        }
    }
}
