import Foundation

// Entry point. The same binary also has two small command-line modes:
//   NeverSleep --watchdog <parent-pid> <state-file>   crash watchdog (started by the app)
//   NeverSleep --install-helper                        same as Settings › Helper › Install
let args = CommandLine.arguments
if args.count >= 4, args[1] == "--watchdog", let parent = Int32(args[2]) {
    Watchdog.run(parentPID: parent, stateFile: URL(fileURLWithPath: args[3]))
} else if args.count >= 2, args[1] == "--install-helper" {
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        let (ok, msg) = await HelperClient().install()
        print(ok ? "helper: \(msg)" : "helper install failed: \(msg)")
        exit(ok ? 0 : 1)
    }
    sem.wait()
} else {
    NeverSleepApp.main()
}
