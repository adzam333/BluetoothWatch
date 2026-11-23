import Testing
@testable import BluetoothWatchCore

struct DeviceListSectionsTests {
    private func device(
        _ id: String,
        transport: BluetoothTransport = .lowEnergy,
        name: String? = nil
    ) -> DiscoveredDevice {
        DiscoveredDevice(id: DeviceIdentity(transport: transport, identifier: id), name: name)
    }

    @Test func hidesUnnamedDevicesInBothSectionsForBothTransports() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let unnamed = [
            device("ble-nil"),
            device("ble-empty", name: ""),
            device("ble-space", name: " \n\t"),
            device("classic-nil", transport: .classic),
            device("classic-empty", transport: .classic, name: ""),
            device("classic-space", transport: .classic, name: " \n\t")
        ]
        let named = device("named", name: "Sensor")
        let ignored = device("ignored", transport: .classic, name: "Keyboard")
        for item in unnamed + [named, ignored] {
            session.discover(item, at: 1)
        }
        for item in unnamed where item.id.identifier.contains("empty") {
            session.setIgnored(true, for: item.id)
        }
        session.setIgnored(true, for: ignored.id)

        let sections = DeviceListSections(records: Array(session.records.values))
        #expect(sections.visible.map(\.id) == [named.id])
        #expect(sections.ignored.map(\.id) == [ignored.id])
        #expect(session.records.count == unnamed.count + 2)
    }

    @Test func lateNameShowsDeviceWithoutChangingBaselineOrIgnoredState() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let baseline = device("baseline")
        let ignored = device("ignored")
        let new = device("new")
        #expect(session.discover(baseline, at: 1) == false)
        #expect(session.discover(ignored, at: 11) == false)
        #expect(session.discover(new, at: 12) == false)
        session.setIgnored(true, for: ignored.id)
        var sections = DeviceListSections(records: Array(session.records.values))
        #expect(sections.visible.isEmpty)
        #expect(sections.ignored.isEmpty)

        #expect(session.discover(device("baseline", name: "Early"), at: 13) == false)
        #expect(session.discover(device("ignored", name: "Ignored"), at: 14) == false)
        #expect(session.discover(device("new", name: "New"), at: 15) == true)
        sections = DeviceListSections(records: Array(session.records.values))
        #expect(Set(sections.visible.map(\.id)) == [baseline.id, new.id])
        #expect(sections.ignored.map(\.id) == [ignored.id])
        #expect(session.records[baseline.id]?.origin == .baseline)
        #expect(session.records[baseline.id]?.firstSeen == 1)
        #expect(session.records[ignored.id]?.isIgnored == true)
        #expect(session.records[new.id]?.firstSeen == 12)
        #expect(session.discover(device("new", name: "New"), at: 16) == false)
    }

    @Test func unnamedClassicStillAlertsWithoutAppearingInTheList() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let classic = device("aa:bb:cc:dd:ee:ff", transport: .classic)
        #expect(session.discover(classic, at: 11) == true)
        let sections = DeviceListSections(records: Array(session.records.values))
        #expect(sections.visible.isEmpty)
        #expect(sections.ignored.isEmpty)
        #expect(session.records[classic.id]?.wasAlerted == true)
    }

    @Test func preservesInputOrderWithinEachSection() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let first = device("first", name: "First")
        let second = device("second", name: "Second")
        let ignored = device("ignored", name: "Ignored")
        for item in [first, second, ignored] {
            session.discover(item, at: 1)
        }
        session.setIgnored(true, for: ignored.id)
        let records = [session.records[second.id]!, session.records[ignored.id]!, session.records[first.id]!]
        let sections = DeviceListSections(records: records)
        #expect(sections.visible.map(\.id) == [second.id, first.id])
        #expect(sections.ignored.map(\.id) == [ignored.id])
    }

    @Test func filtersNamedDevicesByTransportAndIgnoredState() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let classic = device("aa:bb:cc:dd:ee:ff", transport: .classic, name: "Keyboard")
        let lowEnergy = device("sensor-uuid", name: "Sensor")
        let ignored = device("headset-uuid", transport: .lowEnergy, name: "Headset")
        for item in [classic, lowEnergy, ignored] {
            session.discover(item, at: 1)
        }
        session.setIgnored(true, for: ignored.id)
        let sections = DeviceListSections(records: Array(session.records.values))

        #expect(Set(DeviceListFilter.named.records(in: sections, matching: "").map(\.id)) == [classic.id, lowEnergy.id])
        #expect(DeviceListFilter.classic.records(in: sections, matching: "").map(\.id) == [classic.id])
        #expect(DeviceListFilter.lowEnergy.records(in: sections, matching: "").map(\.id) == [lowEnergy.id])
        #expect(DeviceListFilter.ignored.records(in: sections, matching: "").map(\.id) == [ignored.id])
    }

    @Test func hideBaselineFilterAppliesToVisibleAndIgnoredButNotNewOrUnnamedDevices() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let baseline = device("baseline", name: "Nearby keyboard")
        let baselineIgnored = device("baseline-ignored", name: "Nearby headset")
        let new = device("new", name: "New sensor")
        let newIgnored = device("new-ignored", name: "New ignored sensor")
        let unnamedBaseline = device("unnamed-baseline")
        #expect(session.discover(baseline, at: 1) == false)
        #expect(session.discover(baselineIgnored, at: 2) == false)
        #expect(session.discover(unnamedBaseline, at: 3) == false)
        #expect(session.discover(new, at: 11) == true)
        #expect(session.discover(newIgnored, at: 12) == true)
        session.setIgnored(true, for: baselineIgnored.id)
        session.setIgnored(true, for: newIgnored.id)

        let sections = DeviceListSections(
            records: Array(session.records.values),
            hidingBaselineDevices: true
        )

        #expect(sections.visible.map(\.id) == [new.id])
        #expect(sections.ignored.map(\.id) == [newIgnored.id])
        #expect(session.records[baseline.id]?.origin == .baseline)
        #expect(session.records[baselineIgnored.id]?.isIgnored == true)
        #expect(session.records[unnamedBaseline.id] != nil)
    }

    @Test func selectedIgnoredBaselineDeviceIsRevealedInIgnoredSection() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let baseline = device("baseline", name: "Nearby keyboard")
        #expect(session.discover(baseline, at: 1) == false)
        session.setIgnored(true, for: baseline.id)

        let sections = DeviceListSections(
            records: Array(session.records.values),
            hidingBaselineDevices: true,
            revealing: baseline.id
        )

        #expect(sections.visible.isEmpty)
        #expect(sections.ignored.map(\.id) == [baseline.id])
    }

    @Test func selectedBaselineDeviceIsRevealedThroughHideFilterAndSearch() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let baseline = device("baseline", name: "Nearby keyboard")
        let new = device("new", name: "New sensor")
        #expect(session.discover(baseline, at: 1) == false)
        #expect(session.discover(new, at: 11) == true)
        let records = Array(session.records.values)

        let hiddenSections = DeviceListSections(records: records, hidingBaselineDevices: true)
        let revealedSections = DeviceListSections(
            records: records,
            hidingBaselineDevices: true,
            revealing: baseline.id
        )

        #expect(DeviceListFilter.named.records(in: hiddenSections, matching: "keyboard").isEmpty)
        #expect(DeviceListFilter.named.records(in: revealedSections, matching: "keyboard").map(\.id) == [baseline.id])
        #expect(DeviceListFilter.named.records(in: revealedSections, matching: "sensor").map(\.id) == [new.id])
    }

    @Test func searchesNamesIdentifiersAndTransportLabelsCaseInsensitively() {
        var session = DiscoverySession()
        session.resume(at: 0)
        let classic = device("AA:BB:CC:DD:EE:FF", transport: .classic, name: "Keyboard")
        let lowEnergy = device("Sensor-UUID", name: "Room Sensor")
        session.discover(classic, at: 1)
        session.discover(lowEnergy, at: 1)
        let sections = DeviceListSections(records: Array(session.records.values))

        #expect(DeviceListFilter.named.records(in: sections, matching: "KEY").map(\.id) == [classic.id])
        #expect(DeviceListFilter.named.records(in: sections, matching: "sensor-uuid").map(\.id) == [lowEnergy.id])
        #expect(DeviceListFilter.named.records(in: sections, matching: "bluetooth classic").map(\.id) == [classic.id])
        #expect(DeviceListFilter.named.records(in: sections, matching: "  ").count == 2)
    }

    @Test func bleThrottleLimitsRepeatedReportsButAllowsLateNamesImmediately() {
        var throttle = BLEDiscoveryThrottle(minimumInterval: 3)
        let anonymous = device("late-name", name: nil)
        #expect(throttle.shouldDeliver(anonymous, at: 0) == true)
        #expect(throttle.shouldDeliver(anonymous, at: 0.25) == false)
        #expect(throttle.shouldDeliver(anonymous, at: 2.99) == false)
        #expect(throttle.shouldDeliver(anonymous, at: 3) == true)
        #expect(throttle.shouldDeliver(anonymous, at: 4) == false)

        let named = device("late-name", name: "Sensor")
        #expect(throttle.shouldDeliver(named, at: 4.1) == true)
        #expect(throttle.shouldDeliver(named, at: 5) == false)
        #expect(throttle.shouldDeliver(named, at: 7.1) == true)
    }

    @Test func bleThrottleTreatsWhitespaceAndNameCaseChangesAsDuplicates() {
        var throttle = BLEDiscoveryThrottle(minimumInterval: 3)
        #expect(throttle.shouldDeliver(device("a", name: "Sensor"), at: 1) == true)
        #expect(throttle.shouldDeliver(device("a", name: " sensor "), at: 2) == false)
        #expect(throttle.shouldDeliver(device("a", name: "New sensor"), at: 2.1) == true)
    }

    @Test func bleThrottlePrunesOldRotatingIdentities() {
        var throttle = BLEDiscoveryThrottle(minimumInterval: 3, retentionInterval: 10)
        let first = device("rotating-a")
        #expect(throttle.shouldDeliver(first, at: 0) == true)
        #expect(throttle.shouldDeliver(device("rotating-b"), at: 30) == true)
        #expect(throttle.shouldDeliver(first, at: 31) == true)
    }

    @Test func bleThrottleDoesNotThrottleClassicDevices() {
        var throttle = BLEDiscoveryThrottle(minimumInterval: 3)
        let classic = device("aa:bb:cc:dd:ee:ff", transport: .classic)
        #expect(throttle.shouldDeliver(classic, at: 1) == true)
        #expect(throttle.shouldDeliver(classic, at: 1.1) == true)
    }
}
