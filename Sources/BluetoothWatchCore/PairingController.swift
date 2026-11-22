import Foundation

public enum PairingResult: Equatable, Sendable {
    case paired
    case cancelled
    case failed(String)
    /// The attempt could not pair in-app; hand off to Bluetooth settings with this reason.
    case settingsRequired(String)
}

public enum PairingStatus: Equatable {
    case pairing
    case paired
    case cancelled
    case failed(String)
    case settingsOpened
    case settingsFallback(String)

    public var message: String {
        switch self {
        case .pairing: return "Pairing... Follow any confirmation or passkey prompt."
        case .paired: return "Paired successfully."
        case .cancelled: return "Pairing cancelled."
        case .failed(let reason): return "Pairing failed: \(reason)"
        case .settingsOpened:
            return "Select this device in Bluetooth settings. Opening settings does not pair it."
        case .settingsFallback(let reason):
            return "\(reason) Bluetooth settings opened; select this device there. Opening settings does not pair it."
        }
    }
}

@MainActor
public protocol PairingDriver: AnyObject {
    func canPair(_ device: DiscoveredDevice) -> Bool
    func startPairing(_ device: DiscoveredDevice, completion: @escaping (PairingResult) -> Void)
    func cancelPairing()
}

@MainActor
public final class PairingController {
    public private(set) var statuses: [DeviceIdentity: PairingStatus] = [:]
    public private(set) var activeDeviceID: DeviceIdentity?
    public var onChange: (() -> Void)?
    private let driver: PairingDriver
    private let leDriver: PairingDriver?
    private let openSettings: (DiscoveredDevice) -> Bool
    private var attempt: UUID?
    private var activeDriver: PairingDriver?

    /// `driver` handles Bluetooth Classic devices; the optional `leDriver` handles Bluetooth LE.
    /// Devices neither driver supports open Bluetooth settings.
    public init(
        driver: PairingDriver,
        leDriver: PairingDriver? = nil,
        openSettings: @escaping (DiscoveredDevice) -> Bool
    ) {
        self.driver = driver
        self.leDriver = leDriver
        self.openSettings = openSettings
    }

    @discardableResult
    public func pair(_ device: DiscoveredDevice) -> Bool {
        guard activeDeviceID == nil else { return false }
        let candidate = device.id.transport == .lowEnergy ? leDriver : driver
        guard let selected = candidate, selected.canPair(device) else {
            statuses[device.id] = openSettings(device)
                ? .settingsOpened : .failed("Could not open Bluetooth settings.")
            onChange?()
            return true
        }
        let token = UUID()
        attempt = token
        activeDeviceID = device.id
        activeDriver = selected
        statuses[device.id] = .pairing
        onChange?()
        selected.startPairing(device) { [weak self] result in
            guard let self, self.attempt == token else { return }
            switch result {
            case .paired: self.statuses[device.id] = .paired
            case .cancelled: self.statuses[device.id] = .cancelled
            case .failed(let reason): self.statuses[device.id] = .failed(reason)
            case .settingsRequired(let reason):
                self.statuses[device.id] = self.openSettings(device)
                    ? .settingsFallback(reason)
                    : .failed("\(reason) Could not open Bluetooth settings.")
            }
            self.activeDeviceID = nil
            self.activeDriver = nil
            self.attempt = nil
            self.onChange?()
        }
        return true
    }

    public func cancel() {
        guard let id = activeDeviceID else { return }
        let cancelled = activeDriver
        attempt = nil
        activeDeviceID = nil
        activeDriver = nil
        statuses[id] = .cancelled
        cancelled?.cancelPairing()
        onChange?()
    }
}
