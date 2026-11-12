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
/// Engage:    disablesleep 1, then SIGSTOP (or quit) every regular app not on the allow-list.
/// Disengage: SIGCONT every app we paused for lid mode, then disablesleep 0.
///
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

    private let sleep: SleepControlling
    private let procs: ProcessControlling
    private let store: StateStore
    private var sleepDisabled = false
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

    private func step() async {
        let problem = safetyProblem
        let wantActive = enabled && lidClosed && problem == nil && latchedCutoff == nil

        if phase == .active && !wantActive {
            await disengage()
            phase = .armed
            if enabled && lidClosed, let reason = problem {
                // Safety cutoff with the lid still closed: let the Mac sleep like normal.
                latchedCutoff = reason
                phase = .cutoff(reason)
                procs.sleepSystemNow()
                return
            }
        } else if phase != .active && wantActive {
            await engage()
            return
        } else if phase != .active && enabled && lidClosed, latchedCutoff == nil, let reason = problem {
            // Lid closed while already unsafe: refuse to engage until the lid has been opened again.
            latchedCutoff = reason
        }

        if phase == .active { return }
        if !enabled {
            phase = .off
        } else if let reason = latchedCutoff, lidClosed {
            phase = .cutoff(reason)
        } else {
            phase = .armed
        }
    }

    private func engage() async {
        do {
            try await sleep.setDisableSleep(true)
            sleepDisabled = true
            persist()
        } catch {
            lastError = "Could not keep the Mac awake: \(error.localizedDescription)"
            phase = enabled ? .armed : .off
            return
        }
        lastError = nil

        let alreadyPaused = Set(paused.map(\.pid))
        for app in procs.runningRegularApps() where shouldFreeze(app) && !alreadyPaused.contains(app.pid) {
            if let bid = app.bundleID, config.quitInsteadOfPause.contains(bid) {
                _ = procs.requestQuit(app.pid)
                continue
            }
            guard let start = procs.startTime(of: app.pid) else { continue }
            if procs.sendStop(app.pid) {
                paused.append(PausedRecord(pid: app.pid, bundleID: app.bundleID, name: app.name,
                                           startTime: start, source: .lidMode))
            }
        }
        persist()
        if config.sleepDisplayOnEngage { procs.sleepDisplay() }
        phase = .active
    }

    private func disengage() async {
        resume(where: { $0.source == .lidMode })
        await allowSleep()
    }

    private func allowSleep() async {
        guard sleepDisabled else { return }
        do {
            try await sleep.setDisableSleep(false)
            sleepDisabled = false
            persist()
        } catch {
            lastError = "Could not re-enable sleep: \(error.localizedDescription). Run: sudo pmset -a disablesleep 0"
        }
    }

    public func shouldFreeze(_ app: RunningApp) -> Bool {
        if config.protectedPIDs.contains(app.pid) { return false }
        if app.pid <= 1 { return false }
        if let bid = app.bundleID {
            if config.allowList.contains(bid) || config.protectedBundleIDs.contains(bid) { return false }
        }
        return true
    }

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
    }

    public func manualResume(pid: Int32) throws {
        guard paused.contains(where: { $0.pid == pid }) else { throw ManualError.notPaused }
        resume(where: { $0.pid == pid })
    }

    public func isPaused(_ pid: Int32) -> Bool { paused.contains { $0.pid == pid } }

    // MARK: Recovery / shutdown

    /// Undo anything a previous run left behind (crash, force quit, power loss).
    public func recoverLeftovers() async {
        if !paused.isEmpty { resume(where: { _ in true }) }
        if sleepDisabled { await allowSleep() }
    }

    /// Synchronous part of shutdown: resume every app we paused. Safe to call from
    /// applicationWillTerminate or a signal handler. Sleep is restored separately.
    public func resumeAllNow() {
        resume(where: { _ in true })
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
        let before = paused.count
        paused.removeAll { procs.startTime(of: $0.pid) != $0.startTime }
        if paused.count != before { persist() }
    }

    private func resume(where predicate: (PausedRecord) -> Bool) {
        var keep: [PausedRecord] = []
        for rec in paused {
            guard predicate(rec) else { keep.append(rec); continue }
            // Only signal the same process we stopped (PID reuse guard).
            if procs.startTime(of: rec.pid) == rec.startTime {
                _ = procs.sendCont(rec.pid)
            }
        }
        paused = keep
        persist()
    }

    private func persist() {
        store.save(PersistedState(paused: paused, sleepDisabled: sleepDisabled))
    }
}
