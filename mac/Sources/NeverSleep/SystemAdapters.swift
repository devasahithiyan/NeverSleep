import AppKit
import Darwin
import NeverSleepCore

enum ProcessInfoReader {
    /// Kernel process start time in microseconds, used to make sure a PID still names the
    /// same process before we signal it.
    static func startTime(of pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
    }
}

/// JSON file in ~/Library/Application Support/NeverSleep/state.json, written atomically.
final class FileStateStore: StateStore {
    let url: URL
    init(url: URL) { self.url = url }

    static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeverSleep", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    func load() -> PersistedState {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(PersistedState.self, from: data) else { return PersistedState() }
        return s
    }

    func save(_ state: PersistedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

final class SystemProcessController: ProcessControlling {
    func runningRegularApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier > 1 }
            .map { RunningApp(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier,
                              name: $0.localizedName ?? $0.bundleIdentifier ?? "pid \($0.processIdentifier)") }
    }

    func startTime(of pid: Int32) -> UInt64? { ProcessInfoReader.startTime(of: pid) }

    func sendStop(_ pid: Int32) -> Bool { kill(pid, SIGSTOP) == 0 }
    func sendCont(_ pid: Int32) -> Bool { kill(pid, SIGCONT) == 0 }

    func requestQuit(_ pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.terminate() ?? false
    }

    func forceQuit(_ pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.forceTerminate() ?? false
    }

    func sleepDisplay() { Self.pmset(["displaysleepnow"]) }
    func sleepSystemNow() { Self.pmset(["sleepnow"]) }

    private static func pmset(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// Reads `SleepDisabled` from `pmset -g` (no root needed).
    static func isSleepDisabledSystemWide() -> Bool? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        for line in out.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.first == "SleepDisabled", parts.count >= 2 { return parts[1] == "1" }
        }
        return false
    }
}

struct InstalledApp: Identifiable, Hashable, Codable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let path: String
}

enum InstalledAppScanner {
    static func scan() -> [InstalledApp] {
        let fm = FileManager.default
        var roots = ["/Applications", "/Applications/Utilities", "/System/Applications",
                     "/System/Applications/Utilities"].map { URL(fileURLWithPath: $0) }
        roots.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))
        var seen: [String: InstalledApp] = [:]
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            var candidates: [URL] = []
            for item in items {
                if item.pathExtension == "app" { candidates.append(item); continue }
                // One level of folders (e.g. /Applications/Microsoft Office/…)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue,
                   let sub = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                    candidates += sub.filter { $0.pathExtension == "app" }
                }
            }
            for url in candidates {
                guard let b = Bundle(url: url), let bid = b.bundleIdentifier,
                      RemoteCommand.isValidBundleID(bid), seen[bid] == nil else { continue }
                let name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                seen[bid] = InstalledApp(bundleID: bid, name: name, path: url.path)
            }
        }
        return seen.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
