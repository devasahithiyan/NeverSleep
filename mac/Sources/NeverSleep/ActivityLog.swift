import Foundation
import os

/// Persistent activity log: ~/Library/Logs/NeverSleep/activity.log (rotated at 1 MB, 3 old files
/// kept), mirrored to the unified log at .notice level (subsystem com.neversleep.app), and kept
/// in memory for the menu, the Settings › Activity tab and the remote dashboard.
///
///   tail -f ~/Library/Logs/NeverSleep/activity.log
///   log show --last 1h --predicate 'subsystem == "com.neversleep.app"'
@MainActor
final class ActivityLog: ObservableObject {
    static let shared = ActivityLog()

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let kind: String
        let message: String
    }

    @Published private(set) var recent: [Entry] = []
    private static let keepInMemory = 300

    nonisolated static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/NeverSleep", isDirectory: true)
    }
    nonisolated static var fileURL: URL { directory.appendingPathComponent("activity.log") }

    private init() {
        recent = Self.loadTail()
    }

    func record(_ kind: String, _ message: String) {
        let entry = Entry(date: Date(), kind: kind, message: message)
        recent.append(entry)
        if recent.count > Self.keepInMemory { recent.removeFirst(recent.count - Self.keepInMemory) }
        Logger(subsystem: "com.neversleep.app", category: kind).notice("\(message, privacy: .public)")
        Self.appendLine(kind: kind, message: message, date: entry.date)
    }

    // MARK: File (also used by the watchdog process)

    nonisolated(unsafe) private static let stamp: ISO8601DateFormatter = {   // thread-safe class
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    nonisolated static func appendLine(kind: String, message: String, date: Date = Date()) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        rotateIfNeeded()
        let clean = message.replacingOccurrences(of: "\n", with: " ")
        let line = "\(stamp.string(from: date)) [\(kind)] \(clean)\n"
        let fd = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        _ = line.withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }

    nonisolated private static func rotateIfNeeded() {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber,
              size.intValue > 1_000_000 else { return }
        for i in stride(from: 3, through: 1, by: -1) {
            let src = i == 1 ? fileURL : directory.appendingPathComponent("activity.\(i - 1).log")
            let dst = directory.appendingPathComponent("activity.\(i).log")
            try? fm.removeItem(at: dst)
            try? fm.moveItem(at: src, to: dst)
        }
    }

    /// Last entries from the file, so the menu shows history across restarts.
    private static func loadTail() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n").suffix(keepInMemory)
        return lines.compactMap { line -> Entry? in
            // "<date> [kind] message"
            guard let sp = line.firstIndex(of: " "),
                  let date = stamp.date(from: String(line[..<sp])) else { return nil }
            let rest = line[line.index(after: sp)...]
            guard rest.hasPrefix("["), let close = rest.firstIndex(of: "]") else { return nil }
            let kind = String(rest[rest.index(after: rest.startIndex)..<close])
            let msg = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return Entry(date: date, kind: kind, message: msg)
        }
    }
}
