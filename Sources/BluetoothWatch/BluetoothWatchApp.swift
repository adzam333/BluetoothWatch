import AppKit
import SwiftUI

@main
struct BluetoothWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Bluetooth Watch", systemImage: "dot.radiowaves.left.and.right") {
            MenuBarContent(model: .shared)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var devicesWindow: NSWindow?
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

    private func showDevices() {
        if devicesWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 660, height: 650),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Bluetooth Watch"
            window.contentViewController = NSHostingController(rootView: DeviceListView(model: .shared))
            window.minSize = NSSize(width: 520, height: 440)
            window.isReleasedWhenClosed = false
            window.center()
            devicesWindow = window
        }
        devicesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
