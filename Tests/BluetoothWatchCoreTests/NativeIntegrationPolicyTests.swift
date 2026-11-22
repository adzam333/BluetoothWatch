import Testing
@testable import BluetoothWatchCore

struct NativeIntegrationPolicyTests {
    @Test func stopInvalidatesCallbacksFromPriorInquiryGeneration() {
        var generation = DiscoveryCallbackGeneration()
        let inquiryGeneration = generation.advance()
        #expect(generation.accepts(inquiryGeneration))

        generation.advance()
        #expect(!generation.accepts(inquiryGeneration))
        let retryGeneration = generation.advance()
        #expect(generation.accepts(retryGeneration))
        #expect(!generation.accepts(inquiryGeneration))
    }

    @Test func inquiryFailureAndRetryRestartTheQuietBaseline() {
        var session = DiscoverySession()
        let known = DiscoveredDevice(
            id: DeviceIdentity(transport: .classic, identifier: "aa:bb:cc:dd:ee:ff"),
            name: "Keyboard"
        )
        session.updateScannerState(isRunning: true, isPaused: false, isAsleep: false, at: 0)
        #expect(session.discover(known, at: 11) == true)
        #expect(session.baselineIsComplete)

        session.updateScannerState(isRunning: false, isPaused: false, isAsleep: false, at: 20)
        #expect(!session.isScanning)
        #expect(!session.baselineIsComplete)
        session.updateScannerState(isRunning: true, isPaused: false, isAsleep: false, at: 30)
        #expect(!session.baselineIsComplete)
        #expect(session.discover(known, at: 31) == false)
        #expect(session.discover(known, at: 40) == false)
        let newDevice = DiscoveredDevice(
            id: DeviceIdentity(transport: .classic, identifier: "bb:cc:dd:ee:ff:00"),
            name: "New keyboard"
        )
        #expect(session.discover(newDevice, at: 41) == true)
    }

    @Test func permissionRecoveryRecreatesOnlyDeniedManager() {
        #expect(BluetoothAvailability.denied.shouldRecreateAfterSettings)
        #expect(!BluetoothAvailability.ready.shouldRecreateAfterSettings)
        #expect(!BluetoothAvailability.poweredOff.shouldRecreateAfterSettings)
        #expect(!BluetoothAvailability.unsupported.shouldRecreateAfterSettings)
        #expect(!BluetoothAvailability.resetting.shouldRecreateAfterSettings)
        #expect(!BluetoothAvailability.unknown.shouldRecreateAfterSettings)
    }

    @Test func startingWhileInquiryIsWaitingDoesNotInvalidateItsGeneration() {
        #expect(!BluetoothAvailability.ready.shouldHandleOnStart(
            isRunning: false, hasActiveInquiry: true
        ))
        #expect(BluetoothAvailability.ready.shouldHandleOnStart(
            isRunning: false, hasActiveInquiry: false
        ))
        #expect(!BluetoothAvailability.ready.shouldHandleOnStart(
            isRunning: true, hasActiveInquiry: true
        ))
        #expect(BluetoothAvailability.poweredOff.shouldHandleOnStart(
            isRunning: false, hasActiveInquiry: true
        ))
    }

    @Test func notificationFromEarlierRunCannotRouteToCurrentDevice() {
        let device = DeviceIdentity(transport: .classic, identifier: "aa:bb:cc:dd:ee:ff")
        #expect(NotificationRoute.resolve(
            notificationRunID: "previous",
            currentRunID: "current",
            notificationIdentifier: device.notificationIdentifier,
            currentDevices: [device]
        ) == .earlierRun)
    }

    @Test func currentNotificationRoutesExactClassicIdentityWithColons() {
        let device = DeviceIdentity(transport: .classic, identifier: "aa:bb:cc:dd:ee:ff")
        #expect(NotificationRoute.resolve(
            notificationRunID: "current",
            currentRunID: "current",
            notificationIdentifier: device.notificationIdentifier,
            currentDevices: [device]
        ) == .device(device))
    }

    @Test func notificationForMissingOrMalformedDeviceIsRejected() {
        let known = DeviceIdentity(transport: .lowEnergy, identifier: "sensor")
        #expect(NotificationRoute.resolve(
            notificationRunID: "current",
            currentRunID: "current",
            notificationIdentifier: "lowEnergy:other",
            currentDevices: [known]
        ) == .unknownDevice)
        #expect(NotificationRoute.resolve(
            notificationRunID: "current",
            currentRunID: "current",
            notificationIdentifier: "unknown:sensor",
            currentDevices: [known]
        ) == .unknownDevice)
        #expect(NotificationRoute.resolve(
            notificationRunID: "current",
            currentRunID: "current",
            notificationIdentifier: "lowEnergy:",
            currentDevices: [known]
        ) == .unknownDevice)
    }
}
