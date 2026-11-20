import Foundation

public enum BluetoothTransport: String, Codable, Sendable {
    case classic
    case lowEnergy

    public var label: String {
        self == .classic ? "Bluetooth Classic" : "Bluetooth LE"
    }
}

public struct DeviceIdentity: Hashable, Codable, Sendable {
    public let transport: BluetoothTransport
    public let identifier: String

    public init(transport: BluetoothTransport, identifier: String) {
        self.transport = transport
        self.identifier = transport == .classic
            ? identifier.lowercased().replacingOccurrences(of: "-", with: ":")
            : identifier.lowercased()
    }

    public var notificationIdentifier: String {
        "\(transport.rawValue):\(identifier)"
    }
}

public struct DiscoveredDevice: Identifiable, Equatable, Sendable {
    public let id: DeviceIdentity
    public var name: String?
    public var rssi: Int?

    public init(id: DeviceIdentity, name: String? = nil, rssi: Int? = nil) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }

    public var displayName: String {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Unnamed Bluetooth device"
        }
        return name
    }
}

public struct DeviceRecord: Identifiable, Equatable {
    public enum Origin: Equatable { case baseline, newlyDiscovered }
    public var id: DeviceIdentity { device.id }
    public var device: DiscoveredDevice
    public let origin: Origin
    public let firstSeen: TimeInterval
    public var lastSeen: TimeInterval
    public var isIgnored = false
}
