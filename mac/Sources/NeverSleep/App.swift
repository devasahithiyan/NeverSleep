import SwiftUI
import AppKit
import NeverSleepCore

struct NeverSleepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(model)
                .environmentObject(model.engine)
                .environmentObject(model.relay)
        } label: {
            Image(systemName: Self.symbol(for: model.engine.phase))
        }
        .menuBarExtraStyle(.window)

        Window("NeverSleep Settings", id: "settings") {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.engine)
                .environmentObject(model.relay)
                .frame(minWidth: 620, minHeight: 520)
        }
        .windowResizability(.contentSize)
    }

    /// off / armed / active (lid closed, apps paused) / cutoff
    static func symbol(for phase: LidModeEngine.Phase) -> String {
        switch phase {
        case .off: return "moon.zzz"
        case .armed: return "laptopcomputer"
        case .active: return "bolt.fill"
        case .cutoff: return "exclamationmark.triangle"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.start() }
        // Restore on SIGTERM/SIGINT/SIGHUP too (e.g. `killall NeverSleep`, logout scripts).
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                MainActor.assumeIsolated { AppModel.shared.emergencyRestore() }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.emergencyRestore() }
    }
}
