/// Decides how the scanner reacts to Classic inquiry lifecycle callbacks.
///
/// Observed on macOS 26: `IOBluetoothDeviceInquiry` never calls `deviceInquiryStarted`,
/// and the system's periodic continuous-inquiry restart is reported as a completion with
/// the undocumented code `0x1`. Only that code, after an inquiry went live, is treated as
/// a routine cycle end; every other non-success completion is surfaced.
public struct ClassicInquiryPolicy: Equatable, Sendable {
    public static let observedCycleEndCode: Int32 = 0x1

    public enum Evidence: Equatable, Sendable {
        /// `deviceInquiryStarted` was delivered.
        case startedCallback
        /// A Classic device was reported by the inquiry.
        case result
        /// `start()` succeeded and no failure arrived within the grace period.
        /// This proves only the absence of an early failure, not active scanning.
        case gracePeriodElapsed
    }

    public enum Readiness: Equatable, Sendable {
        case waiting
        /// Treated as live so the baseline can run, but macOS has not confirmed Classic scanning.
        case unconfirmed
        case confirmed
    }

    public enum Decision: Equatable, Sendable {
        /// Routine end; start the next inquiry after the normal gap without interrupting the session.
        case continueAfterGap
        /// The inquiry never went live; retry after the gap (bounded).
        case retryAfterGap
        /// Surface the failure and stop monitoring until the user retries.
        case fail(Int32)
    }

    public let maxUnstartedFailures: Int
    public private(set) var isInquiryLive = false
    public private(set) var isClassicConfirmed = false
    public private(set) var consecutiveUnstartedFailures = 0

    public init(maxUnstartedFailures: Int = 3) {
        self.maxUnstartedFailures = max(1, maxUnstartedFailures)
    }

    public var readiness: Readiness {
        if isClassicConfirmed { return .confirmed }
        return isInquiryLive ? .unconfirmed : .waiting
    }

    /// Forget all evidence, e.g. after an interruption or explicit stop.
    public mutating func reset() {
        self = ClassicInquiryPolicy(maxUnstartedFailures: maxUnstartedFailures)
    }

    public mutating func beginInquiry() {
        isInquiryLive = false
    }

    /// Returns true when readiness changed.
    @discardableResult
    public mutating func observe(_ evidence: Evidence) -> Bool {
        let before = readiness
        isInquiryLive = true
        consecutiveUnstartedFailures = 0
        if evidence != .gracePeriodElapsed { isClassicConfirmed = true }
        return readiness != before
    }

    public mutating func complete(error: Int32, aborted: Bool) -> Decision {
        let wasLive = isInquiryLive
        isInquiryLive = false
        if aborted || error == 0 { return .continueAfterGap }
        if wasLive {
            if error == Self.observedCycleEndCode { return .continueAfterGap }
            return .fail(error)
        }
        consecutiveUnstartedFailures += 1
        if consecutiveUnstartedFailures < maxUnstartedFailures { return .retryAfterGap }
        consecutiveUnstartedFailures = 0
        return .fail(error)
    }
}
