import Combine
import Foundation

struct AppAccessPreferences: Equatable {
    var showInMenuBar: Bool
    var showInDock: Bool
    static let defaults = Self(showInMenuBar: false, showInDock: true)
    var hasEntryPoint: Bool { showInMenuBar || showInDock }
}

@MainActor
final class AppAccessSettings: ObservableObject {
    static let defaultsKey = "libraryAppAccess"
    static let changedNotification = Notification.Name("local.codex-dictation-console.access-changed")
    @Published private(set) var preferences: AppAccessPreferences
    private let defaults: UserDefaults
    private var observation: NSObjectProtocol?
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: Self.defaultsKey)
        let loaded = AppAccessPreferences(
            showInMenuBar: saved?["showInMenuBar"] as? Bool ?? false,
            showInDock: saved?["showInDock"] as? Bool ?? true
        )
        preferences = loaded.hasEntryPoint ? loaded : .defaults
        if !loaded.hasEntryPoint { persist() }
        if defaults === UserDefaults.standard {
            observation = DistributedNotificationCenter.default().addObserver(
                forName: Self.changedNotification, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.reload() } }
        }
    }

    deinit { if let observation { DistributedNotificationCenter.default().removeObserver(observation) } }

    func reload() {
        defaults.synchronize()
        let saved = defaults.dictionary(forKey: Self.defaultsKey)
        let loaded = AppAccessPreferences(showInMenuBar: saved?["showInMenuBar"] as? Bool ?? false,
            showInDock: saved?["showInDock"] as? Bool ?? true)
        if !loaded.hasEntryPoint {
            preferences = .defaults
            persist()
            onChange?()
        } else { set(loaded) }
    }

    @discardableResult
    func set(_ preferences: AppAccessPreferences) -> Bool {
        guard preferences.hasEntryPoint else { return false }
        guard preferences != self.preferences else { return true }
        self.preferences = preferences
        persist()
        onChange?()
        return true
    }

    func setMenuBar(_ visible: Bool) {
        var next = preferences; next.showInMenuBar = visible; set(next)
    }

    func setDock(_ visible: Bool) {
        var next = preferences; next.showInDock = visible; set(next)
    }

    private func persist() {
        defaults.set(["showInMenuBar": preferences.showInMenuBar, "showInDock": preferences.showInDock],
                     forKey: Self.defaultsKey)
        if defaults === UserDefaults.standard {
            defaults.synchronize()
            DistributedNotificationCenter.default().postNotificationName(Self.changedNotification,
                object: nil, userInfo: nil, deliverImmediately: true)
        }
    }
}
