import Foundation

/// Identifiers shared by the app, the helper and the build script.
public enum NeverSleepIDs {
    public static let appBundleID = "com.neversleep.app"
    public static let helperLabel = "com.neversleep.helper"
    /// Mach service name the helper's launchd plist publishes.
    public static let helperMachService = "com.neversleep.helper"
    /// File name of the plist inside NeverSleep.app/Contents/Library/LaunchDaemons/.
    public static let helperPlistName = "com.neversleep.helper.plist"
}

/// The entire privileged surface: one call. Nothing else is exported over XPC.
@objc public protocol NeverSleepHelperProtocol {
    /// Runs `/usr/bin/pmset -a disablesleep 1|0` as root.
    /// Reply: (success, error message or nil).
    func setDisableSleep(_ disabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)
}
