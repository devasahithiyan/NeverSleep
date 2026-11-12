import Foundation
import Security
import Darwin

public enum CodeRequirement {
    /// Returns the designated requirement string of the code at `url`
    /// (an .app bundle or a Mach-O binary), or nil if it is unsigned/unreadable.
    ///
    /// The app and the helper use each other's designated requirement for
    /// `NSXPCConnection.setCodeSigningRequirement`, so whatever identity signs the
    /// bundle (Developer ID or ad-hoc), only that exact signer can talk to the other side.
    /// For ad-hoc builds the designated requirement pins the exact cdhash.
    public static func designatedRequirement(of url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return nil }
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &req) == errSecSuccess, let r = req else { return nil }
        var str: CFString?
        guard SecRequirementCopyString(r, [], &str) == errSecSuccess, let s = str else { return nil }
        return s as String
    }

    /// Absolute path of the running executable, from the kernel. Do not use argv[0]: launchd
    /// starts SMAppService daemons with a *relative* argv[0] ("Contents/MacOS/NeverSleepHelper").
    public static func currentExecutableURL() -> URL? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(getpid(), &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath()
    }

    /// NeverSleep.app/Contents/MacOS/NeverSleepHelper -> NeverSleep.app
    public static func enclosingAppBundle(ofExecutable exe: URL) -> URL? {
        let macOS = exe.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return nil }
        return app
    }
}
