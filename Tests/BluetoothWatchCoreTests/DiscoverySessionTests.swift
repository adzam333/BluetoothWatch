import XCTest
@testable import BluetoothWatchCore

final class DiscoverySessionTests: XCTestCase {
    private func device(_ identifier: String, name: String = "Mouse") -> DiscoveredDevice {
        DiscoveredDevice(
            id: DeviceIdentity(transport: .lowEnergy, identifier: identifier),
            name: name
        )
    }

    func testStartupDevicesStaySilentWhenTheyReturn() {
        var session = DiscoverySession()
        session.resume(at: 100)
        let mouse = device("a")
        XCTAssertFalse(session.discover(mouse, at: 101))
        XCTAssertFalse(session.discover(mouse, at: 150))
        XCTAssertEqual(session.records[mouse.id]?.origin, .baseline)
        XCTAssertTrue(session.baselineIsComplete)
    }

    func testExactlyTenSecondsDefinesTheBoundaryWithoutTimerTick() {
        var session = DiscoverySession()
        session.resume(at: 100)
        XCTAssertFalse(session.discover(device("before"), at: 109.999))
        XCTAssertTrue(session.discover(device("at"), at: 110))
        XCTAssertTrue(session.discover(device("after"), at: 110.001))
        XCTAssertEqual(session.records[device("before").id]?.origin, .baseline)
        XCTAssertEqual(session.records[device("at").id]?.origin, .newlyDiscovered)
        XCTAssertEqual(session.baselineSecondsRemaining(at: 110), 0)
    }

    func testNewDeviceAlertsOnceAndUpdatesItsDetails() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let unnamed = DiscoveredDevice(id: device("a").id, rssi: -70)
        XCTAssertTrue(session.discover(unnamed, at: 11))
        let named = DiscoveredDevice(id: unnamed.id, name: "Travel Mouse", rssi: -40)
        XCTAssertFalse(session.discover(named, at: 12))
        XCTAssertEqual(session.records[unnamed.id]?.device.name, "Travel Mouse")
        XCTAssertEqual(session.records[unnamed.id]?.device.rssi, -40)
        XCTAssertEqual(session.records[unnamed.id]?.firstSeen, 11)
        XCTAssertEqual(session.records[unnamed.id]?.lastSeen, 12)
    }

    func testEqualNamesDoNotMergeDifferentDevicesOrTransports() {
        var session = DiscoverySession()
        session.resume(at: 0)
        XCTAssertTrue(session.discover(device("a"), at: 10))
        XCTAssertTrue(session.discover(device("b"), at: 10))
        let classic = DiscoveredDevice(
            id: DeviceIdentity(transport: .classic, identifier: "a"), name: "Mouse"
        )
        XCTAssertTrue(session.discover(classic, at: 10))
        XCTAssertEqual(session.records.count, 3)
    }

    func testClassicAddressFormatsReferToOneDeviceWithoutChangingBLEIdentifiers() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let dashed = DiscoveredDevice(
            id: DeviceIdentity(transport: .classic, identifier: "AA-BB-CC-DD-EE-FF")
        )
        let colon = DiscoveredDevice(
            id: DeviceIdentity(transport: .classic, identifier: "aa:bb:cc:dd:ee:ff")
        )
        XCTAssertTrue(session.discover(dashed, at: 11))
        XCTAssertFalse(session.discover(colon, at: 12))
        XCTAssertEqual(session.records.count, 1)
        XCTAssertEqual(dashed.id.identifier, "aa:bb:cc:dd:ee:ff")
        let ble = DeviceIdentity(transport: .lowEnergy, identifier: "ABCD-1234")
        XCTAssertEqual(ble.identifier, "abcd-1234")
    }

    func testBaselineCountsOnlyActiveTimeAcrossPause() {
        var session = DiscoverySession()
        session.resume(at: 20)
        session.pause(at: 24)
        XCTAssertEqual(session.baselineSecondsRemaining(at: 90), 6)
        XCTAssertFalse(session.discover(device("not-scanned"), at: 50))
        XCTAssertTrue(session.records.isEmpty)
        session.resume(at: 100)
        XCTAssertFalse(session.discover(device("before"), at: 105.999))
        XCTAssertTrue(session.discover(device("at"), at: 106))
    }

    func testPauseAfterBaselineDoesNotCreateAnotherBaseline() {
        var session = DiscoverySession()
        session.resume(at: 0)
        XCTAssertTrue(session.discover(device("first"), at: 11))
        session.pause(at: 12)
        session.resume(at: 100)
        XCTAssertTrue(session.discover(device("second"), at: 100))
        XCTAssertFalse(session.discover(device("first"), at: 101))
    }

    func testIgnoreAndUndoNeverRealertOrEraseIdentity() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let mouse = device("a")
        XCTAssertTrue(session.discover(mouse, at: 11))
        session.setIgnored(true, for: mouse.id)
        XCTAssertTrue(session.records[mouse.id]?.isIgnored == true)
        XCTAssertFalse(session.discover(mouse, at: 12))
        XCTAssertTrue(session.records[mouse.id]?.isIgnored == true)
        session.setIgnored(false, for: mouse.id)
        XCTAssertTrue(session.records[mouse.id]?.isIgnored == false)
        XCTAssertFalse(session.discover(mouse, at: 13))
    }

    func testRestartClearsIgnoredAndBaselineHistory() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let mouse = device("a")
        XCTAssertTrue(session.discover(mouse, at: 11))
        session.setIgnored(true, for: mouse.id)
        session = DiscoverySession()
        XCTAssertTrue(session.records.isEmpty)
        XCTAssertFalse(session.baselineIsComplete)
        session.resume(at: 100)
        XCTAssertFalse(session.discover(mouse, at: 101))
        XCTAssertTrue(session.records[mouse.id]?.isIgnored == false)
        XCTAssertEqual(session.records[mouse.id]?.origin, .baseline)
    }

    func testInterruptionRebaselinesButPreservesSeenExclusions() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let old = device("old")
        XCTAssertTrue(session.discover(old, at: 11))
        session.setIgnored(true, for: old.id)
        session.interrupt(at: 20)
        XCTAssertFalse(session.isScanning)
        XCTAssertFalse(session.baselineIsComplete)
        session.resume(at: 50)
        XCTAssertFalse(session.discover(device("during-gap"), at: 51))
        XCTAssertFalse(session.discover(old, at: 61))
        XCTAssertFalse(session.discover(device("during-gap"), at: 62))
        XCTAssertTrue(session.discover(device("new"), at: 63))
        XCTAssertTrue(session.records[old.id]?.isIgnored == true)
    }

    func testRepeatedResumeDoesNotResetBaselineClock() {
        var session = DiscoverySession()
        session.resume(at: 0)
        session.resume(at: 9)
        XCTAssertTrue(session.discover(device("a"), at: 10))
    }
}
