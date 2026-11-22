import Foundation
import UserNotifications
import BluetoothWatchCore

enum DeviceNotificationAction { case pair, ignore, review }

@MainActor
final class NotificationHub: NSObject, UNUserNotificationCenterDelegate {
    var onAction: ((String, String, DeviceNotificationAction) -> Void)?
    var onPermission: ((String?) -> Void)?
    var onError: ((String) -> Void)?
    private let center = UNUserNotificationCenter.current()
    private let category = "DISCOVERED_DEVICE"
    private let runID: String

    init(runID: String) {
        self.runID = runID
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: category,
                actions: [
                    UNNotificationAction(identifier: "PAIR", title: "Pair", options: [.foreground]),
                    UNNotificationAction(identifier: "IGNORE", title: "Ignore", options: [])
                ],
                intentIdentifiers: []
            )
        ])
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                if let error {
                    self?.onPermission?("Notifications unavailable: \(error.localizedDescription)")
                } else {
                    self?.onPermission?(granted ? nil : "Notifications are off. Enable Bluetooth Watch in System Settings > Notifications. New devices still appear here.")
                }
            }
        }
    }

    func refreshPermission() {
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                guard let self else { return }
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    self.onPermission?(settings.alertSetting == .enabled
                        ? nil
                        : "Notifications are disabled. Enable alerts for Bluetooth Watch in System Settings > Notifications.")
                case .denied:
                    self.onPermission?("Notifications are off. Enable Bluetooth Watch in System Settings > Notifications.")
                case .notDetermined:
                    self.onPermission?("Notifications have not been authorized. New devices still appear in the menu bar list.")
                @unknown default:
                    self.onPermission?("Notification permission status is unavailable. Check System Settings > Notifications.")
                }
            }
        }
    }

    func notify(_ device: DiscoveredDevice) {
        let content = UNMutableNotificationContent()
        content.title = "New Bluetooth device"
        content.body = "\(device.displayName) is discoverable. Pair or ignore it."
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = ["run": runID, "device": device.id.notificationIdentifier]
        center.add(UNNotificationRequest(
            identifier: device.id.notificationIdentifier, content: content, trigger: nil
        )) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.onError?("Could not deliver a notification: \(error.localizedDescription)")
            }
        }
    }

    func dismiss(_ id: DeviceIdentity) {
        center.removeDeliveredNotifications(withIdentifiers: [id.notificationIdentifier])
        center.removePendingNotificationRequests(withIdentifiers: [id.notificationIdentifier])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let run = info["run"] as? String
        let device = info["device"] as? String
        let identifier = response.actionIdentifier
        Task { @MainActor in
            defer { completionHandler() }
            guard let run, let device else {
                self.onError?("The notification is missing its device identity. Open the device list.")
                return
            }
            switch identifier {
            case "PAIR": self.onAction?(run, device, .pair)
            case "IGNORE": self.onAction?(run, device, .ignore)
            case UNNotificationDefaultActionIdentifier: self.onAction?(run, device, .review)
            default: break
            }
        }
    }
}
