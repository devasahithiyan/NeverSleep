import Foundation

public struct RunningApp: Equatable, Sendable {
    public let pid: Int32
    public let bundleID: String?
    public let name: String
    public init(pid: Int32, bundleID: String?, name: String) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
    }
}

public enum PauseSource: String, Codable, Sendable {
    /// Paused automatically because the lid closed. Resumed when the lid opens.
    case lidMode
    /// Paused by hand from the dashboard. Stays paused until resumed by hand (or NeverSleep quits).
    case manual
}

/// One process we sent SIGSTOP to. `startTime` guards against PID reuse:
/// we only SIGCONT a PID whose process start time still matches.
public struct PausedRecord: Codable, Equatable, Sendable {
    public let pid: Int32
    public let bundleID: String?
    public let name: String
    public let startTime: UInt64
    public let source: PauseSource
    public init(pid: Int32, bundleID: String?, name: String, startTime: UInt64, source: PauseSource) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.startTime = startTime
        self.source = source
    }
}

/// What the engine persists so a later launch (or the watchdog) can undo our changes.
public struct PersistedState: Codable, Equatable, Sendable {
    public var paused: [PausedRecord] = []
    /// True between a successful `disablesleep 1` and the matching `disablesleep 0`.
    public var sleepDisabled = false
    public init(paused: [PausedRecord] = [], sleepDisabled: Bool = false) {
        self.paused = paused
        self.sleepDisabled = sleepDisabled
    }
}

public enum ThermalLevel: Int, Comparable, Sendable {
    case nominal = 0, fair, serious, critical
    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }
    public var name: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        }
    }
}

public struct PowerReading: Equatable, Sendable {
    /// nil on desktops / when no battery is present.
    public var batteryPercent: Int?
    public var onACPower: Bool
    public init(batteryPercent: Int?, onACPower: Bool) {
        self.batteryPercent = batteryPercent
        self.onACPower = onACPower
    }
}

public struct LidModeConfig: Equatable, Sendable {
    public var allowList: Set<String> = []
    public var quitInsteadOfPause: Set<String> = []
    public var batteryCutoffPercent: Int = 20
    public var sleepDisplayOnEngage: Bool = true
    /// Bundle IDs that are never signalled even if they are not on the allow-list.
    public var protectedBundleIDs: Set<String> = LidModeConfig.defaultProtected
    /// PIDs that are never signalled (our own app, our watchdog).
    public var protectedPIDs: Set<Int32> = []

    public static let defaultProtected: Set<String> = [
        "com.apple.finder",
        "com.apple.loginwindow",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.WindowManager",
        "com.apple.Spotlight",
        "com.apple.ActivityMonitor",
        "com.apple.systempreferences",
        "com.apple.SecurityAgent",
        "com.apple.coreservices.uiagent",
    ]

    public init() {}
}
