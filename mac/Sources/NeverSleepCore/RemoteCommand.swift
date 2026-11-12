import Foundation

/// The complete, fixed set of things the remote dashboard can ask the Mac to do.
/// Anything that does not parse into one of these cases is rejected. There is no
/// generic "run this" command by design.
public enum RemoteCommand: Equatable, Sendable {
    case refresh
    case listInstalledApps
    case quitApp(pid: Int32)
    case forceQuitApp(pid: Int32)
    case pauseApp(pid: Int32)
    case resumeApp(pid: Int32)
    case launchApp(bundleID: String)
    case setLidMode(enabled: Bool)
    case setAllowList(bundleIDs: [String])
    case setQuitInsteadOfPause(bundleID: String, enabled: Bool)

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknownCommand(String)
        case badArgs(String)
        public var description: String {
            switch self {
            case .unknownCommand(let c): return "unknown command: \(c)"
            case .badArgs(let m): return "bad arguments: \(m)"
            }
        }
    }

    public static let maxAllowList = 500

    public static func isValidBundleID(_ s: String) -> Bool {
        guard (1...200).contains(s.utf8.count) else { return false }
        return s.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    public static func parse(cmd: String, args: [String: Any]) throws -> RemoteCommand {
        func exactKeys(_ keys: Set<String>) throws {
            let got = Set(args.keys)
            guard got == keys else { throw ParseError.badArgs("expected keys \(keys.sorted()), got \(got.sorted())") }
        }
        func pid() throws -> Int32 {
            try exactKeys(["pid"])
            // JSONSerialization gives NSNumber; reject bools and non-integers.
            guard let n = args["pid"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue == n.doubleValue.rounded(), n.int64Value > 1, n.int64Value < Int64(Int32.max)
            else { throw ParseError.badArgs("pid must be an integer > 1") }
            return Int32(n.int64Value)
        }
        func bool(_ key: String) throws -> Bool {
            guard let n = args[key] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
                throw ParseError.badArgs("\(key) must be a boolean")
            }
            return n.boolValue
        }
        func bundleID(_ key: String) throws -> String {
            guard let s = args[key] as? String, isValidBundleID(s) else {
                throw ParseError.badArgs("\(key) must be a bundle identifier")
            }
            return s
        }

        switch cmd {
        case "refresh": try exactKeys([]); return .refresh
        case "listInstalledApps": try exactKeys([]); return .listInstalledApps
        case "quitApp": return .quitApp(pid: try pid())
        case "forceQuitApp": return .forceQuitApp(pid: try pid())
        case "pauseApp": return .pauseApp(pid: try pid())
        case "resumeApp": return .resumeApp(pid: try pid())
        case "launchApp":
            try exactKeys(["bundleId"])
            return .launchApp(bundleID: try bundleID("bundleId"))
        case "setLidMode":
            try exactKeys(["enabled"])
            return .setLidMode(enabled: try bool("enabled"))
        case "setAllowList":
            try exactKeys(["bundleIds"])
            guard let list = args["bundleIds"] as? [Any], list.count <= maxAllowList else {
                throw ParseError.badArgs("bundleIds must be an array of at most \(maxAllowList)")
            }
            var out: [String] = []
            for item in list {
                guard let s = item as? String, isValidBundleID(s) else { throw ParseError.badArgs("invalid bundle id") }
                if !out.contains(s) { out.append(s) }
            }
            return .setAllowList(bundleIDs: out)
        case "setQuitInsteadOfPause":
            try exactKeys(["bundleId", "enabled"])
            return .setQuitInsteadOfPause(bundleID: try bundleID("bundleId"), enabled: try bool("enabled"))
        default:
            throw ParseError.unknownCommand(String(cmd.prefix(64)))
        }
    }
}
