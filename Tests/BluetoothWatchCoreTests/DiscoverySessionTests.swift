import Testing
@testable import BluetoothWatchCore

struct DiscoverySessionTests {
    private func device(_ identifier: String, name: String = "Mouse") -> DiscoveredDevice {
        DiscoveredDevice(
            id: DeviceIdentity(transport: .lowEnergy, identifier: identifier),
            name: name
        )
    }

    @Test func testStartupDevicesStaySilentWhenTheyReturn() {
        var session = DiscoverySession()
        session.resume(at: 100)
        let mouse = device("a")
        #expect(session.discover(mouse, at: 101) == false)
        #expect(session.discover(mouse, at: 150) == false)
        #expect(session.records[mouse.id]?.origin == .baseline)
        #expect(session.baselineIsComplete)
    }

    @Test func testExactlyTenSecondsDefinesTheBoundaryWithoutTimerTick() {
        var session = DiscoverySession()
        session.resume(at: 100)
        #expect(session.discover(device("before"), at: 109.999) == false)
        #expect(session.discover(device("at"), at: 110) == true)
        #expect(session.discover(device("after"), at: 110.001) == true)
        #expect(session.records[device("before").id]?.origin == .baseline)
        #expect(session.records[device("at").id]?.origin == .newlyDiscovered)
        #expect(session.baselineSecondsRemaining(at: 110) == 0)
    }

    @Test func testNewDeviceAlertsOnceAndUpdatesItsDetails() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let unnamed = DiscoveredDevice(id: device("a").id, rssi: -70)
        #expect(session.discover(unnamed, at: 11) == false)
        let named = DiscoveredDevice(id: unnamed.id, name: "Travel Mouse", rssi: -40)
        #expect(session.discover(named, at: 12) == true)
        #expect(session.discover(named, at: 13) == false)
        #expect(session.discover(unnamed, at: 14) == false)
        #expect(session.records[unnamed.id]?.device.name == "Travel Mouse")
        #expect(session.records[unnamed.id]?.device.rssi == -70)
        #expect(session.records[unnamed.id]?.firstSeen == 11)
        #expect(session.records[unnamed.id]?.lastSeen == 14)
    }

    @Test func testAnonymousBLEIsListedButNeverAlerts() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let anonymous = device("rotating", name: "  ")
        #expect(session.discover(anonymous, at: 11) == false)
        #expect(session.discover(anonymous, at: 30) == false)
        #expect(session.records[anonymous.id]?.origin == .newlyDiscovered)
    }

    @Test func testUnnamedClassicStillAlerts() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let classic = DiscoveredDevice(id: DeviceIdentity(transport: .classic, identifier: "aa-bb-cc-dd-ee-ff"))
        #expect(session.discover(classic, at: 11) == true)
        #expect(session.discover(classic, at: 12) == false)
    }

    @Test func testBaselineOrIgnoredDevicesDoNotAlertWhenNameArrives() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let early = DiscoveredDevice(id: device("early").id)
        #expect(session.discover(early, at: 1) == false)
        #expect(session.discover(device("early"), at: 20) == false)

        let hidden = DiscoveredDevice(id: device("hidden").id)
        #expect(session.discover(hidden, at: 21) == false)
        session.setIgnored(true, for: hidden.id)
        #expect(session.discover(device("hidden"), at: 22) == false)
    }

    @Test func testEqualNamesDoNotMergeDifferentDevicesOrTransports() {
        var session = DiscoverySession()
        session.resume(at: 0)
        #expect(session.discover(device("a"), at: 10) == true)
        #expect(session.discover(device("b"), at: 10) == true)
        let classic = DiscoveredDevice(
            id: DeviceIdentity(transport: .classic, identifier: "a"), name: "Mouse"
        )
        #expect(session.discover(classic, at: 10) == true)
        #expect(session.records.count == 3)
    }

    @Test func testClassicAddressFormatsReferToOneDeviceWithoutChangingBLEIdentifiers() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let dashed = DiscoveredDevice(
            id: DeviceIdentity(transport: .classic, identifier: "AA-BB-CC-DD-EE-FF")
        )
        let colon = DiscoveredDevice(
            id: DeviceIdentity(transport: .classic, identifier: "aa:bb:cc:dd:ee:ff")
        )
        #expect(session.discover(dashed, at: 11) == true)
        #expect(session.discover(colon, at: 12) == false)
        #expect(session.records.count == 1)
        #expect(dashed.id.identifier == "aa:bb:cc:dd:ee:ff")
        let ble = DeviceIdentity(transport: .lowEnergy, identifier: "ABCD-1234")
        #expect(ble.identifier == "abcd-1234")
    }

    @Test func testBaselineCountsOnlyActiveTimeAcrossPause() {
        var session = DiscoverySession()
        session.resume(at: 20)
        session.pause(at: 24)
        #expect(session.baselineSecondsRemaining(at: 90) == 6)
        #expect(session.discover(device("not-scanned"), at: 50) == false)
        #expect(session.records.isEmpty)
        session.resume(at: 100)
        #expect(session.discover(device("before"), at: 105.999) == false)
        #expect(session.discover(device("at"), at: 106) == true)
    }

    @Test func testPauseAfterBaselineDoesNotCreateAnotherBaseline() {
        var session = DiscoverySession()
        session.resume(at: 0)
        #expect(session.discover(device("first"), at: 11) == true)
        session.pause(at: 12)
        session.resume(at: 100)
        #expect(session.discover(device("second"), at: 100) == true)
        #expect(session.discover(device("first"), at: 101) == false)
    }

    @Test func testIgnoreAndUndoNeverRealertOrEraseIdentity() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let mouse = device("a")
        #expect(session.discover(mouse, at: 11) == true)
        session.setIgnored(true, for: mouse.id)
        #expect(session.records[mouse.id]?.isIgnored == true)
        #expect(session.discover(mouse, at: 12) == false)
        #expect(session.records[mouse.id]?.isIgnored == true)
        session.setIgnored(false, for: mouse.id)
        #expect(session.records[mouse.id]?.isIgnored == false)
        #expect(session.discover(mouse, at: 13) == false)
    }

    @Test func testIgnoreConsumesPendingDelayedNameAlertAcrossUndo() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let anonymous = DiscoveredDevice(id: device("ignored-late-name").id)
        #expect(session.discover(anonymous, at: 11) == false)

        session.setIgnored(true, for: anonymous.id)
        #expect(session.discover(device("ignored-late-name"), at: 12) == false)
        session.setIgnored(false, for: anonymous.id)
        #expect(session.discover(device("ignored-late-name"), at: 13) == false)
    }

    @Test func testRestartClearsIgnoredAndBaselineHistory() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let mouse = device("a")
        #expect(session.discover(mouse, at: 11) == true)
        session.setIgnored(true, for: mouse.id)
        session = DiscoverySession()
        #expect(session.records.isEmpty)
        #expect(!(session.baselineIsComplete))
        session.resume(at: 100)
        #expect(session.discover(mouse, at: 101) == false)
        #expect(session.records[mouse.id]?.isIgnored == false)
        #expect(session.records[mouse.id]?.origin == .baseline)
    }

    @Test func testInterruptionRebaselinesButPreservesSeenExclusions() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let old = device("old")
        #expect(session.discover(old, at: 11) == true)
        session.setIgnored(true, for: old.id)
        session.interrupt(at: 20)
        #expect(!(session.isScanning))
        #expect(!(session.baselineIsComplete))
        session.resume(at: 50)
        #expect(session.discover(device("during-gap"), at: 51) == false)
        #expect(session.discover(old, at: 61) == false)
        #expect(session.discover(device("during-gap"), at: 62) == false)
        #expect(session.discover(device("new"), at: 63) == true)
        #expect(session.records[old.id]?.isIgnored == true)
    }

    @Test func testInterruptionConsumesPendingDelayedNameAlert() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let anonymous = DiscoveredDevice(id: device("late-name").id)
        #expect(session.discover(anonymous, at: 11) == false)
        #expect(session.records[anonymous.id]?.origin == .newlyDiscovered)

        session.interrupt(at: 12)
        session.resume(at: 100)
        #expect(session.discover(device("late-name"), at: 101) == false)
        #expect(!(session.baselineIsComplete))
        #expect(session.discover(device("late-name"), at: 110) == false)
        #expect(session.records[anonymous.id]?.wasAlerted == true)
    }

    @Test func testRepeatedResumeDoesNotResetBaselineClock() {
        var session = DiscoverySession()
        session.resume(at: 0)
        session.resume(at: 9)
        #expect(session.discover(device("a"), at: 10) == true)
    }
}
