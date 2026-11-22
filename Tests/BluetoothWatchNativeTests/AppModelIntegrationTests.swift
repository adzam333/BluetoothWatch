import AppKit
import Testing
import BluetoothWatchCore
@testable import BluetoothWatch

@MainActor
private final class FakeDiscovery: BluetoothDiscoveryServing {
    var onDevice: ((DiscoveredDevice) -> Void)?
    var onState: ((Bool, String) -> Void)?
    var isClassicConfirmed = false
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var refreshes = 0
    var stateAfterRefresh: (Bool, String)?

    func start() { starts += 1 }
    func stop() { stops += 1 }
    func scanNow() {}
    func refreshAfterSettings() {
        refreshes += 1
        if let (running, message) = stateAfterRefresh { state(running, message) }
    }

    func report(_ device: DiscoveredDevice) { onDevice?(device) }
    func state(_ running: Bool, _ message: String) { onState?(running, message) }
}

@MainActor
private final class FakeNotifications: NotificationServing {
    var onAction: ((String, String, DeviceNotificationAction) -> Void)?
    var onPermission: ((String?) -> Void)?
    var onError: ((String) -> Void)?
    private(set) var runID = ""
    private(set) var refreshes = 0
    private(set) var notified: [DiscoveredDevice] = []
    var permissionAfterRefresh: String?

    init(runID: String) { self.runID = runID }
    func requestPermission() {}
    func refreshPermission() {
        refreshes += 1
        onPermission?(permissionAfterRefresh)
    }
    func notify(_ device: DiscoveredDevice) { notified.append(device) }
    func dismiss(_ id: DeviceIdentity) {}
    func act(runID: String, identifier: String, action: DeviceNotificationAction) {
        onAction?(runID, identifier, action)
    }
}

@MainActor
struct AppModelIntegrationTests {
    @Test func scannerFailureAndRetryRestartBaselineWithoutRealertingKnownDevice() {
        var time: TimeInterval = 0
        let scanner = FakeDiscovery()
        var notifications: FakeNotifications?
        let model = AppModel(
            scannerFactory: { scanner },
            notificationFactory: { runID in
                let fake = FakeNotifications(runID: runID)
                notifications = fake
                return fake
            },
            uptime: { time }
        )
        defer { model.shutdown() }

        model.start()
        scanner.state(true, "Scanning.")
        let known = DiscoveredDevice(
            id: DeviceIdentity(transport: .classic, identifier: "aa:bb:cc:dd:ee:ff"),
            name: "Keyboard"
        )
        time = 11
        scanner.report(known)
        #expect(notifications?.notified == [known])
        #expect(model.baselineComplete)

        time = 20
        scanner.state(false, "Classic inquiry failed.")
        #expect(!model.isScanning)
        #expect(!model.baselineComplete)
        time = 30
        scanner.state(true, "Scanning.")
        time = 31
        scanner.report(known)
        #expect(!model.baselineComplete)
        #expect(notifications?.notified == [known])
        time = 40
        scanner.report(known)
        #expect(model.baselineComplete)
        #expect(notifications?.notified == [known])

        let newDevice = DiscoveredDevice(
            id: DeviceIdentity(transport: .classic, identifier: "bb:cc:dd:ee:ff:00"),
            name: "New keyboard"
        )
        time = 41
        scanner.report(newDevice)
        #expect(notifications?.notified == [known, newDevice])
    }

    @Test func notificationFromEarlierRunIsRejectedAndCurrentRunRoutesExactDevice() {
        var time: TimeInterval = 0
        let scanner = FakeDiscovery()
        var notifications: FakeNotifications?
        let model = AppModel(
            scannerFactory: { scanner },
            notificationFactory: { runID in
                let fake = FakeNotifications(runID: runID)
                notifications = fake
                return fake
            },
            uptime: { time }
        )
        defer { model.shutdown() }
        model.start()
        scanner.state(true, "Scanning.")
        let device = DiscoveredDevice(
            id: DeviceIdentity(transport: .classic, identifier: "aa:bb:cc:dd:ee:ff"),
            name: "Keyboard"
        )
        time = 11
        scanner.report(device)

        notifications?.act(runID: "previous-run", identifier: device.id.notificationIdentifier, action: .review)
        #expect(model.selectedDeviceID == nil)
        #expect(model.actionMessage?.contains("earlier run") == true)

        notifications?.act(runID: notifications?.runID ?? "", identifier: device.id.notificationIdentifier, action: .review)
        #expect(model.selectedDeviceID == device.id)
    }

    @Test func returningFromSettingsRechecksScannerAndNotificationPermission() async {
        let scanner = FakeDiscovery()
        var notifications: FakeNotifications?
        let model = AppModel(
            scannerFactory: { scanner },
            notificationFactory: { runID in
                let fake = FakeNotifications(runID: runID)
                notifications = fake
                return fake
            }
        )
        defer { model.shutdown() }
        model.start()
        scanner.state(false, "Bluetooth access is denied.")
        notifications?.onPermission?("Notifications are off.")
        scanner.stateAfterRefresh = (true, "Scanning.")
        notifications?.permissionAfterRefresh = nil

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        await Task.yield()

        #expect(scanner.refreshes == 1)
        #expect(notifications?.refreshes == 1)
        #expect(model.isScanning)
        #expect(model.notificationMessage == nil)
    }
}
