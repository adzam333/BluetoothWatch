import XCTest
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

final class PairingControllerTests: XCTestCase {
    private func device(_ id: String, transport: BluetoothTransport = .classic) -> DiscoveredDevice {
        DiscoveredDevice(id: DeviceIdentity(transport: transport, identifier: id), name: "Mouse")
    }

    func testPairRoutesExactIdentityAndWaitsForActualSuccess() async {
        await MainActor.run {
            let driver = FakePairingDriver()
            let controller = PairingController(driver: driver, openSettings: { _ in
                XCTFail("Supported Classic device must use direct pairing")
                return false
            })
            let mouse = device("aa:bb:cc:dd:ee:ff")
            XCTAssertTrue(controller.pair(mouse))
            XCTAssertEqual(driver.devices, [mouse])
            XCTAssertEqual(controller.statuses[mouse.id], .pairing)
            XCTAssertEqual(controller.activeDeviceID, mouse.id)
            driver.completions[0](.paired)
            XCTAssertEqual(controller.statuses[mouse.id], .paired)
            XCTAssertNil(controller.activeDeviceID)
        }
    }

    func testBLEAlwaysOpensSettingsAndNeverClaimsPaired() async {
        await MainActor.run {
            let driver = FakePairingDriver()
            var opened: [DeviceIdentity] = []
            let controller = PairingController(driver: driver) { device in
                opened.append(device.id)
                return true
            }
            let mouse = device("ble-uuid", transport: .lowEnergy)
            XCTAssertTrue(controller.pair(mouse))
            XCTAssertEqual(opened, [mouse.id])
            XCTAssertTrue(driver.devices.isEmpty)
            XCTAssertEqual(controller.statuses[mouse.id], .settingsOpened)
            XCTAssertNil(controller.activeDeviceID)
        }
    }

    func testUnsupportedClassicFallsBackAndReportsSettingsFailure() async {
        await MainActor.run {
            let driver = FakePairingDriver()
            driver.supported = false
            var target: DiscoveredDevice?
            let controller = PairingController(driver: driver) { device in
                target = device
                return false
            }
            let mouse = device("aa")
            XCTAssertTrue(controller.pair(mouse))
            XCTAssertEqual(target, mouse)
            XCTAssertTrue(driver.devices.isEmpty)
            XCTAssertEqual(controller.statuses[mouse.id], .failed("Could not open Bluetooth settings."))
        }
    }

    func testDuplicateAndConcurrentAttemptsAreRejected() async {
        await MainActor.run {
            let driver = FakePairingDriver()
            let controller = PairingController(driver: driver, openSettings: { _ in true })
            let first = device("a")
            let sameNameOtherDevice = device("b")
            XCTAssertTrue(controller.pair(first))
            XCTAssertFalse(controller.pair(first))
            XCTAssertFalse(controller.pair(sameNameOtherDevice))
            XCTAssertEqual(driver.devices, [first])
            XCTAssertNil(controller.statuses[sameNameOtherDevice.id])
        }
    }

    func testFailureIsReportedWithoutAutomaticRetryOrSettingsHandoff() async {
        await MainActor.run {
            let driver = FakePairingDriver()
            let controller = PairingController(driver: driver, openSettings: { _ in
                XCTFail("Failures must be shown before an explicit settings action")
                return true
            })
            let mouse = device("a")
            XCTAssertTrue(controller.pair(mouse))
            driver.completions[0](.failed("Device is no longer discoverable"))
            XCTAssertEqual(controller.statuses[mouse.id], .failed("Device is no longer discoverable"))
            XCTAssertNil(controller.activeDeviceID)
            XCTAssertEqual(driver.devices.count, 1)
        }
    }

    func testCancellationStopsDriverAndDiscardsStaleCompletion() async {
        await MainActor.run {
            let driver = FakePairingDriver()
            let controller = PairingController(driver: driver, openSettings: { _ in true })
            let first = device("a")
            let second = device("b")
            XCTAssertTrue(controller.pair(first))
            controller.cancel()
            XCTAssertEqual(driver.cancellations, 1)
            XCTAssertEqual(controller.statuses[first.id], .cancelled)
            XCTAssertNil(controller.activeDeviceID)
            XCTAssertTrue(controller.pair(second))
            driver.completions[0](.paired)
            XCTAssertEqual(controller.statuses[first.id], .cancelled)
            XCTAssertEqual(controller.activeDeviceID, second.id)
            XCTAssertEqual(controller.statuses[second.id], .pairing)
            driver.completions[1](.cancelled)
            XCTAssertEqual(controller.statuses[second.id], .cancelled)
            XCTAssertNil(controller.activeDeviceID)
        }
    }
}
