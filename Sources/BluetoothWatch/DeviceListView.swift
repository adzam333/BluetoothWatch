import AppKit
import SwiftUI
import BluetoothWatchCore

struct DeviceListView: View {
    static let width: CGFloat = 460
    static let height: CGFloat = 620
    @ObservedObject var model: AppModel
    @State private var searchText = ""
    @State private var selectedFilter: DeviceListFilter = .named

    private var filteredRecords: [DeviceRecord] {
        selectedFilter.records(in: model.listSections, matching: searchText)
    }

    private func revealSelectedRecord() {
        guard let record = model.selectedRecord else { return }
        searchText = ""
        selectedFilter = record.isIgnored ? .ignored : .named
    }

    var body: some View {
        let sections = model.listSections
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Bluetooth Watch", systemImage: "dot.radiowaves.left.and.right").font(.headline)
                Spacer()
                Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }
                Button("Scan Now") { model.scanNow() }.disabled(model.isPaused)
            }
            Text(model.status)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text("The first 10 seconds are quiet. Only devices first seen afterward trigger alerts. Nearby devices that advertise late can still appear as new.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            if let record = model.selectedUnnamedRecord {
                Text("This device has no name, so it is hidden from the list. Use its notification actions or Bluetooth Settings.")
                    .font(.callout)
                if let pairingStatus = model.pairingStatuses[record.id] {
                    Text(pairingStatus.message).font(.callout).textSelection(.enabled)
                }
                HStack {
                    if model.activePairingID == record.id {
                        Button("Cancel Pairing") { model.cancelPairing() }
                    }
                    Button("Bluetooth Settings") { model.openSettings(for: record.id) }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search name or identifier", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search devices by name or identifier")
                Picker("Filter devices", selection: $selectedFilter) {
                    ForEach(DeviceListFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel("Filter devices")
            }
            ScrollViewReader { proxy in
                List {
                    if selectedFilter != .ignored {
                        Section("Discovered this run") {
                            if filteredRecords.isEmpty {
                                Text(model.listSections.visible.isEmpty
                                    ? "No named devices to show. Put a device in pairing mode to make it discoverable."
                                    : "No named devices match this search or filter.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(filteredRecords) { record in
                                DeviceRow(model: model, record: record).id(record.id)
                            }
                        }
                    }
                    if selectedFilter == .ignored {
                        Section("Ignored until the app restarts") {
                            if filteredRecords.isEmpty {
                                Text(sections.ignored.isEmpty
                                    ? "No ignored named devices."
                                    : "No ignored devices match this search.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(filteredRecords) { record in
                                DeviceRow(model: model, record: record).id(record.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .onChange(of: model.selectedDeviceID) { _, id in
                    if let id {
                        revealSelectedRecord()
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .onAppear {
                    if let id = model.selectedDeviceID {
                        revealSelectedRecord()
                        proxy.scrollTo(id, anchor: .center)
                    }
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
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            Text("Discovery stays on your Mac").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: Self.width, height: Self.height)
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
                .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                let age = max(0, Int(ProcessInfo.processInfo.systemUptime - record.lastSeen))
                Text("Last reported \(age)s ago. Discoverable does not always mean pairable.")
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
                Menu {
                    Button("Copy Name") { model.copyName(record.device) }
                        .disabled(record.device.name?.isEmpty != false)
                    Button("Bluetooth Settings") { model.openSettings(for: record.id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("More actions")
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(selected ? Color.accentColor.opacity(0.10) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
