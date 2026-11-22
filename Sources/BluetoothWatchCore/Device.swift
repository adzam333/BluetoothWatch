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

    public var hasName: Bool {
        guard let name else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var displayName: String {
        guard hasName, let name else { return "Unnamed Bluetooth device" }
        return name
    }

    /// Anonymous BLE advertisers (often rotating private addresses) do not alert.
    public var isAlertEligible: Bool {
        id.transport == .classic || hasName
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
    public var wasAlerted = false
}

public struct DeviceListSections {
    public private(set) var visible: [DeviceRecord] = []
    public private(set) var ignored: [DeviceRecord] = []

    public init(records: [DeviceRecord]) {
        for record in records where record.device.hasName {
            if record.isIgnored {
                ignored.append(record)
            } else {
                visible.append(record)
            }
        }
    }
}

public enum DeviceListFilter: String, CaseIterable, Identifiable, Sendable {
    case named
    case classic
    case lowEnergy
    case ignored

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .named: "Named"
        case .classic: "Classic"
        case .lowEnergy: "Bluetooth LE"
        case .ignored: "Ignored"
        }
    }

    public func records(in sections: DeviceListSections, matching search: String) -> [DeviceRecord] {
        let candidates: [DeviceRecord]
        switch self {
        case .named:
            candidates = sections.visible
        case .classic:
            candidates = sections.visible.filter { $0.id.transport == .classic }
        case .lowEnergy:
            candidates = sections.visible.filter { $0.id.transport == .lowEnergy }
        case .ignored:
            candidates = sections.ignored
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return candidates }
        return candidates.filter {
            $0.device.displayName.localizedCaseInsensitiveContains(query)
                || $0.id.identifier.localizedCaseInsensitiveContains(query)
                || $0.id.transport.label.localizedCaseInsensitiveContains(query)
        }
    }

}

public struct BLEDiscoveryThrottle: Sendable {
    private struct Observation: Sendable {
        var deliveredAt: TimeInterval
        var name: String?
    }

    public let minimumInterval: TimeInterval
    private let retentionInterval: TimeInterval
    private var observations: [DeviceIdentity: Observation] = [:]
    private var lastPrunedAt: TimeInterval?

    public init(minimumInterval: TimeInterval = 3, retentionInterval: TimeInterval = 120) {
        self.minimumInterval = max(0, minimumInterval)
        self.retentionInterval = max(minimumInterval, retentionInterval)
    }

    /// Allows prompt name updates, otherwise delivers at most once per minimum interval.
    public mutating func shouldDeliver(_ device: DiscoveredDevice, at now: TimeInterval) -> Bool {
        guard device.id.transport == .lowEnergy else { return true }
        pruneIfNeeded(at: now)
        let name = normalizedName(device.name)
        guard var prior = observations[device.id] else {
            observations[device.id] = Observation(deliveredAt: now, name: name)
            return true
        }

        if let name, name != prior.name {
            prior.name = name
            prior.deliveredAt = now
            observations[device.id] = prior
            return true
        }
        guard now - prior.deliveredAt >= minimumInterval else { return false }
        prior.deliveredAt = now
        observations[device.id] = prior
        return true
    }

    private mutating func pruneIfNeeded(at now: TimeInterval) {
        guard lastPrunedAt.map({ now - $0 >= minimumInterval * 10 }) ?? true else { return }
        observations = observations.filter { now - $0.value.deliveredAt < retentionInterval }
        lastPrunedAt = now
    }

    private func normalizedName(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name.lowercased()
    }
}
