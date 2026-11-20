import AppKit
import Foundation
@preconcurrency import IOBluetooth
import BluetoothWatchCore

@MainActor
final class ClassicPairingDriver: NSObject, PairingDriver {
    private let timeout: TimeInterval = 60
    private var activePair: IOBluetoothDevicePair?
    private var completion: ((PairingResult) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    private var deviceLabel = "Bluetooth device"
    private var activePrompt: NSAlert?

    func canPair(_ device: DiscoveredDevice) -> Bool {
        device.id.transport == .classic && Self.isBluetoothAddress(device.id.identifier)
    }

    func startPairing(_ device: DiscoveredDevice, completion: @escaping (PairingResult) -> Void) {
        guard activePair == nil else {
            completion(.failed("Another Classic Bluetooth pairing attempt is already active."))
            return
        }
        guard canPair(device) else {
            completion(.failed("Only devices with a valid Bluetooth Classic address can be paired here. Bluetooth LE devices must use Bluetooth settings."))
            return
        }
        guard let target = IOBluetoothDevice(addressString: device.id.identifier),
              let pair = IOBluetoothDevicePair(device: target) else {
            completion(.failed("macOS could not create a Classic Bluetooth pairing attempt for this device. Try Bluetooth settings."))
            return
        }

        let candidateName = device.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        deviceLabel = candidateName.flatMap { $0.isEmpty ? nil : $0 } ?? device.id.identifier
        self.completion = completion
        activePair = pair
        pair.delegate = self
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(self?.timeout ?? 60))
            } catch {
                return
            }
            guard let self, self.activePair === pair else { return }
            self.finish(
                .failed("Pairing timed out after 60 seconds. Check that the device is nearby and ready to pair."),
                stopPair: true
            )
        }

        let result = pair.start()
        guard result == kIOReturnSuccess else {
            finish(
                .failed("macOS could not start pairing (error \(Self.errorCode(result)))."),
                stopPair: true
            )
            return
        }
    }

    func cancelPairing() {
        guard activePair != nil else { return }
        finish(.cancelled, stopPair: true)
    }

    private func finish(_ result: PairingResult, stopPair: Bool) {
        let pair = activePair
        let callback = completion
        activePair = nil
        completion = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        dismissPrompt()
        pair?.delegate = nil
        if stopPair { pair?.stop() }
        callback?(result)
    }

    private func showConfirmation(for pair: IOBluetoothDevicePair, numericValue: BluetoothNumericValue) {
        let formattedPasskey = String(format: "%06u", UInt32(numericValue))
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Confirm Bluetooth pairing"
        alert.informativeText = "Confirm that \(deviceLabel) displays the same code: \(formattedPasskey)"
        alert.addButton(withTitle: "Confirm")
        alert.addButton(withTitle: "Cancel")
        guard present(alert, for: pair, response: { [weak self] response in
            guard let self, self.activePair === pair else { return }
            let accepted = response == .alertFirstButtonReturn
            pair.replyUserConfirmation(accepted)
            if !accepted {
                self.finish(.cancelled, stopPair: true)
            }
        }) else {
            finish(.failed("A visible BluetoothWatch window is required to confirm pairing. Open the app and retry, or use Bluetooth settings."), stopPair: true)
            return
        }
    }

    private func requestPIN(for pair: IOBluetoothDevicePair) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Enter the Bluetooth PIN"
        alert.informativeText = "Enter the PIN requested by \(deviceLabel). Use 1–16 printable ASCII characters."
        alert.addButton(withTitle: "Submit PIN")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "PIN"
        field.setAccessibilityLabel("Bluetooth PIN")
        alert.accessoryView = field
        guard present(alert, for: pair, response: { [weak self] response in
            guard let self, self.activePair === pair else { return }
            guard response == .alertFirstButtonReturn else {
                self.finish(.cancelled, stopPair: true)
                return
            }

            let bytes = Array(field.stringValue.utf8)
            guard !bytes.isEmpty, bytes.count <= 16, bytes.allSatisfy({ (0x20...0x7e).contains($0) }) else {
                self.finish(
                    .failed("The PIN must contain 1–16 printable ASCII characters. Pairing was stopped; retry to enter it again."),
                    stopPair: true
                )
                return
            }

            var pinCode = BluetoothPINCode()
            withUnsafeMutableBytes(of: &pinCode) { buffer in
                for (index, byte) in bytes.enumerated() {
                    buffer[index] = byte
                }
            }
            pair.replyPINCode(bytes.count, pinCode: &pinCode)
        }) else {
            finish(.failed("A visible BluetoothWatch window is required to enter the PIN. Open the app and retry, or use Bluetooth settings."), stopPair: true)
            return
        }
    }

    private func showPasskeyNotification(_ passkey: BluetoothPasskey) {
        let formattedPasskey = String(format: "%06u", UInt32(passkey))
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Bluetooth passkey"
        alert.informativeText = "Enter \(formattedPasskey) on \(deviceLabel) to continue pairing."
        alert.addButton(withTitle: "OK")
        guard present(alert, for: activePair, response: { [weak self] _ in
            self?.activePrompt = nil
        }) else {
            finish(.failed("A visible BluetoothWatch window is required to display the passkey. Open the app and retry, or use Bluetooth settings."), stopPair: true)
            return
        }
    }

    private func present(
        _ alert: NSAlert,
        for pair: IOBluetoothDevicePair?,
        response: @escaping (NSApplication.ModalResponse) -> Void
    ) -> Bool {
        guard let pair, activePair === pair,
              let window = NSApp.mainWindow ?? NSApp.keyWindow else { return false }
        NSApp.activate(ignoringOtherApps: true)
        dismissPrompt()
        activePrompt = alert
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self, self.activePair === pair, self.activePrompt === alert else { return }
            self.activePrompt = nil
            response(result)
        }
        return true
    }

    private func dismissPrompt() {
        guard let alert = activePrompt else { return }
        activePrompt = nil
        alert.window.sheetParent?.endSheet(alert.window, returnCode: .abort)
    }

    private static func isBluetoothAddress(_ value: String) -> Bool {
        let octets = value.split(separator: ":", omittingEmptySubsequences: false)
        return octets.count == 6 && octets.allSatisfy {
            $0.count == 2 && $0.allSatisfy(\.isHexDigit)
        }
    }

    private static func errorCode(_ error: IOReturn) -> String {
        String(format: "0x%08x", UInt32(bitPattern: error))
    }
}

extension ClassicPairingDriver: IOBluetoothDevicePairDelegate {
    func devicePairingPINCodeRequest(_ sender: Any!) {
        guard let pair = sender as? IOBluetoothDevicePair, pair === activePair else { return }
        requestPIN(for: pair)
    }

    func devicePairingUserConfirmationRequest(
        _ sender: Any!,
        numericValue: BluetoothNumericValue
    ) {
        guard let pair = sender as? IOBluetoothDevicePair, pair === activePair else { return }
        showConfirmation(for: pair, numericValue: numericValue)
    }

    func devicePairingUserPasskeyNotification(_ sender: Any!, passkey: BluetoothPasskey) {
        guard let pair = sender as? IOBluetoothDevicePair, pair === activePair else { return }
        showPasskeyNotification(passkey)
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        guard let pair = sender as? IOBluetoothDevicePair, pair === activePair else { return }
        if error == kIOReturnSuccess {
            finish(.paired, stopPair: false)
        } else {
            finish(
                .failed("macOS pairing failed (error \(Self.errorCode(error))). Verify the device is in pairing mode, then retry."),
                stopPair: false
            )
        }
    }
}
