import Foundation

public enum PairingResult: Equatable {
    case paired
    case cancelled
    case failed(String)
}

public enum PairingStatus: Equatable {
    case pairing
    case paired
    case cancelled
    case failed(String)
    case settingsOpened

    public var message: String {
        switch self {
        case .pairing: return "Pairing... Follow any confirmation or passkey prompt."
        case .paired: return "Paired successfully."
        case .cancelled: return "Pairing cancelled."
        case .failed(let reason): return "Pairing failed: \(reason)"
        case .settingsOpened:
            return "Select this device in Bluetooth settings. Opening settings does not pair it."
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
    private let openSettings: (DiscoveredDevice) -> Bool
    private var attempt: UUID?

    public init(driver: PairingDriver, openSettings: @escaping (DiscoveredDevice) -> Bool) {
        self.driver = driver
        self.openSettings = openSettings
    }

    @discardableResult
    public func pair(_ device: DiscoveredDevice) -> Bool {
        guard activeDeviceID == nil else { return false }
        if device.id.transport == .lowEnergy || !driver.canPair(device) {
            statuses[device.id] = openSettings(device)
                ? .settingsOpened : .failed("Could not open Bluetooth settings.")
            onChange?()
            return true
        }
        let token = UUID()
        attempt = token
        activeDeviceID = device.id
        statuses[device.id] = .pairing
        onChange?()
        driver.startPairing(device) { [weak self] result in
            guard let self, self.attempt == token else { return }
            switch result {
            case .paired: self.statuses[device.id] = .paired
            case .cancelled: self.statuses[device.id] = .cancelled
            case .failed(let reason): self.statuses[device.id] = .failed(reason)
            }
            self.activeDeviceID = nil
            self.attempt = nil
            self.onChange?()
        }
        return true
    }

    public func cancel() {
        guard let id = activeDeviceID else { return }
        attempt = nil
        activeDeviceID = nil
        statuses[id] = .cancelled
        driver.cancelPairing()
        onChange?()
    }
}
