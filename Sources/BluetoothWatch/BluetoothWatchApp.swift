import AppKit
import SwiftUI

@main
struct BluetoothWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The menu bar item and its dropdown are managed by AppDelegate so the app can open them itself.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var didStart = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else {
            let alert = NSAlert()
            alert.messageText = "Run Bluetooth Watch as an app bundle"
            alert.informativeText = "In the project folder, run: bash scripts/build-app.sh --install"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        didStart = true
        setUpStatusItem()
        AppModel.shared.onReveal = { [weak self] in self?.showDevices() }
        AppModel.shared.start()
        if !UserDefaults.standard.bool(forKey: "hasShownWelcome") {
            showDevices()
            UserDefaults.standard.set(true, forKey: "hasShownWelcome")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if didStart { AppModel.shared.shutdown() }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "dot.radiowaves.left.and.right",
            accessibilityDescription: "Bluetooth Watch"
        )
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item
        AppModel.shared.observeStatusIcon { [weak self] symbol, tint in
            guard let button = self?.statusItem?.button else { return }
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Bluetooth Watch")
            button.contentTintColor = tint
            button.toolTip = AppModel.shared.status
        }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: DeviceListView.width, height: DeviceListView.height)
        popover.contentViewController = NSHostingController(rootView: DeviceListView(model: .shared))
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender) } else { showDevices() }
    }

    private func showDevices() {
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }
}
