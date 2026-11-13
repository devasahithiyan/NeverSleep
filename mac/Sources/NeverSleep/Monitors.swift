import Foundation
import IOKit
import IOKit.ps
import NeverSleepCore

/// Watches `AppleClamshellState` on IOPMrootDomain. Uses an IOKit interest notification
/// (fires on clamshell changes, among other power messages) and also polls every 2 s as a
/// fallback, because interest messages are not guaranteed for every hardware/OS combination.
final class LidMonitor {
    /// (closed, source) where source is "IOKit notification" or "2 s poll".
    var onChange: ((Bool, String) -> Void)?
    private(set) var isClosed: Bool = false
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var root: io_service_t = 0
    private var timer: Timer?

    static func readClamshellClosed(root: io_service_t? = nil) -> Bool? {
        let svc = root ?? IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard svc != 0 else { return nil }
        defer { if root == nil { IOObjectRelease(svc) } }
        let prop = IORegistryEntryCreateCFProperty(svc, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return prop?.takeRetainedValue() as? Bool
    }

    /// False on Macs without a lid (no AppleClamshellState property).
    static var hasLid: Bool { readClamshellClosed() != nil }

    func start() {
        root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        isClosed = Self.readClamshellClosed(root: root) ?? false
        if root != 0, let p = IONotificationPortCreate(kIOMainPortDefault) {
            port = p
            IONotificationPortSetDispatchQueue(p, .main)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            IOServiceAddInterestNotification(p, root, kIOGeneralInterest, { refcon, _, _, _ in
                guard let refcon else { return }
                Unmanaged<LidMonitor>.fromOpaque(refcon).takeUnretainedValue().poll(source: "IOKit notification")
            }, refcon, &notifier)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll(source: "2 s poll") }
        timer?.tolerance = 0.5
    }

    func poll(source: String) {
        guard let closed = Self.readClamshellClosed(root: root == 0 ? nil : root) else { return }
        if closed != isClosed {
            isClosed = closed
            onChange?(closed, source)
        }
    }

    deinit {
        timer?.invalidate()
        if notifier != 0 { IOObjectRelease(notifier) }
        if let port { IONotificationPortDestroy(port) }
        if root != 0 { IOObjectRelease(root) }
    }
}

struct BatteryInfo: Equatable {
    var present = false
    var percent: Int?
    var charging = false
    var onAC = true
    var timeToEmptyMin: Int?
    var timeToFullMin: Int?

    var powerReading: PowerReading { PowerReading(batteryPercent: present ? percent : nil, onACPower: onAC) }

    static func read() -> BatteryInfo {
        var out = BatteryInfo()
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return out }
        if let src = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
            out.onAC = (src == kIOPSACPowerValue)
        }
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return out }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            out.present = (desc[kIOPSIsPresentKey] as? Bool) ?? true
            if let cur = desc[kIOPSCurrentCapacityKey] as? Int, let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                out.percent = Int((Double(cur) / Double(max) * 100).rounded())
            }
            out.charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            if let t = desc[kIOPSTimeToEmptyKey] as? Int, t > 0 { out.timeToEmptyMin = t }
            if let t = desc[kIOPSTimeToFullChargeKey] as? Int, t > 0 { out.timeToFullMin = t }
            if let state = desc[kIOPSPowerSourceStateKey] as? String { out.onAC = (state == kIOPSACPowerValue) }
            break
        }
        return out
    }
}

/// Battery (IOPowerSources change notifications + 60 s poll) and thermal state.
final class PowerMonitor {
    var onBattery: ((BatteryInfo) -> Void)?
    var onThermal: ((ThermalLevel) -> Void)?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var thermalObserver: NSObjectProtocol?

    static func thermalLevel() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .critical
        }
    }

    func start() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue().fire()
        }, ctx)?.takeRetainedValue() {
            source = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.fire() }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.onThermal?(Self.thermalLevel()) }
        fire()
        onThermal?(Self.thermalLevel())
    }

    func fire() { onBattery?(BatteryInfo.read()) }

    deinit {
        timer?.invalidate()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
    }
}
