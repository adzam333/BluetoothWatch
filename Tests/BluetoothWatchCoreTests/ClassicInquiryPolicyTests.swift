import Testing
@testable import BluetoothWatchCore

struct ClassicInquiryPolicyTests {
    private let cycleEnd = ClassicInquiryPolicy.observedCycleEndCode
    private let ioReturnError: Int32 = Int32(bitPattern: 0xe00002bc)

    @Test func startWithoutEvidenceIsWaiting() {
        var policy = ClassicInquiryPolicy()
        policy.beginInquiry()
        #expect(policy.readiness == .waiting)
        #expect(!policy.isInquiryLive)
    }

    @Test func gracePeriodIsLiveButUnconfirmed() {
        var policy = ClassicInquiryPolicy()
        policy.beginInquiry()
        #expect(policy.observe(.gracePeriodElapsed) == true)
        #expect(policy.readiness == .unconfirmed)
        #expect(!policy.isClassicConfirmed)
    }

    @Test func resultOrStartedCallbackConfirmsClassicScanning() {
        for evidence in [ClassicInquiryPolicy.Evidence.result, .startedCallback] {
            var policy = ClassicInquiryPolicy()
            policy.beginInquiry()
            #expect(policy.observe(.gracePeriodElapsed) == true)
            #expect(policy.observe(evidence) == true)
            #expect(policy.readiness == .confirmed)
            #expect(policy.observe(.result) == false)
        }
    }

    @Test func confirmationSurvivesRoutineCyclesButNotReset() {
        var policy = ClassicInquiryPolicy()
        policy.beginInquiry()
        policy.observe(.result)
        #expect(policy.complete(error: cycleEnd, aborted: false) == .continueAfterGap)
        policy.beginInquiry()
        #expect(policy.readiness == .confirmed)
        #expect(policy.observe(.gracePeriodElapsed) == false)
        policy.reset()
        #expect(policy.readiness == .waiting)
    }

    @Test func synchronousStartFailureResetsPriorClassicConfirmation() {
        var policy = ClassicInquiryPolicy()
        policy.beginInquiry()
        policy.observe(.result)
        #expect(policy.isClassicConfirmed)

        policy.beginInquiry()
        policy.reset()
        #expect(policy.readiness == .waiting)
        #expect(!policy.isClassicConfirmed)
    }

    @Test func inquiryCreationFailureClearsPriorClassicConfirmation() {
        var policy = ClassicInquiryPolicy()
        policy.beginInquiry()
        policy.observe(.result)
        #expect(policy.readiness == .confirmed)

        policy.beginInquiry()
        policy.inquiryCreationFailed()
        #expect(policy.readiness == .waiting)
        #expect(!policy.isClassicConfirmed)
        #expect(policy.consecutiveUnstartedFailures == 0)
    }

    @Test func observedCycleEndAfterLiveContinues() {
        var policy = ClassicInquiryPolicy()
        policy.beginInquiry()
        policy.observe(.gracePeriodElapsed)
        #expect(policy.complete(error: cycleEnd, aborted: false) == .continueAfterGap)
        #expect(!policy.isInquiryLive)
    }

    @Test func otherFailureAfterLiveIsSurfacedImmediately() {
        for evidence in [ClassicInquiryPolicy.Evidence.gracePeriodElapsed, .result] {
            var policy = ClassicInquiryPolicy()
            policy.beginInquiry()
            policy.observe(evidence)
            #expect(policy.complete(error: ioReturnError, aborted: false) == .fail(ioReturnError))
            policy.beginInquiry()
            policy.observe(evidence)
            #expect(policy.complete(error: 2, aborted: false) == .fail(2))
        }
    }

    @Test func successAndAbortContinue() {
        var policy = ClassicInquiryPolicy()
        policy.beginInquiry()
        #expect(policy.complete(error: 0, aborted: false) == .continueAfterGap)
        policy.beginInquiry()
        #expect(policy.complete(error: ioReturnError, aborted: true) == .continueAfterGap)
        #expect(policy.consecutiveUnstartedFailures == 0)
    }

    @Test func failuresBeforeGoingLiveRetryBoundedThenSurface() {
        var policy = ClassicInquiryPolicy(maxUnstartedFailures: 3)
        for code in [cycleEnd, ioReturnError] {
            policy.beginInquiry()
            #expect(policy.complete(error: code, aborted: false) == .retryAfterGap)
        }
        policy.beginInquiry()
        #expect(policy.complete(error: cycleEnd, aborted: false) == .fail(cycleEnd))
        #expect(policy.consecutiveUnstartedFailures == 0)
    }

    @Test func goingLiveResetsUnstartedFailureCount() {
        var policy = ClassicInquiryPolicy(maxUnstartedFailures: 2)
        policy.beginInquiry()
        #expect(policy.complete(error: cycleEnd, aborted: false) == .retryAfterGap)
        policy.beginInquiry()
        policy.observe(.gracePeriodElapsed)
        #expect(policy.consecutiveUnstartedFailures == 0)
        #expect(policy.complete(error: cycleEnd, aborted: false) == .continueAfterGap)
        policy.beginInquiry()
        #expect(policy.complete(error: cycleEnd, aborted: false) == .retryAfterGap)
    }

    /// Mirrors how AppModel maps scanner state: routine cycles only resume,
    /// while a surfaced failure interrupts and the retry starts a new quiet baseline.
    @Test func cycleRestartsKeepBaselineButSurfacedFailureRebaselines() {
        var session = DiscoverySession()
        var policy = ClassicInquiryPolicy()
        let early = DiscoveredDevice(id: DeviceIdentity(transport: .classic, identifier: "aa:aa:aa:aa:aa:aa"))
        let late = DiscoveredDevice(id: DeviceIdentity(transport: .classic, identifier: "bb:bb:bb:bb:bb:bb"))

        policy.beginInquiry()
        policy.observe(.gracePeriodElapsed)
        session.resume(at: 0)
        #expect(session.discover(early, at: 3) == false)
        #expect(policy.complete(error: cycleEnd, aborted: false) == .continueAfterGap)
        policy.beginInquiry()
        policy.observe(.result)
        session.resume(at: 7)
        #expect(session.discover(late, at: 10) == true)

        #expect(policy.complete(error: ioReturnError, aborted: false) == .fail(ioReturnError))
        session.interrupt(at: 20)
        #expect(!session.isScanning)
        session.resume(at: 30)
        let during = DiscoveredDevice(id: DeviceIdentity(transport: .classic, identifier: "cc:cc:cc:cc:cc:cc"))
        #expect(session.discover(during, at: 31) == false)
        #expect(session.discover(late, at: 41) == false)
        #expect(session.discover(early, at: 41) == false)
    }
}
