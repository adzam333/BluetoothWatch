import Foundation

/// Decides how an explicit Bluetooth LE pairing attempt proceeds.
///
/// macOS has no public API that bonds an LE device directly. The only public route
/// is to connect and read characteristics: reading one that requires encryption makes
/// macOS show its own pairing prompt. A successful read or connection is not proof of
/// pairing, so `.paired` is only reported when macOS lists a new matching paired device.
public struct LEPairingProbe: Sendable {
    public struct Candidate: Equatable, Sendable {
        public let serviceUUID: String
        public let characteristicUUID: String
        public let isReadable: Bool

        public init(serviceUUID: String, characteristicUUID: String, isReadable: Bool) {
            self.serviceUUID = serviceUUID.uppercased()
            self.characteristicUUID = characteristicUUID.uppercased()
            self.isReadable = isReadable
        }
    }

    public enum ReadResult: Equatable, Sendable {
        case success
        /// The read needed encryption or authentication that macOS did not establish
        /// (the prompt was declined, timed out, or the device rejected the keys).
        case securityRequired
        /// The device reports it no longer has this Mac's pairing keys.
        case pairingRemoved
        case notPermitted
        case otherError(String)

        /// Classifies a CoreBluetooth read error by domain and code (values from CBError.h).
        public static func classify(domain: String?, code: Int) -> ReadResult {
            switch (domain, code) {
            case (nil, _): return .success
            case ("CBATTErrorDomain", 0x05), ("CBATTErrorDomain", 0x0C), ("CBATTErrorDomain", 0x0F):
                return .securityRequired
            case ("CBATTErrorDomain", 0x02), ("CBATTErrorDomain", 0x08):
                return .notPermitted
            case ("CBErrorDomain", 14): return .pairingRemoved
            case ("CBErrorDomain", 15): return .securityRequired
            case (let domain?, _): return .otherError("\(domain) \(code)")
            }
        }
    }

    public enum Step: Equatable, Sendable {
        case read(Candidate)
        case finish(PairingResult)
    }

    /// Generic Access, Generic Attribute and Device Information are readable without
    /// encryption on practically every device, so reading them cannot prompt for pairing.
    public static let openServices: Set<String> = ["1800", "1801", "180A"]

    public private(set) var readsAttempted = 0
    private var queue: [Candidate]
    private let maxReads: Int

    public init(candidates: [Candidate], maxReads: Int = 12) {
        queue = candidates.filter { $0.isReadable && !Self.openServices.contains($0.serviceUUID) }
        self.maxReads = maxReads
    }

    public var hasCandidates: Bool { !queue.isEmpty }

    /// The first step after services and characteristics are known.
    public mutating func start(pairedEvidence: Bool) -> Step {
        next(pairedEvidence: pairedEvidence)
    }

    /// The step after a characteristic read finishes.
    public mutating func record(_ result: ReadResult, pairedEvidence: Bool) -> Step {
        if pairedEvidence { return .finish(.paired) }
        switch result {
        case .securityRequired:
            return .finish(.failed("macOS requested pairing, but it was not completed (declined, timed out, or rejected by the device). Retry, or use Bluetooth settings."))
        case .pairingRemoved:
            return .finish(.failed("The device no longer has this Mac's pairing keys. Remove it in Bluetooth settings, then pair again."))
        case .success, .notPermitted, .otherError:
            return next(pairedEvidence: false)
        }
    }

    private mutating func next(pairedEvidence: Bool) -> Step {
        if pairedEvidence { return .finish(.paired) }
        guard readsAttempted < maxReads, !queue.isEmpty else {
            return .finish(.settingsRequired(readsAttempted == 0
                ? "This device exposes nothing BluetoothWatch can use to request pairing."
                : "BluetoothWatch connected, but macOS did not request or confirm pairing. This device may only pair through Bluetooth settings (most mice and keyboards do)."))
        }
        readsAttempted += 1
        return .read(queue.removeFirst())
    }
}

/// Matches macOS's paired-device list against a snapshot taken before an attempt.
public enum LEPairingEvidence {
    public struct PairedDevice: Equatable, Sendable {
        public let address: String
        public let name: String?

        public init(address: String, name: String?) {
            self.address = address.lowercased().replacingOccurrences(of: "-", with: ":")
            self.name = name
        }
    }

    /// True only if a device absent from `before` is now paired and, when both names are
    /// known, has the same name. Unrelated pairings made elsewhere are ignored when names differ.
    public static func isNewPairing(
        before: Set<String>,
        after: [PairedDevice],
        deviceName: String?
    ) -> Bool {
        let normalizedBefore = Set(before.map {
            $0.lowercased().replacingOccurrences(of: "-", with: ":")
        })
        let wanted = normalized(deviceName)
        return after.contains { paired in
            guard !paired.address.isEmpty, !normalizedBefore.contains(paired.address) else { return false }
            guard let wanted, let name = normalized(paired.name) else { return true }
            return name == wanted
        }
    }

    private static func normalized(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}
