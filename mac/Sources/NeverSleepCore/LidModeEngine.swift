import Foundation
import Combine

/// The lid-mode state machine.
///
///   off ──enable──▶ armed ──lid closes (safety OK)──▶ active
///                    ▲                                  │
///                    └──────── lid opens ───────────────┤
///                                                       │ battery low / thermal pressure
///                                                       ▼
///                                       cutoff (latched until the lid opens)
///
/// Sleep hold: `disablesleep 1` while armed (config.keepAwakeWhileArmed, default) or only while
///             the lid is closed. Holding it while armed means a lid close can never race us.
/// Engage:     with sleep held and the lid closed, SIGSTOP (or quit) every regular app that is not
///             allowed. "Allowed" = on the allow-list, a bundle ID nested under an allowed one
///             (com.foo.app.helper), or launched by an allowed app (parent-process chain).
/// Disengage:  SIGCONT every app we paused for lid mode, then release the hold if no longer wanted.
///
/// Every decision is reported through `onEvent` for the activity log.
/// Transitions run one at a time on the main actor; each one re-reads the latest inputs,
/// so rapid lid flapping converges on the final state.
@MainActor
public final class LidModeEngine: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case off
        case armed
        case active
        case cutoff(String)

        public var name: String {
            switch self {
            case .off: return "off"
            case .armed: return "armed"
            case .active: return "active"
            case .cutoff: return "cutoff"
            }
        }
    }

    @Published public private(set) var phase: Phase = .off
    @Published public private(set) var paused: [PausedRecord] = []
    @Published public private(set) var lastError: String?

    // Inputs
    @Published public private(set) var enabled = false
    @Published public private(set) var lidClosed = false
    @Published public private(set) var power = PowerReading(batteryPercent: nil, onACPower: true)
    @Published public private(set) var thermal: ThermalLevel = .nominal
    public var config: LidModeConfig
    /// Activity log sink (lid, sleep, app, safety events).
    public var onEvent: ((ActivityEvent) -> Void)?

    private let sleep: SleepControlling
    private let procs: ProcessControlling
    private let store: StateStore
    private var sleepDisabled = false
    /// True while apps are paused for a closed lid.
    private var appsEngaged = false
    private var latchedCutoff: String?
    private var queue: Task<Void, Never>?

    public init(config: LidModeConfig, sleep: SleepControlling, procs: ProcessControlling, store: StateStore) {
        self.config = config
        self.sleep = sleep
        self.procs = procs
        self.store = store
        let persisted = store.load()
        self.paused = persisted.paused
        self.sleepDisabled = persisted.sleepDisabled
    }

    // MARK: Inputs

    public func setEnabled(_ on: Bool) {
        if on != enabled { emit("mode", on ? "Lid mode armed" : "Lid mode disarmed") }
        enabled = on
        if !on { lastError = nil }
        schedule()
    }
    public func setLidClosed(_ closed: Bool) {
        guard closed != lidClosed else { return }
        lidClosed = closed
        if !closed {
            latchedCutoff = nil
            lastError = nil   // errors are about the last lid-close attempt; it is over
        }
        schedule()
    }
    public func updatePower(_ reading: PowerReading) { power = reading; schedule() }
    /// Re-run the state machine after a config change.
    public func reevaluate() { schedule() }
    public func updateThermal(_ level: ThermalLevel) { thermal = level; schedule() }

    /// Waits for all queued transitions (used by tests and on quit).
    public func settle() async {
        while let q = queue {
            await q.value
            if queue == q { break }
        }
    }

    /// Why lid mode may not engage right now, or nil if it may.
    public var safetyProblem: String? {
        if thermal >= .serious { return "thermal pressure (\(thermal.name))" }
        if let pct = power.batteryPercent, !power.onACPower, pct < config.batteryCutoffPercent {
            return "battery at \(pct)% (below \(config.batteryCutoffPercent)%)"
        }
        return nil
    }

    // MARK: Transitions

    private func schedule() {
        let previous = queue
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.step()
        }
        queue = task
    }

    private func emit(_ kind: String, _ message: String) {
        onEvent?(ActivityEvent(kind, message))
    }

    private func step() async {
        let problem = safetyProblem
        var sleepAfterRelease = false
        if enabled, lidClosed, latchedCutoff == nil, let reason = problem {
            // Unsafe with the lid closed: stop until the lid has been opened again. If we were
            // holding sleep off, macOS already let the clamshell-close pass, so sleep it ourselves.
            latchedCutoff = reason
            sleepAfterRelease = sleepDisabled
            emit("safety", "Safety cutoff: \(reason). Resuming apps and letting the Mac sleep.")
        }
        let safe = problem == nil && latchedCutoff == nil
        let wantHold = enabled && safe && (lidClosed || config.keepAwakeWhileArmed)
        let wantPause = wantHold && lidClosed

        if appsEngaged && !wantPause {
            let n = paused.filter { $0.source == .lidMode }.count
            resume(where: { $0.source == .lidMode }, reason: lidClosed ? "safety cutoff" : "lid opened")
            appsEngaged = false
            emit("engine", "Disengaged: resumed \(n) app(s)")
        }
        if sleepDisabled && !wantHold {
            await allowSleep()
        }
        if !sleepDisabled && wantHold {
            await holdSleep()
        }
        if !appsEngaged && wantPause && sleepDisabled {
            pauseApps()
            appsEngaged = true
        }

        if !enabled {
            phase = .off
        } else if appsEngaged {
            phase = .active
        } else if let reason = latchedCutoff, lidClosed {
            phase = .cutoff(reason)
        } else {
            phase = .armed
        }
        if sleepAfterRelease && !sleepDisabled {
            emit("sleep", "Putting the Mac to sleep (pmset sleepnow)")
            procs.sleepSystemNow()
        }
    }

    private func holdSleep() async {
        do {
            try await sleep.setDisableSleep(true)
            sleepDisabled = true
            lastError = nil
            persist()
            emit("sleep", "Sleep disabled (pmset disablesleep 1) — \(lidClosed ? "lid closed" : "armed, waiting for lid close")")
        } catch {
            lastError = "Could not keep the Mac awake: \(error.localizedDescription)"
            emit("error", "Helper call setDisableSleep(true) failed: \(error.localizedDescription)")
        }
    }

    private func pauseApps() {
        let alreadyPaused = Set(paused.map(\.pid))
        let apps = procs.runningRegularApps()
        let allowedPIDs = Set(apps.filter { $0.bundleID.map(config.allowList.contains) == true }.map(\.pid))
        var pausedN = 0, quitN = 0, keptN = 0
        for app in apps where !alreadyPaused.contains(app.pid) {
            let label = "\(app.name) [\(app.bundleID ?? "no bundle id")] pid \(app.pid)"
            if let why = keepReason(app, apps: apps, allowedPIDs: allowedPIDs) {
                keptN += 1
                emit("app", "Kept running: \(label) — \(why)")
                continue
            }
            if let bid = app.bundleID, config.quitInsteadOfPause.contains(bid) {
                let ok = procs.requestQuit(app.pid)
                quitN += 1
                emit("app", "Quit: \(label) — not allowed, set to quit instead\(ok ? "" : " (request failed)")")
                continue
            }
            guard let start = procs.startTime(of: app.pid) else { continue }
            if procs.sendStop(app.pid) {
                pausedN += 1
                paused.append(PausedRecord(pid: app.pid, bundleID: app.bundleID, name: app.name,
                                           startTime: start, source: .lidMode))
                emit("app", "Paused: \(label) — not on allow-list")
            } else {
                emit("error", "Could not pause \(label)")
            }
        }
        persist()
        emit("engine", "Engaged: \(keptN) kept, \(pausedN) paused, \(quitN) quit")
        if config.sleepDisplayOnEngage { procs.sleepDisplay() }
    }

    /// Why an app must keep running, or nil if it may be paused.
    public func keepReason(_ app: RunningApp, apps: [RunningApp]? = nil, allowedPIDs: Set<Int32>? = nil) -> String? {
        if config.protectedPIDs.contains(app.pid) || app.pid <= 1 { return "NeverSleep itself" }
        if let bid = app.bundleID {
            if config.allowList.contains(bid) { return "on allow-list" }
            if config.protectedBundleIDs.contains(bid) { return "system app (never paused)" }
            if let parent = config.allowList.first(where: { bid.hasPrefix($0 + ".") }) {
                return "helper of allowed \(parent)"
            }
        }
        let list = apps ?? procs.runningRegularApps()
        let allowed = allowedPIDs ?? Set(list.filter { $0.bundleID.map(config.allowList.contains) == true }.map(\.pid))
        var pid = app.pid
        for _ in 0..<32 {
            guard let ppid = procs.parentPID(of: pid), ppid > 1 else { break }
            if allowed.contains(ppid) {
                let name = list.first(where: { $0.pid == ppid })?.name ?? "pid \(ppid)"
                return "launched by allowed \(name)"
            }
            pid = ppid
        }
        return nil
    }

    private func allowSleep() async {
        guard sleepDisabled else { return }
        do {
            try await sleep.setDisableSleep(false)
            sleepDisabled = false
            persist()
            emit("sleep", "Sleep re-enabled (pmset disablesleep 0)")
        } catch {
            lastError = "Could not re-enable sleep: \(error.localizedDescription). Run: sudo pmset -a disablesleep 0"
            emit("error", "Helper call setDisableSleep(false) failed: \(error.localizedDescription)")
        }
    }

    public func shouldFreeze(_ app: RunningApp) -> Bool { keepReason(app) == nil }

    // MARK: Manual control (dashboard)

    public enum ManualError: Error, Equatable { case notFound, protected, signalFailed, notPaused }

    public func manualPause(pid: Int32) throws {
        guard let app = procs.runningRegularApps().first(where: { $0.pid == pid }) else { throw ManualError.notFound }
        if config.protectedPIDs.contains(pid) || app.bundleID.map(config.protectedBundleIDs.contains) == true {
            throw ManualError.protected
        }
        if paused.contains(where: { $0.pid == pid }) { return }
        guard let start = procs.startTime(of: pid), procs.sendStop(pid) else { throw ManualError.signalFailed }
        paused.append(PausedRecord(pid: pid, bundleID: app.bundleID, name: app.name, startTime: start, source: .manual))
        persist()
        emit("app", "Paused by hand: \(app.name) [\(app.bundleID ?? "-")] pid \(pid)")
    }

    public func manualResume(pid: Int32) throws {
        guard paused.contains(where: { $0.pid == pid }) else { throw ManualError.notPaused }
        resume(where: { $0.pid == pid }, reason: "resumed by hand")
    }

    public func isPaused(_ pid: Int32) -> Bool { paused.contains { $0.pid == pid } }

    // MARK: Recovery / shutdown

    /// Undo anything a previous run left behind (crash, force quit, power loss).
    public func recoverLeftovers() async {
        if !paused.isEmpty {
            emit("recovery", "Found \(paused.count) app(s) left paused by a previous run; resuming")
            resume(where: { _ in true }, reason: "recovery")
        }
        if sleepDisabled {
            emit("recovery", "Sleep was left disabled by a previous run; re-enabling")
            await allowSleep()
        }
    }

    /// Synchronous part of shutdown: resume every app we paused. Safe to call from
    /// applicationWillTerminate or a signal handler. Sleep is restored separately.
    public func resumeAllNow() {
        resume(where: { _ in true }, reason: "NeverSleep quitting")
        appsEngaged = false
    }

    /// Full async shutdown.
    public func shutdown() async {
        enabled = false
        resumeAllNow()
        await allowSleep()
        phase = .off
    }

    /// Drop records for processes that exited on their own.
    public func pruneDeadRecords() {
        let gone = paused.filter { procs.startTime(of: $0.pid) != $0.startTime }
        guard !gone.isEmpty else { return }
        for rec in gone { emit("app", "Paused app exited: \(rec.name) [\(rec.bundleID ?? "-")] pid \(rec.pid)") }
        paused.removeAll { procs.startTime(of: $0.pid) != $0.startTime }
        persist()
    }

    private func resume(where predicate: (PausedRecord) -> Bool, reason: String) {
        var keep: [PausedRecord] = []
        for rec in paused {
            guard predicate(rec) else { keep.append(rec); continue }
            // Only signal the same process we stopped (PID reuse guard).
            let label = "\(rec.name) [\(rec.bundleID ?? "-")] pid \(rec.pid)"
            if procs.startTime(of: rec.pid) == rec.startTime {
                let ok = procs.sendCont(rec.pid)
                emit("app", "Resumed: \(label) — \(reason)\(ok ? "" : " (signal failed)")")
            } else {
                emit("app", "Not resumed: \(label) — process is gone or PID was reused")
            }
        }
        paused = keep
        persist()
    }

    private func persist() {
        store.save(PersistedState(paused: paused, sleepDisabled: sleepDisabled))
    }
}
