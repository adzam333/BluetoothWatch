import Foundation

/// Decides how an explicit Bluetooth LE pairing attempt proceeds.
///
/// macOS has no public API that bonds an LE device directly. The only public route
/// is to connect and read characteristics: reading one that requires encryption makes
/// macOS show its own pairing prompt. CoreBluetooth does not expose a public way
/// to confirm that the selected peripheral was bonded, so the probe never reports
/// a successful read or connection as pairing.
public struct LEPairingProbe: Sendable {
    public struct Candidate: Equatable, Sendable {
        public let instanceIndex: Int
        public let serviceUUID: String
        public let characteristicUUID: String
        public let isReadable: Bool

        public init(instanceIndex: Int, serviceUUID: String, characteristicUUID: String, isReadable: Bool) {
            self.instanceIndex = instanceIndex
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
    public mutating func start() -> Step {
        next()
    }

    /// The step after a characteristic read finishes.
    public mutating func record(_ result: ReadResult) -> Step {
        switch result {
        case .securityRequired:
            return .finish(.failed("macOS requested pairing, but it was not completed (declined, timed out, or rejected by the device). Retry, or use Bluetooth settings."))
        case .pairingRemoved:
            return .finish(.failed("The device no longer has this Mac's pairing keys. Remove it in Bluetooth settings, then pair again."))
        case .success, .notPermitted, .otherError:
            return next()
        }
    }

    public static let timeoutResult = PairingResult.settingsRequired(
        "Pairing timed out after 60 seconds. Check that the device is nearby and ready to pair."
    )

    private mutating func next() -> Step {
        guard readsAttempted < maxReads, !queue.isEmpty else {
            return .finish(.settingsRequired(readsAttempted == 0
                ? "This device exposes nothing BluetoothWatch can use to request pairing."
                : "BluetoothWatch connected, but cannot confirm whether macOS paired this device. Check its status in Bluetooth settings."))
        }
        readsAttempted += 1
        return .read(queue.removeFirst())
    }
}
