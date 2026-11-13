import SwiftUI
import AppKit
import NeverSleepCore

struct MenuContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: LidModeEngine
    @EnvironmentObject var relay: RelayClient
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: NeverSleepApp.symbol(for: engine.phase))
                Text("NeverSleep").font(.headline)
                Spacer()
                Text(phaseText).font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Keep apps running with lid closed", isOn: Binding(
                get: { model.lidModeEnabled }, set: { model.setLidMode($0) }))
                .toggleStyle(.switch)

            if let err = engine.lastError {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let warn = model.startupWarning {
                Text(warn).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !model.helperEnabled {
                HStack {
                    Image(systemName: "lock.shield").foregroundStyle(.orange)
                    Text("Helper: \(model.helperStatusText)").font(.caption)
                    Spacer()
                    Button("Install") { model.installHelper() }.controlSize(.small).disabled(model.helperBusy)
                }
            }

            Divider()
            LabeledContent("Battery", value: batteryText)
            LabeledContent("Lid", value: model.lidClosed ? (model.simulateLidClosed ? "closed (simulated)" : "closed") : "open")
            LabeledContent("Paused apps", value: "\(engine.paused.count)")
            LabeledContent("Remote", value: relay.status.text)
            if let code = relay.pairingCode ?? relay.browserCode {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign-in code — type it in the dashboard:").font(.caption)
                    Text(code).font(.system(.title2, design: .monospaced)).textSelection(.enabled)
                    Text("Valid for 10 minutes, one use.").font(.caption2).foregroundStyle(.secondary)
                }
            } else if relay.status == .connected {
                Button("Show code to sign in a browser") { relay.requestBrowserCode() }
                    .controlSize(.small)
            }
            if let note = relay.browserNotice {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            RecentActivityView(limit: 4)
            Divider()
            Toggle("Simulate lid closed (debug)", isOn: Binding(
                get: { model.simulateLidClosed }, set: { model.setSimulateLidClosed($0) }))
                .font(.caption)

            HStack {
                Button("Settings…") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit NeverSleep") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { model.refreshHelperStatus() }
    }

    var phaseText: String {
        switch engine.phase {
        case .off: return "Off"
        case .armed: return "Armed"
        case .active: return "Lid closed – active"
        case .cutoff(let r): return "Cut off: \(r)"
        }
    }

    var batteryText: String {
        let b = model.battery
        guard b.present, let p = b.percent else { return "No battery" }
        var s = "\(p)%"
        if b.charging { s += " charging" } else if b.onAC { s += " on AC" }
        if let t = b.timeToEmptyMin, !b.onAC { s += " · \(t / 60)h \(t % 60)m left" }
        return s
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            AllowListView().tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            SafetyView().tabItem { Label("Safety", systemImage: "thermometer.medium") }
            RemoteView().tabItem { Label("Remote", systemImage: "antenna.radiowaves.left.and.right") }
            HelperView().tabItem { Label("Helper", systemImage: "lock.shield") }
            ActivityTabView().tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
        }
        .padding()
    }
}

struct AllowListView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: LidModeEngine
    // Plain ObservableObject instead of @State: @State is a macro in the macOS 27 SDK and the
    // Command Line Tools ship without the SwiftUI macro plugin.
    final class SearchBox: ObservableObject { @Published var text = "" }
    @StateObject private var searchBox = SearchBox()
    private var search: String { searchBox.text }

    struct Row: Identifiable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let path: String?
        let running: Bool
    }

    var rows: [Row] {
        let running = model.procs.runningRegularApps()
        var byID: [String: Row] = [:]
        for app in model.installedApps {
            byID[app.bundleID] = Row(bundleID: app.bundleID, name: app.name, path: app.path, running: false)
        }
        for app in running {
            guard let bid = app.bundleID else { continue }
            byID[bid] = Row(bundleID: bid, name: app.name, path: byID[bid]?.path, running: true)
        }
        for bid in model.allowList where byID[bid] == nil {
            byID[bid] = Row(bundleID: bid, name: bid, path: nil, running: false)
        }
        return byID.values
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || $0.bundleID.localizedCaseInsensitiveContains(search) }
            .filter { !engine.config.protectedBundleIDs.contains($0.bundleID) }
            .sorted {
                if model.allowList.contains($0.bundleID) != model.allowList.contains($1.bundleID) {
                    return model.allowList.contains($0.bundleID)
                }
                if $0.running != $1.running { return $0.running }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("Checked apps keep running while the lid is closed. Apps they launch, and their helper apps (bundle IDs under theirs), keep running too. Every other app is paused (SIGSTOP) and resumed when you open the lid, or quit if you choose “Quit instead”. Tip: a CLI agent in Terminal needs Terminal checked — a paused terminal stops the agent once its output buffer fills.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Search apps", text: $searchBox.text).textFieldStyle(.roundedBorder)
            List(rows) { row in
                HStack {
                    Toggle(isOn: Binding(get: { model.allowList.contains(row.bundleID) },
                                         set: { model.setAllowed(row.bundleID, $0) })) {
                        HStack {
                            if let p = row.path {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().frame(width: 18, height: 18)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                Text(row.name)
                                Text(row.bundleID).font(.caption2).foregroundStyle(.secondary)
                            }
                            if row.running { Text("running").font(.caption2).foregroundStyle(.green) }
                        }
                    }
                    Spacer()
                    if !model.allowList.contains(row.bundleID) {
                        Toggle("Quit instead", isOn: Binding(get: { model.quitInsteadOfPause.contains(row.bundleID) },
                                                             set: { model.setQuitInstead(row.bundleID, $0) }))
                            .font(.caption).toggleStyle(.checkbox)
                    }
                }
            }
        }
    }
}

struct SafetyView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: LidModeEngine

    var body: some View {
        Form {
            Section("Battery") {
                Stepper(value: Binding(get: { model.batteryCutoff }, set: { model.setBatteryCutoff($0) }),
                        in: 5...90, step: 5) {
                    Text("Stop and let the Mac sleep below \(model.batteryCutoff)% (when not plugged in)")
                }
            }
            Section("Heat") {
                Text("If macOS reports serious or critical thermal pressure, NeverSleep resumes all apps, re-enables sleep and puts the Mac to sleep. Current: \(model.thermal.name).")
                    .font(.callout)
            }
            Section("Reliability") {
                Toggle("Keep the Mac awake for the whole time lid mode is on (recommended)",
                       isOn: Binding(get: { model.keepAwakeWhileArmed }, set: { model.setKeepAwakeWhileArmed($0) }))
                Text("Sleep stays disabled from the moment you switch lid mode on, so closing the lid can never race NeverSleep. The Mac won't idle-sleep while lid mode is on; the battery and heat cutoffs still apply. Off: sleep is only disabled after the lid closes.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Open NeverSleep at login",
                       isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
            }
            Section("Display") {
                Toggle("Turn the display off when lid mode engages",
                       isOn: Binding(get: { model.sleepDisplay }, set: { model.setSleepDisplay($0) }))
            }
            Section("Debug") {
                Toggle("Simulate lid closed", isOn: Binding(get: { model.simulateLidClosed },
                                                             set: { model.setSimulateLidClosed($0) }))
                Text("Runs the real lid-close actions (keeps the Mac awake, pauses apps) without closing the lid. Turn it off to resume everything.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Engine phase", value: engine.phase.name)
                LabeledContent("Real lid state", value: model.realLidClosed ? "closed" : "open")
                if !engine.paused.isEmpty {
                    Text("Paused: " + engine.paused.map { "\($0.name) (\($0.pid))" }.joined(separator: ", "))
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct RemoteView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var relay: RelayClient

    var body: some View {
        Form {
            Section("Relay") {
                TextField("Relay URL", text: $model.relayURLDraft, prompt: Text("https://neversleep-relay.<you>.workers.dev"))
                    .disabled(relay.credentials != nil)
                LabeledContent("Status", value: relay.status.text)
            }
            Section("Pairing") {
                if let creds = relay.credentials {
                    LabeledContent("Device ID", value: creds.deviceID)
                    if let code = relay.browserCode {
                        Text("Open the dashboard in a browser and enter:")
                        Text(code).font(.system(.largeTitle, design: .monospaced)).textSelection(.enabled)
                    }
                    HStack {
                        Button("Show browser sign-in code") { relay.requestBrowserCode() }
                            .disabled(relay.status != .connected)
                        Button("Sign out all browsers") { relay.revokeBrowsers() }
                            .disabled(relay.status != .connected)
                    }
                    if let note = relay.browserNotice { Text(note).font(.caption) }
                    HStack {
                        Button("Reconnect") { relay.connect() }
                        Button("Unpair", role: .destructive) { relay.unpair() }
                    }
                } else if let code = relay.pairingCode {
                    Text("Open the dashboard in a browser and enter:")
                    Text(code).font(.system(.largeTitle, design: .monospaced)).textSelection(.enabled)
                    Button("Cancel") { relay.cancelPairing() }
                } else {
                    Button("Pair this Mac") { model.startPairing() }
                        .disabled(RelayClient.normalizedBaseURL(model.relayURLDraft) == nil)
                }
                if let err = relay.pairingError { Text(err).foregroundStyle(.red) }
            }
            Section {
                Text("There is no password: a browser signs in with a one-time code shown here, and can then control only this Mac. Only a device token is stored on this Mac (in the Keychain); the relay keeps a hash of it. The dashboard can only send a fixed set of commands: quit / force quit / pause / resume an app, launch an installed app, toggle lid mode and edit the allow-list.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct HelperView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Privileged helper") {
                LabeledContent("Status", value: model.helperStatusText)
                Text("Keeping the Mac awake with the lid closed needs `pmset -a disablesleep 1`, which requires root. A small launch daemon does exactly that one thing and nothing else, and only for this app. Installing it asks for your administrator password once (and again after NeverSleep is updated).")
                    .font(.callout)
                HStack {
                    Button("Install") { model.installHelper() }.disabled(model.helperBusy)
                    Button("Refresh") { model.refreshHelperStatus() }
                    Spacer()
                    Button("Uninstall", role: .destructive) { model.uninstallHelper() }.disabled(model.helperBusy)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshHelperStatus() }
    }
}

private let activityTime: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

struct RecentActivityView: View {
    @ObservedObject private var log = ActivityLog.shared
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Recent activity").font(.caption).bold()
                Spacer()
                Button("Open log") { NSWorkspace.shared.open(ActivityLog.fileURL) }
                    .buttonStyle(.link).font(.caption)
            }
            if log.recent.isEmpty {
                Text("Nothing yet").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(log.recent.suffix(limit).reversed()) { e in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(activityTime.string(from: e.date)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Text(e.message).font(.caption2).lineLimit(2)
                        .foregroundStyle(e.kind == "error" || e.kind == "safety" ? Color.red : Color.primary)
                }
            }
        }
    }
}

struct ActivityTabView: View {
    @ObservedObject private var log = ActivityLog.shared

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Everything NeverSleep decides is logged to ~/Library/Logs/NeverSleep/activity.log (helper: /Library/Logs/NeverSleep/helper.log).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ActivityLog.fileURL]) }
            }
            List(log.recent.reversed()) { e in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(activityTime.string(from: e.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(e.kind).font(.caption2).padding(.horizontal, 5).background(.quaternary, in: Capsule())
                    Text(e.message).font(.caption).textSelection(.enabled)
                        .foregroundStyle(e.kind == "error" || e.kind == "safety" ? Color.red : Color.primary)
                }
            }
        }
    }
}
