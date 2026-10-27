import Darwin
import Foundation

/// Ownership is independent of the executable's location. The private mailbox
/// accepts only bounded, short-lived Open requests; it cannot carry commands.
public final class ApplicationLifetime: @unchecked Sendable {
    public enum HandoffError: LocalizedError {
        case unavailable
        case unsafeDirectory
        public var errorDescription: String? {
            switch self {
            case .unavailable: "The running library did not acknowledge the Open request. It may still be starting or quitting."
            case .unsafeDirectory: "The library's private application-ownership directory is not safe to use."
            }
        }
    }

    private struct OpenRequest: Codable {
        let action: String
        let expiresAt: Date
    }

    private let descriptor: Int32
    private let directory: URL
    private let queue = DispatchQueue(label: "local.codex-dictation-console.open-requests")
    private var watcher: DispatchSourceFileSystemObject?
    private let onOpen: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let onUpdateQuit: (@Sendable (@escaping @Sendable () -> Void) -> Void)?

    public static var productionDirectory: URL {
        ArchiveLayout().applicationSupportURL.appendingPathComponent("App Access", isDirectory: true)
    }

    /// Own the app before services exist, or hand an explicit launch to its owner.
    /// A contender retries briefly while the winner initializes or exits.
    public static func acquireOrForward(
        directory: URL = productionDirectory, background: Bool = false,
        onOpen: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
        onUpdateQuit: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil
    ) throws -> ApplicationLifetime? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        repeat {
            if let owner = try acquire(directory: directory, onOpen: onOpen, onUpdateQuit: onUpdateQuit) { return owner }
            if background { return nil }
            do { try forwardOpen(directory: directory); return nil }
            catch { /* An exiting owner can release the lock during handoff. */ }
        } while ContinuousClock.now < deadline
        throw HandoffError.unavailable
    }

    private init(descriptor: Int32, events: Int32, directory: URL,
                 onOpen: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
                 onUpdateQuit: (@Sendable (@escaping @Sendable () -> Void) -> Void)?) {
        self.descriptor = descriptor
        self.directory = directory
        self.onOpen = onOpen
        self.onUpdateQuit = onUpdateQuit
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: events, eventMask: [.write, .rename], queue: queue
        )
        watcher.setEventHandler { [weak self] in self?.receiveRequests() }
        watcher.setCancelHandler { _ = Darwin.close(events) }
        self.watcher = watcher
        watcher.resume()
        queue.async { [weak self] in self?.receiveRequests() }
    }

    deinit {
        watcher?.cancel()
        _ = Darwin.close(descriptor)
    }

    /// nil means another owner holds the lock. Never unlink the lock file.
    public static func acquire(
        directory: URL = productionDirectory,
        onOpen: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
        onUpdateQuit: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil
    ) throws -> ApplicationLifetime? {
        try prepare(directory)
        let fd = Darwin.open(directory.appendingPathComponent("owner.lock").path,
                             O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw posixError() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG else {
            _ = Darwin.close(fd)
            throw HandoffError.unsafeDirectory
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            _ = Darwin.close(fd)
            if code == EWOULDBLOCK || code == EAGAIN { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let events = Darwin.open(directory.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        guard events >= 0 else {
            let error = posixError()
            _ = Darwin.close(fd)
            throw error
        }
        return ApplicationLifetime(descriptor: fd, events: events, directory: directory, onOpen: onOpen, onUpdateQuit: onUpdateQuit)
    }

    public static func forwardOpen(directory: URL = productionDirectory, timeout: TimeInterval = 0.5) throws {
        try forward(action: "open", directory: directory, timeout: timeout)
    }

    public static func forwardUpdateQuit(directory: URL = productionDirectory, timeout: TimeInterval = 15) throws {
        try forward(action: "quit-for-update", directory: directory, timeout: timeout)
    }

    private static func forward(action: String, directory: URL, timeout: TimeInterval) throws {
        try prepare(directory)
        let token = UUID().uuidString
        let requestURL = directory.appendingPathComponent(token + ".open")
        let acknowledgementURL = directory.appendingPathComponent(token + ".ack")
        defer {
            try? FileManager.default.removeItem(at: requestURL)
            try? FileManager.default.removeItem(at: acknowledgementURL)
        }
        let request = OpenRequest(action: action, expiresAt: Date().addingTimeInterval(timeout))
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        repeat {
            if (try? Data(contentsOf: acknowledgementURL)) == Data("OK\n".utf8) { return }
            Thread.sleep(forTimeInterval: 0.02)
        } while ContinuousClock.now < deadline
        throw HandoffError.unavailable
    }

    private func receiveRequests() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return }
        for url in urls {
            let token = url.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: token) != nil else { continue }
            if url.pathExtension == "ack" {
                if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   Date().timeIntervalSince(modified) > 10 { try? FileManager.default.removeItem(at: url) }
                continue
            }
            guard url.pathExtension == "open" else { continue }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & S_IFMT == S_IFREG, info.st_size <= 512 else { continue }
            let request = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(OpenRequest.self, from: $0) }
            try? FileManager.default.removeItem(at: url)
            guard let request, request.expiresAt > Date() else { continue }
            let handler: (@Sendable (@escaping @Sendable () -> Void) -> Void)?
            switch request.action {
            case "open" where request.expiresAt.timeIntervalSinceNow <= 5: handler = onOpen
            case "quit-for-update" where request.expiresAt.timeIntervalSinceNow <= 20: handler = onUpdateQuit
            default: handler = nil
            }
            guard let handler else { continue }
            let acknowledgementURL = directory.appendingPathComponent(token + ".ack")
            handler {
                // Do not leave acknowledgements for a client that timed out.
                guard request.expiresAt > Date() else { return }
                try? Data("OK\n".utf8).write(to: acknowledgementURL, options: .atomic)
            }
        }
    }

    private static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            throw HandoffError.unsafeDirectory
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
