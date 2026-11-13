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
    var parents: [Int32: Int32] = [:]
    var systemSleeps = 0

    func add(_ pid: Int32, _ bid: String) {
        apps.append(RunningApp(pid: pid, bundleID: bid, name: bid))
        startTimes[pid] = UInt64(pid) * 1000
    }
    func runningRegularApps() -> [RunningApp] { apps }
    func startTime(of pid: Int32) -> UInt64? { startTimes[pid] }
    func parentPID(of pid: Int32) -> Int32? { parents[pid] }
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
        cfg.keepAwakeWhileArmed = false   // classic mode; the hold-while-armed tests opt in
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

@MainActor
struct HoldWhileArmedTests {
    let base = LidModeEngineTests()

    func make() -> (LidModeEngine, FakeSleep, FakeProcs, MemoryStateStore, [ActivityEvent]) {
        let (e, s, p, st) = base.make { $0.keepAwakeWhileArmed = true }
        return (e, s, p, st, [])
    }

    func holdsSleepFromArmToDisarm() async {
        let (e, s, p, _, _) = make()
        e.setEnabled(true); await e.settle()
        expect(e.phase == .armed)
        expect(s.calls == [true])               // held before the lid ever closes
        expect(p.stopped.isEmpty)
        e.setLidClosed(true); await e.settle()
        expect(e.phase == .active)
        expect(s.calls == [true])               // no helper call needed at lid close
        expect(p.stopped == [30, 50])
        e.setLidClosed(false); await e.settle()
        expect(e.phase == .armed && p.stopped.isEmpty)
        expect(s.calls == [true])               // still held while armed
        e.setEnabled(false); await e.settle()
        expect(e.phase == .off && s.calls == [true, false])
    }

    func cutoffWithLidClosedSleepsTheMac() async {
        let (e, s, p, _, _) = make()
        e.updatePower(PowerReading(batteryPercent: 60, onACPower: false))
        e.setEnabled(true); e.setLidClosed(true); await e.settle()
        e.updatePower(PowerReading(batteryPercent: 10, onACPower: false)); await e.settle()
        expect(e.phase.name == "cutoff")
        expect(p.stopped.isEmpty)
        expect(s.calls == [true, false])
        expect(p.systemSleeps == 1)
    }

    func closingLidWhileUnsafeSleepsTheMac() async {
        // Hold was on while armed; lid closes with battery already low → release and sleep.
        let (e, s, p, _, _) = make()
        e.updatePower(PowerReading(batteryPercent: 60, onACPower: false))
        e.setEnabled(true); await e.settle()
        e.updatePower(PowerReading(batteryPercent: 10, onACPower: false))
        e.setLidClosed(true); await e.settle()
        expect(e.phase.name == "cutoff")
        expect(s.calls == [true, false])
        expect(p.systemSleeps == 1)
        expect(p.stopped.isEmpty)
    }

    func lowBatteryWithLidOpenOnlyReleases() async {
        let (e, s, p, _, _) = make()
        e.updatePower(PowerReading(batteryPercent: 60, onACPower: false))
        e.setEnabled(true); await e.settle()
        e.updatePower(PowerReading(batteryPercent: 10, onACPower: false)); await e.settle()
        expect(e.phase == .armed)
        expect(s.calls == [true, false])
        expect(p.systemSleeps == 0)
        e.updatePower(PowerReading(batteryPercent: 10, onACPower: true)); await e.settle()
        expect(s.calls == [true, false, true])  // plugged in: hold again
    }

    func keepsHelpersOfAllowedApps() async {
        let (e, _, p, _, _) = make()
        p.add(60, "com.allowed.helper")         // bundle-ID prefix of an allowed app
        p.add(70, "com.unrelated.tool")         // launched directly by allowed app 20
        p.parents[70] = 20
        p.add(80, "com.deep.child")             // launched via a non-app process (900) of app 20
        p.parents[80] = 900; p.parents[900] = 20
        p.add(90, "com.allowedish")             // similar name, NOT a prefix match
        e.setEnabled(true); e.setLidClosed(true); await e.settle()
        expect(!p.stopped.contains(60))
        expect(!p.stopped.contains(70))
        expect(!p.stopped.contains(80))
        expect(p.stopped.contains(90))
        expect(e.keepReason(RunningApp(pid: 60, bundleID: "com.allowed.helper", name: "h"))?.contains("helper") == true)
    }

    func logsEveryDecision() async {
        let (e, _, _, _, _) = make()
        var events: [ActivityEvent] = []
        e.onEvent = { events.append($0) }
        e.setEnabled(true); e.setLidClosed(true); await e.settle()
        e.setLidClosed(false); await e.settle()
        let text = events.map { "\($0.kind): \($0.message)" }
        expect(text.contains { $0.hasPrefix("mode: Lid mode armed") })
        expect(text.contains { $0.contains("Sleep disabled") })
        expect(text.contains { $0.contains("Paused: com.other") })
        expect(text.contains { $0.contains("Kept running: com.allowed") && $0.contains("on allow-list") })
        expect(text.contains { $0.contains("Resumed: com.other") && $0.contains("lid opened") })
        expect(text.contains { $0.contains("Engaged:") })
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
