import AppKit
import Combine
import ServiceManagement
import BluetoothWatchCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published private(set) var records: [DeviceRecord] = []
    @Published private(set) var isPaused = false
    @Published private(set) var isScanning = false
    @Published private(set) var baselineRemaining = 10
    @Published private(set) var baselineComplete = false
    @Published private(set) var scannerMessage = "Waiting to scan..."
    @Published private(set) var classicCoverageConfirmed = false
    @Published private(set) var notificationMessage: String?
    @Published private(set) var actionMessage: String?
    @Published private(set) var pairingStatuses: [DeviceIdentity: PairingStatus] = [:]
    @Published private(set) var activePairingID: DeviceIdentity?
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginNeedsApproval = false
    @Published var selectedDeviceID: DeviceIdentity?
    var onReveal: (() -> Void)?
    private var onStatusIconChange: ((String, NSColor?) -> Void)?
    private(set) var statusSymbolName = ""

    private var session = DiscoverySession()
    private let scannerFactory: @MainActor () -> BluetoothDiscoveryServing
    private let notificationFactory: @MainActor (String) -> NotificationServing
    private let uptime: () -> TimeInterval
    private lazy var scanner: BluetoothDiscoveryServing = scannerFactory()
    private let runID = UUID().uuidString
    private lazy var notifications: NotificationServing = notificationFactory(runID)
    private lazy var pairing = PairingController(
        driver: ClassicPairingDriver(), leDriver: LEPairingDriver()
    ) { [weak self] device in
        self?.selectedDeviceID = device.id
        self?.onReveal?()
        return Self.openBluetoothSettings()
    }
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var applicationObserver: NSObjectProtocol?
    private var isAsleep = false
    private var started = false
    private var now: TimeInterval { uptime() }

    init(
        scannerFactory: @escaping @MainActor () -> BluetoothDiscoveryServing = { BluetoothDiscovery() },
        notificationFactory: @escaping @MainActor (String) -> NotificationServing = { NotificationHub(runID: $0) },
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.scannerFactory = scannerFactory
        self.notificationFactory = notificationFactory
        self.uptime = uptime
    }

    var listSections: DeviceListSections { DeviceListSections(records: records) }
    var selectedRecord: DeviceRecord? {
        records.first { $0.id == selectedDeviceID }
    }
    var selectedUnnamedRecord: DeviceRecord? {
        records.first { $0.id == selectedDeviceID && !$0.device.hasName }
    }

    var status: String {
        if isPaused { return "Paused" }
        if !isScanning { return scannerMessage }
        let caveat = classicCoverageConfirmed ? "" : " (Classic discovery unconfirmed: no Classic device has responded yet)"
        if !baselineComplete { return "Learning nearby devices: \(baselineRemaining)s remaining\(caveat)" }
        return "Watching for newly discovered devices\(caveat)"
    }

    func start() {
        guard !started else { return }
        started = true
        notifications.onAction = { [weak self] run, identifier, action in
            self?.handleNotification(run: run, identifier: identifier, action: action)
        }
        notifications.onPermission = { [weak self] in self?.notificationMessage = $0 }
        notifications.onError = { [weak self] in self?.actionMessage = $0 }
        notifications.requestPermission()
        pairing.onChange = { [weak self] in
            guard let self else { return }
            self.pairingStatuses = self.pairing.statuses
            self.activePairingID = self.pairing.activeDeviceID
        }
        scanner.onDevice = { [weak self] device in
            guard let self, !self.isPaused, !self.isAsleep else { return }
            let shouldNotify = self.session.discover(device, at: self.now)
            self.refresh()
            if shouldNotify { self.notifications.notify(device) }
        }
        scanner.onState = { [weak self] running, message in
            guard let self else { return }
            self.scannerMessage = message
            self.classicCoverageConfirmed = self.scanner.isClassicConfirmed
            self.session.updateScannerState(
                isRunning: running,
                isPaused: self.isPaused,
                isAsleep: self.isAsleep,
                at: self.now
            )
            self.refresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.sleep() } })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.wake() } })
        applicationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.appBecameActive() } }
        refreshLoginStatus()
        scanner.start()
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        pairing.cancel()
        scanner.stop()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        if let applicationObserver {
            NotificationCenter.default.removeObserver(applicationObserver)
            self.applicationObserver = nil
        }
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused {
            session.pause(at: now)
            scanner.stop()
        } else if !isAsleep {
            scanner.start()
        }
        refresh()
    }

    func scanNow() {
        guard !isPaused, !isAsleep else { return }
        scanner.scanNow()
    }

    func reveal() { onReveal?() }

    func pair(_ id: DeviceIdentity) {
        guard let record = session.records[id] else {
            actionMessage = "This device is no longer in this run's list. Scan again."
            return
        }
        selectedDeviceID = id
        onReveal?()
        notifications.dismiss(id)
        if !pairing.pair(record.device) {
            actionMessage = "Finish or cancel the current pairing attempt first."
        } else {
            session.setIgnored(false, for: id)
            actionMessage = nil
            refresh()
        }
    }

    func cancelPairing() { pairing.cancel() }

    func ignore(_ id: DeviceIdentity) {
        guard session.records[id] != nil else {
            actionMessage = "This device is no longer in this run's list."
            return
        }
        if pairing.activeDeviceID == id { pairing.cancel() }
        session.setIgnored(true, for: id)
        notifications.dismiss(id)
        refresh()
    }

    func undoIgnore(_ id: DeviceIdentity) {
        session.setIgnored(false, for: id)
        refresh()
    }

    func openSettings(for id: DeviceIdentity? = nil) {
        if let id { selectedDeviceID = id }
        if !Self.openBluetoothSettings() {
            actionMessage = "Could not open settings. Open System Settings > Bluetooth manually."
        }
    }

    func openBluetoothPrivacySettings() {
        openSystemSettings(
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Bluetooth",
            fallback: "Open System Settings > Privacy & Security > Bluetooth manually."
        )
    }

    func openNotificationSettings() {
        openSystemSettings(
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=local.bluetoothwatch.app",
            fallback: "Open System Settings > Notifications > Bluetooth Watch manually."
        )
    }

    func copyName(_ device: DiscoveredDevice) {
        guard let name = device.name, !name.isEmpty else {
            actionMessage = "This device has not advertised a name. Use its details to identify it."
            return
        }
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setString(name, forType: .string) {
            actionMessage = "Could not copy the device name."
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            actionMessage = nil
        } catch {
            actionMessage = "Could not change launch at login: \(error.localizedDescription)"
        }
        refreshLoginStatus()
    }

    func refreshLoginStatus() {
        loginEnabled = SMAppService.mainApp.status == .enabled
            || SMAppService.mainApp.status == .requiresApproval
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    func observeStatusIcon(_ handler: @escaping (String, NSColor?) -> Void) {
        onStatusIconChange = handler
        updateStatusIcon()
        handler(statusSymbolName, statusIconColor)
    }

    private func appBecameActive() {
        scanner.refreshAfterSettings()
        notifications.refreshPermission()
    }

    private func tick() {
        session.advance(to: now)
        refresh()
    }

    private func refresh() {
        isScanning = session.isScanning
        baselineRemaining = Int(ceil(session.baselineSecondsRemaining(at: now)))
        baselineComplete = session.baselineIsComplete
        let updated = session.records.values.sorted {
            if $0.firstSeen != $1.firstSeen { return $0.firstSeen > $1.firstSeen }
            return $0.id.notificationIdentifier < $1.id.notificationIdentifier
        }
        if records != updated { records = updated }
        updateStatusIcon()
    }

    private var statusIconColor: NSColor? {
        if isPaused { return .systemOrange }
        if !isScanning { return .systemRed }
        if !classicCoverageConfirmed { return .systemYellow }
        return nil
    }

    private func updateStatusIcon() {
        let state = DiscoveryStatusIconState.current(
            isPaused: isPaused,
            isScanning: isScanning,
            classicCoverageConfirmed: classicCoverageConfirmed
        )
        guard state.symbolName != statusSymbolName else {
            onStatusIconChange?(statusSymbolName, statusIconColor)
            return
        }
        statusSymbolName = state.symbolName
        onStatusIconChange?(state.symbolName, statusIconColor)
    }

    private func sleep() {
        isAsleep = true
        session.interrupt(at: now)
        scanner.stop()
        refresh()
    }

    private func wake() {
        isAsleep = false
        if !isPaused { scanner.start() }
    }

    private func handleNotification(run: String, identifier: String, action: DeviceNotificationAction) {
        let route = NotificationRoute.resolve(
            notificationRunID: run,
            currentRunID: runID,
            notificationIdentifier: identifier,
            currentDevices: Set(session.records.keys)
        )
        guard case .device(let id) = route else {
            actionMessage = "That alert belongs to an earlier run. Choose a device from the current list."
            onReveal?()
            return
        }
        switch action {
        case .pair: pair(id)
        case .ignore: ignore(id)
        case .review:
            selectedDeviceID = id
            onReveal?()
        }
    }

    private static func openBluetoothSettings() -> Bool {
        // This opens the pane only; there is no supported per-device selection API.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    private func openSystemSettings(_ urlString: String, fallback: String) {
        guard let url = URL(string: urlString), NSWorkspace.shared.open(url) else {
            actionMessage = fallback
            return
        }
        actionMessage = nil
    }
}
