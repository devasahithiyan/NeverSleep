import Foundation
import NeverSleepCore

final class FakeSleep: SleepControlling {
    var calls: [Bool] = []
    var fail = false
    struct Boom: Error {}
    func setDisableSleep(_ disabled: Bool) async throws {
        if fail { throw Boom() }
        calls.append(disabled)
    }
}

final class FakeProcs: ProcessControlling {
    var apps: [RunningApp] = []
    var stopped: Set<Int32> = []
    var log: [String] = []
    var quitRequested: [Int32] = []
    var startTimes: [Int32: UInt64] = [:]
    var systemSleeps = 0

    func add(_ pid: Int32, _ bid: String) {
        apps.append(RunningApp(pid: pid, bundleID: bid, name: bid))
        startTimes[pid] = UInt64(pid) * 1000
    }
    func runningRegularApps() -> [RunningApp] { apps }
    func startTime(of pid: Int32) -> UInt64? { startTimes[pid] }
    func sendStop(_ pid: Int32) -> Bool { stopped.insert(pid); log.append("STOP \(pid)"); return true }
    func sendCont(_ pid: Int32) -> Bool { stopped.remove(pid); log.append("CONT \(pid)"); return true }
    func requestQuit(_ pid: Int32) -> Bool { quitRequested.append(pid); return true }
    func sleepDisplay() {}
    func sleepSystemNow() { systemSleeps += 1 }
}

@MainActor
struct LidModeEngineTests {
    func make(_ configure: (inout LidModeConfig) -> Void = { _ in })
        -> (LidModeEngine, FakeSleep, FakeProcs, MemoryStateStore)
    {
        var cfg = LidModeConfig()
        cfg.allowList = ["com.allowed"]
        cfg.protectedPIDs = [10]
        configure(&cfg)
        let s = FakeSleep(), p = FakeProcs(), st = MemoryStateStore()
        p.add(10, "com.neversleep.app")
        p.add(20, "com.allowed")
        p.add(30, "com.other")
        p.add(40, "com.apple.finder")
        p.add(50, "com.quitme")
        let e = LidModeEngine(config: cfg, sleep: s, procs: p, store: st)
        return (e, s, p, st)
    }

    func lidCloseAndOpenFullCycle() async {
        let (e, s, p, st) = make { $0.quitInsteadOfPause = ["com.quitme"] }
        e.setEnabled(true); await e.settle()
        expect(e.phase == .armed)

        e.setLidClosed(true); await e.settle()
        expect(e.phase == .active)
        expect(s.calls == [true])
        expect(p.stopped == [30])           // not self, not allowed, not Finder, quit-instead app quit
        expect(p.quitRequested == [50])
        expect(st.state.sleepDisabled)
        expect(st.state.paused.map(\.pid) == [30])

        e.setLidClosed(false); await e.settle()
        expect(e.phase == .armed)
        expect(p.stopped.isEmpty)
        expect(s.calls == [true, false])
        // Resume happens before sleep is re-enabled.
        expect(p.log == ["STOP 30", "CONT 30"])
        expect(st.state == PersistedState())
    }

    func disabledDoesNothingOnLidClose() async {
        let (e, s, p, _) = make()
        e.setLidClosed(true); await e.settle()
        expect(e.phase == .off)
        expect(s.calls.isEmpty && p.stopped.isEmpty)
    }

    func batteryCutoffResumesAndSleepsAndLatches() async {
        let (e, s, p, _) = make()
        e.updatePower(PowerReading(batteryPercent: 50, onACPower: false))
        e.setEnabled(true); e.setLidClosed(true); await e.settle()
        expect(e.phase == .active)

        e.updatePower(PowerReading(batteryPercent: 19, onACPower: false)); await e.settle()
        expect(e.phase.name == "cutoff")
        expect(p.stopped.isEmpty)
        expect(s.calls == [true, false])
        expect(p.systemSleeps == 1)

        // Plugging in while still closed does not re-engage (latched until lid opens).
        e.updatePower(PowerReading(batteryPercent: 19, onACPower: true)); await e.settle()
        expect(e.phase.name == "cutoff")
        expect(s.calls == [true, false])

        e.setLidClosed(false); await e.settle()
        expect(e.phase == .armed)
    }

    func lowBatteryOnACIsFine() async {
        let (e, _, _, _) = make()
        e.updatePower(PowerReading(batteryPercent: 5, onACPower: true))
        e.setEnabled(true); e.setLidClosed(true); await e.settle()
        expect(e.phase == .active)
    }

    func thermalPressureCutsOff() async {
        let (e, s, p, _) = make()
        e.setEnabled(true); e.setLidClosed(true); await e.settle()
        e.updateThermal(.serious); await e.settle()
        expect(e.phase.name == "cutoff")
        expect(p.stopped.isEmpty)
        expect(s.calls.last == false)
    }

    func refusesToEngageWhenUnsafe() async {
        let (e, s, _, _) = make()
        e.updateThermal(.critical)
        e.setEnabled(true); e.setLidClosed(true); await e.settle()
        expect(e.phase.name == "cutoff")
        expect(s.calls.isEmpty)
    }

    func helperFailureDoesNotPauseApps() async {
        let (e, s, p, _) = make()
        s.fail = true
        e.setEnabled(true); e.setLidClosed(true); await e.settle()
        expect(e.phase == .armed)
        expect(e.lastError != nil)
        expect(p.stopped.isEmpty)
    }

    func disablingWhileClosedRestores() async {
        let (e, s, p, _) = make()
        e.setEnabled(true); e.setLidClosed(true); await e.settle()
        e.setEnabled(false); await e.settle()
        expect(e.phase == .off)
        expect(p.stopped.isEmpty)
        expect(s.calls == [true, false])
    }

    func rapidFlappingConverges() async {
        let (e, s, p, _) = make()
        e.setEnabled(true)
        for i in 0..<9 { e.setLidClosed(i % 2 == 0) }   // ends closed
        await e.settle()
        expect(e.phase == .active)
        expect(p.stopped == [30, 50])
        expect(s.calls.last == true)
    }

    func manualPauseSurvivesLidOpenButNotShutdown() async {
        let (e, _, p, _) = make()
        try? e.manualPause(pid: 20)                     // allowed app, paused by hand
        e.setEnabled(true); e.setLidClosed(true); await e.settle()
        e.setLidClosed(false); await e.settle()
        expect(p.stopped == [20])
        await e.shutdown()
        expect(p.stopped.isEmpty)
    }

    func manualPauseRejectsSelfAndProtected() {
        let (e, _, _, _) = make()
        expectThrows(LidModeEngine.ManualError.protected) { try e.manualPause(pid: 10) }
        expectThrows(LidModeEngine.ManualError.protected) { try e.manualPause(pid: 40) }
        expectThrows(LidModeEngine.ManualError.notFound) { try e.manualPause(pid: 999) }
    }

    func pidReuseIsNotResumed() async {
        let (e, _, p, _) = make()
        e.setEnabled(true); e.setLidClosed(true); await e.settle()
        p.startTimes[30] = 999_999                      // pid 30 died and was reused
        e.setLidClosed(false); await e.settle()
        expect(!p.log.contains("CONT 30"))
    }

    func recoversLeftoverStateFromCrash() async {
        let st = MemoryStateStore()
        st.state = PersistedState(
            paused: [PausedRecord(pid: 30, bundleID: "com.other", name: "x", startTime: 30_000, source: .lidMode)],
            sleepDisabled: true)
        let s = FakeSleep(), p = FakeProcs()
        p.add(30, "com.other"); p.stopped = [30]
        let e = LidModeEngine(config: LidModeConfig(), sleep: s, procs: p, store: st)
        await e.recoverLeftovers()
        expect(p.stopped.isEmpty)
        expect(s.calls == [false])
        expect(st.state == PersistedState())
    }
}

struct RemoteCommandTests {
    func parsesValidCommands() throws {
        expect(try RemoteCommand.parse(cmd: "pauseApp", args: ["pid": NSNumber(value: 123)]) == .pauseApp(pid: 123))
        expect(try RemoteCommand.parse(cmd: "launchApp", args: ["bundleId": "com.apple.Safari"])
                == .launchApp(bundleID: "com.apple.Safari"))
        expect(try RemoteCommand.parse(cmd: "setLidMode", args: ["enabled": kCFBooleanTrue as Any])
                == .setLidMode(enabled: true))
        expect(try RemoteCommand.parse(cmd: "setAllowList", args: ["bundleIds": ["a.b", "a.b", "c.d"]])
                == .setAllowList(bundleIDs: ["a.b", "c.d"]))
    }

    func rejectsEverythingElse() {
        expectThrows { _ = try RemoteCommand.parse(cmd: "shell", args: ["cmd": "rm -rf /"]) }
        expectThrows { _ = try RemoteCommand.parse(cmd: "pauseApp", args: ["pid": "123"]) }
        expectThrows { _ = try RemoteCommand.parse(cmd: "pauseApp", args: ["pid": NSNumber(value: 1)]) }
        expectThrows { _ = try RemoteCommand.parse(cmd: "pauseApp", args: ["pid": NSNumber(value: 1.5)]) }
        expectThrows {
            _ = try RemoteCommand.parse(cmd: "pauseApp", args: ["pid": NSNumber(value: 5), "extra": 1])
        }
        expectThrows { _ = try RemoteCommand.parse(cmd: "launchApp", args: ["bundleId": "../../bin/sh"]) }
        expectThrows { _ = try RemoteCommand.parse(cmd: "setLidMode", args: ["enabled": NSNumber(value: 1)]) }
    }
}
