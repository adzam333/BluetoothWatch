import Testing
@testable import BluetoothWatchCore

@MainActor
private final class FakePairingDriver: PairingDriver {
    var supported = true
    var devices: [DiscoveredDevice] = []
    var completions: [(PairingResult) -> Void] = []
    var cancellations = 0

    func canPair(_ device: DiscoveredDevice) -> Bool { supported }
    func startPairing(_ device: DiscoveredDevice, completion: @escaping (PairingResult) -> Void) {
        devices.append(device)
        completions.append(completion)
    }
    func cancelPairing() { cancellations += 1 }
}

struct PairingControllerTests {
    private func device(_ id: String, transport: BluetoothTransport = .classic) -> DiscoveredDevice {
        DiscoveredDevice(id: DeviceIdentity(transport: transport, identifier: id), name: "Mouse")
    }

    @Test func testPairRoutesExactIdentityAndWaitsForActualSuccess() async {
        await MainActor.run {
            let driver = FakePairingDriver()
            let controller = PairingController(driver: driver, openSettings: { _ in
                Issue.record("Supported Classic device must use direct pairing")
                return false
            })
            let mouse = device("aa:bb:cc:dd:ee:ff")
            #expect(controller.pair(mouse))
            #expect(driver.devices == [mouse])
            #expect(controller.statuses[mouse.id] == .pairing)
            #expect(controller.activeDeviceID == mouse.id)
            driver.completions[0](.paired)
            #expect(controller.statuses[mouse.id] == .paired)
            #expect(controller.activeDeviceID == nil)
        }
    }

    @Test func testBLEAlwaysOpensSettingsAndNeverClaimsPaired() async {
        await MainActor.run {
            let driver = FakePairingDriver()
            var opened: [DeviceIdentity] = []
            let controller = PairingController(driver: driver) { device in
                opened.append(device.id)
                return true
            }
            let mouse = device("ble-uuid", transport: .lowEnergy)
            #expect(controller.pair(mouse))
            #expect(opened == [mouse.id])
            #expect(driver.devices.isEmpty)
            #expect(controller.statuses[mouse.id] == .settingsOpened)
            #expect(controller.activeDeviceID == nil)
        }
    }

    @Test func testUnsupportedClassicFallsBackAndReportsSettingsFailure() async {
        await MainActor.run {
            let driver = FakePairingDriver()
            driver.supported = false
            var target: DiscoveredDevice?
            let controller = PairingController(driver: driver) { device in
                target = device
                return false
            }
            let mouse = device("aa")
            #expect(controller.pair(mouse))
            #expect(target == mouse)
            #expect(driver.devices.isEmpty)
            #expect(controller.statuses[mouse.id] == .failed("Could not open Bluetooth settings."))
        }
    }

    @Test func testDuplicateAndConcurrentAttemptsAreRejected() async {
        await MainActor.run {
            let driver = FakePairingDriver()
            let controller = PairingController(driver: driver, openSettings: { _ in true })
            let first = device("a")
            let sameNameOtherDevice = device("b")
            #expect(controller.pair(first))
            #expect(!(controller.pair(first)))
            #expect(!(controller.pair(sameNameOtherDevice)))
            #expect(driver.devices == [first])
            #expect(controller.statuses[sameNameOtherDevice.id] == nil)
        }
    }

    @Test func testFailureIsReportedWithoutAutomaticRetryOrSettingsHandoff() async {
        await MainActor.run {
            let driver = FakePairingDriver()
            let controller = PairingController(driver: driver, openSettings: { _ in
                Issue.record("Failures must be shown before an explicit settings action")
                return true
            })
            let mouse = device("a")
            #expect(controller.pair(mouse))
            driver.completions[0](.failed("Device is no longer discoverable"))
            #expect(controller.statuses[mouse.id] == .failed("Device is no longer discoverable"))
            #expect(controller.activeDeviceID == nil)
            #expect(driver.devices.count == 1)
        }
    }

    @Test func testCancellationStopsDriverAndDiscardsStaleCompletion() async {
        await MainActor.run {
            let driver = FakePairingDriver()
            let controller = PairingController(driver: driver, openSettings: { _ in true })
            let first = device("a")
            let second = device("b")
            #expect(controller.pair(first))
            controller.cancel()
            #expect(driver.cancellations == 1)
            #expect(controller.statuses[first.id] == .cancelled)
            #expect(controller.activeDeviceID == nil)
            #expect(controller.pair(second))
            driver.completions[0](.paired)
            #expect(controller.statuses[first.id] == .cancelled)
            #expect(controller.activeDeviceID == second.id)
            #expect(controller.statuses[second.id] == .pairing)
            driver.completions[1](.cancelled)
            #expect(controller.statuses[second.id] == .cancelled)
            #expect(controller.activeDeviceID == nil)
        }
    }

    @Test func testBLEUsesLEDriverAndOnlyPairsOnReportedSuccess() async {
        await MainActor.run {
            let classic = FakePairingDriver()
            let le = FakePairingDriver()
            let controller = PairingController(driver: classic, leDriver: le, openSettings: { _ in
                Issue.record("A paired LE device must not open settings")
                return true
            })
            let sensor = device("ble-uuid", transport: .lowEnergy)
            #expect(controller.pair(sensor))
            #expect(classic.devices.isEmpty)
            #expect(le.devices == [sensor])
            #expect(controller.statuses[sensor.id] == .pairing)
            #expect(controller.activeDeviceID == sensor.id)
            le.completions[0](.paired)
            #expect(controller.statuses[sensor.id] == .paired)
            #expect(controller.activeDeviceID == nil)
        }
    }

    @Test func testBLESettingsRequiredOpensSettingsWithReason() async {
        await MainActor.run {
            let le = FakePairingDriver()
            var opened: [DeviceIdentity] = []
            let controller = PairingController(driver: FakePairingDriver(), leDriver: le) { device in
                opened.append(device.id)
                return true
            }
            let mouse = device("ble-uuid", transport: .lowEnergy)
            #expect(controller.pair(mouse))
            #expect(opened.isEmpty)
            le.completions[0](.settingsRequired("No pairing prompt."))
            #expect(opened == [mouse.id])
            #expect(controller.statuses[mouse.id] == .settingsFallback("No pairing prompt."))
            #expect(controller.activeDeviceID == nil)
        }
    }

    @Test func testBLESettingsRequiredReportsWhenSettingsCannotOpen() async {
        await MainActor.run {
            let le = FakePairingDriver()
            let controller = PairingController(driver: FakePairingDriver(), leDriver: le, openSettings: { _ in false })
            let mouse = device("ble-uuid", transport: .lowEnergy)
            #expect(controller.pair(mouse))
            le.completions[0](.settingsRequired("No pairing prompt."))
            #expect(controller.statuses[mouse.id] == .failed("No pairing prompt. Could not open Bluetooth settings."))
        }
    }

    @Test func testUnsupportedBLEFallsBackWithoutStartingLEDriver() async {
        await MainActor.run {
            let le = FakePairingDriver()
            le.supported = false
            var opened = 0
            let controller = PairingController(driver: FakePairingDriver(), leDriver: le) { _ in
                opened += 1
                return true
            }
            let mouse = device("not-a-uuid", transport: .lowEnergy)
            #expect(controller.pair(mouse))
            #expect(le.devices.isEmpty)
            #expect(opened == 1)
            #expect(controller.statuses[mouse.id] == .settingsOpened)
        }
    }

    @Test func testCancellingBLECancelsOnlyLEDriverAndIgnoresLateResult() async {
        await MainActor.run {
            let classic = FakePairingDriver()
            let le = FakePairingDriver()
            let controller = PairingController(driver: classic, leDriver: le, openSettings: { _ in
                Issue.record("A cancelled attempt must not open settings")
                return true
            })
            let sensor = device("ble-uuid", transport: .lowEnergy)
            #expect(controller.pair(sensor))
            #expect(!controller.pair(device("aa:bb:cc:dd:ee:ff")))
            controller.cancel()
            #expect(le.cancellations == 1)
            #expect(classic.cancellations == 0)
            le.completions[0](.settingsRequired("late"))
            #expect(controller.statuses[sensor.id] == .cancelled)
            #expect(controller.activeDeviceID == nil)
        }
    }
}
