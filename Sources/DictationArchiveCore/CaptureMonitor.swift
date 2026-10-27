import Darwin
import Foundation

public final class CaptureMonitor: @unchecked Sendable {
    public typealias ResultHandler = @Sendable (Result<CaptureScanResult, Error>) -> Void

    private let engine: DictationCaptureEngine
    private let queue = DispatchQueue(label: "CodexDictationLab.CaptureMonitor", autoreleaseFrequency: .workItem)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let resultHandler: ResultHandler?
    private var parentWatcher: DispatchSourceFileSystemObject?
    private var parentPath: String?
    private var rootWatcher: DispatchSourceFileSystemObject?
    private var folderWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var timer: DispatchSourceTimer?
    private var pendingScan: DispatchWorkItem?
    private var isStarted = false
    private var wakeRecoveryPending = false

    public init(
        engine: DictationCaptureEngine,
        resultHandler: ResultHandler? = nil
    ) {
        self.engine = engine
        self.resultHandler = resultHandler
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { stop() }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.isStarted else { return }
            self.isStarted = true
            self.installWatchers()
            self.installTimer()
            self.performScan()
        }
    }

    public func stop(capturePendingChanges: Bool = false) {
        let finish = {
            if capturePendingChanges, self.isStarted { self.performScan() }
            self.isStarted = false
            self.wakeRecoveryPending = false
            self.pendingScan?.cancel()
            self.pendingScan = nil
            self.clearWatchers()
            self.timer?.cancel()
            self.timer = nil
        }
        // Result handlers may stop the monitor from its own serial queue.
        if DispatchQueue.getSpecific(key: queueKey) == true { finish() }
        else { queue.sync(execute: finish) }
    }

    public func scanNow() {
        queue.async { [weak self] in
            self?.scheduleScan(after: .milliseconds(50))
        }
    }

    public func rescanAfterWake() {
        queue.async { [weak self] in
            guard let self, self.isStarted, !self.wakeRecoveryPending else { return }
            self.wakeRecoveryPending = true
            // Reopen descriptors in case the source was replaced while asleep.
            self.clearWatchers()
            self.installWatchers()
            self.scheduleScan(after: .milliseconds(100))
        }
    }

    private func clearWatchers() {
        parentWatcher?.cancel()
        parentWatcher = nil
        parentPath = nil
        rootWatcher?.cancel()
        rootWatcher = nil
        folderWatchers.values.forEach { $0.cancel() }
        folderWatchers.removeAll()
    }

    private func installTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(15), repeating: .seconds(15), leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.performScan()
        }
        timer.resume()
        self.timer = timer
    }

    private func installWatchers() {
        installRootWatcherIfNeeded()
        rebuildFolderWatchers()
    }

    private func installRootWatcherIfNeeded() {
        guard rootWatcher == nil else { return }
        let path = engine.sourceURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            installParentWatcher()
            return
        }
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke],
            queue: queue
        )
        watcher.setEventHandler { [weak self, weak watcher] in
            guard let self, let watcher, self.rootWatcher === watcher else { return }
            let flags = watcher.data
            if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
                watcher.cancel()
                self.rootWatcher = nil
            }
            self.scheduleScan(after: .milliseconds(200))
        }
        watcher.setCancelHandler { close(descriptor) }
        watcher.resume()
        rootWatcher = watcher
        parentWatcher?.cancel()
        parentWatcher = nil
        parentPath = nil
    }

    private func installParentWatcher() {
        // Codex may not have created its history directory yet at login.
        // Watch the nearest existing ancestor until the source appears.
        var parent = engine.sourceURL.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: parent.path), parent.path != "/" {
            parent.deleteLastPathComponent()
        }
        guard parentPath != parent.path else { return }
        parentWatcher?.cancel()
        parentWatcher = nil
        parentPath = nil
        let descriptor = open(parent.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .revoke], queue: queue
        )
        watcher.setEventHandler { [weak self, weak watcher] in
            guard let self, let watcher, self.parentWatcher === watcher else { return }
            if !watcher.data.intersection([.rename, .delete, .revoke]).isEmpty {
                watcher.cancel()
                self.parentWatcher = nil
                self.parentPath = nil
            }
            self.scheduleScan(after: .milliseconds(150))
        }
        watcher.setCancelHandler { close(descriptor) }
        parentPath = parent.path
        parentWatcher = watcher
        watcher.resume()
    }

    private func rebuildFolderWatchers() {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: engine.sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            folderWatchers.values.forEach { $0.cancel() }
            folderWatchers.removeAll()
            return
        }

        let validFolders = folders.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let paths = Set(validFolders.map(\.path))
        for path in folderWatchers.keys.filter({ !paths.contains($0) }) {
            folderWatchers.removeValue(forKey: path)?.cancel()
        }
        for folder in validFolders where folderWatchers[folder.path] == nil {
            let descriptor = open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let watcher = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke],
                queue: queue
            )
            watcher.setEventHandler { [weak self, weak watcher] in
                guard let self, let watcher, self.folderWatchers[folder.path] === watcher else { return }
                let flags = watcher.data
                if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
                    watcher.cancel()
                    self.folderWatchers.removeValue(forKey: folder.path)
                }
                self.scheduleScan(after: .milliseconds(150))
            }
            watcher.setCancelHandler { close(descriptor) }
            watcher.resume()
            folderWatchers[folder.path] = watcher
        }
    }

    private func scheduleScan(after delay: DispatchTimeInterval) {
        // Bound the wait from the first event. Repeated writes must not push
        // preservation back until the 15-second reconciliation timer fires.
        guard isStarted, pendingScan == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.performScan()
        }
        pendingScan = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func performScan() {
        guard isStarted else { return }
        wakeRecoveryPending = false
        pendingScan?.cancel()
        pendingScan = nil
        do {
            let result = try engine.scan()
            resultHandler?(.success(result))
        } catch {
            resultHandler?(.failure(error))
        }
        guard isStarted else { return }
        installRootWatcherIfNeeded()
        rebuildFolderWatchers()
    }
}
