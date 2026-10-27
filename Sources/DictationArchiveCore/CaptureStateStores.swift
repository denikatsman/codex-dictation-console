import Foundation

public struct CaptureSettingsStore: Sendable {
    public let layout: ArchiveLayout
    private let notifyHelper: @Sendable () -> Void

    public init(layout: ArchiveLayout = ArchiveLayout()) {
        self.init(layout: layout) {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("local.codex-dictation-console.capture-settings-changed"),
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        }
    }

    init(layout: ArchiveLayout, notifyHelper: @escaping @Sendable () -> Void) {
        self.layout = layout
        self.notifyHelper = notifyHelper
    }

    public func load() -> CaptureSettings {
        (try? loadChecked()) ?? .unavailable
    }

    public func loadChecked() throws -> CaptureSettings {
        do {
            return try JSONDecoder.archiveDecoder.decode(CaptureSettings.self, from: Data(contentsOf: layout.settingsURL))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .default
        } catch {
            throw ArchiveError.invalidRecord("Capture settings could not be read. Automatic capture is disabled until the settings are corrected. \(error.localizedDescription)")
        }
    }

    public func save(_ settings: CaptureSettings) throws {
        try ArchiveLock.withExclusiveAccess(to: layout) { try persist(settings) }
    }

    @discardableResult
    public func update(_ change: (inout CaptureSettings) -> Void) throws -> CaptureSettings {
        try ArchiveLock.withExclusiveAccess(to: layout) {
            var settings: CaptureSettings
            do { settings = try loadChecked() }
            catch {
                // Only an explicit edit enters this path. Keep the unreadable
                // bytes before allowing that edit from disabled defaults.
                let data = try Data(contentsOf: layout.settingsURL)
                let backup = layout.applicationSupportURL.appendingPathComponent("capture-settings-unreadable-\(UUID().uuidString).json")
                try data.write(to: backup, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                settings = .unavailable
            }
            change(&settings)
            try persist(settings)
            return settings
        }
    }

    private func persist(_ settings: CaptureSettings) throws {
        try layout.prepare()
        let data = try JSONEncoder.archiveEncoder.encode(settings)
        try data.write(to: layout.settingsURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: layout.settingsURL.path
        )
        // The installed helper observes the default archive. Saving a fixture
        // or another independent archive must not ask that helper to scan.
        if layout.applicationSupportURL.standardizedFileURL == ArchiveLayout().applicationSupportURL.standardizedFileURL {
            notifyHelper()
        }
    }
}

public struct CaptureStatusStore: Sendable {
    public let layout: ArchiveLayout

    public init(layout: ArchiveLayout = ArchiveLayout()) {
        self.layout = layout
    }

    public func load() -> CaptureHealthSnapshot? {
        guard
            let data = try? Data(contentsOf: layout.statusURL),
            let snapshot = try? JSONDecoder.archiveDecoder.decode(
                CaptureHealthSnapshot.self,
                from: data
            )
        else { return nil }
        return snapshot
    }

    public func save(_ snapshot: CaptureHealthSnapshot) throws {
        try layout.prepare()
        let data = try JSONEncoder.archiveEncoder.encode(snapshot)
        try data.write(to: layout.statusURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: layout.statusURL.path
        )
    }
}
