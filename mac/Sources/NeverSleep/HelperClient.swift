import Foundation
import ServiceManagement
import NeverSleepShared
import NeverSleepCore
import os

let appLog = Logger(subsystem: NeverSleepIDs.appBundleID, category: "app")

/// Talks to the privileged helper, installed as a standard launch daemon
/// (/Library/LaunchDaemons/com.neversleep.helper.plist → /Library/PrivilegedHelperTools/…)
/// by Support/install-helper.sh through the macOS administrator prompt.
///
/// Why not SMAppService.daemon: with ad-hoc signed builds every rebuild looks like a new app to
/// Background Task Management, which piles up stale approval records until the daemon can no
/// longer be enabled. A plain launch daemon has no such approval state.
///
/// Falls back to `sudo -n pmset` if the user installed the optional sudoers rule (README).
final class HelperClient: SleepControlling {
    enum HelperError: LocalizedError {
        case notInstalled, xpc(String), helper(String), timeout
        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "The NeverSleep helper is not installed. Open Settings › Helper and click Install."
            case .xpc(let m): return "XPC error: \(m). If NeverSleep was just updated, open Settings › Helper and click Install again."
            case .helper(let m): return m
            case .timeout: return "The helper did not answer in time."
            }
        }
    }

    static let plistPath = "/Library/LaunchDaemons/\(NeverSleepIDs.helperLabel).plist"
    static let installedHelperPath = "/Library/PrivilegedHelperTools/\(NeverSleepIDs.helperLabel)"
    static let pinnedRequirementPath = "/Library/Application Support/NeverSleep/client-requirement"

    private var connection: NSXPCConnection?
    private let lock = NSLock()

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.plistPath)
            && FileManager.default.fileExists(atPath: Self.installedHelperPath)
    }

    /// True when the helper was installed for a different build of NeverSleep (it would refuse us).
    var needsReinstall: Bool {
        guard isInstalled,
              let pinned = try? String(contentsOfFile: Self.pinnedRequirementPath, encoding: .utf8),
              let mine = CodeRequirement.designatedRequirement(of: Bundle.main.bundleURL) else { return false }
        return pinned.trimmingCharacters(in: .whitespacesAndNewlines) != mine
    }

    var statusText: String {
        if !isInstalled { return "Not installed" }
        if needsReinstall { return "Installed for an older build — click Install to update" }
        return "Installed"
    }

    // MARK: Install / uninstall (macOS administrator prompt)

    private func runInstaller(_ args: [String]) -> (Bool, String) {
        guard let script = Bundle.main.url(forResource: "install-helper", withExtension: "sh") else {
            return (false, "install-helper.sh is missing from the app bundle")
        }
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let shell = (["/bin/bash", script.path] + args).map(q).joined(separator: " ")
        let apple = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges with prompt \"NeverSleep needs to install its helper that keeps the Mac awake with the lid closed.\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", apple]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return (false, error.localizedDescription) }
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus == 0, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Removes the old SMAppService registration (if any) so it can't clash with the daemon label.
    private func removeLegacyRegistration() async {
        let svc = SMAppService.daemon(plistName: NeverSleepIDs.helperPlistName)
        if svc.status != .notRegistered && svc.status != .notFound {
            try? await svc.unregister()
        }
    }

    func install() async -> (Bool, String) {
        await removeLegacyRegistration()
        dropConnection()
        let r = runInstaller(["install", Bundle.main.bundleURL.path])
        return r
    }

    func uninstall() async -> (Bool, String) {
        await removeLegacyRegistration()
        dropConnection()
        return runInstaller(["uninstall"])
    }

    // MARK: XPC

    private func dropConnection() {
        lock.lock(); defer { lock.unlock() }
        connection?.invalidate()
        connection = nil
    }

    private func proxyConnection() -> NSXPCConnection {
        lock.lock(); defer { lock.unlock() }
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: NeverSleepIDs.helperMachService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: NeverSleepHelperProtocol.self)
        // Only talk to the root-owned helper we installed.
        if let req = CodeRequirement.designatedRequirement(of: URL(fileURLWithPath: Self.installedHelperPath)) {
            c.setCodeSigningRequirement(req)
        }
        c.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.connection = nil; self.lock.unlock()
        }
        c.resume()
        connection = c
        return c
    }

    func setDisableSleep(_ disabled: Bool) async throws {
        if isInstalled {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let once = OnceFlag()
                let proxy = proxyConnection().remoteObjectProxyWithErrorHandler { err in
                    if once.claim() { cont.resume(throwing: HelperError.xpc(err.localizedDescription)) }
                } as? NeverSleepHelperProtocol
                guard let proxy else {
                    if once.claim() { cont.resume(throwing: HelperError.xpc("no proxy")) }
                    return
                }
                proxy.setDisableSleep(disabled) { ok, msg in
                    guard once.claim() else { return }
                    if ok { cont.resume() } else { cont.resume(throwing: HelperError.helper(msg ?? "pmset failed")) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                    if once.claim() { cont.resume(throwing: HelperError.timeout) }
                }
            }
            return
        }
        // Fallback: passwordless sudo rule limited to `pmset -a disablesleep 0|1` (see README).
        if Self.sudoFallback(disabled) { return }
        throw HelperError.notInstalled
    }

    /// Blocking variant for applicationWillTerminate / signal handlers.
    @discardableResult
    func setDisableSleepSync(_ disabled: Bool, timeout: TimeInterval = 3) -> Bool {
        if isInstalled {
            let sem = DispatchSemaphore(value: 0)
            var result = false
            let proxy = proxyConnection().remoteObjectProxyWithErrorHandler { _ in sem.signal() } as? NeverSleepHelperProtocol
            proxy?.setDisableSleep(disabled) { ok, _ in result = ok; sem.signal() }
            _ = sem.wait(timeout: .now() + timeout)
            if result { return true }
        }
        return Self.sudoFallback(disabled)
    }

    private static func sudoFallback(_ disabled: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

final class OnceFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
