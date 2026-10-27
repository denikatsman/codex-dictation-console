import AppKit
import DictationArchiveCore
import Foundation

@main
enum CaptureHelperMain {
    static func main() {
        if CommandLine.arguments.contains("--verify") {
            runVerification()
            return
        }
        if CommandLine.arguments.contains("--scan-once") {
            runSingleScan()
            return
        }

        do {
            // Login registration and a manual open can arrive independently.
            // A duplicate exits before installing a menu or starting a scan;
            // it never interrupts the helper that already owns capture.
            guard let lifetime = try CaptureHelperLifetime.acquire() else { return }
            let application = NSApplication.shared
            let delegate = CaptureHelperDelegate()
            application.delegate = delegate
            application.setActivationPolicy(.accessory)
            application.run()
            // applicationWillTerminate drains the monitor before ownership is
            // released. The OS also releases the descriptor after a crash.
            withExtendedLifetime((delegate, lifetime)) {}
        } catch {
            FileHandle.standardError.write(Data(
                "Background capture could not claim helper ownership: \(error.localizedDescription)\n".utf8
            ))
            exit(EXIT_FAILURE)
        }
    }

    private static func runSingleScan() {
        do {
            let result = try DictationCaptureEngine(processKind: .manual).scan()
            let data = try JSONEncoder.archiveEncoder.encode(result)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func runVerification() {
        do {
            let result = try ArchiveStore().verifyArchivedFiles()
            let data = try JSONEncoder.archiveEncoder.encode(result)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            if !result.isHealthy { exit(EXIT_FAILURE) }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}

/// A headless worker: the main app owns the only menu/Dock surfaces.
private final class CaptureHelperDelegate: NSObject, NSApplicationDelegate {
    private var monitor: CaptureMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor = CaptureMonitor(engine: DictationCaptureEngine(processKind: .helper)) { result in
            if case .success(let scan) = result, scan.importedCount > 0 || scan.updatedCount > 0 {
                DistributedNotificationCenter.default().postNotificationName(ArchiveStore.didChangeNotification,
                    object: nil, userInfo: nil, deliverImmediately: true)
            }
        }
        monitor?.start()
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(settingsChanged),
            name: Notification.Name("local.codex-dictation-console.capture-settings-changed"), object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        monitor?.stop(capturePendingChanges: true)
    }
    @objc private func systemDidWake(_ notification: Notification) { monitor?.rescanAfterWake() }
    @objc private func settingsChanged(_ notification: Notification) { monitor?.scanNow() }
}
