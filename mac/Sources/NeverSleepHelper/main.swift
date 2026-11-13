import Foundation
import NeverSleepShared
import os

// Privileged launch daemon. Registered by the app with SMAppService.daemon and approved
// once by the user in System Settings > General > Login Items & Extensions.
//
// Surface: exactly one XPC method, setDisableSleep(Bool). Callers must satisfy the
// designated code-signing requirement of the NeverSleep.app bundle this binary lives in.
//
// Safety: if the client that turned sleep off disconnects (quit, crash, kill -9), the
// helper turns sleep back on. A marker file covers helper restarts and reboots.

let log = Logger(subsystem: NeverSleepIDs.helperLabel, category: "helper")
let markerDir = URL(fileURLWithPath: "/Library/Application Support/NeverSleep", isDirectory: true)
let markerFile = markerDir.appendingPathComponent("disablesleep.on")
let logFile = URL(fileURLWithPath: "/Library/Logs/NeverSleep/helper.log")

/// Notice-level unified log + /Library/Logs/NeverSleep/helper.log (world-readable, rotated at 512 KB).
func record(_ message: String) {
    log.notice("\(message, privacy: .public)")
    let fm = FileManager.default
    try? fm.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let size = (try? fm.attributesOfItem(atPath: logFile.path))?[.size] as? NSNumber, size.intValue > 512_000 {
        let old = logFile.deletingPathExtension().appendingPathExtension("1.log")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: logFile, to: old)
    }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = .current
    let line = "\(f.string(from: Date())) \(message)\n"
    let fd = open(logFile.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return }
    _ = line.withCString { write(fd, $0, strlen($0)) }
    close(fd)
}

@discardableResult
func runPmset(disable: Bool) -> (Bool, String?) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-a", "disablesleep", disable ? "1" : "0"]
    let errPipe = Pipe()
    p.standardError = errPipe
    p.standardOutput = FileHandle.nullDevice
    do {
        try p.run()
        p.waitUntilExit()
    } catch {
        return (false, "pmset failed to start: \(error.localizedDescription)")
    }
    guard p.terminationStatus == 0 else {
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (false, "pmset exited \(p.terminationStatus): \(err)")
    }
    if disable {
        try? FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: markerFile.path, contents: Data())
    } else {
        try? FileManager.default.removeItem(at: markerFile)
    }
    return (true, nil)
}

final class HelperService: NSObject, NeverSleepHelperProtocol {
    weak var connection: NSXPCConnection?
    /// True if this connection last asked for sleep to be disabled.
    var holdsDisable = false

    func setDisableSleep(_ disabled: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
        let pid = connection?.processIdentifier ?? -1
        let (ok, err) = runPmset(disable: disabled)
        record("setDisableSleep(\(disabled)) from pid \(pid): \(ok ? "ok" : "FAILED \(err ?? "")")")
        if ok { holdsDisable = disabled }
        reply(ok, err)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let requirement: String?

    override init() {
        let exe = CodeRequirement.currentExecutableURL()
        record("helper starting (pid \(getpid())) from \(exe?.path ?? "?")")
        if let exe, let app = CodeRequirement.enclosingAppBundle(ofExecutable: exe) {
            // Registered with SMAppService: live inside NeverSleep.app, trust that bundle's signer.
            requirement = CodeRequirement.designatedRequirement(of: app)
        } else {
            // Installed as a standard launch daemon by install-helper.sh: the app's requirement
            // was pinned at install time in a root-owned, non-writable file.
            requirement = ListenerDelegate.pinnedRequirement()
        }
        super.init()
        if let r = requirement {
            record("accepting clients that satisfy: \(r)")
        } else {
            record("ERROR: no client requirement found; refusing all clients")
        }
    }

    static func pinnedRequirement() -> String? {
        let path = markerDir.appendingPathComponent("client-requirement").path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0,
              let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue, perms & 0o022 == 0,
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        let req = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return req.isEmpty ? nil : req
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        guard let requirement else {
            record("rejecting pid \(conn.processIdentifier): no client requirement")
            return false
        }
        // The kernel/XPC runtime enforces this on every message, using the audit token,
        // so there is no PID-reuse race.
        conn.setCodeSigningRequirement(requirement)
        conn.exportedInterface = NSXPCInterface(with: NeverSleepHelperProtocol.self)
        let service = HelperService()
        service.connection = conn
        conn.exportedObject = service
        let restore = { [weak service] in
            guard let service, service.holdsDisable else { return }
            record("client went away while sleep was disabled; re-enabling sleep")
            runPmset(disable: false)
            service.holdsDisable = false
        }
        conn.invalidationHandler = restore
        conn.interruptionHandler = restore
        conn.resume()
        record("client connected: pid \(conn.processIdentifier) (signature checked on every message)")
        return true
    }
}

// Leftover from a crash of the helper itself or a reboot while lid mode was active.
if FileManager.default.fileExists(atPath: markerFile.path) {
    record("found stale disablesleep marker; re-enabling sleep")
    runPmset(disable: false)
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: NeverSleepIDs.helperMachService)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
