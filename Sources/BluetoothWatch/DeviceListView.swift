import AppKit
import SwiftUI
import BluetoothWatchCore

struct MenuBarContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Bluetooth Watch", systemImage: "dot.radiowaves.left.and.right").font(.headline)
            Text(model.status).font(.callout)
            if model.notificationMessage != nil {
                Label("Notifications need attention", systemImage: "bell.badge").font(.caption)
            }
            Button("Show Devices...") { model.reveal() }.keyboardShortcut("o")
            HStack {
                Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }
                Button("Scan Now") { model.scanNow() }.disabled(model.isPaused)
            }
            Divider()
            Toggle("Launch at login", isOn: Binding(
                get: { model.loginEnabled }, set: { model.setLaunchAtLogin($0) }
            ))
            Button("Quit Bluetooth Watch") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 310)
        .onAppear { model.refreshLoginStatus() }
    }
}

struct DeviceListView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bluetooth Watch").font(.title2.bold())
                    Text(model.status).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }
                Button("Scan Now") { model.scanNow() }.disabled(model.isPaused)
            }
            Text("The first 10 seconds are quiet. Only devices first seen afterward trigger alerts. Nearby devices that advertise late can still appear as new.")
                .font(.callout).foregroundStyle(.secondary)
            if !model.isScanning && !model.isPaused {
                HStack {
                    Button("Retry Discovery") { model.scanNow() }
                    Button("Bluetooth Settings") { model.openSettings() }
                }
            }
            if let message = model.notificationMessage {
                HStack(alignment: .top) {
                    Label(message, systemImage: "bell.slash")
                    Spacer()
                    Button("Check Permission") { model.requestNotificationPermission() }
                }.font(.callout)
            }
            if let message = model.actionMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).textSelection(.enabled)
            }
            ScrollViewReader { proxy in
                List {
                    Section("Discovered this run") {
                        if model.visibleRecords.isEmpty {
                            Text("No devices discovered yet. Put a device in pairing mode to make it discoverable.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.visibleRecords) { record in
                            DeviceRow(model: model, record: record).id(record.id)
                        }
                    }
                    if !model.ignoredRecords.isEmpty {
                        Section("Ignored until the app restarts") {
                            ForEach(model.ignoredRecords) { record in
                                DeviceRow(model: model, record: record).id(record.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .onChange(of: model.selectedDeviceID) { _, id in
                    if let id {
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .onAppear {
                    if let id = model.selectedDeviceID { proxy.scrollTo(id, anchor: .center) }
                }
            }
            HStack {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.loginEnabled }, set: { model.setLaunchAtLogin($0) }
                ))
                if model.loginNeedsApproval {
                    Button("Approve in Login Items") { model.openLoginSettings() }
                }
                Spacer()
                Text("Discovery stays on your Mac").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .onAppear { model.refreshLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLoginStatus()
        }
    }
}

private struct DeviceRow: View {
    @ObservedObject var model: AppModel
    let record: DeviceRecord
    private var selected: Bool { model.selectedDeviceID == record.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                Text(record.device.displayName).font(.headline).textSelection(.enabled)
                Spacer()
                Text(record.origin == .baseline ? "Startup device" : "New this run")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(record.id.transport.label) · \(record.id.identifier)")
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                let age = max(0, Int(ProcessInfo.processInfo.systemUptime - record.lastSeen))
                Text("Last seen \(age)s ago. Discoverable does not always mean pairable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let pairingStatus = model.pairingStatuses[record.id] {
                Text(pairingStatus.message).font(.callout).textSelection(.enabled)
            }
            if selected {
                Text("If Bluetooth settings opens, select “\(record.device.displayName)” there. macOS may not let this app highlight it for you.")
                    .font(.callout)
            }
            HStack {
                Button("Pair") { model.pair(record.id) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.activePairingID != nil)
                if model.activePairingID == record.id {
                    Button("Cancel Pairing") { model.cancelPairing() }
                }
                if record.isIgnored {
                    Button("Undo Ignore") { model.undoIgnore(record.id) }
                } else {
                    Button("Ignore") { model.ignore(record.id) }
                }
                Spacer()
                Button("Copy Name") { model.copyName(record.device) }
                    .disabled(record.device.name?.isEmpty != false)
                Button("Bluetooth Settings") { model.openSettings(for: record.id) }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(selected ? Color.accentColor.opacity(0.10) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
