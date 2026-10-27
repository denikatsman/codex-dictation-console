import AppKit
import Foundation

public enum CodexApplicationLocator {
    public static let bundleIdentifier = "com.openai.codex"

    public static func locate() -> URL? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .compactMap(\.bundleURL)
        let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        let standard = roots.flatMap { root in
            ["Codex.app", "ChatGPT.app"].map { root.appendingPathComponent($0) }
        }
        return locate(in: running + [registered].compactMap { $0 } + standard)
    }

    static func locate(in candidates: [URL]) -> URL? {
        candidates.first { information(at: $0)?["CFBundleIdentifier"] as? String == bundleIdentifier }
    }

    static func information(at app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    public static func accountServiceBinary(in app: URL) -> URL? {
        // Desktop releases moved the CLI into its own nested application.
        // Keep the older layout available for installations that still use it.
        ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
         "Contents/Resources/codex"].map { app.appendingPathComponent($0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// Cheap invalidation for installed-build evidence. Read fresh plist/file
/// attributes rather than caching a Bundle across an application update.
public struct CodexBuildStamp: Equatable, Sendable {
    public let appPath: String?
    let informationHash: String?
    let archiveSize: UInt64?
    let archiveModifiedAt: Date?
    let archiveFileNumber: UInt64?

    public init(appURL: URL?) {
        appPath = appURL?.path
        let info = appURL.flatMap { try? Data(contentsOf: $0.appendingPathComponent("Contents/Info.plist")) }
        informationHash = info.map(DictationCaptureEngine.sha256)
        let attributes = appURL.flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0.appendingPathComponent("Contents/Resources/app.asar").path)
        }
        archiveSize = (attributes?[.size] as? NSNumber)?.uint64Value
        archiveModifiedAt = attributes?[.modificationDate] as? Date
        archiveFileNumber = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}
