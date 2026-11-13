import Foundation

/// Open-at-login via a per-user LaunchAgent (~/Library/LaunchAgents/com.neversleep.app.plist).
/// Chosen over SMAppService.mainApp because ad-hoc signed rebuilds confuse Background Task
/// Management. KeepAlive/SuccessfulExit=false also relaunches NeverSleep if it crashes
/// (a normal Quit exits 0 and is not relaunched).
enum LoginItem {
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.neversleep.app.plist")
    }

    static func sync(enabled: Bool) {
        let fm = FileManager.default
        guard enabled else {
            try? fm.removeItem(at: plistURL)
            return
        }
        guard let exe = Bundle.main.executableURL?.path, exe.hasPrefix("/Applications/") else { return }
        let plist: [String: Any] = [
            "Label": "com.neversleep.app",
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        if (try? Data(contentsOf: plistURL)) == data { return }
        try? fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: plistURL, options: .atomic)
        // Not bootstrapped now (that would start a second copy); launchd loads it at next login.
    }
}
