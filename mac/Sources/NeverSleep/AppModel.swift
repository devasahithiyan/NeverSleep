import AppKit
import Combine
import ServiceManagement
import NeverSleepCore
import NeverSleepShared

/// Persistent user settings (UserDefaults).
final class Prefs {
    /// Prefilled relay URL. Empty by default: everyone deploys their own relay (see README).
    /// Set it here if you build NeverSleep for yourself and want the field filled in.
    static let defaultRelayURL = ""
    private let d = UserDefaults.standard
    var allowList: Set<String> {
        get { Set(d.stringArray(forKey: "allowList") ?? []) }
        set { d.set(newValue.sorted(), forKey: "allowList") }
    }
    var quitInsteadOfPause: Set<String> {
        get { Set(d.stringArray(forKey: "quitInsteadOfPause") ?? []) }
        set { d.set(newValue.sorted(), forKey: "quitInsteadOfPause") }
    }
    var batteryCutoff: Int {
        get { d.object(forKey: "batteryCutoff") as? Int ?? 20 }
        set { d.set(min(max(newValue, 5), 90), forKey: "batteryCutoff") }
    }
    var sleepDisplay: Bool {
        get { d.object(forKey: "sleepDisplay") as? Bool ?? true }
        set { d.set(newValue, forKey: "sleepDisplay") }
    }
    var keepAwakeWhileArmed: Bool {
        get { d.object(forKey: "keepAwakeWhileArmed") as? Bool ?? true }
        set { d.set(newValue, forKey: "keepAwakeWhileArmed") }
    }
    var openAtLogin: Bool {
        get { d.object(forKey: "openAtLogin") as? Bool ?? true }
        set { d.set(newValue, forKey: "openAtLogin") }
    }
    var lidModeEnabled: Bool {
        get { d.bool(forKey: "lidModeEnabled") }
        set { d.set(newValue, forKey: "lidModeEnabled") }
    }
    var relayURL: String {
        get { d.string(forKey: "relayURL") ?? Prefs.defaultRelayURL }
        set { d.set(newValue, forKey: "relayURL") }
    }
}

@MainActor
final class AppModel: ObservableObject, RelayHandler {
    static let shared = AppModel()

    let prefs = Prefs()
    let procs = SystemProcessController()
    let helper = HelperClient()
    let store = FileStateStore(url: FileStateStore.defaultURL)
    let engine: LidModeEngine
    let relay = RelayClient()
    private let lid = LidMonitor()
    private let power = PowerMonitor()

    @Published var allowList: Set<String> = []
    @Published var quitInsteadOfPause: Set<String> = []
    @Published var batteryCutoff: Int = 20
    @Published var sleepDisplay = true
    @Published var keepAwakeWhileArmed = true
    @Published var openAtLogin = true
    @Published var lidModeEnabled = false
    @Published var simulateLidClosed = false
    @Published private(set) var realLidClosed = false
    @Published private(set) var battery = BatteryInfo()
    @Published private(set) var thermal: ThermalLevel = .nominal
    @Published private(set) var installedApps: [InstalledApp] = []
    @Published private(set) var helperStatusText = ""
    @Published private(set) var helperEnabled = false
    @Published var relayURLDraft = ""
    @Published private(set) var startupWarning: String?

    private var bag = Set<AnyCancellable>()
    private var watchdog: Process?
    private var activity: NSObjectProtocol?
    private var stateDebounce: DispatchWorkItem?
    private var started = false

    private init() {
        var cfg = LidModeConfig()
        cfg.protectedPIDs = [getpid()]
        cfg.protectedBundleIDs.insert(NeverSleepIDs.appBundleID)
        engine = LidModeEngine(config: cfg, sleep: helper, procs: procs, store: store)
        allowList = prefs.allowList
        quitInsteadOfPause = prefs.quitInsteadOfPause
        batteryCutoff = prefs.batteryCutoff
        sleepDisplay = prefs.sleepDisplay
        keepAwakeWhileArmed = prefs.keepAwakeWhileArmed
        openAtLogin = prefs.openAtLogin
        lidModeEnabled = prefs.lidModeEnabled
        relayURLDraft = relay.credentials?.relayURL ?? prefs.relayURL
    }

    var lidClosed: Bool { realLidClosed || simulateLidClosed }

    func start() {
        guard !started else { return }
        started = true
        let log = ActivityLog.shared
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        log.record("app", "NeverSleep \(version) started (pid \(getpid())). Helper: \(helper.statusText). Lid mode \(lidModeEnabled ? "on" : "off"), keep awake while armed: \(keepAwakeWhileArmed ? "on" : "off"). Allow-list: \(allowList.sorted().joined(separator: ", ").isEmpty ? "(empty)" : allowList.sorted().joined(separator: ", "))")
        engine.onEvent = { ActivityLog.shared.record($0.kind, $0.message) }
        LoginItem.sync(enabled: openAtLogin)

        // Keep timers and the WebSocket responsive while the lid is closed (no App Nap).
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep], reason: "NeverSleep lid mode and remote control")

        watchdog = Watchdog.spawn(stateFile: store.url)
        refreshHelperStatus()
        applyConfig()

        Task {
            // Undo anything a previous crash left behind before doing anything else.
            await engine.recoverLeftovers()
            if SystemProcessController.isSleepDisabledSystemWide() == true && engine.phase != .active {
                startupWarning = "System sleep is disabled (pmset SleepDisabled = 1). NeverSleep will re-enable it."
                try? await helper.setDisableSleep(false)
                if SystemProcessController.isSleepDisabledSystemWide() == false { startupWarning = nil }
            }
            engine.setEnabled(lidModeEnabled)
        }

        lid.onChange = { [weak self] closed, source in
            Task { @MainActor in
                ActivityLog.shared.record("lid", "Lid \(closed ? "closed" : "opened") (detected by \(source))")
                self?.realLidClosed = closed
                self?.pushLid()
            }
        }
        lid.start()
        realLidClosed = lid.isClosed
        log.record("lid", LidMonitor.hasLid ? "Lid is \(lid.isClosed ? "closed" : "open") at startup (AppleClamshellState)" : "No lid sensor found (AppleClamshellState missing)")
        pushLid()

        power.onBattery = { [weak self] info in
            Task { @MainActor in
                guard let self else { return }
                if info.present && info.onAC != self.battery.onAC {
                    ActivityLog.shared.record("power", "Now on \(info.onAC ? "AC power" : "battery") (\(info.percent.map { "\($0)%" } ?? "?"))")
                }
                self.battery = info
                self.engine.updatePower(info.powerReading)
                self.stateChanged()
            }
        }
        power.onThermal = { [weak self] level in
            Task { @MainActor in
                if self?.thermal != level { ActivityLog.shared.record("power", "Thermal state: \(level.name)") }
                self?.thermal = level
                self?.engine.updateThermal(level)
                self?.stateChanged()
            }
        }
        power.start()

        engine.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.stateChanged() }
        }.store(in: &bag)

        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in
                    self?.engine.pruneDeadRecords()
                    self?.stateChanged()
                }
            }.store(in: &bag)
        }

        relay.handler = self
        if relay.credentials != nil { relay.connect() }
        relay.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.objectWillChange.send() } }
            .store(in: &bag)

        Task.detached(priority: .utility) {
            let apps = InstalledAppScanner.scan()
            await MainActor.run { AppModel.shared.installedApps = apps }
        }
    }

    // MARK: Settings mutations

    func setLidMode(_ on: Bool, source: String = "menu") {
        if on != lidModeEnabled { ActivityLog.shared.record("mode", "Lid mode switched \(on ? "on" : "off") from \(source)") }
        lidModeEnabled = on
        prefs.lidModeEnabled = on
        engine.setEnabled(on)
        stateChanged()
    }

    func setSimulateLidClosed(_ on: Bool) {
        if on != simulateLidClosed { ActivityLog.shared.record("lid", "Simulate lid closed \(on ? "ON" : "OFF")") }
        simulateLidClosed = on
        pushLid()
    }

    func setAllowed(_ bundleID: String, _ allowed: Bool) {
        if allowed { allowList.insert(bundleID) } else { allowList.remove(bundleID) }
        prefs.allowList = allowList
        applyConfig()
    }

    func setAllowList(_ ids: [String]) {
        allowList = Set(ids)
        prefs.allowList = allowList
        applyConfig()
    }

    func setQuitInstead(_ bundleID: String, _ on: Bool) {
        if on { quitInsteadOfPause.insert(bundleID) } else { quitInsteadOfPause.remove(bundleID) }
        prefs.quitInsteadOfPause = quitInsteadOfPause
        applyConfig()
    }

    func setBatteryCutoff(_ v: Int) {
        prefs.batteryCutoff = v
        batteryCutoff = prefs.batteryCutoff
        applyConfig()
        engine.updatePower(battery.powerReading)
    }

    func setKeepAwakeWhileArmed(_ on: Bool) {
        keepAwakeWhileArmed = on
        prefs.keepAwakeWhileArmed = on
        ActivityLog.shared.record("mode", "Keep awake while armed: \(on ? "on" : "off")")
        applyConfig()
        engine.reevaluate()
    }

    func setOpenAtLogin(_ on: Bool) {
        openAtLogin = on
        prefs.openAtLogin = on
        LoginItem.sync(enabled: on)
        ActivityLog.shared.record("app", "Open at login: \(on ? "on" : "off")")
    }

    func setSleepDisplay(_ on: Bool) {
        sleepDisplay = on
        prefs.sleepDisplay = on
        applyConfig()
    }

    private func applyConfig() {
        var c = engine.config
        c.allowList = allowList
        c.quitInsteadOfPause = quitInsteadOfPause
        c.batteryCutoffPercent = batteryCutoff
        c.sleepDisplayOnEngage = sleepDisplay
        c.keepAwakeWhileArmed = keepAwakeWhileArmed
        if let w = watchdog { c.protectedPIDs.insert(w.processIdentifier) }
        engine.config = c
        stateChanged()
    }

    private func pushLid() {
        engine.setLidClosed(lidClosed)
        stateChanged()
    }

    // MARK: Helper

    func refreshHelperStatus() {
        helperStatusText = helper.statusText
        helperEnabled = helper.isInstalled && !helper.needsReinstall
    }

    @Published private(set) var helperBusy = false

    /// Installs (or updates) the helper. macOS shows its administrator prompt.
    func installHelper() {
        guard !helperBusy else { return }
        helperBusy = true
        Task {
            ActivityLog.shared.record("helper", "Installing helper (administrator prompt)")
            let (ok, msg) = await helper.install()
            ActivityLog.shared.record("helper", ok ? "Helper installed" : "Helper install failed: \(msg)")
            helperBusy = false
            refreshHelperStatus()
            if !ok { helperStatusText = msg.contains("-128") ? "Cancelled" : "Install failed: \(msg)" }
        }
    }

    func uninstallHelper() {
        guard !helperBusy else { return }
        helperBusy = true
        Task {
            let (ok, msg) = await helper.uninstall()
            ActivityLog.shared.record("helper", ok ? "Helper uninstalled" : "Helper uninstall failed: \(msg)")
            helperBusy = false
            refreshHelperStatus()
            if !ok { helperStatusText = msg.contains("-128") ? "Cancelled" : "Uninstall failed: \(msg)" }
        }
    }

    // MARK: Pairing

    func startPairing() {
        prefs.relayURL = relayURLDraft
        relay.startPairing(relayURL: relayURLDraft, deviceName: Host.current().localizedName ?? "Mac")
    }

    // MARK: Shutdown

    /// Synchronous restore used by applicationWillTerminate and signal handlers.
    func emergencyRestore() {
        ActivityLog.shared.record("app", "NeverSleep quitting: resuming paused apps and re-enabling sleep")
        engine.resumeAllNow()
        if store.load().sleepDisabled || SystemProcessController.isSleepDisabledSystemWide() == true {
            let ok = helper.setDisableSleepSync(false)
            ActivityLog.shared.record("sleep", ok ? "Sleep re-enabled on quit" : "Could not re-enable sleep on quit (helper will restore it when the connection drops)")
            if ok {
                var s = store.load()
                s.sleepDisabled = false
                store.save(s)
            }
        }
        watchdog?.terminate()
    }

    // MARK: Remote state + commands

    private func stateChanged() {
        objectWillChange.send()
        stateDebounce?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.relay.sendState() }
        stateDebounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
    }

    func relayStateSnapshot() -> [String: Any] {
        let pausedByPID = Dictionary(engine.paused.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let apps: [[String: Any]] = procs.runningRegularApps().map { app in
            var d: [String: Any] = ["pid": app.pid, "name": app.name]
            d["bundleId"] = app.bundleID ?? NSNull()
            d["paused"] = pausedByPID[app.pid] != nil
            d["pausedBy"] = pausedByPID[app.pid]?.source.rawValue ?? NSNull()
            d["allowed"] = app.bundleID.map(allowList.contains) ?? false
            d["quitInsteadOfPause"] = app.bundleID.map(quitInsteadOfPause.contains) ?? false
            let protected = engine.config.protectedPIDs.contains(app.pid)
                || (app.bundleID.map(engine.config.protectedBundleIDs.contains) ?? false)
            d["protected"] = protected
            let keep = engine.keepReason(app)
            d["keptBecause"] = (keep != nil && !protected && !(app.bundleID.map(allowList.contains) ?? false)) ? keep! : NSNull()
            return d
        }
        var reason: Any = NSNull()
        if case .cutoff(let r) = engine.phase { reason = r }
        return [
            "battery": [
                "present": battery.present,
                "percent": battery.percent.map { $0 as Any } ?? NSNull(),
                "charging": battery.charging,
                "pluggedIn": battery.onAC,
                "timeToEmptyMin": battery.timeToEmptyMin.map { $0 as Any } ?? NSNull(),
                "timeToFullMin": battery.timeToFullMin.map { $0 as Any } ?? NSNull(),
            ],
            "thermal": thermal.name,
            "lid": ["closed": lidClosed, "simulated": simulateLidClosed, "hasLid": LidMonitor.hasLid],
            "lidMode": [
                "enabled": lidModeEnabled,
                "phase": engine.phase.name,
                "reason": reason,
                "error": engine.lastError ?? NSNull(),
                "batteryCutoff": batteryCutoff,
                "pausedCount": engine.paused.count,
            ],
            "helper": helperEnabled ? "enabled" : "notEnabled",
            "apps": apps,
            "allowList": allowList.sorted(),
            "quitInsteadOfPause": quitInsteadOfPause.sorted(),
            "device": [
                "name": Host.current().localizedName ?? "Mac",
                "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
            ],
            "events": ActivityLog.shared.recent.suffix(40).map {
                ["t": Int($0.date.timeIntervalSince1970 * 1000), "kind": $0.kind, "msg": String($0.message.prefix(300))]
            },
            "sentAt": Int(Date().timeIntervalSince1970 * 1000),
        ]
    }

    private func regularApp(_ pid: Int32) throws -> NSRunningApplication {
        guard pid != getpid(), let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular, !app.isTerminated else {
            throw RelayError(message: "No such app")
        }
        if let bid = app.bundleIdentifier, engine.config.protectedBundleIDs.contains(bid) {
            throw RelayError(message: "That app is protected")
        }
        return app
    }

    func relayHandle(_ cmd: RemoteCommand) async throws -> [String: Any]? {
        if cmd != .refresh && cmd != .listInstalledApps {
            ActivityLog.shared.record("remote", "Dashboard command: \(Self.describe(cmd))")
        }
        do {
            return try await handleCommand(cmd)
        } catch {
            ActivityLog.shared.record("remote", "Dashboard command failed: \(Self.describe(cmd)) — \(error.localizedDescription)")
            throw error
        }
    }

    private static func describe(_ cmd: RemoteCommand) -> String {
        func app(_ pid: Int32) -> String {
            let a = NSRunningApplication(processIdentifier: pid)
            return "\(a?.localizedName ?? "?") [\(a?.bundleIdentifier ?? "-")] pid \(pid)"
        }
        switch cmd {
        case .refresh: return "refresh"
        case .listInstalledApps: return "list installed apps"
        case .quitApp(let pid): return "quit \(app(pid))"
        case .forceQuitApp(let pid): return "force quit \(app(pid))"
        case .pauseApp(let pid): return "pause \(app(pid))"
        case .resumeApp(let pid): return "resume \(app(pid))"
        case .launchApp(let bid): return "open \(bid)"
        case .setLidMode(let on): return "lid mode \(on ? "on" : "off")"
        case .setAllowList(let ids): return "set allow-list (\(ids.count) apps): \(ids.joined(separator: ", "))"
        case .setQuitInsteadOfPause(let bid, let on): return "quit-instead \(on ? "on" : "off") for \(bid)"
        }
    }

    private func handleCommand(_ cmd: RemoteCommand) async throws -> [String: Any]? {
        switch cmd {
        case .refresh:
            return nil
        case .listInstalledApps:
            if installedApps.isEmpty { installedApps = InstalledAppScanner.scan() }
            return ["apps": installedApps.map { ["bundleId": $0.bundleID, "name": $0.name] }]
        case .quitApp(let pid), .forceQuitApp(let pid):
            let app = try regularApp(pid)
            // A stopped process cannot handle a quit request, so let it run first.
            if engine.isPaused(pid) { try? engine.manualResume(pid: pid) }
            let force: Bool
            if case .forceQuitApp = cmd { force = true } else { force = false }
            let ok = force ? app.forceTerminate() : app.terminate()
            if !ok { throw RelayError(message: "The app refused to quit") }
            return nil
        case .pauseApp(let pid):
            _ = try regularApp(pid)
            do { try engine.manualPause(pid: pid) } catch { throw RelayError(message: "Could not pause (\(error))") }
            return nil
        case .resumeApp(let pid):
            do { try engine.manualResume(pid: pid) } catch { throw RelayError(message: "Not paused") }
            return nil
        case .launchApp(let bid):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else {
                throw RelayError(message: "App not installed")
            }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            return nil
        case .setLidMode(let on):
            setLidMode(on, source: "dashboard")
            return nil
        case .setAllowList(let ids):
            setAllowList(ids)
            return nil
        case .setQuitInsteadOfPause(let bid, let on):
            setQuitInstead(bid, on)
            return nil
        }
    }
}
