import BluetoothWatchCore

@MainActor
protocol BluetoothDiscoveryServing: AnyObject {
    var onDevice: ((DiscoveredDevice) -> Void)? { get set }
    var onState: ((Bool, String) -> Void)? { get set }
    var isClassicConfirmed: Bool { get }
    func start()
    func stop()
    func scanNow()
    func refreshAfterSettings()
}

@MainActor
protocol NotificationServing: AnyObject {
    var onAction: ((String, String, DeviceNotificationAction) -> Void)? { get set }
    var onPermission: ((String?) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func requestPermission()
    func refreshPermission()
    func notify(_ device: DiscoveredDevice)
    func dismiss(_ id: DeviceIdentity)
}

extension BluetoothDiscovery: BluetoothDiscoveryServing {}
extension NotificationHub: NotificationServing {}
