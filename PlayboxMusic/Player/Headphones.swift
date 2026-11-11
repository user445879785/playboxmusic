import AVFoundation
import CoreBluetooth
import Foundation

/// Watches what audio is coming out of (earbuds, speaker, AirPlay) and,
/// when asked, tries to read the earbuds' battery over Bluetooth LE.
///
/// iOS gives apps no direct way to read a Bluetooth headset's battery. This
/// reads the standard BLE Battery Service (0x180F) when the earbuds offer it
/// to other apps; many do, some (including some Soundcore models) only share
/// it with their own app, and then iOS's Batteries widget is the only place.
final class HeadphoneMonitor: NSObject, ObservableObject {
    enum BatteryState: Equatable {
        case idle
        case searching
        case level(Int)
        case unavailable(String)
    }

    /// Name of the current output, such as "soundcore K20i".
    @Published private(set) var routeName: String?
    @Published private(set) var isHeadphones = false
    @Published private(set) var battery: BatteryState = .idle

    private var central: CBCentralManager?
    private var target: CBPeripheral?
    private var searchTimeout: Task<Void, Never>?
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")

    override init() {
        super.init()
        updateRoute()
        NotificationCenter.default.addObserver(
            self, selector: #selector(routeChanged),
            name: AVAudioSession.routeChangeNotification, object: nil
        )
    }

    @objc private func routeChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let before = self.routeName
            self.updateRoute()
            if before != self.routeName {
                self.disconnect()
                self.battery = .idle
                if self.isHeadphones, UserDefaults.standard.bool(forKey: "headphones.batteryOptIn") {
                    self.refreshBattery()
                }
            }
        }
    }

    private func updateRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let headphoneTypes: [AVAudioSession.Port] = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .headphones, .usbAudio]
        if let port = outputs.first(where: { headphoneTypes.contains($0.portType) }) {
            routeName = port.portName
            isHeadphones = true
        } else {
            routeName = outputs.first?.portName
            isHeadphones = false
        }
    }

    // MARK: Battery

    /// Starts Bluetooth (asking permission the first time) and looks for the
    /// earbuds' battery level.
    func refreshBattery() {
        guard isHeadphones else {
            battery = .unavailable("Connect Bluetooth earbuds to see their battery.")
            return
        }
        UserDefaults.standard.set(true, forKey: "headphones.batteryOptIn")
        battery = .searching
        if let central {
            if central.state == .poweredOn { search() }
        } else {
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    private func search() {
        guard let central else { return }
        // Already connected to iOS and offering the battery service?
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.batteryService])
        if let match = connected.first(where: matchesRoute) ?? connected.first {
            connect(match)
            return
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        searchTimeout?.cancel()
        searchTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, self.battery == .searching else { return }
            self.central?.stopScan()
            self.battery = .unavailable("These earbuds don't share their battery with other apps. Check the Batteries widget on your Home Screen.")
        }
    }

    private func matchesRoute(_ peripheral: CBPeripheral) -> Bool {
        guard let name = peripheral.name?.lowercased(), let route = routeName?.lowercased() else { return false }
        if name == route || name.contains(route) || route.contains(name) { return true }
        // Match on the model word, such as "k20i".
        let words = route.split(separator: " ").filter { $0.count >= 3 && $0.contains(where: \.isNumber) }
        return words.contains { name.contains($0) }
    }

    private func connect(_ peripheral: CBPeripheral) {
        central?.stopScan()
        target = peripheral
        peripheral.delegate = self
        central?.connect(peripheral)
    }

    private func disconnect() {
        searchTimeout?.cancel()
        central?.stopScan()
        if let target { central?.cancelPeripheralConnection(target) }
        target = nil
    }
}

extension HeadphoneMonitor: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if battery == .searching { search() }
        case .unauthorized:
            battery = .unavailable("Allow Bluetooth for Playbox Music in Settings to see the battery.")
        case .poweredOff:
            battery = .unavailable("Bluetooth is off.")
        case .unsupported:
            battery = .unavailable("Bluetooth LE isn't available on this device.")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard target == nil, matchesRoute(peripheral) else { return }
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        target = nil
        battery = .unavailable("Couldn't connect to the earbuds' battery service.")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.batteryService }) else {
            searchTimeout?.cancel()
            battery = .unavailable("These earbuds don't share their battery with other apps. Check the Batteries widget on your Home Screen.")
            return
        }
        peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let level = service.characteristics?.first(where: { $0.uuid == Self.batteryLevel }) else { return }
        peripheral.readValue(for: level)
        if level.properties.contains(.notify) { peripheral.setNotifyValue(true, for: level) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.batteryLevel, let byte = characteristic.value?.first else { return }
        searchTimeout?.cancel()
        battery = .level(min(100, Int(byte)))
    }
}

extension HeadphoneProfile {
    /// Picks a profile from the output's name, like AutoEq does from the
    /// connected headphones.
    static func detect(_ routeName: String?) -> HeadphoneProfile? {
        guard let name = routeName?.lowercased() else { return nil }
        if name.contains("k20i") { return .soundcoreK20i }
        if name.contains("p20i") { return .soundcoreP20i }
        if name.contains("airpods pro") { return .airPodsPro }
        if name.contains("airpods max") { return .off }
        if name.contains("airpods") { return .airPods }
        return nil
    }
}
