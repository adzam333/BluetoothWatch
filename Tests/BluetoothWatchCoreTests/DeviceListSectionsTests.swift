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
}
