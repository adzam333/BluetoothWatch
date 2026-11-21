import Foundation

public struct DiscoverySession {
    public static let baselineDuration: TimeInterval = 10
    public private(set) var records: [DeviceIdentity: DeviceRecord] = [:]
    public private(set) var isScanning = false
    public private(set) var baselineIsComplete = false
    private var remainingBaseline = Self.baselineDuration
    private var baselineStartedAt: TimeInterval?

    public init() {}

    public func baselineSecondsRemaining(at now: TimeInterval) -> TimeInterval {
        guard !baselineIsComplete else { return 0 }
        return max(0, remainingBaseline - elapsedBaseline(at: now))
    }

    public mutating func resume(at now: TimeInterval) {
        guard !isScanning else { return }
        isScanning = true
        if !baselineIsComplete { baselineStartedAt = now }
    }

    public mutating func advance(to now: TimeInterval) {
        if isScanning && !baselineIsComplete && baselineSecondsRemaining(at: now) <= 0 {
            baselineIsComplete = true
            remainingBaseline = 0
            baselineStartedAt = nil
        }
    }

    public mutating func pause(at now: TimeInterval) {
        guard isScanning else { return }
        advance(to: now)
        if !baselineIsComplete {
            remainingBaseline = baselineSecondsRemaining(at: now)
            baselineStartedAt = nil
        }
        isScanning = false
    }

    public mutating func interrupt(at now: TimeInterval) {
        pause(at: now)
        baselineIsComplete = false
        remainingBaseline = Self.baselineDuration
        baselineStartedAt = nil
    }

    /// Returns true at most once per post-baseline identity: the first time it is observed
    /// while alert-eligible (Classic, or BLE with a name, which may arrive in a later update).
    @discardableResult
    public mutating func discover(_ device: DiscoveredDevice, at now: TimeInterval) -> Bool {
        guard isScanning else { return false }
        advance(to: now)
        var record: DeviceRecord
        if let existing = records[device.id] {
            record = existing
            if device.hasName { record.device.name = device.name }
            if let rssi = device.rssi { record.device.rssi = rssi }
            record.lastSeen = now
        } else {
            record = DeviceRecord(
                device: device,
                origin: baselineIsComplete ? .newlyDiscovered : .baseline,
                firstSeen: now,
                lastSeen: now
            )
        }
        let shouldAlert = record.origin == .newlyDiscovered && !record.wasAlerted
            && !record.isIgnored && record.device.isAlertEligible
        if shouldAlert { record.wasAlerted = true }
        records[device.id] = record
        return shouldAlert
    }

    public mutating func setIgnored(_ ignored: Bool, for id: DeviceIdentity) {
        records[id]?.isIgnored = ignored
    }

    private func elapsedBaseline(at now: TimeInterval) -> TimeInterval {
        baselineStartedAt.map { max(0, now - $0) } ?? 0
    }
}
