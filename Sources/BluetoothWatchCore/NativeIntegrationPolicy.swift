import Foundation

/// Token used to reject callbacks from a native scan after stop or restart.
public struct DiscoveryCallbackGeneration: Equatable, Sendable {
    public private(set) var current: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func advance() -> UInt64 {
        current &+= 1
        return current
    }

    public func accepts(_ callback: UInt64) -> Bool {
        callback == current
    }

    public func accepts(_ callback: UInt64?) -> Bool {
        callback == current
    }
}

public enum NotificationRoute: Equatable, Sendable {
    case device(DeviceIdentity)
    case earlierRun
    case unknownDevice

    /// Validates notification run and device identity against the current discovery records.
    public static func resolve(
        notificationRunID: String,
        currentRunID: String,
        notificationIdentifier: String,
        currentDevices: Set<DeviceIdentity>
    ) -> Self {
        guard notificationRunID == currentRunID else { return .earlierRun }
        guard let separator = notificationIdentifier.firstIndex(of: ":") else {
            return .unknownDevice
        }
        let transportName = notificationIdentifier[..<separator]
        let identifier = String(notificationIdentifier[notificationIdentifier.index(after: separator)...])
        guard !identifier.isEmpty,
              let transport = BluetoothTransport(rawValue: String(transportName)) else {
            return .unknownDevice
        }
        let identity = DeviceIdentity(transport: transport, identifier: identifier)
        return currentDevices.contains(identity) ? .device(identity) : .unknownDevice
    }
}

public enum BluetoothAvailability: Equatable, Sendable {
    case ready
    case denied
    case poweredOff
    case unsupported
    case resetting
    case unknown

    public var shouldRecreateAfterSettings: Bool {
        self == .denied
    }

    public func shouldHandleOnStart(isRunning: Bool, hasActiveInquiry: Bool) -> Bool {
        !isRunning && !(self == .ready && hasActiveInquiry)
    }
}
