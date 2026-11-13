import Foundation
import NeverSleepCore

/// Runs in a separate, non-GUI process (never a "regular" app, so lid mode never pauses it).
/// When the main app dies for any reason (crash, kill -9), resumes every app it had paused.
/// `disablesleep` is restored by the privileged helper when the app's XPC connection drops.
enum Watchdog {
    static func run(parentPID: Int32, stateFile: URL) -> Never {
        let kq = kqueue()
        var ev = kevent(ident: UInt(parentPID), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                        fflags: NOTE_EXIT, data: 0, udata: nil)
        // If the parent is already gone, kevent fails with ESRCH; fall through to cleanup.
        if kevent(kq, &ev, 1, nil, 0, nil) == 0 {
            var out = kevent()
            while kevent(kq, nil, 0, &out, 1, nil) < 0 && errno == EINTR {}
        }
        let store = FileStateStore(url: stateFile)
        var state = store.load()
        if !state.paused.isEmpty {
            ActivityLog.appendLine(kind: "watchdog", message: "NeverSleep (pid \(parentPID)) exited with \(state.paused.count) app(s) paused; resuming them")
        }
        for rec in state.paused where ProcessInfoReader.startTime(of: rec.pid) == rec.startTime {
            let ok = kill(rec.pid, SIGCONT) == 0
            ActivityLog.appendLine(kind: "watchdog", message: "Resumed \(rec.name) [\(rec.bundleID ?? "-")] pid \(rec.pid)\(ok ? "" : " (failed)")")
        }
        if !state.paused.isEmpty {
            state.paused = []
            store.save(state)   // sleepDisabled stays as-is so the next launch also double-checks pmset.
        }
        exit(0)
    }

    static func spawn(stateFile: URL) -> Process? {
        let p = Process()
        p.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        p.arguments = ["--watchdog", String(getpid()), stateFile.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); return p } catch { return nil }
    }
}
