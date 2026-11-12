import Foundation

/// Turns `pmset disablesleep` on/off (via the privileged helper in the real app).
public protocol SleepControlling: AnyObject {
    func setDisableSleep(_ disabled: Bool) async throws
}

/// Process operations. The real implementation uses NSWorkspace + kill(2).
public protocol ProcessControlling: AnyObject {
    /// Running apps with activationPolicy == .regular.
    func runningRegularApps() -> [RunningApp]
    /// Kernel start time of `pid` (microseconds since epoch), nil if it no longer exists.
    func startTime(of pid: Int32) -> UInt64?
    func sendStop(_ pid: Int32) -> Bool
    func sendCont(_ pid: Int32) -> Bool
    /// Ask the app to quit normally (like Cmd-Q).
    func requestQuit(_ pid: Int32) -> Bool
    func sleepDisplay()
    /// Put the whole Mac to sleep now (used after a safety cutoff while the lid is closed).
    func sleepSystemNow()
}

public protocol StateStore: AnyObject {
    func load() -> PersistedState
    func save(_ state: PersistedState)
}

public final class MemoryStateStore: StateStore {
    public var state = PersistedState()
    public init() {}
    public func load() -> PersistedState { state }
    public func save(_ state: PersistedState) { self.state = state }
}
