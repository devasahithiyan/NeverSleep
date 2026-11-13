import Foundation
import NeverSleepCore

// Minimal test harness (no Xcode needed): `swift run NeverSleepSelfTest`

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0
nonisolated(unsafe) var currentTest = ""

func expect(_ cond: @autoclosure () throws -> Bool, file: StaticString = #fileID, line: UInt = #line) {
    checks += 1
    do {
        if try !cond() { failures += 1; print("  FAIL \(currentTest) at \(file):\(line)") }
    } catch {
        failures += 1; print("  FAIL \(currentTest) at \(file):\(line): threw \(error)")
    }
}

func expectThrows(file: StaticString = #fileID, line: UInt = #line, _ body: () throws -> Void) {
    checks += 1
    do { try body(); failures += 1; print("  FAIL \(currentTest) at \(file):\(line): did not throw") } catch {}
}

func expectThrows<E: Error & Equatable>(_ expected: E, file: StaticString = #fileID, line: UInt = #line,
                                        _ body: () throws -> Void) {
    checks += 1
    do {
        try body(); failures += 1; print("  FAIL \(currentTest) at \(file):\(line): did not throw")
    } catch let e as E where e == expected {
    } catch {
        failures += 1; print("  FAIL \(currentTest) at \(file):\(line): threw \(error), expected \(expected)")
    }
}

@MainActor
func run(_ name: String, _ body: () async throws -> Void) async {
    currentTest = name
    let before = failures
    do { try await body() } catch { failures += 1; print("  FAIL \(name): threw \(error)") }
    print(failures == before ? "ok   \(name)" : "FAIL \(name)")
}

@MainActor
func main() async {
    let t = LidModeEngineTests()
    await run("lidCloseAndOpenFullCycle") { await t.lidCloseAndOpenFullCycle() }
    await run("disabledDoesNothingOnLidClose") { await t.disabledDoesNothingOnLidClose() }
    await run("batteryCutoffResumesAndSleepsAndLatches") { await t.batteryCutoffResumesAndSleepsAndLatches() }
    await run("lowBatteryOnACIsFine") { await t.lowBatteryOnACIsFine() }
    await run("thermalPressureCutsOff") { await t.thermalPressureCutsOff() }
    await run("refusesToEngageWhenUnsafe") { await t.refusesToEngageWhenUnsafe() }
    await run("helperFailureDoesNotPauseApps") { await t.helperFailureDoesNotPauseApps() }
    await run("disablingWhileClosedRestores") { await t.disablingWhileClosedRestores() }
    await run("rapidFlappingConverges") { await t.rapidFlappingConverges() }
    await run("manualPauseSurvivesLidOpenButNotShutdown") { await t.manualPauseSurvivesLidOpenButNotShutdown() }
    await run("manualPauseRejectsSelfAndProtected") { t.manualPauseRejectsSelfAndProtected() }
    await run("pidReuseIsNotResumed") { await t.pidReuseIsNotResumed() }
    await run("recoversLeftoverStateFromCrash") { await t.recoversLeftoverStateFromCrash() }
    let h = HoldWhileArmedTests()
    await run("holdsSleepFromArmToDisarm") { await h.holdsSleepFromArmToDisarm() }
    await run("cutoffWithLidClosedSleepsTheMac") { await h.cutoffWithLidClosedSleepsTheMac() }
    await run("closingLidWhileUnsafeSleepsTheMac") { await h.closingLidWhileUnsafeSleepsTheMac() }
    await run("lowBatteryWithLidOpenOnlyReleases") { await h.lowBatteryWithLidOpenOnlyReleases() }
    await run("keepsHelpersOfAllowedApps") { await h.keepsHelpersOfAllowedApps() }
    await run("logsEveryDecision") { await h.logsEveryDecision() }
    let r = RemoteCommandTests()
    await run("parsesValidCommands") { try r.parsesValidCommands() }
    await run("rejectsEverythingElse") { r.rejectsEverythingElse() }
    print("\n\(checks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

await main()
