import Foundation
import OSLog
@preconcurrency import CoreBluetooth
@preconcurrency import IOBluetooth
import BluetoothWatchCore

/// Experimental in-app Bluetooth LE pairing, started only by an explicit Pair action.
///
/// Connects with a private central, then reads characteristics so macOS can show its
/// own pairing prompt for any that require encryption. Reports `.paired` only when
/// macOS lists a new matching paired device; otherwise hands off to Bluetooth settings.
@MainActor
final class LEPairingDriver: NSObject, PairingDriver {
    private let timeout: TimeInterval = 60
    private let connectTimeout: TimeInterval = 15
    private let evidenceSettleDelay: TimeInterval = 1.5
    private let logger = Logger(subsystem: "local.bluetoothwatch.app", category: "LEPairing")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var device: DiscoveredDevice?
    private var completion: ((PairingResult) -> Void)?
    private var attempt: UUID?
    private var pairedBefore: Set<String> = []
    private var pendingServices = 0
    private var characteristics: [CBCharacteristic] = []
    private var probe: LEPairingProbe?
    private var currentRead: CBCharacteristic?
    private var isSettling = false
    private var timeoutTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?

    func canPair(_ device: DiscoveredDevice) -> Bool {
        device.id.transport == .lowEnergy && UUID(uuidString: device.id.identifier) != nil
    }

    func startPairing(_ device: DiscoveredDevice, completion: @escaping (PairingResult) -> Void) {
        guard attempt == nil else {
            completion(.failed("Another Bluetooth LE pairing attempt is already active."))
            return
        }
        guard canPair(device) else {
            completion(.settingsRequired("This device has no Bluetooth LE identifier BluetoothWatch can connect to."))
            return
        }
        let token = UUID()
        attempt = token
        self.device = device
        self.completion = completion
        pairedBefore = Set(Self.pairedDevices().map(\.address))
        logger.notice("LE pairing started; \(self.pairedBefore.count) paired devices before.")
        timeoutTask = after(timeout, token) { driver in
            driver.finish(.failed("Pairing timed out after 60 seconds. Check that the device is nearby and ready to pair, or use Bluetooth settings."))
        }
        if let central {
            handleState(central.state)
        } else {
            central = CBCentralManager(
                delegate: self,
                queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
        }
    }

    func cancelPairing() {
        guard attempt != nil else { return }
        finish(.cancelled)
    }

    private func handleState(_ state: CBManagerState) {
        guard attempt != nil, peripheral == nil else { return }
        switch state {
        case .poweredOn: connect()
        case .unknown, .resetting: break
        case .unauthorized:
            finish(.failed("Bluetooth access is denied. Allow it in System Settings > Privacy & Security > Bluetooth."))
        case .poweredOff:
            finish(.failed("Bluetooth is powered off. Turn it on, then retry."))
        default:
            finish(.failed("Bluetooth is unavailable on this Mac."))
        }
    }

    private func connect() {
        guard let central, let token = attempt, let device,
              let uuid = UUID(uuidString: device.id.identifier) else { return }
        guard let target = central.retrievePeripherals(withIdentifiers: [uuid]).first else {
            finish(.settingsRequired("macOS no longer recognizes this device. Scan again, or use Bluetooth settings."))
            return
        }
        peripheral = target
        target.delegate = self
        central.connect(target, options: nil)
        connectTimeoutTask = after(connectTimeout, token) { driver in
            driver.finish(.settingsRequired("The device did not accept a connection within 15 seconds; it may not be connectable from apps."))
        }
    }

    private func beginProbe() {
        let candidates = characteristics.compactMap { characteristic -> LEPairingProbe.Candidate? in
            guard let service = characteristic.service else { return nil }
            return LEPairingProbe.Candidate(
                serviceUUID: service.uuid.uuidString,
                characteristicUUID: characteristic.uuid.uuidString,
                isReadable: characteristic.properties.contains(.read)
            )
        }
        var probe = LEPairingProbe(candidates: candidates)
        logger.notice("LE pairing found \(candidates.count) characteristics; probing: \(probe.hasCandidates).")
        let step = probe.start(pairedEvidence: hasPairingEvidence())
        self.probe = probe
        apply(step)
    }

    private func apply(_ step: LEPairingProbe.Step) {
        switch step {
        case .read(let candidate):
            guard let peripheral,
                  let characteristic = characteristics.first(where: {
                      $0.uuid.uuidString.uppercased() == candidate.characteristicUUID
                          && $0.service?.uuid.uuidString.uppercased() == candidate.serviceUUID
                  }) else {
                record(.otherError("characteristic unavailable"))
                return
            }
            currentRead = characteristic
            peripheral.readValue(for: characteristic)
        case .finish(.settingsRequired(let reason)):
            // macOS may update its paired list just after the prompt completes.
            guard let token = attempt else { return }
            isSettling = true
            _ = after(evidenceSettleDelay, token) { driver in
                driver.finish(driver.hasPairingEvidence() ? .paired : .settingsRequired(reason))
            }
        case .finish(let result):
            finish(result)
        }
    }

    private func record(_ result: LEPairingProbe.ReadResult) {
        guard var probe else { return }
        logger.notice("LE pairing read result: \(String(describing: result), privacy: .public).")
        let step = probe.record(result, pairedEvidence: hasPairingEvidence())
        self.probe = probe
        apply(step)
    }

    private func hasPairingEvidence() -> Bool {
        LEPairingEvidence.isNewPairing(
            before: pairedBefore,
            after: Self.pairedDevices(),
            deviceName: device?.name
        )
    }

    private func finish(_ result: PairingResult) {
        guard attempt != nil else { return }
        logger.notice("LE pairing finished: \(String(describing: result), privacy: .public).")
        let callback = completion
        attempt = nil
        completion = nil
        device = nil
        probe = nil
        currentRead = nil
        isSettling = false
        characteristics = []
        pendingServices = 0
        timeoutTask?.cancel()
        timeoutTask = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        if let peripheral {
            peripheral.delegate = nil
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        callback?(result)
    }

    private func after(
        _ delay: TimeInterval,
        _ token: UUID,
        _ action: @escaping @MainActor (LEPairingDriver) -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.attempt == token else { return }
            action(self)
        }
    }

    private static func pairedDevices() -> [LEPairingEvidence.PairedDevice] {
        (IOBluetoothDevice.pairedDevices() ?? []).compactMap { item in
            guard let paired = item as? IOBluetoothDevice, let address = paired.addressString else { return nil }
            return LEPairingEvidence.PairedDevice(address: address, name: paired.name)
        }
    }
}

extension LEPairingDriver: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central else { return }
        if peripheral != nil, central.state != .poweredOn {
            finish(.failed("Bluetooth became unavailable during pairing."))
            return
        }
        handleState(central.state)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.central === central, peripheral === self.peripheral, attempt != nil else { return }
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        logger.notice("LE pairing connected; discovering services.")
        peripheral.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.central === central, peripheral === self.peripheral, attempt != nil else { return }
        let detail = error.map { " (\($0.localizedDescription))" } ?? ""
        finish(.settingsRequired("The device refused the connection\(detail)."))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.central === central, peripheral === self.peripheral,
              attempt != nil, !isSettling else { return }
        finish(hasPairingEvidence()
            ? .paired
            : .failed("The device disconnected before pairing finished. Retry, or use Bluetooth settings."))
    }
}

extension LEPairingDriver: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral, attempt != nil else { return }
        let services = peripheral.services ?? []
        if let error {
            finish(.settingsRequired("Could not read the device's services (\(error.localizedDescription))."))
            return
        }
        guard !services.isEmpty else {
            beginProbe()
            return
        }
        pendingServices = services.count
        services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard peripheral === self.peripheral, attempt != nil, pendingServices > 0 else { return }
        if error == nil { characteristics += service.characteristics ?? [] }
        pendingServices -= 1
        if pendingServices == 0 { beginProbe() }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral === self.peripheral, attempt != nil, characteristic === currentRead else { return }
        currentRead = nil
        let nsError = error as NSError?
        record(.classify(domain: nsError?.domain, code: nsError?.code ?? 0))
    }
}
