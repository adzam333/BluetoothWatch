import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import IOBluetooth
import BluetoothWatchCore

@MainActor
final class BluetoothDiscovery: NSObject {
    var onDevice: ((DiscoveredDevice) -> Void)?
    var onState: ((Bool, String) -> Void)?
    private(set) var isRunning = false

    private let inquiryDuration: UInt8 = 8
    private let inquiryGap: TimeInterval = 4
    private var central: CBCentralManager?
    private var activeInquiry: IOBluetoothDeviceInquiry?
    private var activeInquiryGeneration: UInt64?
    private var wantsMonitoring = false
    private var generation: UInt64 = 0
    private var classicGapTimer: Timer?
    private var pendingBLE: [DeviceIdentity: DiscoveredDevice] = [:]

    func start() {
        wantsMonitoring = true
        if central == nil {
            central = CBCentralManager(
                delegate: self,
                queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
        } else if !isRunning {
            handleCentralState(central!.state)
        }
    }

    func stop() {
        wantsMonitoring = false
        generation &+= 1
        classicGapTimer?.invalidate()
        classicGapTimer = nil
        central?.stopScan()
        central?.delegate = nil
        central = nil
        pendingBLE.removeAll()
        if let result = stopClassicInquiry(),
           result != kIOReturnSuccess && result != kIOReturnNotPermitted {
            setRunning(false, message: "Classic discovery could not stop cleanly (error \(Self.errorCode(result))). No further results will be accepted.")
            return
        }
        setRunning(false, message: "Bluetooth monitoring is stopped.")
    }

    /// Requests discovery without interrupting an inquiry already in progress.
    func scanNow() {
        guard wantsMonitoring else {
            start()
            return
        }
        guard central?.state == .poweredOn else {
            if let central { handleCentralState(central.state) }
            return
        }
        guard isRunning else {
            startTransportsIfReady()
            return
        }

        classicGapTimer?.invalidate()
        classicGapTimer = nil
        central?.stopScan()
        central?.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        if activeInquiry == nil { startClassicInquiry() }
    }

    private func handleCentralState(_ state: CBManagerState) {
        guard wantsMonitoring else { return }
        switch state {
        case .poweredOn:
            generation &+= 1
            startTransportsIfReady()
        case .unauthorized:
            stopTransportsForUnavailableState()
            setRunning(
                false,
                message: "Bluetooth access is denied. Allow Bluetooth access for BluetoothWatch in System Settings > Privacy & Security > Bluetooth, then retry."
            )
        case .poweredOff:
            stopTransportsForUnavailableState()
            setRunning(
                false,
                message: "Bluetooth is powered off. Turn Bluetooth on in System Settings, then retry."
            )
        case .unsupported:
            stopTransportsForUnavailableState()
            setRunning(false, message: "This Mac does not support Bluetooth scanning.")
        case .resetting:
            stopTransportsForUnavailableState()
            setRunning(false, message: "Bluetooth is resetting. Monitoring will resume when the adapter is ready.")
        case .unknown:
            stopTransportsForUnavailableState()
            setRunning(false, message: "Bluetooth authorization or adapter state is not ready yet. Monitoring will retry when macOS reports a state.")
        @unknown default:
            stopTransportsForUnavailableState()
            setRunning(false, message: "Bluetooth reported an unsupported adapter state. Retry after checking System Settings.")
        }
    }

    private func startTransportsIfReady() {
        guard wantsMonitoring, central?.state == .poweredOn else { return }
        central?.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        guard activeInquiry == nil else { return }
        startClassicInquiry()
    }

    private func startClassicInquiry() {
        guard wantsMonitoring, central?.state == .poweredOn, activeInquiry == nil else { return }
        guard let inquiry = IOBluetoothDeviceInquiry(delegate: self) else {
            central?.stopScan()
            setRunning(
                false,
                message: "macOS could not create a Classic Bluetooth inquiry. Check Bluetooth permissions in System Settings, then retry."
            )
            return
        }
        inquiry.inquiryLength = inquiryDuration
        inquiry.updateNewDeviceNames = false
        activeInquiry = inquiry
        activeInquiryGeneration = generation

        let result = inquiry.start()
        guard result == kIOReturnSuccess else {
            activeInquiry = nil
            activeInquiryGeneration = nil
            central?.stopScan()
            setRunning(
                false,
                message: "Classic Bluetooth inquiry could not start (error \(Self.errorCode(result))). Check Bluetooth in System Settings, then use Retry."
            )
            return
        }
        if !isRunning {
            setRunning(false, message: "Waiting for macOS to begin Bluetooth Classic discovery...")
        }
    }

    private func stopTransportsForUnavailableState() {
        generation &+= 1
        classicGapTimer?.invalidate()
        classicGapTimer = nil
        central?.stopScan()
        pendingBLE.removeAll()
        _ = stopClassicInquiry()
    }

    private func stopClassicInquiry() -> IOReturn? {
        let inquiry = activeInquiry
        activeInquiry = nil
        activeInquiryGeneration = nil
        inquiry?.delegate = nil
        return inquiry?.stop()
    }

    private func scheduleNextInquiry() {
        classicGapTimer?.invalidate()
        let scheduledGeneration = generation
        classicGapTimer = Timer.scheduledTimer(withTimeInterval: inquiryGap, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == scheduledGeneration,
                      self.wantsMonitoring, self.central?.state == .poweredOn else { return }
                self.classicGapTimer = nil
                self.startClassicInquiry()
            }
        }
    }

    private func setRunning(_ running: Bool, message: String) {
        let changed = isRunning != running
        isRunning = running
        if changed || !running {
            onState?(running, message)
        }
    }

    private func deliver(_ device: DiscoveredDevice, generation callbackGeneration: UInt64) {
        guard wantsMonitoring, isRunning,
              callbackGeneration == generation,
              central?.state == .poweredOn else { return }
        onDevice?(device)
    }

    private static func errorCode(_ error: IOReturn) -> String {
        String(format: "0x%08x", UInt32(bitPattern: error))
    }
}

extension BluetoothDiscovery: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central else { return }
        handleCentralState(central.state)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard self.central === central, wantsMonitoring, central.state == .poweredOn else { return }
        let identity = DeviceIdentity(transport: .lowEnergy, identifier: peripheral.identifier.uuidString)
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let device = DiscoveredDevice(
            id: identity, name: advertisedName ?? peripheral.name, rssi: RSSI.intValue
        )
        if isRunning { deliver(device, generation: generation) }
        else { pendingBLE[identity] = device }
    }
}

extension BluetoothDiscovery: IOBluetoothDeviceInquiryDelegate {
    func deviceInquiryStarted(_ sender: IOBluetoothDeviceInquiry!) {
        guard let sender, sender === activeInquiry,
              activeInquiryGeneration == generation, wantsMonitoring else { return }
        // start() can succeed before a throttled inquiry actually begins.
        setRunning(true, message: "Scanning for Bluetooth Classic and Bluetooth LE devices.")
        let buffered = Array(pendingBLE.values)
        pendingBLE.removeAll()
        for device in buffered { deliver(device, generation: generation) }
    }

    func deviceInquiryDeviceFound(
        _ sender: IOBluetoothDeviceInquiry!,
        device: IOBluetoothDevice!
    ) {
        guard let sender, let device,
              sender === activeInquiry,
              let callbackGeneration = activeInquiryGeneration else { return }
        let address = senderDeviceAddress(device)
        guard !address.isEmpty else { return }
        deliver(
            DiscoveredDevice(
                id: DeviceIdentity(transport: .classic, identifier: address),
                name: device.name
            ),
            generation: callbackGeneration
        )
    }

    func deviceInquiryComplete(
        _ sender: IOBluetoothDeviceInquiry!,
        error: IOReturn,
        aborted: Bool
    ) {
        guard let sender, sender === activeInquiry else { return }
        activeInquiry = nil
        let callbackGeneration = activeInquiryGeneration
        activeInquiryGeneration = nil

        guard wantsMonitoring else { return }
        guard callbackGeneration == generation else {
            if central?.state == .poweredOn { startTransportsIfReady() }
            return
        }
        if aborted {
            scheduleNextInquiry()
        } else if error == kIOReturnSuccess {
            scheduleNextInquiry()
        } else {
            central?.stopScan()
            setRunning(
                false,
                message: "Classic Bluetooth inquiry failed (error \(Self.errorCode(error))). Bluetooth LE alone cannot provide complete device coverage. Check Bluetooth in System Settings, then retry."
            )
        }
    }

    private func senderDeviceAddress(_ device: IOBluetoothDevice) -> String {
        device.addressString ?? ""
    }
}
